# Secondmate context handoff

When a persistent secondmate's context window fills, running `/compact` degrades its working memory and answer quality.
This home instead hands the work off to a FRESH secondmate agent that recovers from durable on-disk state plus a continuation document, done BEFORE the context fills.

This document is the evidence and mechanism narrative.
The procedure lives in the `secondmate-provisioning` skill's "Context handoff" section.
Exact flags, paths, and commands live in the headers and `--help` of `bin/fm-secondmate-context.sh` and `bin/fm-secondmate-handoff.sh`.
The threshold configuration schema lives in `docs/configuration.md`.

## Reading a live secondmate's context usage

The monitor never guesses.
For each supported harness it either has an evidence-backed read or it reports `unknown` and the monitor fails closed (no handoff is ever triggered from an unreadable context).

### claude (VERIFIED 2026-07-20, Claude Code 2.1.215)

The authoritative signal is the harness's own session transcript, not the pane footer.

**Why not the pane footer.**
The pane footer is unreliable as a machine signal:

- It is a user-configurable surface.
  This home runs a third-party `ccstatusline` command statusline, so the footer reads `Opus 4.8 | low | Total: 1142.2M | 976...` rather than any standard claude context line.
  A different home with a different (or no) custom statusline shows something else entirely.
- It is truncated to the pane width.
  Captured at 80 columns the context figure is cut off mid-number (`976...`, `84.7k...`), so the exact token count is frequently not even present in the capture.
- The standard claude footer only surfaces a context figure when context is already low, which is too late for a proactive handoff.

Exact commands and output that established this (this home, 2026-07-20):

```
$ claude --version
2.1.215 (Claude Code)

$ tmux capture-pane -p -t firstmate:3 -S -3 | tail -3
  Opus 4.8 | low | Total: 1142.2M | 976...
  ⏵⏵ bypass permissions on · 1 shell · ← for agents

$ grep -A6 -i statusline ~/.claude/settings.json
  "statusLine": {
    "type": "command",
    "command": "ccstatusline",
    "padding": 0,
    "refreshInterval": 1
  },
```

**The authoritative read.**
Claude Code appends a JSONL transcript per session under `<config-dir>/projects/<munged-cwd>/<session-id>.jsonl`, where:

- `<config-dir>` is `$CLAUDE_CONFIG_DIR` when set, otherwise `~/.claude`.
- `<munged-cwd>` is the session's launch directory with every `/` and `.` replaced by `-`.
  Verified: `/Users/cyuan/.treehouse/firstmate-7bab20/3/firstmate` maps to the on-disk directory `-Users-cyuan--treehouse-firstmate-7bab20-3-firstmate` (the `/.` in `/.treehouse` becomes `--`).
- The launch directory of a secondmate agent is its home, recorded as `home=` in `state/<id>.meta`.
  Verified: the live `fm-pricing-qa` pane reports `pane_current_path` = its recorded `home=`.

Each assistant turn writes a `message.usage` object.
The context-window occupancy at that turn is the sum of the three input components:

```
context_tokens = input_tokens + cache_creation_input_tokens + cache_read_input_tokens
```

Verified against the same live secondmate the ccstatusline footer described (2026-07-20):

```
$ F=~/.claude/projects/-Users-cyuan--treehouse-firstmate-7bab20-5-firstmate/64738c64-....jsonl
$ grep '"usage"' "$F" | grep -v '"isSidechain":true' | tail -1 \
    | jq '(.message.usage.input_tokens // 0)+(.message.usage.cache_creation_input_tokens // 0)+(.message.usage.cache_read_input_tokens // 0)'
88563
```

The pane's ccstatusline had shown `84.7k...` a few turns earlier, so the transcript sum tracks the harness's own accounting.

Read rules that keep this robust:

- Pick the newest-mtime `*.jsonl` in the project directory; that is the active session (a resumed or compacted session keeps writing the same file).
- Consider only lines carrying `message.usage` and skip `isSidechain:true` lines: sub-agent (Task) turns are a separate context and must not be counted as the main thread's occupancy.
- Take the LAST such line: it is the most recent completed main-thread turn.
- `jq` is required to parse the line safely; when `jq` is absent the read returns `unknown` and the monitor fails closed.

Known staleness edge: between a `/compact` (or resume) and the first assistant turn afterward, the last recorded usage still reflects the pre-compact turn, so the read is briefly stale-high.
This is safe for a threshold monitor - it can only over-report, never silently miss - and the handoff orchestrator re-checks safety (idle, not mid-turn) before acting, and this feature exists precisely to make that `/compact` unnecessary.

### jcode (VERIFIED 2026-08-01)

