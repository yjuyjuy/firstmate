#!/usr/bin/env bash
# fm-heavy-run.sh - the fleet's single serialization point for HEAVY runs: unit
# suites, end-to-end suites, lint sweeps, builds - anything that saturates the
# host rather than merely occupying an agent.
#
# A crewmate wraps its heavy command instead of running it directly:
#   fm-heavy-run.sh --task <id> -- npm test
# The command runs unchanged, its stdout and stderr stream straight through, and
# this script exits with the command's own status, so the crewmate acts on real
# results and is never left guessing whether its suite passed.
#
# Usage:
#   fm-heavy-run.sh [--task <id>] [--label <text>] [--max-wait <secs>] [--] <command> [args...]
#   fm-heavy-run.sh --status        print ceiling, running runs, and queue depth
#   fm-heavy-run.sh --slots         print the resolved concurrency ceiling
#   fm-heavy-run.sh --help
#
# WHY A LEASE QUEUE AND NOT A DAEMON. The thing that must be capped is the
# number of heavy runs executing at one instant, and the requester must receive
# the run's real output and status. A long-running worker would have to own the
# child process and then relay its stream and status back over some transport -
# a second protocol to build, supervise, and recover, plus a wedge risk of its
# own when the worker dies holding a run. Here the requesting crewmate's own
# process IS the worker: it takes a lease, runs its command in the foreground of
# its own shell, and drops the lease on exit. There is no component to keep
# alive, nothing to recover after a reboot, and output and exit status are
# native rather than relayed. The queue is therefore a directory of lease
# records plus one short-held admission lock (bin/fm-wake-lib.sh's proven
# symlink-owner lock, the same primitive the wake queue serializes on).
#
# WHY IT IS NOT THE RESOURCE GUARD. The host-resource monitor answers "is this
# machine healthy right now" and reports; this answers "how many heavy runs may
# proceed right now" and blocks. The two are deliberately uncoupled: a reading
# is advisory and momentary, while admission must be a hard, stateful count that
# holds across the exact transition the guard cannot catch - several parked
# crewmates being unblocked at once and all starting a suite before the next
# reading is ever taken.
#
# WHY THE LEDGER IS HOST-GLOBAL, NOT PER-HOME. The machine is the resource being
# protected, and a fleet runs several operational homes (a primary plus one or
# more secondmate homes) on one host. A per-home queue would give each home its
# own N slots, so the host-wide count would be N times the number of homes -
# exactly the multiplication this cap exists to prevent. The default queue
# therefore lives at a fixed host-global path outside any home
# (/tmp/fm-heavy-runs-<uid>, one per operating user so a shared box cannot cross-
# contaminate or be hijacked), and every home's runs share one running count.
# FM_HEAVY_RUN_DIR still overrides it (a test seam, and the way to scope a queue
# to something other than the whole host). The ceiling VALUE is read from the
# primary home's config so the homes sharing the ledger also share one cap:
# FM_HEAVY_SLOTS_FILE points at that authoritative config, and when it is unset
# or unreadable the resolver falls back to this home's own config, then to 1.
#
# LEASE RECORDS. <queue>/<seq>.entry, one per participant, each with seq, pid, a
# PID identity (start time plus command line), state=waiting or state=running,
# started, the operational home that owns the run, task, label, and a truncated
# command string. The home field is attribution only, so --status and firstmate
# can see which home each shared-ledger run belongs to. The admission lock is
# held only while records are read and rewritten, never while a command runs.
# Records are written to a temp file and renamed, so an unlocked --status never
# reads a half-written record.
#
# FAIRNESS AND VISIBILITY. Sequence numbers are monotonic and the lowest waiting
# sequence is admitted first, so a queued run cannot be starved by later
# arrivals. A waiting requester prints a queued notice to stderr immediately and
# again every FM_HEAVY_NOTICE seconds, so a crewmate and anyone reading its pane
# can tell it is queued rather than hung, and --status shows the whole queue.
#
# DEATH AND WEDGE SAFETY. Every record carries the requester's PID and identity.
# Each admission pass removes records whose process is gone, or whose PID has
# been reused by a different process, so a crewmate killed while queued or mid
# run frees its slot at the next pass without any timeout. Removing a record is
# the ONLY reaping action: this script never signals a process it did not start.
# The one process it does signal is its own child, which it forwards TERM, INT,
# and HUP to, so a killed requester does not orphan a running suite.
#
# HOST-PRESSURE GUARD. Admission also reads the watcher's CACHED sustained
# pressure verdict (state/.resource-status, the word the resource probe already
# published on its own cadence). A free slot is NOT granted while that cached
# verdict is a fresh `critical`, because starting new heavy work into a host that
# is already thrashing is the second failure mode this control exists to prevent.
# It reads the cache only and never samples afresh at acquire time, so it honours
# the sustained-sampling rule rather than reacting to a momentary spike. It fails
# OPEN: an absent, stale, unreadable, or non-critical verdict lets admission
# proceed normally, so a home with no resource monitor is never wedged by it.
#
# RELEASE NUDGE. When a run that HELD a slot releases it and a waiter is still
# queued, the releasing process enqueues one `check heavy-run-slot-free` wake, so
# firstmate nudges a waiter parked on `paused: awaiting test slot` to retry.
# Firstmate is the nudger, never the granter: the waiter still re-acquires
# through ordinary admission, and there is no separate FIFO ticket queue.
#
# REFUSALS. An unusable queue directory, an unobtainable admission lock, a
# vanished own record, or an exceeded --max-wait all refuse WITHOUT running the
# command: proceeding unserialized is exactly the failure this exists to
# prevent. A malformed ceiling falls back to 1, the safest value, and warns.
#
# Exit status:
#   the command's own status when the command ran
#   64  usage error
#   69  refused: the queue could not be brought to a safe state; nothing ran
#   75  refused: --max-wait elapsed while still queued; nothing ran
#   76  refused: the host is under sustained critical pressure; nothing ran
#
# ADRs docs/adr/0001-heavy-run-refuse-by-default-admission.md and
# docs/adr/0002-heavy-run-host-global-ledger.md record why admission refuses by
# default and why the ledger deliberately lives outside home isolation.
# docs/configuration.md owns the config/heavy-run-slots knob and the FM_HEAVY_*
# environment variables; this header owns the mechanism.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# The default ledger is host-global (see the header): one queue for the whole
# machine, scoped per operating user so a shared host cannot cross-contaminate.
# FM_HEAVY_RUN_DIR overrides it, which is also how the tests isolate.
HEAVY_GLOBAL_DEFAULT="${TMPDIR:-/tmp}/fm-heavy-runs-$(id -u 2>/dev/null || printf '%s' 0)"
HEAVY_DIR="${FM_HEAVY_RUN_DIR:-$HEAVY_GLOBAL_DEFAULT}"
QUEUE="$HEAVY_DIR/q"
LOCK="$HEAVY_DIR/admit.lock"
SEQ_FILE="$HEAVY_DIR/seq"
# This home's own ceiling file, and the authoritative pointer that overrides it
# so every home sharing the host-global ledger resolves one cap (see the header).
SLOTS_FILE="$CONFIG/heavy-run-slots"
SLOTS_POINTER="${FM_HEAVY_SLOTS_FILE:-}"

