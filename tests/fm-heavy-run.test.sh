#!/usr/bin/env bash
# Behavior tests for bin/fm-heavy-run.sh, the fleet's heavy-run serialization
# point.
#
# The load these tests place on the host is deliberately tiny (short `sleep`s,
# no suites), because the failure this script exists to prevent is exactly a
# host thrashing under concurrent suite runs.
#
# The concurrency proofs are paired on purpose: serialization at ceiling 1 is
# only meaningful next to observed overlap at ceiling 2, otherwise a runner that
# never runs anything concurrently would pass the serialization test vacuously.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-heavy-run)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
QUEUE="$HOME_DIR/state/heavy-runs/q"
HR="$ROOT/bin/fm-heavy-run.sh"

export FM_STATE_OVERRIDE="$HOME_DIR/state"
export FM_CONFIG_OVERRIDE="$HOME_DIR/config"
# The default ledger is now host-global (DELTA 2); pin it to this home's own dir
# so the suite is isolated from the real /tmp ledger and $QUEUE stays accurate.
# The one test that exercises the host-global default overrides this with env -u.
export FM_HEAVY_RUN_DIR="$HOME_DIR/state/heavy-runs"
# Poll fast and notice often so waiting states are observable within a test.
export FM_HEAVY_POLL=0.2
export FM_HEAVY_NOTICE=1

# Processes started by a test must never outlive it, or a later test inherits a
# held slot.
STRAYS=()
heavy_cleanup() {
  local pid
  for pid in "${STRAYS[@]:-}"; do
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
  done
  fm_test_cleanup
}
trap heavy_cleanup EXIT

# --- helpers ----------------------------------------------------------------

status_field() {  # <key>
  "$HR" --status 2>/dev/null | awk -F= -v k="$1" '$1 == k { print $2; exit }'
}

