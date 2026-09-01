#!/usr/bin/env bash
# Watcher liveness and worktree-tangle guard, called by supervision scripts, by
# fm-wake-drain.sh after it empties queued wakes, and by fm-session-start.sh in
# read-only advisory mode when another session holds the fleet lock.
# First, always warn if the firstmate primary checkout (FM_ROOT) is on a named
# non-default branch, because that means firstmate-on-itself work landed in the
# primary instead of an isolated worktree.
# Then, if any task is in flight (a state/<id>.meta exists) and the watcher's
# liveness beacon (state/.last-watcher-beat, touched every poll cycle) is
# missing or older than FM_GUARD_GRACE seconds, prints a loud, clearly delimited
# banner so the agent cannot skim past it in the tool output of whatever it was
# doing - the one channel every harness has. The full banner is emitted once per
# distinct staleness episode in this FM_HOME (keyed to beacon mtime or absence);
# later guarded commands in the same episode print a one-line reminder instead.
# Episode state lives only under state/.guard-watcher-stale-banner (volatile,
# bounded). Independent alarms (queued wakes, worktree tangle) are never
# suppressed by that dedup. Normal wake handling (watcher briefly down between a
# wake and the next supervision resume) stays inside the grace window and stays
# silent. Always exits 0: the guard warns, it never blocks.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-900}
queue_pending=false
READ_ONLY=${FM_GUARD_READ_ONLY:-0}
case "$READ_ONLY" in 1|true|TRUE|yes|YES) READ_ONLY=1 ;; *) READ_ONLY=0 ;; esac
CONTINUE_LINE=${FM_GUARD_CONTINUE_LINE:-This is a supervision warning only; the guarded operation WILL still run.}

# Volatile, home-scoped episode marker: one line = the current stale-episode key.
# Cleared when the home leaves the unhealthy state so a later episode re-arms.
STALE_BANNER_MARKER="$STATE/.guard-watcher-stale-banner"

# Volatile, home-scoped marker for the wake-path-unowned warning. It records the
# epoch when the alive-watcher-but-no-wake-owner state was FIRST observed, plus a
# "warned" sentinel once the warning has fired. This gives both a grace window (a
# sub-second wake-handoff gap never trips it, because the state must persist past
# FM_GUARD_WAKE_PATH_GRACE before the first warning) and a dedup (the warning
# prints once per contiguous unowned episode). Cleared whenever the wake path is
# owned again, so a later unowned episode re-arms.
WAKE_PATH_MARKER="$STATE/.guard-wake-path-unowned"
WAKE_PATH_GRACE=${FM_GUARD_WAKE_PATH_GRACE:-60}
case "$WAKE_PATH_GRACE" in ''|*[!0-9]*) WAKE_PATH_GRACE=60 ;; esac

# fm_guard_wake_path_clear: forget any recorded unowned state.
fm_guard_wake_path_clear() {
  rm -f "$WAKE_PATH_MARKER" 2>/dev/null || true
}

# fm_guard_wake_path_should_warn: exit 0 exactly once per contiguous unowned
# episode, and only after the unowned state has persisted past the grace window.
# First observation records the epoch and stays silent (grace). A later
# observation past the grace prints once, then records a "warned" sentinel so
# subsequent calls in the same episode stay silent.
fm_guard_wake_path_should_warn() {
  local now first
  now=$(date +%s 2>/dev/null) || return 1
  first=$(cat "$WAKE_PATH_MARKER" 2>/dev/null || true)
  case "$first" in
    warned) return 1 ;;
    ''|*[!0-9]*)
      printf '%s\n' "$now" > "$WAKE_PATH_MARKER" 2>/dev/null || true
      return 1
      ;;
  esac
  [ $((now - first)) -ge "$WAKE_PATH_GRACE" ] || return 1
  printf 'warned\n' > "$WAKE_PATH_MARKER" 2>/dev/null || true
  return 0
}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-afk-daemon-lib.sh
. "$SCRIPT_DIR/fm-afk-daemon-lib.sh"

