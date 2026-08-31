#!/usr/bin/env bash
# Safe, home-scoped (re-)arm of the firstmate watcher, with honest verification.
#
# The watcher (bin/fm-watch.sh) blocks until it has an actionable wake to
# surface, then prints one reason line and exits. While an away-mode daemon is
# actually live for this home the daemon owns triage and the watcher exits on
# every wake for the daemon to classify; away mode with no daemon leaves triage
# in the watcher. Reliability depends on arming through a mechanism that SURVIVES the
# call and NOTIFIES on exit, so firstmate must run this script as the harness's
# own tracked background task (e.g. run_in_background). Run it as its own
# standalone background task, never bundled onto the tail of another command.
# NEVER fire it and forget with a shell `&` inside another call: that backgrounded
# child is reaped when the call returns, leaving NO watcher running and a false
# "already running" off the dying process. That exact mistake silently took
# supervision down for ~30 minutes.
# On a harness with a PreToolUse-equivalent hook, bin/fm-arm-pretool-check.sh
# applies the command-position policy before the command runs; see
# docs/arm-pretool-check.md for the blessed tree and deny reason codes. It is a
# pre-execution seatbelt, not a substitute for the verification here.
#
# This script forks the watcher as a tracked child, then VERIFIES the outcome
# before it settles in. It confirms a watcher process is genuinely alive AND the
# liveness beacon (state/.last-watcher-beat) is fresh within FM_GUARD_GRACE (the
# single source of truth, shared with fm-watch.sh and fm-guard.sh), and prints
# exactly one unambiguous status line:
#   watcher: started pid=<N> (beacon fresh)              - it launched one and confirmed it
#   watcher: attached pid=<N> (beacon <age>s)            - a live+fresh successor holds the lock;
#                                                          this arm attaches and follows it
#   watcher: attached wake surfaced (queue seq A -> B)   - the followed watcher enqueued a new
#                                                          durable wake; this arm completes
#                                                          (exit 0, wake-shaped) so the harness
#                                                          re-drives the idle model, exactly like
#                                                          the started path's actionable exit
#   watcher: FAILED - no live watcher with a fresh beacon  - could not confirm one
#   watcher: FAILED - cycle ended without an actionable reason
#                                                        - a clean cycle ended with no wake and no
#                                                          verified healthy successor
# It NEVER reports started/attached/healthy off a stale beacon or a dead/reused pid: a
# stale-beacon or dead-pid holder either self-heals (the fresh child steals the
# dead lock per the singleton self-eviction/steal path and is confirmed) or this
# returns the FAILED line. On started it waits the child and propagates the wake
# reason; on attached it stays live across identity-matched successors. An
# attached cycle that ends without a healthy successor is a typed nonzero failure,
# never a clean empty completion. On FAILED it exits non-zero so the failure is
# loud. A live cycle already present means re-arm attaches - do not start a second
# watcher.
#
# A started child may also close with a "tick:" line: fm-watch.sh's env-gated
# (FM_WATCH_ABSORB_TICK) proof-of-life exit for a benign-absorbed wake. It is neither
# an actionable wake nor a failure - the line is printed and the cycle returns success
# without the empty-cycle FAILED path (see watch_output_is_tick, owned_child_finished).
#
# Every observed watcher cycle appends one tab-separated lifecycle record to
# state/.watch-cycle-exits.log. The arm layer owns that bounded ledger; it records
# arm/watcher identities, timestamps, exit/signal classification, beacon age,
# lock identity before and after close, and successor disposition. The separate
# state/.watch-triage.log remains exclusively the watcher's absorbed-wake debug
# log and is never written here.
#
# --restart: stop ONLY this FM_HOME's watcher (the pid recorded in THIS home's
# state/.watch.lock) and own a fresh cycle, or attach if a verified live peer
# wins the singleton while the duplicate child stands down. It
# resolves and signals exactly that pid, so it can never touch another home's
# watcher. NEVER `pkill -f
# bin/fm-watch.sh`: that pattern matches every firstmate home's watcher
# (secondmate homes run the same script) and would kill siblings.
#
# --converge: collapse a MULTI-watcher tangle for THIS home and leave exactly one
# owner. --restart can only stop the single pid recorded in the lock, so an
# orphan immediately re-grabs the lock and a single-pid restart can never
# converge a 4-watcher tangle. --converge enumerates every watcher AND every
# stale arm-loop for this home by ABSOLUTE-PATH cmdline match (bin/fm-watch-scope-lib.sh),
# kills the arm-loops FIRST (they are the re-attach engines that would restart a
# killed watcher and re-tangle), then the surplus watchers, keeping one genuinely
# healthy survivor when one exists, then falls through to arm exactly one owner.
# It mirrors --restart's TERM->grace->KILL escalation and, like --restart, only
# ever signals absolute-path-matched this-home pids, never a cross-home
# `pkill -f`. It is a manual/agent-invoked repair, wired into no automatic path.
#
# --drain: fold the mandatory pre-arm wake drain (bin/fm-wake-drain.sh) into this
# one invocation so one logical supervision step is a single call rather than a
# drain, an arm, and a forced re-arm each time a wake lands inside the arm's
# confirmation window on a busy fleet. It drains first, prints the drained
# records under a "=== WAKE QUEUE (drained) ===" header, then runs the unchanged
# arm (or --restart) logic, which still leaves exactly one live watcher. A drain
# failure is reported loudly on stderr but never aborts the arm, because an
# un-armed turn is the more dangerous outcome. --drain composes with --restart.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-watch-scope-lib.sh
. "$SCRIPT_DIR/fm-watch-scope-lib.sh"

