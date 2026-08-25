# Configuration

The files and environment variables you set to operate firstmate.

## Orchestrator behavior (AGENTS.md)

The shared orchestrator behavior lives in [`AGENTS.md`](../AGENTS.md) - edit it like any prompt when the fleet is empty, or dispatch shared-repo edits to a crewmate while tasks are in flight.

## Operational home layout and state

This section is the single owner of the top-level operational-home layout; producer script headers and their help own exact child-file fields and mutation contracts.
The tracked code root contains the shared instruction, skill, documentation, workflow, and `bin/` surfaces, while each effective `FM_HOME` contains private operational directories.
`data/` holds durable private fleet records such as the project and secondmate registries, captain preferences, optional shared captain preferences, learnings, backlog, briefs, scout reports, and the merge queue of released-but-unmerged ship branches (`data/merge-queue.tsv`, owned by `bin/fm-merge-queue-lib.sh`; see [merge-queue.md](merge-queue.md)).
`state/` holds volatile runtime records such as task metadata, append-only status events, endpoint signals, watcher and wake-queue coordination, away-mode state, generated X-mode artifacts, private secondmate config-reread generations with their retry and quarantine state, and parent-owned secondmate pending-reply records under `state/pending-replies/` (`bin/fm-pending-reply-lib.sh`).
`config/` holds local gitignored operating choices - with one tracked exception, the shared token-price snapshot `config/token-prices.json` owned by `bin/fm-token-prices.sh` (`--refresh`, see that script's header and `AGENTS.md` section 2) - and `projects/` holds the local project clones that Firstmate reads but changes only through the guarded exceptions in `AGENTS.md`.
`.treehouse/` holds this home's own Treehouse worktree pools for those clones, so a spawn can never be handed a worktree belonging to another copy of the same repo; it is gitignored, created by Treehouse rather than by Firstmate, and pinned per clone by `bin/fm-treehouse-pin.sh` (see [treehouse-pools.md](treehouse-pools.md)).

`bin/fm-spawn.sh` owns the base task-metadata fields it emits, while the runtime-backend section below owns backend-specific fields and selector interpretation.
The producing PR and X helpers own the fields they append, `bin/fm-classify-lib.sh` owns status-event vocabulary, and `bin/fm-crew-state.sh` owns current-state reconciliation.
Wake, watcher, away-mode, and X-specific state mechanics remain with their named scripts and reference sections rather than being duplicated into one exhaustive state tree here.

`bin/fm-session-start.sh`'s header is the single owner of session-start ordering, composed commands, digest contents, and the digest's startup mechanism.
`docs/sessionstart-nudge.md` owns the native session-open adapter mechanics that nudge the digest command.
`AGENTS.md` retains the run-once and read-once operator rules, lock-refusal safety, installation consent, and direct-report recovery boundaries because those facts apply at every session start.
Ordinary dead-direct-report recovery is owned by `stuck-crewmate-recovery`, while persistent-secondmate recovery is owned by `secondmate-provisioning`.

The full annotated tree, moved here from `AGENTS.md` section 2:

```
AGENTS.md            this file (CLAUDE.md is a symlink to it)
CONTRIBUTING.md      contributor workflow and repo conventions
README.md            public overview and development notes
.github/workflows/   shared CI and PR enforcement, committed
.tasks.toml          tracked tasks-axi markdown backend config for the default backlog backend (section 10)
.agents/skills/      firstmate-loaded internal skills, committed; each carries metadata.internal=true for installers
.claude/skills       symlink to .agents/skills for claude compatibility
skills/              standalone public installer-facing skills, committed; not loaded by firstmate
bin/                 helper scripts, committed; read each script's header before first use
.env                 optional X-mode pairing token; LOCAL, gitignored; presence-gates section 14
config/crew-harness  crewmate harness override; LOCAL, gitignored; absent or "default" = same as firstmate. Inherited as the literal file: a concrete primary adapter value also controls a secondmate home's own crewmates (section 4)
config/crew-dispatch.json  optional crewmate dispatch profiles; LOCAL, gitignored; firstmate-maintained but human-editable natural-language rules that choose a per-task harness/model/effort profile (section 4). Inherited by secondmate homes
config/secondmate-harness  harness the PRIMARY uses to launch SECONDMATE agents, optionally followed by a model and effort token, as a default line or a per-secondmate-id pin (see docs/configuration.md; section 4); LOCAL, gitignored; absent or "default" harness falls back to config/crew-harness then firstmate's own. The primary's own setting; NOT inherited into secondmate homes (secondmates do not spawn secondmates)
config/backlog-backend  backlog backend override; LOCAL, gitignored; absent or "tasks-axi" = default tasks-axi backend, "manual" = force routine backlog updates to hand-editing; inherited by secondmate homes (section 10)
config/backend  runtime session-provider backend override for new tasks; LOCAL, gitignored; absent = falls through to runtime auto-detection (the runtime firstmate itself is executing inside), then tmux; tmux is the verified reference backend (docs/tmux-backend.md), while herdr, zellij, orca, and cmux are experimental spawn backends (docs/herdr-backend.md, docs/zellij-backend.md, docs/orca-backend.md, docs/cmux-backend.md) - herdr and cmux can also be selected by runtime auto-detection, zellij and orca never are (always explicit), and codex-app is not accepted; see docs/codex-app-backend.md; not inherited into secondmate homes
config/herdr-presentation-spaces  optional presence flag for Herdr's default-off disposable single-task visual projection; LOCAL, gitignored; inherited by secondmate homes; see docs/herdr-backend.md "Optional disposable single-task presentation spaces"
config/cmux-socket-password  optional cmux control-socket password; LOCAL, gitignored; read fresh on every cmux CLI call and passed through without ever overriding an operator's own ambient CMUX_SOCKET_PASSWORD when absent (docs/cmux-backend.md "Setup")
config/present-daemon  optional presence flag for the present-mode supervision daemon; LOCAL, gitignored; absent means the session arms the watcher itself per turn, as before. Not inherited by secondmate homes; see docs/configuration.md and bin/fm-present-daemon.sh
config/present-daemon-pane-wake  optional presence flag that makes the present-mode daemon ALSO pane-inject a wake on each actionable watcher cycle, for a primary harness whose background completion does not wake an idle model (jcode); LOCAL, gitignored; absent auto-enables on a jcode primary and stays off on claude/grok, present forces it on (first line "off" force-disables), and any unsupported backend or unresolved pane degrades silently to the plain silent re-arm. Not inherited by secondmate homes; see docs/configuration.md and bin/fm-present-daemon.sh
config/liveness-watchdog  optional presence flag for the external liveness watchdog (bin/fm-liveness-watchdog.sh), which runs OUTSIDE the agent tree and, when the primary dies with work in flight, re-wakes the primary's own supervisor pane (recorded at session start in state/.supervisor-target) and writes a durable local escalation (state/.liveness-escalation) surfaced at next session start - NO phone push; LOCAL, gitignored; absent means the feature is inert. Optional config/liveness-resume gives a relaunch command for a dead-shell supervisor pane. Not inherited by secondmate homes; see docs/liveness-watchdog.md
config/wedge-alarm  optional away-mode wedge-alarm active-alert directives; LOCAL, gitignored; absent means auto (macOS Notification Center when available); see docs/wedge-alarm.md
config/heavy-run-slots  how many heavy runs (suites, lint, builds) may execute at once on the host; LOCAL, gitignored; absent or malformed = 1; the ledger is host-global and every home resolves one shared ceiling from the primary home's copy of this file (docs/configuration.md "Heavy-run serialization")
config/watcher-cadence  optional supervision-watcher cadence knobs (signal_grace, poll, heartbeat) as key=value seconds; LOCAL, gitignored; present overrides, absent uses built-in defaults (signal_grace 240, poll 300, heartbeat 600), malformed value or unknown key falls back to the default and is reported loudly; a VALID file value wins over the equivalent env var (config-authoritative, the fix for the settings.local.json drift class), env is the fallback/test-seam only; resolver owned by bin/fm-cadence-lib.sh, read by bin/fm-watch.sh so no env prefix is needed at arm time (docs/configuration.md "Watcher cadence")
config/captain-preferences  optional record of the captain's standing preference for captain-owned operating values (e.g. watcher_poll, watcher_signal_grace, watcher_heartbeat) as key=value; LOCAL, gitignored; session-start drift alarm (bin/fm-drift-check.sh, run in bin/fm-bootstrap.sh) SHOUTS a CONFIG_DRIFT line when a live value disagrees with the recorded preference; absent/empty key = no preference recorded (not agreement); generalized, not hard-wired to one key (docs/configuration.md "Captain-owned value drift alarm")
config/x-mode.env    generated X-mode watcher cadence; LOCAL, gitignored; source before arming watcher when present
config/token-prices.json  shared token-price snapshot, TRACKED (the one non-local config file); the owned per-provider USD-per-Mtok price table that bin/fm-token-lib.sh costs token usage against; written ONLY by bin/fm-token-prices.sh --refresh as a straight copy of every provider table out of jcode's cached models.dev feed, with a header carrying price_source, the source's cached_at, and the snapshot's written_at so every price is traceable from the file alone; never hand-edited (one-owner-per-contract; bin/fm-token-prices.sh header owns the format, design PR-T1)
data/                personal fleet records; LOCAL, gitignored as a whole
  backlog.md         task queue, dependencies, history
  captain.md         this home's domain-local captain preferences and working style; LOCAL, gitignored, canonical even if harness memory mirrors it, and updated with inspect-then-update
  captain-shared.md  main-authoritative shared captain preferences propagated read-only to secondmate homes; LOCAL, gitignored, owned by secondmate-provisioning
  learnings.md       fleet-local operational facts and gotchas; LOCAL, gitignored; dated, evidence-backed, curated, and updated with inspect-then-update - rewrite and prune rather than append forever, the same contract as captain.md; created lazily, absent until this home has a learning to store
  projects.md        thin fleet navigation registry; firstmate-private, parsed by fm-project-mode.sh (section 6)
  secondmates.md      secondmate routing table; firstmate-private, maintained by fm-home-seed.sh (section 6)
  merge-queue.tsv    durable list of released-but-unmerged ship branches; firstmate-private, owned by fm-merge-queue-lib.sh, surfaced/swept by fm-merge-queue.sh (docs/merge-queue.md, section 7)
  session-stats.log  append-only one-line-per-session close record; firstmate-private, owned by fm-end-session.sh (docs/configuration.md)
  completions.tsv    append-only, NEVER-pruned completion ledger, one line per task that reaches teardown; firstmate-private, owned by fm-completions-lib.sh (the single owner of exact field mechanics), appended from fm-teardown.sh at the authoritative completion point so work-report can query precise ticket-completion data
  token-sessions.tsv  append-only, NEVER-pruned harness-session ledger, many rows per task id (one per spawn/relaunch, deduped only by exact id+session_id pair) plus a row under the sentinel id `__firstmate__` for firstmate's own session; captain-private, gitignored, owned by fm-token-sessions-lib.sh (the single owner of append mechanics and fm_resolve_crew_session_id); appended best-effort from fm-spawn.sh post-launch and from fm-session-start.sh, and left untouched by teardown so per-ticket token/cost rollup survives task-metadata pruning
  decision-desk-ledger.md  human-readable value ledger for the decision-desk secondmate, one row per routed request with its status and optional overturned annotation; firstmate-private, owned by fm-decision-desk-ledger.sh (route/resolve/overturn/tally), created lazily on first route
  <id>/brief.md      per-task crewmate brief, or per-secondmate charter brief when kind=secondmate
  <id>/report.md     scout task deliverable, written by the crewmate; survives teardown
projects/            cloned repos; gitignored; READ-ONLY for you
.treehouse/          this home's own worktree pools for those clones; gitignored; created by treehouse, pinned per clone by bin/fm-treehouse-pin.sh so a spawn cannot draw a worktree of another copy of the repo (docs/treehouse-pools.md)
state/               volatile runtime signals; gitignored
  <id>.status        appended by crewmates: "<state>: <note>" wake-event lines, not current-state truth
  <id>.turn-ended    touched by turn-end hooks
  <id>.grok-turnend-token   firstmate-owned grok hook registry token for the task; removed by teardown
  <id>.meta          written by fm-spawn: window=, worktree=, project=, harness=, model=, effort=, kind=, mode=, yolo=, autoland=, tasktmp=; a post-launch best-effort session_id= stamp records the resolved jcode harness session for token/cost attribution when resolvable (bin/fm-token-sessions-lib.sh); an --unsupervised (hands-off) pane also records supervise=off, which the watcher's recorded_windows drops from every supervision path (the grilling-handoff griller pane); kind=secondmate also records home= and projects=; a non-default runtime backend records further backend-specific fields (docs/configuration.md "Runtime backend"; bin/fm-backend.sh, section 8); fm-pr-check, including through fm-pr-merge, records one canonical pr= and the forge's pr_head= when available (GitHub pull requests and GitLab merge requests; docs/gitlab-merge-watch.md); fm-x-link appends x_request=, x_request_ts=, x_followups=, and optional x_platform=/x_reply_max_chars= for an X-mode-originated task (section 14); fm-lease-extra-worktree.sh appends one extra_worktree=<clone>\t<worktree> line per separately-leased second worktree so teardown returns it too (docs/treehouse-pools.md)
  <id>.telemetry     key=value, same format as <id>.meta; shared per-task producer artifact written in place by bin/fm-telemetry-lib.sh's fm_telemetry_set (one key updated without clobbering sibling keys); fm-spawn stamps account=/account_source=spawn for jcode/claude workers (fail-soft), fm-watch's post-rotation switch restamps account_source=switch, and fm-watch's fleet_quota_sweep fans quota_pct/quota_window/quota_reset_ts onto every live task once per slow-poll CHECK_INTERVAL (Visibility Gap-1; absent = unknown, never zero); the watcher's quota_anomaly_scan (Visibility Gap-2) writes count_429/last_429_ts here on a pane 429/rate-limit tripwire; fm-send stamps last_steer_ts on every confirmed text delivery, and the watcher's steer_stuck_check (Visibility Gap-4) sets composer_stuck=1 when a fresh steer's pane hash hasn't advanced since delivery and the pane isn't busy, clearing it on busy or hash advance or on the steer aging past FM_STEER_STUCK_WINDOW (default 600s); the watcher's dead_turn_check (Visibility Gap-5) records resume_probe_ts=<epoch> when it sends its single automatic resume steer to a lane whose content has been frozen since a recent 429 (never gated on busy, which lies on dead jcode panes), escalating `check: dead-turn <task>` on the next poll that is still content-frozen (mechanism and evidence: docs/design-visibility-improvements.md); removed by teardown
  <id>.herdr-presentation  quarantinable attempt journal for Herdr's optional visual projection; never task or endpoint authority; see docs/herdr-backend.md "Optional disposable single-task presentation spaces"
  <id>.check.sh      authenticated slow poll; the watcher dispatches validated PR data and the byte-identified X shim through trusted repository scripts, runs registered custom checks from hash-validated private snapshots, and rejects every other state check without execution
  <id>.check-trust   private content binding created by fm-check-register.sh for an intentional custom check
  <id>.pr-poll       private validated data sidecar for the byte-static PR merge poll
  <id>.pr-poll-registration  private transactional provenance record binding the task, canonical metadata identity, sidecar, and static poll publication
  .pr-check-quarantine/  private non-runnable storage for checks neutralized by the non-executing migration
  .pr-check-migration.log  private per-task outcomes distinguishing rebuilt or canonically registered replacement polls, quarantined unarmed polls, and incomplete migrations
  .pr-check-migration-scan-v1  private marker proving the non-executing scan disabled every unsafe legacy check; .pr-check-migration-v1 separately records completed private repairs
  x-watch.check.sh   generated X-mode relay poll shim; present only when opted in (section 14)
  pending-replies/   parent-owned secondmate pending-reply records (correlation id, delivery vs reply, recovery, escalation); fm-pending-reply-lib.sh
  heavy-runs/        heavy-run lease queue when FM_HEAVY_RUN_DIR points here; by default the ledger is host-global outside any home ($TMPDIR/fm-heavy-runs-<uid>), one record per running or queued suite plus its admission lock; bin/fm-heavy-run.sh owns it, never edit by hand (docs/configuration.md "Heavy-run serialization")
  x-inbox/           generated X-mode pending mention payloads; fmx-respond drains it (section 14)
  x-context/         generated X-mode durable per-request reply context and one-wake offer markers, keyed by request_id; survives inbox cleanup and expires within seven days (section 14; bin/fm-x-lib.sh)
  x-outbox/          generated X-mode dry-run reply and dismiss previews; inspect it when FMX_DRY_RUN is set (section 14)
  x-poll.error x-poll.claim-error  generated X-mode relay and offer-claim diagnostic dedupe markers
  .wake-queue        durable queued wakes: epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload
  .afk               durable away-mode flag; present = the away posture, so a live sub-supervisor daemon may inject escalations, while supervision ownership follows an actually-live daemon rather than this flag (bin/fm-afk-daemon-lib.sh; set by /afk, cleared on an explicit captain return)
  .afk-driver.lock .afk-driver-steered-* .afk-driver-noted-*  away-mode driver per-tick lock and its one-time action records, so a nudge or a report is never repeated on every tick; owned by bin/fm-afk-driver.sh
  .afk-persist       durable away-mode PERSIST INTENT, distinct from operational .afk; present = the captain ordered away supervision to survive a session turnover, so session start re-enters away mode and revives the daemon (bin/fm-bootstrap.sh afk_daemon_revive_sweep); owned by bin/fm-afk-launch.sh, set by `persist`, cleared ONLY by the explicit `unpersist` exit (never by auto-return)
  .afk-delivery .afk-outbox* .afk-inbox.beat  away-mode delivery mode, the durable pull-delivery records used when no supervisor pane exists, and the reader's liveness beacon; acknowledged only by bin/fm-afk-inbox.sh (docs/configuration.md)
  .watch.lock .wake-queue.lock watcher singleton and queue serialization locks
  .wake-brief-spool-*  bin/fm-wake-brief.sh's drained-record spool; removed after a successful brief, kept and named in the output when the drain failed because it is then the only copy of those records
  .hash-* .count-* .stale-* .stale-since-* .paused-* .wedge-escalations-* .seen-* .hb-surfaced-* .last-* .resource-* .heartbeat-streak   watcher internals; never touch
  .hourly-armed .hourly-*-surfaced .hourly-*.latest .hourly-decision-* .hourly-cleanup.log  hourly session-review and cleanup pass state: armed for the session by bin/fm-session-start.sh, run by the one watcher on its slow poll (docs/configuration.md); watcher internals, never touch
  .watch-triage.log  watcher's absorbed-wake debug log (size-capped); never relied on, safe to delete
  .last-watcher-beat watcher liveness beacon, touched every poll (including while absorbing benign wakes); guard scripts read it
  .supervisor-target  "<backend>\t<target>" of the primary's own supervisor pane, recorded at session start for the external liveness watchdog (bin/fm-liveness-watchdog.sh); the detached watchdog reads it to re-wake the primary
  .liveness-escalation  durable external-liveness-watchdog escalation record, surfaced as a LIVENESS_ESCALATION line at next session start and cleared after surfacing (NO phone push); owned by bin/fm-liveness-watchdog.sh
  .liveness-watchdog.lock .liveness-watchdog.log .liveness-watchdog-episode .liveness-watchdog-resumes .liveness-watchdog-capreported  external liveness watchdog singleton lock, log, and per-down-episode resume-cap state; watchdog internals, never touch
  .subsuper-* .supervise-daemon.*   sub-supervisor internals; never touch
.no-mistakes/        local validation state and evidence; gitignored
```

## Backlog backend (.tasks.toml / config/backlog-backend)

The tracked `.tasks.toml` pins the default `tasks-axi` markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
When the default backend is selected and compatible `tasks-axi` is on `PATH`, firstmate uses its verbs for routine backlog mutations.
Secondmate handoffs are separate and unconditional: `fm-backlog-handoff.sh` keeps only its own fleet-level validation and always delegates the item move to `tasks-axi mv`, the single owner of the backlog format.
It moves in-scope `## Queued` items only and refuses `## In flight` and historical `## Done` records, which stay with their home for pruning or archiving.
Handoff item bodies must use at least two leading spaces, and the helper refuses a selected item with a single-space or tab-indented continuation rather than risk orphaning it.
Because bootstrap requires `tasks-axi` on `PATH` on every profile, that delegation works fleet-wide, and the `config/backlog-backend=manual` knob governs firstmate's own hand-editing of its backlog, not this validated helper.
Compatible means the shared bootstrap probe accepts `tasks-axi --version` as 0.1.1 or newer, `tasks-axi update --help` exposes `--archive-body`, and `tasks-axi mv --help` exposes `[<id>...]` for the atomic multi-ID move introduced in 0.2.2 and required by handoff delegation.
That sentence is the single owner of the tasks-axi compatibility definition; every other document points here instead of restating the version gates.
Bootstrap requires compatible `tasks-axi` on every profile; see "Toolchain" below for missing-tool reporting and silent default-backend behavior.
Set the local, gitignored `config/backlog-backend` file to `manual` to force manual backlog editing and suppress the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not missing-tool reporting.
Absent or `tasks-axi` selects the default tasks-axi backend.
The file format is unchanged in both modes; tasks-axi and manual edits produce the same `## In flight`, `## Queued`, and `## Done` sections.

## Runtime backend (config/backend / FM_BACKEND)

For spawn-capable adapters, the runtime session-provider backend controls where task windows/endpoints are created, captured, sent to, watched, and killed.
`tmux` is the verified reference backend (see [`docs/tmux-backend.md`](tmux-backend.md)); `herdr`, `zellij`, `orca`, and `cmux` are experimental spawn backends (see [`docs/herdr-backend.md`](herdr-backend.md), [`docs/zellij-backend.md`](zellij-backend.md), [`docs/orca-backend.md`](orca-backend.md), and [`docs/cmux-backend.md`](cmux-backend.md)).
Treehouse remains the worktree provider for tmux, herdr, zellij, and cmux, since herdr, zellij, and cmux are session providers only; Orca provides both the task worktree and terminal endpoint.
New spawns choose the backend in this order: an explicit `--backend` flag firstmate passes when it spawns a task, then `FM_BACKEND`, then the first non-empty line of local gitignored `config/backend`, then runtime auto-detection from `$TMUX`, `HERDR_ENV=1`, or cmux runtime signals, then default `tmux`.
If more than one runtime marker is present, detection resolves innermost-first: `$TMUX` is checked before `HERDR_ENV=1`, which is checked before cmux's primary `CMUX_WORKSPACE_ID` marker and its documented fallback signals - tmux or herdr started from inside a cmux terminal is the innermost, currently-executing layer, while cmux itself (a terminal application, not a nestable multiplexer) is always checked last.
See [`docs/cmux-backend.md`](cmux-backend.md#runtime-auto-detection) for why cmux can be selected when `CMUX_WORKSPACE_ID` is absent.
Auto-detected herdr or cmux prints a stderr notice naming `config/backend` and `--backend tmux` as opt-outs; auto-detected tmux stays silent to preserve existing default behavior.
Zellij and Orca are never auto-detected; select them by putting the name in a local `config/backend` file, by exporting `FM_BACKEND=<name>`, or by telling the first mate in chat.
Any value other than `tmux`, `herdr`, `zellij`, `orca`, or `cmux` is rejected until another adapter is implemented and verified.
`fm-spawn.sh` accepts `tmux`, `herdr`, `zellij`, `orca`, and `cmux` for ship and scout tasks; `backend=orca` and `backend=cmux` both still refuse `--secondmate` until secondmate launch semantics are designed for each.
`codex-app` is not an accepted runtime backend yet; [`docs/codex-app-backend.md`](codex-app-backend.md) owns the Codex App boundary.
The session-start secondmate liveness sweep uses a deeper `fm_backend_agent_alive` probe where verified.
Today that probe can classify tmux and herdr secondmate endpoints as `alive`, `dead`, or `unknown`; zellij, Orca, and cmux report `unknown` until their own agent-process classifiers are verified.
A herdr spawn additionally version-gates against the installed `herdr` binary's protocol and requires `jq`, refusing loudly on an incompatible or missing installation.
A zellij spawn additionally version-gates against the installed `zellij` binary's version and requires `jq`, refusing loudly when either is missing or the version is older than 0.44.
A cmux spawn additionally version-gates against the installed `cmux` binary's version, requires `jq`, and requires the control socket to be reachable and accessible (see [`docs/cmux-backend.md`](cmux-backend.md) "Setup" for the one-time socket-access configuration this needs; Automation mode is the recommended socket control mode, with Password mode supported via `config/cmux-socket-password`), refusing loudly and non-retryably on a `cmuxOnly`/unauthenticated socket.
A backend spawn refusal from a missing dependency, version gate, or unauthenticated socket is terminal for that selected backend; firstmate surfaces it as a blocker instead of silently retrying another backend.
Task meta records `backend=` only for a non-default backend; an absent `backend=` means `tmux`, preserving existing default-path meta files.
A herdr task additionally records `herdr_session=`, `herdr_workspace_id=`, `herdr_tab_id=`, and `herdr_pane_id=`.
A zellij task additionally records `zellij_session=`, `zellij_tab_id=`, and `zellij_pane_id=`.
An Orca task additionally records `orca_worktree_id=` and `terminal=`, with `window=fm-<id>` kept as the shared firstmate alias.
A cmux task additionally records `cmux_workspace_id=` and `cmux_surface_id=`.
Task selectors for `fm-peek.sh`, `fm-send.sh`, and `fm-crew-state.sh` resolve centrally through `fm_backend_resolve_selector`.
A selector containing `:` is passed through as an explicit backend endpoint escape hatch.
Otherwise an exact task id matching `state/<id>.meta` wins before the legacy `fm-<id>` label fallback, so task ids that themselves start with `fm-` route to their own metadata instead of being stripped.
A metadata-routed selector returns the recorded backend target (`terminal=` for Orca, otherwise `window=`), and matching explicit targets can still recover the recorded backend when metadata contains the same endpoint.
Only metadata-routed task selectors carry secondmate-marker and Codex-harness context; explicit endpoint escape hatches do not.
These five sentences are the single owner of the task-selector vocabulary; backend guides and other documents point here instead of restating the resolution order.
`fm-teardown.sh <id>` takes a task id directly and uses the same recorded backend target fields after loading `state/<id>.meta`.
By default, Herdr workspaces are derived from `FM_HOME`: the primary home uses `firstmate`, and a secondmate home marked by `.fm-secondmate-home` uses `2ndmate-<secondmate-id>`.
The default-container spawn, list-live, and recovery paths read that label from the active home, so a secondmate's own crewmates stay inside that secondmate home's herdr space.
The optional local `config/herdr-presentation-spaces` presence flag instead enables Herdr's default-off disposable single-task visual projection; [`docs/herdr-backend.md`](herdr-backend.md#optional-disposable-single-task-presentation-spaces) owns its behavior, safety limits, and recovery contract.
The flag is default-off and inherited into secondmate homes under the primary-authoritative contract owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md).
For normal herdr operations, `HERDR_SESSION` selects the named session, but destructive test cleanup must not rely on `HERDR_SESSION` alone.
Use the explicit guarded cleanup path described in [`docs/herdr-backend.md`](herdr-backend.md) instead of `herdr server stop`.
For normal zellij operations, `FM_ZELLIJ_SESSION` selects the named session and defaults to `firstmate`.
Zellij has no per-home workspace split: primary and secondmate tasks share that one session, and visible tab titles are scoped by the active `FM_HOME` readable label plus a short hash of the resolved `FM_ROOT` path as `fm-<home-label>-<id>`.
Use the guarded cleanup path described in [`docs/zellij-backend.md`](zellij-backend.md) instead of `kill-all-sessions` or `delete-all-sessions`.
cmux has no session layer at all - one workspace per task, in whatever cmux window is open - and its socket password (when configured) is read from local, gitignored `config/cmux-socket-password` under the effective config directory, never committed.
The caller-facing label remains `fm-<id>`, but the actual cmux workspace title is scoped by the active `FM_HOME` readable label plus a short hash of the resolved `FM_ROOT` path as `fm-<home-label>-<id>`.
Test cleanup must use the guarded path described in [`docs/cmux-backend.md`](cmux-backend.md)'s "Test safety" section, never enumerate-and-close every workspace.
The `config/backend` file is not inherited by secondmate homes.

## Away-mode supervisor backend (FM_SUPERVISOR_BACKEND / FM_SUPERVISOR_TARGET)

The `/afk` sub-supervisor injects escalation digests into firstmate's own pane independently of where new task endpoints are spawned.
It currently supports only `tmux` and `herdr` supervisor panes.
Set `FM_SUPERVISOR_BACKEND=tmux|herdr` and `FM_SUPERVISOR_TARGET=<target>` to override both axes explicitly; for herdr the target is `"<session>:<pane-id>"`.
Without overrides, backend detection uses `$TMUX_PANE` first, then `HERDR_ENV=1` with `HERDR_PANE_ID`, then falls back to `tmux`.
That keeps a tmux pane nested inside herdr on the tmux transport, matching the runtime backend's innermost-first rule.
Target detection uses `FM_SUPERVISOR_TARGET`, then `$TMUX_PANE`, then `"${HERDR_SESSION:-default}:${HERDR_PANE_ID}"` under herdr.
When none of those identifies firstmate's pane, the daemon no longer injects into the legacy `firstmate:0` guess; it selects paneless delivery instead, as the next section describes.
Selecting any other supervisor backend, including `zellij`, `orca`, or `cmux`, refuses at daemon startup instead of trying tmux injection primitives against a non-tmux pane.

## Away-mode paneless delivery (FM_AFK_DELIVERY / state/.afk-outbox)

The sub-supervisor delivers escalation digests one of two ways, chosen once at daemon startup and logged with its reason.
Pane delivery types the digest into firstmate's own pane and is unchanged whenever the discovery above positively identifies that pane.
Paneless delivery is selected when nothing identified it - a primary firstmate running outside every supported terminal backend, such as a session launched from the desktop app - and appends each flushed digest to a durable outbox that firstmate pulls from, so escalations no longer depend on a pane that does not exist.
`FM_AFK_DELIVERY` overrides that choice with `auto` (the default), `pane`, or `paneless`; an unrecognized value warns and behaves as `auto`.
A supported-but-broken pane, such as an explicit `FM_SUPERVISOR_TARGET` that does not resolve or an unsupported `FM_SUPERVISOR_BACKEND`, still refuses loudly at startup rather than switching channels silently.

Paneless state lives in the effective home's `state/`: `.afk-delivery` records the selected mode, `.afk-outbox` holds the append-only delivery records, `.afk-outbox.ack` holds the acknowledged high-water mark, `.afk-outbox.seq` holds the sequence counter, `.afk-outbox.lock` serializes the writer against the reader, and `.afk-inbox.beat` is the reader's liveness beacon.
[`bin/fm-afk-outbox-lib.sh`](../bin/fm-afk-outbox-lib.sh) is the single owner of that record format and its acknowledgement contract, including why only the reader may consume a record.
Firstmate arms [`bin/fm-afk-inbox-arm.sh`](../bin/fm-afk-inbox-arm.sh) as its own harness-tracked background task the way it arms the watcher; that wrapper is the single owner of resident-reader residence and crash recovery.
The wrapper is also the per-home reader singleton, reusing the shared portable mutex on `state/.afk-inbox-arm.lock` rather than a second locking scheme: on arm it retires any pre-existing reader for this home (the predecessor wrapper recorded as the lock holder, whose trap tears down its reader child, and any orphan reader a hard-killed wrapper left recorded in `state/.afk-inbox-reader.pid`) before claiming the lock, so a stale reader from a dead session cannot survive and keep acknowledging the outbox to a stdout nobody reads (evidence 2026-08-06: three stale readers acknowledged the outbox while the captain got no wakes).
Retiring is unconditional like `bin/fm-watch-arm.sh --restart`, home-scoped, zombie/dead-pid safe, and gated on a captured process identity, so it can never signal a reused pid or another home's reader.
The wrapper runs the bare reader [`bin/fm-afk-inbox.sh`](../bin/fm-afk-inbox.sh) with `--timeout 0` so a quiet home never idle-exits it, relaunches it on a crash with bounded backoff, surfaces a durable degraded `check` wake after a run of rapid crashes, and passes every genuine reader outcome (a delivery, an operational failure, a do-not-re-arm condition) straight through with the reader's own stdout and status.
The reader script's header and `--help` own its flags, its exit lines, and the `FM_AFK_INBOX_TIMEOUT`, `FM_AFK_INBOX_POLL`, and `FM_AFK_INBOX_LOCK_TIMEOUT_MAX` knobs; the wrapper's header owns `FM_AFK_INBOX_ARM_RAPID_SECONDS`, `FM_AFK_INBOX_ARM_FAILURE_THRESHOLD`, `FM_AFK_INBOX_ARM_BACKOFF_BASE`, and `FM_AFK_INBOX_ARM_BACKOFF_MAX`.
All of these are session-scoped delivery state: `bin/fm-afk-start.sh` clears them on a fresh away entry - the lock and the atomic-rename temporary files included - and `bin/fm-afk-return.sh` reports any unacknowledged record as return catch-up evidence before clearing it.
Return catch-up retires that state through the outbox library's own locked clearing owner rather than deleting the files directly, because the reader this session armed exits only on its next poll and can still be inside an acknowledgement's compaction, whose atomic rename would otherwise resurrect the finished session's records with the acknowledgement mark gone; a clear that cannot take the lock leaves everything in place, names the lock, and does not reopen the gate.
A read of the outbox that fails is never treated as an outbox that is empty: the reader exits non-zero rather than printing a healthy idle line, and return catch-up reports the failure as a blocker and leaves the records on disk instead of deleting escalations it never read.
That non-zero exit still carries a `re-arm to keep listening` verdict, because its records stay pending and nothing else is listening for them; only an argument error exits with no verdict, since re-arming the same bad invocation would loop without ever listening.
A read that failed only because the bounded outbox-lock acquire timed out is reported as its own condition, because that one is transient: a blocking reader stays alive, prints no status line, acknowledges nothing, and retries on its next poll, and only after `FM_AFK_INBOX_LOCK_TIMEOUT_MAX` consecutive timeouts does it exit non-zero naming the lock it could not acquire.
Return catch-up gets a single pass and then clears the outbox, so it treats that same timeout as a blocker exactly like any other failed read.
Because appending to the outbox always succeeds, the pane path's max-defer wedge alarm cannot detect a stall here, so the daemon raises that same alarm from the age of the oldest unacknowledged record when it exceeds `FM_MAX_DEFER_SECS`, and clears it once the reader has acknowledged everything.
That alarm also requires the reader's liveness beacon to be absent or stale, because age alone cannot tell a reader that was never armed from a firstmate that is armed and simply mid-turn, and agent turns longer than the max-defer window are routine.
The reader stamps `.afk-inbox.beat` when it arms, on every poll iteration, and on every acknowledgement, and `FM_AFK_INBOX_BEACON_STALE_SECS` sets how stale it must be.
Its default is twice `FM_MAX_DEFER_SECS` (600 seconds at defaults; an invalid or zero value uses that derived default) because the window it must survive is one firstmate turn rather than one poll interval: the reader exits as soon as it delivers, so nothing stamps the beacon while firstmate processes the digests and only re-arms it at the end of that turn.
A reader that is never re-armed, or a firstmate that died, is therefore still reported within that window of its last sign of life rather than silently, and raising `FM_MAX_DEFER_SECS` instead is the wrong fix because that trades the false alarm for a silent gap.
An alarm whose own inbox read then finds every record already acknowledged records that recovery in the daemon log only, raising no alert and writing no wedge marker, because that marker means wedged to every consumer that surfaces it; an inbox that could not be read still alarms.
A read that cannot even look into `state/` is a failed read too, not an empty outbox, so an untraversable state directory blocks the reader and return catch-up rather than reading as nothing pending.
A paneless away home therefore depends on TWO live processes, and both must self-heal.
The daemon appends escalations, and the reader delivers them into a firstmate turn; either one dying alone leaves away supervision silent.
The daemon's own death is healed at session start by `afk_daemon_revive_sweep` under the persist intent below.
A dead reader is self-concealing, because reviving it requires the very firstmate turn its own delivery would have started, so the incident on 2026-07-30 left nine escalations unread for over eleven hours while the daemon kept working.
The resilient arm wrapper [`bin/fm-afk-inbox-arm.sh`](../bin/fm-afk-inbox-arm.sh) shrinks that window at the source: the reader is resident rather than idle-exiting every hour, and a reader crash is relaunched in-process rather than waiting for a firstmate turn, so the only remaining re-arm point is an actual delivery and the outer nets below are the belt-and-suspenders for the wrapper process itself being reaped.
Two independent paths close that loop.
The daemon's undelivered-escalation alarm above wakes a human through the active-alert channel and the durable wedge marker.
[`bin/fm-afk-reader-check.sh`](../bin/fm-afk-reader-check.sh) gives the next firstmate turn a machine-readable instruction instead: session start runs it as `afk_reader_revive_sweep` ([`bin/fm-bootstrap.sh`](../bin/fm-bootstrap.sh)) and prints one `AFK_READER:` line when away mode is active, delivery is paneless, this home's daemon is confidently live, the beacon is stale beyond the shared window, and records are genuinely waiting; a home whose daemon is gone is left to the revive sweep instead, so the report never points a session at the wrong subsystem.
That check is a detector and never starts a reader itself, because the reader acknowledges every record it prints, so a reader started outside the harness would consume the captain's escalations to a stdout nobody reads.
The [`afk`](../.agents/skills/afk/SKILL.md) skill owns the operating procedure.

A paneless home hosts the daemon durably in a detached tmux session through `bin/fm-afk-launch.sh start-paneless`, which forces `FM_AFK_DELIVERY=paneless` so the daemon selects pull delivery unconditionally rather than discovering the tmux pane it is itself hosted in.
tmux is present as the runtime backend even though a paneless firstmate runs outside it, so a detached tmux session is a session-independent host that outlives a firstmate session turnover; the older `start-native` path hosted the daemon as a harness-native background job that was a child of the firstmate session and was reaped on turnover, silently taking away supervision down (evidence 2026-07-26).
The daemon owns `bin/fm-watch.sh` as its child, so hosting the daemon durably makes the watcher durable too.

### Away-mode autonomous queue advancement

Escalation is a notification: the daemon tells firstmate what to drive, and firstmate's own agent turn does the driving.
While the captain is away there may be no firstmate turn for hours, and on 2026-07-30 the fleet coasted roughly 9.5 hours even though every escalation was correct.
[`bin/fm-afk-driver.sh`](../bin/fm-afk-driver.sh) closes that gap, and its header is the single owner of what one tick does, the dispatch-recipe format it requires, and the safety boundaries it keeps.
The daemon's housekeeping runs one bounded tick per cadence while `state/.afk` is present, wrapped so a driver failure or overrun is logged and supervision continues.
The knobs this file owns are `FM_AFK_DRIVER_TICK_SECS` (cadence, default 600 seconds; `0` switches the hook off for a home without changing anything else about away mode), `FM_AFK_DRIVER_TIMEOUT_SECS` (maximum seconds for one tick, default 300), `FM_AFK_DRIVER_MAX_WORKERS` (worker cap below its hard maximum of 4), and `FM_AFK_DRIVER_DISABLE=1` (refuse every tick for this home).

## Away-mode persist intent (state/.afk-persist)

`state/.afk-persist` is the durable, machine-readable record that the captain ordered away supervision to survive a session turnover, distinct from the session-operational `state/.afk` flag.
[`bin/fm-afk-launch.sh`](../bin/fm-afk-launch.sh) owns it: `persist` sets it and enters durable paneless away mode, and `unpersist` is the only path that clears it - the explicit-return flow ([`bin/fm-afk-return.sh`](../bin/fm-afk-return.sh)) deliberately does not, so a turnover during a still-standing away order resumes supervision rather than dropping it.
It is not a session-scoped delivery artifact, so a fresh away entry never clears it.
While it is set and no live daemon owns the home, the session-start revive sweep ([`bin/fm-bootstrap.sh`](../bin/fm-bootstrap.sh) `afk_daemon_revive_sweep`) re-enters durable paneless away mode automatically, reporting only a revive failure as an `AFK_DAEMON:` line.
Plain `/afk` without `persist` keeps its single-session auto-exit behavior.

## Away-mode wedge alarm channels (config/wedge-alarm)

When away-mode injection wedges past `FM_MAX_DEFER_SECS`, the sub-supervisor raises a loud, rate-limited alarm.
Beyond the durable `state/.subsuper-inject-wedged` marker and the tmux status-line flash, it attempts a configured backend-independent active alert that can reach the captain even when every pane and its backend status-line is unreadable.
`config/wedge-alarm` (local, gitignored) lists channel directives, one per non-empty, non-comment line; every listed non-`off` channel fires, best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with a single directive.
Directives are `off` (a position-independent kill switch that disables every active alert), `auto`/`default`, `osascript` (macOS Notification Center banner), `notify-send` (Linux libnotify desktop banner), `herdr` (herdr UI notification), and `command:<cmd>` (run `<cmd>` via `sh -c`, summary on `$1` and stdin).
An absent file means `auto`, i.e. default-on on a desktop macOS or Linux host: macOS resolves to `osascript` and Linux to `notify-send` when that binary is present, so the alarm exists precisely so a wedged away-mode primary is never silent, and it fires at most once per max-defer window after a genuine wedge.
A missing or failing channel logs and falls through to the next, never crashing the daemon.
See [`wedge-alarm.md`](wedge-alarm.md) for the channel reference and macOS verification evidence, and [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## Present-mode supervision daemon (config/present-daemon)

The watcher is single-shot on an actionable wake, so an active session normally pays a per-turn tax to re-arm it and wait for that arm to confirm.
The optional local `config/present-daemon` presence flag moves that re-arm loop off the session and into `bin/fm-present-daemon.sh`, a small detached background process that runs `bin/fm-watch-arm.sh` again whenever a watcher cycle ends.
The feature is inert without the flag: nothing launches, and supervision behaves exactly as it did before.
The file's contents are ignored; only its presence matters.
It is not inherited into secondmate homes, because a secondmate is idle by default and pays no per-turn supervision tax.

The daemon only keeps a watcher alive.
It never classifies a wake, decides anything, or acts on a finding, and it changes no approval authority: every wake stays in `state/.wake-queue` for firstmate to drain at the top of its next turn.
That is the line separating it from the away-mode sub-supervisor, which does own triage and escalation.

Session start launches it when this session actually holds the fleet lock, through `bin/fm-bootstrap.sh`'s `present_daemon_sweep`, and only a real launch failure prints an actionable `PRESENT_DAEMON:` line.
While the daemon is live, `bin/fm-supervision-instructions.sh` reports it in the emitted supervision block and tells firstmate not to arm per turn; the wake queue must still be drained at the top of every turn.

Never-blind is unchanged.
The daemon touches neither guard and never touches the session lock `state/.lock`; it holds only its own `state/.present-daemon.lock` while its watcher child holds `state/.watch.lock`.
If the daemon dies, its orphaned watcher ends on the next actionable wake, the beacon ages past the guard grace, and `bin/fm-turnend-guard.sh` fires its normal alarm, so the session degrades to per-turn arming rather than to blind supervision.

Away mode and present mode never supervise concurrently.
The daemon refuses to start while `state/.afk` exists, `bin/fm-afk-start.sh` stops it before the away daemon takes over, and a running loop re-checks the flag between arm cycles.
Because away entry stops it, `bin/fm-afk-return.sh` restarts it on return, once the away daemon is confirmed stopped, so an in-session away-return does not leave supervision without a beacon re-arm engine until the next session start (the 2026-08-12 blackout, where the watcher beacon went dark past grace three times in one hour after a same-session return).

### Pane-wake (config/present-daemon-pane-wake)

Keeping a watcher armed is enough on claude and grok, where a background task's completion re-drives the model by default, so the arm-task completion itself wakes an idle session.
It is not enough on jcode: a jcode background task defaults to a passive notification that does not wake an idle model, and the wake flag can only be set from the model's own `bg` call, not from any script (`docs/jcode-wake-adapter.md`, `docs/jcode-primary-supervision.md`).
A silently re-armed watcher therefore cannot wake an idle jcode session.

Pane-wake closes that gap: when enabled, the daemon ALSO injects one short wake line into firstmate's own supervisor pane on each actionable watcher cycle, which jcode always re-drives on, exactly as the away-mode sub-supervisor already injects escalations.
It reuses that daemon's shared primitives: `bin/fm-supervisor-target-lib.sh` resolves the pane once at startup, and `bin/fm-backend.sh` supplies the busy-guard, the confirmed-empty-composer guard, and the verify-retry submit, so a nudge never lands in a busy pane mid-turn, in a non-empty composer, or in a dead shell.
The wake is already durably queued by the watcher, so a deferred nudge is fine and the next actionable cycle retries.

On herdr the resolved pane target is not stable: herdr can reassign a session's pane id under the same live tab (the `HERDR_PANE_ID` drift), which silently froze a startup-resolved target so every cycle logged `target gone; skipping` and never woke the model while the watcher stayed armed and the beacon stayed fresh (incident: `data/fix-present-daemon-stale-pane-wake-target`).
The daemon therefore captures the stable owning tab identity (`fm_backend_herdr_pane_tab_identity`) at resolve time and, before each inject, re-resolves the current pane for that tab when the recorded pane has gone (`fm_backend_herdr_target_for_tab_identity`), waking the new pane instead of skipping.
Only a genuinely closed tab (firstmate's own pane gone) makes an inject skip, and tmux pane ids are stable so they pass through unchanged.

Pane-wake is enabled when the local, gitignored `config/present-daemon-pane-wake` flag is present (its contents are ignored unless the first non-empty, non-comment line is `off`, which force-disables it), OR automatically when firstmate's own harness is jcode.
claude and grok stay on the silent-re-arm path unless the flag forces pane-wake on.
Supported supervisor backends are tmux and herdr only; an unsupported backend, or a pane that does not positively resolve (only the legacy `firstmate:0` fallback remained), degrades silently to today's silent-re-arm behavior rather than blocking supervision or typing into an unrelated pane.
Pane-wake never runs in away mode, where the away daemon owns the pane; the existing away-mode interlock already guarantees this.
It is not inherited into secondmate homes, for the same reason the present daemon is not.

`bin/fm-present-daemon.sh --help` owns the subcommands, the exact status lines, and the `FM_PRESENT_*` tuning knobs.

## External liveness watchdog (config/liveness-watchdog)

Where the present daemon keeps a watcher armed while the primary is HEALTHY, the external liveness watchdog (`bin/fm-liveness-watchdog.sh`) is for when the primary DIES.
The hosted primary runs its watcher as a child of its own agent process, so a primary death for any reason takes the watcher with it and the fleet sits silent until a human attaches (incident: `data/scout-overnight-turnover-while-captain-asleep/report.md`).
The watchdog runs a loop OUTSIDE the agent process tree - detached via `setsid`, reparented to init, the same mechanism the present daemon uses - and watches durable state that survives the primary's death: `state/*.meta` for work in flight and `state/.last-watcher-beat` for watcher liveness.
When work is in flight but no watcher has beaten within the grace window, it re-wakes the primary's own supervisor pane AND writes a durable escalation.

There is no phone push on this home; the escalation is local and durable.
The watchdog records the primary's supervisor pane at session start into `state/.supervisor-target` (the detached loop inherits no herdr environment, so it cannot resolve the pane itself), then on a trigger reads that pane's liveness and acts: a live-but-idle pane gets an Enter nudge to re-drive its turn, a confidently dead shell gets a configured relaunch command run in the pane only if `config/liveness-resume` provides one, and a dead shell with no relaunch command or a home with no recorded pane gets a clean escalation.
The escalation is written to `state/.liveness-escalation` and surfaced two ways the captain sees on next attach: a prominent `LIVENESS_ESCALATION:` line at session start (both read-only and full modes; a lock-holding session clears it after surfacing, a read-only session leaves it for the lock holder) and a durable `check` wake.
Resume is capped per down-episode (`FM_LIVENESS_MAX_RESUMES`, default 3), then escalates instead of retrying forever.
Its stale-beacon signal also catches a wedged-but-alive primary as a secondary benefit: the Enter nudge is the right, safe action for a live-but-idle supervisor pane, and it never relaunches a client it read as alive.

The feature is inert without the local `config/liveness-watchdog` presence flag.
It stands down under away mode, which already hosts a session-independent watcher through its own durable daemon.
Session start launches it when this session holds the fleet lock, through `bin/fm-bootstrap.sh`'s `liveness_watchdog_sweep`, which also re-records the supervisor pane and acks a surfaced escalation; only a real launch failure prints an actionable `LIVENESS_WATCHDOG:` line.
Session start is the natural relaunch point, because the failure the watchdog guards against also removes its own relaunch opportunity until a fresh session exists.

It is not inherited into secondmate homes, because a secondmate is idle by default and its supervision is the parent's concern.
`docs/liveness-watchdog.md` owns the full design, the `config/liveness-resume` relaunch command, the `FM_GUARD_GRACE` / `FM_LIVENESS_INTERVAL` / `FM_LIVENESS_MAX_RESUMES` knobs, and the verification record; `docs/examples/liveness-watchdog` carries a copyable relaunch example.

## Gate defaults (.no-mistakes.yaml)

The tracked `.no-mistakes.yaml` keeps test evidence outside the repo and pins `commands.lint` to `bin/fm-lint.sh` so local lint matches CI.
That evidence policy is specific to the firstmate repo: target projects may legitimately commit `.no-mistakes/evidence/` from their own no-mistakes pipeline, but firstmate keeps `.no-mistakes/` local and CI rejects tracked entries under that path.
It does not set `commands.test` to a complete `tests/*.test.sh` walk.
See [CONTRIBUTING.md](../CONTRIBUTING.md) for the firstmate-specific local test policy and entry points.
Portable shard evidence and coverage rules are in [fm-test-portable-shards.md](fm-test-portable-shards.md), and [herdr-backend.md](herdr-backend.md) owns the real-Herdr lane's verification and isolation rationale.

## Captain Preferences (data/captain.md / data/captain-shared.md)

Domain-local preferences for one captain's fleet live locally in each home's `data/captain.md`; it is gitignored and printed in the session-start context digest after `data/projects.md` and optional `data/secondmates.md`.
Before changing it, inspect the current file and rewrite or prune the matching bullet in place; add a new bullet only for a genuinely new durable preference.
A preference that a config file already owns is recorded as a pointer at that file, never as a restated value.
Prose binds only when an agent reads and obeys it, while a config file binds mechanically, so a second copy of a harness, model, effort level, ceiling, threshold, cadence, path, or retention count is pure drift risk: the two disagree the moment only one is edited, and the prose copy is what gets believed.
Keep the durable ruling in prose - what to prefer, what to escalate, what never to force - and keep the number in its config.
Shared captain preferences that apply across secondmate domains live only in the primary home's optional `data/captain-shared.md`.
`secondmate-provisioning` owns its propagation contract, including the required header, read-only secondmate copies, quarantine diagnostics, and the rollout rule that existing homes trim `data/captain.md` by hand after first propagation rather than deleting private content automatically.

## Operational learnings (data/learnings.md)

Fleet-local operational facts and gotchas live locally in `data/learnings.md`; it is gitignored and printed after the captain-preference files in the session-start context digest.
The file is created lazily on first learning and follows the same dated, evidence-backed, curated style as `data/captain.md`: inspect the current file first, then rewrite or prune stale entries instead of appending forever.
There is no shared learnings file by captain decision.
The pointer-not-value rule from the captain-preference section above applies here too: a learning may record what a value WAS on a dated occasion as evidence, but the live value is always read from its config file.

## Session stats (data/session-stats.log)

`data/session-stats.log` is this home's append-only session history: one tab-separated `key=value` line per session closed through `bin/fm-end-session.sh`, whose header owns the exact field list.
It is gitignored like the rest of `data/`, and it is history rather than state, so records are never rewritten, reordered, or pruned.
Only durable identifiers and counts are recorded - no worktree paths, pane ids, or tool versions, which rot the moment the session ends.

Away-mode time in that record is deliberately incomplete.
`state/.afk` holds the epoch second away mode was entered, so a stretch still open when the session closes is measurable to the second and records as `away_source=open-flag`.
A stretch that already ended leaves no durable duration behind, because return clears the flag without recording how long it was held, so those sessions record `away_source=unrecorded` rather than an estimate.
Making cumulative away time recoverable would require away-mode entry and return to append a durable stretch ledger (entered and exited epochs per stretch); until they do, no consumer may infer total away time from this file.

## Secondmate routes (data/secondmates.md)

Persistent secondmate routes live locally in `data/secondmates.md`.
The concise single-line route contract is owned by the [`secondmate-provisioning` skill](../.agents/skills/secondmate-provisioning/SKILL.md#routing-table), including the parser-compatible fields, one-sentence summary requirement, `home:` pointer to the seeded charter, and limit on extra registry prose.
`fm-home-seed.sh validate` refuses duplicate ids, duplicate homes, and nested or overlapping homes.
The main first mate routes by reading those scopes with judgment; the project list is provisioning data, not exclusive ownership.
Use `fm-home-seed.sh <id> - {<project>...|--no-projects}` to lease a fresh firstmate worktree for the secondmate home.
Use the deliberate `--no-projects` signal only for a firstmate-repo domain that needs no separate project clones.
It cannot be combined with a project list, and omitting both still fails loudly.
A project-less seed requires no existing project clones or `data/projects.md` entries in the home, so it refuses a populated-home conversion without changing that home.
A preexisting project-bearing charter is also refused until it is re-scaffolded with `--no-projects` or removed.
The lease is held under the secondmate id until explicit retirement or seed rollback returns it, so normal restarts do not free or recycle the home.
Teardown of a leased home fails closed if `treehouse return` cannot release the lease; plain-clone homes with no treehouse pool slot are removed directly.
Secondmate routes cover remote-backed `no-mistakes`, `direct-PR`, and `direct-push` projects; `local-only` projects remain main-firstmate work.
For `no-mistakes` and `direct-push` projects, seeding initializes only projects newly cloned into a secondmate home and refuses to mutate a preexisting clone that is not already initialized.
That refusal aborts the whole seed transactionally, including for an uninitialized preexisting `direct-push` clone, so initialize that clone and reseed.
After creating a secondmate, move existing main-backlog queued items that you have judged in-scope with `fm-backlog-handoff.sh <secondmate-id> <item-key>...`; it is idempotent and refuses In flight, Done, or non-secondmate homes.
Set `FM_SECONDMATE_CHARTER` to seed from inline charter text when no filled charter brief exists; set `FM_SECONDMATE_SCOPE` when the routing scope should differ from the charter text.
The seeded home's `data/charter.md` owns the standard secondmate lifecycle and escalation contract; the route file points to it through the existing `home:` field instead of adding another pointer.
Each seed writes an `.fm-secondmate-home` identity marker at the home root.
The tracked root `.gitignore` ignores that marker, so validation can read it without making a freshly seeded home appear dirty to porcelain-based safety checks.
This does not relax protection for any other untracked file.
An existing linked-worktree home that predates this rule advances through its marker-only state during its next bootstrap or spawn local sync, after which Git ignores the marker normally.
A standalone-clone home cannot receive a primary-local commit through that no-fetch sync, so it receives the rule through `/updatefirstmate`'s origin refresh instead.

## FM_HOME

`FM_HOME` selects the operational home for one firstmate instance.
When it is unset, most scripts use the repo root as the home; when it is set, scripts still run from this repo's `bin/`, but `state/`, `data/`, `config/`, and `projects/` come from `$FM_HOME`.
`FM_ROOT_OVERRIDE` overrides the firstmate repo root used by scripts, including the primary checkout watched by the worktree-tangle guard.
When `FM_HOME` is unset, it also behaves as the old whole-root override.
`bin/fm-send.sh` is intentionally stricter than that general fallback: it requires `FM_HOME` unless the current directory is itself a valid firstmate home (data/, state/, config/ and AGENTS.md present), so operator steers cannot silently resolve against the wrong home.
`FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, and `FM_CONFIG_OVERRIDE` override individual operational directories for tests and specialized harness setup.
For the herdr backend, `FM_HOME` also determines the workspace label used by the adapter.
For the zellij backend, `FM_HOME` does not split containers, but it determines the readable home prefix embedded in visible tab titles; use `FM_ZELLIJ_SESSION` when a separate zellij session is needed.
The full zellij home label also includes a short hash of the resolved `FM_ROOT` path.
For the cmux backend, `FM_CONFIG_OVERRIDE` overrides where `config/cmux-socket-password` is read from, while `FM_HOME` determines the default config path and readable home prefix embedded in workspace titles.
The full cmux home label also includes a short hash of the resolved `FM_ROOT` path, and there is no per-home container split.

## Harness support

claude, codex, opencode, pi, and grok are all empirically verified; new harnesses get verified through a supervised trial task before joining the set.
The verified adapter knowledge - busy signatures, interrupt and exit commands, skill-invocation syntax, and per-harness quirks - lives in [`.agents/skills/harness-adapters/SKILL.md`](../.agents/skills/harness-adapters/SKILL.md).
Launch mechanics, including the verified command templates, live in [`bin/fm-spawn.sh`](../bin/fm-spawn.sh).
Primary-session turn-end guard integrations for verified harnesses are tracked as repo-level hook files and documented in [`docs/turnend-guard.md`](turnend-guard.md).
Primary-session watcher wake protocols are rendered at session start by [`bin/fm-supervision-instructions.sh`](../bin/fm-supervision-instructions.sh) from [`docs/supervision-protocols/`](supervision-protocols/).
Claude and Grok use background-notify cycles, Codex uses bounded foreground checkpoints, Pi uses its two tracked primary extensions, and OpenCode uses its TUI plugin.
`config/crew-harness` is a local, gitignored file containing one adapter name for crewmate and scout launches.
When it is absent or contains `default`, crewmates mirror the firstmate's own harness.
`config/secondmate-harness` is a separate local, gitignored file containing the adapter the primary uses to launch secondmate agents, optionally followed by model and effort tokens on the same line.
Each non-empty, non-comment line is either a single-line default `<harness> [<model>] [<effort>]` or a per-id pin `<id>: <harness> [<model>] [<effort>]` that binds one secondmate id, letting different secondmates run on different harness, model, and effort.
A per-id line's first token is the secondmate id followed by a colon; every other line is the default line.
Resolution for a given secondmate is line-level: the first matching per-id line wins, otherwise the single default line applies, otherwise the fallback chain below.
A bare `<harness>` default line preserves the previous behavior: harness only, with no model or effort launch flag, applied to every secondmate that has no per-id line.
When the resolved harness token is absent or `default`, secondmate launch falls back through `config/crew-harness` and then the primary's own harness, and no model or effort is read from that file.
`fm-harness.sh secondmate`, `fm-harness.sh secondmate-model`, and `fm-harness.sh secondmate-effort` each take an optional secondmate id and resolve the per-id pin before the default line; the resolver header owns the exact line grammar and precedence.
`fm-spawn.sh --secondmate` passes the spawning secondmate's id so a pin binds at launch and re-resolves on every respawn.
`config/crew-harness` remains a bare adapter-name file.
An explicit harness argument to `fm-spawn.sh` still overrides either config file for that spawn only.
An explicit `--model` or `--effort` overrides the matching token from `config/secondmate-harness`; an explicit harness or raw launch command starts with clean model and effort defaults unless those flags are also passed.
When `config/crew-dispatch.json` exists, crewmate and scout spawns require an explicit resolved harness instead of automatically falling back to `config/crew-harness`.
The inherited-local-material contract is owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md); its harness-relevant consequence is that a secondmate's own crewmates use the primary's dispatch profiles and static harness value.
Those inherited values are defaults and rules only; `fm-spawn` still permits a consciously chosen explicit runtime outside the config.
`config/secondmate-harness` is not inherited because secondmates do not launch secondmates.
For grok, `fm-spawn.sh` installs one firstmate-owned global turn-end hook under `$GROK_HOME/hooks/`, or `~/.grok/hooks/` when `GROK_HOME` is unset, and drops a per-task `.fm-grok-turnend` pointer in the worktree, with teardown removing the task token and pointer.
For Pi secondmate launches, `fm-spawn.sh` starts Pi with `-e` pointed at the secondmate home's own tracked `.pi/extensions/fm-primary-pi-watch.ts` and `.pi/extensions/fm-primary-turnend-guard.ts`, both already present from the secondmate home's git worktree.

## Secondmate context-handoff threshold (config/secondmate-context-threshold)

`config/secondmate-context-threshold` is an optional local, gitignored file holding a single positive integer: the context-window token count at which a live secondmate is handed off to a fresh agent instead of running `/compact`.
The first non-empty, non-comment line is parsed; an absent file, a non-integer, or a non-positive value falls back to the default `200000`, so a typo never silently disables the safety net.
`200000` is the point a 200k-window model reaches auto-compact; raise the knob for a larger-window model.
This is the primary's monitoring knob and is not inherited into secondmate homes, because secondmates do not spawn secondmates and so have nothing downstream that reads it.
The primary's watcher reads each live secondmate's usage on its slow-poll cadence (claude only; every other harness reads unknown and is skipped) and acts once when the count first crosses the threshold, either by waking firstmate to run the handoff by hand or, when automatic handoff is enabled below, by handing off automatically.
The read mechanism and the evidence behind the claude-only support live in [`docs/secondmate-context-handoff.md`](secondmate-context-handoff.md); the handoff procedure lives in the `secondmate-provisioning` skill; exact flags and paths live in the headers and `--help` of [`bin/fm-secondmate-context.sh`](../bin/fm-secondmate-context.sh) and [`bin/fm-secondmate-handoff.sh`](../bin/fm-secondmate-handoff.sh).

## Automatic secondmate context handoff (config/secondmate-auto-handoff)

`config/secondmate-auto-handoff` is an optional local, gitignored presence flag that opts this home into AUTOMATIC secondmate context handoff.
It is opt-in and fails closed by default: when the file is absent a threshold crossing only wakes the primary to run `bin/fm-secondmate-handoff.sh <id>` by hand, exactly as before.
When the file is present the watcher hands the crossed secondmate off automatically, with no primary wake needed to start it.
Presence is consent: an empty or comment-only file enables the feature; a file whose first non-empty, non-comment line is `off` force-disables it, so a mistakenly created flag can be neutralized without deleting it.
This is the primary's monitoring knob and is not inherited into secondmate homes, because secondmates do not spawn secondmates.
The default is fail-closed (escalate-only) rather than on-by-default deliberately: an automatic handoff replaces a live agent, so the captain enables it only after deciding this home should self-heal a context-full secondmate unattended.
Automatic handoff never widens any other authority: it hands off only an idle secondmate (never mid-turn), runs the same fail-closed, idempotent, work-preserving `bin/fm-secondmate-handoff.sh` sequence, respawns only through the guarded `bin/fm-spawn.sh <id> --secondmate` path, and always tells the primary after the fact.
The mechanism and its safety invariants live in [`docs/secondmate-context-handoff.md`](secondmate-context-handoff.md); exact flags, env, and the notification wording live in the header of [`bin/fm-secondmate-auto-handoff.sh`](../bin/fm-secondmate-auto-handoff.sh); the procedure lives in the `secondmate-provisioning` skill.

## Firstmate own-context stow threshold (config/context-stow-threshold)

`config/context-stow-threshold` is an optional local, gitignored file holding a single positive integer: the context-window token count at which firstmate is nudged to `/stow` now, and to `/compact` when the session cannot auto-compact, so knowledge is persisted before a context reset can lose it.
The first non-empty, non-comment line is parsed; an absent file, a non-integer, or a non-positive value falls back to the default `200000`, exactly like the secondmate threshold above, so a typo never silently disables the nudge.
This is a distinct knob from `config/secondmate-context-threshold`: that one decides when to hand a secondmate off to a fresh agent, this one decides when to tell firstmate to save its own knowledge.
Two supervision paths read the same knob and share one durable marker (`state/.context-stow-nudged`) and one crossing/directive owner (`fm_context_stow_should_nudge` and `fm_context_stow_directive` in [`bin/fm-secondmate-context-lib.sh`](../bin/fm-secondmate-context-lib.sh)), so they never double-nudge or drift across a mode switch.
During normal supervision the always-on watcher ([`bin/fm-watch.sh`](../bin/fm-watch.sh)'s `context_stow_sweep`) reads firstmate's own live context on its slow-poll (`FM_CHECK_INTERVAL`) cadence and, when the count first crosses the threshold, wakes firstmate once with `check: context-stow-nudge` carrying the self-executing directive to `/stow` now, then `/compact`, then re-arm supervision, before auto-compaction can discard un-stowed knowledge; it only nudges and never runs `/stow` or `/compact` itself, because a stow needs firstmate's judgment about where each durable fact belongs and an auto-fired bare compact would summarize away un-stowed knowledge.
While a live away-mode daemon owns supervision the watcher sweep stays out, and the daemon ([`bin/fm-supervise-daemon.sh`](../bin/fm-supervise-daemon.sh)'s `context_stow_check`) instead reads on the `FM_CONTEXT_STOW_CHECK_SECS` cadence (default `120`; `0` disables the check) and injects the same nudge through the away-supervisor path, so firstmate recognizes it as an operational nudge rather than captain input.
This is the interim enforcement while the structural turn-end backstop (`enforce-stow-at-turnend-guard`) stays blocked on an unbuilt jcode turn-end hook.
The nudge fires once per crossing and re-arms only after the count drops back below `threshold - FM_CONTEXT_STOW_HYSTERESIS` (default hysteresis `20000`, owned by `bin/fm-secondmate-context-lib.sh` and shared by both paths), which a fresh or compacted session does, so a count hovering at the line cannot re-nudge every tick.
The read is claude/jcode-capable, using the same per-harness readers the secondmate monitor uses (claude and jcode each have their own; see docs/secondmate-context-handoff.md); it fails closed, so on any other harness or any unreadable count neither path ever nudges.
The `200000` default sits at the point a 200k-window session reaches auto-compaction, so the nudge fires before that reset can silently discard un-stowed knowledge; raise the knob for a larger-window model.
This knob is not inherited into secondmate homes: it governs firstmate's own session, and a secondmate that fills its context is handed off to a fresh agent through `config/secondmate-context-threshold` rather than nudged to stow.
The read mechanism and the jcode evidence live in [`docs/secondmate-context-handoff.md`](secondmate-context-handoff.md); the crossing logic, the cadence, and the `FM_CONTEXT_STOW_*` knobs live in the header of [`bin/fm-supervise-daemon.sh`](../bin/fm-supervise-daemon.sh) and the `context_stow_sweep` comment in [`bin/fm-watch.sh`](../bin/fm-watch.sh); the `/afk` skill's "Classification policy" points here for the contract.

## Host resource monitoring (FM_RESOURCE_INTERVAL)

`FM_RESOURCE_INTERVAL` is the number of seconds between host CPU, memory, and swap sweeps, defaulting to `900`.
`0` switches host-resource monitoring off for this home, and a malformed value falls back to the default rather than silently disabling the monitor.
This section is the single owner of that knob; [`bin/fm-resource-check.sh`](../bin/fm-resource-check.sh)'s header and `--help` own the thresholds, the recommended-ceiling formula, the exit statuses, and the `FM_RESOURCE_*` test-injection seam.

The cadence is deliberately separate from the watcher poll cadence (`FM_POLL`) and the slow-check cadence (`FM_CHECK_INTERVAL`).
Host pressure changes on a scale of minutes, so re-reading it every poll would be pure waste, and tying it to the slow-check sweep would couple it to a cadence X mode drives down to seconds.
`bin/fm-watch.sh` reads the resolved interval once at process start, the same way it fixes every other cadence for the watcher's lifetime, so a change takes effect at the next watcher cycle.

Readings are kernel-wide, taken from `sysctl` and `vm_stat` on macOS and from `/proc` on Linux, never by enumerating processes.
Firstmate's own `ps` view is sandboxed to a small subset of the host, so summing per-process usage would silently under-report a loaded machine.
For the same reason the reading is a host total and never attributes load to a particular crew.
The crew count in the reading is the number of crews whose agent is actually running, not the number of recorded tasks, so a task that has stopped but has not been cleaned up yet no longer inflates the count or the shed advice.
Only the watcher's sweep pays for that liveness answer, and it caches the verdict, so the count every other caller shows is at most two sweep intervals old (`FM_RESOURCE_INTERVAL`, default 900 seconds, so 1800 seconds at the default).
Two intervals rather than one is deliberate: the watcher exits on every wake and is re-armed, so a home between arms routinely has no sweep running while the other callers keep reading the cache.
When no cached verdict is available, or it is older than that, the reading falls back to the count of recorded tasks and says so with "liveness unverified" instead of presenting it as a verified count.
The ceiling's memory component allows one active agent per 640 MB of available memory.
That figure is measured rather than assumed: the 2026-07-24 measurement recorded in `data/measure-ccstatusline-cost/report.md` puts a working agent at 394-491 MB resident and an idle one at roughly 290 MB decaying toward 180 MB over hours of genuine inactivity.
It replaced an earlier 1024 MB per agent, which over-charged even a working agent and over-charged an idle one by around 3.5 times.
640 MB sits about 30 percent above the top of the measured working range, the conservative choice the report's own caveat asks for, since it measured never-prompted sessions and so treats 290 MB as a floor that context size moves upward.

A persistent secondmate whose own home has no routed work in flight is idle, and by the captain's ruling of 2026-07-24 an idle secondmate is charged nothing: it counts toward neither the ceiling's memory component, nor its processor component, nor the overage that produces shed advice.
The measurement is what justifies that: idle agents changed the host's load average by -0.11 and its swap by -239 MB while five were added.
A working secondmate is charged exactly like an ordinary crew.
Idleness is decided from files alone, by looking for recorded tasks under the secondmate's own home, so the synchronous callers still never touch a backend, and a secondmate whose home cannot be read is charged as active rather than silently discounted.
Nothing disappears from the reading by ceasing to be charged: the line names the all-agents total, then the active figure the ceiling and overage are measured on, then the crew and secondmate breakdown, and labels the ceiling in active agents.
The number of crews the shed advice names is still capped at the ordinary crews, because AGENTS.md makes an idle secondmate endpoint healthy and its retirement an explicit decision, so a home whose only running agents are persistent secondmates never gets shed advice.

`FM_RESOURCE_SWEEP_BUDGET` is the number of seconds one sweep may spend checking crew liveness in total, defaulting to `30`, and `0` or a malformed value falls back to that default rather than disabling the budget.
It bounds the watcher's poll loop however many crews are recorded and however unresponsive a backend is, since bounding each check on its own would still allow one timeout per recorded crew.
A check started near the deadline gets only the time the budget has left, so the worst case is the budget plus a sub-second stop grace rather than the budget plus one whole per-check timeout.
Crews left unchecked when the budget runs out count toward the live total anyway, the same conservative direction an unanswered check already takes, and the reading says "liveness partly unverified" so a partly checked count is never shown as a fully verified one.
That marker is cached with the count, so a partly checked count keeps the same label on the later synchronous readings that reuse it.
`FM_RESOURCE_PROBE_TIMEOUT` bounds each individual crew-liveness check inside that budget, defaulting to `5`, with the same fallback for `0` or a malformed value; each check is terminated as a process group, so a wedged backend leaves no stuck process behind.

The probe process that runs the sweep is bounded and serialized so a wedged backend can never take the host down, the failure mode recorded in the `20260823T031739Z-home-oom-fm-resource-probe-runaway` incident.
The probe concurrency lock is host-global: it lives at `${TMPDIR:-/tmp}/fm-resource-probe-<uid>.lock` (one per operating user), so a fleet running several homes and a treehouse spreading one home across several worktrees still run exactly one probe at a time on the host, rather than N simultaneous heavy sweeps.
A home that loses the race defers and keeps its previous cached reading, well within the two-interval freshness window every consumer already tolerates.
`FM_RESOURCE_PROBE_LOCK` overrides the lock path (a test seam, and the way to scope a lock to something narrower than the whole host); `bin/fm-resource-probe.sh --lock-path` prints the resolved path, which is how the watcher consults it.
`FM_RESOURCE_PROBE_MEM_MB` is a hard address-space ceiling (`ulimit -v`) set on the probe and inherited by the sweep and every backend CLI it forks, defaulting to `1024` MiB, with `0` or a malformed value disabling it; a healthy probe costs single-digit MB and a herdr query tens of MB, so the default is a wide margin that still kills a genuine runaway before it can OOM a swapless host.
`FM_RESOURCE_PROBE_MAX_BYTES` truncates the sweep output the probe reads into a shell variable, defaulting to `1048576` bytes, with `0` or a malformed value disabling it, so a backend dumping a huge stream cannot inflate the probe through the command capture itself.
The probe also renices itself to `19` and drops to the idle I/O class (best-effort, no privilege required) before any work, so a probe that is slow under load yields CPU and disk to interactive work such as an ssh login rather than queuing ahead of it.

`FM_RESOURCE_SWEEP_BUDGET` is the number of seconds one sweep may spend checking crew liveness in total, defaulting to `30`, and a malformed value falls back to that default rather than disabling the budget.
It bounds the watcher's poll loop however many crews are recorded and however unresponsive a backend is, since bounding each check on its own would still allow one timeout per recorded crew.
Crews left unchecked when the budget runs out count toward the live total anyway, the same conservative direction an unanswered check already takes, and the reading says "liveness partly unverified" so a partly checked count is never shown as a fully verified one.

Three callers consult the monitor, and all three only report:

- [`bin/fm-spawn.sh`](../bin/fm-spawn.sh) prints the reading to stderr as a pre-dispatch `warning:` advisory when the host is degraded or critical, and still spawns.
  It reads the cached crew-liveness verdict and never probes a backend, so an unresponsive backend cannot delay a dispatch.
- [`bin/fm-watch.sh`](../bin/fm-watch.sh) sweeps on this cadence and wakes firstmate with `check: host-resources <reading>` when pressure first gets worse than the level firstmate was last told about, and annotates a heartbeat with the last cached reading while the monitor is enabled and that reading is still recent.
  A sweep that cannot read the host leaves the last known level in place rather than clearing it, so pressure on a machine whose probes stopped answering is not silently dropped, and the same recency gate bounds how long that annotation can survive.
- [`bin/fm-session-start.sh`](../bin/fm-session-start.sh) prints one reading in the fleet-state digest, so a session opens knowing whether the machine can take more work.
  It reads the same cached verdict, so the digest stays fast and bounded whatever the backends are doing.

Nothing in this path pauses, sheds, or kills anything.
Shedding load is the captain's decision, so the monitor's job ends at reporting the pressure and the crew count the host can support.
An unknown reading, on a host where no kernel-wide probe answers, and a disabled monitor both stay silent instead of alarming, the same never-wake-on-an-unreadable-probe rule the secondmate context monitor follows.

The watcher keeps its sweep state in `state/.last-resource` (sweep cadence), `state/.resource-status` (latest reading, read by the heartbeat annotation), `state/.resource-live` (last running-agent counts, split into crews, working secondmates and idle secondmates, plus whether the sweep could check them all, read by the synchronous callers), and `state/.resource-surfaced` (worst level already reported, so recovery to healthy re-arms the monitor silently).
These are watcher internals; never edit them by hand.

## Hourly session passes (FM_HOURLY_REVIEW_INTERVAL / FM_HOURLY_CLEANUP_INTERVAL)

Every session start arms two recurring passes that then run for the life of the session: an hourly session review and an hourly cleanup sweep.
[`bin/fm-session-start.sh`](../bin/fm-session-start.sh) arms them, [`bin/fm-hourly-lib.sh`](../bin/fm-hourly-lib.sh) owns the arming, cadence, and suppression contract, and the two pass scripts own what they look at.

Arming writes durable schedule state only.
The one live watcher runs a due pass on its existing slow poll and wakes firstmate with `check: session-review <headline>` or `check: session-cleanup <headline>`, so no second supervision cycle and no extra timer exists.
Arming is a mutating step, so a read-only session (one that did not acquire the home's session lock) leaves it to the session holding the lock, and an unarmed home never runs a pass at all.
Arming is idempotent and creates a cadence stamp only when it is absent, so elapsed time survives a session restart and a home whose sessions restart faster than the interval still runs its passes.

Both passes are silent unless they have something the fleet has not already been told about.
The session review reports only what has not moved - an open decision nobody has answered, a worker that has posted nothing for hours, queued work with nothing running, a batch of finished-but-unmerged branches - because a point-in-time fleet review is what the watcher heartbeat already provides.
It also surfaces any repo whose skipped-doc/lint batch has grown big enough for a batched document+lint recovery pass, one actionable line per repo carrying the dispatch command; see [doclint-batch.md](doclint-batch.md).
A queued item that is blocked by another item or captain-held is not dispatchable, so it never counts toward the idle-capacity finding.
Both passes ignore a persistent secondmate's record, which is idle by contract, so it neither counts as work under way nor reads as a stalled worker.
The cleanup sweep silently reclaims bookkeeping that can hold no work (watcher temp residue, suppression markers for a fleet that no longer exists) and reports without removing anything that could hold unlanded work, leaving [`bin/fm-teardown.sh`](../bin/fm-teardown.sh) the single owner of the landed-work test.
It never writes into a project clone and never touches the network, so the merge queue is swept only by firstmate's own [`bin/fm-merge-queue.sh`](../bin/fm-merge-queue.sh) run, and per-task temp roots under a shared `/tmp` are not scanned at all because they carry no reliable home ownership.
A finding surfaces once and stays silent while it is unchanged; an emptied finding set re-arms the report silently, the same shape the host-resource monitor uses.

`FM_HOURLY_REVIEW_INTERVAL` and `FM_HOURLY_CLEANUP_INTERVAL` are the seconds between runs of each pass, both defaulting to `3600`.
`0` disables that pass for this home, and a malformed value falls back to the default rather than silently disabling it.
The thresholds each pass applies (`FM_REVIEW_DECISION_SECS`, `FM_REVIEW_STALL_SECS`, `FM_REVIEW_MERGE_BATCH`, `FM_CLEANUP_TEMP_SECS`, `FM_CLEANUP_MARKER_SECS`, `FM_CLEANUP_ORPHAN_SECS`) are owned by the two script headers.

State lives in `state/.hourly-armed` (armed for this session), `state/.last-hourly-review` and `state/.last-hourly-cleanup` (cadence stamps), `state/.hourly-review-surfaced` and `state/.hourly-cleanup-surfaced` (what has already been reported), `state/.hourly-review.latest` and `state/.hourly-cleanup.latest` (the full report behind each one-line headline), and `state/.hourly-decision-<id>__<key>` (when an open decision was first seen, so a later unrelated status append cannot reset its age), and `state/.hourly-cleanup.log` (what the cleanup sweep reclaimed, size-capped like the watcher's triage log).
These are watcher internals; never edit them by hand.

## Crew dispatch profiles (config/crew-dispatch.json)

`config/crew-dispatch.json` is an optional local, gitignored file containing natural-language rules that firstmate reads before dispatching a crewmate or scout.
The shell scripts do not match those rules; firstmate chooses the best matching rule with judgment, resolves that rule directly or through a supported selector, and passes only concrete `--harness`, `--model`, and `--effort` flags to `fm-spawn.sh`.
When the file exists, `fm-spawn.sh` enforces that contract by refusing crewmate and scout spawns that lack an explicit harness (`--harness`, a positional adapter, or a raw launch command).
Batch spawns satisfy the same requirement with a shared `--harness`.
Secondmate spawns are exempt and still resolve through `config/secondmate-harness` and its optional model and effort tokens.
This section is the single owner of the canonical schema and its per-field semantics; `AGENTS.md` section 4 keeps only the dispatch procedure and points here.

```json
{
  "rules": [
    {
      "when": "<natural-language condition describing a kind of task>",
      "use": [
        { "harness": "<adapter>", "model": "<optional model>", "effort": "<low|medium|high|xhigh|max, optional>" }
      ],
      "select": "<optional strategy>",
      "why": "<optional rationale that helps firstmate choose>"
    }
  ],
  "default": [
    { "harness": "<adapter>", "model": "<optional model>", "effort": "<optional effort>" }
  ]
}
```

Per rule, `when` and `use` are required.
Both `use` and the optional top-level `default` accept either one profile object or a non-empty array of profile objects.
The single-object form stays fully backward-compatible, and every profile needs `harness`.
Profile `model` and `effort` fields and rule `why` are optional.
An omitted model or effort means the selected harness uses its own default for that axis.
Every profile array is an implicit quota-aware choice and does not need a selector property.
`select: "quota-balanced"` remains accepted on rules for compatibility and has the same behavior as an implicit array choice.
If no dispatch rule fits, firstmate resolves `default` through the same object-or-array selection path before falling back to `config/crew-harness`.
If a selected profile carries an effort value the chosen harness does not accept, `fm-spawn.sh` records the requested `effort=` in task meta for traceability but omits the launch flag, and bootstrap reports the invalid harness/effort pair as a `CREW_DISPATCH` diagnostic when it is visible in the file.
Quota-aware selection is implemented by `bin/fm-dispatch-select.sh`, whose header owns provider and product mapping, relevant-window scoring, the stale-clear freshness margin, random tie-breaking, OS-backed random operational fallback, and safe selection-basis diagnostics.
Quota-data trouble never blocks dispatch, but malformed profile configuration remains an actionable validation error.
See [`docs/examples/crew-dispatch.json`](examples/crew-dispatch.json) for a starting point to copy into local `config/crew-dispatch.json`.
When the file exists, bootstrap validates it with `jq`.
Valid files stay silent by default; with `FM_BOOTSTRAP_VERBOSE_FACTS=1`, bootstrap emits `BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json`, one `BOOTSTRAP_INFO:` fact per rule, and one fact for the optional default profile set.
Malformed JSON, an empty or malformed rule/default array, an unverified harness, an unknown `select`, or an effort value unsupported by that harness is reported as `CREW_DISPATCH: invalid config/crew-dispatch.json - ...`; missing `jq` is reported through the normal `MISSING: jq` install-consent flow.
Because the spawn backstop is gated by file presence, any fallback path after a missing match, validation error, or missing `jq` still passes a resolved harness explicitly until the file is fixed or removed.
Secondmate homes inherit this file from the primary, so a secondmate's own crewmates apply the same dispatch profile behavior.

## Heavy-run serialization (config/heavy-run-slots)

`config/heavy-run-slots` is an optional local, gitignored file holding a single positive integer: the number of HEAVY runs - unit suites, end-to-end suites, lint sweeps, builds - that may execute at one instant in this home.
The first non-empty line is parsed, and the default is `1`.
This section is the single owner of the knob; [`bin/fm-heavy-run.sh`](../bin/fm-heavy-run.sh)'s header and `--help` own the lease-queue mechanism, the record format, the refusal cases, and the exit statuses.

A malformed or below-floor value falls back to `1` and warns, rather than falling back to something permissive.
That direction is deliberate: guessing high recreates the host thrash the ceiling exists to prevent, while guessing low only makes runs wait.

Crewmates reach it by wrapping their heavy command:

```sh
bin/fm-heavy-run.sh --task <id> -- npm test
```

The command runs unchanged, its output streams straight through, and the wrapper exits with the command's own status, so a crewmate always acts on its real result.
While a run waits its turn it prints a queued notice naming its position, so a waiting crewmate is visibly queued rather than apparently hung.
The generated crewmate briefs ([`bin/fm-brief.sh`](../bin/fm-brief.sh)) carry that instruction, which is how the runner actually gets adopted.

The same scaffold carries three further shared-machine rules, for the same reason: a rule that only exists as a hand-typed steer does not bind a crewmate that was just spawned.

- Test parallelism is capped at `VITEST_MAX_WORKERS=2`, never 4, because vitest sizes its worker pool from the CPU count and is the fleet's dominant memory consumer.
- Every test run is announced in the status file, `working: TEST START - ...` before and `working: TEST END - ...` after, which is the signal firstmate coordinates the machine from.
- A crewmate announces live browser use in the status file, `working: BROWSER START - ...` before and `working: BROWSER END - ...` after, so the shared-machine log shows browser activity. This is a non-blocking coordination announce, and a worker never waits on firstmate for a browser slot.

For the same reason, every ship and scout scaffold also generates the standing captain rules as a labelled `C1`-`C6` block, and the secondmate charter generates the supervising subset under the same stable labels; [`bin/fm-brief.sh`](../bin/fm-brief.sh)'s header and `--help` own their exact wording and scope.

Ship scaffolds also require the final report to declare whether the change was built test-first and whether it has end-to-end coverage.
A gap does not block the merge; leaving it unstated does, because the captain reviews every untested product change.

This is deliberately NOT the host-resource monitor.
That monitor answers "is this machine healthy right now" and only reports; this ceiling answers "how many heavy runs may proceed right now" and actually blocks.
The two stay uncoupled because a resource reading is momentary and advisory, while the failure mode being prevented - several parked crewmates unblocked at once, all starting a suite before any new reading is taken - needs a hard, stateful count.

Inspect the queue at any time:

```sh
bin/fm-heavy-run.sh --status
```

It prints `ceiling=`, `running=`, `waiting=`, then one line per run and per waiter in queue order.
Each line also carries `home=`, the operational home that owns the run, because the ledger is shared across homes (below).
The runner's state lives in the ledger directory; these are runtime records, not files to edit by hand.

The ledger is host-global by default, not per home.
The machine is the resource being protected, and a fleet runs a primary home plus one or more secondmate homes on one host, so a per-home queue would give each home its own N slots and the host-wide count would be N times the number of homes - exactly the multiplication the cap exists to prevent.
The default ledger therefore lives at a fixed path outside any home, `${TMPDIR:-/tmp}/fm-heavy-runs-<uid>`, one directory per operating user so a shared host neither cross-contaminates nor can be hijacked through a world-writable `/tmp`.
Every home's runs share that one running count, and each record carries its owning home for attribution.
`FM_HEAVY_RUN_DIR` still overrides the path, which is how the tests isolate and how a queue can deliberately be scoped to something other than the whole host.
So that the homes sharing the ledger also share one ceiling, set `FM_HEAVY_SLOTS_FILE` to the authoritative `config/heavy-run-slots` (the primary home's); when it is unset or unreadable the resolver falls back to this home's own `config/heavy-run-slots`, then to `1`.
[`bin/fm-spawn.sh`](../bin/fm-spawn.sh) exports that pointer into every crew and secondmate it launches - propagating an already-inherited authoritative pointer down the chain, otherwise rooting it at the spawning primary home's `config/heavy-run-slots` - so a child home's waiter resolves the one host-global ceiling rather than its own default `1`.
[ADR 0002](adr/0002-heavy-run-host-global-ledger.md) records this deliberate, contained exception to home isolation, and [ADR 0001](adr/0001-heavy-run-refuse-by-default-admission.md) records why admission refuses by default through a lease wrapper.

Admission also reads the host-resource monitor's cached verdict as a second gate.
It is not coupled to the monitor's cadence: it reads only the word the resource probe already published in `state/.resource-status` and never samples the host afresh, so it honours the sustained-sampling rule rather than reacting to a momentary spike.
A free slot is refused (exit `76`) only while that cached verdict is a fresh `critical`, because starting new heavy work into a host that is already thrashing is the second failure mode this control exists to prevent.
It fails open: an absent, stale, unreadable, or non-critical verdict lets admission proceed normally, so a home with no resource monitor is never wedged by it.

When a run that held a slot releases it and a waiter is still queued, the releasing process enqueues one `check heavy-run-slot-free` wake, so firstmate can nudge a crewmate parked on `paused: awaiting test slot` to retry.
Firstmate is the nudger, never the granter: the waiter still re-acquires through ordinary admission, and there is no separate FIFO ticket queue.

## Watcher cadence (config/watcher-cadence)

`config/watcher-cadence` is an optional local, gitignored file that tunes the supervision watcher's cadence knobs, read by [`bin/fm-watch.sh`](../bin/fm-watch.sh).
This section is the single owner of the knob; [`bin/fm-cadence-lib.sh`](../bin/fm-cadence-lib.sh) owns the resolver, shared with the drift alarm below so the value the watcher consumes and the value the alarm audits are resolved by one function.
The file follows the same present/absent/malformed contract as `config/heavy-run-slots`: present means override, absent means the built-in default, and a malformed value falls back to the default loudly, never silently.

The format is one `key = value` line per knob, where the value is a non-negative integer number of seconds.
Blank lines and `#` comment lines are ignored, whitespace around the key and value is tolerated, and the last occurrence of a key wins.
Three keys are recognized:

- `signal_grace` - seconds the watcher lingers after the first changed signal before it classifies, so trailing signals from one worker (a status write, then the same turn's turn-end hook, then another status note) coalesce into a single wake. Default `240`.
- `poll` - seconds between watcher cycles. Default `300`. It must stay below the beacon grace (`900` by default), or a cycle's blind wait could outlive the liveness beacon; the watcher warns at startup when this invariant is violated.
- `heartbeat` - base seconds between heartbeat scans. Default `600`.

An unknown key is itself a loud condition: the file said something the reader could not honor, so it is reported and ignored rather than silently dropped.
A malformed value for a recognized key falls back to that key's default and is reported, so the operator sees why the value they wrote was not applied.
Both classes of warning go to the watcher's stderr and its durable triage log at startup.

Precedence is config-authoritative: a valid value in `config/watcher-cadence` wins over the equivalent environment variable (`FM_SIGNAL_GRACE`, `FM_POLL`, `FM_HEARTBEAT`), and the environment supplies a knob only when the file is silent on that key, as the operator override and test seam.
This is deliberate and is the fix for the drift class that motivated the file's owner role.
The value used to live only in a local settings file that any session could lower for a short-lived debugging reason and never restore, so a temporary value silently became the permanent one.
Making the captain's owning file outrank a stale environment value means a leftover `FM_POLL` from a prior session can no longer quietly win.
A key whose file value is malformed still falls back to that key's default loudly and does not consult the environment for that key, because the owning file said something and the reader must not paper over it with a possibly-stale environment value.
The file exists because those environment variables are unreachable in normal operation: the arm-command seatbelt ([`bin/fm-arm-pretool-check.sh`](../bin/fm-arm-pretool-check.sh)) refuses an env-prefixed invocation such as `FM_SIGNAL_GRACE=240 bin/fm-watch-arm.sh` as a compound wrapper, so firstmate cannot set them at arm time.
The watcher reading a file sidesteps that entirely: firstmate edits `config/watcher-cadence` and arms with a clean, unprefixed `bin/fm-watch-arm.sh`.

The raised `signal_grace` default of `240` is deliberate and evidence-based.
Before it, a single worker lane produced four separate wakes in minutes (a status append, a turn-end, another status append, then a stale reading while its suite ran), and each wake forces firstmate through a drain and re-arm before any other fleet command, costing the captain a full round trip per wake for no decision.
A 240s window spans that burst so ordinary worker chatter batches into one wake, honoring the standing priority that firstmate's responsiveness to the captain outranks instant reaction to worker notifications.

This does not delay a genuine terminal event.
The coalescing linger is skipped when the first scan already carries a captain-relevant verb (`done:`, `failed:`, `needs-decision:`, `blocked:`), so a real terminal wake still surfaces promptly and only no-verb chatter pays the wait.

## Captain-owned value drift alarm (config/captain-preferences)

`config/captain-preferences` is an optional local, gitignored file that records the captain's standing preference for captain-owned operating values, so a startup alarm can shout when a live value has silently drifted from it.
This section is the single owner of the file's schema, and [`bin/fm-drift-check.sh`](../bin/fm-drift-check.sh) owns the comparison mechanism and the generalized list of owned values it audits.

It exists because the watcher poll cadence drifted for weeks with no owner and no provenance: any session could lower it for a short-lived debugging reason, nothing recorded the captain's standing preference, and nothing compared the live value against it, so a temporary value silently became the permanent one.
The config owner (`config/watcher-cadence` above, read in preference to the environment) is the missing-ownership half of the fix, this alarm is the missing-provenance half, and the two compose.

The format is one `key = value` line per recorded preference, parsed exactly like `config/watcher-cadence`: blank lines and `#` comment lines are ignored, whitespace around the key and value is tolerated, and the last occurrence of a key wins.
A key that is absent, empty, or whitespace records no preference for that value, so drift is not evaluated for it (absence is not agreement).
The recognized keys are one per captain-owned value.
The watcher cadence knobs are recorded as `watcher_poll`, `watcher_signal_grace`, and `watcher_heartbeat`, whose live value is resolved by the same [`bin/fm-cadence-lib.sh`](../bin/fm-cadence-lib.sh) the watcher uses, so the audited value is byte-for-byte the value a running watcher would consume.

At session start, [`bin/fm-bootstrap.sh`](../bin/fm-bootstrap.sh) runs the alarm in both detect-only and full modes, exactly like the tangle check, because a read-only session still needs to see that a captain-owned value drifted.
For every owned value whose preference is recorded, it compares the live value against it and, on a mismatch, prints one loud line and nothing when they agree:

```
CONFIG_DRIFT: <label> is <live> but the captain's recorded preference is <recorded> (...)
```

The alarm never mutates anything and never fails the session.
The remedy is in the line: set `config/watcher-cadence` back to the recorded value, or update `config/captain-preferences` when the change is intended.
Generalizing to a new captain-owned value is cheap: append one producer row to `fm_drift_owned_values` in `bin/fm-drift-check.sh` and document its preference key here.

## Toolchain

On session start the first mate detects what its required toolchain is missing or too old and lists each problem with either an exact install command or manual instructions.
It installs automatically supported tools only after you say go; manual-only tools remain for you to install from the printed instructions.
Required tools come in two parts: a universal toolchain every home needs regardless of backend, and a per-backend delta that follows the runtime backend actually resolved for this home.
The universal toolchain is node, git, gh with GitHub auth via `gh auth login`, no-mistakes v1.31.2 or newer, gh-axi, chrome-devtools-axi, lavish-axi, compatible tasks-axi per "Backlog backend" above, and quota-axi.
This section is the single owner of that universal toolchain list; backend guides' prerequisites point here and add only their backend-specific tools.
In that list, no-mistakes runs the validation pipeline, gh-axi, chrome-devtools-axi, and lavish-axi cover GitHub, browser, and rich-review operations, and tasks-axi plus quota-axi back backlog mutations and quota-aware array dispatch.
The per-backend delta is required only for the backend resolved from `FM_BACKEND`, then `config/backend`, then runtime auto-detection, then default `tmux`, so a home is never told to install a tool an inactive backend or feature would need.
That delta is owned in code by `fm_backend_required_tools` in `bin/fm-backend.sh`: the resolved backend's own session-provider CLI (`tmux`, `herdr`, `zellij`, `orca`, or `cmux`), `jq` for the JSON-emitting experimental adapters (`herdr`, `zellij`, `cmux`) whose spawn and liveness paths parse the backend's JSON output, and the `treehouse` worktree provider for every session-provider-only backend (`tmux`, `herdr`, `zellij`, `cmux`).
Backend tool availability uses the adapter's own executable resolver, so bootstrap and spawn agree on supported non-`PATH` locations such as cmux's bundled CLI.
An unknown resolved backend emits `BACKEND_INVALID` and blocks dispatch instead of silently dropping its dependency delta or falling back to tmux.
Orca provides both the task worktree and terminal endpoint (see "Runtime backend" above), so `backend=orca` requires only `orca` on top of the universal toolchain and skips both `treehouse` and every other backend's session CLI.
A herdr, zellij, or cmux home is therefore never told `tmux` is missing, and the `treehouse` durable-lease upgrade check runs only for the backends that actually use treehouse.
When `config/crew-dispatch.json` exists, bootstrap also requires `jq` for dispatch profile validation.
When X mode is opted in, bootstrap also requires `curl` and `jq` before arming the relay poll shim.
`tasks-axi` and `quota-axi` are required bootstrap tools in every profile, the same class as `lavish-axi`.
An absent or incompatible `tasks-axi` reports `MISSING: tasks-axi (install: npm install -g tasks-axi)`; when `config/backlog-backend` is not `manual` and compatible `tasks-axi` is on `PATH`, bootstrap stays silent and firstmate uses its verbs for routine backlog mutations, otherwise it hand-edits `data/backlog.md` until installation is approved and completed.
An absent `quota-axi` reports `MISSING: quota-axi (install: npm install -g quota-axi)`; `bin/fm-dispatch-select.sh` still selects uniformly from the valid candidate array with an OS-backed random source when quota data is unavailable.
Bootstrap also reports a `TANGLE:` line when `FM_ROOT` is on a named non-default branch; follow the printed checkout remediation rather than treating it as an installable tool problem.
In a read-only session that did not get the fleet lock, the same line is advisory and omits the checkout command.
The locked session-start bootstrap step also runs a best-effort project clone refresh through `fm-fleet-sync.sh`.
It emits `FLEET_SYNC:` for skipped refreshes that may matter, recovered self-heals, `STUCK:` alarms, `FETCH FAILED:` reports, and `PIN FAILED:` reports.
Normal completed runs keep local-only and no-origin skips silent.
Every sync also converges each clone's Treehouse worktree pool pin through `bin/fm-treehouse-pin.sh`, before the local-only and no-origin skips, so existing clones self-heal and a home that moves re-pins itself.
A converged pin stays silent; a pin that cannot be applied is reported as `PIN FAILED:` and never aborts the refresh, because an unpinned clone shares one pool with every other copy of the same repo on the machine and its spawns will be refused (see [treehouse-pools.md](treehouse-pools.md)).
A failed fetch is deliberately reported as `FETCH FAILED:` rather than as a skip, because a clone that stops fetching still presents a clean tree on its default branch and is otherwise indistinguishable from a healthy one, so a quiet skip lets work be reasoned against silently stale code.
If bootstrap kills a timed-out refresh, it replays any completed `fm-fleet-sync.sh` output before the aggregate timeout skip so no finished result is lost.
A killed refresh (or a teardown process kill) can leave an orphaned `.git/packed-refs.lock` in a clone, which makes the next refresh's fetch fail with Git's `Unable to create '...packed-refs.lock': File exists`.
On that signature only, `fm-fleet-sync.sh` retries the fetch with a bounded wait for the lock to self-clear, then removes the lock and retries once more only when it can prove the lock stale, exactly like the `fm-teardown.sh` `index.lock` recovery.
It never removes a live lock, leaves any other failure shape untouched, and prints every wait, retry, and removal to stderr plus a one-line `recovered:` summary to stdout on success so that this session-start relay still surfaces the recovery.
The locked session-start bootstrap step also runs the guarded local secondmate sync for recorded live secondmate homes, then propagates declared inherited local material into each validated live home.
It emits `SECONDMATE_SYNC:` only when a home was skipped for an actionable sync reason, inheritance failed, or a divergent shared captain-preference copy was quarantined.
When a running home advances and its loaded instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) changed, bootstrap sends the re-read nudge itself through the stable `fm-<id>` selector - only when the home carries in-flight work (any `state/*.meta` in its own home; lazy nudge policy owned in `bin/fm-ff-lib.sh`) - and reports the exact completed send as `BOOTSTRAP_INFO:`.
An idle home is never nudged: it is already advanced on disk and picks the new instructions up at next routed task or respawn, and the skip is reported as a `BOOTSTRAP_INFO:` line.
If that send fails, bootstrap keeps an idempotent retry marker and emits `NUDGE_SECONDMATES:` with the failure reason.
The same lazy policy applies to `/updatefirstmate`'s `nudge-secondmates:` line, which lists only updated live secondmates with in-flight work.
The same bootstrap run emits `SECONDMATE_LIVENESS:` only when a live secondmate endpoint is skipped or respawn fails; already-live and successfully respawned endpoints are handled silently.
For a mid-session inherited local-material edit where tracked-file sync is not needed, run `bin/fm-config-push.sh`.
It uses the same live secondmate discovery and propagation helper as bootstrap, prints each live home's `crew-dispatch.json`, `crew-harness`, `backlog-backend`, `herdr-presentation-spaces`, and `data/captain-shared.md` result as `pushed`, `unchanged`, `skipped`, or `error`, and exits non-zero for real propagation errors or config-reread send failures.
When an allowlisted config item changes for an already-running home, it sends the literal-content reread pointer described in [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md) - gated on the same lazy nudge policy as the AGENTS.md re-read (`secondmate_has_inflight_work` in `bin/fm-ff-lib.sh`): the propagation and instruction file write always happen, but the send is skipped with a `BOOTSTRAP_INFO:` note for an idle home, whose published `.pending` instruction stays as the durable record until it is busy again or relaunches (fresh config read at launch); unchanged allowlisted config sends no pointer unless a previous delivery is pending.
The locked bootstrap inheritance pass uses the same per-home changed-set and reread path for already-running homes; see `secondmate-provisioning` for the single contract owner.
That live discovery starts from `state/*.meta` records with `kind=secondmate`; `data/secondmates.md` only backfills `home=` for older or incomplete meta records.
Skipped items, such as a destination checkout that does not yet gitignore the item, are visible warnings but not hard failures.

## X mode (.env)

X mode lets a firstmate instance answer public `@myfirstmate` mentions and act on normal reversible mention requests through firstmate's normal lifecycle.
It is off unless the firstmate home's gitignored `.env` contains a non-empty `FMX_PAIRING_TOKEN`.
The pairing token both identifies the relay tenant and records opt-in consent for autonomous public replies and eligible lifecycle actions.
Destructive, irreversible, or security-sensitive asks are flagged for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a home is from that home's owner/captain, while parent-thread context may still include other public accounts.
`FMX_RELAY_URL` is optional and defaults to `https://myfirstmate.io`, mainly for developers pointing at a local relay.
For direct client invocations, environment values override `.env`; bootstrap activation still keys off `.env` presence so watcher artifacts are explicit local opt-in state.
`FMX_ENV_FILE` can point direct poll/reply client invocations at another `.env`-style file, but it does not change bootstrap activation.

The locked session-start bootstrap step turns the token into local generated state.
It writes `state/x-watch.check.sh`, a byte-static identity shim for `bin/fm-x-poll.sh`, and `config/x-mode.env`, which exports `FM_CHECK_INTERVAL=30` for watcher processes in that home.
The watcher accepts the shim only when its bytes match the expected generated content, then invokes the trusted repository poll script directly instead of executing state-file source.
This section is the single owner of the X-mode cadence contract: an X instance polls every 30 seconds instead of the default 300, only an X instance speeds up because a non-X home has no `config/x-mode.env`, and the session-start supervision operating block includes the cadence instruction when that file exists.
The active primary-harness supervision protocol owns how that sourced cadence reaches the watcher process.
Because `bin/fm-watch.sh` reads `FM_CHECK_INTERVAL` only at process start, a cadence transition - opt-in while a watcher is already running, or opt-out - is applied by restarting the home-scoped watcher through the emitted harness protocol; bootstrap deliberately never restarts the watcher itself.
While an away-mode daemon is actually live for the home it owns the watcher and its default cadence applies, so daemon-owned away-mode X cadence is a deferred follow-up.
Away mode with no live daemon is the away posture only: the home arms its own watcher through the emitted harness protocol, which sources `config/x-mode.env`, so the 30-second X cadence above applies there exactly as with away mode off (`docs/turnend-guard.md` "Away Mode").
When the token is removed or empty, the next locked session-start bootstrap step removes those artifacts.
Steady-state off is silent and writes nothing.
X mode remains additive to non-X lifecycle behavior: homes without the generated artifacts keep the default watcher cadence and do not run the X poll.
Its request handling remains in X-specific `bin/` scripts and the `fmx-respond` skill, while the watcher owns authenticated dispatch from the generated local identity shim.

`bin/fm-x-poll.sh` calls `GET /connector/poll` with `Authorization: Bearer <FMX_PAIRING_TOKEN>`.
HTTP 204 is silent.
A newly offered pending mention with non-empty `text` is stored at `state/x-inbox/<request_id>.json` and wakes firstmate exactly once with `x-mention <request_id>`.
The poll atomically claims `state/x-context/<request_id>.offered.json` before emitting that wake, and subsequent offers of the same request stay silent even after the inbox is drained following an answer or dismiss.
Offer markers share the context registry's bounded seven-day retention, so losing or expiring the local marker lets a relay offer wake firstmate again.
The full relay object is preserved, including `in_reply_to: {author_handle, text}` when the mention is a reply in a conversation or `null` for fresh mentions.
At the same time the poll records a durable per-request reply context at `state/x-context/<request_id>.json` (`{request_id, platform, reply_max_chars, recorded_at}`) from the same authoritative relay payload, best-effort and keyed by `request_id` so concurrent requests never overwrite each other; it survives the inbox cleanup that follows the acknowledgement, so a delayed follow-up can recover the original platform and split budget even with no task link.
`recorded_at` begins as the locally observed first-seen Unix epoch and remains unchanged when the same request is polled again.
A successful live initial answer refreshes it to the time that the relay establishes the follow-up binding; dry-runs, failed answers, and follow-ups do not refresh it.
Configured polls prune records beyond the local follow-up window, capped at the relay's seven-day window; legacy or malformed records fall back to their file modification time so they cannot remain indefinitely.
The record is written only when a platform or explicit budget is actually known, so an unknown-platform mention leaves no useless entry.
The `fmx-respond` skill decides whether the stashed mention is an actionable request, a question, or a pure acknowledgment.
Actionable reversible requests are run through intake, backlog, dispatch, investigation, or ship flow as appropriate.
If the work completes in that turn, the public reply reports the outcome.
If the request spawns a longer-running task, firstmate posts an acknowledgement through the normal answer endpoint, links the task to the mention with `bin/fm-x-link.sh`, and posts up to three completion follow-ups on genuine milestones, always finishing with a `--final` one when the task reaches a terminal state.
That link stores optional reply-platform context so Discord-originated follow-ups keep Discord's larger message budget after the inbox file has been drained.
Platform/budget resolution is layered and independent of the task link: a per-axis `FMX_REPLY_PLATFORM` / `FMX_REPLY_MAX_CHARS` override (how `bin/fm-x-followup.sh` passes a recorded link's context) wins.
For either axis without an override, `bin/fm-x-lib.sh:fmx_resolve_reply_context` owns the source order: the durable per-request registry is consulted first, then the still-present inbox payload, then - for a follow-up posted live by request_id - an authoritative relay lookup via `POST /connector/request-context` (`{request_id}` in, `{platform, reply_max_chars}` back).
This is what keeps a delayed request-id follow-up on the original platform's budget even after the inbox is drained and with no task link surviving; the relay step is confined to the live follow-up path so the answer path and every dry-run stay network-free.
`bin/fm-x-link.sh` follows the same ordering when recording a fresh link's context and requires `jq`; its request-context lookup is best-effort: no token or `curl`; a non-2xx response; an unresolved response; or a relay version without that endpoint leaves the context unknown.
In that case the link is still recorded but `bin/fm-x-link.sh` prints a loud warning; and when either a follow-up's platform or explicit budget cannot be authoritatively resolved from any source, `bin/fm-x-reply.sh` refuses it (fail-safe exit 8) rather than posting with a local default - firstmate holds and retries it once both values are recoverable.
Fresh links start with `x_followups=0` and the current timestamp; when relinking the same relay request onto a successor task, pass paired `--carry-count <n> --carry-ts <epoch>` flags plus any prior `x_platform=` and `x_reply_max_chars=` as `--carry-platform <x|discord> --carry-max <n>` so the successor preserves the already-consumed follow-up count, original 7-day window, and reply split budget.
Pure acknowledgments or mentions with nothing to answer are dismissed through `bin/fm-x-dismiss.sh` before the local inbox file is cleared.
Dismiss sends `POST /connector/dismiss` with `{request_id}`, posts no text, and tells the relay to drop the request instead of re-offering it or falling back to an offline auto-reply; on success it clears that request's durable reply-context record, while the separate offer marker remains for its bounded retention so a brief relay re-offer stays silent.
Relay auth or config problems are reported once as `x-mode-error ...` until recovery.
A failed durable offer claim is likewise reported once as `x-mode-error cannot record mention offer` and remains deduplicated through quiet no-pending polls until a later offer confirms an existing valid marker or claims a new one.
Live replies are posted by `bin/fm-x-reply.sh`, which sends `POST /connector/answer` with `{request_id,text}` for one-message replies.
Add `--image <path>` to attach one local PNG, JPEG, GIF, WebP, BMP, or TIFF as `{media_type,data_base64}` in the relay's optional `image` object.
Completion follow-ups use `bin/fm-x-followup.sh`, which checks the local `state/<id>.meta` link and sends the same payload shape through `POST /connector/followup` by calling `bin/fm-x-reply.sh --followup`, up to three times per link within the window.
Add `--image <path>` there too when a completion follow-up should carry an image.
A successful post increments the local `x_followups=` counter and keeps the link, unless `--final` was passed or the new count reaches the cap, in which case the link is cleared instead; a failed post leaves the link and counter untouched so it can be retried.
The relay itself rejects a follow-up past its own cap or window with HTTP 409 and may include `{"error":"followup_unavailable"}` in the response body; the client surfaces any follow-up 409 as a distinguishable exit code and uses the body marker only for a sharper diagnostic.
`fm-x-followup.sh` treats that exit exactly like a locally-detected expiry - clearing the link and skipping quietly rather than retrying - so an older single-follow-up relay or an already-exhausted binding degrades gracefully.
It treats `fm-x-reply.sh`'s fail-safe refusal (exit 8: platform or explicit budget unresolved) differently: that is a retryable hold, so the link is KEPT and the follow-up is retried once both values can be recovered, never posted with a local default.
Past-window relay rejections are only guaranteed while the expired binding row still exists on the relay side; after its cleanup sweep, a very-late follow-up call may instead see a benign no-op 200, which is why the local window and cap pruning remains the primary guard.
Reply splitting is platform-aware: an explicit relay platform field (`reply_platform`, `platform`, `target_platform`, `source_platform`, or `provider`) wins, otherwise a legacy `tweet_id` beginning with `discord:` selects Discord and a numeric `tweet_id` selects X.
An explicit relay limit field (`reply_max_chars`, `reply_max_characters`, `message_max_chars`, `message_limit`, or `max_chars`) wins over the platform defaults.
If the reply exceeds the selected budget, the client splits it into a numbered thread on fenced-code, paragraph, line, and word boundaries and sends `{request_id,text,texts}`, where `texts` is the ordered chunk list and `text` remains the first chunk for older relays.
When `--image <path>` is present on a split reply, the image rides the first/opener message and later chunks stay text-only.
`FMX_X_REPLY_MAX_CHARS` defaults to 280 and clamps to a minimum of 50; `FMX_DISCORD_REPLY_MAX_CHARS` defaults to 1900, clamps to a minimum of 50, and resets values above Discord's 2000-character limit back to 1900.
`FMX_X_THREAD_MAX` defaults to 25 and caps oversized reply threads for every platform, marking the last retained message with an ellipsis when truncation is needed.
`FMX_FOLLOWUP_MAX_AGE_SECS` defaults to 604800 (7 days) and controls the local completion follow-up window; `FMX_FOLLOWUP_MAX_COUNT` defaults to 3 and controls the local follow-up cap.

Set `FMX_DRY_RUN` to preview replies and dismissals without posting.
Truthy means anything except unset, empty, `0`, `false`, `no`, or `off`; an explicit environment value wins over `.env`.
In dry-run, `fm-x-reply.sh` records the would-be payload to `state/x-outbox/<request_id>.json`, including `texts` for a thread and an `endpoint` marker for follow-up previews, prints a `DRY RUN` summary to stderr, echoes the `request_id`, and exits 0.
When an image is attached, the dry-run record uses compact `{media_type, bytes, source_path}` metadata instead of writing the base64 bytes.
In dry-run, `fm-x-dismiss.sh` records `{request_id, endpoint:"dismiss"}` to the same outbox path, prints a `DRY RUN` summary, echoes the `request_id`, and exits 0.
The live answer and follow-up bodies intentionally stay the same shape, including optional `image`; the relay distinguishes them by endpoint, and dismiss stays `{request_id}`.
These paths need `jq` to build the JSON payload, but they run before token and network checks, so they need neither `FMX_PAIRING_TOKEN` nor `curl`.

## Mattermost captain-firstmate messaging (.env)

Mattermost messaging lets the captain command the fleet and receive escalations over a Mattermost control channel with no terminal, so a phone is enough.
It is the private, single-captain sibling of X mode, and [docs/mattermost-messaging.md](mattermost-messaging.md) owns the design and rationale.
This section owns the config contract; the exact wire calls and paths live in the `bin/fm-mm-poll.sh`, `bin/fm-mm-post.sh`, and `bin/fm-mm-lib.sh` headers.

It is off unless the home's gitignored `.env` contains a non-empty `MM_TOKEN` (a Mattermost personal access token).
Absent that token every entry point is a hard no-op: `bin/fm-mm-poll.sh` exits silently and `bin/fm-mm-post.sh` posts nothing, so a non-opted-in home is completely inert.
The token authorizes reading the control channel and posting escalations and firstmate's own answers to it.
It does not expand any approval authority: an inbound Mattermost message is a captain steer, never an approval, and never auto-approves or auto-executes a merge or any destructive, irreversible, or security-sensitive action (AGENTS.md sections 8 and 9).

The transport is a shell-side Mattermost REST v4 poll authorized by `MM_TOKEN`, because the Mattermost MCP is agent-only, has no channel-list or new-message signal, and gates `post_reply` behind explicit confirmation, so it cannot drive the always-on shell watcher.
The MCP remains the agent-side rich reader for a thread and its attachments once a message has woken firstmate.

Config values resolve from `.env` (or the environment, which wins for a direct invocation or a test):

- `MM_TOKEN` - the Mattermost personal access token; the single opt-in gate.
- `MM_SERVER_URL` - the Mattermost base URL, e.g. `https://mattermost.hyfin.app`.
- `MM_CHANNEL_ID` - the control channel id; when set it wins and no name lookup runs.
- `MM_TEAM` and `MM_CHANNEL` - the team and channel URL slugs (e.g. `dashnow` and `fm-cyuan`); used to resolve the channel id once when `MM_CHANNEL_ID` is unset, because the MCP cannot discover a channel and the captain names it by URL. The resolved id is cached to `state/mm-channel-id`.
- `MM_DRY_RUN` - truthy previews an outbound post to `state/mm-outbox/` without posting.
- `MM_ENV_FILE` - optional alternate `.env`-style file for direct client invocations.

Inbound wiring reuses the watcher's custom-check path: register `bin/fm-mm-poll.sh` as the home's `state/<id>.check.sh` and bind it with `bin/fm-check-register.sh`, so the watcher runs it each slow-check cycle and its `mm-message <post_id>` output becomes an ordinary `check:` wake on the existing supervision and away-mode escalation path.
The poll filters out firstmate's own posts using its bot user id (resolved once via `GET /api/v4/users/me`, cached to `state/mm-self-user`), advances a durable `state/mm-cursor` (epoch ms), anchors that cursor to now on first run so channel history is never replayed, and stashes each new captain post to `state/mm-inbox/<post_id>.json`.

Outbound escalations reuse the content firstmate already surfaces per AGENTS.md section 9: `bin/fm-mm-post.sh` posts them with the token, threading a reply onto the captain post it answers via `--root` or posting a new root for an unprompted escalation.
A planned future integration would add the same helper as an additional delivery sink for the digests the away-mode outbox produces (`bin/fm-afk-outbox-lib.sh`); it is not yet wired in this change (no away-mode code calls `bin/fm-mm-post.sh` today).
All generated state lives under the already-gitignored `state/`.

## Environment variables

Runtime tuning via environment variables (defaults shown):

```sh
FM_HOME=                 # optional operational home for most scripts, unset means this repo root; fm-send defaults to the current directory when that directory is a valid firstmate home
FM_ROOT_OVERRIDE=        # override firstmate repo root, tangle-guard target, and zellij/cmux home-title hash; also legacy whole-root override when FM_HOME is unset
FM_STATE_OVERRIDE=       # alternate state dir, mainly for tests
FM_DATA_OVERRIDE=        # alternate data dir, mainly for tests
FM_PROJECTS_OVERRIDE=    # alternate projects dir, mainly for tests
FM_CONFIG_OVERRIDE=      # alternate config dir, mainly for tests
FM_PROC_ROOT_OVERRIDE=   # alternate /proc root for the Linux process-identity read in fm-wake-lib.sh, mainly for tests
FM_BACKEND=             # optional runtime backend override for new spawns; tmux/herdr/zellij/orca/cmux support ship/scout spawns, codex-app is not accepted
HERDR_SESSION=default  # herdr-only: named session for normal backend ops; not enough for destructive cleanup (docs/herdr-backend.md)
FM_BACKEND_HERDR_COMPOSER_LINES=20  # herdr-only: tail lines scanned by composer-state guard/fallback paths; idle-baseline submit confirmation uses agent-state
FM_BACKEND_HERDR_IDLE_RE='^Type a message\.\.\.$'  # herdr-only: empty-composer placeholder regex after shared ghost extraction plus border and prompt stripping
FM_BACKEND_HERDR_BARE_PROMPT_RE='^[❯›]'  # herdr-only: verified agent glyphs recognized as an UNBORDERED (bare) composer row, e.g. claude's ❯ or codex's ›; shell glyphs remain unknown rather than empty, and de-emphasised ghost/placeholder text (dim or dark-truecolor) after an agent prompt reads empty via the shared fm_composer_strip_ghost (docs/herdr-backend.md "Incident (2026-07-08)", "Incident (2026-07-10)")
FM_BACKEND_HERDR_PI_COMPOSER_MAX_LINES=8  # herdr-only: maximum rows admitted between Pi's native-identity-corroborated separator pair; taller or ambiguous candidates stay unknown (docs/herdr-backend.md "Incident (2026-07-14)")
FM_BACKEND_HERDR_SUBMIT_POLLS=6  # herdr-only: agent-state samples spread across each Enter attempt's budget when confirming a submit (docs/herdr-backend.md "Native agent-state submit confirmation")
FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.6  # herdr-only: minimum per-Enter confirmation budget before polling agent-state after an idle baseline
FM_BACKEND_ORCA_COMPOSER_LINES=200  # orca-only: terminal-read lines scanned to locate the composer row for submit verification
FM_BACKEND_ORCA_IDLE_RE='^Type a message\.\.\.$'  # orca-only: empty-composer placeholder regex after border/prompt stripping
FM_ZELLIJ_SESSION=firstmate  # zellij-only: named session for normal backend ops and test isolation (docs/zellij-backend.md)
FM_BACKEND_CMUX_COMPOSER_LINES=20  # cmux-only: tail lines scanned to locate the composer row for submit verification
FM_BACKEND_CMUX_IDLE_RE='^Type a message\.\.\.$'  # cmux-only: empty-composer placeholder regex after border/prompt stripping
CMUX_SOCKET_PASSWORD=   # cmux-only: socket password fallback when config/cmux-socket-password is absent (docs/cmux-backend.md)
FM_SESSION_START_STATUS_TAIL=5   # state/*.status lines printed per task in the session-start digest
FM_SESSION_START_STALL_THRESHOLD=1800   # seconds a worker's last status event must be older than for a PAUSED worker to appear in the session-start cross-session stall banner; a BLOCKED worker always appears regardless of age; malformed falls back to the default
FM_SESSION_START_EVENT_OLD_THRESHOLD=600   # seconds a task's last status EVENT must exceed for the session-start paired current-state line to mark it (OLD); only fires when the current state has a fresher authoritative source (run-step/pane); malformed falls back to the default
FM_SNAPSHOT_EVENT_OLD_THRESHOLD=600   # same OLD-marker threshold for the fleet snapshot/view's paired event+current-state cell (last_event.old); only fires when current_state.source is run-step/pane; malformed falls back to the default
FM_BOOTSTRAP_DETECT_ONLY=0   # internal/read-only session-start mode: skip bootstrap's mutating sweeps and print advisory TANGLE wording
FM_GUARD_READ_ONLY=0    # internal/read-only guard mode: keep alarms but suppress drain, supervision repair, and checkout repair commands
FM_GUARD_CONTINUE_LINE='This is a supervision warning only; the guarded operation WILL still run.'   # banner continuation line; fm-send.sh overrides it to name the requested message specifically
FM_POLL=300             # seconds between watcher poll cycles; keep below the beacon grace (FM_WATCHER_STALE_GRACE, which defaults to FM_GUARD_GRACE and to 900) - see the POLL < grace invariant below
FM_HEARTBEAT=600        # base seconds between heartbeat scans; no-change heartbeats are absorbed while idle
FM_HEARTBEAT_MAX=7200   # heartbeat backoff cap
FM_WATCH_ABSORB_TICK=0  # 1 makes a benign-absorbed wake end the cycle with a distinguishable "tick:" proof-of-life line (no wake record); default off = byte-identical silent absorb; only while work is under way. See docs/watcher-continuity.md "Absorbed-wake proof-of-life tick"
FM_CHECK_INTERVAL=300   # seconds between slow checks (authenticated merge polls, custom checks, or X-mode dispatch)
FM_CHECK_TIMEOUT=30     # seconds allowed per slow check script
FM_RESOURCE_INTERVAL=900   # seconds between host CPU/memory/swap sweeps; own cadence, NOT tied to FM_POLL or FM_CHECK_INTERVAL; 0 disables the monitor, malformed falls back to the default (see the host resource monitoring section above)
FM_HOURLY_REVIEW_INTERVAL=3600   # seconds between hourly session-review passes; 0 disables it, malformed falls back to the default (see the hourly session passes section above)
FM_HOURLY_CLEANUP_INTERVAL=3600  # seconds between hourly cleanup sweeps; same 0/malformed rules
FM_RESOURCE_SWEEP_BUDGET=30   # seconds one sweep may spend on crew-liveness checks in total; 0 or malformed falls back to the default
FM_RESOURCE_PROBE_TIMEOUT=5   # seconds allowed per crew-liveness check inside a sweep; 0 or malformed falls back to the default
FM_RESOURCE_PROBE_LOCK=       # override for the host-global probe concurrency lock path; default ${TMPDIR:-/tmp}/fm-resource-probe-<uid>.lock (one probe at a time across every worktree and home on the host); the tests use it to isolate
FM_RESOURCE_PROBE_MEM_MB=1024 # hard address-space ceiling (ulimit -v, MiB) on the probe and every child it forks; 0 or malformed disables it
FM_RESOURCE_PROBE_MAX_BYTES=1048576 # cap on the sweep output the probe reads into a variable; 0 or malformed disables it
FM_HEAVY_SLOTS=         # heavy-run ceiling override; wins over the authoritative and local config, malformed or below-floor values fall back to 1 (see the heavy-run serialization section above)
FM_HEAVY_SLOTS_FILE=    # path to the authoritative heavy-run ceiling file (the primary home's config/heavy-run-slots); when set and readable it overrides this home's own config so every home sharing the host-global ledger resolves one cap, otherwise the local config is used
FM_HEAVY_RUN_DIR=       # alternate heavy-run queue dir; the default is host-global ($TMPDIR/fm-heavy-runs-<uid>, one queue for the whole machine), and this override scopes the queue elsewhere (the tests use it to isolate)
FM_HEAVY_RESOURCE_STATUS=   # path to the cached host-pressure verdict the admission guard reads, default state/.resource-status; a fresh `critical` verdict refuses a free slot (exit 76), absent/stale/non-critical fails open
FM_HEAVY_RESOURCE_INTERVAL= # override for the resource-probe interval used to bound the cached verdict's freshness (2 * interval); default resolves from bin/fm-resource-check.sh --interval, then 900
FM_HEAVY_POLL=2         # seconds between admission attempts while a heavy run is queued
FM_HEAVY_NOTICE=30      # seconds between "still queued" notices printed by a waiting heavy run
FM_HEAVY_LOCK_WAIT=30   # seconds a heavy run waits for the admission lock before refusing without running
FM_CODEX_WATCH_CHECKPOINT=180   # seconds per foreground watcher checkpoint in Codex primary supervision
FM_CREW_STATE_NM_TIMEOUT=10   # seconds allowed per no-mistakes query inside fm-crew-state.sh
FM_CREW_STATE_RUNS_LIMIT=200  # recent no-mistakes run rows scanned when axi status cannot be attributed to the current code
FM_CREW_STATE_BIN=bin/fm-crew-state.sh   # test override for the current-state reader used by working/paused watcher triage and by fm-wake-brief.sh
FM_WAKE_BRIEF_TAIL=5    # state/*.status lines printed per task in the fm-wake-brief.sh wake-handling brief
FM_WAKE_DRAIN_BIN=bin/fm-wake-drain.sh   # test override for the drain fm-wake-brief.sh composes, mainly to exercise its failed-drain path
FM_SPAWN_ALLOW_DUPLICATE=   # deliberate override for fm-spawn.sh's pre-spawn duplicate-dispatch guard; truthy 1 spawns a crewmate/scout even if the task id is already in data/completions.tsv or its recorded pr= is already merged
FMX_PAIRING_TOKEN=      # X mode pairing token; .env opt-in authorizes replies and eligible lifecycle actions
FMX_RELAY_URL=https://myfirstmate.io   # optional X relay override, mainly for local relay development
FMX_ENV_FILE=           # optional alternate .env file for direct X client invocations; bootstrap still checks $FM_HOME/.env
FMX_DRY_RUN=            # truthy previews X replies and dismissals to state/x-outbox/ without posting or requiring a token
FMX_X_REPLY_MAX_CHARS=280   # X reply per-message split budget; values below 50 clamp to 50
FMX_DISCORD_REPLY_MAX_CHARS=1900   # Discord reply per-message split budget; values below 50 clamp to 50, values above 2000 reset to 1900
FMX_X_THREAD_MAX=25     # maximum messages in one auto-split reply thread
FMX_FOLLOWUP_MAX_AGE_SECS=604800   # local window for posting X-mode completion follow-ups (7 days)
FMX_FOLLOWUP_MAX_COUNT=3   # local cap on X-mode completion follow-ups per linked mention
MM_TOKEN=               # Mattermost messaging opt-in; a Mattermost personal access token. Absent = the feature is fully inert
MM_SERVER_URL=          # Mattermost base URL, e.g. https://mattermost.hyfin.app
MM_CHANNEL_ID=          # control channel id; when set it wins and no team/name lookup runs
MM_TEAM=                # team URL slug (e.g. dashnow); with MM_CHANNEL resolves the channel id once when MM_CHANNEL_ID is unset
MM_CHANNEL=             # control channel URL slug (e.g. fm-cyuan); see MM_TEAM
MM_DRY_RUN=             # truthy previews an outbound Mattermost post to state/mm-outbox/ without posting
MM_ENV_FILE=            # optional alternate .env file for direct Mattermost client invocations
FM_LOCK_STALE_AFTER=2   # seconds before dead-pid lock records can be reclaimed; mid-acquire locks keep at least 2s grace
FM_GUARD_GRACE=900      # seconds before guard warnings, arm health checks, and the primary turn-end guard treat a watcher beacon as stale
FM_AFK_DAEMON_PENDING_TTL=300   # seconds an away-mode daemon-start intent marker (state/.supervise-daemon.starting) reads as owned before it decays to daemon-free; bounds the bring-up window (docs/turnend-guard.md "Away Mode")
FM_AFK_DAEMON_STATE_TIMEOUT_MS=5000   # milliseconds the OpenCode auto-arm plugin waits for bin/fm-afk-daemon-state.sh to answer supervision ownership before treating away mode as daemon-owned and not arming
FM_ARM_CONFIRM_TIMEOUT=10   # seconds fm-watch-arm waits to confirm a fresh watcher before reporting FAILED
FM_ARM_ATTACH_POLL=0.5  # seconds between checks while fm-watch-arm is attached to an existing healthy watcher cycle
FM_OPENCODE_ARM_READY_TIMEOUT_MS=12000   # milliseconds the OpenCode primary watcher plugin waits for an arm attempt to report started, healthy, wake, or failure
FM_PI_ARM_READY_TIMEOUT_MS=12000   # milliseconds the Pi watcher extension waits for a successor arm to report started or attached
FM_WATCH_ARM_RETIRE_TIMEOUT_MS=1000   # milliseconds Pi/OpenCode wait for an unready successor arm to exit before abandoning retries
FM_WATCH_REARM_RETRY_BASE_MS=250   # Pi/OpenCode adapter base delay for continuity restoration retries
FM_WATCH_REARM_RETRY_MAX_MS=4000   # Pi/OpenCode adapter cap for exponential continuity retry delay
FM_WATCH_REARM_RETRY_LIMIT=5   # Pi/OpenCode adapter launch-failure retries before surfacing restoration failure
FM_WATCH_CYCLE_LOG_MAX_BYTES=262144   # size cap for the arm-owned watcher lifecycle ledger
FM_WATCH_CYCLE_LOG_KEEP_LINES=1000   # newest complete lifecycle rows considered when the ledger is capped
FM_WATCHER_STALE_GRACE=900   # defaults to FM_GUARD_GRACE, which itself defaults to 900; seconds a live watcher lock may have a stale beacon before re-arm errors. POLL < grace invariant: FM_POLL must stay below this grace. The watcher refreshes its liveness beacon (state/.last-watcher-beat) at the top of each cycle, so a full cycle's terminal wait that outlives the grace would read a healthy sleeping watcher as dead (the guard prints WATCHER DOWN and re-arm refuses) for the back of every cycle. bin/fm-watch.sh keeps the beacon fresh by slicing that wait into pieces no longer than min(FM_POLL, grace/2) and re-touching the beacon each slice, and warns at start-up when FM_POLL >= grace, but the cadence and the liveness grace should still be set so FM_POLL is the smaller.
FM_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'   # captain-relevant status regex; nonterminal progress verbs remain excluded even when their prose matches
FM_CLASSIFY_PAUSED_VERB=paused     # leading status verb for a declared external wait; excluded from FM_CAPTAIN_RE and distinct from blocked
FM_CLASSIFY_AUTH_EXHAUSTION_RE='usage[ _-]?limit|usage[ _-]?window|session[ _-]?limit|quota|revoked|...'   # a paused: reason matching this is a captain-fixable auth/quota/token exhaustion, reclassified to blocked (surfaces) rather than absorbed as a benign wait; bin/fm-classify-lib.sh owns the full default
FM_STALE_ESCALATE_SECS=240       # idle seconds before a provably-working stale pane's wedge timer fires; the first expiry of a stall episode sends the one auto-nudge and restarts this window for a reply, so the stale wake reaches firstmate only when the crew stays silent past the nudge grace (a stopped non-terminal crew is nudged once on first sight under the same window); an undeliverable nudge escalates immediately; secondmates and supervise=off panes are never nudged
FM_PAUSE_RESURFACE_SECS=3600       # seconds before an idle declared external wait re-surfaces for a recheck in the watcher or away-mode daemon
FM_WEDGE_DEMAND_INSPECT_COUNT=3    # consecutive provably-working stale escalations on the same unchanged pane before demand-deep-inspection is added
FM_WATCH_TRIAGE_LOG_MAX_BYTES=262144   # size cap for the watcher's absorbed-wake debug log
FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=     # optional seconds allowed for bootstrap's best-effort clone refresh; unset/blank defaults to max(20, 5 + 3 * origin-backed-project-count)
FM_FLEET_PRUNE=1        # set to 0 to skip pruning local branches whose upstream is gone
FM_STALE_WORKTREE_LOCK_AGE_SECS=30       # min mtime age before fm-teardown.sh treats a leftover worktree git index.lock as provably stale
FM_TREEHOUSE_RETURN_LOCK_RETRIES=3        # retries after a treehouse return fails on the transient git index.lock signature
FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1 # seconds fm-teardown.sh waits before each retry after that signature
FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=   # legacy alias for FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS when the new variable is unset
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3        # fetch retries after fm-fleet-sync.sh hits the orphaned .git/packed-refs.lock signature
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=1 # seconds fm-fleet-sync.sh waits before each of those retries
FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=30       # min mtime age before fm-fleet-sync.sh treats a leftover packed-refs.lock as provably stale
FM_BUSY_REGEX='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'   # busy-pane signatures, shared by watcher, fm-crew-state pane fallback, and tmux helper
FM_COMPOSER_IDLE_RE=    # optional empty-composer regex, applied after ghost and border stripping
FM_COMPOSER_GHOST_LUMA_MAX=128   # fleet-wide: max perceived luminance (0.299R+0.587G+0.114B, 0-255) for a TRUECOLOR foreground to count as de-emphasised ghost/placeholder text and be stripped; dim/faint (SGR 2) is stripped regardless. Assumes a dark terminal theme (bin/fm-composer-lib.sh's fm_composer_strip_ghost, shared by the tmux and herdr composer readers)
GROK_HOME=              # optional Grok config home for firstmate's global grok turn-end hook; defaults to ~/.grok
FM_SEND_RETRIES=3       # fm-send Enter-retry attempts after typing the line once
FM_SEND_SLEEP=0.4       # seconds between fm-send submit checks
FM_SEND_SETTLE=1        # seconds fm-send waits after a successful text submit; 0 disables
FM_PENDING_REPLY_GRACE_SECS=120   # seconds after marked-request delivery before a completed turn without a correlated parent report is eligible for its one recovery repost
# sub-supervisor (bin/fm-supervise-daemon.sh); presence-gated via /afk
FM_SUPERVISOR_BACKEND=             # optional supervisor pane backend override; tmux/herdr only, otherwise detects $TMUX_PANE then HERDR_ENV/HERDR_PANE_ID before tmux fallback
FM_SUPERVISOR_TARGET=              # optional supervisor pane target override; tmux target or herdr <session>:<pane-id>, otherwise auto-detected
FM_INJECT_SKIP=heartbeat           # |-prefixes force-self-handled bypassing classification; empty disables
FM_ESCALATE_BATCH_SECS=90          # buffer window for batched escalation digests; 0 = flush immediately
FM_MAX_DEFER_SECS=300              # max buffered escalation age before retry plus wedge alarm; 0 disables
FM_WEDGE_ALARM_CHANNEL=            # override config/wedge-alarm with one active-alert directive for the wedge alarm; off|auto|osascript|notify-send|herdr|command:<cmd>; absent = auto (macOS -> osascript, Linux -> notify-send when present)
FM_WEDGE_ALARM_EXEC=              # notifier seam: route every channel (osascript, notify-send, herdr, command:) through this command as `<cmd> <channel> <summary>`; "discard" fires nothing; unset in production; the daemon defaults it to "discard" when sourced so no test posts a real notification (docs/wedge-alarm.md)
FM_WEDGE_ALARM_TIMEOUT_SECS=10    # maximum seconds for each osascript, notify-send, herdr, override, or command: notifier before its watchdog terminates it and continues to the next channel; invalid or zero values use 10
FM_INJECT_FAIL_SLEEP=30            # seconds to back off when the supervisor pane is unavailable
FM_INJECT_CONFIRM_RETRIES=3        # daemon Enter-retry attempts after typing a digest once
FM_INJECT_CONFIRM_SLEEP=0.5        # seconds between daemon submit checks
FM_HEARTBEAT_SCAN_SECS=300         # cadence of the catch-all status scan for missed captain verbs
FM_HOUSEKEEPING_TICK=15            # seconds between batch-flush, stale/pause-recheck, and scan passes
FM_AFK_DRIVER_TICK_SECS=600        # cadence of the bounded away-mode queue-advancing driver tick; 0 disables the hook
FM_AFK_DRIVER_TIMEOUT_SECS=300     # maximum seconds for one driver tick before the daemon stops it and retries next cadence
FM_AFK_DRIVER_MAX_WORKERS=4        # worker cap the driver dispatches under; values above 4 clamp to 4
FM_AFK_DRIVER_DISABLE=             # set to 1 to refuse every away-mode driver tick for this home
FM_CRASH_THRESHOLD=10              # watcher crashes allowed inside FM_CRASH_WINDOW before daemon backoff
FM_CRASH_WINDOW=60                 # seconds in the crash-loop detection window
FM_CRASH_BACKOFF=60                # seconds to wait after crossing the crash threshold
FM_CRASH_NORMAL_SLEEP=5            # seconds to wait after an isolated watcher crash
FM_LOG_MAX_BYTES=1048576           # daemon log size that triggers trimming
FM_LOG_KEEP_LINES=2000             # daemon log lines kept when trimming
```

`fm-teardown.sh` retries only Git's `Unable to create '...index.lock': File exists` return failure up to `FM_TREEHOUSE_RETURN_LOCK_RETRIES` times.
`FM_TREEHOUSE_RETURN_LOCK_RETRIES` accepts a nonnegative integer, and an unset, blank, or invalid value uses the default of 3.
`FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS` accepts nonnegative whole or fractional seconds between attempts.
When it is unset or blank, `FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS` remains a compatible fallback, and a blank fallback uses the 1-second default.
An invalid nonblank wait falls back to 1 second rather than interrupting teardown.
Teardown never removes a lock during the retry window, and after that window it attempts stale-lock cleanup only for a still-present lock that passes the configured age and live-holder checks.

`fm-fleet-sync.sh` applies the same shape to an orphaned `.git/packed-refs.lock`: it retries only Git's `Unable to create '...packed-refs.lock': File exists` fetch failure up to `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES` times (nonnegative integer; unset, blank, or invalid uses the default of 3), waiting `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS` seconds (nonnegative whole or fractional; invalid falls back to 1 second) before each.
Only after those retries exhaust does it remove the lock, and only when it is provably stale - still present, mtime age at least `FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS` (default 30), and no `lsof` holder of the lock file or of the clone worktree itself (a live `git` keeps that as its cwd even in the window after it closes the lock and before it exits).
A live lock, a missing `lsof`, any failed check, or any other fetch failure keeps today's behavior.
Every wait, retry, and removal is printed to stderr, and a successful recovery also prints one `recovered:` summary line to stdout so a session-start refresh - which discards fleet-sync stderr and relays only stdout - still surfaces it.
The shared staleness proof lives in `bin/fm-lock-lib.sh`, which both `fm-teardown.sh` and `fm-fleet-sync.sh` use.