# Portable size:mtime signature, byte-identical to the one bin/fm-watch.sh
# records into its .seen-* markers (Darwin lacks `stat -c`, Linux lacks `-f`).
# The benign-only nag suppressor below compares a queued signal's current status
# signature against that marker to tell an already-surfaced record from a fresh one.
if [ "$(uname)" = Darwin ]; then
  fm_guard_stat_sig() { stat -f '%z:%Fm' "$1" 2>/dev/null; }
else
  fm_guard_stat_sig() { stat -c '%s:%Y' "$1" 2>/dev/null; }
fi

# fm_guard_queue_all_benign <queue> <state>
# Exit 0 only when EVERY pending wake record is a benign, already-surfaced signal:
# a signal wake on a .status key whose status file's current size:mtime signature
# still equals the watcher's recorded .seen-* signature (so it was already
# surfaced or absorbed) AND whose last line is not captain-relevant. Exit 1 (the
# nag fires) for anything else: any non-signal record (heartbeat, stale, check),
# a .turn-ended marker, a status file whose signature has advanced past .seen (a
# newer, not-yet-surfaced line), a captain-relevant status, a missing status or
# .seen file, or an empty/unreadable queue. This never weakens the drain mandate:
# it only decides whether to print the ADVISORY warning, and errs toward printing
# it (return 1) on any uncertainty, so a genuinely actionable wake is never hidden.
fm_guard_queue_all_benign() {  # <queue> <state>
  local queue=$1 state=$2 epoch seq kind key payload saw=0
  local statusf seenf cur seen last
  [ -s "$queue" ] || return 1
  while IFS="$(printf '\t')" read -r epoch seq kind key payload; do
    [ -n "$kind" ] || continue
    saw=1
    # Only signal records can ever be benign; every other kind is actionable.
    [ "$kind" = signal ] || return 1
    # A .turn-ended marker (mapped historical) is treated as actionable, so scope
    # to a direct .status key whose current signature we can compare to .seen.
    case "$key" in *.status) ;; *) return 1 ;; esac
    fm_wake_status_key_map "$key" || return 1
    [ "$FM_WAKE_STATUS_HISTORICAL" = false ] || return 1
    statusf="$state/$FM_WAKE_STATUS_KEY"
    seenf="$state/.seen-$(printf '%s' "$FM_WAKE_STATUS_KEY" | tr '.' '_')"
    [ -f "$statusf" ] || return 1
    [ -f "$seenf" ] || return 1
    cur=$(fm_guard_stat_sig "$statusf") || return 1
    seen=$(cat "$seenf" 2>/dev/null) || return 1
    [ -n "$cur" ] && [ "$cur" = "$seen" ] || return 1
    last=$(last_status_line "$statusf")
    status_is_captain_relevant "$last" && return 1
  done < "$queue"
  [ "$saw" = 1 ]
}

# Deterministic episode key from beacon state: same continuous stale beacon
# (or continuous absence) shares a key; a recovered-then-restale beacon gets a
# new mtime and therefore a new episode.
fm_guard_stale_episode_key() {
  local state=$1 beat m
  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    printf 'beat:%s\n' "${m:-unknown}"
  else
    printf 'beat:absent\n'
  fi
}

# Claim the full banner for this episode. Exit 0 = print full banner (this call
# owns the first announcement). Exit 1 = same episode already announced (print
# reminder). The shared wake lock helper owns the race-safety mechanics; the
# re-check under the lock makes concurrent claims idempotent.
fm_guard_claim_stale_banner() {
  local state=$1 key=$2
  local marker="$state/.guard-watcher-stale-banner"
  local lock="$state/.guard-watcher-stale-banner.lock"
  local seen i

  seen=$(cat "$marker" 2>/dev/null || true)
  # Strip a single trailing newline so key comparison is line-content based.
  seen=${seen%$'\n'}
  if [ "$seen" = "$key" ]; then
    return 1
  fi

  i=0
  while [ "$i" -lt 50 ]; do
    if fm_lock_try_acquire "$lock"; then
      seen=$(cat "$marker" 2>/dev/null || true)
      seen=${seen%$'\n'}
      if [ "$seen" = "$key" ]; then
        fm_lock_release "$lock" 2>/dev/null || true
        return 1
      fi
      # Bounded write: one line, no growth across episodes (overwrite).
      printf '%s\n' "$key" > "$marker" || true
      fm_lock_release "$lock" 2>/dev/null || true
      return 0
    fi
    seen=$(cat "$marker" 2>/dev/null || true)
    seen=${seen%$'\n'}
    if [ "$seen" = "$key" ]; then
      return 1
    fi
    # Brief yield; 0.02s is fine on macOS/Linux sleep, fall back to 1s.
    sleep 0.02 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  # Contended past the spin budget: stay loud rather than dropping the alarm.
  return 0
}

