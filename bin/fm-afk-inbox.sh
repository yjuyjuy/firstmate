#!/usr/bin/env bash
# fm-afk-inbox.sh - blocking reader for away-mode PULL delivery.
#
# The away-mode sub-supervisor normally types its escalation digests into
# firstmate's own pane. When firstmate runs outside every supported terminal
# backend there is no such pane, so bin/fm-supervise-daemon.sh selects paneless
# delivery and appends each flushed digest to the durable outbox instead
# (bin/fm-afk-outbox-lib.sh owns that record and acknowledgement contract).
#
# This script is the other half: firstmate keeps it armed through its resilient
# wrapper bin/fm-afk-inbox-arm.sh, which firstmate arms as the harness's OWN
# tracked background task exactly the way bin/fm-watch-arm.sh is armed, and the
# harness's task-completion notification becomes the delivery mechanism. This
# reader blocks until an unacknowledged record exists, prints the pending digests
# on stdout, marks them acknowledged, and exits. The wrapper (not this script) is
# what firstmate arms directly: it runs this reader resident (--timeout 0) so a
# quiet home never idle-exits it and relaunches it on a crash. Never fire this
# reader with a shell `&`: that backgrounded child is reaped when the call
# returns, leaving nothing listening.
#
# It exits promptly, and always after delivering anything already pending, when:
#   - records were delivered (the normal case),
#   - the daemon recorded PANE delivery (a supervisor pane exists, so nothing
#     will ever arrive here),
#   - away mode ended (state/.afk is gone), or
#   - --timeout elapsed with nothing pending.
#
# RE-ARM VERDICT. Every one of those exits is 0 and ends with exactly one status
# line, and every such line ends in either "re-arm to keep listening..." or
# "- do not re-arm". Firstmate obeys that line rather than re-deriving the state:
# re-arming after a "do not re-arm" exit is an immediate-exit loop, because those
# exits mean this channel is not the one delivering.
#
# A genuine OPERATIONAL failure - an outbox that could not be READ at all, a
# delivery that could not be acknowledged, a lock that never came free - exits
# NON-ZERO with a loud stderr diagnostic instead of pretending the channel is
# healthy. In particular, a failed read is never reported as an empty outbox: it
# never gets an idle or nothing-pending line. It still ends in its own re-arm
# verdict, because records are pending and nothing else is listening for them, so
# a mute exit would leave firstmate with no instruction and the channel unarmed -
# the same unwatched silence this path exists to remove. Re-arm it once and report
# the diagnostic; a second identical failure is a blocker for the captain, not a
# loop to keep running.
#
# Argument and state-directory failures are the exception and stay mute: re-arming
# with the same bad arguments, or against a state directory that cannot be
# created, would loop without ever listening.
#
# LOCK CONTENTION. The outbox lock is held for short mutations by the daemon and
# by any other reader, so a bounded acquire that simply times out is a transient
# condition, not a broken channel: this reader stays alive, prints no status line,
# acknowledges nothing, and tries again on the next poll. That retry is BOUNDED -
# after FM_AFK_INBOX_LOCK_TIMEOUT_MAX consecutive timeouts (default 12, so roughly
# a minute of a lock nobody releases) it exits non-zero naming the lock file it
# could not acquire, because a channel that spins forever is the same silence this
# path exists to remove. Any successful read resets the count.
#
# LIVENESS. This reader stamps state/.afk-inbox.beat as its first action when it
# arms, on every poll iteration while it waits, and on every acknowledgement, the
# same way bin/fm-watch.sh stamps state/.last-watcher-beat. The daemon's paneless
# undelivered-escalation alarm reads that beacon so it can tell "nobody is going
# to read this" from "firstmate is armed and simply mid-turn"; without it, any
# turn longer than the max-defer window would alarm the captain on the healthy
# path. The daemon owns how stale the stamp must be. The beacon is
# session-scoped and cleared on fresh away entry, so a previous session's stamp
# can never make a reader that is not running look alive.
#
# Concurrency: the outbox library takes the repo's portable lock (flock is absent
# on macOS) for every append and every pending read, so this reader is safe to
# run while the daemon is writing. Killing the reader mid-wait or mid-print loses
# nothing: records are acknowledged only after they are already on stdout, so the
# next run delivers the same unacknowledged records.
#
# Usage: fm-afk-inbox.sh [--timeout <secs>] [--poll <secs>] [--once]
#   --timeout <secs>  give up waiting after <secs> and exit 0 (default 3600, or
#                     FM_AFK_INBOX_TIMEOUT; 0 waits until away mode ends)
#   --poll <secs>     seconds between checks (default 1, or FM_AFK_INBOX_POLL)
#   --once            check once and exit without waiting
#   FM_AFK_INBOX_LOCK_TIMEOUT_MAX  consecutive outbox-lock timeouts tolerated
#                     before exiting non-zero (default 12)
#   FM_STATE_OVERRIDE alternate state dir (testing)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# FM_ROOT/FM_HOME/STATE and die (canonical exit 1 default) come from the shared
# preamble. Every die callsite here passes a single message argument, so the
# canonical die (prints "<FM_PROG>: <msg>", exits 1) is behavior-identical to the
# old local die. die_operational below stays script-local: it adds the re-arm
# verdict line and is not the plain die the lib owns.
FM_PROG=fm-afk-inbox
# shellcheck source=bin/fm-preamble-lib.sh
. "$SCRIPT_DIR/fm-preamble-lib.sh"

