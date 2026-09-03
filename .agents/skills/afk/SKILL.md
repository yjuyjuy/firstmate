---
name: afk
description: >-
  Enter away-mode supervision when the captain invokes /afk, says they are going afk, `state/.afk` exists, an incoming message starts with `FM_INJECT_MARK`, or any `state/.subsuper-*` marker is involved.
  It sets a durable away-mode flag so the sub-supervisor daemon can self-handle routine wakes and escalate captain-relevant events plus bounded declared-external-wait rechecks as batched digests during walk-away stretches, and it persists through ordinary captain messages until an explicit exit instruction returns firstmate to full per-wake responsiveness.
user-invocable: true
metadata:
  internal: true
---

# afk

Away-mode supervision. When invoked, `/afk` makes the daemon's token-saving
tradeoff **consented** and **explicit**: the captain is stepping away, so the
sub-supervisor may triage routine wakes in bash instead of waking firstmate's
LLM for each one. Escalations still reach the captain, but as one pre-read,
batched digest rather than per-wake injections.
Where no pane exists for the daemon to inject into, the daemon still runs and delivers through the durable outbox that firstmate's armed inbox reader drains; pick the entry path first.

## Pick the entry path first

Away mode has two first-class entry paths.
Decide between them BEFORE running anything, from one question: does the daemon have a delivery channel here?

- **An injectable supervisor pane exists** (firstmate runs inside tmux or herdr, so a pane can be typed into): use the **daemon entry** below in its pane-delivery form.
- **No injectable supervisor pane, but this harness has a native tracked-background tool** (claude's background bash, grok's background tool, so the daemon and the inbox reader can both be hosted): use the **daemon entry** below in its paneless pull-delivery form.
- **Neither** (no pane the daemon could reach and no way to host the daemon or the reader, or a supported backend that refuses to launch the daemon terminal): use the **daemon-free entry** below.

Never start a daemon with nowhere to deliver.
A daemon that cannot reach firstmate talks to nobody: its escalations buffer and are lost silently, a failure this fleet has already had.
Paneless pull delivery through the durable outbox plus the armed inbox reader IS a delivery channel, so it satisfies that requirement; a daemon started with no pane AND no armed reader does not.
Never manufacture a pane just to satisfy the daemon.

Both entries share the same away posture, the same exit contract, and the same
approval authority; they differ only in what supervises.

## Daemon entry (pane delivery or paneless pull delivery)

1. **Enter the lifecycle through `bin/fm-afk-launch.sh`.**
   This owns the durable state write, session-scoped stale-artifact clearing,
   terminal record, and rollback.
   The flag survives a firstmate restart, so recovery re-enters afk when it is present.

2. **Ensure the sub-supervisor daemon is running as a tracked background process.**
   Its hosting differs by harness.
   Pick the right path:
   - **Paneless home** (no injectable supervisor pane, e.g. a claude desktop-app
     session): run `bin/fm-afk-launch.sh start-paneless`. It hosts the daemon in
     a detached tmux session with pull delivery forced on, so the daemon (and the
     watcher it owns as a child) survives a firstmate session turnover.
     tmux is present as the runtime backend even though firstmate itself runs
     outside it, so a detached tmux session is a session-independent host.
     Do NOT use the older `start-native` path here: it hosts the daemon as a
     harness-native background job that is a CHILD of the firstmate session and is
     reaped on the next turnover, silently taking away supervision down with it
     (evidence 2026-07-26). `start-native` remains only for a home with no tmux
     CLI at all; a genuinely tmux-less home should prefer the daemon-free entry.
     Never wrap the daemon in `nohup ... &` (Codex/herdr can reap fire-and-forget
     shell children after a tool call returns); a detached tmux session is not
     that.
   - **Harness WITHOUT one** (e.g. pi): run `bin/fm-afk-launch.sh start`. It is
     the single owner of the daemon terminal: it creates a NON-VISIBLE tracked
     terminal for the current backend (a herdr dedicated `--no-focus` workspace,
     a detached tmux session), records its exact id, and passes the captain pane
     in as `FM_SUPERVISOR_TARGET` so the daemon injects into the captain, not its
     own new pane. **Never manufacture a terminal by splitting the captain's
     active pane** (`herdr pane split`): a split co-tenants the tab and visibly
     shrinks the captain's pane (docs/herdr-backend.md "Away-mode daemon terminal
     launch").
   The paneless form captures no supervisor pane and injects into nothing; it forces `FM_AFK_DELIVERY=paneless` so the daemon selects pull delivery unconditionally rather than discovering the tmux pane it is itself hosted in and typing there.
   All hosting paths share `bin/fm-afk-start.sh` as the daemon entry, which performs its state setup inside the new terminal.
   It exits immediately if the identity-backed daemon lock already names a live process, otherwise it execs `bin/fm-supervise-daemon.sh` in the foreground.
   The daemon is **presence-gated**: it injects escalations only while
   `state/.afk` exists, and stays quiet otherwise.

