#!/usr/bin/env bash
# fm-afk-outbox-lib.sh - the single owner of away-mode PULL delivery: the durable
# outbox the sub-supervisor writes when it has no supervisor pane to type into,
# and the acknowledgement contract its reader (bin/fm-afk-inbox.sh) uses.
#
# Why this exists. bin/fm-supervise-daemon.sh delivers every escalation digest by
# typing it into firstmate's own pane. A primary firstmate that runs OUTSIDE any
# supported terminal backend - a Claude Code session launched from the desktop
# app, for example - has no such pane, so supervisor discovery falls through to
# its legacy "firstmate:0" GUESS, types into whatever unrelated pane answers to
# it, never gets an affirmatively-empty-composer confirmation, and buffers
# forever. Observed 2026-07-22: ~80 minutes of away-mode escalations undelivered
# behind repeated "inject deferred: supervisor composer not confirmed-empty"
# lines and one "away-mode escalation undelivered 1531s" ERROR. Nothing was lost
# (the durable wake queue survived), but away mode was silently useless.
#
# The pull path needs no pane: the daemon appends each flushed digest here, and
# firstmate keeps bin/fm-afk-inbox.sh armed through its resilient wrapper
# bin/fm-afk-inbox-arm.sh as its own harness-tracked background task, exactly the
# way bin/fm-watch-arm.sh is armed. The harness's own task-completion
# notification becomes the delivery mechanism.
#
# RECORD FORMAT (one line per flushed digest, append only):
#   <epoch>\t<seq>\t<kind>\t<digest>
# <seq> is a strictly increasing integer allocated from state/.afk-outbox.seq.
# <digest> is the exact single-line text the pane path would have typed, its
# in-band operational envelope included, with any tab, CR, or LF replaced by a
# space so one record stays one line.
# bin/fm-operational-input.sh owns that envelope; this library only carries it.
#
# ACKNOWLEDGEMENT. state/.afk-outbox.ack holds the highest acknowledged <seq>.
# Only the READER writes it, and only after those records are already on its
# stdout. The writer never consumes a record. So a reader killed mid-wait or
# mid-print loses nothing: the next reader run delivers the same unacknowledged
# records. Delivery is exactly-once within a run and at-least-once across a
# killed run, which is the correct bias - a killed reader's stdout never reached
# firstmate. Acknowledgement also compacts the outbox: records at or below the
# mark are dropped under the lock by an atomic rewrite, so the file stays
# proportional to what is still pending instead of growing all session.
#
# Two readers running at once inherit that same at-least-once bias: each prints
# before it acknowledges, so an interleaving where both read the same pending
# records before either acknowledges delivers them twice. That is deliberate.
# Holding the lock across the print would make it exactly-once but would block
# the daemon's appends behind whatever is consuming the reader's stdout, and
# acknowledging first would lose records outright. A duplicated escalation digest
# is harmless; a dropped one is the incident this whole path exists to fix.
#
# LOCKING. Every mutation and every pending read takes the repo's portable lock
# helper (bin/fm-wake-lib.sh) on state/.afk-outbox.lock, so the daemon may append
# while a reader waits. flock is absent on macOS and is never used.
#
# This library is sourced, never executed. It has no side effects at source time:
# bin/fm-wake-lib.sh creates its state directory when sourced, so the lock helpers
# are pulled in lazily on first use against an explicit state directory.

FM_AFK_OUTBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FM_AFK_OUTBOX_NAME=".afk-outbox"
FM_AFK_OUTBOX_ACK_NAME=".afk-outbox.ack"
FM_AFK_OUTBOX_SEQ_NAME=".afk-outbox.seq"
FM_AFK_OUTBOX_LOCK_NAME=".afk-outbox.lock"
FM_AFK_DELIVERY_MODE_NAME=".afk-delivery"
FM_AFK_INBOX_BEACON_NAME=".afk-inbox.beat"

# A read that FAILED - the lock helper is unusable, or the record scan itself
# could not read the file - reports this status, distinct from a read that
# succeeded and found nothing. The two must never be conflated: "the outbox could
# not be read" announced as "the outbox is empty" turns a real delivery failure
# into a healthy idle exit, and lets the return catch-up gate delete escalations
# it never read. Only a genuinely successful read may be reported as nothing, and
# only a genuinely successful read may ever permit deletion.
FM_AFK_OUTBOX_UNREADABLE=2

# A read whose only failure was the BOUNDED lock acquire giving up reports this
# status instead. The outbox itself is intact and the next attempt will usually
# get the lock, so a caller that can retry - the blocking reader - must stay alive
# rather than tearing the delivery channel down over a lock the daemon happened to
# hold. Everything the unreadable status forbids still applies here unchanged: a
# timeout is never an empty read, never acknowledges, and never permits deletion.
FM_AFK_OUTBOX_LOCK_TIMEOUT=4

