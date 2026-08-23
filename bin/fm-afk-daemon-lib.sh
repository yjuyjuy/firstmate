# shellcheck shell=bash
# Shared away-mode daemon liveness helpers.
# Usage: . bin/fm-afk-daemon-lib.sh
#
# One owner for the question "is an away-mode supervision daemon actually
# running for THIS home?". bin/fm-afk-start.sh (and through it
# bin/fm-afk-launch.sh) uses it to decide start-vs-refresh; every script that
# must tell the daemon-owned away mode apart from the daemon-free away mode - the
# turn-end guard, the watcher's triage gate, the pull-based guard banner, and the
# session-start digest - asks fm_afk_daemon_owns_supervision below rather than
# reading state/.afk directly.
#
# Home scoping comes from the lock path itself (state/.supervise-daemon.lock
# lives in one home's state dir) and, when present, the pid identity recorded
# beside it. Scripts come from the shared tracked code root, so a daemon path
# match is NOT home discrimination; strict mode only rejects a process that is
# not this repo's supervise daemon at all.
#
# FAIL DIRECTION: liveness has THREE outcomes, not two. "No lock at all" and
# "the lock is held but the probe itself could not complete" are different
# states and must not collapse into one boolean. A probe can fail without the
# daemon being gone: fm_pid_identity returns non-zero when /proc or ps cannot be
# read, and ps can hand back an empty command line under fork pressure. Reading
# that as daemon-free would let the watcher run its OWN triage while a live
# daemon is also triaging - the double triage the design forbids - and triage
# absorption advances the suppression markers, so a wake the away-mode digest
# needed could be swallowed permanently while the captain is away. So
# fm_afk_daemon_supervision_state reports undetermined for an unprobeable lock
# and fm_afk_daemon_owns_supervision treats it as still daemon-owned. Only a
# genuinely absent or torn-down lock, or a holder confidently read as dead or as
# some other process, reads as daemon-free. A lock link whose owner directory is
# already gone belongs in that torn-down group rather than in undetermined: its
# pid record is unrecoverable, so undetermined would latch daemon-owned forever
# and leave a daemon-free away-mode home with nothing arming its own watcher.
# The boolean fm_afk_daemon_alive keeps its narrower "confidently live" meaning
# for the start-vs-refresh decision, where the safe direction is the opposite
# one.
#
# DAEMON BRING-UP: the lock is taken by the daemon itself, so between away-mode
# entry and that acquisition the lock is genuinely absent while a daemon IS
# expected. Reading that window as daemon-free would arm a second watcher whose
# state/.watch.lock then blocks the daemon's own watcher child, and would print a
# supervision-lapse banner during a healthy start. The entry paths therefore
# state their intent: they write state/.supervise-daemon.starting BEFORE
# state/.afk, and fm_afk_daemon_supervision_state treats a live marker as
# daemon-owned. Intent, not elapsed-time guessing - but it is bounded, because a
# start that never completes must not latch ownership forever: the daemon clears
# the marker as it takes the lock, bin/fm-afk-launch.sh clears it on a failed
# start and on stop, the daemon-free entry path clears it (and refuses while one
# is live), and a marker older than FM_AFK_DAEMON_PENDING_TTL seconds is ignored.
#
# Sources bin/fm-pid-lib.sh for fm_pid_alive and fm_pid_identity.

FM_AFK_DAEMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pid-lib.sh
. "$FM_AFK_DAEMON_LIB_DIR/fm-pid-lib.sh"

: "${FM_AFK_DAEMON_PENDING_TTL:=300}"

# fm_afk_daemon_pending_path <state-dir>
# The daemon-starting intent marker for this home.
fm_afk_daemon_pending_path() {
  printf '%s\n' "$1/.supervise-daemon.starting"
}

# fm_afk_daemon_pending_mark <state-dir>
# Record "a daemon is being started for this home right now", stamped so the
# claim expires on its own. Written atomically so a reader never sees a partial
# stamp, which would read as an unusable marker and reopen the window.
fm_afk_daemon_pending_mark() {
  local state=$1 marker pending
  marker=$(fm_afk_daemon_pending_path "$state")
  mkdir -p "$state" || return 1
  pending="$marker.pending.$$"
  date '+%s' > "$pending" 2>/dev/null || { rm -f "$pending" 2>/dev/null; return 1; }
  mv "$pending" "$marker" || { rm -f "$pending" 2>/dev/null; return 1; }
}

# fm_afk_daemon_pending_clear <state-dir>
# Drop the marker: the daemon holds the lock now, the start failed, away mode
# ended, or this home deliberately runs away mode with no daemon.
fm_afk_daemon_pending_clear() {
  rm -f "$(fm_afk_daemon_pending_path "$1")" 2>/dev/null || return 1
}

