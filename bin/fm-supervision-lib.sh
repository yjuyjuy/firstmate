# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# True exactly when a firstmate home has in-flight work (a state/<id>.meta
# exists) but no watcher has a fresh liveness beacon (state/.last-watcher-beat,
# touched every poll cycle, within the grace window). bin/fm-guard.sh uses this
# grace-based warning predicate directly; bin/fm-turnend-guard.sh uses the status
# fields here for its banner but performs its end-of-turn block decision with the
# live watcher lock check in bin/fm-wake-lib.sh.
#
# fm_wake_path_owned (below) is the second predicate this file owns: a live+fresh
# watcher is only truly non-blind if SOMETHING owns a path that will complete to
# wake the idle model. It sources only function-only libraries (side-effect free),
# so sourcing this file stays safe for a read-only reporting command.

FM_SUPERVISION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-watch-scope-lib.sh
. "$FM_SUPERVISION_LIB_DIR/fm-watch-scope-lib.sh"

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 900, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-900}} meta beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly in the dangerous state: in-flight work exists and no
# watcher has a fresh beacon. Exit 1 (false) otherwise, including zero in-flight.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_IN_FLIGHT" -gt 0 ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}

# fm_wake_path_owned <state-dir> <script-dir>
# Exit 0 (owned) when SOMETHING owns a path that will complete to wake the idle
# model, exit 1 (blind) when a watcher can be alive yet nothing will re-drive the
# session. This closes the exact hole the incident went through: the old guards
# checked only "is a watcher alive" and passed the whole incident because one was,
# while no completing arm and no daemon owned a wake path.
#
# Owned if ANY of:
#   (a) a live present-mode daemon owns re-arming (it pane-wakes on jcode), OR
#   (b) a live away-mode daemon owns supervision for this home, OR
#   (c) a live THIS-home arm process exists (the completing background task whose
#       exit re-drives the model), enumerated by the shared absolute-path helper.
#
# The present-daemon check (a) reads its lock via the generic liveness helper in
# bin/fm-afk-daemon-lib.sh rather than executing `fm-present-daemon.sh status`:
# the lock is the same pid+identity+fm-home shape, the helper is already sourced
# by both guards, and this keeps the guard hook off the daemon's heavy tmux/backend
# dependency chain while judging present-daemon liveness exactly as away-daemon
# liveness is judged. Live OR undetermined counts as owned, matching that library's
# documented fail direction (an unprobeable-but-held lock stays owned).
#
# FAIL DIRECTION: this predicate errs toward OWNED (silence), the OPPOSITE of the
# arm's own never-blind bias. A false alarm here would nag every turn-end, so an
# uncertain probe must NOT alarm; the existing stale-beacon backstop still catches
# a genuinely dead watcher. If the afk-daemon liveness helper is unavailable
# (never sourced), the present-daemon path cannot be probed and is skipped rather
# than read as blind. The sub-second wake-handoff gap (arm completed, model not
# yet re-armed) is handled by the CALLERS, not here: the turn-end guard only fires
# at a real turn end, and the pull-based guard gates this behind its grace/dedup
# window.
fm_wake_path_owned() {
  local state=$1 script_dir=$2 arm_pids

  # (a) Present-mode daemon, judged by its lock (live or undetermined => owned).
  if command -v fm_afk_daemon_liveness >/dev/null 2>&1; then
    case "$(fm_afk_daemon_liveness "$state/.present-daemon.lock" "$script_dir/fm-present-daemon.sh" 1)" in
      live|undetermined) return 0 ;;
    esac
  fi

  # (b) Away-mode daemon ownership (undetermined counts as owned, per the afk
  # library's documented fail direction). Only consult it when the library is
  # available; its absence is not evidence of blindness.
  if command -v fm_afk_daemon_owns_supervision >/dev/null 2>&1; then
    if fm_afk_daemon_owns_supervision "$state" "$script_dir"; then
      return 0
    fi
  fi

  # (c) A live this-home arm process: the completion-wake owner whose exit
  # re-drives the model. Absolute-path scoped, so never another home's arm.
  arm_pids=$(fm_home_arm_pids "$script_dir")
  if [ -n "$arm_pids" ]; then
    return 0
  fi

  return 1
}