WATCH="$SCRIPT_DIR/fm-watch.sh"
WATCH_LOCK="$STATE/.watch.lock"
BEAT="$STATE/.last-watcher-beat"
# "Fresh" reuses the guard's threshold so there is one definition of liveness.
GRACE=${FM_GUARD_GRACE:-900}
# How long to wait for a freshly forked watcher to acquire the lock and beat.
CONFIRM_TIMEOUT=${FM_ARM_CONFIRM_TIMEOUT:-10}
# Poll interval while attached to an existing healthy watcher.
ATTACH_POLL=${FM_ARM_ATTACH_POLL:-0.5}
CYCLE_LOG="$STATE/.watch-cycle-exits.log"
CYCLE_LOG_LOCK="$STATE/.watch-cycle-exits.lock"
CYCLE_LOG_MAX_BYTES=${FM_WATCH_CYCLE_LOG_MAX_BYTES:-262144}
CYCLE_LOG_KEEP_LINES=${FM_WATCH_CYCLE_LOG_KEEP_LINES:-1000}
ARM_PID=${BASHPID:-$$}
case "$CYCLE_LOG_MAX_BYTES" in ''|*[!0-9]*|0) CYCLE_LOG_MAX_BYTES=262144 ;; esac
case "$CYCLE_LOG_KEEP_LINES" in ''|*[!0-9]*|0) CYCLE_LOG_KEEP_LINES=1000 ;; esac

# The lifecycle ledger is diagnostic evidence, not a supervision dependency.
# Writes are bounded and best-effort so an observability failure cannot stall an
# otherwise healthy watcher cycle.
cycle_clean_field() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-512
}

lock_snapshot() {
  local pid identity
  pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  printf 'pid:%s|identity:%s' "$(cycle_clean_field "${pid:-none}")" "$(cycle_clean_field "${identity:-none}")"
}

cycle_active=0
cycle_watcher_pid=none
cycle_origin=unknown
cycle_started_at=0
cycle_lock_before='pid:none|identity:none'

cycle_begin() {
  cycle_watcher_pid=$1
  cycle_origin=$2
  cycle_started_at=$(date +%s)
  cycle_lock_before=$(lock_snapshot)
  cycle_active=1
}

cycle_refresh_lock_before() {
  [ "$cycle_active" -eq 1 ] || return 0
  cycle_lock_before=$(lock_snapshot)
}

cycle_signal_name() {
  local rc=$1 signal_number
  case "$rc" in
    ''|*[!0-9]*) printf 'unknown'; return ;;
  esac
  [ "$rc" -gt 128 ] || { printf 'none'; return; }
  signal_number=$((rc - 128))
  kill -l "$signal_number" 2>/dev/null || printf '%s' "$signal_number"
}

