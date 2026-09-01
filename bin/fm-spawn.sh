#!/usr/bin/env bash
# Spawn a direct report: a crewmate in a treehouse or Orca worktree, or a
# secondmate in its isolated firstmate home.
# Usage: fm-spawn.sh <task-id> <project-dir> [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] [--env <KEY=VAL>]... [--scout] [--unsupervised]
#        fm-spawn.sh <task-id> [<firstmate-home>] [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] [--env <KEY=VAL>]... --secondmate
#   --harness <name> is the explicit per-spawn harness/profile adapter. The old
#   positional harness arg still works for back-compat.
#   --model <name> and --effort <low|medium|high|xhigh|max> are concrete profile
#   axes chosen by firstmate at intake. They are only threaded into harnesses whose
#   installed CLIs were verified to support that axis; unsupported axes are omitted
#   from that harness's launch rather than guessed.
#   --env KEY=VAL (repeatable) exports KEY=VAL into the crewmate pane shell
#   before the agent launches, so the agent and every child process inherits it.
#   Last --env for the same KEY wins (shell `export` override). This is the
#   per-spawn API-token swap path for harnesses whose auth rides an env var -
#   e.g. OPENCODE_API_KEY for a second opencode-go workspace. The wrapper
#   bin/fm-spawn-joe.sh owns the canonical joe-workspace token lookup + call.
#   --backend <name> is the explicit runtime session-provider backend for this
#   spawn. Without it, the script resolves FM_BACKEND, then config/backend, then
#   runtime auto-detection (the runtime firstmate itself is executing inside -
#   $TMUX, HERDR_ENV=1, or cmux runtime signals; bin/fm-backend.sh's
#   fm_backend_detect, with cmux fallback details in docs/cmux-backend.md),
#   then tmux.
#   Spawn-capable backends are the reference tmux adapter and experimental
#   herdr, zellij, orca, and cmux. Orca owns both the task worktree and
#   terminal, so ship/scout Orca spawns do not run treehouse get; cmux is a
#   session provider only, exactly like herdr/zellij, so it does. An
#   auto-detected herdr or cmux spawn prints a loud stderr notice;
#   auto-detected tmux stays silent; zellij and orca are never auto-detected.
#   codex-app is not a known backend yet; docs/codex-app-backend.md owns that
#   blocked backend contract. Default tmux spawns do not write backend= to meta;
#   absent backend= means tmux. cmux does not support --secondmate spawns yet.
#   A backend spawn refusal (missing dependency, version gate, unauthenticated
#   socket, or unsupported secondmate mode) is terminal for that selected backend;
#   callers must surface it instead of silently retrying another backend.
#   Herdr additionally supports a default-off presentation-only layout when the
#   local config/herdr-presentation-spaces flag exists. A clean fresh task first
#   writes state/<id>.herdr-presentation atomically, then creates a disposable
#   workspace containing only the ordinary task pane. The journal and visible
#   random token are never endpoint or ownership authority. Existing, ambiguous,
#   or recovered state is never adopted, reused, closed, or deleted through that
#   presentation path; a flat launch is allowed only after duplicate-agent risk
#   is independently absent. Treehouse allocation and task metadata are unchanged.
#   A clean projected create makes one bounded attempt to hold the one
#   session-scoped presentation-order lock (keyed by named session plus
#   canonical socket, outside any home's state/) through launch handoff. Lock
#   contention warns and falls back to the ordinary flat layout before any
#   projection mutation. The exact response-derived new workspace is inserted
#   immediately after its owning parent (firstmate or 2ndmate-<id>) contiguous
#   child block. Ordering never authorizes lifecycle cleanup, and any
#   unavailable, ambiguous, or failed move warns while the spawn continues.
#   Every projected create, prune, and move captures and verifies the named
#   session's exact active workspace and tab. A detected focus change restores
#   only that exact tab id; an ambiguous pre-operation snapshot refuses the
#   focus-sensitive presentation mutation.
#   Every single-task invocation holds one task-id-scoped lock across backend
#   creation through metadata publication, so concurrent same-id spawns serialize
#   even when they select different backends.
#   With no harness arg, a crewmate/scout spawn resolves the CREW harness only when
#   config/crew-dispatch.json is absent. When that file exists, crewmate/scout
#   spawns require an explicit harness so firstmate cannot silently skip dispatch
#   profile consultation. A --secondmate spawn is exempt and resolves the SECONDMATE
#   harness (config/secondmate-harness per-id pin -> its single-line default ->
#   config/crew-harness -> own), so the
#   secondmate-vs-crewmate split is DURABLE across every respawn (recovery,
#   /updatefirstmate, restart). A bare adapter name (claude|codex|opencode|pi|grok|jcode)
#   overrides it for this spawn (either kind). A non-flag string containing
#   whitespace is treated as a RAW launch command - the escape hatch for verifying
#   new adapters.
#   config/secondmate-harness may also carry an optional model and effort as extra
#   whitespace-separated tokens ("<harness> [<model>] [<effort>]") on either the
#   single-line default or a per-id line ("<id>: <harness> [<model>] [<effort>]"),
#   resolved for THIS secondmate's id. For a
#   --secondmate spawn, those tokens apply only when this spawn also resolves its
#   harness from config/secondmate-harness. An explicit per-spawn --harness,
#   positional harness arg, or raw launch command starts with clean model/effort
#   defaults unless the caller also passes explicit --model/--effort flags. When
#   the file governs the spawn, its model/effort tokens are re-resolved on every
#   respawn exactly like the harness axis, and explicit --model/--effort flags
#   still win over the file's tokens.
#   A --secondmate spawn also propagates the primary's declared inherited local
#   material, so the secondmate's OWN crewmates inherit primary config and the
#   secondmate receives the primary's read-only shared captain-preference file
#   (fm-config-inherit-lib.sh). A successful launch clears pending inherited
#   config reread generations because the new agent reads the converged files.
#   --scout records kind=scout in the task's meta (report deliverable, scratch worktree;
#   see AGENTS.md task lifecycle); --secondmate records kind=secondmate and launches in a
#   provisioned firstmate home; the default is kind=ship.
#   --unsupervised records supervise=off in the task's meta and installs NO
#   turn-end hook, and the watcher (bin/fm-watch.sh recorded_windows) drops any
#   supervise=off pane from every supervision path: the stale/wedge loop, the
#   turn-end/event fast wake, and the context sweep. The result is a genuinely
#   hands-off pane that firstmate creates but never peeks, steers, nudges, or
#   pokes. It exists for a live interview firstmate must not touch (the
#   grilling-handoff griller pane); any firstmate injection would corrupt that
#   interview. supervise=off is orthogonal to kind and combines with the default
#   ship kind or with --scout; it is refused with --secondmate (a secondmate is
#   supervised through its status writes by design). The default omits the field,
#   so an ordinary spawn's meta stays byte-identical (absent supervise= means on).
#   Before a secondmate launch, the home is locally fast-forwarded to the primary
#   default-branch commit when safe; skipped syncs warn and launch unchanged.
#   Ship/scout spawns refuse to launch unless the project is one of THIS home's
#   own clones (a direct child of $PROJECTS) and the resolved task path is a real
#   git worktree root of that same clone, distinct from the primary checkout.
#   Every spawn also refuses a brief that still holds the bare {TASK}
#   placeholder fm-brief.sh scaffolds as the Task section body: firstmate never
#   filled in the task, so dispatching it would only waste the spawn on a
#   crewmate that can do nothing but report the empty brief. The match is
#   structural - the placeholder standing alone as a line - so a mention of the
#   token inside explanatory prose or backticks (the scaffold's own Herdr
#   declaration quotes it) does not trip the guard. The scaffold cannot know the
#   task text, so the check lives here rather than in fm-brief.sh.
# Batch dispatch: pass one or more `id=repo` pairs instead of a single <id> <project>, e.g.
#     fm-spawn.sh fix-a-k3=projects/foo add-b-q7=projects/bar [--scout]
#   Each pair re-execs this script in single-task mode, so the single path stays the only
#   source of truth; shared --scout/--harness/--model/--effort/--backend applies to every pair.
#   If config/crew-dispatch.json exists, shared --harness is required for crewmate
#   and scout batches. The loop lives here, in bash, so callers never hand-write a
#   multi-task shell loop (the tool shell is zsh, which does not word-split unquoted
#   $vars and silently breaks ad-hoc `for ... in $pairs` loops).
#   Launch templates live in launch_template() below; placeholders replaced before launch:
#     __BRIEF__    absolute path to data/<task-id>/brief.md
#     __TURNEND__  absolute path to state/<task-id>.turn-ended (for harnesses whose
#                  turn-end signal rides the launch command, e.g. codex -c notify=[...])
#     __PIEXT__    absolute path to state/<task-id>.pi-ext.ts (pi turn-end extension,
#                  written by this script; outside the worktree to avoid pi's trust gate)
#     __PITURNEND__ absolute path to .pi/extensions/fm-primary-turnend-guard.ts in a pi secondmate home
#     __PIWATCH__   absolute path to .pi/extensions/fm-primary-pi-watch.ts in a pi secondmate home
#     __OPINPUT__   absolute path to the canonical operational-input encoder
#     __PIBRIEFENV__ shell assignment identifying the unchanged Pi positional brief
#   A harness with no positional prompt (jcode) carries no __BRIEF__ placeholder:
#   its brief, model, and effort are delivered to the live session after launch by
#   jcode_post_launch_delivery(), which waits FM_SPAWN_JCODE_READY_POLLS seconds
#   for the composer, then - for an explicitly requested model/effort - pins them
#   while the session is idle and VERIFIES them against the session store BEFORE
#   submitting the launch-brief pointer (jcode defers /model|/effort while a turn
#   runs, so the brief must not start a turn first); a profile that cannot be
#   verified blocks the lane and the brief is withheld. The pointer is submitted
#   through jcode_submit_brief_verified, which re-submits Enter until the composer
#   clears, so the brief is never dropped.
# Per-harness turn-end hooks are installed automatically; some live outside the worktree.
# grok uses a firstmate-owned global hook under ${GROK_HOME:-$HOME/.grok}/hooks
# plus a gitignored .fm-grok-turnend worktree pointer and a state token.
# jcode gets NO turn-end hook: its native turn_end lifecycle hook is read by the
# shared background server rather than by the launched client, so this spawn
# cannot arm one per task. Its crewmates are supervised through stale-pane
# detection alone (harness-adapters owns the evidence and the consequence).
# Before dispatching it prints the host-resource reading from bin/fm-resource-check.sh
# to stderr as a `warning:` advisory when the host is degraded or critical; that
# is a report, never a refusal, and nothing is stopped automatically.
# Pre-spawn duplicate-dispatch guard: for a crewmate or scout (never a persistent
# secondmate), the spawn is refused loudly, before any backend mutation, when the
# task id already appears in data/completions.tsv (read through
# fm_completions_lib.sh's fm_completions_lookup) or when the task's recorded PR
# (state/<id>.meta pr=) is already merged to origin. The merged-PR probe degrades
# gracefully: an unreachable forge or missing tooling leaves the state unknown,
# which never refuses, so offline dispatch keeps working. Set
# FM_SPAWN_ALLOW_DUPLICATE=1 to override the refusal deliberately.
# On success prints: spawned <id> harness=<name> kind=<ship|scout|secondmate> mode=<mode> yolo=<on|off> window=<backend-target> worktree=<path>
# mode/yolo are resolved per-project from data/projects.md for ship/scout tasks;
# secondmate spawns record mode=secondmate, yolo=off, home=, and projects=.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The header comment IS the help text, from the line after the shebang down to
# the last comment before the first executable line. Deriving that range beats
# hardcoding it, which silently truncates --help the moment the header grows.
usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-completions-lib.sh
. "$SCRIPT_DIR/fm-completions-lib.sh"
# shellcheck source=bin/fm-token-sessions-lib.sh
. "$SCRIPT_DIR/fm-token-sessions-lib.sh"
# jcode model/effort pin seam (fm_jcode_apply_profile / fm_jcode_pin_and_verify):
# the RELIABLE debug-socket pin that replaces the TUI slash-command popup race in
# jcode_post_launch_delivery. Side-effect-free on source; depends on
# fm_session_store_profile from the token-sessions lib sourced just above.
# shellcheck source=bin/fm-jcode-profile-lib.sh
. "$SCRIPT_DIR/fm-jcode-profile-lib.sh"
# Resume-command mapping + resume-token helper for stuck-crewmate recovery
# (bin/fm-resume-lib.sh). Side-effect-free on source, like the two libs above;
# the post-launch capture below stamps the resume token so a dead session can be
# resumed in place instead of restarted from scratch.
# shellcheck source=bin/fm-resume-lib.sh
. "$SCRIPT_DIR/fm-resume-lib.sh"
# Backlog backend opt-out probe (fm_backlog_backend_manual): the post-launch
# capture mirrors the resume token into the durable task record via
# tasks-axi --resume, unless config/backlog-backend=manual opts out. Cheap
# single-file read on source; no tasks-axi call here.
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# Shared per-task telemetry writer (state/<id>.telemetry, key=value). Gap-1
# stamps the resolved Claude account (account=/account_source=) at spawn; the
# same library owns the in-place key update for sibling producers. No side
# effects on source.
# shellcheck source=bin/fm-telemetry-lib.sh
. "$SCRIPT_DIR/fm-telemetry-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never spawn
# a direct report (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent
# Seconds jcode_post_launch_delivery waits for a just-launched jcode TUI to draw
# its composer before giving up on delivering the launch profile and brief. It
# connects to an already-running shared server, so this is client startup only.
FM_SPAWN_JCODE_READY_POLLS=${FM_SPAWN_JCODE_READY_POLLS:-30}
# The brief is the LAST and longest message jcode_post_launch_delivery submits,
# and it is the one that used to race jcode's slash-command handling and get
# dropped: the composer was left holding the typed-but-unsubmitted brief while
# the short /model and /effort lines landed (observed twice 2026-08-10,
# data/learnings.md "jcode spawn: /model ... verdict pending + brief dropped").
# The fix submits the brief as its own separately-verified step: after the slash
# commands settle, confirm the composer actually cleared and re-submit if it did
# not, up to FM_SPAWN_JCODE_BRIEF_SUBMIT_TRIES attempts. This mirrors the
# verified-submit model bin/fm-send.sh already uses, so a swallowed brief Enter
# is retried rather than silently abandoned. FM_SPAWN_JCODE_BRIEF_SETTLE is the
# per-attempt pause before re-reading the composer.
FM_SPAWN_JCODE_BRIEF_SUBMIT_TRIES=${FM_SPAWN_JCODE_BRIEF_SUBMIT_TRIES:-3}
FM_SPAWN_JCODE_BRIEF_SETTLE=${FM_SPAWN_JCODE_BRIEF_SETTLE:-1}
# Before the brief is delivered, jcode_post_launch_delivery PINS an explicitly
# requested launch profile through jcode's race-free debug socket
# (`jcode debug -S <sid> set_model:{"model":..,"effort":..}`, applied atomically
# server-side under the agent lock) and VERIFIES it against the jcode session
# store (the only truth for what a session actually runs; incident 2026-08-23,
# data/learnings.md "MODEL DRIFT INCIDENT": the old slash-popup race silently
# lost /model|/effort, leaving three tooling lanes on the wrong model at max
# effort for hours). The debug verb waits out any in-flight turn rather than
# being deferred-and-forgotten like a typed /model|/effort, so the pin lands even
# if a turn is running; it persists to the store, which is read back to confirm.
# On a mismatch the pin is re-applied and the store re-read, at most
# FM_SPAWN_JCODE_VERIFY_TRIES verification attempts; a store that still disagrees
# appends a `blocked: model-drift` status so the watcher escalates and the brief
# is withheld, never a quiet continue on the wrong model. FM_SPAWN_JCODE_VERIFY_SETTLE
# is the settle before each store read (the store write can lag the verb return
# under filesystem load).
FM_SPAWN_JCODE_VERIFY_TRIES=${FM_SPAWN_JCODE_VERIFY_TRIES:-3}
FM_SPAWN_JCODE_VERIFY_SETTLE=${FM_SPAWN_JCODE_VERIFY_SETTLE:-3}
# Skip the watcher guard when re-exec'd for one pair of a batch (FM_SPAWN_NO_GUARD is
# set by the batch loop below), so the guard runs once for the batch, not once per pair.
[ -n "${FM_SPAWN_NO_GUARD:-}" ] || "$FM_ROOT/bin/fm-guard.sh" || true
# Host-resource advisory before dispatch: adding a crew to an already-thrashing
# host is how a healthy fleet turns into a scatter of phantom test failures. This
# REPORTS and never refuses or sheds - whether to stop work is the captain's
# call, not this script's. Same batch gate as the guard above, so a batch warns
# once rather than once per pair. A healthy, unknown or disabled reading is silent.
# The check runs WITHOUT --sweep, so it reads the watcher's cached crew-liveness
# verdict and never probes a backend: a wedged backend cannot delay a dispatch.
if [ -z "${FM_SPAWN_NO_GUARD:-}" ]; then
  RESOURCE_OUT=$("$FM_ROOT/bin/fm-resource-check.sh" 2>/dev/null) && RESOURCE_RC=0 || RESOURCE_RC=$?
  case "$RESOURCE_RC" in
    1|2)
      printf '%s\n' "$RESOURCE_OUT" | while IFS= read -r resource_line; do
        printf 'warning: %s\n' "$resource_line" >&2
      done
      printf 'warning: the host is under resource pressure; consider finishing or stopping heavy work before adding another crew (nothing is stopped automatically).\n' >&2
      ;;
  esac