fm_afk_outbox_file() {  # <state>
  printf '%s/%s' "$1" "$FM_AFK_OUTBOX_NAME"
}

fm_afk_outbox_ack_file() {  # <state>
  printf '%s/%s' "$1" "$FM_AFK_OUTBOX_ACK_NAME"
}

fm_afk_outbox_seq_file() {  # <state>
  printf '%s/%s' "$1" "$FM_AFK_OUTBOX_SEQ_NAME"
}

fm_afk_outbox_lock_file() {  # <state>
  printf '%s/%s' "$1" "$FM_AFK_OUTBOX_LOCK_NAME"
}

fm_afk_delivery_mode_file() {  # <state>
  printf '%s/%s' "$1" "$FM_AFK_DELIVERY_MODE_NAME"
}

fm_afk_inbox_beacon_file() {  # <state>
  printf '%s/%s' "$1" "$FM_AFK_INBOX_BEACON_NAME"
}

# The reader's liveness beacon, in the same shape as the watcher's
# state/.last-watcher-beat: bin/fm-afk-inbox.sh touches it on every poll
# iteration while it blocks, and again on every acknowledgement, so a long quiet
# wait with no traffic still reads as ALIVE.
#
# The daemon's paneless undelivered-escalation alarm must answer "is anyone going
# to read this?", not "how old is the oldest record?". Age alone cannot tell a
# reader that was never armed from a firstmate that is simply mid-turn, and agent
# turns longer than the max-defer window are routine, so age alone alarms on the
# healthy path. Age AND a stale-or-absent beacon means nothing has claimed the
# outbox, which is the condition worth waking the captain for.
#
# Best-effort: a beacon that cannot be written leaves it looking absent, which
# alarms rather than staying silent - the direction that cannot hide an
# undelivered escalation.
fm_afk_inbox_beacon_touch() {  # <state>
  local state=$1 file
  file=$(fm_afk_inbox_beacon_file "$state")
  # `touch`, not a truncating redirect: an already-empty beacon truncated again
  # is not guaranteed to have its mtime updated, and the mtime IS the signal.
  touch "$file" 2>/dev/null || return 1
}

# The effective away-mode max-defer window and the multiple of it that a reader
# beacon must go unstamped before the reader counts as gone. Both live here, with
# the beacon they describe, because two consumers now need the same answer: the
# daemon's paneless undelivered alarm (bin/fm-supervise-daemon.sh) and the
# session-start reader-liveness check (bin/fm-afk-reader-check.sh). Deriving the
# staleness window from max-defer keeps the two windows comparable however
# max-defer is configured, and docs/configuration.md owns the published defaults.
FM_AFK_MAX_DEFER_SECS_DEFAULT=300

FM_AFK_INBOX_BEACON_STALE_DEFER_MULTIPLE=2

# Seconds since <file> was last touched, and a very large number when it does not
# exist - so an absent beacon reads as the strongest possible form of "nothing is
# listening" rather than as a fresh stamp. Same portable stat pair the watcher and
# the daemon use, kept here so every beacon consumer measures age identically.
#
# The stat FLAVOR is decided ONCE by uname, never by a `stat -f || stat -c`
# fallback: on GNU/Linux `stat -f %m` reads FILESYSTEM status (not mtime) and
# EXITS 0 with garbage, so an `||` chain never reaches `stat -c %Y` and the age
# comes back empty. An empty age silently defeats every beacon consumer - the
# reader-liveness detector reads a healthy home and the daemon's undelivered
# alarm never fires - which is the same never-decide-per-call discipline
# bin/fm-watch.sh applies. A stat that cannot read the mtime falls back to `now`,
# i.e. age 0, the safe direction that never fabricates staleness.
if [ "$(uname)" = Darwin ]; then
  _fm_afk_file_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  _fm_afk_file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi
fm_afk_file_age() {  # <file>
  local f=$1 mtime now
  [ -e "$f" ] || { printf '999999'; return 0; }
  now=$(date +%s)
  mtime=$(_fm_afk_file_mtime "$f")
  case "$mtime" in
    ''|*[!0-9]*) mtime=$now ;;
  esac
  printf '%s' $(( now - mtime ))
}

# Seconds without a beacon stamp before firstmate's inbox reader counts as gone.
# A non-numeric or zero FM_AFK_INBOX_BEACON_STALE_SECS override falls back to the
# derived default rather than disabling the check, because a window of zero would
# make every armed reader look dead.
fm_afk_inbox_beacon_stale_secs() {
  local secs=${FM_AFK_INBOX_BEACON_STALE_SECS:-} max_defer
  case "$secs" in
    ''|*[!0-9]*|0)
      max_defer=${FM_MAX_DEFER_SECS:-$FM_AFK_MAX_DEFER_SECS_DEFAULT}
      case "$max_defer" in
        ''|*[!0-9]*|0) max_defer=$FM_AFK_MAX_DEFER_SECS_DEFAULT ;;
      esac
      secs=$(( max_defer * FM_AFK_INBOX_BEACON_STALE_DEFER_MULTIPLE ))
      ;;
  esac
  printf '%s' "$secs"
}