fm_guard_stale_banner_seen() {
  local state=$1 key=$2
  local marker="$state/.guard-watcher-stale-banner"
  local seen

  seen=$(cat "$marker" 2>/dev/null || true)
  seen=${seen%$'\n'}
  [ "$seen" = "$key" ]
}

fm_guard_clear_stale_banner() {
  rm -f "$STALE_BANNER_MARKER" 2>/dev/null || true
}

# Worktree-tangle alarm, checked FIRST and independent of in-flight tasks: the
# firstmate PRIMARY checkout (FM_ROOT) must stay on its default branch. If a
# crewmate's branch/commits landed here instead of in its own isolated worktree,
# the primary is stranded on a feature branch - surface it loudly on the very next
# fleet action, the same way the watcher-down banner does. Scoped to the primary
# only: detached HEAD (linked worktrees, secondmate homes) never trips this.
tangle_branch=$(fm_primary_tangle_branch "$FM_ROOT" || true)
if [ -n "$tangle_branch" ]; then
  tangle_default=$(fm_default_branch "$FM_ROOT" 2>/dev/null || echo main)
  trule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$trule"
    printf '●  WORKTREE TANGLE - PRIMARY CHECKOUT IS ON A FEATURE BRANCH\n'
    printf "●  %s is on '%s', not its default branch '%s'.\n" "$FM_ROOT" "$tangle_branch" "$tangle_default"
    printf '●  A crewmate likely branched/committed in the primary instead of its own worktree.\n'
    printf "●  The work is SAFE on the '%s' ref.\n" "$tangle_branch"
    if [ "$READ_ONLY" -eq 1 ]; then
      printf '●  This read-only session must leave restore work to the session holding the fleet lock.\n'
    else
      printf "●  Restore the primary to '%s':\n" "$tangle_default"
      printf '●      git -C %s checkout %s\n' "$FM_ROOT" "$tangle_default"
      printf "●  then re-validate '%s' in a proper isolated worktree.\n" "$tangle_branch"
    fi
    printf '●%s\n' "$trule"
  } >&2
fi

# Compute in-flight count and watcher-beacon freshness via the shared
# grace-based predicate (bin/fm-supervision-lib.sh). Only act with tasks in
# flight; count them so the banner can say how much is riding on an absent
# watcher.
fm_supervision_status "$STATE" "$GRACE"
in_flight=$FM_SUP_IN_FLIGHT
watcher_fresh=$FM_SUP_WATCHER_FRESH
beacon_desc=$FM_SUP_BEACON_DESC
if [ "$in_flight" -eq 0 ]; then
  # Leave the unhealthy state (no work riding on the watcher): clear so a later
  # in-flight + stale combination is a fresh episode even if the beacon is still
  # absent with the same key string.
  [ "$READ_ONLY" -eq 1 ] || fm_guard_clear_stale_banner
  exit 0
fi

[ -s "$FM_WAKE_QUEUE" ] && queue_pending=true