# Cached sustained host-pressure verdict the resource probe publishes, and the
# freshness bound the heartbeat annotation already uses (2 * probe interval).
RESOURCE_STATUS_FILE="${FM_HEAVY_RESOURCE_STATUS:-$STATE/.resource-status}"
RESOURCE_INTERVAL_OVERRIDE="${FM_HEAVY_RESOURCE_INTERVAL:-}"

POLL=${FM_HEAVY_POLL:-2}
NOTICE_EVERY=${FM_HEAVY_NOTICE:-30}
LOCK_MAX_WAIT=${FM_HEAVY_LOCK_WAIT:-30}

# The header comment IS the help text, from the description line to the last
# comment before the first executable line. Deriving that range beats hardcoding
# it, which silently truncates --help the moment the header grows a line.
usage() {
  awk 'NR < 2 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

log() {
  printf 'fm-heavy-run: %s\n' "$*" >&2
}

die_usage() {
  log "$*"
  log "run 'fm-heavy-run.sh --help' for usage"
  exit 64
}

refuse() {
  log "refusing without running the command: $*"
  exit 69
}

refuse_pressure() {
  log "refusing without running the command: $*"
  exit 76
}

# One line, no tabs or newlines, bounded length: lease records are line-oriented
# key=value and are read by --status without a lock.
one_line() {
  printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | cut -c1-200
}

# --- ceiling ----------------------------------------------------------------
#
# FM_HEAVY_SLOTS (operator override and test seam), then the authoritative
# ceiling file, then 1. The authoritative file is FM_HEAVY_SLOTS_FILE (the
# primary home's config/heavy-run-slots) when it is set and readable, so every
# home sharing the host-global ledger resolves ONE cap; otherwise this home's own
# config/heavy-run-slots. A malformed value falls back to 1 rather than to a
# permissive number: the failure mode of guessing high is the host thrash this
# exists to prevent.
resolve_slots() {
  local raw='' source_file=$SLOTS_FILE
  if [ -n "$SLOTS_POINTER" ] && [ -f "$SLOTS_POINTER" ] && [ -r "$SLOTS_POINTER" ]; then
    source_file=$SLOTS_POINTER
  fi
  if [ -n "${FM_HEAVY_SLOTS:-}" ]; then
    raw=$FM_HEAVY_SLOTS
  elif [ -f "$source_file" ]; then
    raw=$(grep -v '^[[:space:]]*$' "$source_file" 2>/dev/null | head -n 1 | tr -d '[:space:]')
  fi
  [ -n "$raw" ] || { printf '1\n'; return 0; }
  case "$raw" in
    ''|*[!0-9]*)
      log "warning: ignoring malformed heavy-run ceiling '$raw'; using 1"
      printf '1\n'
      return 0
      ;;
  esac
  if [ "$raw" -lt 1 ]; then
    log "warning: heavy-run ceiling '$raw' is below the floor; using 1"
    printf '1\n'
    return 0
  fi
  printf '%s\n' "$raw"
}