fi
KIND=ship
UNSUPERVISED=off
HARNESS_ARG=
MODEL=
EFFORT=
BACKEND_ARG=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
BACKEND_SET=0
ENV_OVERRIDES=()
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      harness) HARNESS_ARG=$a; HARNESS_SET=1 ;;
      model) MODEL=$a; MODEL_SET=1 ;;
      effort) EFFORT=$a; EFFORT_SET=1 ;;
      backend) BACKEND_ARG=$a; BACKEND_SET=1 ;;
      env_override)
        case "$a" in
          *=*) ;;
          *) echo "error: --env requires KEY=VAL (got: $a)" >&2; exit 1 ;;
        esac
        ENV_OVERRIDES+=("$a")
        ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --unsupervised) UNSUPERVISED=on ;;
    --harness) want_value=harness ;;
    --harness=*) HARNESS_ARG=${a#--harness=}; HARNESS_SET=1 ;;
    --model) want_value=model ;;
    --model=*) MODEL=${a#--model=}; MODEL_SET=1 ;;
    --effort) want_value=effort ;;
    --effort=*) EFFORT=${a#--effort=}; EFFORT_SET=1 ;;
    --backend) want_value=backend ;;
    --backend=*) BACKEND_ARG=${a#--backend=}; BACKEND_SET=1 ;;
    --env) want_value=env_override ;;
    --env=*)
      v=${a#--env=}
      case "$v" in
        *=*) ;;
        *) echo "error: --env requires KEY=VAL (got: $v)" >&2; exit 1 ;;
      esac
      ENV_OVERRIDES+=("$v")
      ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "$HARNESS_SET" -eq 0 ] || [ -n "$HARNESS_ARG" ] || { echo "error: --harness requires a non-empty value" >&2; exit 1; }
[ "$MODEL_SET" -eq 0 ] || [ -n "$MODEL" ] || { echo "error: --model requires a non-empty value" >&2; exit 1; }
[ "$EFFORT_SET" -eq 0 ] || [ -n "$EFFORT" ] || { echo "error: --effort requires a non-empty value" >&2; exit 1; }
[ "$BACKEND_SET" -eq 0 ] || [ -n "$BACKEND_ARG" ] || { echo "error: --backend requires a non-empty value" >&2; exit 1; }
# --unsupervised is a hands-off crewmate/scout pane; a secondmate is supervised
# through its own status writes by design, so the combination is contradictory.
[ "$UNSUPERVISED" = off ] || [ "$KIND" != secondmate ] || { echo "error: --unsupervised cannot combine with --secondmate" >&2; exit 1; }
# Validate each --env KEY=VAL form. KEY must be a POSIX shell env-var name
# (letters/digits/underscore, not starting with a digit); VAL is anything (may
# be empty).
for kv in "${ENV_OVERRIDES[@]+"${ENV_OVERRIDES[@]}"}"; do
  k=${kv%%=*}
  case "$k" in
    ''|[0-9]*|*[!A-Za-z0-9_]*)
      echo "error: --env KEY must be a POSIX env var name (got: $k)" >&2; exit 1 ;;
  esac
done
case "$EFFORT" in
  ''|low|medium|high|xhigh|max) ;;
  *) echo "error: --effort must be one of low, medium, high, xhigh, max" >&2; exit 1 ;;
esac

# Backend selection (data/fm-backend-design-d7): explicit --backend, else
# FM_BACKEND env, else config/backend, else runtime auto-detection, else
# default tmux (fm_backend_name). fm_backend_validate_spawn refuses unknown or
# non-spawn-capable backends. The resolved value is
# recorded in meta only when it is NOT tmux (fm-teardown.sh and fm-watch.sh's
# window_backend/fm_backend_of_meta already treat an absent backend= as tmux),
# so the default path's meta stays byte-identical.
if [ "$BACKEND_SET" -eq 1 ]; then
  BACKEND=$BACKEND_ARG
else
  BACKEND=$(fm_backend_name)
fi
fm_backend_validate_spawn "$BACKEND" || exit 1
fm_backend_source "$BACKEND" || exit 1
if [ "$BACKEND" = orca ] && [ "$KIND" = secondmate ]; then
  echo "error: backend=orca does not support --secondmate spawns yet" >&2
  exit 1
fi
if [ "$BACKEND" = cmux ] && [ "$KIND" = secondmate ]; then
  echo "error: backend=cmux does not support --secondmate spawns yet" >&2
  exit 1
fi
if [ "$BACKEND" = orca ]; then
  fm_backend_orca_runtime_check || exit 1
fi
ORCA_ABORT_CLEANUP=0
ORCA_WORKTREE_ID=
ORCA_TERMINAL=
HERDR_PROJECTION_ABORT_CLEANUP=0
HERDR_PROJECTION_ABORT_SESSION=
HERDR_PROJECTION_ABORT_TASK_PANE=
HERDR_PROJECTION_ABORT_SEEDED_PANE=
HERDR_PRESENTATION_ORDER_LOCK=
HERDR_PRESENTATION_ORDER_LOCK_HELD=0
SPAWN_TASK_LOCK=
SPAWN_TASK_LOCK_HELD=0
CONFIG_INHERIT_LOCK=
CONFIG_INHERIT_LOCK_HELD=0

