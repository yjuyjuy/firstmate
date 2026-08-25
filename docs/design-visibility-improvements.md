# Watcher visibility-gap checks

This doc owns the mechanism, the backend/harness axis review, and the dated
verification evidence for the watcher visibility-gap checks in
`bin/fm-watch.sh` (the Gap-N series).
The original gap-series design narrative lives in the captain-private home
record `data/design-visibility-improvements/report.md`; this tracked doc is the
repo-side owner for everything that travels with the code.
`docs/configuration.md` owns the telemetry key list; each producing script's
header owns its exact mechanics.
Do not restate the full contract here that one of those owners states in full.

## Gap series

| Gap | Check | Code owner | Surfaces as |
|-----|-------|------------|-------------|
| 1 | fleet-wide account/quota producer | `fleet_quota_sweep` | passive telemetry, one `quota-axi --json` per slow-poll CHECK_INTERVAL, never wakes |
| 2 | per-pane 429/rate-limit anomaly | `quota_anomaly_scan` | `count_429`/`last_429_ts` telemetry; `check: quota-anomaly` on a rate |
| 3 | stale status-event vs current-state render | `bin/fm-crew-state.sh` + renderers | paired event/state/age surfacing |
| 4 | delivered-but-never-processed steer | `steer_stuck_check` | `composer_stuck` telemetry; steer-aware `stale:` wake |
| 5 | dead turn after a reactive 429 rotation | `dead_turn_check` | `resume_probe_ts` telemetry; one resume steer; `check: dead-turn <task>` |

## Gap 5 - dead-turn liveness tripwire

A lane that reactively rotates accounts on a 429 can have its in-flight turn
die during or after the rotation, with the harness never starting a new turn.
The pane stays present and may keep redrawing its footer (spinner, growing
elapsed timer, busy composer row), so the raw-hash stale loop never fires and
the lane looks healthy.
Telemetry already carries the 429 cue (`last_429_ts`, written by
`quota_anomaly_scan`, Gap-2); the reliable dead-turn signals are CONTENT-STALL
and the jcode terminal-dead markers.

### The lying busy predicate (root cause, supervision-miss-rootcause F4)

A dead jcode pane after a rotation reads busy forever: herdr reports
`agent_status=working` (the app believes its turn is still in flight), the
frozen `NNN…` composer row matches `BUSY_REGEX`, and the footer animates.
`window_is_busy` is therefore NEVER a liveness signal for this check: it is
never consulted for probe, escalate, or recovery, and a busy-by-native-state
pane with frozen content is never marked resolved.

### Content-stall observation (F1 seam)

`pane_content_hash` hashes the tail40 MINUS the animated footer rows
(`FM_WATCH_FOOTER_ROW_RE`: spinner chars, elapsed-timer rows, the `⏳`
composer/indicator rows, `·●·` rows), stripping only TRAILING rows that match
so content rows are never eaten.
The check persists each in-window poll's content hash in
`state/.dead-turn-content-<key>`; two consecutive identical hashes are a
content-stall.
The incident panes' content rows were byte-identical for 10 hours while the
footer redrew every poll; the content hash catches exactly that.

### Detection conditions

All of these must hold:

1. `last_429_ts` is recent, within `FM_DEAD_TURN_WINDOW` (default 900s, env-overridable).
2. Content-STALL across two polls (previous content hash == current content
   hash), OR a conclusive jcode terminal-dead marker in the tail
   (`fm_composer_tail_has_jcode_dead_marker`, owner
   `bin/fm-composer-lib.sh`: `Auto-retry limit reached` and
   `Already processing a message`; `Retryable stream error` alone is NOT
   decisive because jcode can legitimately retry and continue).
3. There has been NO status append to `state/<task>.status` since
   `last_429_ts` (status-file mtime compared against the 429 timestamp via
   the `stat_mtime` helper; an absent status file counts as no append).
4. The lane is not in a declared pause / captain-hold
   (`status_is_paused_or_captain_held`).

A secondmate window or a supervise=off pane is never probed: the secondmate's
own home supervises its lanes, a marked main-home steer would open a parent
pending-reply expectation, and recorded_windows already drops unsupervised
panes.

### State machine, never a probe loop

1. Each in-window poll observes the content hash (footer stripped) and
   persists it; a poll whose hash matches the previous poll's is a
   content-stall (the first poll after a restart or a fresh window only
   establishes the baseline and never probes).
2. First qualifying poll (above): send exactly ONE bounded automatic resume
   steer via `bin/fm-send.sh` (the `FM_DEAD_TURN_SEND_BIN` seam, which tests
   stub, mirrors `FM_STALE_NUDGE_BIN`), record `resume_probe_ts=` in
   telemetry, and persist the episode in `state/.dead-turn-probe-<key>`
   holding the `last_429_ts` probed for.
   `fm-send` stamps `last_steer_ts=` on confirmed delivery, so the probe's
   steer ts is also pre-recorded in Gap-4's `state/.steer-stuck-<key>` warned
   marker: Gap-4 would otherwise escalate the same steer as a stuck composer
   one poll later without the 429 context, and the dead-turn wake must be the
   single escalation for the probe steer.
   The suppression is fail-soft: an unreadable stamp skips it, and Gap-4 may
   also wake - a duplicate, never a missed lane.