3. **On the paneless form, arm the away-mode inbox reader as a tracked background task.**
   This step belongs to the paneless entry, because the reader IS that form's delivery channel (see "Delivery channel" below); a pane-delivery entry does not arm a reader.
   Run `bin/fm-afk-inbox-arm.sh` through the harness's own tracked background mechanism, exactly the way `bin/fm-watch-arm.sh` is armed, and never with a shell `&`.
   On a jcode primary, "exactly the way `bin/fm-watch-arm.sh` is armed" includes the mandatory jcode wake step: after launching the reader arm as a `Bash run_in_background` task, set `wake: true` on that task id with the `bg` tool (subscribe), because a jcode background task defaults to `wake: false` and a `wake: false` completion never wakes the idle away session - that exact non-wake left away-mode escalations delivered but unread (`docs/jcode-wake-adapter.md`).
   The wrapper is the resilient arm layer around the bare reader `bin/fm-afk-inbox.sh`: it runs the reader resident so a quiet home never idle-exits it, self-relaunches it on a crash with bounded backoff, and passes every genuine reader outcome straight through.
   Do not arm the bare `bin/fm-afk-inbox.sh` directly; the wrapper owns residence and crash recovery, and the bare reader alone reintroduces the hourly idle-exit gap this path removed.
   If you armed it on a session that turns out to have a pane, it costs nothing: it prints one line saying the pane is delivering and exits immediately.
   Each completion is an internal escalation, not captain input.
   Read the digests it printed and act on them.
   Then obey its final line for whether to arm it again: every exit ends in either `re-arm to keep listening` or `- do not re-arm`.
   Re-arming after a `do not re-arm` line is an immediate-exit loop, because that line means the pane is delivering or the away session is over, so nothing will ever arrive here.
   A run that failed exits non-zero with a loud diagnostic and still ends in a `re-arm to keep listening` line, because its records are still pending and nothing else is listening for them: re-arm it once and report the diagnostic, and treat a second identical failure as a blocker for the captain rather than a loop to keep running.
   An argument error is the one exit with no verdict at all; fix the invocation instead of re-arming it.

4. **Do not separately arm the watcher.**
   The daemon manages `bin/fm-watch.sh` as its child, and the singleton lock
   no-ops a stray arm harmlessly.

5. **Acknowledge** in `AGENTS.md` section 9 language: "Captain, away mode is active; I will batch routine updates and surface only decisions, failures, credentials, or review-ready work until you return."

## Persisting away mode across a session turnover

By default away mode is a single-session posture: the operational `state/.afk`
flag is cleared when the captain becomes responsive again (the return flow) or
at an explicit stop, and a fresh session after a turnover starts responsive.

When the captain orders away supervision to SURVIVE turnovers - "stay away until
I tell you otherwise" - record that as a durable, machine-readable intent, not
just prose in `data/captain.md`:

- **Enter persistent away** with `bin/fm-afk-launch.sh persist`.
  It records the durable persist intent (`state/.afk-persist`) and enters durable
  paneless away mode in one step.
- **Session start then self-heals.** While the persist intent is set, the
  session-start revive sweep (`bin/fm-bootstrap.sh` afk_daemon_revive_sweep) sees
  no live daemon after a turnover and re-enters durable paneless away mode
  automatically, bringing the daemon and its watcher child back with no manual
  re-arm. Only a revive failure surfaces, as a bootstrap `AFK_DAEMON:` line.