parse_orca_worktree_result() {
  local raw=$1 rest
  ORCA_WORKTREE_ID=${raw%%$'\t'*}
  if [ "$raw" = "$ORCA_WORKTREE_ID" ]; then
    WT=
    ORCA_TERMINAL=
    return 1
  fi
  rest=${raw#*$'\t'}
  WT=${rest%%$'\t'*}
  if [ "$rest" != "$WT" ]; then
    ORCA_TERMINAL=${rest#*$'\t'}
  else
    ORCA_TERMINAL=
  fi
}

spawn_abort_cleanup() {
  local status=$?
  if [ "$HERDR_PROJECTION_ABORT_CLEANUP" = 1 ] \
     && [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" != 1 ]; then
    if ! spawn_herdr_presentation_order_lock_acquire "${HERDR_PROJECTION_ABORT_SESSION:-}"; then
      echo "warning: herdr presentation focus lock unavailable; retaining the projection journal and refusing concurrent abort cleanup" >&2
      HERDR_PROJECTION_ABORT_CLEANUP=0
    fi
  fi
  if [ "$HERDR_PROJECTION_ABORT_CLEANUP" = 1 ]; then
    HERDR_PROJECTION_ABORT_CLEANUP=0
    fm_backend_herdr_projection_cleanup_exact \
      "$HERDR_PROJECTION_ABORT_SESSION" \
      "$HERDR_PROJECTION_ABORT_TASK_PANE" \
      "$HERDR_PROJECTION_ABORT_SEEDED_PANE" || true
  fi
  if [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" = 1 ]; then
    HERDR_PRESENTATION_ORDER_LOCK_HELD=0
    fm_lock_release "$HERDR_PRESENTATION_ORDER_LOCK" || true
  fi
  if [ "$ORCA_ABORT_CLEANUP" = 1 ]; then
    ORCA_ABORT_CLEANUP=0
    if [ -n "${ORCA_TERMINAL:-}" ]; then
      fm_backend_kill orca "$ORCA_TERMINAL" 2>/dev/null || true
    fi
    if [ -n "${ORCA_WORKTREE_ID:-}" ]; then
      if ! fm_backend_remove_worktree orca "$ORCA_WORKTREE_ID" 2>/dev/null; then
        mkdir -p "$STATE" 2>/dev/null || true
        if [ -d "$STATE" ]; then
          {
            echo "window=$W"
            echo "worktree=${WT:-}"
            echo "project=$PROJ_ABS"
            echo "harness=$HARNESS"
            echo "kind=$KIND"
            echo "mode=${MODE:-no-mistakes}"
            echo "yolo=${YOLO:-off}"
            echo "tasktmp=${TASK_TMP:-}"
            echo "model=${MODEL:-default}"
            echo "effort=${EFFORT:-default}"
            echo "backend=orca"
            echo "orca_worktree_id=$ORCA_WORKTREE_ID"
            [ -z "${ORCA_TERMINAL:-}" ] || echo "terminal=$ORCA_TERMINAL"
          } > "$STATE/$ID.meta" 2>/dev/null || true
        fi
      fi
    fi
  fi
  if [ "$SPAWN_TASK_LOCK_HELD" = 1 ]; then
    SPAWN_TASK_LOCK_HELD=0
    fm_lock_release "$SPAWN_TASK_LOCK" || true
  fi
  if [ "$CONFIG_INHERIT_LOCK_HELD" = 1 ]; then
    CONFIG_INHERIT_LOCK_HELD=0
    fm_lock_release "$CONFIG_INHERIT_LOCK" || true
  fi
  return "$status"
}
trap spawn_abort_cleanup EXIT

# One bounded lock per live Herdr session/socket, shared across all homes.
# <session> is required so secondmate and primary spawns serialize against the
# same session without writing any other home's state directory.
spawn_herdr_presentation_order_lock_acquire() {
  local session=${1:-} attempt lock_path
  [ -n "$session" ] || session=$(fm_backend_herdr_session)
  lock_path=$(fm_backend_herdr_presentation_session_lock_path "$session") || return 1
  HERDR_PRESENTATION_ORDER_LOCK="$lock_path"
  attempt=0
  while [ "$attempt" -lt 50 ]; do
    if fm_lock_try_acquire "$HERDR_PRESENTATION_ORDER_LOCK"; then
      HERDR_PRESENTATION_ORDER_LOCK_HELD=1
      return 0
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

spawn_herdr_presentation_order_lock_release() {
  [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" = 1 ] || return 0
  HERDR_PRESENTATION_ORDER_LOCK_HELD=0
  fm_lock_release "$HERDR_PRESENTATION_ORDER_LOCK" || true
}

# Batch dispatch (see header): when the first positional is an `id=repo` pair, treat every
# positional as one and spawn each by re-execing this script in single-task mode. We use
# the FM_ROOT path (not $0) so it works whatever cwd or relative path invoked us, and reuse
# the single path verbatim. A failed pair is reported and skipped; the rest still launch;
# exit is non-zero if any pair failed. Single-task invocations never carry an '=' in arg
# one (task ids are bare slugs), so they fall straight through to the logic below.
idpart=${POS[0]:-}
idpart=${idpart%%=*}
if [ "${#POS[@]}" -gt 0 ] && [ "${POS[0]}" != "$idpart" ] && case "$idpart" in */*) false ;; *) true ;; esac; then
  if [ "$KIND" != secondmate ] && [ -z "$HARNESS_ARG" ] && [ -f "$CONFIG/crew-dispatch.json" ]; then
    echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
    exit 1
  fi
  rc=0
  shared_args=()
  [ -z "$HARNESS_ARG" ] || shared_args+=(--harness "$HARNESS_ARG")
  [ -z "$MODEL" ] || shared_args+=(--model "$MODEL")
  [ -z "$EFFORT" ] || shared_args+=(--effort "$EFFORT")
  [ -z "$BACKEND_ARG" ] || shared_args+=(--backend "$BACKEND_ARG")
  [ "$UNSUPERVISED" = off ] || shared_args+=(--unsupervised)
  for pair in "${POS[@]}"; do
    case "$pair" in
      *=*) : ;;
      *) echo "error: batch dispatch expects every argument as id=repo; got '$pair'" >&2; rc=2; continue ;;
    esac
    if [ "$KIND" = secondmate ]; then
      echo "error: batch dispatch does not support --secondmate; spawn each secondmate explicitly" >&2
      rc=2
      continue
    elif [ "$KIND" = scout ]; then
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" "${shared_args[@]+"${shared_args[@]}"}" --scout; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    else
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" "${shared_args[@]+"${shared_args[@]}"}"; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    fi
  done
  exit "$rc"
fi
ID=${POS[0]}
fm_task_id_creation_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
SPAWN_TASK_LOCK="$STATE/.spawn-$ID.lock"
if ! fm_lock_try_acquire "$SPAWN_TASK_LOCK"; then
  echo "error: another spawn is already creating task $ID" >&2
  exit 1
fi
SPAWN_TASK_LOCK_HELD=1

# Pre-spawn duplicate-dispatch guard (warn-and-STOP, fail closed): a worker must
# never be spawned onto work that already landed. The close side of the
# build-batch-doclint-pass double-build incident was fixed by PR #85; this is the
# dispatch side. Two independent checks, both refuse loudly rather than skipping:
#   1. The task id already appears in data/completions.tsv (the append-only,
#      never-pruned completion ledger). Read through fm_completions_lookup, the
#      single owner of field mechanics, never by hand-parsing columns.
#   2. The task's recorded PR/MR (state/<id>.meta pr=) is already merged to the
#      forge default branch. This probe degrades gracefully: an unreachable forge
#      or missing tooling leaves the merge state unknown, which never refuses -
#      only a confirmed merge refuses - so offline dispatch keeps working.
# A secondmate is persistent and legitimately respawns for recovery and updates,
# so this guard is scoped to crewmate/scout ship-or-scout spawns only. The
# operator can override deliberately with FM_SPAWN_ALLOW_DUPLICATE=1.
if [ "$KIND" != secondmate ] && [ "${FM_SPAWN_ALLOW_DUPLICATE:-}" != 1 ]; then
  if dup_hit=$(fm_completions_lookup "$DATA" "$ID"); then
    echo "error: refusing to spawn '$ID' - it already reached completion (data/completions.tsv):" >&2
    printf '%s\n' "$dup_hit" | while IFS= read -r dup_line; do
      printf '  %s\n' "$dup_line" >&2
    done
    echo "This work already landed. Re-run with FM_SPAWN_ALLOW_DUPLICATE=1 to override deliberately." >&2
    exit 1
  fi
  dup_meta="$STATE/$ID.meta"
  if [ -f "$dup_meta" ]; then
    dup_pr=$(fm_meta_get "$dup_meta" pr)
    if [ -n "$dup_pr" ] && fm_pr_url_parse "$dup_pr"; then
      dup_state=$("$SCRIPT_DIR/fm-pr-poll.sh" --validated \
        "$FM_PR_PROVIDER" "$FM_PR_URL" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" 2>/dev/null || true)
      if [ "$dup_state" = merged ]; then
        echo "error: refusing to spawn '$ID' - its recorded PR is already merged to origin: $dup_pr" >&2
        echo "This work already shipped. Re-run with FM_SPAWN_ALLOW_DUPLICATE=1 to override deliberately." >&2
        exit 1
      fi
    fi
  fi
fi

PROJ=
ARG3=
FIRSTMATE_HOME=

if [ "$KIND" = secondmate ]; then
  case "${POS[1]:-}" in
    ''|claude|codex|opencode|pi|grok|jcode)
      ARG3=${POS[1]:-}
      ;;
    *' '*)
      if [ "${#POS[@]}" -gt 2 ] || [ -d "${POS[1]}" ]; then
        FIRSTMATE_HOME=${POS[1]}
        ARG3=${POS[2]:-}
      else
        ARG3=${POS[1]}
      fi
      ;;
    *)
      FIRSTMATE_HOME=${POS[1]}
      ARG3=${POS[2]:-}
      ;;
  esac
else
  PROJ=${POS[1]}
  ARG3=${POS[2]:-}
fi
[ -z "$HARNESS_ARG" ] || ARG3=$HARNESS_ARG

# The verified launch command per adapter. The knowledge half of each adapter
# (busy signature, exit command, dialogs, quirks) lives in the harness-adapters skill.
launch_template() {
  local harness=$1 kind=${2:-ship}
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
  case "$harness" in
    # CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false disables claude's interactive
    # predicted-next-prompt ghost text, which renders as dim/faint text inside an
    # otherwise-empty composer and would otherwise read like real typed input when
    # firstmate captures the pane (see the harness-adapters skill). It is a per-launch env
    # prefix scoped to this firstmate-launched agent; it never touches the captain's
    # global config. The CLI's --prompt-suggestions flag is print/SDK-mode only and
    # does NOT suppress the interactive ghost text (verified empirically), so the env
    # var is the correct control. The dim-aware composer reader in fm-tmux-lib.sh is
    # the defense-in-depth backstop for any pane this flag cannot reach.
    # IS_SANDBOX=1 is injected ONLY when firstmate runs as root (uid 0). claude
    # refuses --dangerously-skip-permissions under root/sudo ("cannot be used with
    # root/sudo privileges for security reasons"), which fails every claude crew
    # spawn closed at launch on a root-run server (verified 2026-07-30 and
    # 2026-07-31). IS_SANDBOX=1 clears that root refusal. It is gated on uid 0 so a
    # normal non-root host keeps the byte-identical launch template and is never
    # weakened by the sandbox hint.
    claude)
      local claude_sandbox=''
      [ "$(id -u)" = 0 ] && claude_sandbox='IS_SANDBOX=1 '
      printf '%s' "${claude_sandbox}"'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--prompt "$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    pi)
      if [ "$kind" = secondmate ]; then
        printf '%s' '__PIBRIEFENV__ pi __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s' '__PIBRIEFENV__ pi __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      fi
      ;;
    # grok (Grok Build TUI): a positional prompt starts the supervised interactive
    # session. --always-approve auto-approves every tool execution (verified: the
    # crewmate runs fully autonomously, no permission gate), which an unattended
    # crewmate needs; it is the targeted equivalent of claude's
    # --dangerously-skip-permissions. grok's turn-end signal does NOT ride the
    # launch command - it is a Stop-event hook installed below (global hook +
    # per-task pointer), so the template is identical for ship/scout/secondmate.
    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    # jcode: the ONLY verified adapter with no positional prompt - `jcode 'text'`
    # is rejected as an unrecognized subcommand - so the brief is delivered AFTER
    # launch by jcode_post_launch_delivery below, and the launch command carries
    # no brief, model, or effort placeholder at all. --no-update keeps the launcher
    # from interrupting the spawn with an update check. Tools run with no
    # permission prompt by default, so there is no autonomy flag to pass and no
    # trust dialog to accept (verified 2026-07-30, jcode server 0.64.2: a spawned
    # session ran a bash tool unattended in a fresh git worktree). Model and
    # effort launch flags are deliberately omitted: jcode's agent runs in a
    # shared background server, and when that server is already up - it always is
    # in practice - the launcher prints "provider/model flags only apply when
    # starting a new server" and ignores them, so both axes are applied
    # per-session after launch instead. No turn-end hook is installed: jcode's
    # native turn_end lifecycle hook is read by the shared server, not by the
    # client this spawn launches, so a per-task hook cannot be armed from here
    # (evidence and the supervision consequence: harness-adapters).
    jcode) printf '%s' 'jcode --no-update' ;;
    *) return 1 ;;
  esac
}

# jcode_post_launch_delivery: apply the resolved launch profile and deliver the
# brief to a just-launched jcode session, the work its launch command cannot do.
#
# Ordering is a HARD GATE when a model or effort is explicitly requested: the
# model and effort are pinned AND VERIFIED against the session store BEFORE the
# brief is ever submitted, so the first real turn cannot run on the wrong route.
# The account line (when present) is one message typed into the composer and
# submitted through the target backend's own verified submit path, with the same
# slash-autocomplete popup settle bin/fm-send.sh uses. Model and effort are NOT
# typed: they are pinned through the debug socket (see below), so there is no
# slash-popup race to lose them to.
#
# WHY the debug socket for model/effort (the fix for the recurring model-drift
# incidents): a TYPED /model or /effort is DEFERRED behind the agent lock while a
# turn is running (jcode-app-core server/provider_control.rs handle_set_model /
# handle_set_reasoning_effort spawn a deferred mutation when agent.try_lock()
# fails), and it can also be swallowed by the slash-autocomplete popup - the two
# silent-loss modes behind the 2026-08-23 "MODEL DRIFT INCIDENT" (three tooling
# lanes ran the wrong model at max effort for hours), the 2026-08-11 effort-pin
# failures (came up High on 3 of 4 spawns), and the "verdict pending + brief
# raced ahead" reports. jcode's debug-socket verb
# `jcode debug -S <sid> set_model:{"model":..,"effort":..}` avoids BOTH modes: it
# runs server-side under `agent.lock().await` (jcode-app-core
# server/debug_command_exec.rs -> agent.set_model_and_effort), so a call issued
# while a turn is in flight WAITS for the turn and then applies rather than being
# deferred-and-forgotten, and it never touches the composer so there is no popup
# to lose it to. It applies model+effort atomically (a rejected effort rolls the
# model back), persists to the store, and returns the applied values, failing
# loud on a bad model or effort. This is delivered by fm_jcode_pin_and_verify in
# bin/fm-jcode-profile-lib.sh, which also fixes the busy re-send path for free:
# the same lock-waiting apply is what bin/fm-jcode-repin.sh uses to re-pin a
# drifted live lane.
#
# The jcode session store (~/.jcode/sessions/<sid>.json, fields model and
# reasoning_effort; sid resolved with fm_resolve_crew_session_id) stays the ONLY
# verification oracle; the debug verb's return is not trusted on its own. For an
# explicit profile the store is read back until it CONFIRMS the requested axis
# values, re-applying between reads, bounded by FM_SPAWN_JCODE_VERIFY_TRIES. Only
# on a positive match are the CONFIRMED values stamped into the task meta as
# model=/effort= (fm_meta_get is last-write-wins, so the append overrides the
# requested values the spawn recorded) and the brief delivered. On exhaustion -
# an unresolvable session, an unreadable store, or a debug verb that could not
# apply - the function appends `blocked: model-drift wanted=<m>/<e>
# actual=<m>/<e>` to the task status file (the watcher escalates it) and WITHHOLDS
# the brief, returning failure: a loud blocked lane, never silent wrong-model work.
#
# The brief is delivered as a POINTER to data/<id>/brief.md rather than as the
# brief text: the brief is many lines, and every backend's composer submit is
# line-oriented, so a raw newline would submit a partial brief. That matches
# AGENTS.md's standing rule that long instructions travel as a file. The pointer
# still rides the canonical launch-brief operational input, so the crewmate
# receives it as a structurally typed launch brief exactly like every other
# harness. It is submitted through jcode_submit_brief_verified, which confirms
# the composer actually cleared and re-submits Enter if it did not.
#
# A DEFAULT profile (no explicit model and no explicit effort) has nothing to
# pin: verification is skipped and the brief is delivered directly, so a normal
# spawn stays byte-identical - no store read, no meta stamp, no escalation. The
# account pin, when present, rides the same idle pre-brief send but is best-effort
# and unverified (the store carries no account field to read it back).
jcode_post_launch_delivery() {  # <target> <brief-path> <model> <effort> [<account>] [<worktree> <spawn_ts> <status-file> <meta-file>]
  local target=$1 brief=$2 model=$3 effort=$4 account=${5:-} i=0 state=unknown verdict line
  local worktree=${6:-} spawn_ts=${7:-} status_file=${8:-} meta_file=${9:-}
  local slash_lines=() want_model=- want_effort=- actual_model='' actual_effort=''
  local attempt=0 sid='' tmp kv drift_msg brief_line confirmed=''
  # Wait for the TUI: until its composer row exists there is nothing to type
  # into, and a message typed into the still-starting client is lost.
  while [ "$i" -lt "$FM_SPAWN_JCODE_READY_POLLS" ]; do
    state=$(fm_backend_composer_state "$BACKEND" "$target" 2>/dev/null) || state=unknown
    [ "$state" = unknown ] || break
    sleep 1
    i=$((i + 1))
  done
  if [ "$state" = unknown ]; then
    echo "warning: jcode composer did not appear within ${FM_SPAWN_JCODE_READY_POLLS}s on $target; the launch profile and brief were not delivered" >&2
    return 1
  fi
  # Encode the brief pointer up front so an encode failure aborts before any
  # slash command is sent (nothing half-applied) rather than after a verified pin.
  brief_line=$(printf 'Read %s and follow it as your task brief.' "$brief" \
    | "$FM_ROOT/bin/fm-operational-input.sh" encode launch-brief) \
    || { echo "warning: could not encode the jcode launch brief for $target" >&2; return 1; }
  # Account pin FIRST: the orchestrator (quota-axi decide, consulted before
  # launch) chose a non-exhausted Claude account for this jcode worker, applied
  # here through jcode's own per-session `/account claude switch <label>` slash
  # command - the same reversible control surface bin/fm-switch-account.sh drives.
  # It may reset the provider session, so it precedes the model/effort pin. Empty
  # (orchestrator unavailable/keep decision) leaves the session on its default
  # account. It is best-effort and NOT verified (no store field to read it back).
  if [ -n "$account" ]; then
    slash_lines+=("/account claude switch $account")
  fi
  if [ -n "$model" ] && [ "$model" != default ]; then
    want_model=$model
  fi
  if [ -n "$effort" ] && [ "$effort" != default ]; then
    want_effort=$effort
  fi
  # Send the ACCOUNT slash line ONCE while the session is still IDLE (no brief
  # yet, so no turn has started and jcode defers nothing). The account has no
  # store field to read back and no debug verb, so it stays on the best-effort
  # slash path; a pending/send-failed verdict is warned about, never a gate.
  # Model and effort do NOT ride this path: they are pinned through the
  # race-free debug socket below (fm_jcode_pin_and_verify), so there is no typed
  # /model|/effort to lose to the slash-autocomplete popup and no noisy
  # "verdict pending" warning on a pin that actually landed.
  for line in "${slash_lines[@]}"; do
    verdict=$(fm_backend_send_text_submit "$BACKEND" "$target" "$line" 3 0.4 1.2 2>/dev/null) || verdict=send-failed
    case "$verdict" in
      pending|send-failed)
        echo "warning: jcode did not confirm '$line' on $target (verdict $verdict); it is best-effort and not gated" >&2
        ;;
    esac
    sleep 1
  done
  # DEFAULT profile (no explicit model AND no explicit effort): nothing to pin,
  # so skip verification and deliver the brief. This keeps a normal spawn
  # byte-identical - no store read, no meta stamp, no escalation.
  if [ "$want_model" = - ] && [ "$want_effort" = - ]; then
    if ! jcode_submit_brief_verified "$target" "$brief_line"; then
      echo "warning: jcode did not confirm the brief submitted on $target (the composer still held the unsubmitted brief after ${FM_SPAWN_JCODE_BRIEF_SUBMIT_TRIES} attempts); inspect the pane before relying on the task" >&2
      return 1
    fi
    return 0
  fi
  # EXPLICIT model/effort: HARD GATE, verify BEFORE the brief. Verification needs
  # the worktree+spawn_ts anchors to resolve the session id and a status file to
  # fail loud into; the real spawn always passes them. If they are missing we
  # cannot verify an explicit pin, so WITHHOLD the brief rather than risk
  # wrong-model work.
  if [ -z "$worktree" ] || [ -z "$spawn_ts" ] || [ -z "$status_file" ]; then
    echo "warning: cannot verify the jcode launch profile on $target (wanted ${want_model}/${want_effort}); the worktree/spawn_ts/status anchors are missing, so the brief is withheld" >&2
    return 1
  fi
  # Resolve the session id, tolerating a store write that lags the composer
  # coming up. The debug-socket pin needs a session id to target; without one
  # there is nothing to pin, which fails loud below with actual=-/-.
  attempt=0
  while [ "$attempt" -lt "$FM_SPAWN_JCODE_VERIFY_TRIES" ]; do
    attempt=$((attempt + 1))
    sid=$(fm_resolve_crew_session_id "$worktree" "$spawn_ts" 2>/dev/null || true)
    [ -n "$sid" ] && break
    sleep "$FM_SPAWN_JCODE_VERIFY_SETTLE"
  done
  # Pin the profile through the RACE-FREE debug socket and CONFIRM it against the
  # store: jcode's `debug -S <sid> set_model:{...}` takes the agent lock (waits
  # out any in-flight turn, never deferred-and-forgotten the way a typed slash
  # is), applies model+effort atomically, and persists to the store, so one apply
  # normally verifies on the first read. fm_jcode_pin_and_verify retries as a
  # fail-closed backstop for a store write that lags the return. It prints the
  # CONFIRMED store values on success (one line per requested axis); empty on
  # exhaustion.
  if [ -n "$sid" ]; then
    if confirmed=$(fm_jcode_pin_and_verify "$sid" "$want_model" "$want_effort" \
        "$FM_SPAWN_JCODE_VERIFY_TRIES" "$FM_SPAWN_JCODE_VERIFY_SETTLE"); then
      # VERIFIED. Stamp the CONFIRMED values into the meta so later readers (the
      # heartbeat drift watch) compare against what this session REALLY runs, not
      # what the spawn wanted. Last-write-wins parsing (fm_meta_get tails the
      # file), so these appends override the requested values. THEN deliver the
      # brief - only now, with the pin proven.
      if [ -n "$meta_file" ]; then
        printf '%s\n' "$confirmed" >> "$meta_file"
      fi
      if ! jcode_submit_brief_verified "$target" "$brief_line"; then
        echo "warning: jcode did not confirm the brief submitted on $target (the composer still held the unsubmitted brief after ${FM_SPAWN_JCODE_BRIEF_SUBMIT_TRIES} attempts); inspect the pane before relying on the task" >&2
        return 1
      fi
      return 0
    fi
    # The pin did not verify: read the store one last time so the blocked line
    # reports what the session actually runs (or -/- when unreadable).
    tmp=$(fm_session_store_profile "$sid" 2>/dev/null || true)
    actual_model='' actual_effort=''
    while IFS= read -r kv; do
      case "$kv" in
        model=*) actual_model=${kv#model=} ;;
        effort=*) actual_effort=${kv#effort=} ;;
      esac
    done <<EOF
$tmp
EOF
  fi
  # Unverifiable - an unresolvable session, an unreadable store, or a debug verb
  # that could not apply the profile. FAIL LOUD and WITHHOLD the brief: a
  # `blocked: model-drift` status line is captain-relevant, so the watcher
  # escalates it; the same line goes to the spawn caller. actual_* is the last
  # store read (or `-` when the session/store was never readable). A loud blocked
  # lane beats silent wrong-model hours.
  drift_msg="blocked: model-drift wanted=${want_model}/${want_effort} actual=${actual_model:--}/${actual_effort:--}"
  echo "$drift_msg" >> "$status_file"
  echo "warning: $drift_msg on $target; the launch profile did not verify after ${FM_SPAWN_JCODE_VERIFY_TRIES} attempts, so the brief was withheld" >&2
  return 1
}

# jcode_submit_brief_verified: type the brief once, submit it, then INDEPENDENTLY
# confirm the composer cleared - and if it did not, re-submit Enter only (never
# retype, which would duplicate the brief) up to FM_SPAWN_JCODE_BRIEF_SUBMIT_TRIES
# times. This is the separately-verified brief-submit step: jcode drops the last,
# longest paste under slash-command racing, so a single submit-and-trust is not
# enough for the payload. Composer verdicts (fm_backend_composer_state): `empty`
# means the box cleared (brief submitted, turn idle or already running - jcode's
# idle "N>" and busy "N…" rows both read empty); `pending` means the brief is
# still sitting unsubmitted, the retry cue; `unknown` means the pane could not be
# read, treated leniently as delivered at exhaustion exactly as bin/fm-send.sh
# treats an unreadable pane, since only a positively-confirmed swallow is an error.
jcode_submit_brief_verified() {  # <target> <brief-line>
  local target=$1 line=$2 attempt=0 typed=0 verdict state last=unknown
  while [ "$attempt" -lt "$FM_SPAWN_JCODE_BRIEF_SUBMIT_TRIES" ]; do
    attempt=$((attempt + 1))
    if [ "$typed" -eq 0 ]; then
      # First attempt types the brief once and runs the backend's own
      # verified type+submit (it retries Enter internally, never retyping).
      verdict=$(fm_backend_send_text_submit "$BACKEND" "$target" "$line" 3 0.4 0.3 2>/dev/null) || verdict=send-failed
      typed=1
      [ "$verdict" = empty ] && return 0
    else
      # The brief text is already in the composer from a prior swallowed attempt;
      # re-submit Enter ONLY. Retyping would duplicate the brief.
      fm_backend_send_key "$BACKEND" "$target" Enter 2>/dev/null || true
    fi
    sleep "$FM_SPAWN_JCODE_BRIEF_SETTLE"
    state=$(fm_backend_composer_state "$BACKEND" "$target" 2>/dev/null) || state=unknown
    last=$state
    [ "$state" = empty ] && return 0
  done
  # Exhausted. A composer still positively holding the brief (pending) is a hard
  # failure; an unreadable pane (unknown) is lenient, assume delivered.
  case "$last" in
    pending) return 1 ;;
    *) return 0 ;;
  esac
}

case "$ARG3" in
  *' '*)  # raw launch command (unverified-adapter escape hatch)
    LAUNCH=$ARG3
    HARNESS=""
    for word in $LAUNCH; do
      case "$word" in [A-Za-z_]*=*) continue ;; *) HARNESS=$(basename "$word"); break ;; esac
    done
    ;;
  '')
    # No explicit harness: resolve from config. A secondmate AGENT launches on the
    # secondmate harness (config/secondmate-harness -> config/crew-harness -> own);
    # every other kind uses the crew harness only when no dispatch profile file is
    # active. Resolving here on every spawn is what makes the split DURABLE - a
    # respawn (recovery, /updatefirstmate, restart) re-resolves, so
    # config/secondmate-harness keeps governing secondmate launches across restarts.
    # The launch_template lookup below is the unverified-adapter guard for both
    # kinds: a harness with no template aborts the spawn.
    if [ "$KIND" = secondmate ]; then
      HARNESS=$("$FM_ROOT/bin/fm-harness.sh" secondmate "$ID")
      harness_src='config/secondmate-harness (per-id pin, falling back to the default line then config/crew-harness)'
    else
      if [ -f "$CONFIG/crew-dispatch.json" ]; then
        echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
        exit 1
      fi
      HARNESS=$("$FM_ROOT/bin/fm-harness.sh" crew)
      harness_src='config/crew-harness'
    fi
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: no launch template for harness '$HARNESS' (from $harness_src or detection); pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
  *)
    HARNESS=$ARG3
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: unknown harness '$HARNESS'; pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
esac

# config/secondmate-harness may carry optional model/effort tokens alongside the
# harness ("<harness> [<model>] [<effort>]"). They apply only when this is a
# --secondmate spawn and no explicit per-spawn harness/raw launch was supplied, so
# the harness itself came from the secondmate config fallback chain. Resolving
# here on every spawn makes the pin durable across respawns. Precedence: explicit
# --model/--effort flags still win over the file's tokens.
if [ "$KIND" = secondmate ] && [ -z "$ARG3" ]; then
  if [ "$MODEL_SET" -eq 0 ]; then
    SM_MODEL=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model "$ID")
    [ -z "$SM_MODEL" ] || MODEL=$SM_MODEL
  fi
  if [ "$EFFORT_SET" -eq 0 ]; then
    SM_EFFORT=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort "$ID")
    if [ -n "$SM_EFFORT" ]; then
      case "$SM_EFFORT" in
        low|medium|high|xhigh|max) EFFORT=$SM_EFFORT ;;
        *) echo "warning: config/secondmate-harness effort token '$SM_EFFORT' is not one of low, medium, high, xhigh, max; ignoring" >&2 ;;
      esac
    fi
  fi
fi

secondmate_registry_value() {
  local id=$1 key=$2 reg line value
  reg="$DATA/secondmates.md"
  [ -f "$reg" ] || return 1
  line=$(grep -E "^- $id( |$)" "$reg" | tail -1 || true)
  [ -n "$line" ] || return 1
  case "$key" in
    home) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p') ;;
    projects) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: [^;)]*; scope: [^;)]*; projects: \([^;)]*\); added .*/\1/p') ;;
    *) return 1 ;;
  esac
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

model_flag_for_harness() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    claude|codex|opencode|pi|grok)
      printf -- '--model %s ' "$(shell_quote "$model")"
      ;;
    # jcode is deliberately absent: its launch model flag applies only when the
    # launcher starts the shared background server, so jcode's model is applied
    # per session after launch instead (see effort_flag_for_harness below and
    # jcode_post_launch_delivery).
  esac
}

effort_flag_for_harness() {
  local harness=$1 effort=$2
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case "$harness" in
    claude)
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    codex)
      # The installed codex config schema uses model_reasoning_effort, and the
      # bundled model catalog advertises low|medium|high|xhigh. Omit max rather
      # than passing an unsupported value.
      case "$effort" in
        low|medium|high|xhigh) printf -- '-c %s ' "$(shell_quote "model_reasoning_effort=\"$effort\"")" ;;
      esac
      ;;
    grok)
      # grok exposes both --effort and --reasoning-effort; firstmate's profile
      # axis is the reasoning knob. As of grok 0.2.99, --reasoning-effort accepts
      # only low|medium|high and rejects both xhigh and max, so omit those rather
      # than passing a known-bad value.
      case "$effort" in
        low|medium|high) printf -- '--reasoning-effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    pi)
      # Pi 0.80.6 accepts the full shared effort vocabulary, including max, through
      # its --thinking flag.
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--thinking %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    # opencode's interactive `opencode --prompt` launch has a verified --model
    # flag but no verified effort flag. Its `opencode run --variant` flag belongs
    # to a different, non-interactive launch mode, so fm-spawn does not pass it.
    #
    # jcode has both -m/--model and provider flags, but they apply only when the
    # launcher STARTS the shared background server, so on an already-running
    # server they are silently ignored. Neither axis is a launch flag for it:
    # jcode_post_launch_delivery applies both to the live session with /model and
    # /effort, which do work per session (verified 2026-07-30). jcode's /effort
    # accepts a superset of firstmate's vocabulary, so nothing is capped, but
    # which levels a given model honors is jcode's own decision.
  esac
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: firstmate home does not exist or is not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