3. Next poll, still content-stalled (or still showing the dead marker) and
   still no status append since the 429: escalate exactly ONCE as
   `check: dead-turn <task>` via `state/.dead-turn-escalated-<key>` using the
   same wake pattern as `quota_anomaly_scan` (`fm_wake_append check ...` +
   `wake`).
4. A send that cannot be confirmed (fm-send exits non-zero) records the
   episode's single probe marker AND the escalation marker, and escalates
   immediately with a delivery-FAILED reason: a failing sender must never
   swallow a stalled worker, and a failure never retries into a probe loop.
5. Recovery - a status append after the 429, or ADVANCING content (the
   content hash differs from the previous poll: the lane produced a new row,
   which is liveness even while the app still draws a busy footer), before or
   after the probe - clears the episode's active markers silently, sends
   nothing, and wakes nothing.
   It also records the episode as SPENT in `state/.dead-turn-resolved-<key>`,
   so a later idle poll inside the same window stays silent: the lane is
   healthy, not a new dead turn, and a resolved lane that idles again must
   never receive a second nudge.
   Only a genuinely new `last_429_ts` re-arms an episode.
   Busy-ness NEVER resolves an episode.
6. Window expiry (the 429 ages past `FM_DEAD_TURN_WINDOW`) drops all four
   tracking files (probe, escalated, resolved, content baseline) so a
   long-idle healthy pane with an old 429 never trips, and a later, genuinely
   new `last_429_ts` starts a fresh episode that may probe once again.

The window default is 900s because it is > 2x the default poll cadence
(POLL 300s), so a probe and its follow-up escalation both land inside it, it
is ~1.5x the slow-check cadence (CHECK_INTERVAL 600s), and it is the same
order as `FM_STEER_STUCK_WINDOW` (600s), the sibling fresh-concern window.
An old 429 (hours old) on a long-idle healthy pane never trips.

### Fail-soft rules

An absent or unreadable telemetry file, a missing meta, or a marker or
telemetry write failure surfaces nothing and never blocks the watcher loop.
A status-file stat failure counts as no append (the conservative direction for
a liveness tripwire).
The check reuses the per-window `tail40` the stale loop already captured and
adds ZERO backend captures to the loop.

## Axis review

Reviewed 2026-08-25 (re-reviewed after the supervision-miss-rootcause F4
correction) against the live integration surfaces. A cell is marked
not-applicable (NA) only after inspecting the axis and finding no behavior
difference that the check must handle.

### Runtime backends

| Backend | `window_is_busy` | pane-content hash (footer strip) | resume steer via fm-send | telemetry + status mtime | Axis verdict |
|---------|------------------|----------------------------------|--------------------------|--------------------------|--------------|
| tmux | NA for this check after inspection: `fm_backend_busy_state` reports unknown and the BUSY_REGEX fallback lies on frozen composer rows, so the dead-turn check never consults busy (F4) | BUSY_REGEX already scopes its footer scan to the last 6 non-blank lines; `pane_content_hash` strips the same footer area by pattern | `fm_backend_tmux_send_text_submit`, verified confirm-or-loud-fail submit; stamps `last_steer_ts` on confirmed delivery | state files, backend-independent | supported, unchanged path |
| herdr | NA for this check after inspection: native `agent_status=working` on a dead jcode pane is the app's prompt state, not stream liveness (the incident's lying predicate) | herdr captures the same tail40 shape; the strip is pattern-based, backend-independent | `fm_backend_herdr_send_text_submit`, verified submit | state files, backend-independent | supported; busy explicitly distrusted |
| zellij | NA for this check after inspection (see tmux) | pattern strip, backend-independent | `fm_backend_zellij_send_text_submit`, verified submit, internal content-diff, composer state unknown | state files, backend-independent | supported |
| orca | NA for this check after inspection (see tmux) | pattern strip, backend-independent | `fm_backend_orca_send_text_submit`, verified submit, Enter/C-c only (plain-text steer is Enter-only, so no Escape dependency) | state files, backend-independent | supported |
| cmux | NA for this check after inspection (see tmux) | pattern strip, backend-independent | `fm_backend_cmux_send_text_submit`, verified submit | state files, backend-independent | supported |

### Primary harnesses