jcode (github.com/1jehuang/jcode) is a Claude-Agent-SDK runtime, but it does NOT write to claude's `~/.claude/projects/` transcript directory.
It persists its own per-session journal at `<jcode-home>/sessions/session_<id>.journal.jsonl`, where `<jcode-home>` is `$JCODE_HOME`, else `~/.jcode`.
The context count is the LAST POSITIVE per-record `append_messages[].token_usage` sum, each summed as `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` - the same three-component formula as claude, but a different object (`append_messages[].token_usage`, not claude's `message.usage`) in a different, record-append journal.
jcode has its own reader, `fm_sm_jcode_context_tokens`, and `fm_sm_context_tokens` dispatches jcode to it rather than to the claude reader.

**Why the last POSITIVE record, not simply the last record.**
A real jcode journal can END on a degenerate `token_usage` record - `{"input_tokens":0,"output_tokens":0}` with no cache fields - after many high-usage turns.
This is an interrupted, placeholder, or system turn that carries no context accounting.
A naive last-record read sums that to `0`, fails the `> 0` guard, and returns `unknown`, so a high-occupancy session (even ~500000 tokens) reads as `unknown` and no handoff fires.
Observed live in `session_unicorn_1787764311482_c2b58efc0fa21e76.journal.jsonl` (this machine, 2026-09-01): 28 `token_usage` records climbing to `84661`, then a final `{"input_tokens":0,"output_tokens":0}` that a tail-1 read scored as `0`.
The reader instead walks the per-record sums and keeps the last POSITIVE one, so the trailing degenerate turn cannot mask real occupancy.
It still returns `unknown` when NO record is positive (a genuinely empty or format-shifted journal), so the fail-closed contract holds.

```
$ f=~/.jcode/sessions/session_unicorn_1787764311482_c2b58efc0fa21e76.journal.jsonl
$ grep '"token_usage"' "$f" | jq '([.append_messages[]?.token_usage//empty]|last) as $u
        | (($u.input_tokens//0)+($u.cache_creation_input_tokens//0)+($u.cache_read_input_tokens//0))' | tail -3
83399
84661
0
# last-record read -> 0 -> unknown (the bug); last-positive read -> 84661 (correct)
```

A session is keyed to its home by its FIRST journal line's `.meta.working_dir`, compared for EXACT string equality against the home path (jcode stores the raw absolute path, so there is no path-munging step).
Multiple stale same-home journals can exist, so selection prefers the journal whose `session_<id>` basename is present in `<jcode-home>/active_pids/` (the running session), falling back to the newest-mtime `working_dir` match when no active-pid match exists (a resumed or edge session).
This prevents a stale `.json`-only same-home leftover from shadowing the live session.

Earlier a false verification recorded jcode as "byte-identical to claude" returning `51046` from `~/.claude/projects/-work-firstmate-work/`.
That number came from a stale, frozen claude-directory mirror (last updated 2026-07-31T21:50) while the live jcode journal for the same home had climbed past 180000, so the byte-identical claim and the claude dispatch were both wrong.

Exact commands and output that established the corrected read (this machine, 2026-08-01, firstmate running natively on jcode):

```
$ bin/fm-harness.sh
jcode

$ F=~/.jcode/sessions/session_hare_1785566988431_25ee34e0e322bffd.journal.jsonl
$ head -1 "$F" | jq '.meta.working_dir,.meta.status'
"/root/.treehouse/firstmate-work-468eb4/2/firstmate-work"
"Active"

$ grep '"token_usage"' "$F" | tail -1 \
    | jq '(.append_messages[].token_usage) as $u
          | ($u.input_tokens//0)+($u.cache_creation_input_tokens//0)+($u.cache_read_input_tokens//0)'
86866

$ grep '"token_usage"' "$F" | tail -1 | jq '.append_messages[].token_usage | keys'
["cache_creation_input_tokens","cache_read_input_tokens","input_tokens","output_tokens"]
```

The reader mirrors the claude reader's fail-closed discipline: an absent `jq`, an absent sessions directory, no `working_dir` match, no `token_usage` line, or no record with a positive sum all return `unknown` rather than a wrong number.
Every field is guarded with jq `// 0` and each per-record sum is validated with `[[ =~ ^[0-9]+$ ]] && > 0`, keeping only the last positive one, so any jcode format shift (a renamed field or a moved directory) makes all matches fail and the reader returns `unknown`.
Only each file's first line is scanned for `working_dir` before parsing usage, which is sub-second even across ~130 session files on the slow-poll cadence.
This same read is what the supervision daemon uses for firstmate's OWN context-stow nudge (`config/context-stow-threshold`, docs/configuration.md), pointed at firstmate's home instead of a secondmate's - which is why this correction also restores that nudge, which the stale-mirror read had silently under-reported.

Known staleness edge (same as claude): between a `/compact` (or resume) and the first turn afterward, the last `token_usage` still reflects the pre-compact turn, so the read is briefly stale-high.
This is acceptable for a threshold monitor because it can only over-report, never silently miss, and the handoff orchestrator re-checks idle before acting.

### codex, opencode, pi, grok (NOT APPLICABLE - no verified read)

Each of these harnesses persists session state in its own place and format, none of which has been reverse-engineered and verified for a token-occupancy read:

- codex: `~/.codex/sessions/` (inspected 2026-07-20; format not verified).
- opencode: `~/.local/share/opencode/storage/` (inspected 2026-07-20; format not verified).
- pi: `~/.pi/context-mode/sessions/` (inspected 2026-07-20; format not verified).
- grok: not installed on this machine at inspection time; no artifact to inspect.

For every harness other than claude the context read returns `unknown` and the monitor fails closed: it never triggers a handoff it cannot justify.
Adding a verified read for another harness is future work - reverse-engineer its transcript, record the evidence here in the same date/version/command/output form, and extend `bin/fm-secondmate-context-lib.sh`'s `fm_sm_context_tokens` dispatch.

## Threshold monitoring and the wake

The primary's watcher already runs a slow poll every `FM_CHECK_INTERVAL` seconds (default 300).
That block iterates each live secondmate window, reads its context tokens with the rule above, and acts once when the count first crosses the configured threshold.
A per-window surfaced marker makes the crossing idempotent: the action fires once per crossing and re-arms only after the count drops back below the threshold (which a fresh post-handoff agent does).
The read is bounded and only runs on the slow-poll cadence, never on every fast poll.

What the crossing does depends on the opt-in `config/secondmate-auto-handoff` flag (`docs/configuration.md`):

- Flag ABSENT (the default, fail-closed): the watcher only enqueues a `check:` wake (`secondmate-context <id>`) so firstmate is woken to run `bin/fm-secondmate-handoff.sh <id>` by hand.
  This is the original behavior, unchanged.
- Flag PRESENT (opt-in): the watcher hands the secondmate off automatically, with no primary wake needed to start it.

### Automatic handoff (opt-in)

When `config/secondmate-auto-handoff` is enabled, a first threshold crossing on an IDLE secondmate launches the handoff itself instead of waking the primary.
The design preserves every safety invariant:

- Only an idle secondmate is handed off.
  The watcher checks the pane is not mid-turn before launching, and the handoff script re-checks idle before it steers, so a mid-turn agent is deferred to a later cycle.
  A deferred crossing does NOT set the surfaced marker, so it is re-evaluated on the next poll rather than lost.
- The handoff runs DETACHED from the watcher.
  The multi-minute steer, bounded wait, exit, and respawn of `bin/fm-secondmate-handoff.sh` is a several-minute sequence, so running it inside the slow-poll cycle would stall the whole supervision loop.
  The watcher instead launches `bin/fm-secondmate-auto-handoff.sh <id>` in the background and never waits on it, so the supervision loop keeps polling immediately.
  The surfaced marker is set BEFORE the launch, so a handoff in flight is not re-launched on the next poll.
- The handoff itself is the SAME orderly, fail-closed, idempotent `bin/fm-secondmate-handoff.sh` sequence below.
  The auto-handoff wrapper adds nothing to that contract; it delegates the whole sequence unchanged and owns only the after-the-fact primary notification and a per-id double-launch lock.
- The primary is always told an automatic handoff happened.
  This FYI is required, so the primary knows its secondmate was replaced.
  On success the wrapper enqueues one `check: secondmate-handoff <id>` wake the primary surfaces at its next supervision cycle; on failure it enqueues one `check: secondmate-handoff-failed <id>` escalation naming the by-hand command, failing closed to the escalate-only path on any doubt.
  A failed handoff leaves the surfaced marker in place (the old, still-over-threshold agent keeps the crossing marked), so the escalation fires exactly once and does not re-launch every poll.

Exact flags, env, and the notification wording live in the header of `bin/fm-secondmate-auto-handoff.sh`; the flag schema lives in `docs/configuration.md`; the procedure lives in the `secondmate-provisioning` skill.

## Handoff sequence

`bin/fm-secondmate-handoff.sh <id>` orchestrates the replacement, idempotently and failing closed:

1. Resolve `home`, `window`, `harness`, and `kind=secondmate` from `state/<id>.meta`; refuse if any is missing or the task is not a secondmate.
2. Refuse if the secondmate agent is not confidently idle (mid-turn work must finish first) or its endpoint is unreadable - a handoff must never interrupt in-flight work.
3. Steer the secondmate to write its continuation document to a durable in-home path (`data/handoff-latest.md`, never OS temp) via `/handoff`, then run `stow`, and signal completion.
4. Wait, bounded, for the durable document and completion signal; time out and refuse rather than proceeding blind.
5. Exit the old agent with the harness-correct exit form.
6. Respawn a fresh secondmate with `bin/fm-spawn.sh <id> --secondmate` and point it at the durable document plus its charter.

The respawn preserves the home's backlog, projects, and in-flight crew exactly as `secondmate-provisioning` recovery does; the handoff never tears down or discards unlanded work.
