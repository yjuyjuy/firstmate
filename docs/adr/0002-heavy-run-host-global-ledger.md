# ADR 0002: The heavy-run ledger lives at a host-global path, outside home isolation

Date: 2026-08-05.
Status: accepted.
Context owner for the mechanism: [`bin/fm-heavy-run.sh`](../../bin/fm-heavy-run.sh)'s header.
Config owner: [`docs/configuration.md`](../configuration.md#heavy-run-serialization-configheavy-run-slots).
Builds on: [ADR 0001](0001-heavy-run-refuse-by-default-admission.md).

## Context

Firstmate keeps each operational home isolated.
A home has its own `state/`, `config/`, `data/`, and `projects/`, selected by `FM_HOME`, and the strong default everywhere in the fleet is that a home never reads or writes another home's state.
A running fleet is a primary home plus one or more secondmate homes, and those homes frequently share one physical host.

The heavy-run cap protects the host, not the home.
Its whole purpose is to bound how many heavy runs execute on the machine at one instant.
The first landed version of the lease queue lived under a home's own `state/heavy-runs/`, which means each home enforced its own independent count of N slots.
On a host running a primary and two secondmate homes at N = 2, that is up to 6 heavy runs at once - three times the intended ceiling.
Per-home slots multiply across homes and defeat the control precisely when the fleet is busiest.

## Decision

The default ledger lives at a fixed host-global path outside any home: `${TMPDIR:-/tmp}/fm-heavy-runs-<uid>`, one directory per operating user.
Every home's heavy runs register in that one ledger and share one running count, so the ceiling is a property of the machine as the design always intended.

Two supporting decisions keep this from eroding home isolation any further than necessary:

- Each lease record carries a `home=` attribution field (the run's `FM_HOME`) alongside its task id, so `--status` and firstmate can see which home each shared-ledger run belongs to. Attribution is read-only reporting; it grants no home authority over another home's record beyond the identity-checked reap that already governs every record.
- The ceiling VALUE is resolved from one authoritative config so the homes sharing the ledger also share one cap. `FM_HEAVY_SLOTS_FILE` points at the primary home's `config/heavy-run-slots`; when it is unset or unreadable the resolver falls back to this home's own `config/heavy-run-slots`, then to the safe floor of 1.

The per-user scoping (`-<uid>`) means a shared host with more than one operator does not cross-contaminate, and a world-writable `/tmp` cannot be used by another user to hijack this user's queue directory.
`FM_HEAVY_RUN_DIR` still overrides the default path: it is the test isolation seam, and the way to deliberately scope a queue to something other than the whole host.

## Consequences

- The cap once again means what it says: N heavy runs on the machine, not N per home.
- This is a deliberate, contained exception to home isolation. It is contained because the ledger holds only lease records, never a home's real state, and because attribution is reporting rather than authority. It is deliberate because the resource being protected is genuinely the host, which no single home owns.
- The reap contract is unchanged and still the only reaping action: a record whose process is gone or whose PID was reused is removed, and no process is ever signalled. That contract already tolerated records from arbitrary processes, so it needs nothing added to tolerate records from sibling homes.
- A misconfigured `FM_HEAVY_SLOTS_FILE` (pointing at a missing or unreadable file) does not fail the run: it falls back to the local config and then to 1, the safest value, matching the malformed-ceiling posture in ADR 0001.

## Alternatives rejected

- Keep the queue per-home and tell each home to set the same ceiling: rejected because it still multiplies the running count by the number of homes, and because a shared-count invariant enforced only by everyone independently configuring the same number is invisible the moment one home is misconfigured.
- Move agents themselves onto one shared home: rejected as a far larger change to the supervision fabric to solve a problem that a shared ledger solves directly.