| Harness | animated footer rows (stripped by `pane_content_hash`) | jcode dead-marker catalog | plain-text single-line steer | telemetry | Axis verdict |
|---------|---------------------------------------------------------|---------------------------|------------------------------|-----------|--------------|
| claude | covered by the spinner/timer/`⏳` catalog | NA after inspection: the catalog is jcode-specific (`bin/fm-composer-lib.sh`), verified against the jcode binary; claude has no such rows | separate text line + Enter, no slash command, no `$...` skill invocation | backend-independent | supported, NA for any harness-specific steer handling |
| codex | covered | NA after inspection (jcode-specific) | same | backend-independent | supported |
| opencode | covered | NA after inspection (jcode-specific) | same | backend-independent | supported |
| pi | covered | NA after inspection (jcode-specific) | same | backend-independent | supported |
| grok | covered | NA after inspection (jcode-specific) | same | backend-independent | supported |
| jcode | the incident footers (`⠋ thinking… 15m 2s · https`, `6… ⏳`) are exactly the stripped shapes | `Auto-retry limit reached` / `Already processing a message` are the conclusive terminal rows (F2); `Retryable stream error` alone is NOT decisive | same | backend-independent | supported; this is the incident harness the check targets |

### Other axes

| Axis | Verdict |
|------|---------|
| reactive account rotation (`orchestrator_rotate_on_tripwire`) | NA after inspection: the check only OBSERVES the 429 the rotation path already surfaces (`last_429_ts`), it never calls the orchestrator |
| composer/pending-input state (`fm_backend_composer_state`) | NA after inspection: the probe path relies on fm-send's own verified submit, not a separate pre-submit guard |
| busy predicates (`window_is_busy`, herdr native busy, BUSY_REGEX) | NA after inspection (F4): supervision-miss-rootcause proved all three lie on a dead jcode pane, so the check deliberately never consults busy for probe, escalate, or recovery |
| secondmate windows | skipped by contract: their own home supervises their lanes, and a marked main-home steer would open a parent pending-reply expectation |
| supervise=off panes | skipped by contract: recorded_windows drops them from every supervision path, and the check repeats the guard so the helper's contract stays single-place |
| OS stat flavor | handled by the existing `stat_mtime` helper (Darwin `-f %m`, Linux `-c %Y`), never a `-f || -c` fallback |

## Verification evidence

Dated 2026-08-25 (F4 rework evidence; the pre-F4 evidence is history in this
file's git log). Code under test: see the sha pin below; the evidence was
captured from exactly that tree.

`bin/fm-lint.sh` (shellcheck 0.11.0, the pinned version):

```
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
```

Exit status 0, no findings.

Colocated test `bash tests/fm-watch-dead-turn.test.sh`, run through
`bin/fm-heavy-run.sh --task watch-429-liveness`:

```
ok - the frozen-busy fixture reads busy, and dead_turn_check never consults window_is_busy
ok - the animated footer changes the raw hash while the content hash stays frozen
ok - a frozen-busy pane probes once: the dead turn is NOT marked resolved by busy
ok - the next poll escalates check: dead-turn exactly once via the durable wake queue
ok - no second probe after the escalation (the episode stays silent, never a probe loop)
ok - a genuinely new 429 episode starts fresh and probes once again
ok - recovery via advancing content clears the episode silently
ok - a recovered episode stays silent when the pane idles again
ok - a pane with advancing content is never probed, and stays silent when it later freezes
ok - recovery via a new status append clears the episode silently
ok - a lane with a status append since the 429 is never probed
ok - a declared pause or captain-hold is never probed and never alarmed
ok - an old 429 outside FM_DEAD_TURN_WINDOW never trips and expiry cleans the episode markers
ok - an unconfirmed resume steer escalates immediately and never retries into a probe loop
ok - the probe preserves sibling telemetry keys and pre-records Gap-4's warned marker
ok - a jcode terminal-dead marker probes and escalates without waiting for a baseline
ok - secondmate and supervise=off windows are never probed
ok - dead_turn_check adds zero backend captures and zero busy probes; the loop keeps its single capture
ok - fm-watch-dead-turn.test.sh: all checks passed
```

Sibling watcher suites re-run on the same tree, all green:
`fm-composer-lib.test.sh`, `fm-watch-steer-stuck.test.sh`,
`fm-watch-quota-anomaly.test.sh`, `fm-watch-tripwire-rotation.test.sh`,
`fm-watch-fleet-quota.test.sh` (each ends `all checks passed`).

Known pre-existing flake, not a regression: `fm-watch-triage.test.sh`
reproduced `not ok - beacon aged 3s past the 2s grace during the terminal
sleep` on the PRISTINE base commit `6d1f6c3` (detached checkout of the same
worktree, stash in and out) under the same loaded host; the dead-turn,
composer-lib, and watcher sibling suites pass with the F4 changes applied.

Loop-capture and busy-call guard (asserted inside the test, output above):
the stale loop keeps exactly one
`fm_backend_capture "$(window_backend ..."`, and `dead_turn_check` performs
zero captures and zero `window_is_busy` calls on a live frozen-busy fixture.