# Account-switch orchestrator (firstmate caller)

Firstmate is a thin CALLER of the quota-axi account-switch orchestrator (ADR 0031, Phase 1).
The decision brain (`quota-axi decide`) and the single fenced mutation verb (`quota-axi switch`) live in quota-axi and own all account-selection and actuation logic.
Firstmate never reimplements either; it builds the pure inputs those verbs consume, invokes them, and reads back their versioned JSON.

`bin/fm-account-orchestrator.sh` is firstmate's single caller of the orchestrator.
Its header owns the exact subcommands, flags, environment overrides, and fail-soft mechanics.
This document owns the integration shape and the tripwire error catalog.

## Where firstmate calls the orchestrator

There are exactly two integration points, both fail-soft.

1. Spawn (`bin/fm-spawn.sh`).
   When a jcode worker is launched on a `claude-*` model, the spawn consults `quota-axi decide` through `fm-account-orchestrator.sh resolve-account` and pins the chosen non-exhausted Claude account through jcode's own per-session `/account claude switch <label>` slash command, applied in `jcode_post_launch_delivery` before the model, effort, and brief.
   A worker is therefore never launched onto an account `decide` reports exhausted (reserve floor crossed, tripwire in the future, priming-gated).
   Scope is jcode workers on `claude-*` models only, because that is the route that draws down the shared Claude OAuth window; a non-jcode or non-Claude spawn is unchanged.

2. Watcher tripwire wake (`bin/fm-watch.sh`).
   On a live limit-error (tripwire) wake for a jcode worker, the watcher calls `fm-account-orchestrator.sh rotate`, which invokes `quota-axi switch`.
   `switch` re-runs `decide` internally, folds the recorded tripwires, actuates the jcode live-session control surface itself, and records the durable tripwire so the exhausted account stays out until its recovery deadline.
   Firstmate does not itself touch jcode sessions or write tripwire state; it only invokes `switch`.
   The rotation is idempotent per task within a cooldown window (`FM_ORCH_ROTATE_COOLDOWN`, default one hour) and runs in addition to surfacing the blocking status to the captain, never instead of it.

The manual `bin/fm-switch-account.sh` broadcast is the documented fallback for when the orchestrator is unavailable, the installed quota-axi lacks the merged verbs, or the captain wants to force a specific account by hand.
It is not deleted; deletion is a later confidence step and a captain call.

## Paced fleet re-warm after a switch

After the fleet moves to a new account its prompt caches are cold, so each lane's first turn re-sends its full working context (about 120K to 180K tokens per lane).
Starting every lane's first turn at the same instant sends that whole cold-cache burst inside one minute.
On 2026-08-25 a burst of five simultaneous cold-cache resume steers tripped the `claude-1` account's per-minute rate limit and produced 147 HTTP 429 responses in about two minutes.

`bin/fm-resume-fleet.sh` re-warms the fleet without that burst.
It resumes the home's recorded lanes one at a time, in a deliberate order, and paces the starts so at most one large cold-cache request begins per minute.
Its header owns the exact mechanics; the integration-level contract is:

- Lane set: the supervised ship and scout lanes recorded in this home's `state/<id>.meta`, read through the same `fm_backend_of_meta` / `fm_backend_target_of_meta` helpers every other `fm-*` script uses.
  A service sidecar meta with no backend target, a `kind=secondmate` lane (idle by contract), and a `supervise=off` pane are skipped, never treated as errors.
- Order: an explicit `--priority <id>` lane first, then any lane whose meta records a truthy `priority=`, then the rest in stable id order.
- Verify before advancing: after sending a lane its resume steer, the script polls for positive evidence the turn actually started, either a backend busy or working indicator or a fresh append to that lane's status file, before it moves to the next lane.
- Pacing: a jittered gap in the 60 to 90 second window (randomized per gap, not a fixed sleep) is held before a send only when a prior send actually landed a turn, so exactly one gap sits between each pair of consecutive real cold-cache starts and a swallowed send can never collapse the gap between two real starts.
- Escalation, never a silent drop: a lane that does not start a turn within the bounded verify window gets a clearly attributed `blocked:` line appended to its status file and is listed as failed in the run summary, while the remaining lanes still run, so one wedged lane never blocks the whole re-warm.
- Idempotent: a lane already mid-turn is detected and skipped rather than poked a second time, so the script is safe to re-run.

`fm-switch-account.sh --resume` chains into `fm-resume-fleet.sh` after its own switch confirmations complete, so a manual fleet account switch re-warms the fleet on the new account with the same paced stagger in one command.
The flag changes nothing when absent, and the re-warm's advisory exit never fails the account switch, which has already succeeded by the time the re-warm runs.
The routine watcher-driven `rotate` path actuates live sessions through `quota-axi switch` and does not itself chain this re-warm today; the paced re-warm is the manual-switch and deliberate-re-warm path.

## Versioned contracts firstmate pins to

Firstmate pins to the merged quota-axi JSON contracts and never re-derives them:

