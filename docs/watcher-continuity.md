# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Watcher-side exit contract

One-shot means an ACTIONABLE reason closes the cycle, not that any non-actionable outcome does.
`bin/fm-watch.sh` ends a cycle for exactly two reasons: an actionable wake (it queues a reason line and exits zero) or a real internal error (it prints a loud message and exits nonzero).
Absorbing a benign wake must never end the cycle; the loop continues so the single live supervision cycle is preserved.
The distinction matters most for a best-effort side effect that fails: a dedupe-marker write, a log append, or any optimization that is not itself the surfacing of a wake.
While a wake is being absorbed, such a failure surfaces nothing, so it is logged and the loop continues.
After an actionable wake is already durably queued, the surface is guaranteed, so a later side-effect failure still surfaces the reason rather than exiting.
Only a failure that would actually lose a wake (the durable enqueue itself failing) is the internal-error exit, and it announces `watcher: FAILED` so it is distinguishable from a benign continue.
The event fast-path (`handle_push_transition`, the herdr push escalation) follows this rule: its declared-pause absorb continues on a failed dedupe commit, its actionable branch still wakes the supervisor on a failed post-enqueue commit because the record is already queued, and only a failed enqueue exits loudly.
`tests/fm-supervision-events.test.sh` pins all three cases; `tests/fm-watch-triage.test.sh` pins that the poll loop keeps the liveness beacon fresh while absorbing.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude retains its native tracked background-task completion path.
Its new PreToolUse continuity gate allows wake drain, the `bin/fm-wake-brief.sh` batch of that same drain plus read-only reads, arm recovery, and independently fail-closed teardown, but refuses other fleet commands while tasks are in flight and no identity-matched live watcher holds the home lock.
Allowing an ordinary literal teardown prevents a terminal wake from creating a recovery circle: forced or dynamically constructed teardown remains blocked, ordinary teardown itself still refuses dirty, unlanded, incomplete-scout, and unresolved-decision cases, and the turn-end guard continues to require supervision for any tasks left in flight.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

The existing turn-end guard implementation and adapters are unchanged.
They remain the final backstop rather than the normal continuity mechanism.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.
An attached arm follows verified identity-matched successors and reports the same typed failure if that chain ends without one.
An attached arm also COMPLETES (exit zero, wake-shaped) the instant its followed watcher enqueues a new durable wake, so a completion-wake harness re-drives the idle model instead of staying deaf while the watcher cycles under it. It watches the monotonic wake-queue sequence (`fm_wake_queue_seq`, which `bin/fm-wake-drain.sh` never resets) rather than queue content, so the signal is drain-immune and the worst case is one redundant wake-drive, never a missed one.

`bin/fm-watch-arm.sh --converge` collapses a multi-watcher/arm-loop tangle for THIS home when `--restart` cannot (it can only stop the single lock-recorded pid, so an orphan arm-loop immediately re-tangles). It enumerates every this-home watcher and arm-loop by absolute-path cmdline match through `bin/fm-watch-scope-lib.sh`, kills the arm-loops first (the re-attach engines), then surplus watchers, keeps one healthy survivor when present, and falls through to arm exactly one owner. Like `--restart` it signals only absolute-path-matched this-home pids, never a cross-home `pkill -f`, and it is a manual/agent repair wired into no automatic path.

`bin/fm-watch-arm.sh --drain` folds the mandatory pre-arm wake drain into the arm invocation so one logical supervision step is a single call rather than a drain, an arm, and a forced re-arm each time a wake lands inside the arm's confirmation window on a busy fleet.
It shells out to `bin/fm-wake-drain.sh` (the single owner of the drain and of the liveness assertion it makes), prints the drained records under a `=== WAKE QUEUE (drained) ===` header, then runs the unchanged arm or `--restart` logic, which still leaves exactly one live watcher.
A drain failure is surfaced loudly but never aborts the arm, because an un-armed turn is the more dangerous outcome.
`--drain` composes with `--restart` and does not relax the continuity or turn-end guard: a home with tasks in flight and no live watcher still fails the turn-end guard, and once `--drain` arms a watcher that guard passes.