# shellcheck source=bin/fm-afk-outbox-lib.sh
. "$SCRIPT_DIR/fm-afk-outbox-lib.sh"

usage() {
  awk '/^# Usage:/ { show = 1 } show && /^#/ { sub(/^# ?/, ""); print; next } show { exit }' \
    "${BASH_SOURCE[0]}"
}

TIMEOUT=${FM_AFK_INBOX_TIMEOUT:-3600}
POLL=${FM_AFK_INBOX_POLL:-1}
ONCE=0
LOCK_TIMEOUT_MAX=${FM_AFK_INBOX_LOCK_TIMEOUT_MAX:-12}
case "$LOCK_TIMEOUT_MAX" in ''|*[!0-9]*|0) LOCK_TIMEOUT_MAX=12 ;; esac
LOCK_TIMEOUTS=0

# An OPERATIONAL failure - the outbox could not be read, a delivery could not be
# acknowledged, the lock never came free - still ends the run, but it must not end
# it MUTE. Firstmate obeys this reader's final line to decide whether to arm it
# again; a run that exits with only a stderr diagnostic leaves that decision
# undefined, and the honest reading of "undefined" has historically been "do
# nothing", which is exactly the unwatched channel this path exists to remove.
# Records are still pending and nothing else is listening for them, so the verdict
# is always re-arm. The exit stays non-zero and the diagnostic stays loud, so this
# can never be mistaken for a healthy idle exit: it is deliberately not one of the
# nothing-pending, idle, or delivered lines.
#
# The diagnostic is written FIRST so the verdict really is the final line even
# when the caller merges both streams.
#
# Argument and state-directory failures deliberately keep the plain die above: a
# reader re-armed with the same bad arguments, or against a state directory it
# cannot create, would loop on the same failure without ever listening.
die_operational() {
  printf 'fm-afk-inbox: %s\n' "$*" >&2
  printf 'afk-inbox: this run ended without delivering anything and any records stay pending; report the failure above and re-arm to keep listening\n'
  exit 1
}

# Print and acknowledge everything pending, then announce what was delivered.
# Returns 0 when something was delivered, 1 when the outbox was genuinely empty,
# and 2 when the bounded outbox-lock acquire timed out - a retryable failure that
# is emphatically NOT an empty read, so it prints nothing and the caller must go
# round the poll again rather than take any nothing-pending exit.
# An outbox that could NOT be read is a failure, never an empty one: reporting it
# as "nothing pending" would print a healthy re-arm line and exit 0 while records
# sit undelivered, which is the incident this whole channel exists to prevent.
#
# The count is announced AFTER the records, from what this run actually put on
# stdout. Announcing a pending count first would let a reader that loses the race
# to a concurrent reader print "1 away-mode escalation(s)" and then no record at
# all, which reads to firstmate as a swallowed escalation.
deliver() {
  local rc=0
  fm_afk_outbox_deliver "$STATE" || rc=$?
  case "$rc" in
    0)
      LOCK_TIMEOUTS=0
      # Acknowledgement is the strongest possible liveness proof, so re-stamp the
      # beacon right after one.
      fm_afk_inbox_beacon_touch "$STATE" || true
      printf 'afk-inbox: delivered %s away-mode escalation(s); re-arm to keep listening while away mode is active\n' \
        "$FM_AFK_OUTBOX_DELIVERED"
      return 0
      ;;
    1) LOCK_TIMEOUTS=0; return 1 ;;
    "$FM_AFK_OUTBOX_DELIVER_LOCK_TIMEOUT") return 2 ;;
    "$FM_AFK_OUTBOX_DELIVER_UNREADABLE")
      die_operational "the away-mode inbox could not be read (state directory unwritable, or the outbox lock is held); nothing was delivered and any records stay pending"
      ;;
    *) die_operational "delivered records could not be acknowledged; they stay pending and will be delivered again" ;;
  esac
}

away_mode_active() {
  [ -e "$STATE/.afk" ]
}

