# ADR 0001: Heavy-run admission refuses by default, through a lease wrapper

Date: 2026-08-05.
Status: accepted.
Context owner for the mechanism: [`bin/fm-heavy-run.sh`](../../bin/fm-heavy-run.sh)'s header.
Config owner: [`docs/configuration.md`](../configuration.md#heavy-run-serialization-configheavy-run-slots).

## Context

A fleet of crewmates shares one host.
The heavy cost is not a crewmate existing, it is a crewmate running a suite, a build, or a lint sweep: each of those is multiple gigabytes and transient.
The failure mode that motivated this control is a burst: several crewmates parked on captain decisions get unblocked at once, every one starts a suite in the same instant, and the host thrashes before the resource monitor takes its next reading.
Measured on a 10-core / 16 GB host, 13 concurrent runs drove load to 104 with swap at 83 percent, the unit suite went non-deterministic, and the watcher wedged.

The resource monitor cannot catch this, because a reading is momentary and advisory while the burst needs a hard, stateful count held across the transition.
So heavy runs are serialized behind a concurrency ceiling, and the question this ADR settles is what happens to a run that arrives when no slot is free.

Two shapes were available:

- A long-running worker daemon that owns each child process and relays its output and exit status back over a transport.
- A lease wrapper where the requesting process itself takes a lease, runs its command in its own foreground, and drops the lease on exit.

And two default postures for a full queue:

- Block: the requester waits in a FIFO until a slot frees.
- Refuse: the requester exits with a prescriptive non-zero status and retries later, blocking only when it explicitly opts in with `--max-wait`.

## Decision

The mechanism is a lease wrapper, not a daemon.
The requesting crewmate's own process is the worker: `fm-heavy-run.sh --task <id> -- <command>`.
The command runs unchanged, its output streams straight through, and the wrapper exits with the command's own status.

The default posture is refuse, not block.
When no slot is free the wrapper exits non-zero with a message naming the current holders and telling the crewmate to append `paused: awaiting test slot` and retry, or do non-test work in the meantime.
A crewmate that genuinely wants to block opts in with `--max-wait <secs>`, and even then the wait is bounded and refuses rather than running unserialized when it elapses.

## Consequences

- No component to keep alive, supervise, or recover after a reboot, and no second protocol to relay output and status: they are native to the requester's own shell.
- Release is structural, not disciplinary. A lease drops when the requester's process exits, including on an unclean death, because each admission pass reaps records whose process is gone or whose PID was reused. The wrapper never signals a process it did not start, which matters on a fleet where a blanket process kill has taken out live crewmate agents before.
- Refuse-by-default suits a harness where a long in-command block risks a shell timeout that fails worse than a clean refusal. A crewmate is never left hanging: it is told exactly what happened and what to do.
- The cost is that a refused crewmate must retry rather than being handed the slot the instant one frees. ADR 0003's release nudge softens that by waking a parked waiter, but the waiter still re-acquires through ordinary admission. Firstmate is the nudger, never the granter, and there is no FIFO ticket queue in this version.

## Alternatives rejected

- A daemon worker: rejected for the supervision, recovery, and relay-protocol cost, and for its own wedge risk when the worker dies holding a run.
- Block-by-default: rejected because a long in-command block fails badly under harness shell timeouts, and because a burst of unblocked crewmates all blocking at once is harder to observe than a burst all refusing loudly.