cycle_log_append() {
  local exit_code=$1 signal=$2 reason=$3 successor=$4 ended_at beacon_age lock_after size tmp raw i
  [ "$cycle_active" -eq 1 ] || return 0
  ended_at=$(date +%s)
  beacon_age=$(fm_path_age "$BEAT")
  lock_after=$(lock_snapshot)

  i=0
  while ! fm_lock_try_acquire "$CYCLE_LOG_LOCK"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  printf 'arm_pid=%s\twatcher_pid=%s\torigin=%s\tstarted_at=%s\tended_at=%s\texit_code=%s\tsignal=%s\treason=%s\tbeacon_age=%s\tlock_before=%s\tlock_after=%s\tsuccessor=%s\n' \
    "$ARM_PID" \
    "$(cycle_clean_field "$cycle_watcher_pid")" \
    "$(cycle_clean_field "$cycle_origin")" \
    "$cycle_started_at" \
    "$ended_at" \
    "$(cycle_clean_field "$exit_code")" \
    "$(cycle_clean_field "$signal")" \
    "$(cycle_clean_field "$reason")" \
    "$beacon_age" \
    "$(cycle_clean_field "$cycle_lock_before")" \
    "$(cycle_clean_field "$lock_after")" \
    "$(cycle_clean_field "$successor")" >> "$CYCLE_LOG" 2>/dev/null || true

  size=$(wc -c < "$CYCLE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$size" -ge "$CYCLE_LOG_MAX_BYTES" ]; then
        tmp="$CYCLE_LOG.tmp.$ARM_PID"
        raw="$tmp.raw"
        tail -n "$CYCLE_LOG_KEEP_LINES" "$CYCLE_LOG" 2>/dev/null \
          | tail -c "$CYCLE_LOG_MAX_BYTES" > "$raw" 2>/dev/null \
          && awk 'NR > 1 || /^arm_pid=/' "$raw" > "$tmp" 2>/dev/null \
          && mv -f "$tmp" "$CYCLE_LOG" 2>/dev/null
        rm -f "$tmp" "$raw" 2>/dev/null || true
      fi
      ;;
  esac
  fm_lock_release "$CYCLE_LOG_LOCK"
  cycle_active=0
}

# A persistent adapter passes the arm pid that just closed. Once this new arm
# verifies its watcher, update that predecessor's final record in place so the
# one-record-per-cycle ledger captures the actual successor outcome without an
# extra synthetic lifecycle row.
cycle_mark_predecessor_successor() {
  local successor=$1 predecessor=${FM_WATCH_PREDECESSOR_ARM_PID:-} i tmp
  case "$predecessor" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ -f "$CYCLE_LOG" ] || return 0
  i=0
  while ! fm_lock_try_acquire "$CYCLE_LOG_LOCK"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  tmp="$CYCLE_LOG.link.$ARM_PID"
  awk -v target="arm_pid=$predecessor" -v replacement="successor=$(cycle_clean_field "$successor")" '
    {
      lines[NR] = $0
      count = split($0, fields, "\t")
      if (fields[1] == target) {
        for (i = 1; i <= count; i += 1) {
          if (fields[i] == "successor=none") last = NR
        }
      }
    }
    END {
      for (i = 1; i <= NR; i += 1) {
        if (i == last) sub(/\tsuccessor=none$/, "\t" replacement, lines[i])
        print lines[i]
      }
    }
  ' "$CYCLE_LOG" > "$tmp" 2>/dev/null && mv -f "$tmp" "$CYCLE_LOG" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
  fm_lock_release "$CYCLE_LOG_LOCK"
}

clear_stale_recorded_watcher_lock() {
  local lock_home lock_path lock_identity
  lock_home=$(cat "$WATCH_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$WATCH_LOCK/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 0
  [ "$lock_path" = "$WATCH" ] || return 0
  [ -n "$lock_identity" ] || return 0
  fm_lock_remove_path "$WATCH_LOCK" || true
}

# A watcher is "healthy" iff the lock names a live process that is genuinely THIS
# home's watcher (the identity match guards against a recycled/reused pid) AND the
# liveness beacon is fresh within GRACE. Sets HEALTHY_PID on success. This is the
# single honesty gate: a dead pid, a reused pid, or a stale beacon all fail it, so
# this script can never report a watcher that is not really there.
HEALTHY_PID=
healthy_watcher() {
  HEALTHY_PID=
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" || return 1
  HEALTHY_PID=$FM_WATCHER_HEALTHY_PID
}

report_attached() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "watcher: attached pid=$HEALTHY_PID (beacon ${age}s)"
}