- **The return flow does NOT clear the persist intent.** An explicit exit
  instruction makes THIS session responsive (stops the daemon, clears `.afk`),
  but the standing away order remains, so the next turnover resumes supervision.
  Persistent away ends completely only through `unpersist`.
- **End persistent away** with `bin/fm-afk-launch.sh unpersist` (the only path
  that clears the intent), then run the normal return flow below. After that a
  turnover no longer re-enters away mode.

Plain `/afk` (without `persist`) keeps its single-session auto-exit behavior
unchanged.

## Daemon-free entry (no delivery channel at all)

Use this only when the daemon has neither a pane nor a hostable pull path: this harness has no native tracked-background tool to run the daemon and its reader in, or the supported backend it would need refuses to launch the daemon terminal.
A session that merely lacks a supervisor pane is NOT this case; it takes the paneless daemon entry above.
This is a supported configuration, not a degraded one.
`state/.afk` then carries the away POSTURE only (batched updates and the standing routine merge authority), while this home's own watcher stays the real supervision mechanism.

1. **Enter the lifecycle with `bin/fm-afk-launch.sh start-daemonless`.**
   It is the same lifecycle owner as the daemon paths: it writes `state/.afk`,
   clears session-scoped stale artifacts, records that no terminal exists, and
   rolls back on failure.
   It creates no terminal and starts nothing.
   Never hand-write `state/.afk`.
   It refuses with a non-zero status, and changes nothing, when an away-mode daemon is already live for this home, naming that daemon's process id.
   Handle that refusal deliberately: either stop the live daemon with `bin/fm-afk-launch.sh stop` and re-run the daemon-free entry, or decide this session really does have a delivery channel and use the daemon entry instead.
   Never work around the refusal by hand-writing the flag.

2. **Skip the daemon entirely.**
   Do not run `bin/fm-afk-start.sh`, `start`, or `start-native`, and do not
   manufacture a pane for a daemon.
   Say plainly to the captain that away mode is running without the daemon
   because there is no way to reach them with its escalations here.

3. **Keep arming and repairing this home's own watcher cycle** exactly as in
   normal mode, for the whole away stretch, through the emitted primary-harness
   supervision protocol.
   That cycle is the supervision mechanism here, so every ordinary wake, arm,
   and repair rule still applies.

4. **Acknowledge** in the same `AGENTS.md` section 9 language as the daemon entry.

Supervision ownership is decided by whether an away-mode daemon is actually live
for this home, never by the flag alone; `bin/fm-afk-daemon-lib.sh` owns that
question and every script asks it there.

## How to exit afk

Both entry paths exit the same way, through `bin/fm-afk-return.sh`, and differ only in what that shutdown has to stop.
When the durable persist intent is set (see "Persisting away mode across a session turnover" above), this return still makes THIS session responsive but deliberately leaves the intent in place, so a later turnover resumes supervision; a full stop needs `bin/fm-afk-launch.sh unpersist` first.
After a daemon entry it stops the daemon, so per-wake responsiveness comes back when the daemon is gone.
After a daemon-free entry there is no daemon to stop and per-wake responsiveness was never handed away: exit clears the away posture and this session simply keeps its own watcher-arm supervision running.
Every other part of the return contract, including the durable catch-up gate, is identical on both paths.

Away mode ends ONLY on an explicit exit instruction from the captain.
An ordinary captain message, including an answer to a question firstmate asked, does NOT end it.
This is a standing captain order from 2026-07-25: the captain answers questions from a phone throughout the day while genuinely still away, so treating those replies as a return tore away supervision down repeatedly and cost a daemon restart, a full catch-up gate, and blocker reclassification each time.

`bin/fm-supervise-daemon.sh`'s `message_is_afk_exit` is the single owner of the exit grammar, and its header comment lists every accepted form: `/back`, `/unafk`, `/afk` with an `exit`, `off`, `stop`, `end`, or `done` subcommand, and a whole-message plain-language instruction such as "im back" or "exit away mode".
Do not restate or widen that list here; ask the function.