- `decide`'s `DecisionResponse` (`schemaVersion` 1): `decisions[]` each with `scope`, `action` (`keep`/`switch`/`hold`), optional `chosenAccount`, and `reasons[]`.
  See `projects/quota-axi/src/orchestrator/decide.ts`.
- `switch`'s `SwitchResponse` (`schemaVersion` 1): `outcomes[]` per decision scope.
  See `projects/quota-axi/src/orchestrator/switch.ts`.

The tripwire store path is used consistently between the decide-at-spawn read (folded into observations) and the switch-on-tripwire write (switch owns the write), so an exhausted account actually stays out.
It defaults to quota-axi's own store (`QUOTA_AXI_TRIPWIRES`, else `~/.cache/quota-axi/tripwires.json`) and is overridable with `FM_ORCH_TRIPWIRES`.

## Tripwire error catalog

This section is the single owner of the jcode/Claude limit-error strings the watcher recognizes as "account exhausted".
The recognizer lives in `bin/fm-account-orchestrator.sh` (`is_tripwire_error`, `recognize-tripwire`); this catalog documents its provenance and the exclusions.

The catalog is derived from the REAL error strings jcode's Anthropic runtime emits and classifies, observed in the merged jcode clone, not invented:

- `crates/jcode-provider-anthropic-runtime/src/lib.rs`, `is_retryable_error` and `is_fable_scoped_limit_error`, match `rate limit`/`rate_limit`, `usage limit`/`usage_limit`, `429 too many requests`, and a JSON body `{"type":"rate_limit_error",...}`.
- `crates/jcode-provider-anthropic-runtime/src/anthropic_tests.rs` asserts the live shapes: `429 {"type":"rate_limit_error","message":"You have reached your weekly Fable limit"}`, `usage limit reached for the 7-day model window`, and `global 5-hour rate limit reached`.

Recognized "account exhausted" markers (case-insensitive):

- `rate limit` / `rate_limit` (including the `{"type":"rate_limit_error",...}` body).
- `usage limit` / `usage_limit`.
- `429 too many requests`.
- `reached your ... limit` (for example `You have reached your weekly Fable limit`).
- `limit reached` (for example `usage limit reached for the 7-day model window`).

Critical exclusions, which must NOT trip a rotation:

- `overloaded` / `overloaded_error`.
  This is a transient server fault jcode retries, not account exhaustion; `anthropic_tests.rs` asserts `is_fable_scoped_limit_error` is false for `429 overloaded_error: service temporarily overloaded`.
- 5xx server errors (`500 internal server error`, `502 bad gateway`, `503 service unavailable`, `504 gateway timeout`).
- Network drops (`connection reset`, and the rest of the network-marker vocabulary jcode's `network_retry.rs` owns).

Matching a transient fault would rotate the whole fleet off a healthy account on a blip, so the recognizer is deliberately narrow: the smallest safe set that covers the observed real limit errors and nothing transient.

### Relationship to the status-line auth-exhaustion catalog

`bin/fm-classify-lib.sh` owns a separate catalog, `FM_CLASSIFY_AUTH_EXHAUSTION_RE`, that classifies a WORKER'S OWN self-report (a `blocked:`/`paused:` status note carrying "usage limit", "quota", "session limit", etc.).
This orchestrator catalog classifies a RAW provider error string.
The watcher's `status_is_tripwire` test accepts EITHER: the worker's self-report vocabulary (through `status_is_auth_exhaustion_pause`) or the raw-provider-error recognizer (through `recognize-tripwire`), so either phrasing trips a rotation.
Keep the two catalogs aligned but distinct.

### Known gap

The catalog above is derived from the merged jcode source and its committed tests, not from a live limit error observed in production against a firstmate fleet.
The exact wire text a live Anthropic 5-hour or weekly limit surfaces through jcode's session pane may carry additional wording; the recognizer covers the structural markers those errors are built from (the `rate_limit`/`usage limit`/`429`/`reached your ... limit` families), which is the smallest safe recognizer rather than a broad guess.
When a real live limit error is observed, record its exact string here and widen the recognizer only if a structural marker was missed.

## Installed-CLI note

The installed `quota-axi` at `/usr/local/lib/node_modules/quota-axi` may still be the OLD upstream (observed v0.1.16) WITHOUT the `decide`/`switch` verbs.
`projects/quota-axi` is the delivery clone with the merged verbs but is not built into an installed binary.
`fm-account-orchestrator.sh` resolves the quota-axi binary the same fail-soft way `fm-dispatch-select.sh` does (`FM_DISPATCH_QUOTA_AXI` override) and probes the top-level `--help` command list for `decide` and `switch` before invoking them, because the old CLI accepts `<verb> --help` and silently routes it to the top-level quota help with exit 0.
When the merged verbs are absent, `resolve-account` keeps the current account and `rotate` declines, so both integration points degrade cleanly to today's behavior and the manual fallback.
A live repoint of the installed CLI to the merged build is a separate captain step.