# Session-scoped away-mode delivery artifacts owned by this library, one name per
# line. bin/fm-afk-start.sh folds them into the single session-artifact list that
# fresh-entry clearing and the launcher's transactional rollback both iterate, so
# those two sets can never drift apart.
#
# These are the DURABLE records: plain files whose content is meaningful, so the
# launcher can back them up and restore them byte for byte on a rolled-back
# start. The lock and the mktemp siblings are listed separately below, because
# they are process-scoped scratch that must be cleared with the same list but can
# never be meaningfully backed up or restored.
fm_afk_outbox_artifact_names() {
  printf '%s\n' \
    "$FM_AFK_OUTBOX_NAME" \
    "$FM_AFK_OUTBOX_ACK_NAME" \
    "$FM_AFK_OUTBOX_SEQ_NAME" \
    "$FM_AFK_DELIVERY_MODE_NAME"
}

# Process-scoped scratch this library can leave behind, one shell glob per line:
# the portable lock (plus its steal sibling), the mktemp files that an
# acknowledgement, a compaction, or a delivery-mode record uses for its atomic
# rename, and the reader's liveness beacon. A mid-ack kill leaves those temp files
# behind, and the lock is only recovered lazily by the portable helper's dead-pid
# steal, so a fresh away entry clears them here rather than inheriting another
# session's scratch.
# A lock whose owner process is still ALIVE is the one exception: it is left
# exactly where it is, because it is a working lock rather than scratch.
#
# The beacon belongs in THIS list rather than the durable one above for the same
# reason the lock does: it is a liveness signal about a running process, so it can
# never be meaningfully backed up and restored. A beacon restored onto a
# rolled-back start would make a reader that is not running look alive and hide an
# undelivered escalation; clearing it merely makes the alarm fire sooner.
fm_afk_outbox_transient_artifact_globs() {
  printf '%s\n' \
    "$FM_AFK_OUTBOX_LOCK_NAME" \
    "$FM_AFK_OUTBOX_LOCK_NAME.steal" \
    "$FM_AFK_OUTBOX_ACK_NAME.pending.*" \
    "$FM_AFK_OUTBOX_NAME.compact.*" \
    "$FM_AFK_DELIVERY_MODE_NAME.pending.*" \
    "$FM_AFK_INBOX_BEACON_NAME"
}

# Is the portable lock at <path> still held by a LIVE process? A lock whose owner
# is running is not stale scratch: tearing it out would break mutual exclusion
# between that live holder (a reader armed by an earlier still-running session,
# mid-compaction) and whoever clears. A genuinely dead owner needs no help here,
# because bin/fm-wake-lib.sh's own dead-pid steal already recovers it lazily.
#
# Unreadable or non-numeric pid means NOT alive, so clearing proceeds: that is the
# same reading the lock helper's steal path takes.
_fm_afk_outbox_lock_owner_alive() {  # <path>
  local path=$1 pid
  pid=$(cat "$path/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if declare -F fm_pid_alive >/dev/null 2>&1; then
    fm_pid_alive "$pid"
    return
  fi
  kill -0 "$pid" 2>/dev/null
}

# Remove one transient artifact glob. The lock is a directory or a symlink to an
# owner directory rather than a plain file, so it is retired through the portable
# lock helper's own removal path when that helper is loaded, and torn out
# wholesale otherwise.
#
# A lock still held by a live process is SKIPPED rather than removed, and a skip
# is not a clearing failure: it neither names an unclearable artifact nor makes
# this helper return non-zero, because nothing is stale and nothing is stuck.
#
# Every failure NAMES the artifact it could not clear on stderr as well as
# returning non-zero, so a caller that only sees the status can still report
# something actionable instead of a silent stop.
fm_afk_outbox_clear_transient() {  # <state>
  local state=$1 glob path status=0
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    for path in "$state"/$glob; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      case "$glob" in
        "$FM_AFK_OUTBOX_LOCK_NAME"|"$FM_AFK_OUTBOX_LOCK_NAME".steal)
          if _fm_afk_outbox_lock_owner_alive "$path"; then
            continue
          fi
          ;;
      esac
      if [ -d "$path" ] || [ -L "$path" ]; then
        if declare -F fm_lock_remove_path >/dev/null 2>&1; then
          fm_lock_remove_path "$path" 2>/dev/null && continue
        fi
        rm -rf "$path" 2>/dev/null && continue
        printf 'afk: could not clear stale away-mode artifact %s\n' "$path" >&2
        status=1
        continue
      fi
      rm -f "$path" 2>/dev/null && continue
      printf 'afk: could not clear stale away-mode artifact %s\n' "$path" >&2
      status=1
    done
  done < <(fm_afk_outbox_transient_artifact_globs)
  return "$status"
}