# wait_status <key> <value> <seconds>: poll --status until the field matches.
wait_status() {
  local key=$1 want=$2 limit=$3 i=0
  while [ "$i" -lt "$((limit * 10))" ]; do
    [ "$(status_field "$key")" = "$want" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# wait_pid_gone <pid> <seconds>
wait_pid_gone() {
  local pid=$1 limit=$2 i=0
  while [ "$i" -lt "$((limit * 10))" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

reset_queue() {
  rm -rf "$HOME_DIR/state/heavy-runs"
  rm -f "$HOME_DIR/config/heavy-run-slots"
  unset FM_HEAVY_SLOTS
}

# --- contract ---------------------------------------------------------------

test_script_parses() {
  local out rc
  out=$(bash -n "$HR" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-heavy-run.sh must parse cleanly (got: $out)"
  pass "fm-heavy-run.sh: bash -n succeeds"
}

test_help_includes_entire_header() {
  local help
  help=$("$HR" --help)
  assert_contains "$help" "WHY IT IS NOT THE RESOURCE GUARD." "--help lost the design rationale"
  assert_contains "$help" "this header owns the mechanism." "--help truncated before the header's last line"
  pass "fm-heavy-run.sh: --help renders the complete header"
}

test_usage_error_runs_nothing() {
  local marker out rc
  reset_queue
  marker="$TMP_ROOT/never"
  out=$("$HR" --max-wait 2>&1); rc=$?
  expect_code 64 "$rc" "a flag with no value must be a usage error"
  out=$("$HR" 2>&1); rc=$?
  expect_code 64 "$rc" "no command must be a usage error"
  assert_contains "$out" "no command given" "the usage error must say what was missing"
  out=$("$HR" --status -- touch "$marker" 2>&1); rc=$?
  expect_code 64 "$rc" "--status with a command must be a usage error"
  assert_absent "$marker" "a usage error must never run the command"
  pass "fm-heavy-run.sh: usage errors exit 64 and run nothing"
}

test_passes_through_output_and_status() {
  local out rc
  reset_queue
  out=$("$HR" -- sh -c 'echo to-stdout; echo to-stderr >&2; exit 7' 2>&1); rc=$?
  expect_code 7 "$rc" "the requester must receive the command's real exit status"
  assert_contains "$out" "to-stdout" "the command's stdout must reach the requester"
  assert_contains "$out" "to-stderr" "the command's stderr must reach the requester"
  pass "fm-heavy-run.sh: the requester gets the run's real output and exit status"
}

# --- the ceiling ------------------------------------------------------------

# Both jobs append start/end markers to one trace file. At ceiling 1 the trace
# must be two complete, non-overlapping runs.
run_trace_pair() {  # <trace-file>
  local trace=$1
  : > "$trace"
  "$HR" --task alpha -- sh -c "echo start-alpha >> '$trace'; sleep 2; echo end-alpha >> '$trace'" &
  local a=$!
  "$HR" --task beta -- sh -c "echo start-beta >> '$trace'; sleep 2; echo end-beta >> '$trace'" &
  local b=$!
  wait "$a"
  wait "$b"
}

test_ceiling_one_serializes() {
  local trace first second
  reset_queue
  printf '1\n' > "$HOME_DIR/config/heavy-run-slots"
  trace="$TMP_ROOT/trace-serial"
  run_trace_pair "$trace"
  [ "$(grep -c . "$trace")" -eq 4 ] || fail "expected 4 trace lines, got: $(cat "$trace")"
  first=$(sed -n '1p' "$trace"); second=$(sed -n '2p' "$trace")
  [ "start-${second#end-}" = "$first" ] \
    || fail "ceiling 1 must not interleave runs; trace was:"$'\n'"$(cat "$trace")"
  first=$(sed -n '3p' "$trace"); second=$(sed -n '4p' "$trace")
  [ "start-${second#end-}" = "$first" ] \
    || fail "ceiling 1 must not interleave runs; trace was:"$'\n'"$(cat "$trace")"
  pass "fm-heavy-run.sh: two simultaneous requests serialize at ceiling 1"
}

test_ceiling_two_overlaps() {
  local trace
  reset_queue
  printf '2\n' > "$HOME_DIR/config/heavy-run-slots"
  trace="$TMP_ROOT/trace-parallel"
  run_trace_pair "$trace"
  case "$(sed -n '1p' "$trace")$(sed -n '2p' "$trace")" in
    start-*start-*) : ;;
    *) fail "ceiling 2 must let both runs start; trace was:"$'\n'"$(cat "$trace")" ;;
  esac
  pass "fm-heavy-run.sh: the ceiling is a real knob - at 2 both runs overlap"
}

test_malformed_ceiling_falls_back_to_one() {
  local out
  reset_queue
  printf 'lots\n' > "$HOME_DIR/config/heavy-run-slots"
  out=$("$HR" --slots 2>&1)
  assert_contains "$out" "malformed heavy-run ceiling" "a malformed ceiling must warn"
  [ "$("$HR" --slots 2>/dev/null)" = 1 ] || fail "a malformed ceiling must fall back to 1, not to a permissive value"
  printf '0\n' > "$HOME_DIR/config/heavy-run-slots"
  [ "$("$HR" --slots 2>/dev/null)" = 1 ] || fail "a below-floor ceiling must fall back to 1"
  pass "fm-heavy-run.sh: an unusable ceiling falls back to the safest value"
}

# --- queue visibility -------------------------------------------------------

test_status_shows_queue_depth_and_order() {
  local holder first second status
  reset_queue
  printf '1\n' > "$HOME_DIR/config/heavy-run-slots"
  "$HR" --task holder --label suite -- sleep 4 & holder=$!
  STRAYS+=("$holder")
  wait_status running 1 10 || fail "the holding run never showed as running"
  "$HR" --task first -- true & first=$!
  STRAYS+=("$first")
  wait_status waiting 1 10 || fail "the first waiter never showed as waiting"
  "$HR" --task second -- true & second=$!
  STRAYS+=("$second")
  wait_status waiting 2 10 || fail "the second waiter never showed as waiting"

  status=$("$HR" --status)
  assert_contains "$status" "ceiling=1" "--status must report the ceiling"
  assert_contains "$status" "task=holder" "--status must name the running task"
  assert_contains "$status" "label=suite" "--status must carry the run's label"
  assert_contains "$status" "task=first position=1" "the earlier waiter must hold queue position 1"
  assert_contains "$status" "task=second position=2" "the later waiter must queue behind it"

  wait "$holder"; wait "$first"; wait "$second"
  pass "fm-heavy-run.sh: --status shows the ceiling, the running run, and ordered queue depth"
}

test_waiter_reports_that_it_is_queued() {
  local holder out
  reset_queue
  printf '1\n' > "$HOME_DIR/config/heavy-run-slots"
  "$HR" --task holder -- sleep 3 & holder=$!
  STRAYS+=("$holder")
  wait_status running 1 10 || fail "the holding run never showed as running"
  out=$("$HR" --task waiter -- true 2>&1)
  assert_contains "$out" "queued: position 1" "a queued requester must say it is queued"
  assert_contains "$out" "waiting, not hung" "a queued requester must distinguish itself from a hang"
  wait "$holder"
  pass "fm-heavy-run.sh: a waiting requester reports that it is queued, not hung"
}

test_max_wait_refuses_without_running() {
  local holder marker rc out
  reset_queue
  printf '1\n' > "$HOME_DIR/config/heavy-run-slots"
  marker="$TMP_ROOT/max-wait-ran"
  "$HR" --task holder -- sleep 5 & holder=$!
  STRAYS+=("$holder")
  wait_status running 1 10 || fail "the holding run never showed as running"
  out=$("$HR" --max-wait 1 -- touch "$marker" 2>&1); rc=$?
  expect_code 75 "$rc" "an exceeded --max-wait must refuse with its own status"
  assert_absent "$marker" "an exceeded --max-wait must never run the command unserialized"
  assert_contains "$out" "--max-wait is 1s" "the refusal must name the limit it hit"
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null || true
  pass "fm-heavy-run.sh: --max-wait refuses rather than running unserialized"
}

# --- death and wedge safety -------------------------------------------------

write_record() {  # <seq> <pid> <identity> <state>
  mkdir -p "$QUEUE"
  {
    printf 'seq=%s\n' "$1"
    printf 'pid=%s\n' "$2"
    printf 'identity=%s\n' "$3"
    printf 'state=%s\n' "$4"
    printf 'started=%s\n' "$(date +%s)"
    printf 'task=%s\n' fixture
    printf 'label=-\n'
    printf 'cmd=fixture\n'
  } > "$(printf '%s/%012d.entry' "$QUEUE" "$1")"
}

test_dead_holder_does_not_wedge_the_queue() {
  local dead rc
  reset_queue
  printf '1\n' > "$HOME_DIR/config/heavy-run-slots"
  sh -c 'exit 0' & dead=$!
  wait "$dead" 2>/dev/null || true
  write_record 1 "$dead" "dead-holder-identity" running
  "$HR" --max-wait 5 -- true; rc=$?
  expect_code 0 "$rc" "a slot held by a dead process must be reclaimed, not wedged"
  assert_absent "$(printf '%s/%012d.entry' "$QUEUE" 1)" "the dead holder's record must be removed"
  pass "fm-heavy-run.sh: a run whose owner died frees its slot"
}

test_reap_removes_the_record_but_never_the_process() {
  local victim rc
  reset_queue
  printf '1\n' > "$HOME_DIR/config/heavy-run-slots"
  # A live process this script does not own, recorded under a stale identity -
  # exactly the PID-reuse case. The record must go; the process must not.
  sleep 20 & victim=$!
  STRAYS+=("$victim")
  write_record 1 "$victim" "identity-of-some-long-gone-process" running
  "$HR" --max-wait 5 -- true; rc=$?
  expect_code 0 "$rc" "a record whose PID was reused must not hold a slot"
  assert_absent "$(printf '%s/%012d.entry' "$QUEUE" 1)" "the stale record must be removed"
  kill -0 "$victim" 2>/dev/null || fail "reaping a record must never signal the process it names"
  kill "$victim" 2>/dev/null
  wait "$victim" 2>/dev/null || true
  pass "fm-heavy-run.sh: reaping removes the record only, never the process behind it"
}

test_killed_waiter_does_not_wedge_the_queue() {
  local holder waiter marker rc
  reset_queue
  printf '1\n' > "$HOME_DIR/config/heavy-run-slots"
  marker="$TMP_ROOT/killed-waiter-ran"
  "$HR" --task holder -- sleep 3 & holder=$!
  STRAYS+=("$holder")
  wait_status running 1 10 || fail "the holding run never showed as running"
  "$HR" --task doomed -- touch "$marker" & waiter=$!
  STRAYS+=("$waiter")
  wait_status waiting 1 10 || fail "the doomed waiter never showed as waiting"
  # SIGKILL leaves no chance to clean up, so only the liveness reap can free it.
  # Nothing inspects the queue between here and the next run, so that reap is
  # what the following request depends on.
  kill -9 "$waiter" 2>/dev/null
  wait_pid_gone "$waiter" 5 || fail "the doomed waiter did not die"
  "$HR" --task after --max-wait 15 -- true; rc=$?
  expect_code 0 "$rc" "a queue entry left by a killed waiter must not wedge later runs"
  assert_absent "$marker" "a killed waiter's command must never run later on its behalf"
  wait "$holder" 2>/dev/null || true
  [ "$(status_field waiting)" = 0 ] || fail "the killed waiter's record must be gone"
  pass "fm-heavy-run.sh: a crewmate killed while queued does not wedge the queue"
}

test_killed_requester_does_not_orphan_its_run() {
  local requester child rc
  reset_queue
  printf '1\n' > "$HOME_DIR/config/heavy-run-slots"
  "$HR" --task orphan-check -- sleep 30 & requester=$!
  STRAYS+=("$requester")
  wait_status running 1 10 || fail "the run never started"
  child=$(pgrep -P "$requester" 2>/dev/null | head -n 1)
  [ -n "$child" ] || fail "could not find the run's child process"
  kill -TERM "$requester" 2>/dev/null
  wait_pid_gone "$requester" 10 || fail "the requester ignored TERM"
  wait_pid_gone "$child" 10 || fail "a terminated requester must take its run down, not orphan it"
  wait_status running 0 10 || fail "the terminated requester's slot was never freed"
  "$HR" --max-wait 5 -- true; rc=$?
  expect_code 0 "$rc" "the freed slot must be usable again"
  pass "fm-heavy-run.sh: a terminated requester takes its run down and frees its slot"
}

# --- DELTA 2: host-global ledger and home attribution -----------------------

test_default_ledger_is_host_global_not_per_home() {
  # With FM_HEAVY_RUN_DIR unset, the queue must NOT live under this home's state,
  # because a per-home queue multiplies slots across homes and defeats the cap.
  local out global
  reset_queue
  global="$TMP_ROOT/global-ledger"
  rm -rf "$global"
  # Point the host-global default at a temp dir via TMPDIR, and drop the per-home
  # override so the default path is exercised.
  out=$(env -u FM_HEAVY_RUN_DIR -u FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    TMPDIR="$global" HOME="$HOME_DIR" "$HR" --status 2>/dev/null)
  assert_contains "$out" "ceiling=" "--status must work against the host-global default"
  [ -d "$global/fm-heavy-runs-$(id -u)/q" ] \
    || fail "the default ledger must live at the host-global \$TMPDIR/fm-heavy-runs-<uid>, not under a home"
  pass "fm-heavy-run.sh: the default ledger is host-global, not per-home"
}

test_record_carries_home_attribution() {
  local holder status
  reset_queue
  printf '1\n' > "$HOME_DIR/config/heavy-run-slots"
  FM_HOME="$HOME_DIR" "$HR" --task attributed -- sleep 4 & holder=$!
  STRAYS+=("$holder")
  wait_status running 1 10 || fail "the holding run never showed as running"
  status=$("$HR" --status)
  assert_contains "$status" "home=$HOME_DIR" "--status must attribute a running record to its home"
  assert_contains "$status" "task=attributed" "--status must still name the task"
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null || true
  pass "fm-heavy-run.sh: a lease record carries its owning home for attribution"
}

test_slots_pointer_overrides_local_ceiling() {
  # FM_HEAVY_SLOTS_FILE (the authoritative/primary ceiling) must win over this
  # home's own config, so homes sharing the host-global ledger share one cap.
  local primary
  reset_queue
  primary="$TMP_ROOT/primary-heavy-run-slots"
  printf '1\n' > "$HOME_DIR/config/heavy-run-slots"
  printf '3\n' > "$primary"
  [ "$(FM_HEAVY_SLOTS_FILE="$primary" "$HR" --slots 2>/dev/null)" = 3 ] \
    || fail "the authoritative ceiling pointer must override the local config"
  # An unreadable/missing pointer falls back to the local config, never failing.
  [ "$(FM_HEAVY_SLOTS_FILE="$TMP_ROOT/nonexistent" "$HR" --slots 2>/dev/null)" = 1 ] \
    || fail "a missing ceiling pointer must fall back to the local config"
  pass "fm-heavy-run.sh: the authoritative ceiling pointer wins, and falls back safely"
}

# --- DELTA 3: release-wake nudge --------------------------------------------

test_release_emits_a_nudge_when_a_waiter_is_queued() {
  # A slot-holder that exits while a waiter is still queued must enqueue exactly
  # one check wake, so firstmate nudges a crewmate parked on 'awaiting test slot'.
  local queue_file holder waiter before after
  reset_queue
  export FM_HEAVY_RUN_DIR="$HOME_DIR/state/heavy-runs"
  printf '1\n' > "$HOME_DIR/config/heavy-run-slots"
  queue_file="$HOME_DIR/state/.wake-queue"
  rm -f "$queue_file"
  "$HR" --task nudge-holder -- sleep 2 & holder=$!
  STRAYS+=("$holder")
  wait_status running 1 10 || fail "the holding run never showed as running"
  # A waiter that stays queued THROUGH the holder's exit: its record is present
  # at the moment the holder releases, which is what triggers the nudge. It is
  # then admitted and runs to completion.
  "$HR" --task nudge-waiter --max-wait 20 -- true & waiter=$!
  STRAYS+=("$waiter")
  wait_status waiting 1 10 || fail "the waiter never showed as queued"
  before=$(grep -c 'heavy-run-slot-free' "$queue_file" 2>/dev/null || printf '0')
  wait "$holder" 2>/dev/null || true
  wait "$waiter" 2>/dev/null || true
  after=$(grep -c 'heavy-run-slot-free' "$queue_file" 2>/dev/null || printf '0')
  [ "$after" -gt "$before" ] \
    || fail "releasing a slot with a waiter queued must enqueue a heavy-run-slot-free check wake"
  pass "fm-heavy-run.sh: slot release nudges a queued waiter with a check wake"
}

test_release_emits_no_nudge_with_no_waiter() {
  # A lone run that never had a waiter must not spam the wake queue on exit.
  local queue_file count
  reset_queue
  printf '1\n' > "$HOME_DIR/config/heavy-run-slots"
  queue_file="$HOME_DIR/state/.wake-queue"
  rm -f "$queue_file"
  "$HR" --task lonely -- true
  count=$(grep -c 'heavy-run-slot-free' "$queue_file" 2>/dev/null || printf '0')
  [ "$count" -eq 0 ] \
    || fail "a run with no waiter behind it must not enqueue a release nudge"
  pass "fm-heavy-run.sh: no waiter means no release nudge"
}

# --- DELTA 4: cached-critical guard -----------------------------------------

test_free_slot_refused_under_sustained_critical() {
  # A free slot must NOT be granted when the watcher's cached verdict is a fresh
  # 'critical'. The guard reads the published cache; it never samples afresh.
  local marker rc out
  reset_queue
  printf '2\n' > "$HOME_DIR/config/heavy-run-slots"
  marker="$TMP_ROOT/critical-ran"
  printf 'critical\n' > "$HOME_DIR/state/.resource-status"
  out=$("$HR" --task under-pressure -- touch "$marker" 2>&1); rc=$?
  expect_code 76 "$rc" "a fresh critical verdict must refuse a free slot with its own status"
  assert_absent "$marker" "a critical refusal must never run the command"
  assert_contains "$out" "sustained critical pressure" "the refusal must name the pressure"
  pass "fm-heavy-run.sh: a free slot is refused under sustained critical pressure"
}

test_pressure_guard_fails_open_when_status_absent_or_stale() {
  # No cached verdict, or a stale one, must let admission proceed: a home with no
  # resource monitor is never wedged by the guard.
  local rc marker
  reset_queue
  printf '2\n' > "$HOME_DIR/config/heavy-run-slots"
  rm -f "$HOME_DIR/state/.resource-status"
  "$HR" --task no-monitor -- true; rc=$?
  expect_code 0 "$rc" "an absent resource verdict must fail open, not refuse"
  # A critical verdict older than the freshness bound (2 * interval) must be
  # ignored. Force interval 1 so the bound is 2s, write critical, then age it
  # past 2s before the run, so the guard sees it as stale and fails open.
  marker="$TMP_ROOT/stale-critical-ran"
  printf 'critical\n' > "$HOME_DIR/state/.resource-status"
  sleep 3
  FM_HEAVY_RESOURCE_INTERVAL=1 "$HR" --task stale-crit -- touch "$marker"; rc=$?
  expect_code 0 "$rc" "a stale critical verdict must fail open, not refuse"
  assert_present "$marker" "a stale critical verdict must let the command run"
  pass "fm-heavy-run.sh: the pressure guard fails open on an absent or stale verdict"
}

# --- ledger-recorded ceiling fallback ---------------------------------------

# Write a fixture ledger entry directly, including the new ceiling field. The pid
# need not be alive: resolve_slots reads the ledger without a reap, so a fixture
# with any numeric pid and a live state counts as a recorded ceiling. Pass an
# empty ceiling arg to omit the field entirely (an OLD pre-ceiling entry).
write_ledger_entry() {  # <seq> <state> <ceiling-or-empty>
  mkdir -p "$QUEUE"
  {
    printf 'seq=%s\n' "$1"
    printf 'pid=%s\n' 999999
    printf 'identity=%s\n' fixture-identity
    printf 'state=%s\n' "$2"
    printf 'started=%s\n' "$(date +%s)"
    printf 'home=%s\n' "$HOME_DIR"
    printf 'task=%s\n' fixture
    printf 'label=-\n'
    printf 'cmd=fixture\n'
    [ -n "$3" ] && printf 'ceiling=%s\n' "$3"
  } > "$(printf '%s/%012d.entry' "$QUEUE" "$1")"
}

test_ledger_ceiling_replaces_bare_one_fallback() {
  # A process with no FM_HEAVY_SLOTS and no config file must adopt the highest
  # recorded ceiling among live ledger entries instead of falling back to 1, so a
  # raised ceiling is honoured by the exact processes queuing on the shared ledger.
  reset_queue
  rm -f "$HOME_DIR/config/heavy-run-slots"
  write_ledger_entry 1 running 2
  [ "$("$HR" --slots 2>/dev/null)" = 2 ] \
    || fail "no env/config but a ledger ceiling=2 entry must resolve 2, not the bare-1 fallback"
  # The highest live entry wins when several are recorded.
  write_ledger_entry 2 waiting 3
  [ "$("$HR" --slots 2>/dev/null)" = 3 ] \
    || fail "the highest recorded live ceiling must win"
  pass "fm-heavy-run.sh: a bare-1 fallback adopts the highest recorded ledger ceiling"
}

test_explicit_ceiling_wins_over_ledger() {
  # An explicit local ceiling is authoritative; the ledger read is only the
  # fallback that replaces bare 1. FM_HEAVY_SLOTS and the config file both win.
  reset_queue
  write_ledger_entry 1 running 5
  [ "$(FM_HEAVY_SLOTS=2 "$HR" --slots 2>/dev/null)" = 2 ] \
    || fail "an explicit FM_HEAVY_SLOTS must win over a higher recorded ledger ceiling"
  printf '1\n' > "$HOME_DIR/config/heavy-run-slots"
  [ "$("$HR" --slots 2>/dev/null)" = 1 ] \
    || fail "an explicit config ceiling must win over a higher recorded ledger ceiling"
  pass "fm-heavy-run.sh: an explicit ceiling wins over the ledger read"
}

test_empty_ledger_and_no_config_resolves_one() {
  # With neither config nor any recorded ceiling, the safe bare-1 fallback stands.
  reset_queue
  rm -f "$HOME_DIR/config/heavy-run-slots"
  rm -rf "$QUEUE"
  [ "$("$HR" --slots 2>/dev/null)" = 1 ] \
    || fail "an empty ledger with no config must still resolve 1"
  pass "fm-heavy-run.sh: no config and no recorded ceiling still resolves 1"
}

test_malformed_recorded_ceiling_falls_to_one_loudly() {
  # A garbage recorded ceiling must be ignored loudly and fall to 1, exactly like
  # a malformed config value, rather than silently trusted.
  local out
  reset_queue
  rm -f "$HOME_DIR/config/heavy-run-slots"
  write_ledger_entry 1 running lots
  out=$("$HR" --slots 2>&1)
  assert_contains "$out" "malformed recorded heavy-run ceiling" "a malformed recorded ceiling must warn"
  [ "$("$HR" --slots 2>/dev/null)" = 1 ] \
    || fail "a malformed recorded ceiling must fall back to 1, not be trusted"
  pass "fm-heavy-run.sh: a malformed recorded ceiling falls to 1 loudly"
}

test_entry_ceiling_round_trips_and_old_entry_parses() {
  # entry_write must stamp ceiling= into a real admitted run, and entry_read must
  # tolerate an OLD entry with no ceiling field (backward compat): a pre-existing
  # ledger entry must not break parsing or admission.
  local holder entry rc
  reset_queue
  printf '2\n' > "$HOME_DIR/config/heavy-run-slots"
  # An OLD-format entry with no ceiling field occupying one slot. It must parse
  # (so --status/admission still see it) and must not break the new resolve path.
  write_ledger_entry 1 running ''
  [ "$("$HR" --slots 2>/dev/null)" = 2 ] \
    || fail "an old entry without a ceiling field must not break resolution"
  # A real run must stamp its resolved ceiling into its own live record.
  "$HR" --task stamp -- sleep 3 & holder=$!
  STRAYS+=("$holder")
  wait_status running 1 10 || fail "the stamping run never showed as running"
  entry=$(grep -l 'task=stamp' "$QUEUE"/*.entry 2>/dev/null | head -n 1)
  [ -n "$entry" ] || fail "could not find the stamping run's record"
  grep -q '^ceiling=2$' "$entry" \
    || fail "entry_write must stamp the resolved ceiling into the live record; record was:"$'\n'"$(cat "$entry")"
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null || true
  pass "fm-heavy-run.sh: entry_write stamps ceiling= and entry_read tolerates an old entry"
}

# --- stale-ceiling FIFO deadlock (regression) -------------------------------

test_stale_ceiling_head_waiter_picks_up_raised_ceiling() {
  # The bug: a waiter that started while its home lacked config/heavy-run-slots
  # resolves ceiling 1 and, if the ceiling was cached once at startup, holds it
  # forever. As the FIFO head with one slot occupied, it never admits and starves
  # the whole queue. The fix re-resolves the ceiling each admission pass, so the
  # head waiter must pick up a raised ceiling and admit WITHOUT being killed.
  local holder waiter rc
  reset_queue
  # No ceiling file yet: the waiter launched now resolves ceiling 1.
  rm -f "$HOME_DIR/config/heavy-run-slots"
  # One slot occupied by a long holder.
  "$HR" --task stale-holder -- sleep 6 & holder=$!
  STRAYS+=("$holder")
  wait_status running 1 10 || fail "the holding run never showed as running"
  # The head waiter enters the queue while ceiling is 1.
  "$HR" --task stale-head --max-wait 20 -- true & waiter=$!
  STRAYS+=("$waiter")
  wait_status waiting 1 10 || fail "the head waiter never showed as queued"
  # Raise the ceiling to 2 while the holder still runs. With the bug the waiter
  # keeps ceiling 1 and blocks until the holder exits; with the fix it re-resolves
  # 2, sees a free slot, and admits while the holder is still running.
  printf '2\n' > "$HOME_DIR/config/heavy-run-slots"
  # The waiter must admit and finish while the holder is STILL running, proving it
  # picked up the raised ceiling rather than merely waiting the holder out (with
  # the bug it would block until the holder's sleep ends, then admit at ceiling 1).
  wait "$waiter"; rc=$?
  expect_code 0 "$rc" "the stale-ceiling head waiter must admit under the raised ceiling"
  kill -0 "$holder" 2>/dev/null \
    || fail "the waiter only ran after the holder exited; it did not pick up the raised ceiling"
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null || true
  pass "fm-heavy-run.sh: a stale-ceiling head waiter picks up a raised ceiling and admits"
}

test_symlinked_ledger_dir_is_refused() {
  # A ledger root the operating uid does not own (here, a symlink standing in for
  # an attacker pre-created dir on a sticky world-writable tmp) must be refused
  # without running the command.
  local target ledger marker rc out
  target="$TMP_ROOT/attacker-ledger"
  ledger="$TMP_ROOT/symlinked-ledger"
  mkdir -p "$target"
  rm -rf "$ledger"
  ln -s "$target" "$ledger"
  marker="$TMP_ROOT/symlink-ledger-ran"
  out=$(FM_HEAVY_RUN_DIR="$ledger" "$HR" --task hijack -- touch "$marker" 2>&1); rc=$?
  expect_code 69 "$rc" "a symlinked ledger root must be refused, not used"
  assert_absent "$marker" "a refused ledger must never run the command"
  assert_contains "$out" "$ledger" "the refusal must name the offending path"
  rm -f "$ledger"
  pass "fm-heavy-run.sh: a symlinked ledger directory is refused"
}

test_script_parses
test_symlinked_ledger_dir_is_refused
test_stale_ceiling_head_waiter_picks_up_raised_ceiling
test_ledger_ceiling_replaces_bare_one_fallback
test_explicit_ceiling_wins_over_ledger
test_empty_ledger_and_no_config_resolves_one
test_malformed_recorded_ceiling_falls_to_one_loudly
test_entry_ceiling_round_trips_and_old_entry_parses
test_help_includes_entire_header
test_usage_error_runs_nothing
test_passes_through_output_and_status
test_ceiling_one_serializes
test_ceiling_two_overlaps
test_malformed_ceiling_falls_back_to_one
test_status_shows_queue_depth_and_order
test_waiter_reports_that_it_is_queued
test_max_wait_refuses_without_running
test_dead_holder_does_not_wedge_the_queue
test_reap_removes_the_record_but_never_the_process
test_killed_waiter_does_not_wedge_the_queue
test_killed_requester_does_not_orphan_its_run
test_default_ledger_is_host_global_not_per_home
test_record_carries_home_attribution
test_slots_pointer_overrides_local_ceiling
test_release_emits_a_nudge_when_a_waiter_is_queued
test_release_emits_no_nudge_with_no_waiter
test_free_slot_refused_under_sustained_critical
test_pressure_guard_fails_open_when_status_absent_or_stale
