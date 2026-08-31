Mode: jcode background-notify supervision (async wake), with a foreground-checkpoint fallback.

jcode's background task defaults to a passive `wake: false` delivery, but the `bg` tool can flip a tracked task to `wake: true`, and a `wake: true` background task's completion DOES re-drive an idle model with its completion block across a turn boundary.
See [`../jcode-wake-adapter.md`](../jcode-wake-adapter.md) for the cross-turn verification record (jcode server 0.64.2, 2026-08-05).
The one jcode-specific rule is that arming the wake is TWO paired model actions: launch the arm as a background task, then immediately set `wake: true` on that exact task id. A forgotten wake set silently reverts to `wake: false` and leaves supervision blind, so the two steps are never separated.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`, or with `bin/fm-wake-brief.sh` to get that same drain plus each woken task's status tail, current state, metadata, one host reading, and an endpoint sweep in one call.
   To fold that drain into the arm itself as one call, launch `bin/fm-watch-arm.sh --drain` as the background task in step 3a: it drains first, then arms exactly one watcher, so a wake landing inside the arm window does not become a drain/arm/retry loop.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. First cycle: follow the emitted First-cycle directive above, which accounts for a live present-mode daemon. When no daemon owns the watcher, that directive expands to the two paired actions:
   a. Launch `bin/fm-watch-arm.sh` as its own jcode `Bash` task with `run_in_background: true`, never bundled with another command and never with a shell `&`.
   b. Immediately call the `bg` tool with `action="subscribe"`, that task id, and `wake: true`, so the task's completion will re-drive this session.
   When a live present-mode daemon owns the watcher, the directive instead says NOT to launch `bin/fm-watch-arm.sh`: drain the wake queue, end the turn, and rely on the daemon's pane-wake.
4. Trust only the arm's one-line status: `watcher: started ...` or `watcher: attached ...` means one live cycle exists; on attach the background task follows verified identity-matched successors instead of exiting when the first cycle ends.
5. After a successful start or attach status with `wake: true` set, end the turn. The armed background task is the live wait until it completes with an actionable wake or failure.
6. Ordinary wake: when the `wake: true` background task completes with `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, then start exactly one fresh armed cycle (the same two paired actions) before running other fleet commands to handle the wake.
7. Benign tick close (only with `FM_WATCH_ABSORB_TICK=1`, off by default): a `tick:` completion line is proof of life for an absorbed wake, not an actionable wake and not a failure; reply with the single literal word `tick`, re-arm one fresh cycle (both paired actions), and never run watcher repair.
   See [`watcher-continuity.md`](../watcher-continuity.md) for the mechanism.
8. Failure or missing cycle only: treat any `watcher: FAILED ...` result as an alarm; drain queued wakes, inspect the failure, then start a fresh armed cycle.
9. Do not invent a wake from an attach-status line alone; drain the queue and act only on real wake records or a real watcher reason line.

Fallback: the bounded foreground checkpoint.
When the two-step async arm is not appropriate (for example a single-shot supervision check, or any situation where ending the turn on an armed background task is undesirable), run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"` instead.
It holds a foreground wait that returns control on the watcher's actionable wake, or prints `checkpoint:` and exits 124 on a quiet checkpoint; on either outcome drain queued wakes, process any queued user message now visible to jcode, then take the next checkpoint.
The checkpoint depends on no background-completion wake, so it is always safe, but because the model never idles it does nothing for a turn that genuinely ends; the async arm above is what keeps supervision resident across an ended turn.

Never hold the watcher with a plain jcode `Bash run_in_background` task whose delivery is left at the default `wake: false`: that completes with a passive notification and does not wake an idle model, which is the exact non-wake that recurred before this adapter. The `wake: true` set in step 3b is mandatory, not optional.