# Clear this library's session-scoped artifacts - the durable records AND the
# process-scoped scratch - as one unit UNDER the outbox lock, so a fresh away
# entry cannot race a live holder. Appends and compaction both mutate the outbox
# while holding this lock, and a compaction lands by renaming a sibling over the
# outbox file: clearing outside the lock would let that rename resurrect a prior
# session's records over state the new session just cleared, with the ack mark
# gone, so the new session's reader would replay the prior session's digests as
# if they were fresh.
#
# Holding the lock is also what makes clearing the compaction temp files safe: no
# compaction can be in flight, so no cleared temp can survive to be renamed.
# fm_afk_outbox_clear_transient sees THIS process as the lock's live owner and
# therefore leaves the lock itself alone; the release below retires it.
#
# A bounded acquire that times out names the lock on stderr and returns non-zero
# WITHOUT clearing anything this lock guards: clearing anyway is exactly the race
# this exists to close. The caller still continues into away mode, per the
# entry-point contract in bin/fm-afk-start.sh.
fm_afk_outbox_clear_session() {  # <state>
  local state=$1 lock name status=0
  [ -d "$state" ] || return 0
  lock=$(fm_afk_outbox_lock_file "$state")
  if ! fm_afk_outbox_lock_lib "$state" || ! _fm_afk_outbox_lock_acquire "$lock"; then
    printf 'afk: could not clear stale away-mode artifact %s\n' "$lock" >&2
    return 1
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    rm -f "$state/$name" 2>/dev/null && continue
    printf 'afk: could not clear stale away-mode artifact %s\n' "$state/$name" >&2
    status=1
  done < <(fm_afk_outbox_artifact_names)
  fm_afk_outbox_clear_transient "$state" || status=1
  fm_lock_release "$lock"
  return "$status"
}

# Collapse the field separators so one digest can never become two records. The
# daemon has already collapsed newlines before it reaches here; this is the
# record format's own guarantee, independent of that.
fm_afk_outbox_clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

# Pull in the portable lock helpers on first use, scoped to the state directory
# the caller is operating on. Deferred rather than sourced at the top because
# bin/fm-wake-lib.sh creates its resolved state directory as a source-time side
# effect, and this library is sourced by the daemon's unit tests with no state
# override in force.
fm_afk_outbox_lock_lib() {  # <state>
  local state=$1
  if declare -F fm_lock_acquire_wait >/dev/null 2>&1; then
    return 0
  fi
  # shellcheck source=bin/fm-wake-lib.sh
  FM_STATE_OVERRIDE="$state" . "$FM_AFK_OUTBOX_LIB_DIR/fm-wake-lib.sh"
}

# Take the outbox lock with a BOUNDED wait. fm_lock_acquire_wait retries forever,
# which is right for a short-lived caller but wrong here: the daemon must never
# hang inside a delivery attempt when the state directory itself is unwritable
# (a read-only mount, a full disk). A bounded failure returns to the caller,
# which keeps the digest buffered and logs, so the next tick tries again.
_fm_afk_outbox_lock_acquire() {  # <lock-dir>
  local lock=$1 tries=${FM_AFK_OUTBOX_LOCK_TRIES:-100} i=0
  case "$tries" in
    ''|*[!0-9]*|0) tries=100 ;;
  esac
  while [ "$i" -lt "$tries" ]; do
    if fm_lock_try_acquire "$lock"; then
      return 0
    fi
    i=$((i + 1))
    sleep 0.05
  done
  return 1
}

# Can this state directory be looked INTO at all? Every cheap `[ -e ]` / `[ -s ]`
# early return below only STATS a path, and a stat inside a directory that cannot
# be traversed or read (mode 000, a revoked ACL, a bad mount) fails exactly the
# way an absent file does. Without this guard those early returns would answer
# "the read succeeded and found nothing" for an outbox nobody could look at,
# which is the same failed-read-is-not-an-empty-read conflation
# FM_AFK_OUTBOX_UNREADABLE exists to prevent - it would let the reader print a
# healthy idle line, let housekeeping retire the wedge marker, and let the return
# catch-up gate delete escalations it never saw.
# An ABSENT state directory is legitimately empty, not a failure: no away session
# has written anything here yet. Only a directory that EXISTS and still cannot be
# traversed and read - or a path that exists and is not a directory at all - is a
# failed read.
_fm_afk_outbox_state_readable() {  # <state>
  local state=$1
  [ -e "$state" ] || return 0
  [ -d "$state" ] && [ -x "$state" ] && [ -r "$state" ]
}