A started child may instead close with a `tick:` line, the env-gated proof-of-life exit described under [Absorbed-wake proof-of-life tick](#absorbed-wake-proof-of-life-tick).
The arm layer classifies that close as a benign completion: it prints the line, records `reason=tick` in the cycle ledger, and returns success, distinct from both an actionable wake and the empty-cycle failure.
A tick only ever reaches the session through the owning arm that captured the child's output; an arm merely attached to another home's watcher cannot read that output and just follows the cycle boundary as usual.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The beacon grace itself is unchanged by this contract; `docs/configuration.md` owns its default (`FM_GUARD_GRACE`, 900 seconds).
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Absorbed-wake proof-of-life tick

By default the watcher absorbs a benign wake silently: it advances the wake's suppressor, logs one line to `state/.watch-triage.log`, and keeps blocking without exiting.
From the supervising session's view an absorbed wake and a dead watcher are then indistinguishable, because both produce no cycle close.

`FM_WATCH_ABSORB_TICK` makes that liveness provable, and ships default off.
`docs/configuration.md` owns the knob's default and precedence; this section owns the mechanism.
When it is unset or any value other than `1`, behavior is byte-identical to today.
When it is `1`, a benign-absorbed wake ends the cycle with a distinguishable `tick: <note>` reason line and a zero exit instead of absorbing silently.

A tick is deliberately cheap and safe:

- It enqueues no durable wake record, so `bin/fm-wake-drain.sh` finds nothing, and neither the continuity guard nor the turn-end guard sees any actionable work.
  A tick ends the cycle, but it fires only while work is under way, which is exactly the state in which the turn-end guard already requires a healthy watcher and forces a re-arm, so no guard needs to know about the knob and none was changed.
  A signal presupposes a task, and the absorbed-heartbeat site gates on the same in-flight count the guards use (`fm_supervision_status`), so the watcher and the guards cannot disagree about what "work under way" means.
  With nothing in flight the watcher keeps absorbing silently and never exits, self-sustaining exactly as it did before this knob existed.
- `bin/fm-watch-arm.sh` classifies the `tick:` close as a benign completion, separate from an actionable wake (`signal:`/`stale:`/`check:`/`heartbeat`) and from a failure (nonzero exit), so a live-but-quiet watcher never reads as the empty-cycle failure.
- It fires at most once per absorbed-wake event, never once per poll.
  Only two absorb points emit it, and both first advance their suppression state so the same event cannot re-fire: a benign signal whose `.seen-*` signature is written, and an absorbed heartbeat whose schedule and exponential backoff are advanced.
  Per-poll re-evaluations of an unchanged or churning stale pane deliberately do not tick, so a static or redrawing fleet cannot storm.

On a tick-enabled home the standing convention is a single literal `tick` reply: the session wakes on the proof-of-life close, sees the tick, answers `tick`, and re-arms the watcher exactly as it would after any cycle close.
The heartbeat's backoff bounds the quiet-fleet cadence (base `FM_HEARTBEAT`, doubling to `FM_HEARTBEAT_MAX`), so a quiet-but-supervised fleet ticks on that lengthening interval rather than continuously.
Verified for the Claude native tracked-background path; the Pi, OpenCode, Codex, and Grok adapters are inert while the knob is off.
The Pi extension and the OpenCode plugin classify a clean tick-only close as a third benign category of their own, mirroring the arm layer's precedence (an actionable line always wins), so they re-arm and deliver the tick text instead of reporting a cycle failure; a clean close with no reason line at all still takes the typed empty-cycle failure path.
Both deliver a tick under its own minimal prompt, which states that nothing is queued, orders no wake drain, and asks only for the single literal `tick` reply; OpenCode's streaming observer classifies a tick the same way its close handler does, so a streamed tick counts as a ready successor rather than disagreeing with the close.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops, then simulates actionable, tick-only, and empty child closes against the actual Pi and OpenCode close handlers, proving a tick-only close is delivered as a benign completion with continuity intact rather than as a cycle failure, that its prompt is the minimal no-drain tick form in both adapters, and that OpenCode's streaming observer accepts a tick-only successor as ready, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, the typed self-eviction failure, bounded and successor-linked lifecycle rows, a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination, and the arm layer's tick classification: a clean tick-only close returns success, prints the tick line, and is recorded as `reason=tick`, while a clean close with no reason line at all still takes the typed empty-cycle failure path with the knob on.
`tests/fm-watch-triage.test.sh` covers the watcher side of the proof-of-life tick: with `FM_WATCH_ABSORB_TICK` unset a benign-absorbed wake stays silent and blocking, with the knob on a benign signal and a no-change heartbeat each end the cycle with exactly one `tick:` line and no durable wake record while the heartbeat still backs off its cadence, an idle home with nothing under way never ticks, and an actionable wake is still surfaced and queued rather than ticked.
`tests/fm-continuity-pretool-check.test.sh` proves the Claude gate rejects only non-recovery fleet execution in the precise unhealthy state and preserves the existing Stop registration.

## Sanitized live evidence, 2026-07-17

All five harnesses ran against git-initialized scratch projects and isolated `FM_HOME` state.
Existing harness-managed credentials remained in place, no credential bytes were copied into a fixture or transcript, and no account was created.
Pi used the existing shared Pi auth store with the explicit `openai-codex/gpt-5.6-sol` provider/model pin and low thinking.
Each run used the smallest prompt needed to exercise the harness-native path.

Harness versions:

```text
Claude Code 2.1.214
codex-cli 0.144.4
OpenCode 1.17.18
Pi 0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]
```

Claude ran an arm fixture through its native tracked background option, observed background completion, allowed the wake drain, and refused the next unrelated fleet command before its body executed.
The captured system message exactly named `[watcher-continuity]`, `bin/fm-wake-drain.sh`, tracked Claude re-arm through `bin/fm-watch-arm.sh`, and the blocked `fm-crew-state.sh` command.
Command: `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-continuity-live-e2e.test.sh`.
Observed result: `ok - Claude 2.1.214 (Claude Code) live E2E refused only the post-completion fleet command with exact re-arm guidance`.

Codex ran the real one-second foreground watcher checkpoint and returned `checkpoint: no actionable wake within 1s` without switching to the arm wrapper.
Command: `FM_CODEX_LIVE_E2E=1 tests/fm-codex-continuity-live-e2e.test.sh`.
Observed result: `ok - codex-cli 0.144.4 live E2E preserved the one-second foreground checkpoint path`.

OpenCode ran its persistent TUI plugin, established the first watcher from `session.idle`, received an actionable close, and ledger-linked a live successor before the model handled the wake.
The model executed no watcher-arm command and the turn-end backstop did not fire.
Command: `FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh`.
Observed result: `ok - OpenCode 1.17.18 live E2E auto-started one successor before prompt handling without a model re-arm`.

Pi loaded the tracked extensions in its interactive TUI, called `fm_watch_arm_pi` once, received an actionable close, and ledger-linked a successor before the handling turn ended.
The turn-end backstop did not fire, and `/quit` removed both the watcher and arm child.
Command: `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh`.
Observed result: `ok - Pi 0.80.10 live E2E used shared Codex auth, auto-started one successor before turn end, and cleaned up`.

Grok ran the real arm wrapper through `run_terminal_command` with its tracked background option, surfaced its native task-completion notification after the actionable close, and recorded `reason=actionable-signal` in the cycle ledger.
No shell ampersand was used.
Command: `FM_GROK_LIVE_E2E=1 tests/fm-grok-continuity-live-e2e.test.sh`.
Observed result: `ok - grok 0.2.103 (89c3d36fb6f1) [stable] live E2E preserved tracked background completion and shared ledger classification`.

The goal is continuity with fewer supervision tokens and no Pi/OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed; lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
