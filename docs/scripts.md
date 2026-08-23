# The bin/ toolbelt

The first mate drives these; interactive entrypoints work by hand too, while `*-lib.sh` files are sourced helpers.
Each row is one purpose clause only: the script's own header comment is the authoritative description of its behavior, flags, and contracts, so read the header before first use.
If you have changed away from the firstmate home in an interactive shell, invoke these scripts by absolute path through the repo's `bin/` directory; the scripts self-locate internally after they start.
The shared no-mistakes gate refusal for fleet lifecycle entrypoints is summarized in [architecture.md](architecture.md#no-mistakes-gate-authority-boundary), while `docs/sessionstart-nudge.md` covers the silent hook-nudge use; `fm-gate-refuse-lib.sh`'s header owns its exact contract.

| Script                   | Purpose                                                                              |
| ------------------------ | ------------------------------------------------------------------------------------ |
| `fm-session-start.sh`    | Compose lock, bootstrap, and wake drain into the single ordered session-start digest |
| `fm-sessionstart-nudge.sh` | Print the native session-start hook nudge when the primary has not already run the digest |
| `fm-operational-input.sh` | Construct and parse the canonical cross-language operational-input protocol |
| `fm-bootstrap.sh`        | Detect toolchain and fleet problems, run the locked session-start sweeps, and install approved tools |
| `fm-fleet-sync.sh`       | Refresh project clones with safe fast-forwards, self-heals, `STUCK:` reports, branch pruning, and bounded recovery from an orphaned `.git/packed-refs.lock` |
| `fm-treehouse-pin.sh`    | Pin one project clone's treehouse worktree pool to this home, so a spawn cannot be handed a worktree of another copy of the repo (docs/treehouse-pools.md) |
| `fm-lease-extra-worktree.sh` | Lease a SECOND treehouse worktree for a task and record it durably in the task's meta, so teardown returns it too (docs/treehouse-pools.md) |
| `fm-fleet-snapshot.sh`   | Print the read-only structured fleet snapshot JSON (schema `fm-fleet-snapshot.v1`)   |
| `fm-fleet-view.sh`       | Render the fleet snapshot as a human Markdown view                                   |
| `fm-bearings-snapshot.sh` | Project the fleet snapshot to the compact TOON bearings view; local-only unless `--include-prs` |
| `fm-update.sh`           | Fast-forward-only self-update of firstmate and secondmate homes from origin          |
| `fm-backlog-handoff.sh`  | Validate and delegate queued backlog-item moves into a secondmate home               |
| `fm-decision-hold.sh`    | Create, verify, complete, and resolve durable captain-held decisions                 |
| `fm-decision-desk-ledger.sh` | Log decision-desk requests at routing time and surface a routed/ruled/overturned tally on demand |
| `fm-brief.sh`            | Scaffold ship, scout, secondmate-charter, and Herdr-lab briefs                       |
| `fm-work-report-counts.sh` | Emit reproducible work-report throughput counts (first-parent commits, batch-unrolled fm/ lane landings) for one repo over one resolved window as JSON (work-report skill) |
| `fm-herdr-lab.sh`        | Provision and guardedly operate an isolated, never-default Herdr lab session         |
| `fm-install-herdr.sh`    | Install CI's exact-version Herdr pin with official asset URL, SHA-256, and protocol checks |
| `fm-install-treehouse.sh`| Install CI's exact-version Treehouse pin for real-Herdr E2E that needs spawn worktrees |
| `fm-herdr-ci-cleanup.sh` | Snapshot and tear down only job-owned `fm-lab-*` sessions in the Herdr CI lane       |
| `fm-test-run.sh`         | Behavior-test runner: selection, portable lanes, proven-isolated `--jobs`, coverage guard, timing/JSON |
| `fm-test-isolation-proof.sh` | Phase 2 concurrent isolation proof and proven-isolated candidate set owner |
| `fm-heavy-run.sh`        | Serialize the fleet's heavy runs (suites, lint, builds) behind a configurable ceiling, passing output and exit status straight back |
| `fm-ensure-agents-md.sh` | Ensure a project's real `AGENTS.md`, its `CLAUDE.md` symlink, and the canonical self-governance section |
| `fm-guard.sh`            | Warn on primary-checkout tangles, pending queued wakes, and stale watcher liveness   |
| `fm-primary-scope-lib.sh` | Shared marker-or-plain-checkout primary-home predicate for tracked hooks             |
| `fm-turnend-guard.sh`    | Shared primary turn-end guard predicate so no turn ends blind (docs/turnend-guard.md) |
| `fm-turnend-guard-grok.sh` | Grok Stop-hook adapter for the primary turn-end guard                              |
| `fm-arm-pretool-check.sh` | Stable PreToolUse transport for the watcher-arm command policy (docs/arm-pretool-check.md) |
| `fm-arm-command-policy.mjs` | Semantic owner of the watcher-arm PreToolUse policy (docs/arm-pretool-check.md)   |
| `fm-continuity-pretool-check.sh` | Narrow Claude recovery gate when in-flight work has no live watcher lock (docs/arm-pretool-check.md) |
| `fm-continuity-command-policy.mjs` | Semantic owner of Claude continuity-gate fleet-command classification (docs/arm-pretool-check.md) |
| `fm-subagent-pretool-check.sh` | Primary-home delegation-shape PreToolUse guard (docs/subagent-guard.md) |
| `fm-supervision-instructions.sh` | Render the session-start primary-harness supervision block or the one-line repair instruction |
| `fm-home-seed.sh`        | Transactionally provision a secondmate home and maintain `data/secondmates.md`       |
| `fm-secondmate-context.sh` | Read-only report of a secondmate's context-window usage against the handoff threshold (claude only; else unknown) |
| `fm-secondmate-handoff.sh` | Hand a context-full secondmate to a fresh agent (stow + continuation doc + respawn) instead of `/compact`; idempotent, fail-closed |
| `fm-spawn.sh`            | Spawn crewmates, scouts, `id=repo` batches, and secondmates on the resolved harness and runtime backend; refuses crewmate/scout spawns onto already-completed or already-merged work unless `FM_SPAWN_ALLOW_DUPLICATE=1` |
| `fm-dispatch-select.sh`  | Resolve a dispatch rule/default to one profile, owning quota-aware arrays and random fallback |
| `fm-account-orchestrator.sh` | Firstmate's thin caller of the quota-axi account-switch orchestrator (`decide` at spawn, `decide`+`switch` on a tripwire); owns the jcode/Claude limit-error recognizer (see `docs/account-orchestrator.md`) |
| `fm-backend.sh`          | Runtime-backend selection, meta helpers, selector resolution, and operation dispatch |
| `fm-backend-hometag-lib.sh` | Shared per-installation home-tag derivation for zellij tab and cmux workspace titles |
| `fm-composer-lib.sh`     | Single fleet-wide owner of composer-content classification for all backends          |
| `backends/tmux.sh`       | Verified tmux session-provider adapter                                               |
| `backends/herdr.sh`      | Experimental herdr session-provider adapter                                          |
| `backends/zellij.sh`     | Experimental zellij session-provider adapter                                         |
| `backends/orca.sh`       | Experimental Orca backend adapter owning both worktree and terminal                  |
| `backends/cmux.sh`       | Experimental cmux session-provider adapter                                           |
| `fm-config-push.sh`      | Push declared inherited local material to live secondmates mid-session and send a pointer to the literal-content config reread when config changed |
| `fm-project-mode.sh`     | Resolve a project's delivery mode and `+yolo`/`+autoland` flags from `data/projects.md` |
| `fm-merge-local.sh`      | Fast-forward a `local-only` project's local default branch after approval            |
| `fm-review-diff.sh`      | Review a crewmate branch or resolved PR head against the authoritative base          |
| `fm-marker-lib.sh`       | Compatibility entry point for the from-firstmate carrier owned by `fm-operational-input.sh` |
| `fm-pending-reply-lib.sh` | Parent-owned secondmate pending-reply expectations, recovery, and one-shot escalation |
| `fm-secondmate-report.sh` | Optional helper to append a correlated parent status or document-pointer report       |
| `fm-gate-refuse-lib.sh`  | Shared no-mistakes gate-context refusal for fleet lifecycle entrypoints               |
| `fm-nm-preflight.sh`     | Clear a lane to run no-mistakes: refuse a detached HEAD, optionally re-assert the worktree belongs to the intended clone, warn about an unrelated in-flight run, and print the drive-by-id instruction |
| `fm-watch-arm.sh`        | Verified home-scoped watcher arm wrapper with loud cycle endings and bounded lifecycle ledger |
| `fm-watch-checkpoint.sh` | Run one bounded foreground watcher checkpoint for Codex-style supervision            |
| `fm-watch.sh`            | Singleton-safe always-on watcher: absorb benign wakes, queue and exit on actionable ones |
| `fm-hourly-lib.sh`       | Own arming, cadence, suppression, and script mapping for the two session-lifetime hourly passes |
| `fm-session-review.sh`   | Hourly session review: report only what has NOT moved, and stay silent otherwise    |
| `fm-cleanup-sweep.sh`    | Hourly cleanup sweep: silently reclaim bookkeeping, and report - never remove - anything that could hold unlanded work |
| `fm-afk-daemon-lib.sh`   | Shared owner of "is an away-mode daemon actually live for THIS home?" and who owns supervision |
| `fm-afk-daemon-state.sh` | Print this home's supervision-ownership state so non-shell auto-arm adapters ask that one owner |
| `fm-afk-start.sh`        | Run the common sourceable away-mode daemon entry in the foreground                      |
| `fm-afk-launch.sh`       | Own away-mode entry, exit, rollback, and any backend terminal lifecycle                 |
| `fm-afk-return.sh`       | Own deterministic return shutdown, catch-up evidence, and the firstmate-actionable blocker gate |
| `fm-afk-outbox-lib.sh`   | Own the durable away-mode paneless-delivery outbox: append-only records, portable lock, ack high-water mark, and compaction |
| `fm-afk-inbox.sh`        | Blocking away-mode pull-delivery reader: print pending digests, then acknowledge (armed through fm-afk-inbox-arm.sh, not directly) |
| `fm-afk-inbox-arm.sh`    | Resilient arm wrapper for the pull-delivery reader firstmate arms as a tracked background task: keep it resident, relaunch on crash with bounded backoff, escalate after repeated crashes, pass genuine outcomes through |
| `fm-afk-reader-check.sh`  | Report an away-mode escalation reader that is not running while records wait for it, so session start can re-arm it |
| `fm-afk-driver.sh`       | Advance the away-mode queue autonomously and safely: clean up finished lanes, nudge one that never pushed, start prepared queued work, report every action |
| `fm-supervisor-target-lib.sh` | Resolve the shared supervisor target and backend for the daemon and launcher       |
| `fm-supervise-daemon.sh` | Presence-gated away-mode sub-supervisor: self-handle routine wakes, escalate batched digests, alert on failed delivery |
| `fm-crew-state.sh`       | Print one deterministic current-state line for a crew                                |
| `fm-resource-check.sh`   | Print one kernel-wide host CPU/memory/swap reading with the concurrent-agent ceiling it supports |
| `fm-memory-report.sh`    | Rank every process by phys_footprint, attribute each to its fleet owner from durable records, and refuse rather than report a broken reading (docs/memory-report.md) |
| `fm-tangle-lib.sh`       | Shared default-branch resolution and primary-checkout tangle classification          |
| `fm-supervision-lib.sh`  | Shared in-flight-work-without-fresh-watcher-beacon predicate                         |
| `fm-ff-lib.sh`           | Shared guarded fast-forward helper for origin pulls and local secondmate syncs       |
| `fm-lock-lib.sh`         | Shared "is this git lock provably abandoned?" proof used by teardown and fleet-sync   |
| `fm-config-inherit-lib.sh` | Shared primary-to-secondmate inherited local-material propagation and config-reread delivery |
| `fm-tasks-axi-lib.sh`    | Shared backlog-backend selector and `tasks-axi` compatibility probe                  |
| `fm-wake-drain.sh`       | Atomically drain queued watcher wakes, emit bounded best-effort status-event annotations, then assert watcher liveness |
| `fm-wake-brief.sh`       | Compose one wake-handling turn's reads: that same drain, plus each woken task's status tail, current state, and metadata, one host reading, and one endpoint sweep |
| `fm-wake-lib.sh`         | Shared durable wake queue and watcher identity/health helpers, layered on `fm-mutex-lib.sh` |
| `fm-mutex-lib.sh`        | Side-effect-free portable advisory-mutex primitives (`fm_lock_try_acquire` and friends) |
| `fm-pid-lib.sh`          | Side-effect-free process liveness and pid-identity helpers shared by the wake and daemon libs |
| `fm-classify-lib.sh`     | Shared captain-relevant and declared-external-wait wake classification vocabulary    |
| `fm-send.sh`             | Send one verified literal line or supported key through the target's recorded backend |
| `fm-tmux-lib.sh`         | Shared tmux pane primitives for busy detection, composer capture, and verified submit |
| `fm-peek.sh`             | Print a bounded tail of a crewmate endpoint                                          |
| `fm-check-register.sh`   | Bind an intentional custom watcher check to its current bytes                       |
| `fm-check-lib.sh`        | Validate custom-check registrations and prepare private execution snapshots          |
| `fm-pr-lib.sh`           | Own canonical task and PR validation plus private atomic PR-poll and provenance publication |
| `fm-pr-poll.sh`          | Provide the byte-static watcher program for validated PR/MR-poll sidecars           |
| `fm-pr-check-migrate.sh` | Quarantine older task polls without execution and rebuild only canonical polls       |
| `fm-pr-check.sh`         | Record validated `pr=` and `pr_head=` values, then atomically arm a static merge poll |
| `fm-pr-merge.sh`         | Record PR metadata, then merge a task's canonical full GitHub URL                    |
| `fm-promote.sh`          | Promote a scout task in place to a protected ship task                               |
| `fm-teardown.sh`         | Fail-closed teardown: return landed or fully pushed ship worktrees, require completed scout deliverables, retire secondmate homes |
| `fm-merge-queue.sh`      | Surface, sweep, and prune the durable list of released-but-unmerged ship branches (docs/merge-queue.md) |
| `fm-merge-queue-lib.sh`  | Own the `data/merge-queue.tsv` format, locked record/remove writes, and the fresh content-in-base merged check |
| `fm-merge-queue-poll.sh` | Silent Bitbucket merge-queue watch: poll each queued branch's PR state and wake on merged/declined/superseded; arm and disarm the registered custom check (docs/bitbucket-merge-watch.md) |
| `fm-completions-lib.sh`  | Own the append-only `data/completions.tsv` ledger format, its atomic, idempotent per-completion append, and the exact-id lookup used by the pre-spawn duplicate-dispatch guard |
| `fm-token-sessions-lib.sh` | Side-effect-free owner of the append-only `data/token-sessions.tsv` ledger mechanics, `fm_resolve_crew_session_id` (newest-created_at jcode session matching leased worktree and spawn-or-later `created_at`, fail-closed to empty), and `fm_token_sessions_rows_for` (all ledger rows for a task id, mirrors `fm_completions_lookup`; design PR-T4); appended best-effort from `fm-spawn.sh` after every launch and from `fm-session-start.sh` under the sentinel id `__firstmate__` |
| `fm-token-prices.sh`   | Single owner of the shared token-price snapshot `config/token-prices.json`: `--refresh` copies `providers.anthropic` out of jcode's cached models.dev feed into the owned table with a sourced+dated header, a bare call prints it or a clear not-yet-refreshed message, and a missing source fails loudly without guessing prices (design PR-T1) |
| `fm-token-lib.sh`      | Side-effect-free owner of token-sum + cost-if-API + subscription-coverage math for jcode sessions: exact token sums across assistant `token_usage`, dot-product cost against the owned price snapshot (unknown/unpriced model = UNKNOWN, never 0), exact-then-`-YYYYMMDD`-family price lookup, and the `claude-oauth` OR over `provider_key`/`route_api_method` (design PR-T1) |
| `fm-token-report.sh`  | Read-only per-session, per-period, and time-bucketed (`--by hour\|day\|week\|month`, `--precise` for per-message bucketing) token/cost report over `$JCODE_SESSIONS_DIR`; groups optionally `--by-model`/`--by-provider`, supports `--json`; aggregates raw token sums per group and costs every group through `fm-token-lib.sh` (`--session` routes through `fm_token_sum_session` for exact PR-T1 parity), never reimplementing dollar math; unknown-model tokens land in a separate bucket with dollars withheld, never a fabricated $0 (design PR-T2); adds a per-ticket dimension: bare `<task-id>` sums every `token-sessions.tsv` ledger row for that id (EXACT), `--period ... --by-ticket` groups every store session by ledger ticket or an `unattributed` bucket, and `<task-id> --retro` estimates pre-capture tickets from a `completions.tsv`-close-date-bounded window, always labeled ESTIMATE and refusing tickets with exact ledger data (D4, design PR-T4) |
| `fm-harness.sh`          | Detect the running harness and resolve crew or secondmate harness, model, and effort |
| `fm-lock.sh`             | Per-home firstmate session lock                                                      |
| `fm-x-lib.sh`            | Shared X-mode config, relay, and reply-threading helpers                             |
| `fm-x-poll.sh`           | One bounded X relay poll: stash newly offered mentions and emit their once-only wake |
| `fm-x-reply.sh`          | Post or dry-run preview a composed X-mode reply or follow-up                         |
| `fm-x-dismiss.sh`        | Dismiss a skipped X-mode mention at the relay without replying                       |
| `fm-x-link.sh`           | Link a spawned task to its originating X-mode mention in task meta                   |
| `fm-x-followup.sh`       | Detect, post, and cap completion follow-ups for an X-mode-linked task                |