- An **explicit exit instruction** -> the captain is back.
  Run `bin/fm-afk-return.sh` before acting on the message that brought the captain back.
  That script owns correct-ordered daemon shutdown, durable wake draining, escalation and wedge evidence, any escalation the inbox reader never picked up, and the return-catch-up gate.
  If it reports a firstmate-actionable `blocked:` event, remediate it immediately through the normal lifecycle, or explicitly reclassify it with a durable reason and close its decision key with `resolved [key=...]`, then run `bin/fm-afk-return.sh check`.
  Once the daemon stops, or immediately when the daemon-free entry left none to stop, resume full per-wake responsiveness through the emitted primary-harness supervision protocol while blocker handling proceeds, so the gate never creates a blind wait.
  Do not answer a Bearings request or perform any other ordinary captain work until the check exits successfully.
- A message **with** the current operational prefix (`FM_OPERATIONAL_PREFIX`, U+2063 INVISIBLE SEPARATOR followed by `FIRSTMATE_OP: `), or a legacy bare `FM_INJECT_MARK` daemon escalation -> stay afk and process it.
- Re-invoking `/afk` while already away, including `/afk back in an hour` -> stay afk (refresh the flag); this
  does **not** trigger an exit.
- Any other unmarked captain message -> stay afk and answer it in place, keeping the away posture and batched escalations intact.
  Do not run `bin/fm-afk-return.sh`, do not stop the daemon, and do not open the catch-up gate.
  Answering a question is not returning.

Bias ambiguous cases toward STAYING away: a wrong exit tears down supervision
the captain never asked to end, while a missed exit costs one more explicit
word from a captain who is present anyway.

## Orthogonal to approval authority

afk changes how aggressively firstmate surfaces things, **not who approves
what**. "Away" never means "approves more." A PR ready for merge, a
needs-decision finding, or anything destructive still waits for the captain's
explicit word - the daemon just batches the notification.

## Delivery channel

Escalations reach firstmate one of two ways, chosen once at daemon startup and logged with the reason.

- **Pane delivery** types the digest into firstmate's own pane.
  It is selected whenever supervisor discovery positively identifies that pane, and everything below about busy guards, composer guards, and the verified submit model applies to it.
- **Paneless delivery** is selected when nothing identified that pane, for example a primary firstmate running outside every supported terminal backend such as a desktop-app session.
  Rather than typing into the legacy `firstmate:0` guess, which lands in an unrelated pane and never confirms a submit, the daemon appends each flushed digest to a durable outbox and the armed reader (step 3 above) delivers it.
  A supported-but-broken pane is different and still refuses loudly at startup: an explicit target that does not resolve, or an unsupported supervisor backend, means the captain named a pane and the daemon must not quietly stop using it.

Nothing is lost in either mode.
Records are acknowledged only after the reader has already printed them, so a reader killed mid-wait or mid-print simply delivers the same records on its next run, and anything still unacknowledged at return is reported by `bin/fm-afk-return.sh` as catch-up evidence.
`docs/configuration.md` owns the state files and the `FM_AFK_DELIVERY` override, `bin/fm-afk-outbox-lib.sh` owns the record and acknowledgement contract, and `bin/fm-afk-inbox.sh --help` owns the reader's flags and exit lines.

## Two live processes in paneless mode, and autonomous queue advancement

A paneless away home depends on the daemon AND the reader, and both must be alive for away supervision to reach anyone.
Session start reports a reader that has stopped while records are waiting as one `AFK_READER:` line (`bin/fm-afk-reader-check.sh`, handled by the `bootstrap-diagnostics` skill); the daemon separately raises its loud wedge alarm on the same condition.
Never start the reader with a plain `&`: it acknowledges every record it prints, so a reader nobody is reading consumes the captain's escalations.

Escalating is a notification, and while the captain is away there may be no firstmate turn for hours, so the daemon also runs one bounded `bin/fm-afk-driver.sh` tick per cadence while away mode is active.
Those ticks appear on the captain's catch-up as `away-mode driver:` records, which is how a return report explains what moved with no firstmate turn behind it.
`bin/fm-afk-driver.sh`'s header owns what a tick does and every boundary it keeps, and `docs/configuration.md` owns its cadence and cap knobs.