# fm_afk_daemon_pending_active <state-dir>
# True while an unexpired daemon-start intent is recorded. An unreadable or
# non-numeric stamp is NOT active: the marker exists to close a bounded bring-up
# window, so an unusable one must decay to daemon-free rather than latch
# ownership. A stamp in the future (clock skew) still counts as active.
fm_afk_daemon_pending_active() {
  local marker stamp now
  marker=$(fm_afk_daemon_pending_path "$1")
  [ -f "$marker" ] || return 1
  stamp=$(cat "$marker" 2>/dev/null || true)
  case "$stamp" in
    ''|*[!0-9]*) return 1 ;;
  esac
  now=$(date '+%s' 2>/dev/null) || return 1
  [ "$stamp" -gt "$now" ] && return 0
  [ $((now - stamp)) -lt "$FM_AFK_DAEMON_PENDING_TTL" ]
}

# fm_afk_daemon_lock_owner <lock-path>
# Print the owner directory backing the lock (the symlink target for a linked
# lock, the directory itself for a plain directory lock). Non-zero when no lock,
# including a dangling link whose owner directory is already gone: the lock
# protocol discards the owner as it releases, so a link with no owner behind it
# holds nothing.
fm_afk_daemon_lock_owner() {
  local lock=$1 owner
  if [ -L "$lock" ]; then
    owner=$(readlink "$lock" 2>/dev/null) || return 1
    [ -n "$owner" ] || return 1
    case "$owner" in
      /*) ;;
      *) owner="$(dirname "$lock")/$owner" ;;
    esac
    [ -d "$owner" ] || return 1
    printf '%s\n' "$owner"
    return 0
  fi
  [ -d "$lock" ] || return 1
  printf '%s\n' "$lock"
}

# fm_afk_daemon_lock_pid <lock-path>
# Print the pid recorded in the lock owner, empty when unreadable.
fm_afk_daemon_lock_pid() {
  local owner
  owner=$(fm_afk_daemon_lock_owner "$1") || return 1
  cat "$owner/pid" 2>/dev/null || true
}

# fm_afk_daemon_pid_match_state <pid> <owner-dir> <daemon-path> [strict]
# Print live, dead, or undetermined for "is this live pid really that daemon?".
# The recorded pid identity is authoritative when present. Without one, fall back
# to the process command: strict mode (1) accepts only the full
# bin/fm-supervise-daemon.sh path, while the default also accepts a bare
# fm-supervise-daemon.sh command, which is enough for the start/refresh decision
# that already runs inside the owning home. A probe that cannot complete - an
# unreadable identity or an empty ps command line - is undetermined, never dead.
fm_afk_daemon_pid_match_state() {
  local pid=$1 owner=$2 daemon=$3 strict=${4:-0} identity current command
  identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  if [ -n "$identity" ]; then
    if ! current=$(fm_pid_identity "$pid"); then
      printf 'undetermined\n'
      return 0
    fi
    if [ "$current" = "$identity" ]; then
      printf 'live\n'
    else
      printf 'dead\n'
    fi
    return 0
  fi
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  if [ -z "$command" ]; then
    printf 'undetermined\n'
    return 0
  fi
  case "$command" in
    *"$daemon"*) printf 'live\n'; return 0 ;;
  esac
  if [ "$strict" != 1 ]; then
    case "$command" in
      *"fm-supervise-daemon.sh"*) printf 'live\n'; return 0 ;;
    esac
  fi
  printf 'dead\n'
}

# fm_afk_daemon_pid_matches <pid> <owner-dir> <daemon-path> [strict]
# Boolean form: true only on a confident live match, so an undetermined probe
# reads as no match.
fm_afk_daemon_pid_matches() {
  [ "$(fm_afk_daemon_pid_match_state "$@")" = live ]
}

# fm_afk_daemon_liveness <lock-path> <daemon-path> [strict]
# Print live, dead, or undetermined for this home's away-mode daemon lock. An
# absent lock, or a lock whose owner directory is gone, is dead (nothing holds
# it); a held lock whose pid or holder cannot be read at all is undetermined.
fm_afk_daemon_liveness() {
  local lock=$1 daemon=$2 strict=${3:-0} owner pid
  if ! owner=$(fm_afk_daemon_lock_owner "$lock"); then
    printf 'dead\n'
    return 0
  fi
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*)
      printf 'undetermined\n'
      return 0
      ;;
  esac
  if ! fm_pid_alive "$pid"; then
    printf 'dead\n'
    return 0
  fi
  fm_afk_daemon_pid_match_state "$pid" "$owner" "$daemon" "$strict"
}

# fm_afk_daemon_alive <lock-path> <daemon-path> [strict]
# True exactly when this home's away-mode daemon lock is held by a live process
# that really is that daemon. Boolean by design: the start-vs-refresh decision in
# bin/fm-afk-start.sh must not start a second daemon on a hunch, so an
# undetermined probe reads as not-alive here.
fm_afk_daemon_alive() {
  [ "$(fm_afk_daemon_liveness "$@")" = live ]
}

# fm_afk_daemon_lock_held_by_foreign_live_process <lock-path> <daemon-path> [strict]
# True ONLY when this home's daemon lock is held by a live process that the probe
# CONFIDENTLY reads as something other than this repo's supervise daemon.
#
# This is the "may I tear this lock out?" question, and it is not the negation of
# fm_afk_daemon_alive. That boolean folds an unprobeable holder into not-alive,
# which is the right conservative answer for "should I start a daemon" but the
# wrong one here: an entry path that stole a lock on an undetermined probe would
# take it away from a daemon that is in fact running - fm_pid_identity returns
# non-zero when /proc or ps cannot be read, and ps can hand back an empty command
# line under fork pressure - and leave two supervisors both believing they own
# escalation delivery.
#
# So only a confident `dead` match state (a recorded identity that differs, or a
# readable command line that is not the daemon) authorizes removal. An
# undetermined probe leaves the lock alone; the caller's daemon then refuses to
# start against the held lock, which is loud and self-correcting. A holder whose
# process is genuinely gone needs nothing here either: bin/fm-wake-lib.sh's own
# dead-pid steal already recovers that lock lazily.
fm_afk_daemon_lock_held_by_foreign_live_process() {
  local lock=$1 daemon=$2 strict=${3:-0} owner pid
  owner=$(fm_afk_daemon_lock_owner "$lock") || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_pid_alive "$pid" || return 1
  [ "$(fm_afk_daemon_pid_match_state "$pid" "$owner" "$daemon" "$strict")" = dead ]
}

# fm_afk_daemon_supervision_state <state-dir> <bin-dir>
# Print which of the three supervision-ownership states this home is in:
#   free         - away mode is off, or no daemon holds this home's lock and no
#                  unexpired daemon-start intent is recorded, or the holder is
#                  confidently dead or confidently another process
#   owned        - away mode is on and a live daemon for THIS home holds the
#                  lock, or a daemon is on its way up for this home (an
#                  unexpired state/.supervise-daemon.starting marker)
#   undetermined - away mode is on and the lock is held, but the liveness probe
#                  itself could not complete
# Away mode alone is only the away POSTURE: a home whose captain session runs
# outside any injectable supervisor pane deliberately runs away mode with no
# daemon, and its own watcher stays the real supervision mechanism. This home's
# own lock path is what keeps another home's daemon out; strict matching
# additionally rejects a non-daemon process holding that lock.
fm_afk_daemon_supervision_state() {
  local state=$1 bindir=$2 liveness
  if [ ! -e "$state/.afk" ]; then
    printf 'free\n'
    return 0
  fi
  liveness=$(fm_afk_daemon_liveness "$state/.supervise-daemon.lock" "$bindir/fm-supervise-daemon.sh" 1)
  case "$liveness" in
    live) printf 'owned\n' ;;
    undetermined) printf 'undetermined\n' ;;
    *)
      if fm_afk_daemon_pending_active "$state"; then
        printf 'owned\n'
      else
        printf 'free\n'
      fi
      ;;
  esac
}

# fm_afk_daemon_owns_supervision <state-dir> <bin-dir>
# True when a daemon owns supervision for this home. Undetermined counts as owned
# per the fail direction documented in this file's header.
fm_afk_daemon_owns_supervision() {
  case "$(fm_afk_daemon_supervision_state "$1" "$2")" in
    owned|undetermined) return 0 ;;
  esac
  return 1
}

# fm_afk_posture_situation <state-dir> <daemon-owned> <in-flight> <detail>
# One owner for the supervision-lapse situation clause shared by the push-based
# turn-end guard and the pull-based guard banner, so the daemon-free away-mode
# variant cannot drift between them. <daemon-owned> is the caller's already
# resolved fm_afk_daemon_owns_supervision verdict (1 owned, 0 not), so this never
# re-probes the daemon.
fm_afk_posture_situation() {
  local state=$1 owned=$2 in_flight=$3 detail=$4
  if [ "$owned" -eq 0 ] && [ -e "$state/.afk" ]; then
    printf '%s task(s) in flight, away mode is on with no supervision daemon, and %s\n' "$in_flight" "$detail"
    return 0
  fi
  printf '%s task(s) in flight, but %s\n' "$in_flight" "$detail"
}