# Give a successor the same bounded confirmation window used for a fresh child.
# Adapter-owned continuations normally win immediately, but the bound avoids a
# false failure when process-close delivery and lock publication cross briefly.
wait_for_healthy_successor() {
  local deadline
  # date(1) exposes whole seconds. Add one rounding second so a timeout of one
  # second cannot collapse to a few milliseconds when called near a boundary.
  deadline=$(( $(date +%s) + CONFIRM_TIMEOUT + 1 ))
  while :; do
    healthy_watcher && return 0
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.2
  done
}

fail_unexplained_cycle() {
  echo "watcher: FAILED - cycle ended without an actionable reason"
  return 1
}

# Stay alive across identity-matched healthy holders, but COMPLETE (exit 0,
# wake-shaped) the instant the followed watcher enqueues a new durable wake. On a
# completion-wake harness (jcode/claude/grok) the background task's COMPLETION is
# what re-drives the idle model, so an attach path that only ever looped and
# exited on FAILURE left supervision healthy-looking but deaf: the followed
# watcher cycled and enqueued wakes, yet nothing re-drove the session. The fix
# mirrors the `started` exit by watching the monotonic wake-queue seq snapshotted
# at attach entry: the first new wake completes this arm, its caller drains the
# queue (which now holds the record) and re-arms, identical downstream handling to
# the started path's actionable-* exit.
#
# The seq (not the queue CONTENT) is the signal on purpose: reading queue content
# races the drain (a wake enqueued and drained between two polls would be missed
# and the arm would hang again), while the seq is drain-immune because
# fm-wake-drain.sh truncates the queue but never resets the seq. Worst case is one
# redundant wake-drive, never a missed one - the correct never-blind bias.
#
# If one cycle ends without a wake, attach to a verified successor. With no
# successor, fail loudly instead of returning a clean empty completion that an
# adapter could mistake for a no-op.
attach_and_wait() {
  local attached_pid=$1 attach_seq_baseline current_seq
  attach_seq_baseline=$(fm_wake_queue_seq)
  while :; do
    current_seq=$(fm_wake_queue_seq)
    if [ "$current_seq" -gt "$attach_seq_baseline" ]; then
      cycle_log_append 0 none attached-wake-surfaced "attached:$attached_pid"
      echo "watcher: attached wake surfaced (queue seq $attach_seq_baseline -> $current_seq)"
      exit 0
    fi
    if healthy_watcher; then
      if [ "$HEALTHY_PID" != "$attached_pid" ]; then
        cycle_log_append unknown unknown lock-replaced "attached:$HEALTHY_PID"
        attached_pid=$HEALTHY_PID
        cycle_begin "$attached_pid" attached
        report_attached
      fi
      sleep "$ATTACH_POLL"
      continue
    fi
    if wait_for_healthy_successor; then
      cycle_log_append unknown unknown attached-cycle-ended "attached:$HEALTHY_PID"
      attached_pid=$HEALTHY_PID
      cycle_begin "$attached_pid" attached
      report_attached
      continue
    fi
    cycle_log_append unknown unknown attached-cycle-ended none
    fail_unexplained_cycle
    return 1
  done
}

# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_attached_signal() {
  local signal=$1 rc=$2
  trap - HUP TERM INT
  cycle_log_append "$rc" "$signal" arm-interrupted none
  exit "$rc"
}

trap 'handle_attached_signal HUP 129' HUP
trap 'handle_attached_signal TERM 143' TERM
trap 'handle_attached_signal INT 130' INT

watch_output_has_wake() {
  local out=$1
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null
}

# A tick close is the env-gated proof-of-life exit (fm-watch.sh's absorb_tick, active
# only when FM_WATCH_ABSORB_TICK=1 on this home): a clean exit whose only reason line
# is "tick:". It proves the watcher absorbed a benign wake while alive; it is neither
# an actionable wake nor a failure, so it is classified separately and returns success
# without the empty-cycle FAILED path. The tick line is still printed, so the harness
# surfaces it to the session (the standing "tick" reply). No durable wake record
# exists, so the wake drain finds nothing and the model just re-arms as usual.
watch_output_is_tick() {
  local out=$1
  ! watch_output_has_wake "$out" && grep -Eq '^tick:' "$out" 2>/dev/null
}