## Operational prefix contract

The daemon constructs every current injection as the `away-supervisor` kind owned by `bin/fm-operational-input.sh`, beginning with `FM_OPERATIONAL_PREFIX`: `FM_INJECT_MARK` (U+2063 INVISIBLE SEPARATOR) followed by the stable `FIRSTMATE_OP: ` label.
The bare `FM_INJECT_MARK` form remains accepted for legacy daemon escalations during rollout.
U+2063 has no normal keyboard keystroke and survives terminal transport as UTF-8 text.
This is how firstmate tells a daemon escalation apart from a real message in the same pane.
The operational prefix travels with the message text; it does not rely on harness-level typed-vs-injected detection, which is not portable across claude, codex, opencode, pi, and grok.

## Busy-guard and composer guard

The daemon never injects into an in-use pane. Two checks run before every
injection, dispatched through `bin/fm-backend.sh` for the supervisor's own
backend (tmux or herdr; see "Auto-discovered supervisor pane" below):

- **`pane_is_busy`** - the harness shows a busy footer (agent mid-turn) on tmux (shared with `fm-send.sh` via `bin/fm-tmux-lib.sh`); on herdr, tries the native `agent.get`-backed busy state first, trusts only `busy` outright, and corroborates every non-`busy` verdict with the same regex-over-capture reader.
- **Composer-state guard** - `inject_msg` reads the full `empty`/`pending`/`unknown` verdict from `fm_backend_composer_state` and injects only when it is affirmatively `empty`.
  `pending` means real unsubmitted text, while `unknown` includes an unreadable pane and a bare shell prompt left after the agent exits, so both defer.
  The shared `bin/fm-composer-lib.sh` owns the content decision after each backend captures and structurally identifies its own composer row.
  It preserves idle bordered composers such as claude's `│ > … │` and bare agent glyphs as empty, but a bare shell glyph is unknown unless inside a genuine bordered composer box; see `docs/herdr-backend.md` "Composer-emptiness safety" for the complete contract.
  `pane_input_pending` remains the tested predicate for callers that only need to know whether real unsubmitted text is present, but it is insufficient for an injection-safety decision because it cannot distinguish `empty` from `unknown`.
  The shared classifier receives a candidate row only after the active backend performs its own capture and structural row recognition.
  tmux and herdr route raw styled candidate rows through the shared `fm_composer_strip_ghost` extractor, which removes dim/faint and dark-TRUECOLOR ghost/placeholder text before classification.
  They read the composer shape from a separately ANSI-stripped plain row because a dark TRUECOLOR border can be stripped with ghost content.
  `FM_COMPOSER_IDLE_RE` still overrides tmux empty-composer matching after shared ghost and border stripping, and `FM_BUSY_REGEX` overrides busy footers.

Either condition, or any composer verdict other than `empty`, defers the injection; the buffered escalation survives in `state/.subsuper-escalations` and is retried on the next housekeeping tick.
In afk mode the composer guard is belt-and-suspenders (no human is typing), but it protects against the race window between the captain returning and their message landing, a dead shell, and the daemon's own previous injection sitting unsent.

**Max-defer escape (the daemon must never silently wedge).**
If anything stays buffered past `FM_MAX_DEFER_SECS` (default 300), the daemon
attempts one normal flush, which still requires an idle pane and an affirmatively empty composer.
The alarm is defense in depth rather than a substitute for keeping every genuinely idle supported composer injectable.
If that submit cannot be confirmed, it raises a loud, rate-limited wedge alarm:
an ERROR in the daemon log, a durable
`state/.subsuper-inject-wedged` marker (surface it on the "while you were out"
catch-up if present), a tmux status-line flash when applicable, and a configurable backend-independent active alert.
`docs/wedge-alarm.md` owns the alert channel setup and verification record.
So a guard false-positive becomes a visible stall, never an unbounded silent no-op.

## Submit model