_fm_afk_outbox_int() {  # <text> -> the integer, or 0
  local value=$1
  case "$value" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$value" ;;
  esac
}

# The acknowledged high-water mark. An ABSENT ack file is a genuine 0: nothing has
# been acknowledged yet in this away session. A file that is PRESENT but cannot be
# read, or that holds anything other than a whole number, is a FAILED read and
# returns FM_AFK_OUTBOX_UNREADABLE with no output.
#
# This mark is the only thing that narrows the pending set, so collapsing a failed
# read into 0 is the same failed-read-is-not-a-value defect as the record scan,
# inverted: every record of the session would look unacknowledged, the reader would
# replay every digest it already delivered, the paneless undelivered alarm would
# fire off the session's first record, and the return gate would file the whole
# session as never picked up.
fm_afk_outbox_ack_seq() {  # <state>
  local file value rc=0
  file=$(fm_afk_outbox_ack_file "$1")
  _fm_afk_outbox_state_readable "$1" || return "$FM_AFK_OUTBOX_UNREADABLE"
  [ -e "$file" ] || { printf '0'; return 0; }
  value=$(head -n 1 "$file" 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return "$FM_AFK_OUTBOX_UNREADABLE"
  # The mark is written atomically (a sibling renamed over this file), so it is
  # never legitimately empty or partial while it exists: an empty or non-numeric
  # value is a damaged mark, not a zero.
  case "$value" in
    ''|*[!0-9]*) return "$FM_AFK_OUTBOX_UNREADABLE" ;;
  esac
  printf '%s' "$value"
}