watch_output_reason_type() {
  local out=$1 line
  line=$(grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null | head -1 || true)
  case "$line" in
    signal:*) printf 'actionable-signal' ;;
    stale:*) printf 'actionable-stale' ;;
    check:*) printf 'actionable-check' ;;
    heartbeat*) printf 'actionable-heartbeat' ;;
    *) printf 'none' ;;
  esac
}

print_watch_output() {
  local out=$1
  [ -s "$out" ] && cat "$out"
}

mode=arm
drain_first=0
for arg in "$@"; do
  case "$arg" in
    ''|arm|--arm) mode=arm ;;
    --restart) mode=restart ;;
    --converge) mode=converge ;;
    --drain) drain_first=1 ;;
    *) echo "usage: $(basename "$0") [--drain] [--restart|--converge]" >&2; exit 2 ;;
  esac
done

# Signal one this-home pid down with the same TERM->grace->KILL escalation
# --restart uses, so a wedged watcher/arm that ignores TERM is still collapsed.
# Every pid passed here is already absolute-path scoped to this home by the
# caller (fm_home_watcher_pids / fm_home_arm_pids), so this never reaches a
# sibling home. Best-effort: a pid that dies on its own between enumeration and
# here is a success, not an error.
converge_signal_down() {
  local pid=$1 i
  fm_pid_alive "$pid" || return 0
  kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 50 ] && fm_pid_alive "$pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  if fm_pid_alive "$pid"; then
    kill -KILL "$pid" 2>/dev/null || true
    i=0
    while [ "$i" -lt 50 ] && fm_pid_alive "$pid"; do
      sleep 0.1
      i=$((i + 1))
    done
  fi
}

# Collapse a multi-watcher tangle for THIS home, then fall through to the normal
# arm logic (which arms exactly one owner). Enumeration is absolute-path scoped,
# so a sibling home or secondmate is never touched.
#
# Kill ORDERING is the safety-critical subtlety: arm-loops must die FIRST. An arm
# loop whose followed watcher you kill immediately starts a replacement (the
# started path) and re-tangles, so leaving even one arm-loop alive while killing
# watchers defeats the convergence. So: kill every this-home arm-loop (excluding
# self), then every surplus watcher, keeping one genuinely healthy survivor when
# one exists so an in-flight cycle is not needlessly torn down.
converge_tangle() {
  local survivor='' pid armpid watcher_pids arm_pids
  # Pick the healthy survivor BEFORE any kill so a genuinely healthy watcher keeps
  # its cycle. healthy_watcher sets HEALTHY_PID via the shared honesty gate.
  if healthy_watcher; then
    survivor=$HEALTHY_PID
  fi

  # 1. Kill every this-home arm-loop except this converging process itself. They
  #    are the re-attach engines; all must die or the tangle rebuilds.
  arm_pids=$(fm_home_arm_pids "$SCRIPT_DIR" "$ARM_PID")
  for armpid in $arm_pids; do
    [ "$armpid" = "$ARM_PID" ] && continue
    converge_signal_down "$armpid"
  done

  # 2. Kill every this-home watcher except the chosen survivor.
  watcher_pids=$(fm_home_watcher_pids "$SCRIPT_DIR")
  for pid in $watcher_pids; do
    [ -n "$survivor" ] && [ "$pid" = "$survivor" ] && continue
    converge_signal_down "$pid"
  done

  # 3. If no healthy survivor remains, clear a dangling this-home lock so the arm
  #    below starts a fresh watcher instead of seeing a dead-pid holder.
  if [ -z "$survivor" ] || ! fm_pid_alive "$survivor"; then
    clear_stale_recorded_watcher_lock
  fi

  echo "watcher: converge collapsed tangle for this home; arming one owner"
}