resolve_project_dir_arg() {
  local path=$1
  case "$path" in
    projects/*) printf '%s/%s\n' "$PROJECTS" "${path#projects/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

# The clone-identity assertion in validate_spawn_worktree is RELATIVE: it compares
# the allocated worktree against this spawn's project and refuses when they
# disagree. That catches a pool handing back another clone's slot, but it cannot
# see that the project ITSELF is the wrong clone. resolve_project_dir_arg above
# rewrites only a "projects/<name>" argument; every other string passes through
# verbatim, so a spawn given another checkout of the same repo - the captain's own
# working copy, say - opens its pane there, `treehouse get` allocates a slot of
# THAT clone's object store, and both sides of the clone comparison then name the
# same foreign clone. The assertion passes and the crew commits where the home
# that dispatched it cannot see the branch: a refusal that does not refuse.
#
# Closing it needs an ABSOLUTE test, and the registry model already supplies one -
# every registered project is this home's own clone at $PROJECTS/<name>. Fail
# closed on anything else rather than offering a bypass flag; tests that need a
# different location move the whole projects dir with FM_PROJECTS_OVERRIDE.
validate_project_is_own_clone() {  # <raw-arg> <resolved-abs>
  local raw=$1 abs=$2 abs_real projects_real
  abs_real=$(cd "$abs" 2>/dev/null && pwd -P) || abs_real=$abs
  projects_real=$(cd "$PROJECTS" 2>/dev/null && pwd -P) || projects_real=$PROJECTS
  if [ "$(dirname "$abs_real")" != "$projects_real" ]; then
    echo "error: project '$raw' resolves to '$abs_real', which is not one of this home's project clones (expected a direct child of '$projects_real'); refusing to launch so the task cannot work in a copy of this repo that this home does not own" >&2
    exit 1
  fi
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

validate_firstmate_home_for_spawn() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$FM_HOME")
  abs_root=$(resolved_existing_dir "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the firstmate repo: $home" >&2
    return 1
  fi
  validate_firstmate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    echo "error: firstmate home $home is not a seeded secondmate home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: firstmate home $home is marked for secondmate ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a firstmate home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

validate_firstmate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: secondmate $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the active firstmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the firstmate repo: $dir" >&2
      return 1
    fi
  done
}

if [ "$KIND" = secondmate ]; then
  if [ -z "$FIRSTMATE_HOME" ] && [ -f "$STATE/$ID.meta" ]; then
    FIRSTMATE_HOME=$(grep '^home=' "$STATE/$ID.meta" | cut -d= -f2- || true)
  fi
  if [ -z "$FIRSTMATE_HOME" ]; then
    FIRSTMATE_HOME=$(secondmate_registry_value "$ID" home || true)
  fi
fi

if [ "$KIND" = secondmate ]; then
  [ -n "$FIRSTMATE_HOME" ] || { echo "error: no firstmate home supplied or registered for $ID" >&2; exit 1; }
  PROJ_ABS=$(validate_firstmate_home_for_spawn "$ID" "$FIRSTMATE_HOME")
  WT="$PROJ_ABS"
  # Local-HEAD sync: before launch, fast-forward this secondmate's worktree to the
  # PRIMARY checkout's current default-branch commit, so a freshly spawned or
  # recovery-respawned secondmate always runs the primary's version (AGENTS.md
  # spawn section). Purely local - no fetch: the home is a worktree of this same
  # repo and already holds the commit. ff-only and guarded; a dirty, diverged, or
  # wrong-branch home is left untouched and launches as-is. The agent re-reads
  # AGENTS.md fresh on launch, so no nudge is needed here.
  if sm_primary_head=$(primary_head_commit "$FM_ROOT"); then
    sm_ff_out=$(ff_target "$PROJ_ABS" "secondmate $ID" "$sm_primary_head" yes yes 2>&1 || true)
    case "$sm_ff_out" in
      *': skipped:'*)
        sm_ff_line=$(first_line "$sm_ff_out")
        sm_ff_prefix="secondmate $ID: skipped: "
        sm_ff_reason=${sm_ff_line#"$sm_ff_prefix"}
        echo "warning: secondmate $ID sync skipped before launch: $sm_ff_reason" >&2
        ;;
    esac
  else
    echo "warning: secondmate $ID sync skipped before launch: primary default-branch commit cannot be resolved" >&2
  fi
  mkdir -p "$PROJ_ABS/state" || {
    echo "error: could not create secondmate state directory for $PROJ_ABS" >&2
    exit 1
  }
  CONFIG_INHERIT_LOCK=$(fm_config_inherit_lock_path "$PROJ_ABS") || {
    echo "error: could not resolve secondmate inheritance lock for $PROJ_ABS" >&2
    exit 1
  }
  if ! fm_lock_acquire_wait "$CONFIG_INHERIT_LOCK"; then
    echo "error: could not acquire secondmate inheritance lock for $PROJ_ABS" >&2
    exit 1
  fi
  CONFIG_INHERIT_LOCK_HELD=1
  # Inheritance propagation: push the primary-authoritative local inheritance
  # surface into this secondmate home (fm-config-inherit-lib.sh).
  propagate_secondmate_inheritance "$FM_HOME" "$PROJ_ABS" "$CONFIG" "$DATA" \
    || echo "warning: secondmate $ID inheritance failed for $PROJ_ABS" >&2
  if [ -f "$PROJ_ABS/data/charter.md" ]; then
    BRIEF="$PROJ_ABS/data/charter.md"
  else
    BRIEF="$DATA/$ID/brief.md"
  fi
else
  PROJ_ABS="$(cd "$(resolve_project_dir_arg "$PROJ")" && pwd)"
  validate_project_is_own_clone "$PROJ" "$PROJ_ABS"
  WT=""
  BRIEF="$DATA/$ID/brief.md"
fi
[ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF" >&2; exit 1; }
# An unfilled {TASK} placeholder means firstmate scaffolded the brief but never
# replaced it with the actual task description. Dispatching it wastes the spawn:
# the crewmate can only stop and report the empty brief. Refuse loudly here so
# the dispatch never happens. The scaffold (fm-brief.sh) writes the literal
# {TASK} placeholder on purpose and cannot know the task text, so this guard
# belongs at spawn time, not in the scaffold. Batch dispatch re-execs this script
# in single-task mode, so every pair passes through this check.
#
# The honest signal is structural: fm-brief.sh writes the placeholder as the
# entire body of the `# Task` section, on its own line. A correctly filled brief
# replaces that line. The guard therefore matches only the bare placeholder
# standing alone as a line, not a mention of the token inside explanatory prose
# or backticks - the scaffold's own Herdr safety declaration quotes `{TASK}`
# inline, and refusing on that would force the operator to edit generated safety
# text to spawn a fully filled brief.
if grep -Eq '^[[:space:]]*\{TASK\}[[:space:]]*$' "$BRIEF"; then
  echo "error: brief at $BRIEF still contains an unfilled {TASK} placeholder; replace it with the task description before spawning" >&2
  exit 1
fi

# PROJ_ABS can still carry a symlinked path component (e.g. macOS's /tmp ->
# /private/tmp) when it came from the ship/scout branch's logical `pwd` above.
# Every backend's own current-path read (tmux's pane_current_path, herdr's
# foreground_cwd, zellij/cmux's active pwd probe against the live shell) can
# report the OS-level, physically-resolved cwd, so comparing it against a
# still-symlinked PROJ_ABS can misfire both ways: false-negative (the poll
# below never notices the pane left the project) or false-positive (the
# isolation guard refuses a spawn that never actually tangled). Canonicalize
# once here so every downstream comparison uses the same physical form
# (docs/herdr-backend.md "Known gaps").
PROJ_ABS_REAL=$(cd "$PROJ_ABS" 2>/dev/null && pwd -P) || PROJ_ABS_REAL="$PROJ_ABS"

real_path_or_raw() {  # <path>
  local path=$1 real
  if real=$(cd "$path" 2>/dev/null && pwd -P); then
    printf '%s\n' "$real"
  else
    printf '%s\n' "$path"
  fi
}

# Session-provider container-ensure + task creation. tmux stays exactly as P1
# left it (same session-name / new-window sequence, see bin/backends/tmux.sh);
# a herdr spawn goes through the version-gated, workspace-per-HOME,
# tab-per-task sequence in bin/backends/herdr.sh instead (D4/D5 as refined by
# docs/herdr-backend.md's "workspace-per-home" pass, AGENTS.md task
# herdr-sm-spaces-k4). Both branches converge on the same $T ("target") string
# that every downstream operation (send/capture/kill) already treats as opaque
# per-backend routing (fm_backend_resolve_selector).
# Physical path of a checkout's shared git directory. git-common-dir is the
# object store every worktree of one clone shares, so two checkouts agree here
# if and only if they belong to the SAME clone. `rev-parse --git-common-dir`
# may answer relative to its -C directory (and older git has no
# --path-format=absolute), so resolve it here rather than trusting the raw
# string.
git_common_dir_real() {  # <dir>
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  case "$common" in
    /*) ;;
    *) common="$dir/$common" ;;
  esac
  (cd "$common" 2>/dev/null && pwd -P) || return 1
}

validate_spawn_worktree() {  # <source> <inspect-target>
  local source=$1 inspect_target=$2 wt_real proj_real wt_top wt_top_real
  local wt_common proj_common
  wt_real=
  if ! wt_real=$(cd "$WT" 2>/dev/null && pwd -P); then
    wt_real=
  fi
  proj_real=$PROJ_ABS_REAL
  wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
  wt_top_real=
  if ! wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P); then
    wt_top_real=
  fi
  if [ -z "$wt_real" ] || [ -z "$wt_top_real" ] || [ "$wt_real" != "$wt_top_real" ] || [ "$wt_real" = "$proj_real" ]; then
    echo "error: $source did not yield an isolated worktree (resolved '$WT'; worktree root '${wt_top:-none}'; primary '$PROJ_ABS'); refusing to launch to avoid tangling the primary checkout. Inspect target $inspect_target" >&2
    exit 1
  fi
  # Isolation alone is not enough: one treehouse pool can be shared by two
  # separate clones of the same repo (a main home's projects/<name> and a
  # secondmate home's projects/<name>), so `treehouse get` can hand back a
  # perfectly real, perfectly isolated worktree of the WRONG clone. Every check
  # above passes for such a slot. The crew then commits into another home's
  # object store, where its branch is invisible to the home that dispatched it,
  # and every repo-scoped tool it runs - no-mistakes included - resolves to that
  # foreign clone. Comparing the shared git directory is the only test that
  # separates the two cases. An indeterminate reading refuses too: a worktree
  # whose owning clone cannot be established is exactly the state this assertion
  # exists to keep off the fleet.
  wt_common=$(git_common_dir_real "$WT" || true)
  proj_common=$(git_common_dir_real "$PROJ_ABS" || true)
  if [ -z "$wt_common" ] || [ -z "$proj_common" ] || [ "$wt_common" != "$proj_common" ]; then
    echo "error: $source yielded a worktree of a different clone (resolved '$WT' belongs to '${wt_common:-unknown}'; project '$PROJ_ABS' belongs to '${proj_common:-unknown}'); refusing to launch so the task cannot commit into another copy of this repo. Inspect target $inspect_target" >&2
    exit 1
  fi
}

# No two tasks may record the same worktree. Two metas pointing at one worktree
# silently alias: tearing down either task inspects the SAME worktree, so one
# task's teardown verdict is really about the other task's work. treehouse pins a
# pool slot per clone, but a stale or double-drawn allocation can still hand the
# same path to a second spawn; validate_spawn_worktree proves the slot is a
# genuine isolated worktree of the right clone, not that no other task already
# claims it. This is the same class of assertion as the isolation check above,
# for a different aliasing failure. Refuse here, naming the task that holds the
# worktree, and record nothing.
assert_worktree_unclaimed() {  # <worktree>
  local wt=$1 wt_real m other other_real other_id
  if ! wt_real=$(cd "$wt" 2>/dev/null && pwd -P); then
    wt_real=$wt
  fi
  [ -d "$STATE" ] || return 0
  for m in "$STATE"/*.meta; do
    [ -e "$m" ] || continue
    other_id=$(basename "$m" .meta)
    [ "$other_id" = "$ID" ] && continue
    other=$(grep '^worktree=' "$m" 2>/dev/null | head -n1 | cut -d= -f2-) || continue
    [ -n "$other" ] || continue
    if ! other_real=$(cd "$other" 2>/dev/null && pwd -P); then
      other_real=$other
    fi
    if [ "$other_real" = "$wt_real" ]; then
      echo "error: worktree '$wt' is already claimed by task '$other_id' (state/$other_id.meta); refusing to launch $ID so the two tasks cannot alias one worktree and corrupt each other's teardown verdict." >&2
      exit 1
    fi
  done
}

# A stale presentation journal never grants launch authority.
# When authoritative metadata already exists, require its endpoint to be
# positively dead before the journal's read-only token inspection may allow a
# flat fallback.
herdr_projection_existing_meta_allows_flat() {  # <meta>
  local meta=$1 old_backend old_target old_session old_pane old_state
  old_backend=$(fm_backend_of_meta "$meta")
  old_target=$(fm_backend_target_of_meta "$meta")
  [ -n "$old_target" ] || {
    echo "error: existing metadata for $ID has no endpoint; refusing duplicate launch while its herdr presentation journal is quarantined" >&2
    return 1
  }
  if [ "$old_backend" = herdr ]; then
    fm_backend_herdr_parse_target "$old_target" || {
      echo "error: existing herdr endpoint for $ID is malformed; refusing duplicate launch" >&2
      return 1
    }
    old_session=$FM_BACKEND_HERDR_SESSION
    old_pane=$FM_BACKEND_HERDR_PANE
    fm_backend_herdr_server_ensure "$old_session" || {
      echo "error: existing herdr endpoint for $ID could not be inspected; refusing duplicate launch" >&2
      return 1
    }
    old_state=$(fm_backend_herdr_pane_agent_state "$old_session" "$old_pane")
    case "$old_state" in
      dead|no-agent) return 0 ;;
      live|unknown)
        echo "error: existing herdr endpoint for $ID is $old_state; refusing duplicate launch" >&2
        return 1
        ;;
    esac
  fi
  old_state=$(fm_backend_agent_alive "$old_backend" "$old_target")
  case "$old_state" in
    dead) return 0 ;;
    alive|unknown)
      echo "error: existing $old_backend endpoint for $ID is $old_state; refusing duplicate launch" >&2
      return 1
      ;;
  esac
}

W="fm-$ID"
case "$BACKEND" in
  tmux)
    SES=$(fm_backend_tmux_container_ensure)
    T="$SES:$W"
    # #134 robustness (tmux): fm_backend_tmux_create_task captures a stable window
    # id and pins the window name (automatic-rename/allow-rename off) so a captain's
    # non-default tmux config cannot rename the window away from fm-<id> once
    # treehouse cd's into the worktree. WT_TARGET carries that stable id for the
    # rename-critical worktree-detection steps below; the persisted window= handle
    # stays $T (the name form), which is safe now that rename is disabled.
    WID=$(fm_backend_tmux_create_task "$SES" "$W" "$PROJ_ABS") || exit 1
    WT_TARGET="$WID"
    ;;
  herdr)
    # fm_backend_herdr_workspace_label resolves the target workspace from
    # FM_HOME. For every KIND except secondmate, this process's own FM_HOME is
    # already the right home (the primary spawning its own crewmate/scout, or
    # a secondmate spawning ITS OWN crewmate/scout from its own process's
    # FM_HOME - the latter needs no glue at all). A --secondmate spawn is the
    # one case that does: it is the PRIMARY's own fm-spawn.sh process
    # launching a DIFFERENT home (PROJ_ABS, already validated above as the
    # secondmate's home), so FM_HOME here still names the primary. Shadow it
    # to PROJ_ABS for just these two calls (bash restores it automatically
    # after each prefixed simple-command call) so the secondmate's tab lands
    # in the secondmate's own workspace, not the primary's "firstmate" one.
    HERDR_LABEL_HOME=$FM_HOME
    if [ "$KIND" = secondmate ]; then
      HERDR_LABEL_HOME=$PROJ_ABS
    fi
    HERDR_PRESENTATION_JOURNAL=$(fm_backend_herdr_projection_journal_path "$STATE" "$ID")
    HERDR_PROJECTED=0
    if [ "$KIND" != secondmate ] && [ -f "$CONFIG/herdr-presentation-spaces" ]; then
      if [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; then
        if [ -e "$STATE/$ID.meta" ] || [ -L "$STATE/$ID.meta" ]; then
          herdr_projection_existing_meta_allows_flat "$STATE/$ID.meta" || exit 1
        fi
        HERDR_RECOVERY_SESSION=$(fm_backend_herdr_session)
        fm_backend_herdr_projection_recovery_allows_flat \
          "$HERDR_RECOVERY_SESSION" "$HERDR_PRESENTATION_JOURNAL" "$ID" || exit 1
      elif [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ]; then
        HERDR_SES=$(fm_backend_herdr_session)
        HERDR_PARENT_LABEL=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_workspace_label)
        # Session lock path resolution needs a live named-session socket.
        # Ensure the server before journal publication so lock failure degrades
        # to flat without ever creating an unlocked projection.
        if ! fm_backend_herdr_server_ensure "$HERDR_SES"; then
          echo "warning: herdr presentation could not ensure its session server; using the ordinary flat layout without projection" >&2
        elif spawn_herdr_presentation_order_lock_acquire "$HERDR_SES"; then
          HERDR_PROJECTION_ID=$(fm_backend_herdr_projection_journal_create "$STATE" "$ID") || exit 1
          HERDR_PROJECTION_LABEL=$(fm_backend_herdr_projection_workspace_label "$ID" "$HERDR_PROJECTION_ID")
          if ! FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_projection_create_task \
            "$PROJ_ABS" "$HERDR_PROJECTION_LABEL" "$W"; then
            if [ "${FM_BACKEND_HERDR_PROJECTION_CLEANUP_SAFE:-0}" = 1 ]; then
              HERDR_PROJECTION_ABORT_CLEANUP=1
              HERDR_PROJECTION_ABORT_SESSION=$FM_BACKEND_HERDR_PROJECTION_SESSION
              HERDR_PROJECTION_ABORT_TASK_PANE=$FM_BACKEND_HERDR_PROJECTION_PANE_ID
              HERDR_PROJECTION_ABORT_SEEDED_PANE=$FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID
            fi
            exit 1
          fi
          HERDR_PROJECTED=1
          HERDR_SES=$FM_BACKEND_HERDR_PROJECTION_SESSION
          HERDR_WORKSPACE_ID=$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID
          HERDR_SEEDED_DEFAULT_TAB_ID=$FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID
          HERDR_TAB_ID=$FM_BACKEND_HERDR_PROJECTION_TAB_ID
          HERDR_PANE_ID=$FM_BACKEND_HERDR_PROJECTION_PANE_ID
          HERDR_PROJECTION_ABORT_CLEANUP=1
          HERDR_PROJECTION_ABORT_SESSION=$HERDR_SES
          HERDR_PROJECTION_ABORT_TASK_PANE=$HERDR_PANE_ID
          HERDR_PROJECTION_ABORT_SEEDED_PANE=$FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID
          fm_backend_herdr_projection_order_best_effort \
            "$HERDR_SES" "$HERDR_WORKSPACE_ID" "$HERDR_PARENT_LABEL"
        else
          echo "warning: herdr presentation focus lock unavailable; using the ordinary flat layout without projection" >&2
        fi
      fi
    fi
    if [ "$HERDR_PROJECTED" -ne 1 ]; then
      HERDR_CONTAINER_RAW=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_container_ensure "$PROJ_ABS") || exit 1
      # fm_backend_herdr_container_ensure echoes "<session>:<workspace_id>\t<seeded_default_tab_id>"
      # (the second field empty when this call ADOPTED a pre-existing workspace
      # rather than creating a fresh one). Split on the guaranteed single tab
      # character; the seeded tab id is threaded through to create_task
      # untouched, which is the only function permitted to prune it (never
      # re-derived from labels - see docs/herdr-backend.md "Default-tab prune").
      CONTAINER=${HERDR_CONTAINER_RAW%%$'\t'*}
      HERDR_SEEDED_DEFAULT_TAB_ID=${HERDR_CONTAINER_RAW#*$'\t'}
      HERDR_SES=${CONTAINER%%:*}
      HERDR_WORKSPACE_ID=${CONTAINER#*:}
      HERDR_TASK_IDS=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_create_task "$CONTAINER" "$W" "$PROJ_ABS" "$HERDR_SEEDED_DEFAULT_TAB_ID") || exit 1
      read -r HERDR_TAB_ID HERDR_PANE_ID <<EOF
$HERDR_TASK_IDS
EOF
    fi
    if [ -z "$HERDR_TAB_ID" ] || [ -z "$HERDR_PANE_ID" ]; then
      echo "error: herdr did not return a tab/pane id for $W" >&2
      exit 1
    fi
    T="$HERDR_SES:$HERDR_PANE_ID"
    ;;
  zellij)
    ZELLIJ_SES=$(fm_backend_zellij_container_ensure) || exit 1
    ZELLIJ_TASK_IDS=$(fm_backend_zellij_create_task "$ZELLIJ_SES" "$W" "$PROJ_ABS") || exit 1
    read -r ZELLIJ_TAB_ID ZELLIJ_PANE_ID <<EOF
$ZELLIJ_TASK_IDS
EOF
    if [ -z "$ZELLIJ_TAB_ID" ] || [ -z "$ZELLIJ_PANE_ID" ]; then
      echo "error: zellij did not return a tab/pane id for $W" >&2
      exit 1
    fi
    T="$ZELLIJ_SES:$ZELLIJ_PANE_ID"
    ;;
  cmux)
    fm_backend_cmux_container_ensure || exit 1
    CMUX_TASK_IDS=$(fm_backend_cmux_create_task "$W" "$PROJ_ABS") || exit 1
    read -r CMUX_WORKSPACE_ID CMUX_SURFACE_ID <<EOF
$CMUX_TASK_IDS
EOF
    if [ -z "$CMUX_WORKSPACE_ID" ] || [ -z "$CMUX_SURFACE_ID" ]; then
      echo "error: cmux did not return a workspace/surface id for $W" >&2
      exit 1
    fi
    T="$CMUX_WORKSPACE_ID:$CMUX_SURFACE_ID"
    ;;
  orca)
    set +e
    ORCA_WT_RAW=$(fm_backend_orca_worktree_create "$PROJ_ABS" "$W")
    ORCA_WT_STATUS=$?
    set -e
    if [ "$ORCA_WT_STATUS" -ne 0 ]; then
      if [ "$ORCA_WT_STATUS" -eq 2 ] && [ -n "$ORCA_WT_RAW" ]; then
        if parse_orca_worktree_result "$ORCA_WT_RAW" && [ -n "$ORCA_WORKTREE_ID" ]; then
          ORCA_ABORT_CLEANUP=1
        fi
      fi
      exit 1
    fi
    parse_orca_worktree_result "$ORCA_WT_RAW" || true
    ORCA_ABORT_CLEANUP=1
    if [ -z "$ORCA_WORKTREE_ID" ] || [ -z "$WT" ]; then
      echo "error: orca did not return a worktree id/path for $W" >&2
      exit 1
    fi
    validate_spawn_worktree "orca worktree create" "$W"
    if [ -z "$ORCA_TERMINAL" ]; then
      ORCA_TERMINAL=$(fm_backend_orca_terminal_create "$ORCA_WORKTREE_ID" "$W") || exit 1
    fi
    T="$ORCA_TERMINAL"
    ;;
esac
# #134 robustness: only tmux needs a worktree-detection target distinct from $T -
# its rename-safe stable window id, set as WT_TARGET=$WID in the tmux branch above.
# Every other backend addresses its pane/surface by the id already in $T, so default
# WT_TARGET to $T for them (and for any future backend) - the shared treehouse-get +
# worktree-detection steps below must never reference an unbound WT_TARGET under set -u.
: "${WT_TARGET:=$T}"
spawn_send_text_line() {  # <target> <text>
  case "$BACKEND" in
    tmux) fm_backend_tmux_send_text_line "$1" "$2" ;;
    herdr) fm_backend_herdr_send_text_line "$1" "$2" ;;
    zellij) fm_backend_zellij_send_text_line "$1" "$2" "$W" ;;
    orca) fm_backend_orca_send_text_line "$1" "$2" ;;
    cmux) fm_backend_cmux_send_text_line "$1" "$2" "$W" ;;
  esac
}
spawn_current_path() {  # <target>
  case "$BACKEND" in
    tmux) fm_backend_tmux_current_path "$1" ;;
    herdr) fm_backend_herdr_current_path "$1" ;;
    zellij) fm_backend_zellij_current_path "$1" "$W" ;;
    cmux) fm_backend_cmux_current_path "$1" "$W" ;;
  esac
}
spawn_send_literal() {  # <target> <text>
  case "$BACKEND" in
    tmux) fm_backend_tmux_send_literal "$1" "$2" ;;
    herdr) fm_backend_herdr_send_literal "$1" "$2" ;;
    zellij) fm_backend_zellij_send_literal "$1" "$2" "$W" ;;
    orca) fm_backend_orca_send_literal "$1" "$2" ;;
    cmux) fm_backend_cmux_send_literal "$1" "$2" "$W" ;;
  esac
}
spawn_send_key() {  # <target> <key>
  case "$BACKEND" in
    tmux) fm_backend_tmux_send_key "$1" "$2" ;;
    herdr) fm_backend_herdr_send_key "$1" "$2" ;;
    zellij) fm_backend_zellij_send_key "$1" "$2" "$W" ;;
    orca) fm_backend_orca_send_key "$1" "$2" ;;
    cmux) fm_backend_cmux_send_key "$1" "$2" "$W" ;;
  esac
}
if [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ]; then
  spawn_send_text_line "$WT_TARGET" 'treehouse get'

  # Wait for the treehouse subshell: the pane's cwd moves from the project to the worktree.
  # Target the stable window id, not the name: if the name is ever lost (e.g. an
  # automatic-rename slips through), display-message -t <bad-name> falls back to the
  # active client's window, which would misread firstmate's OWN pane path as the
  # worktree and tangle a hook into the primary checkout. The window id never lies.
  # Compare against PROJ_ABS_REAL (physical), not PROJ_ABS: a symlinked project
  # prefix would otherwise make the pane's OS-level cwd read differ from
  # PROJ_ABS on the very first poll, before the pane has actually moved.
  #
  # A single read that already differs from PROJ_ABS_REAL is not proof the pane
  # settled there: on some tmux/WSL setups a brand-new window's pane_current_path
  # transiently reports an unrelated stale path (seen live as another real git
  # checkout entirely) before the shell catches up with treehouse get's cd. That
  # stale path still passes the PROJ_ABS_REAL comparison and validate_spawn_worktree
  # below (it resolves to a real, distinct worktree top-level too), so accepting it
  # on one read alone silently records the wrong worktree= in state/<id>.meta. Require
  # two consecutive reads to agree on the same non-project path before accepting it;
  # a mismatch just becomes the new candidate rather than resetting the wait, so a
  # pane that is already settled by the first real read only costs the one existing
  # inter-poll sleep as confirmation, not a whole extra cycle on top.
  candidate=""
  for _ in $(seq 1 60); do
    p=$(spawn_current_path "$WT_TARGET" || true)
    if [ -n "$p" ]; then
      p_real=$(real_path_or_raw "$p")
      if [ "$p_real" != "$PROJ_ABS_REAL" ]; then
        if [ -n "$candidate" ] && [ "$p_real" = "$candidate" ]; then
          WT="$p"
          break
        fi
        candidate="$p_real"
      else
        candidate=""
      fi
    else
      candidate=""
    fi
    sleep 1
  done
  if [ -z "$WT" ]; then
    echo "error: treehouse get did not enter a worktree within 60s; inspect window $T" >&2
    exit 1
  fi

  validate_spawn_worktree "treehouse get" "$T"
fi

# Per-task temp root: /tmp/fm-<id>/ with Go's build temp nested at gotmp/. Go won't
# create GOTMPDIR, so mkdir before it is used; fm-teardown removes the whole root.
# Nested (not a bare /tmp/fm-<id>/gotmp) so other per-task temp can live alongside
# later, and teardown cleans one deterministic path. GOTMPDIR (not TMPDIR) is the
# targeted knob: TMPDIR is too broad (affects every program's temp, not just Go's).
TASK_TMP="/tmp/fm-$ID"
mkdir -p "$TASK_TMP/gotmp"

# Per-harness turn-end hook: a file that touches state/<id>.turn-ended when the
# agent finishes a turn. Worktree-resident hooks are kept out of git's view so
# they never block teardown's dirty check or leak into a commit.
mkdir -p "$STATE"
STATE_REAL=$(cd "$STATE" && pwd -P)
TURNEND="$STATE_REAL/$ID.turn-ended"
exclude_path() {
  local rel=$1 EXCL
  EXCL=$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$EXCL" ] || return 0
  mkdir -p "$(dirname "$EXCL")"
  grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >> "$EXCL"
}
# An unsupervised pane installs NO turn-end hook: the watcher never enrolls it
# (recorded_windows drops supervise=off), so a turn-end signal would wake nobody,
# and the whole point is a pane firstmate never observes. Skip the hook for it
# exactly as a secondmate skips it.
if [ "$KIND" != secondmate ] && [ "$UNSUPERVISED" = off ]; then
  case "$HARNESS" in
    claude*)
      mkdir -p "$WT/.claude"
      cat > "$WT/.claude/settings.local.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '$TURNEND'"}]}]}}
EOF
      exclude_path '.claude/settings.local.json'
      ;;
    opencode*)
      mkdir -p "$WT/.opencode/plugins"
      cat > "$WT/.opencode/plugins/fm-turn-end.js" <<EOF
export const FmTurnEnd = async ({ \$ }) => ({
  event: async ({ event }) => {
    if (event.type === "session.idle") await \$\`touch $TURNEND\`
  },
})
EOF
      exclude_path '.opencode/plugins/fm-turn-end.js'
      ;;
    pi*)
      # Written OUTSIDE the worktree: pi's project-trust gate fires on any extension
      # loaded from inside the project (verified live), but an explicit -e path
      # elsewhere loads without a dialog. Lives in state/, cleaned by teardown.
      cat > "$STATE/$ID.pi-ext.ts" <<EOF
// Firstmate turn-end signal; written by fm-spawn.
// Use "turn_end" (fires after each turn the agent finishes), not "agent_end"
// (fires once, only when the whole run exits): the watcher needs a signal at
// every turn boundary so an idle crewmate is surfaced, not just at shutdown.
import { execFile } from "node:child_process";
export default function (pi: any) {
  pi.on("turn_end", () => execFile("touch", ["$TURNEND"]));
}
EOF
      ;;
    codex*)
      # codex: turn-end rides the launch command via -c notify=[...] and __TURNEND__.
      ;;
    grok*)
      # grok fires a Stop hook at every turn boundary (verified, grok 0.2.73), the
      # clean equivalent of codex's notify= and pi's turn_end. But grok only loads
      # PROJECT hooks (<worktree>/.grok/hooks/, <worktree>/.claude/settings.local.json)
      # after the folder is granted hook-trust, which is not automatic and which
      # firstmate cannot establish at launch without editing grok's own managed
      # trust store (a high-blast-radius write). GLOBAL hooks in ~/.grok/hooks/ are
      # always trusted and load on first launch with no gate. So the turn-end hook
      # lives OUTSIDE the worktree as a single firstmate-owned global hook that is a
      # guarded no-op for every non-firstmate grok session: it fires only when the
      # current workspace holds a .fm-grok-turnend token pointer that matches the
      # firstmate-owned hook registry. firstmate then drops that per-task pointer
      # (gitignored, like the other harnesses' worktree hook files).
      # Result: the hook is outside the worktree, needs no trust grant, and never
      # touches grok's managed config - only firstmate-owned files.
      GROK_HOOKS_DIR="${GROK_HOME:-$HOME/.grok}/hooks"
      GROK_AUTH_DIR="$GROK_HOOKS_DIR/fm-turn-end.d"
      mkdir -p "$GROK_AUTH_DIR"
      old_umask=$(umask)
      umask 077
      auth_file=$(mktemp "$GROK_AUTH_DIR/fm.XXXXXXXXXXXX")
      umask "$old_umask"
      printf '%s\n' "$TURNEND" > "$auth_file"
      printf '%s\n' "${auth_file##*/}" > "$STATE/$ID.grok-turnend-token"
      sq_grok_auth_dir=$(shell_quote "$GROK_AUTH_DIR")
      cat > "$GROK_HOOKS_DIR/fm-turn-end.sh" <<EOF