# Highest sequence number present in the outbox itself, 0 when it is empty. A
# read that FAILS returns non-zero with no output rather than 0: a swallowed
# failure here would let the allocator hand out a number an existing
# acknowledgement already covers, making the new record invisible to every reader.
_fm_afk_outbox_last_seq() {  # <state>
  local file last rc=0
  file=$(fm_afk_outbox_file "$1")
  _fm_afk_outbox_state_readable "$1" || return "$FM_AFK_OUTBOX_UNREADABLE"
  [ -s "$file" ] || { printf '0'; return 0; }
  last=$(awk -F '\t' 'NF >= 4 && $2 ~ /^[0-9]+$/ && $2+0 > max { max = $2+0 } END { print max+0 }' \
    "$file" 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return "$FM_AFK_OUTBOX_UNREADABLE"
  printf '%s' "$(_fm_afk_outbox_int "$last")"
}

# Allocate the next sequence number. It is the successor of every number this
# home has already used: the seq counter, the acknowledged high-water mark, and
# the highest record still in the outbox. Taking the maximum of all three means a
# deleted or truncated counter can never hand out a number an acknowledgement
# already covers, which would make the new record invisible to every reader.
_fm_afk_outbox_next_seq() {  # <state>  (call under the outbox lock)
  local state=$1 seq ack last next rc=0
  seq=$(_fm_afk_outbox_int "$(head -n 1 "$(fm_afk_outbox_seq_file "$state")" 2>/dev/null || true)")
  ack=$(fm_afk_outbox_ack_seq "$state") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  last=$(_fm_afk_outbox_last_seq "$state") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  next=$seq
  [ "$ack" -gt "$next" ] && next=$ack
  [ "$last" -gt "$next" ] && next=$last
  printf '%s' "$((next + 1))"
}

# Append one delivery record. Returns non-zero if the record could not be
# persisted, so the daemon keeps the digest buffered instead of losing it.
#
# On success this sets FM_AFK_OUTBOX_APPEND_SEQ to the sequence number it
# allocated and FM_AFK_OUTBOX_APPEND_PENDING to the pending count as observed
# INSIDE the critical section, or to the empty string when that count could not be
# read. A caller that instead re-read the count after the
# lock was released could lose the race to a concurrent reader, fail the bounded
# acquire, and announce "0 record(s) pending pickup" immediately after a record
# it successfully appended - which reads as a dropped escalation during exactly
# the incident that log line exists to diagnose.
# shellcheck disable=SC2034 # Read by callers (fm-supervise-daemon.sh) after this returns.
fm_afk_outbox_append() {  # <state> <kind> <digest>
  local state=$1 kind=$2 digest=$3 clean_kind clean_digest seq lock status=0 ack pending
  FM_AFK_OUTBOX_APPEND_SEQ=0
  FM_AFK_OUTBOX_APPEND_PENDING=
  mkdir -p "$state" || return 1
  clean_kind=$(printf '%s' "$kind" | fm_afk_outbox_clean_field)
  clean_digest=$(printf '%s' "$digest" | fm_afk_outbox_clean_field)
  [ -n "$clean_kind" ] || clean_kind=escalation
  [ -n "$clean_digest" ] || return 1
  fm_afk_outbox_lock_lib "$state" || return 1
  lock=$(fm_afk_outbox_lock_file "$state")
  _fm_afk_outbox_lock_acquire "$lock" || return 1
  seq=$(_fm_afk_outbox_next_seq "$state") || status=1
  [ "$status" -eq 0 ] || { fm_lock_release "$lock"; return 1; }
  printf '%s\n' "$seq" > "$(fm_afk_outbox_seq_file "$state")" || status=1
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$seq" "$clean_kind" "$clean_digest" \
      >> "$(fm_afk_outbox_file "$state")" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    FM_AFK_OUTBOX_APPEND_SEQ=$seq
    # An unreadable acknowledgement mark, or an awk that fails, leaves the count
    # EMPTY rather than 0. The record is already persisted, so the append still
    # succeeds; announcing "0 record(s) pending pickup" for a count that could not
    # be read would misreport a stored escalation as a dropped one.
    if ack=$(fm_afk_outbox_ack_seq "$state"); then
      if pending=$(awk -F '\t' -v ack="$ack" \
        'NF >= 4 && $2 ~ /^[0-9]+$/ && $2+0 > ack+0 { n++ } END { print n+0 }' \
        "$(fm_afk_outbox_file "$state")" 2>/dev/null); then
        FM_AFK_OUTBOX_APPEND_PENDING=$pending
      fi
    fi
  fi
  fm_lock_release "$lock"
  return "$status"
}

# Raw unacknowledged records, oldest first. Read under the lock so a concurrent
# append is never observed half-written. Returns 0 with possibly-empty output
# when the read succeeded, FM_AFK_OUTBOX_UNREADABLE when it did not.
fm_afk_outbox_pending() {  # <state>
  local state=$1 lock ack file records rc=0
  file=$(fm_afk_outbox_file "$state")
  # Ordered before the `[ -s ]` short-circuit on purpose: a state directory that
  # cannot be looked into fails that stat exactly like an absent outbox, so
  # answering it here is what keeps "no outbox file" and "cannot look at the
  # outbox" separate outcomes.
  _fm_afk_outbox_state_readable "$state" || return "$FM_AFK_OUTBOX_UNREADABLE"
  [ -s "$file" ] || return 0
  fm_afk_outbox_lock_lib "$state" || return "$FM_AFK_OUTBOX_UNREADABLE"
  lock=$(fm_afk_outbox_lock_file "$state")
  # A bounded acquire that timed out gets its own status: the outbox is readable,
  # somebody else simply held the lock, so a reader may retry instead of dying.
  _fm_afk_outbox_lock_acquire "$lock" || return "$FM_AFK_OUTBOX_LOCK_TIMEOUT"
  # An acknowledgement mark that could not be read narrows nothing, so it is a
  # failed read too rather than a licence to treat every record as pending.
  ack=$(fm_afk_outbox_ack_seq "$state") || rc=$?
  if [ "$rc" -ne 0 ]; then
    fm_lock_release "$lock"
    return "$FM_AFK_OUTBOX_UNREADABLE"
  fi
  # The record read itself must propagate failure. `[ -s ]` above only STATS the
  # file, so a present-but-unreadable outbox (mode 000, an ACL, a bad mount) or a
  # failing awk reaches here, and swallowing that status would report "the read
  # succeeded and found nothing" - the exact conflation the status below exists to
  # prevent, just moved past the lock.
  records=$(awk -F '\t' -v ack="$ack" 'NF >= 4 && $2 ~ /^[0-9]+$/ && $2+0 > ack+0' "$file" 2>/dev/null) || rc=$?
  fm_lock_release "$lock"
  [ "$rc" -eq 0 ] || return "$FM_AFK_OUTBOX_UNREADABLE"
  [ -n "$records" ] || return 0
  printf '%s\n' "$records"
  # Explicit, rather than inheriting fm_lock_release's status: a release that
  # ever reported failure would otherwise turn a successful pending read into
  # "nothing pending" and stall delivery until the next poll.
  return 0
}

# The count of unacknowledged records, or FM_AFK_OUTBOX_UNREADABLE with no output
# when the read failed. A caller that prints this must check the status: printing
# a bare 0 for an unreadable outbox reads as a dropped escalation.
fm_afk_outbox_pending_count() {  # <state>
  local pending rc=0
  pending=$(fm_afk_outbox_pending "$1") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ -n "$pending" ] || { printf '0'; return 0; }
  printf '%s' "$(printf '%s\n' "$pending" | wc -l | tr -d ' ')"
}