# --- lease records ----------------------------------------------------------

# A process's identity, normalized exactly the way it is stored: start time
# first, then the command line, squashed to one bounded line. BOTH sides of
# every comparison must go through this - a long command line truncated on write
# but not on read would make a live run reap its own record. Bounding is safe
# because the discriminating part, the process start time, sits at the front, so
# a reused PID still mismatches.
identity_of() {  # <pid>
  one_line "$(fm_pid_identity "$1" 2>/dev/null || true)"
}

E_SEQ=; E_PID=; E_IDENTITY=; E_STATE=; E_STARTED=; E_HOME=; E_TASK=; E_LABEL=; E_CMD=
entry_read() {  # <file>: populate E_*; non-zero when the record is unusable
  local file=$1 line
  E_SEQ=; E_PID=; E_IDENTITY=; E_STATE=; E_STARTED=; E_HOME=; E_TASK=; E_LABEL=; E_CMD=
  [ -f "$file" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      seq=*) E_SEQ=${line#seq=} ;;
      pid=*) E_PID=${line#pid=} ;;
      identity=*) E_IDENTITY=${line#identity=} ;;
      state=*) E_STATE=${line#state=} ;;
      started=*) E_STARTED=${line#started=} ;;
      home=*) E_HOME=${line#home=} ;;
      task=*) E_TASK=${line#task=} ;;
      label=*) E_LABEL=${line#label=} ;;
      cmd=*) E_CMD=${line#cmd=} ;;
    esac
  done < "$file"
  case "$E_PID" in ''|*[!0-9]*) return 1 ;; esac
  case "$E_STATE" in waiting|running) ;; *) return 1 ;; esac
  return 0
}