#!/usr/bin/env bash
set -u
auth_dir=$sq_grok_auth_dir
workspace=\${GROK_WORKSPACE_ROOT:-}
[ -n "\$workspace" ] || exit 0
p="\$workspace/.fm-grok-turnend"
[ -f "\$p" ] || exit 0
first=
IFS= read -r -n 256 first < "\$p" 2>/dev/null || [ -n "\$first" ] || exit 0
case "\$first" in token=*) token=\${first#token=} ;; *) exit 0 ;; esac
case "\$token" in fm.????????????) : ;; *) exit 0 ;; esac
case "\$token" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
t=\$(cat "\$auth_dir/\$token" 2>/dev/null) || exit 0
case "\$t" in /*.turn-ended) : ;; *) exit 0 ;; esac
touch "\$t" 2>/dev/null || true
exit 0
EOF
      chmod +x "$GROK_HOOKS_DIR/fm-turn-end.sh"
      hook_command=$(json_escape "bash $(shell_quote "$GROK_HOOKS_DIR/fm-turn-end.sh")")
      printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' "$hook_command" > "$GROK_HOOKS_DIR/fm-turn-end.json"
      printf 'token=%s\n' "${auth_file##*/}" > "$WT/.fm-grok-turnend"
      exclude_path '.fm-grok-turnend'
      ;;
  esac