# Epoch of the OLDEST unacknowledged record, empty when nothing is pending, and
# FM_AFK_OUTBOX_UNREADABLE when the read failed. The daemon's paneless
# undelivered-escalation alarm keys off this age.
fm_afk_outbox_oldest_pending_epoch() {  # <state>
  local pending rc=0
  pending=$(fm_afk_outbox_pending "$1") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ -n "$pending" ] || return 0
  printf '%s\n' "$pending" \
    | awk -F '\t' '$1 ~ /^[0-9]+$/ { if (oldest == "" || $1+0 < oldest) oldest = $1+0 } END { if (oldest != "") print oldest }'
}

# Portable epoch rendering. awk's strftime is a gawk extension that the macOS awk
# does not have, and `date -r` / `date -d @` differ by platform, so the platform
# is decided once here rather than probed per call - the same discipline
# bin/fm-watch.sh applies to stat.
if [ "$(uname)" = Darwin ]; then
  _fm_afk_outbox_stamp() { date -r "$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null; }
else
  _fm_afk_outbox_stamp() { date -d "@$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null; }
fi

# One human-readable line per raw record, for the reader's stdout and for the
# return catch-up gate's evidence. The digest keeps its sentinel marker verbatim,
# so a relayed line is still recognizable as an internal escalation.
fm_afk_outbox_format() {  # <raw-records-on-stdin>
  local epoch seq kind digest stamp
  while IFS="$(printf '\t')" read -r epoch seq kind digest; do
    [ -n "$digest" ] || continue
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    stamp=""
    case "$epoch" in
      ''|*[!0-9]*) ;;
      *) stamp=$(_fm_afk_outbox_stamp "$epoch") ;;
    esac
    printf '[%s] %s: %s\n' "${stamp:-$epoch}" "$kind" "$digest"
  done
}

# Formatted pending records WITHOUT acknowledging them. Used by the return
# catch-up gate, which reports leftovers as evidence rather than consuming them
# as a delivery. Returns FM_AFK_OUTBOX_UNREADABLE when the read failed, so the
# gate can refuse to clear an outbox whose content it never saw.
fm_afk_outbox_pending_report() {  # <state>
  local pending rc=0
  pending=$(fm_afk_outbox_pending "$1") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ -n "$pending" ] || return 0
  printf '%s\n' "$pending" | fm_afk_outbox_format
}

# Drop records the acknowledgement mark already covers, so the outbox stays
# proportional to what is PENDING instead of growing for a whole away session -
# an overnight session would otherwise have the reader's one-second poll re-lock
# and re-scan hundreds of long-delivered records, and once every record is
# acknowledged the compacted file is empty, so the poll's `[ -s ]` check answers
# without taking the lock at all.
#
# Safety, which outranks the speedup: only records at or below the mark are ever
# removed, the rewrite happens under the outbox lock, and it lands by renaming a
# sibling over the file, so an interrupted compaction leaves every record intact
# rather than truncating an unacknowledged one. Sequence allocation is unaffected:
# _fm_afk_outbox_next_seq takes the maximum of the seq counter, the ack mark, and
# the highest record still present, and both of the first two survive compaction,
# so a compacted record's number can never be handed out again.
#
# Entirely best-effort: any failure leaves the outbox exactly as it was.
_fm_afk_outbox_compact() {  # <state>
  local state=$1 file lock ack compact_file
  file=$(fm_afk_outbox_file "$state")
  _fm_afk_outbox_state_readable "$state" || return 1
  [ -s "$file" ] || return 0
  fm_afk_outbox_lock_lib "$state" || return 1
  lock=$(fm_afk_outbox_lock_file "$state")
  _fm_afk_outbox_lock_acquire "$lock" || return 1
  ack=$(fm_afk_outbox_ack_seq "$state") || { fm_lock_release "$lock"; return 1; }
  compact_file=$(mktemp "$state/$FM_AFK_OUTBOX_NAME.compact.XXXXXX") || { fm_lock_release "$lock"; return 1; }
  # A malformed line has no acknowledgeable sequence number, so it is KEPT: only a
  # record this mark demonstrably covers may be dropped.
  if awk -F '\t' -v ack="$ack" \
    '!(NF >= 4 && $2 ~ /^[0-9]+$/ && $2+0 <= ack+0)' "$file" > "$compact_file" 2>/dev/null; then
    mv "$compact_file" "$file" 2>/dev/null || rm -f "$compact_file"
  else
    rm -f "$compact_file"
  fi
  fm_lock_release "$lock"
  return 0
}