# Count one lock-acquire timeout and stop the run once the bound is spent. The
# bound exists so a lock nobody ever releases ends in a loud non-zero exit that
# NAMES the lock, instead of a reader that looks armed forever while records sit
# undelivered. Nothing is acknowledged or removed on this path: the records stay
# pending for the next reader.
note_lock_timeout() {
  LOCK_TIMEOUTS=$((LOCK_TIMEOUTS + 1))
  if [ "$LOCK_TIMEOUTS" -ge "$LOCK_TIMEOUT_MAX" ]; then
    die_operational "the away-mode inbox lock $(fm_afk_outbox_lock_file "$STATE") could not be acquired in $LOCK_TIMEOUTS consecutive attempts; nothing was delivered and any records stay pending"
  fi
}

main() {
  local waited=0 mode deliver_rc=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --timeout) [ "$#" -ge 2 ] || die "--timeout needs a value"; TIMEOUT=$2; shift 2 ;;
      --poll) [ "$#" -ge 2 ] || die "--poll needs a value"; POLL=$2; shift 2 ;;
      --once) ONCE=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) usage >&2; return 2 ;;
    esac
  done
  case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout must be a whole number of seconds" ;; esac
  case "$POLL" in ''|*[!0-9]*|0) die "--poll must be a positive whole number of seconds" ;; esac

  mkdir -p "$STATE" || die "cannot create state directory $STATE"

  # Stamp the liveness beacon before anything else, so a firstmate that arms this
  # reader and then runs a long turn is visibly ALIVE to the daemon's paneless
  # undelivered-escalation alarm from the moment it arms.
  fm_afk_inbox_beacon_touch "$STATE" || true

  # Anything already pending is delivered before any early-exit condition is
  # consulted: a record that exists must reach firstmate even if the away session
  # has since ended or switched to pane delivery.
  deliver_rc=0
  deliver || deliver_rc=$?
  [ "$deliver_rc" -eq 0 ] && return 0

  # A lock-acquire timeout read NOTHING, so none of the early exits below may run
  # off it: each of them announces an outbox this run never actually looked into.
  # A single-shot run has no next poll to retry on, so its only honest outcome is
  # the loud non-zero exit; a blocking run falls through to the poll loop with the
  # timeout counted.
  if [ "$deliver_rc" -eq 2 ]; then
    [ "$ONCE" -eq 0 ] \
      || die_operational "the away-mode inbox lock $(fm_afk_outbox_lock_file "$STATE") could not be acquired; nothing was delivered and any records stay pending"
    LOCK_TIMEOUTS=1
  else
    # A recorded PANE delivery mode means the daemon has a real supervisor pane and
    # nothing will ever be written here, so waiting would be a lie. An ABSENT
    # marker is not treated as pane delivery: no daemon has recorded a mode yet, so
    # this waits, which is the direction that cannot drop an escalation.
    mode=$(fm_afk_delivery_mode_recorded "$STATE")
    if [ "$mode" = pane ]; then
      printf 'afk-inbox: away mode is delivering into the supervisor pane; no inbox reader needed - do not re-arm\n'
      return 0
    fi

    if ! away_mode_active; then
      printf 'afk-inbox: away mode is not active; nothing to wait for - do not re-arm\n'
      return 0
    fi

    if [ "$ONCE" -eq 1 ]; then
      printf 'afk-inbox: nothing pending; re-arm to keep listening while away mode is active\n'
      return 0
    fi
  fi

  while true; do
    sleep "$POLL"
    waited=$((waited + POLL))
    # Every iteration, not only at arm time: a blocking wait with no traffic at
    # all must still read as alive, otherwise the daemon would alarm about an
    # armed and perfectly healthy reader.
    fm_afk_inbox_beacon_touch "$STATE" || true
    deliver_rc=0
    deliver || deliver_rc=$?
    [ "$deliver_rc" -eq 0 ] && return 0
    # A timeout is a failed read, so every exit below it - all of which assert
    # something about an outbox this iteration never saw - is skipped and the wait
    # simply continues. note_lock_timeout ends the run once the bound is spent.
    if [ "$deliver_rc" -eq 2 ]; then
      note_lock_timeout
      continue
    fi
    if ! away_mode_active; then
      printf 'afk-inbox: away mode ended; nothing pending - do not re-arm\n'
      return 0
    fi
    if [ "$(fm_afk_delivery_mode_recorded "$STATE")" = pane ]; then
      printf 'afk-inbox: away mode switched to the supervisor pane; no inbox reader needed - do not re-arm\n'
      return 0
    fi
    if [ "$TIMEOUT" -gt 0 ] && [ "$waited" -ge "$TIMEOUT" ]; then
      printf 'afk-inbox: idle after %ss with nothing pending; re-arm to keep listening\n' "$waited"
      return 0
    fi
  done
}

main "$@"