entry_write() {  # <file> <state>: atomic rewrite preserving this run's fields
  local file=$1 state=$2 tmp
  tmp=$(mktemp "$QUEUE/.entry.XXXXXX") || return 1
  {
    printf 'seq=%s\n' "$MY_SEQ"
    printf 'pid=%s\n' "$MY_PID"
    printf 'identity=%s\n' "$MY_IDENTITY"
    printf 'state=%s\n' "$state"
    printf 'started=%s\n' "$MY_STARTED"
    printf 'home=%s\n' "$MY_HOME"
    printf 'task=%s\n' "$TASK"
    printf 'label=%s\n' "$LABEL"
    printf 'cmd=%s\n' "$CMD_TEXT"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# Records in sequence order. Emits nothing when the queue is empty.
entry_files() {
  local f
  for f in "$QUEUE"/*.entry; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done
}

# Remove records whose owner is gone or whose PID was reused. THE ONLY reaping
# action is removing the record; the process itself is never signalled, because
# a reused PID belongs to somebody else entirely and a live crewmate agent must
# never be killed by fleet tooling. Uncertainty (a PID that is alive but whose
# identity cannot be read) keeps the record.
reap_dead() {
  local f live
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! entry_read "$f"; then
      rm -f "$f"
      continue
    fi
    if ! fm_pid_alive "$E_PID"; then
      rm -f "$f"
      continue
    fi
    [ -n "$E_IDENTITY" ] || continue
    live=$(identity_of "$E_PID")
    [ -n "$live" ] || continue
    [ "$live" = "$E_IDENTITY" ] || rm -f "$f"
  done < <(entry_files)
}

# --- admission lock ---------------------------------------------------------

lock_held=0
lock_acquire() {  # bounded: the lock is only ever held for a few file operations
  local deadline
  deadline=$(( $(date +%s) + LOCK_MAX_WAIT ))
  while ! fm_lock_try_acquire "$LOCK"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.1
  done
  lock_held=1
}

lock_drop() {
  [ "$lock_held" -eq 1 ] || return 0
  lock_held=0
  fm_lock_release "$LOCK"
}

ensure_queue() {
  local prior
  prior=$(umask)
  umask 077
  mkdir -p "$QUEUE" 2>/dev/null
  umask "$prior"
  local d
  for d in "$HEAVY_DIR" "$QUEUE"; do
    [ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] && [ -w "$d" ] \
      || refuse "ledger directory $d is unusable or not owned by this user"
  done
}

# --- status -----------------------------------------------------------------

cmd_status() {
  local slots f running=0 waiting=0 pos=0
  local -a run_lines=() wait_lines=()
  slots=$(resolve_slots)
  ensure_queue
  if lock_acquire; then
    reap_dead
    lock_drop
  else
    log "note: admission lock busy; reporting records without a reap pass"
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    entry_read "$f" || continue
    if [ "$E_STATE" = running ]; then
      running=$(( running + 1 ))
      run_lines+=("run  seq=$E_SEQ pid=$E_PID home=$E_HOME task=$E_TASK started=$E_STARTED label=$E_LABEL cmd=$E_CMD")
    else
      waiting=$(( waiting + 1 ))
      pos=$(( pos + 1 ))
      wait_lines+=("wait seq=$E_SEQ pid=$E_PID home=$E_HOME task=$E_TASK position=$pos queued=$E_STARTED label=$E_LABEL cmd=$E_CMD")
    fi
  done < <(entry_files)
  printf 'ceiling=%s\n' "$slots"
  printf 'running=%s\n' "$running"
  printf 'waiting=%s\n' "$waiting"
  printf '%s\n' "${run_lines[@]+"${run_lines[@]}"}" | grep -v '^$' || true
  printf '%s\n' "${wait_lines[@]+"${wait_lines[@]}"}" | grep -v '^$' || true
}

# --- argument parsing -------------------------------------------------------

MODE=run
TASK=${FM_TASK_ID:--}
LABEL=-
MAX_WAIT=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --status) MODE=status; shift ;;
    --slots) MODE=slots; shift ;;
    --task)
      [ "$#" -ge 2 ] || die_usage "--task needs a value"
      TASK=$(one_line "$2"); shift 2 ;;
    --label)
      [ "$#" -ge 2 ] || die_usage "--label needs a value"
      LABEL=$(one_line "$2"); shift 2 ;;
    --max-wait)
      [ "$#" -ge 2 ] || die_usage "--max-wait needs a value"
      MAX_WAIT=$2
      case "$MAX_WAIT" in ''|*[!0-9]*) die_usage "--max-wait needs whole seconds, got '$MAX_WAIT'" ;; esac
      shift 2 ;;
    --) shift; break ;;
    -*) die_usage "unknown option '$1'" ;;
    *) break ;;
  esac
done

case "$MODE" in
  slots) resolve_slots; exit 0 ;;
  status)
    [ "$#" -eq 0 ] || die_usage "--status takes no command"
    cmd_status
    exit 0
    ;;
esac

[ "$#" -gt 0 ] || die_usage "no command given"

SLOTS=$(resolve_slots)
CMD_TEXT=$(one_line "$*")
MY_PID=${BASHPID:-$$}
MY_IDENTITY=$(identity_of "$MY_PID")
MY_STARTED=$(date +%s)
MY_HOME=$(one_line "$FM_HOME")
MY_SEQ=
MY_ENTRY=
MY_ADMITTED=0

# The freshness bound for the cached host-pressure verdict, resolved ONCE here:
# two probe intervals, the same bound the heartbeat annotation uses. Resolving it
# per admission pass would re-fork the resolver every poll for no gain. This is a
# config read, not a probe, so it never samples the host afresh.
resolve_resource_bound() {
  local interval=$RESOURCE_INTERVAL_OVERRIDE
  if [ -z "$interval" ]; then
    interval=$("$SCRIPT_DIR/fm-resource-check.sh" --interval 2>/dev/null || printf '')
  fi
  case "$interval" in ''|*[!0-9]*) interval=900 ;; esac
  [ "$interval" -ge 1 ] || interval=900
  printf '%s\n' "$(( interval * 2 ))"
}
RESOURCE_STALE_BOUND=$(resolve_resource_bound)

# True (0) only when the watcher's CACHED verdict is a FRESH `critical`. Reads
# the published cache and never samples afresh, honouring the sustained-sampling
# rule. Fails OPEN - absent, unreadable, stale, or non-critical all return 1 - so
# a home with no resource monitor is never wedged by this guard.
host_under_sustained_critical() {
  local status age
  [ -f "$RESOURCE_STATUS_FILE" ] && [ -r "$RESOURCE_STATUS_FILE" ] || return 1
  status=$(cat "$RESOURCE_STATUS_FILE" 2>/dev/null || true)
  [ "$status" = critical ] || return 1
  [ "$RESOURCE_STALE_BOUND" -gt 0 ] || return 1
  age=$(fm_path_age "$RESOURCE_STATUS_FILE" 2>/dev/null || printf '%s' "$RESOURCE_STALE_BOUND")
  case "$age" in ''|*[!0-9]*) return 1 ;; esac
  [ "$age" -lt "$RESOURCE_STALE_BOUND" ] || return 1
  return 0
}

# --- register ---------------------------------------------------------------

ensure_queue

# Emit exactly one release nudge when THIS run held a slot and a waiter is still
# queued, so firstmate wakes a crewmate parked on `paused: awaiting test slot`.
# Firstmate is the nudger, never the granter: the waiter re-acquires through
# ordinary admission. Lock-free on purpose - it runs from the exit trap, where
# re-entering the admission lock could deadlock against a lock this same process
# still holds, and it only needs to know whether ANY waiting record exists, which
# a lockless scan answers well enough for a best-effort nudge. A failed enqueue
# is swallowed: a missed nudge only delays a retry the waiter's own poll already
# covers, and must never turn a clean command exit into a failure.
# shellcheck disable=SC2329 # Invoked indirectly by cleanup() from the traps.
release_nudge() {
  local f saw_waiter=0
  [ "$MY_ADMITTED" -eq 1 ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$f" = "$MY_ENTRY" ] && continue
    entry_read "$f" || continue
    if [ "$E_STATE" = waiting ]; then saw_waiter=1; break; fi
  done < <(entry_files)
  [ "$saw_waiter" -eq 1 ] || return 0
  fm_wake_append check heavy-run-slot-free \
    "check: heavy-run slot freed, a waiter may retry" 2>/dev/null || true
}

# shellcheck disable=SC2329 # Invoked indirectly by the traps below.
cleanup() {
  [ -n "$MY_ENTRY" ] && rm -f "$MY_ENTRY"
  lock_drop
  release_nudge
}
trap cleanup EXIT
# Until the command starts, a signalled requester should drop its own record
# immediately; the liveness reap below is the backstop for an unclean death.
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 129' HUP

lock_acquire || refuse "admission lock at $LOCK stayed busy for ${LOCK_MAX_WAIT}s"
seq_raw=$(cat "$SEQ_FILE" 2>/dev/null || echo 0)
case "$seq_raw" in ''|*[!0-9]*) seq_raw=0 ;; esac
MY_SEQ=$(( seq_raw + 1 ))
if ! printf '%s\n' "$MY_SEQ" > "$SEQ_FILE"; then
  lock_drop
  refuse "cannot record the queue sequence at $SEQ_FILE"
fi
MY_ENTRY=$(printf '%s/%012d.entry' "$QUEUE" "$MY_SEQ")
if ! entry_write "$MY_ENTRY" waiting; then
  MY_ENTRY=
  lock_drop
  refuse "cannot write the queue record in $QUEUE"
fi
lock_drop

# --- admission --------------------------------------------------------------
#
# Returns 0 once this run holds a slot. Under the lock: reap the dead, count the
# running, and admit only when a slot is free AND this record is the oldest
# waiter. WAIT_POSITION and WAIT_AHEAD are set for the queued notice.
WAIT_POSITION=0
WAIT_AHEAD=0
try_admit() {
  local f running=0 first_waiting='' pos=0 admitted=1
  lock_acquire || return 2
  reap_dead
  if [ ! -f "$MY_ENTRY" ]; then
    lock_drop
    return 3
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    entry_read "$f" || continue
    if [ "$E_STATE" = running ]; then
      running=$(( running + 1 ))
      continue
    fi
    pos=$(( pos + 1 ))
    [ -n "$first_waiting" ] || first_waiting=$f
    [ "$f" = "$MY_ENTRY" ] && WAIT_POSITION=$pos
  done < <(entry_files)
  WAIT_AHEAD=$running
  if [ "$running" -lt "$SLOTS" ] && [ "$first_waiting" = "$MY_ENTRY" ]; then
    # DELTA 4: a slot is free and this run is the oldest waiter, but do NOT start
    # new heavy work into a host the watcher already calls sustained-critical.
    # This reads the published cache only (no fresh sample) and fails open.
    if host_under_sustained_critical; then
      lock_drop
      refuse_pressure "host is under sustained critical pressure ($RESOURCE_STATUS_FILE); append 'paused: awaiting test slot' and retry when it recovers"
    fi
    if entry_write "$MY_ENTRY" running; then
      admitted=0
      MY_ADMITTED=1
    else
      lock_drop
      return 3
    fi
  fi
  lock_drop
  return "$admitted"
}

# Elapsed time comes from the clock, not from summing the poll interval, so a
# fractional FM_HEAVY_POLL stays valid.
waited=0
last_notice=0
notified=0
while :; do
  try_admit
  rc=$?
  case "$rc" in
    0) break ;;
    1) ;;
    2) refuse "admission lock at $LOCK stayed busy for ${LOCK_MAX_WAIT}s" ;;
    *) refuse "this run's queue record in $QUEUE vanished" ;;
  esac
  waited=$(( $(date +%s) - MY_STARTED ))
  if [ "$notified" -eq 0 ] || [ $(( waited - last_notice )) -ge "$NOTICE_EVERY" ]; then
    log "queued: position $WAIT_POSITION behind $WAIT_AHEAD running (ceiling $SLOTS, waited ${waited}s) - waiting, not hung"
    notified=1
    last_notice=$waited
  fi
  if [ "$MAX_WAIT" -gt 0 ] && [ "$waited" -ge "$MAX_WAIT" ]; then
    log "still queued after ${waited}s and --max-wait is ${MAX_WAIT}s"
    exit 75
  fi
  sleep "$POLL"
done

[ "$waited" -eq 0 ] || log "starting after ${waited}s queued"

# --- run --------------------------------------------------------------------
#
# The command runs as a child rather than exec'ing, for two reasons: this shell
# must survive to drop its lease, and a requester that is killed must take its
# suite down with it instead of orphaning a run that still holds a slot.
CHILD=
# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
forward() {
  local sig=$1
  [ -n "$CHILD" ] && kill -"$sig" "$CHILD" 2>/dev/null
  return 0
}
trap 'forward TERM' TERM
trap 'forward INT' INT
trap 'forward HUP' HUP

exec 9<&0
"$@" <&9 &
CHILD=$!
exec 9<&-

while :; do
  wait "$CHILD"
  rc=$?
  # A trap interrupts wait and returns 128+signal; re-wait for the real status.
  if [ "$rc" -gt 128 ] && kill -0 "$CHILD" 2>/dev/null; then
    continue
  fi
  break
done

exit "$rc"