fi

# Per-project delivery mode + yolo flag (bin/fm-project-mode.sh; the project-management skill and AGENTS.md task lifecycle).
# Recorded in meta so fm-teardown's safety check and the validate/merge stages can
# branch on them. Mode governs ship tasks; a scout's deliverable is a report, not a
# merge, so scout teardown ignores mode.
SECONDMATE_PROJECTS=
if [ "$KIND" = secondmate ]; then
  MODE=secondmate
  YOLO=off
  AUTOLAND=off
  SECONDMATE_PROJECTS=$(secondmate_registry_value "$ID" projects || true)
else
  PROJ_NAME=$(basename "$PROJ_ABS")
  read -r MODE YOLO AUTOLAND _ <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$PROJ_NAME")
EOF
fi
: "${AUTOLAND:=off}"

# WT is now final for every backend. Refuse before writing meta if another task
# already claims this worktree, so nothing is recorded on refusal.
assert_worktree_unclaimed "$WT"

META_WINDOW=$T
[ "$BACKEND" = orca ] && META_WINDOW=$W
{
  echo "window=$META_WINDOW"
  echo "worktree=$WT"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  echo "autoland=$AUTOLAND"
  echo "tasktmp=$TASK_TMP"
  echo "model=${MODEL:-default}"
  echo "effort=${EFFORT:-default}"
  # supervise=off is written only for an --unsupervised pane, so an ordinary
  # spawn's meta stays byte-identical (absent supervise= means on). The watcher's
  # recorded_windows drops any supervise=off pane from every supervision path.
  [ "$UNSUPERVISED" = off ] || echo "supervise=off"
  # backend= is written only for a non-default (non-tmux) backend, so the
  # default path's meta stays byte-identical (absent backend= means tmux;
  # data/fm-backend-design-d7's P1 compatibility contract).
  [ "$BACKEND" = tmux ] || echo "backend=$BACKEND"
  if [ "$BACKEND" = herdr ]; then
    echo "herdr_session=$HERDR_SES"
    echo "herdr_workspace_id=$HERDR_WORKSPACE_ID"
    echo "herdr_tab_id=$HERDR_TAB_ID"
    echo "herdr_pane_id=$HERDR_PANE_ID"
  fi
  if [ "$BACKEND" = zellij ]; then
    echo "zellij_session=$ZELLIJ_SES"
    echo "zellij_tab_id=$ZELLIJ_TAB_ID"
    echo "zellij_pane_id=$ZELLIJ_PANE_ID"
  fi
  if [ "$BACKEND" = orca ]; then
    echo "orca_worktree_id=$ORCA_WORKTREE_ID"
    echo "terminal=$ORCA_TERMINAL"
  fi
  if [ "$BACKEND" = cmux ]; then
    echo "cmux_workspace_id=$CMUX_WORKSPACE_ID"
    echo "cmux_surface_id=$CMUX_SURFACE_ID"
  fi
  if [ "$KIND" = secondmate ]; then
    echo "home=$PROJ_ABS"
    echo "projects=$SECONDMATE_PROJECTS"
  fi
} > "$STATE/$ID.meta"
[ "$BACKEND" = orca ] && ORCA_ABORT_CLEANUP=0