# Record the acknowledged high-water mark atomically (write a sibling, rename over
# the ack file), so an interrupted acknowledgement leaves the previous mark intact
# and the records are simply delivered again. Acknowledgement is what makes a
# record removable, so this is also where the outbox is compacted.
fm_afk_outbox_ack() {  # <state> <seq>
  local state=$1 seq=$2 ack pending_file
  case "$seq" in
    ''|*[!0-9]*) return 1 ;;
  esac
  ack=$(fm_afk_outbox_ack_file "$state")
  # Built from the same constant fm_afk_outbox_transient_artifact_globs derives
  # its cleanup glob from, so a rename can never orphan the temp files.
  pending_file=$(mktemp "$state/$FM_AFK_OUTBOX_ACK_NAME.pending.XXXXXX") || return 1
  printf '%s\n' "$seq" > "$pending_file" || { rm -f "$pending_file"; return 1; }
  mv "$pending_file" "$ack" || { rm -f "$pending_file"; return 1; }
  # Best-effort: a compaction that cannot run leaves a correct, merely larger
  # outbox, and must never fail an acknowledgement that already landed.
  _fm_afk_outbox_compact "$state" || true
}

# Deliver every unacknowledged record: print the formatted records on stdout
# FIRST, then acknowledge them. Returns 0 when at least one record was delivered,
# 1 when there was nothing pending, 2 when records were printed but could not be
# acknowledged (the caller reports that loudly; the records stay pending and are
# delivered again rather than lost), FM_AFK_OUTBOX_DELIVER_UNREADABLE when the
# pending read itself failed, and FM_AFK_OUTBOX_DELIVER_LOCK_TIMEOUT when that
# read failed only because the bounded lock acquire gave up. Neither of those two
# is 1: an outbox that could not be read is not an outbox that is empty, and a
# caller that conflated them would announce a healthy idle exit during a real
# failure. They stay distinct from each other because a lock timeout is worth
# retrying and an unreadable outbox is not.
#
# Deliberate ordering: print, then acknowledge. A reader killed between the two
# has not actually delivered anything to firstmate, so re-delivering is correct.
#
# Sets FM_AFK_OUTBOX_DELIVERED to how many records actually reached stdout, so a
# caller can announce the count WITHOUT capturing the records into a variable
# first. Capturing them would delay every record behind the acknowledgement and
# reintroduce the loss window the print-then-acknowledge ordering exists to
# close. The count is 0 on every non-zero return, so a caller that lost the race
# to a concurrent reader announces nothing rather than an empty delivery.
FM_AFK_OUTBOX_DELIVER_UNREADABLE=3
FM_AFK_OUTBOX_DELIVER_LOCK_TIMEOUT=5

# shellcheck disable=SC2034 # Read by callers (fm-afk-inbox.sh) after this returns.
fm_afk_outbox_deliver() {  # <state>
  local state=$1 pending last rc=0
  FM_AFK_OUTBOX_DELIVERED=0
  pending=$(fm_afk_outbox_pending "$state") || rc=$?
  if [ "$rc" -eq "$FM_AFK_OUTBOX_LOCK_TIMEOUT" ]; then
    return "$FM_AFK_OUTBOX_DELIVER_LOCK_TIMEOUT"
  fi
  [ "$rc" -eq 0 ] || return "$FM_AFK_OUTBOX_DELIVER_UNREADABLE"
  [ -n "$pending" ] || return 1
  printf '%s\n' "$pending" | fm_afk_outbox_format
  FM_AFK_OUTBOX_DELIVERED=$(printf '%s\n' "$pending" | wc -l | tr -d ' ')
  last=$(printf '%s\n' "$pending" | awk -F '\t' 'NF >= 4 && $2+0 > max { max = $2+0 } END { print max+0 }')
  fm_afk_outbox_ack "$state" "$last" || return 2
  return 0
}

# The daemon records which delivery mode it selected at startup so the reader and
# firstmate can tell a paneless away session from a pane one without re-deriving
# the daemon's own discovery.
fm_afk_delivery_mode_record() {  # <state> <mode>
  local state=$1 mode=$2 file pending_file
  case "$mode" in
    pane|paneless) ;;
    *) return 1 ;;
  esac
  mkdir -p "$state" || return 1
  file=$(fm_afk_delivery_mode_file "$state")
  pending_file=$(mktemp "$state/$FM_AFK_DELIVERY_MODE_NAME.pending.XXXXXX") || return 1
  printf '%s\n' "$mode" > "$pending_file" || { rm -f "$pending_file"; return 1; }
  mv "$pending_file" "$file" || { rm -f "$pending_file"; return 1; }
}

# The recorded delivery mode, or an empty string when no daemon has recorded one
# in this away session yet.
fm_afk_delivery_mode_recorded() {  # <state>
  local mode
  mode=$(head -n 1 "$(fm_afk_delivery_mode_file "$1")" 2>/dev/null || true)
  case "$mode" in
    pane|paneless) printf '%s' "$mode" ;;
    *) printf '' ;;
  esac
}