# --drain folds the mandatory pre-arm wake drain into this one invocation, so a
# single logical supervision step is one call instead of a drain, an arm, and a
# forced re-arm each time a wake lands inside the arm's confirmation window on a
# busy fleet. It shells out to bin/fm-wake-drain.sh, the single owner of the
# drain (and of the liveness assertion it makes afterward), then proceeds into
# the unchanged arm logic below, which still leaves exactly one live watcher.
# The drain runs BEFORE this arm forks its child, so its records print first and
# are never confused with the arm's own status line. A drain failure is loud but
# must not abort the arm: an un-armed turn is the more dangerous outcome, so the
# drain's exit status is surfaced in the printed marker and the arm still runs.
if [ "$drain_first" -eq 1 ]; then
  echo "=== WAKE QUEUE (drained) ==="
  drain_status=0
  "$SCRIPT_DIR/fm-wake-drain.sh" || drain_status=$?
  if [ "$drain_status" -ne 0 ]; then
    echo "watch-arm: DRAIN FAILED (exit $drain_status) - queue may still hold wakes; arming anyway" >&2
  fi
  echo "=== ARM ==="
fi

if [ "$mode" = restart ]; then
  # Home-scoped stop: only the watcher pid recorded in THIS home's lock.
  lock_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  if fm_pid_alive "$lock_pid"; then
    if fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$lock_pid" "$FM_HOME"; then
      kill -TERM "$lock_pid" 2>/dev/null || true
      # Wait for it to actually exit before relaunching, so the fresh watcher
      # either takes a released lock or reclaims a now-dead-pid stale lock instead
      # of seeing the dying one as a live holder and no-opping. The watcher now
      # waits on a backgrounded sleep child, so SIGTERM interrupts its terminal
      # wait and runs its cleanup trap right away; this bound is normally
      # satisfied in well under a second.
      i=0
      while [ "$i" -lt 50 ] && fm_pid_alive "$lock_pid"; do
        sleep 0.1
        i=$((i + 1))
      done
      if fm_pid_alive "$lock_pid" && [ "$(fm_path_age "$BEAT")" -ge "$GRACE" ]; then
        # SIGTERM did not land and the beacon is stale past the grace: this is a
        # genuinely wedged watcher (e.g. stuck mid-syscall, or a machine that just
        # resumed from suspend), not a healthy-but-TERM-resistant peer, so force it
        # down. SIGKILL is untrappable, so the watcher's EXIT trap never runs and
        # would otherwise strand state/.watch.lock and block every future re-arm;
        # clear the lock here so a forced termination never leaves it dangling. A
        # healthy peer (fresh beacon) is left alone - the fresh child no-ops on its
        # held lock and the arm attaches to it below.
        kill -KILL "$lock_pid" 2>/dev/null || true
        i=0
        while [ "$i" -lt 50 ] && fm_pid_alive "$lock_pid"; do
          sleep 0.1
          i=$((i + 1))
        done
        clear_stale_recorded_watcher_lock
      fi
    else
      clear_stale_recorded_watcher_lock
    fi
  fi
fi

if [ "$mode" = converge ]; then
  # Collapse this home's watcher/arm-loop tangle, then behave exactly like a
  # normal arm: attach to the healthy survivor if one remains, else start one
  # fresh watcher. Leaving mode=converge would skip the attach branch below and
  # start a second watcher behind a healthy survivor, so switch to arm here.
  converge_tangle
  mode=arm
fi

# If a genuinely live+fresh watcher already holds the lock, do not start a second
# one - attach to that cycle and wait until it ends so the harness notify fires
# then, not as an immediate empty wake. (--restart skips this: it just stopped
# this home's watcher and wants a fresh one.)
if [ "$mode" = arm ] && healthy_watcher; then
  cycle_mark_predecessor_successor "attached:$HEALTHY_PID"
  cycle_begin "$HEALTHY_PID" attached
  report_attached
  attach_and_wait "$HEALTHY_PID"
  exit $?
fi

# Start a watcher as a tracked child and confirm it before settling in. The child
# stays our child for its whole life: we wait on it, so killing this arm (the
# harness-tracked task) tears the watcher down too, and the watcher's eventual
# wake exit propagates out so the harness re-notifies firstmate.
child=
child_out=
cleanup_child() {
  if [ -n "$child" ] && fm_pid_alive "$child"; then
    kill -TERM "$child" 2>/dev/null || true
  fi
  if [ -n "$child_out" ]; then
    rm -f "$child_out" 2>/dev/null || true
  fi
}

# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_arm_signal() {
  local signal=$1 rc=$2
  trap - HUP TERM INT
  if [ -n "$child" ] && fm_pid_alive "$child"; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
  cycle_log_append "$rc" "$signal" arm-interrupted none
  cleanup_child
  exit "$rc"
}

trap 'handle_arm_signal HUP 129' HUP
trap 'handle_arm_signal TERM 143' TERM
trap 'handle_arm_signal INT 130' INT

child_out=$(mktemp "$STATE/.watch-arm-output.XXXXXX") || {
  echo "watcher: FAILED - no live watcher with a fresh beacon"
  exit 1
}
"$WATCH" >"$child_out" &
child=$!
cycle_begin "$child" started
child_done=0

owned_child_finished() {
  local rc=$1 signal reason_type status
  signal=$(cycle_signal_name "$rc")
  if [ "$rc" -eq 0 ] && watch_output_is_tick "$child_out"; then
    # Proof-of-life tick: a benign-absorbed wake, not an actionable wake and not a
    # failure. Print it so the session sees it, record it, and return success.
    cycle_log_append "$rc" "$signal" tick none
    print_watch_output "$child_out"
    rm -f "$child_out" 2>/dev/null || true
    child=
    child_out=
    return 0
  fi
  if [ "$rc" -eq 0 ] && watch_output_has_wake "$child_out"; then
    reason_type=$(watch_output_reason_type "$child_out")
    cycle_log_append "$rc" "$signal" "$reason_type" none
    print_watch_output "$child_out"
    rm -f "$child_out" 2>/dev/null || true
    child=
    child_out=
    return 0
  fi

  if [ "$rc" -eq 0 ]; then
    if wait_for_healthy_successor; then
      cycle_log_append "$rc" "$signal" unexpected-clean-exit "attached:$HEALTHY_PID"
      print_watch_output "$child_out"
      rm -f "$child_out" 2>/dev/null || true
      child=
      child_out=
      cycle_mark_predecessor_successor "attached:$HEALTHY_PID"
      report_attached
      cycle_begin "$HEALTHY_PID" attached
      attach_and_wait "$HEALTHY_PID"
      return $?
    fi
    cycle_log_append "$rc" "$signal" unexpected-clean-exit none
    print_watch_output "$child_out"
    rm -f "$child_out" 2>/dev/null || true
    child=
    child_out=
    fail_unexplained_cycle
    return 1
  fi

  reason_type="nonzero-exit"
  [ "$signal" = none ] || reason_type="signal-exit"
  cycle_log_append "$rc" "$signal" "$reason_type" none
  print_watch_output "$child_out"
  if ! grep -q '^watcher: FAILED' "$child_out" 2>/dev/null; then
    echo "watcher: FAILED - watcher cycle exited $rc without an actionable reason"
  fi
  rm -f "$child_out" 2>/dev/null || true
  child=
  child_out=
  status=$rc
  [ "$status" -gt 0 ] || status=1
  return "$status"
}

# Verify the outcome: poll until this child is the confirmed healthy watcher, or
# until some other watcher legitimately holds the singleton (a startup race), or
# until the child gives up. Only then print the honest line.
# date(1) exposes whole seconds. Keep the configured confirmation budget from
# collapsing when startup begins just before the next second boundary.
deadline=$(( $(date +%s) + CONFIRM_TIMEOUT + 1 ))
while :; do
  if healthy_watcher; then
    if [ "$HEALTHY_PID" = "$child" ]; then
      cycle_refresh_lock_before
      cycle_mark_predecessor_successor "started:$child"
      echo "watcher: started pid=$child (beacon fresh)"
      wait "$child"
      rc=$?
      owned_child_finished "$rc"
      exit $?
    fi
    # Another watcher won the singleton; our child stood down.
    wait "$child"
    rc=$?
    owned_child_finished "$rc"
    exit $?
  fi
  if [ "$child_done" -eq 0 ] && ! fm_pid_alive "$child"; then
    wait "$child"
    rc=$?
    child_done=1
    owned_child_finished "$rc"
    exit $?
  fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.2
done

trap - HUP TERM INT
print_watch_output "$child_out"
cleanup_child
wait "$child" 2>/dev/null
rc=$?
cycle_log_append "$rc" "$(cycle_signal_name "$rc")" confirmation-timeout none
echo "watcher: FAILED - no live watcher with a fresh beacon"
exit 1