sq_brief=$(shell_quote "$BRIEF")
sq_turnend=$(shell_quote "$TURNEND")
sq_piext=$(shell_quote "$STATE/$ID.pi-ext.ts")
sq_piturnend=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-turnend-guard.ts")
sq_piwatch=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-pi-watch.ts")
sq_opinput=$(shell_quote "$FM_ROOT/bin/fm-operational-input.sh")
PIBRIEFENV=
[ "$HARNESS" != pi ] || PIBRIEFENV="FM_FIRSTMATE_PI_LAUNCH_BRIEF=$sq_brief"
MODELFLAG=$(model_flag_for_harness "$HARNESS" "$MODEL")
EFFORTFLAG=$(effort_flag_for_harness "$HARNESS" "$EFFORT")
LAUNCH=${LAUNCH//__MODELFLAG__/$MODELFLAG}
LAUNCH=${LAUNCH//__EFFORTFLAG__/$EFFORTFLAG}
LAUNCH=${LAUNCH//__BRIEF__/$sq_brief}
LAUNCH=${LAUNCH//__TURNEND__/$sq_turnend}
LAUNCH=${LAUNCH//__PIEXT__/$sq_piext}
LAUNCH=${LAUNCH//__PITURNEND__/$sq_piturnend}
LAUNCH=${LAUNCH//__PIWATCH__/$sq_piwatch}
LAUNCH=${LAUNCH//__OPINPUT__/$sq_opinput}
LAUNCH=${LAUNCH//__PIBRIEFENV__/$PIBRIEFENV}
if [ "$KIND" = secondmate ]; then
  sq_home=$(shell_quote "$PROJ_ABS")
  LAUNCH="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME=$sq_home $LAUNCH"
fi
# Export GOTMPDIR into the crewmate's pane shell so the agent and every child
# process (go build, go test, ...) inherit it. Sent before the launch command so
# the env is set when the agent starts; the brief sleep lets the export land.
spawn_send_text_line "$T" "export GOTMPDIR=$TASK_TMP/gotmp"
# Point every spawned crew and secondmate at ONE host-global heavy-run ceiling.
# The ledger is host-global (docs/configuration.md "Heavy-run serialization"),
# so every home must resolve the same cap through FM_HEAVY_SLOTS_FILE; without
# this export a waiter in a child home falls back to its own (usually absent =
# default 1) config/heavy-run-slots and starves its lane while the real ceiling
# is higher. An already-set FM_HEAVY_SLOTS_FILE is the authoritative primary
# pointer this process inherited (this spawn is itself running inside a
# secondmate that the primary already pointed at the primary's file), so
# propagate it verbatim to keep the whole chain on the primary's ceiling.
# Otherwise this process is the primary home, so its own $CONFIG/heavy-run-slots
# IS the authoritative file. The path is made absolute because the child reads
# it from inside its worktree, where a relative path would resolve wrong.
if [ -n "${FM_HEAVY_SLOTS_FILE:-}" ]; then
  HEAVY_SLOTS_FILE=$FM_HEAVY_SLOTS_FILE
else
  CONFIG_ABS=$(cd "$CONFIG" 2>/dev/null && pwd -P) || CONFIG_ABS=$CONFIG
  HEAVY_SLOTS_FILE="$CONFIG_ABS/heavy-run-slots"
fi
spawn_send_text_line "$T" "export FM_HEAVY_SLOTS_FILE=$(shell_quote "$HEAVY_SLOTS_FILE")"
# Apply any per-spawn --env KEY=VAL overrides into the pane shell env through
# the same channel the GOTMPDIR export uses, so the agent and its children
# inherit the swapped token. Last --env for the same KEY wins (shell `export`
# override). VAL is shell-quoted so a token containing shell metacharacters
# cannot escape the export.
for kv in "${ENV_OVERRIDES[@]+"${ENV_OVERRIDES[@]}"}"; do
  k=${kv%%=*}; v=${kv#*=}
  sq_v=$(shell_quote "$v")
  spawn_send_text_line "$T" "export $k=$sq_v"
  sleep 0.1
done
sleep 0.3
# Token-session capture anchor: the crew's harness session is created at launch,
# so its created_at is at or after THIS instant. Captured as late as possible
# (right before the launch) so an older session that reused this pooled worktree
# has an earlier created_at and is excluded by the >= floor in the resolver.
SPAWN_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
spawn_send_literal "$T" "$LAUNCH"
sleep 0.3
if [ "${HERDR_PROJECTED:-0}" -eq 1 ]; then
  HERDR_PROJECTION_ABORT_CLEANUP=0
  spawn_herdr_presentation_order_lock_release
fi
spawn_send_key "$T" Enter
# jcode's launch command carries no brief, model, or effort (launch_template
# above): they are applied to the live session once its composer exists. A
# delivery failure is reported and does not abort the spawn - the endpoint,
# worktree, and metadata are already recorded, so firstmate supervises and
# recovers this pane through the ordinary stuck-worker path rather than being
# left with a half-torn-down task.
if [ "$HARNESS" = jcode ]; then
  # Consult the account-switch orchestrator (quota-axi decide) for a jcode/Claude
  # worker so it lands on a non-exhausted Claude account, never one decide reports
  # exhausted. Scope: jcode + a claude-* model only (the same route that draws down
  # the shared Claude OAuth window). FAIL-SOFT: an unavailable/erroring/keep
  # orchestrator prints nothing, leaving the session on its default account.
  SPAWN_ACCOUNT=
  case "${MODEL:-}" in
    claude-*)
      SPAWN_ACCOUNT=$("$SCRIPT_DIR/fm-account-orchestrator.sh" resolve-account 2>/dev/null || true)
      ;;
  esac
  jcode_post_launch_delivery "$T" "$BRIEF" "${MODEL:-}" "${EFFORT:-}" "${SPAWN_ACCOUNT:-}" \
    "$WT" "$SPAWN_TS" "$STATE/$ID.status" "$STATE/$ID.meta" || true
  # Gap-1 visibility: stamp the pinned Claude account onto this task's
  # state/<id>.telemetry now the spawn has resolved it (account=/account_source=
  # spawn). FAIL-SOFT: never a spawn blocker; an empty account stamps nothing.
  fm_telemetry_stamp_account "$STATE/$ID.telemetry" "${SPAWN_ACCOUNT:-}" spawn || true
fi

# Token-session capture (best-effort telemetry, NEVER a spawn blocker). Now that
# the agent is launched and its session exists, resolve the crew's harness
# session id (working_dir == the leased worktree, created_at >= SPAWN_TS, newest
# wins) and (a) append one durable ledger row and (b) stamp session_id= into the
# meta. This runs on EVERY spawn, so a relaunch/recovery spawn for the same
# ticket id lands as an ADDITIONAL ledger row (many-rows-per-id). A resolve that
# returns empty (no matching session, or a harness whose session store we cannot
# read) writes NOTHING - no bogus ledger row, no session_id in meta - and never
# fails the spawn. Only jcode's store is readable today; every other harness
# resolves empty and is skipped, not guessed.
if [ "$HARNESS" = jcode ]; then
  CREW_SESSION_ID=$(fm_resolve_crew_session_id "$WT" "$SPAWN_TS" 2>/dev/null || true)
  if [ -n "$CREW_SESSION_ID" ]; then
    if fm_token_sessions_record "$DATA" "$ID" "$CREW_SESSION_ID" "$WT" "$SPAWN_TS" "$HARNESS" 2>/dev/null; then
      echo "session_id=$CREW_SESSION_ID" >> "$STATE/$ID.meta"
    fi
    # Resume-token capture (best-effort, NEVER a spawn blocker). The dead-session
    # recovery counterpart to the attribution ledger above: stuck-crewmate
    # recovery can RESUME this harness session in place - restoring its full turn
    # history, the brief and every step of progress - instead of restarting from
    # scratch. For jcode the resolved session id IS the `jcode --resume <id>`
    # token (fm_resume_token_for_harness), so no second lookup is needed; a future
    # harness whose resume token differs would diverge inside that helper. The
    # token is stamped resume= into meta (bin/fm-resume-cmd.sh reads it during
    # recovery) and, for a backlog-tracked ship/scout task, mirrored into the
    # durable task record via `tasks-axi update --resume` so it survives even a
    # meta teardown. A secondmate is persistent and never a backlog item, so it
    # gets the meta stamp only. Empty token, a manual backlog backend, an
    # incompatible tasks-axi, or a task the backlog does not know all resolve to
    # "no mirror", silently - none fails the spawn.
    RESUME_TOKEN=$(fm_resume_token_for_harness "$HARNESS" "$CREW_SESSION_ID")
    if [ -n "$RESUME_TOKEN" ]; then
      echo "resume=$RESUME_TOKEN" >> "$STATE/$ID.meta"
      if [ "$KIND" != secondmate ] && fm_tasks_axi_backend_available "$CONFIG"; then
        ( cd "$FM_HOME" && tasks-axi update "$ID" --resume "$RESUME_TOKEN" ) >/dev/null 2>&1 || true
      fi
    fi
  fi
fi

if [ "$KIND" = secondmate ]; then
  if ! fm_config_reread_discard_pending "$PROJ_ABS" "$ID" "$FM_HOME"; then
    if fm_config_reread_quarantine_pending "$PROJ_ABS" "$ID" "$FM_HOME"; then
      echo "CONFIG_REREAD: secondmate $ID: quarantined pre-relaunch generations after cleanup failure (destination=$PROJ_ABS/state/.fm-inherited-config-reread-quarantine source=$FM_HOME/state/.fm-inherited-config-reread-quarantine)" >&2
    else
      echo "CONFIG_REREAD: secondmate $ID: cleanup failed; pre-relaunch generations were force-cleared where possible (destination=$PROJ_ABS source=$FM_HOME)" >&2
    fi
  fi
fi

echo "spawned $ID harness=$HARNESS kind=$KIND mode=$MODE yolo=$YOLO window=$META_WINDOW worktree=$WT"

# Keep the captain's already-published desk current: a new worker just changed
# fleet state, so rebuild the desk file in place if one is live. Best-effort and
# silent by contract (no-op without a live desk, never re-serves, never wakes);
# it self-detaches so it cannot delay this spawn. See bin/fm-desk-event.sh.
FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-desk-event.sh" spawn >/dev/null 2>&1 || true