The digest is typed **once** (`send-keys -l` on tmux, `pane send-text` on
herdr - both literal, non-submitting sends), then submitted with Enter and
**verified** through the selected backend's submit primitive.
Enter is retried (Enter only, never a retype) until the backend confirms the
submit landed.
For tmux that confirmation is a cleared composer, using the same corrected,
border-aware detector as the composer guard.
For herdr, normal idle-baseline submits are confirmed by native agent-state showing a real turn started; the ANSI-aware composer classifier remains the affirmative-empty pre-injection guard and conservative fallback for non-idle or unreadable baselines.
A bordered-empty or ghost-only composer is recognized as empty where that backend uses composer confirmation, rather than mistaken for a swallowed Enter.
`fm-send.sh` uses the same primitive and exits non-zero
when a steer's Enter is positively swallowed, so firstmate learns an instruction
did not land instead of leaving it unsubmitted.

**Busy-queued Enter exception (tmux backend, opencode 1.18.4).**
`harness-adapters` owns the full contract; the daemon consequence is one line: while opencode is mid-turn, a queued Enter reads as `empty` (accepted, sends when the turn ends), never as a swallowed Enter, and the strict composer-clears-only-on-`empty` policy above still holds for the daemon.
The herdr backend observes the same opencode behavior but needs a separate fix; the gap is recorded in `docs/herdr-backend.md`.

## Classification policy

The daemon wraps `fm-watch.sh`, runs the watcher as a child, classifies each
wake reason in bash, and self-handles the routine majority without consuming a
firstmate turn.
Captain-relevant events, plus a bounded recheck of a declared external wait that remains idle, escalate to firstmate's context as one pre-read, single-line, batched digest.
The classification predicates (the captain-relevant verb set, declared-pause vocabulary, signal/stale tests, and fleet-scan) live in the shared `bin/fm-classify-lib.sh`, the same library the always-on watcher uses for its own triage when afk is off, so the two modes apply one identical policy.
While a daemon is actually live for this home it owns the watcher, so the watcher reverts to one-shot and lets the daemon do the triage - the two never run their triage at the same time.
In daemon-free away mode nothing would ever pick a one-shot wake up, so the watcher keeps its own normal triage and absorbs benign wakes exactly as with away mode off.

Classify each wake this way:

- `signal` with a terminal captain verb (`done:`, `needs-decision:`, `blocked:`, or `failed:`) -> escalate.
  A nonterminal progress verb remains nonterminal even when its prose contains a legacy free-text token such as `PR ready`, `checks green`, `ready in branch`, or `merged`; only a bare legacy line with such a token escalates.
  Other signals with no captain-relevant status -> self-handle.
- `signal` or `stale` for a declared `paused:` external wait -> self-handle and track the pause rather than a wedge.
  If it remains declared and idle past `FM_PAUSE_RESURFACE_SECS` (default 3600s), housekeeping sends one awaiting-external recheck and resets the pause window.
- `check` -> always escalate. Check scripts print only when firstmate should wake.
- `stale` with a terminal status or bare legacy captain-relevant line -> escalate.
  Nonterminal progress remains transient even when its prose contains a legacy free-text token or its seen-status marker already matches, so record a marker and self-handle.
  If the pane is still idle past `FM_STALE_ESCALATE_SECS` (default 240s), housekeeping escalates it as a possible wedge.
  This bounds wedge-detection latency to the threshold plus a tick: a delay, never a loss.
  Healthy crewmates are autonomous and do not wait on firstmate mid-task.
- `heartbeat` -> self-handle. The daemon runs its own cheap bash fleet scan
  every `FM_HEARTBEAT_SCAN_SECS` (default 300s) as the catch-all for a
  captain-relevant status line the per-wake classifier might miss.
  Every housekeeping cadence clock (catch-all scan, housekeeping tick, away-mode
  driver tick, context-stow check) starts at daemon start, so the first run of
  each is one full cadence after startup rather than on the first tick. The
  per-wake signal path stays the primary escalation owner in that window.
- Unknown reason, or any uncertainty -> escalate fail-safe.

Escalations are buffered up to `FM_ESCALATE_BATCH_SECS` (default 90s; 0 =
immediate) and flushed as one single-line digest prefixed with the current
operational prefix, carrying pre-read status summaries and a recommended action.
Embedded newlines are collapsed to a literal separator before injection.
The single-line format makes the submission unambiguous across harnesses, and
the operational prefix lets firstmate distinguish it from a real captain message.