# No fresh watcher with tasks in flight is the dangerous state: emit a prominent,
# bordered banner FIRST so it reads as an alarm, not a buried stderr line. Later
# calls in the same episode get a one-line reminder only.
if [ "$watcher_fresh" = false ]; then
  episode_key=$(fm_guard_stale_episode_key "$STATE")
  episode_key=${episode_key%$'\n'}
  print_full_banner=0
  if [ "$READ_ONLY" -eq 1 ]; then
    fm_guard_stale_banner_seen "$STATE" "$episode_key" || print_full_banner=1
  elif fm_guard_claim_stale_banner "$STATE" "$episode_key"; then
    print_full_banner=1
  fi
  if [ "$print_full_banner" -eq 1 ]; then
    # Away mode alone is only the away posture; watcher ownership moves to the
    # daemon only while one is actually live for this home, so a daemon-free away
    # mode still gets the ordinary re-arm instruction.
    afk=0
    fm_afk_daemon_owns_supervision "$STATE" "$SCRIPT_DIR" && afk=1
    queue_arg=0
    "$queue_pending" && queue_arg=1
    x_mode=0
    [ -f "$CONFIG/x-mode.env" ] && x_mode=1
    fix=$("$SCRIPT_DIR/fm-supervision-instructions.sh" \
      --read-only "$READ_ONLY" \
      --afk "$afk" \
      --x-mode "$x_mode" \
      --queue-pending "$queue_arg" \
      --repair-line 2>/dev/null || printf '%s\n' 'Repair missing watcher supervision according to the session-start operating block.')
    rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    {
      printf '●%s\n' "$rule"
      printf '●  WATCHER DOWN - SUPERVISION IS OFF\n'
      printf '●  %s.\n' \
        "$(fm_afk_posture_situation "$STATE" "$afk" "$in_flight" \
          "$(printf 'no watcher has a fresh beacon (last beat: %s, grace %ss)' "$beacon_desc" "$GRACE")")"
      if [ "$READ_ONLY" -eq 1 ]; then
        printf '●  This read-only session should report the lapse, not repair it.\n'
      else
        printf '●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.\n'
      fi
      printf '●  %s\n' "$CONTINUE_LINE"
      printf '●  %s\n' "$fix"
      printf '●%s\n' "$rule"
    } >&2
  else
    printf 'WARNING: watcher still down (same stale episode; last beat: %s, grace %ss) - full banner already printed this episode.\n' \
      "$beacon_desc" "$GRACE" >&2
  fi
else
  # Healthy again while work is still in flight: end the stale episode so a later
  # restale re-prints the full banner.
  [ "$READ_ONLY" -eq 1 ] || fm_guard_clear_stale_banner
  # A fresh watcher is necessary but not sufficient: verify a wake path is owned
  # (present daemon, away daemon, or a live this-home arm). When the watcher is
  # alive but NO owner exists, warn - but only behind the grace/dedup gate, so a
  # sub-second wake-handoff gap (arm completed, model not yet re-armed) never trips
  # a spurious warning. fm_wake_path_owned itself errs toward owned on any probe
  # uncertainty, so this warns only on a genuine, persistent unowned state.
  if fm_wake_path_owned "$STATE" "$SCRIPT_DIR"; then
    [ "$READ_ONLY" -eq 1 ] || fm_guard_wake_path_clear
  elif [ "$READ_ONLY" -ne 1 ] && fm_guard_wake_path_should_warn; then
    printf 'WARNING: WATCHER ALIVE BUT NO WAKE-PATH OWNER - %d task(s) in flight, a watcher holds the lock, but no live present daemon, away daemon, or arm task will complete to wake this session. Re-arm one bin/fm-watch-arm.sh cycle. %s\n' \
      "$in_flight" "$CONTINUE_LINE" >&2
  fi
fi

# Queued wakes are an independent hazard; warn whenever they are pending, even if
# a watcher is alive. Kept after the banner so the no-watcher alarm reads first.
# Dedup of the watcher-down banner never suppresses this warning. The one
# exception is the benign-only case: when EVERY pending record is an
# already-surfaced signal (its status signature still equals the watcher's
# recorded .seen-* and its last line is not captain-relevant), draining changes
# nothing firstmate has not already seen, so the advisory is pure noise and is
# dropped. The at-least-once no-loss drain semantics are untouched: this only
# gates the ADVISORY print, and a read-only session still reports the queue to the
# lock holder regardless, because it is not the one that will drain it.
if "$queue_pending"; then
  if [ "$READ_ONLY" -eq 1 ]; then
    echo "WARNING: queued wakes pending - left untouched for the session holding the fleet lock." >&2
  elif ! fm_guard_queue_all_benign "$FM_WAKE_QUEUE" "$STATE"; then
    echo "WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else." >&2
  fi
fi
exit 0