The daemon's housekeeping also runs a firstmate own-context stow nudge: on the
`FM_CONTEXT_STOW_CHECK_SECS` cadence it reads firstmate's OWN live context and, on
the first crossing of the stow threshold, buffers one operational nudge to `/stow`
now (and `/compact` when the session cannot auto-compact) so knowledge is saved
before a context reset can lose it. It is gated on the daemon running, not on away
mode, because context fills in normal mode too, and it fails closed on any
unreadable or unsupported-harness count. `docs/configuration.md`'s
"Firstmate own-context stow threshold" section owns that contract in full,
including `config/context-stow-threshold` and the `FM_CONTEXT_STOW_*` knobs.

## Injection hardening

The single-line digest, the composer guard, and the verified type-once submit model with its max-defer escape are owned by the sections above; the independent protections are:

- **Marker strip** - `strip_injection_marker` removes the current operational
  prefix or legacy bare marker before classification or relay, so the digest
  text firstmate sees is clean.
- **Portable singleton lock** - the daemon uses the repo's portable lock helper
  (`fm-wake-lib.sh`) instead of `flock`, which is absent on macOS.
- **Dedupe across signal/stale/scan** - `classify_signal` and terminal `classify_stale` paths check the seen-status marker before escalating, so a captain-relevant status escalated by one path is not re-escalated by another in the same digest.
  The marker does not clear or suppress possible-wedge aging for a nonterminal progress line.
- **Auto-discovered supervisor pane** - the daemon resolves its own BACKEND
  (tmux vs herdr) and TARGET independently, mirroring
  `bin/fm-backend.sh`'s own runtime auto-detection. Backend: `FM_SUPERVISOR_BACKEND`
  override, then `$TMUX_PANE` set (tmux), then `$HERDR_ENV=1` with
  `$HERDR_PANE_ID` present (herdr), then a tmux fallback. Target:
  `FM_SUPERVISOR_TARGET` override (a tmux target or a herdr
  `"<session>:<pane-id>"` target), then `$TMUX_PANE`, then
  `"${HERDR_SESSION:-default}:${HERDR_PANE_ID}"` under herdr. When none of those
  identifies the pane, the daemon selects paneless delivery instead of injecting
  into the legacy `firstmate:0` guess ("Delivery channel" above). Both resolution
  sources and the selected delivery mode are logged at startup. Other runtime
  backends, including zellij, orca, and cmux, are not yet supported as
  supervisor backends; the daemon refuses loudly at startup instead of
  misapplying tmux primitives to a pane that isn't one
  (docs/herdr-backend.md "Away-mode daemon: herdr supervisor-pane support").

## Stale-artifact lifecycle

Treat `state/.subsuper-escalations`, its `.since` sidecar, `state/.subsuper-inject-wedged`, and the paneless outbox files as session-scoped delivery artifacts, not as the durable work record.
`bin/fm-afk-start.sh` owns the one list of those artifacts that fresh-entry clearing and the launcher's transactional rollback both use.
Always enter through `bin/fm-afk-launch.sh`, which clears prior-session artifacts only for a fresh entry and preserves the current session's buffer on refresh.
Always exit through `bin/fm-afk-launch.sh stop`, which keeps `state/.afk` present through the daemon's shutdown flush and clears it last.
`docs/herdr-backend.md` "Stale-artifact lifecycle fix" owns the mechanism and verification evidence.

## Reliability properties

These properties must hold:

- Nothing is lost. The durable queue plus `fm-wake-drain.sh` recover any missed
  or crashed injection.
- Wedge detection is bounded-latency, not lossy.
- Declared external waits are rechecked on a separate, bounded cadence rather than being mislabeled as wedges.
- The catch-all scan backs up the keyword classifier.
- The daemon preserves a single-instance portable lock, crash-loop backoff,
  a pane-gone guard, and a signal-trapped shutdown that flushes buffered
  escalations before exit.

`FM_INJECT_SKIP` (default `heartbeat`) force-self-handles matching kinds,
overriding classification.
Use it sparingly.
