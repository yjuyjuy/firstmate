#!/usr/bin/env bash
# Behavior tests for the primary turn-end supervision guard (docs/turnend-guard.md).
#
# Two layers:
#   PREDICATE  - bin/fm-supervision-lib.sh, the shared beacon/status computation
#                used by fm-guard.sh and by the hook's banner details.
#   HOOK       - bin/fm-turnend-guard.sh, the shared primary hook predicate that
#                scopes in-flight work to the PRIMARY checkout only and requires
#                a live, identity-matched watcher lock plus a fresh beacon.
# All hermetic over temp dirs; no real agent session is invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-supervision-lib.sh
. "$ROOT/bin/fm-supervision-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-turnend-guard)
fm_git_identity fmtest fmtest@example.invalid

REQUIRED_REASON='repair missing watcher supervision with bin/fm-watch-arm.sh as its own Claude Code background task'

# --- PREDICATE: bin/fm-supervision-lib.sh -----------------------------------

test_predicate_healthy_no_inflight() {
  local state="$TMP_ROOT/pred-empty/state"
  mkdir -p "$state"
  if fm_supervision_unhealthy "$state" 300; then
    fail "predicate reported unhealthy with zero in-flight tasks"
  fi
  [ "$FM_SUP_IN_FLIGHT" -eq 0 ] || fail "expected zero in-flight, got $FM_SUP_IN_FLIGHT"
  pass "fm_supervision_unhealthy: false with no state/*.meta at all"
}

test_predicate_unhealthy_no_beacon() {
  local state="$TMP_ROOT/pred-nobeat/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  fm_supervision_unhealthy "$state" 300 || fail "predicate did not fire: in-flight task, beacon never seen"
  [ "$FM_SUP_IN_FLIGHT" -eq 1 ] || fail "expected 1 in-flight, got $FM_SUP_IN_FLIGHT"
  [ "$FM_SUP_WATCHER_FRESH" = false ] || fail "beacon absent must not read as fresh"
  [ "$FM_SUP_BEACON_DESC" = never ] || fail "beacon description should be 'never', got $FM_SUP_BEACON_DESC"
  pass "fm_supervision_unhealthy: true with in-flight task and no beacon ever"
}

test_predicate_unhealthy_stale_beacon() {
  local state="$TMP_ROOT/pred-stale/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  touch -t 202001010000 "$state/.last-watcher-beat"
  fm_supervision_unhealthy "$state" 300 || fail "predicate did not fire: in-flight task, beacon far outside grace"
  [ "$FM_SUP_WATCHER_FRESH" = false ] || fail "an ancient beacon must not read as fresh"
  pass "fm_supervision_unhealthy: true with in-flight task and a beacon far outside the grace window"
}

test_predicate_healthy_fresh_beacon() {
  local state="$TMP_ROOT/pred-fresh/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  touch "$state/.last-watcher-beat"
  if fm_supervision_unhealthy "$state" 300; then
    fail "predicate fired despite a fresh beacon"
  fi
  [ "$FM_SUP_WATCHER_FRESH" = true ] || fail "a beacon touched just now must read as fresh"
  pass "fm_supervision_unhealthy: false with in-flight task and a fresh beacon"
}

test_predicate_queue_pending_flag() {
  local state="$TMP_ROOT/pred-queue/state"
  mkdir -p "$state"
  fm_supervision_status "$state" 300
  [ "$FM_SUP_QUEUE_PENDING" = false ] || fail "empty/absent wake queue must not read as pending"
  printf 'record\n' > "$state/.wake-queue"
  fm_supervision_status "$state" 300
  [ "$FM_SUP_QUEUE_PENDING" = true ] || fail "a non-empty wake queue must read as pending"
  pass "fm_supervision_status: FM_SUP_QUEUE_PENDING tracks state/.wake-queue"
}

# --- HOOK: bin/fm-turnend-guard.sh ------------------------------------------
#
# Each scenario gets its own directory carrying a copy of the two guard scripts
# under bin/, so the hook (invoked by absolute path) resolves its own FM_ROOT to
# that scenario dir regardless of the test's cwd.

install_guard_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-turnend-guard.sh" "$dir/bin/fm-turnend-guard.sh"
  cp "$ROOT/bin/fm-turnend-guard-grok.sh" "$dir/bin/fm-turnend-guard-grok.sh"
  cp "$ROOT/bin/fm-operational-input.sh" "$dir/bin/fm-operational-input.sh"
  cp "$ROOT/bin/fm-supervision-instructions.sh" "$dir/bin/fm-supervision-instructions.sh"
  cp "$ROOT/bin/fm-harness.sh" "$dir/bin/fm-harness.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-watch-scope-lib.sh" "$dir/bin/fm-watch-scope-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  # fm-wake-lib.sh sources this at load time; without it the guard's own libraries
  # fail to load and the hook emits a sourcing error where it should stay silent.
  cp "$ROOT/bin/fm-mutex-lib.sh" "$dir/bin/fm-mutex-lib.sh"
  cp "$ROOT/bin/fm-pid-lib.sh" "$dir/bin/fm-pid-lib.sh"
  cp "$ROOT/bin/fm-afk-daemon-lib.sh" "$dir/bin/fm-afk-daemon-lib.sh"
  mkdir -p "$dir/docs"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  chmod +x "$dir/bin/fm-turnend-guard.sh" "$dir/bin/fm-turnend-guard-grok.sh" "$dir/bin/fm-operational-input.sh" "$dir/bin/fm-supervision-instructions.sh" "$dir/bin/fm-harness.sh"
}

mark_codex_hook_root() {
  local dir=$1
  mkdir -p "$dir/.codex"
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"fm-turnend-guard.sh"}]}]}}\n' > "$dir/.codex/hooks.json"
}

# A primary-shaped checkout: plain (non-worktree) git repo, AGENTS.md, bin/,
# state/ - everything the hook's scoping check requires to treat it as primary.
make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  printf '%s\n' "$dir"
}

# Same shape as primary, plus the .fm-secondmate-home marker bin/fm-home-seed.sh
# writes at seed time (regardless of treehouse-lease or git-clone acquisition).
make_secondmate_dir() {
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  printf 'sm-test-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# A genuine linked `git worktree` of a base repo - the shape bin/fm-spawn.sh
# always hands crewmate/scout tasks working on firstmate itself. git-dir and
# git-common-dir differ here, unlike a plain checkout.
make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/turnend-guard-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  printf '%s\n' "$dir"
}

# A secondmate home's OWN child crew/scout worktree: a genuine linked git
# worktree of the secondmate home, so git-dir != git-common-dir exactly as for a
# main-home child worktree. A child worktree never carries the gitignored
# .fm-secondmate-home marker, so the marker force-include never fires for it and
# it stays exempt through the linked-worktree git-dir test.
make_secondmate_child_worktree_dir() {
  local home=$1 dir=$2
  git -C "$home" worktree add --quiet -b fm/turnend-secondmate-child "$dir"
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  printf '%s\n' "$dir"
}

# A treehouse-leased secondmate HOME: a genuine linked `git worktree` (git-dir !=
# git-common-dir, exactly like a default treehouse-leased home) that DOES carry a
# valid .fm-secondmate-home marker. This is the production topology the plain
# git-init secondmate fixture cannot represent; the guard must force-INCLUDE it
# as a guarded primary via the marker, not exempt it as a linked worktree.
make_secondmate_linked_home_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/turnend-secondmate-linked-home
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  printf 'sm-linked-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

run_hook() {
  local dir=$1 stop_active=$2 home
  home=$(cd "$dir" && pwd)
  printf '{"stop_hook_active":%s}' "$stop_active" | CLAUDECODE=1 FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" 2>&1
}

nonexistent_pid() {
  local pid=999999
  while kill -0 "$pid" 2>/dev/null; do
    pid=$((pid + 1))
  done
  printf '%s\n' "$pid"
}

watcher_identity() {
  local dir=$1 pid=$2
  FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$dir/bin/fm-pid-lib.sh" "$pid"
}

record_watcher_lock() {
  local dir=$1 pid=$2 identity=$3 root bin_dir
  root=$(cd "$dir" && pwd)
  bin_dir=$(cd "$dir/bin" && pwd)
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$root" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$bin_dir/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
}

# Launch a stand-in for THIS home's arm process: a live `bash <abs>/bin/fm-watch-arm.sh`
# whose /proc cmdline carries that exact absolute path as an argument, so
# fm_home_arm_pids (which the guard consults for wake-path ownership) selects it,
# without running the real arm. The guard copies the real fm-watch-arm.sh into
# <dir>/bin, so overwrite it with a harmless sleep body for the duration of the
# test - the enumeration matches on the cmdline path, not the file contents.
# Echoes the pid.
launch_fake_arm() {  # <dir>
  local dir=$1 arm_path pid i
  arm_path="$(cd "$dir/bin" && pwd)/fm-watch-arm.sh"
  cat > "$arm_path" <<'SH'
#!/usr/bin/env bash
sleep 120
SH
  chmod +x "$arm_path"
  bash "$arm_path" </dev/null >/dev/null 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 50 ] && ! kill -0 "$pid" 2>/dev/null; do sleep 0.02; i=$((i + 1)); done
  printf '%s\n' "$pid"
}

# Record a live present-daemon lock for this home, so fm_wake_path_owned's
# present-daemon check reads it as a live owner (via the shared afk-daemon
# liveness helper the guard already sources).
record_present_daemon_lock() {  # <dir> <pid> <identity>
  local dir=$1 pid=$2 identity=$3 root
  root=$(cd "$dir" && pwd)
  mkdir -p "$dir/state/.present-daemon.lock"
  printf '%s\n' "$pid" > "$dir/state/.present-daemon.lock/pid"
  printf '%s\n' "$root" > "$dir/state/.present-daemon.lock/fm-home"
  printf '%s\n' "$identity" > "$dir/state/.present-daemon.lock/pid-identity"
}

test_hook_silent_when_no_work_in_flight() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-idle")
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "hook must exit 0 with no in-flight work"
  [ -z "$out" ] || fail "hook produced output with no in-flight work: $out"
  pass "fm-turnend-guard: silent no-op with nothing in flight"
}

test_hook_blocks_when_fresh_beacon_has_no_live_lock() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-fresh-no-lock")
  : > "$dir/state/task1.meta"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must block when a fresh beacon has no live watcher lock"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks when a fresh beacon has no live watcher lock"
}

test_hook_blocks_when_dead_lock_has_fresh_beacon() {
  local dir dead out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-dead-lock-fresh")
  dead=$(nonexistent_pid)
  : > "$dir/state/task1.meta"
  record_watcher_lock "$dir" "$dead" "dead watcher identity"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must block when the watcher lock pid is dead despite a fresh beacon"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks on a dead watcher lock even when the beacon is fresh"
}

test_hook_silent_with_live_lock_and_fresh_beacon() {
  local dir pid identity armpid out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-live-lock-fresh")
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  # A live watcher lock and fresh beacon are necessary but not sufficient: the
  # guard also requires a wake-path owner. A live this-home arm is that owner.
  armpid=$(launch_fake_arm "$dir")
  out=$(run_hook "$dir" false); status=$?
  kill "$pid" "$armpid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "hook must exit 0 with a live watcher lock, fresh beacon, and a live arm owner"
  [ -z "$out" ] || fail "hook produced output despite a live fresh watcher lock and arm owner: $out"
  pass "fm-turnend-guard: silent no-op with a live watcher lock, fresh beacon, and a wake-path owner"
}

# --- P4: wake-path ownership (a live watcher is not enough) ------------------
#
# The incident had a live, fresh-beacon watcher and STILL went deaf because
# nothing owned a path that would complete to wake the idle model. The guard must
# alarm on exactly that state, and stay silent when a real owner (present daemon,
# away daemon, or a live this-home arm) exists.

test_blocks_when_watcher_alive_but_no_wake_owner() {
  local dir pid identity out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-wake-path-blind")
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  # NO arm, NO present daemon, NO away daemon: the watcher is alive but nothing
  # will complete to wake the session. This is the exact incident state.
  out=$(run_hook "$dir" false); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "hook must block when a watcher is alive but no wake path is owned"
  assert_contains "$out" "nothing will complete to wake this session" "banner must name the wake-path failure"
  assert_contains "$out" "TURN WOULD END BLIND" "block banner must read as an alarm"
  pass "fm-turnend-guard: blocks when a watcher is alive but no wake-path owner exists (the incident regression)"
}

test_passes_when_present_daemon_owns() {
  local dir pid identity dpid didentity out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-wake-path-present-daemon")
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  # A live present-mode daemon owns re-arming: the wake path is owned.
  sleep 60 &
  dpid=$!
  didentity=$(watcher_identity "$dir" "$dpid") || {
    kill "$pid" "$dpid" 2>/dev/null || true
    fail "could not identify live present-daemon holder"
  }
  record_present_daemon_lock "$dir" "$dpid" "$didentity"
  out=$(run_hook "$dir" false); status=$?
  kill "$pid" "$dpid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  wait "$dpid" 2>/dev/null || true
  expect_code 0 "$status" "hook must pass when a live present daemon owns the wake path"
  [ -z "$out" ] || fail "hook produced output despite a live present-daemon owner: $out"
  pass "fm-turnend-guard: passes when a live present-mode daemon owns the wake path"
}

test_passes_when_arm_alive() {
  local dir pid identity armpid out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-wake-path-arm")
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  armpid=$(launch_fake_arm "$dir")
  out=$(run_hook "$dir" false); status=$?
  kill "$pid" "$armpid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "hook must pass when a live this-home arm owns the wake path"
  [ -z "$out" ] || fail "hook produced output despite a live arm owner: $out"
  pass "fm-turnend-guard: passes when a live this-home arm owns the wake path"
}

test_hook_blocks_with_live_lock_and_stale_beacon() {
  local dir pid identity out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-live-lock-stale")
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "hook must block when a live watcher lock has an ancient beacon"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks on a live watcher lock with an ancient beacon"
}

test_hook_blocks_when_unhealthy_in_primary() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-block")
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must block (exit 2) when in-flight work has no live watcher"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  assert_contains "$out" "TURN WOULD END BLIND" "block banner must read as an alarm"
  pass "fm-turnend-guard: blocks with the exact required reason in the primary when unhealthy"
}

test_hook_blocks_from_fm_home_state() {
  local dir home out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-fm-home")
  home="$TMP_ROOT/hook-fm-home-op"
  mkdir -p "$home/state"
  : > "$home/state/task1.meta"
  out=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 2 "$status" "hook must inspect the active FM_HOME state dir"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks from active FM_HOME state, not only repo-root state"
}

test_hook_x_mode_reason_sources_cadence() {
  local dir home out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-x-mode")
  home=$(cd "$dir" && pwd)
  mkdir -p "$dir/config"
  : > "$dir/config/x-mode.env"
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must block when in-flight X-mode work has no live watcher"
  assert_contains "$out" "source '$home/config/x-mode.env' first" "block reason must source the effective X-mode cadence"
  pass "fm-turnend-guard: X-mode repair reason sources the cadence config"
}

test_hook_ignores_repo_state_when_fm_home_set() {
  local dir home out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-fm-home-ignore-root")
  home="$TMP_ROOT/hook-fm-home-quiet"
  mkdir -p "$home/state"
  : > "$dir/state/task1.meta"
  out=$(printf '{"stop_hook_active":false}' | FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "hook must ignore repo-root state when FM_HOME selects another state dir"
  [ -z "$out" ] || fail "hook produced output from stale repo-root state despite FM_HOME: $out"
  pass "fm-turnend-guard: ignores stale repo-root state when FM_HOME is set"
}

test_hook_uses_state_override() {
  local dir home state out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-state-override")
  home="$TMP_ROOT/hook-state-override-home"
  state="$TMP_ROOT/hook-state-override-active"
  mkdir -p "$home/state" "$state"
  : > "$state/task1.meta"
  out=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 2 "$status" "hook must let FM_STATE_OVERRIDE win over FM_HOME/state"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: uses FM_STATE_OVERRIDE ahead of FM_HOME/state"
}

test_hook_loop_guard_allows_retry() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-loopguard")
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" true); status=$?
  expect_code 0 "$status" "hook must allow the stop when stop_hook_active is already true"
  [ -z "$out" ] || fail "hook produced output on the loop-guarded retry: $out"
  pass "fm-turnend-guard: stop_hook_active=true always allows the stop (never blocks twice in one turn)"
}

# A secondmate's OWN home runs a primary firstmate session and must be guarded
# exactly like the main primary. This was the guard's proven blind spot: the
# .fm-secondmate-home marker used to early-exit here, so an overnight secondmate
# could end a turn with an unsupervised child and sit blind. Removing that marker
# check makes the guard fire, mirroring the cd-guard.
test_hook_blocks_in_secondmate_own_home() {
  local dir out status
  dir=$(make_secondmate_dir "$TMP_ROOT/hook-secondmate")
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must guard a secondmate's own home like the main primary when unhealthy"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  assert_contains "$out" "TURN WOULD END BLIND" "block banner must read as an alarm"
  pass "fm-turnend-guard: blocks a blind turn end in a secondmate's own home (.fm-secondmate-home no longer excludes it)"
}

# Idle-by-default: an empty-queue secondmate has no in-flight meta, so the guard
# exits at the in-flight gate - never forcing a busy continuation loop.
test_hook_silent_in_idle_secondmate_home() {
  local dir out status
  dir=$(make_secondmate_dir "$TMP_ROOT/hook-secondmate-idle")
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "hook must stay silent in an idle, empty-queue secondmate home"
  [ -z "$out" ] || fail "idle secondmate home produced guard output: $out"
  pass "fm-turnend-guard: idle-by-default - silent in a secondmate home with nothing in flight"
}

# The stop_hook_active loop guard bounds the secondmate to one forced
# continuation per turn, exactly as it does for the main primary - no wedged,
# un-endable session.
test_hook_secondmate_loop_guard_allows_retry() {
  local dir out status
  dir=$(make_secondmate_dir "$TMP_ROOT/hook-secondmate-loopguard")
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" true); status=$?
  expect_code 0 "$status" "hook must allow the stop in a secondmate home when stop_hook_active is already true"
  [ -z "$out" ] || fail "secondmate loop-guarded retry produced output: $out"
  pass "fm-turnend-guard: stop_hook_active=true allows the stop in a secondmate home (never blocks twice in one turn)"
}

# The guard's half of the deferred-death recovery loop in a secondmate home,
# proven deterministically without a live model or any daemon: silent while the
# watcher is live (the secondmate ends its turn and relies on the background
# re-invoke), then blocks to force the re-arm once the watcher has exited and a
# second child event lands. The live half - that Claude Code autonomously
# re-invokes the model when the background watcher exits (Mechanism A) - is a
# harness property recorded empirically in docs/turnend-guard.md; it needs a live
# session and cannot be a hermetic CI assertion.
test_hook_secondmate_reinvoke_recovery_loop() {
  local dir pid identity armpid out status
  dir=$(make_secondmate_dir "$TMP_ROOT/hook-secondmate-reinvoke")
  : > "$dir/state/child1.meta"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  # Stop #1: a live watcher AND a live arm task (its completion is the wake path
  # the secondmate relies on) - the guard must stay silent.
  armpid=$(launch_fake_arm "$dir")
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "secondmate turn must end silently while its watcher and arm are live (Stop #1)"
  [ -z "$out" ] || {
    kill "$pid" "$armpid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "guard nagged a healthy secondmate at Stop #1: $out"
  }
  # The watcher AND its arm exit on the wake (their normal lifecycle) and a SECOND
  # child event lands. On the re-invoked recovery turn the secondmate must re-arm;
  # if it did not, the guard blocks that turn's end and forces the re-arm (Stop #2).
  kill "$pid" "$armpid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$dir/state/.watch.lock"
  : > "$dir/state/child2.meta"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "secondmate recovery turn must not end blind after the watcher exits (Stop #2)"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: secondmate deferred-death recovery - silent while watched, forces re-arm once the watcher exits"
}

# The marker force-include must guard only the secondmate's OWN home, never its
# children: a secondmate's linked crew/scout worktree carries no marker, so it
# stays exempt by the same git-dir/git-common-dir test that exempts the main
# home's children.
test_hook_silent_in_secondmate_child_worktree() {
  local home dir out status
  home=$(make_secondmate_dir "$TMP_ROOT/hook-sm-child-home")
  dir="$TMP_ROOT/hook-sm-child-wt"
  make_secondmate_child_worktree_dir "$home" "$dir" >/dev/null
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "hook must stay exempt in a secondmate's own child crew/scout worktree"
  [ -z "$out" ] || fail "hook produced output inside a secondmate's child worktree: $out"
  pass "fm-turnend-guard: inert in a secondmate's own child worktree (linked git worktree) even when unhealthy"
}

# THE regression the plain git-init fixtures masked: a treehouse-leased secondmate
# home is a genuine LINKED worktree (git-dir != git-common-dir), which the
# remove-only form wrongly exempted. With the marker force-include, its own
# primary session is GUARDED. The test asserts the fixture really is a linked
# worktree so it can never silently regress back into a plain-checkout shape.
test_hook_blocks_in_treehouse_leased_secondmate_home() {
  local base dir gd gcd out status
  base="$TMP_ROOT/hook-sm-leased-base"
  dir="$TMP_ROOT/hook-sm-leased-home"
  make_secondmate_linked_home_dir "$base" "$dir" >/dev/null
  gd=$(git -C "$dir" rev-parse --git-dir)
  gcd=$(git -C "$dir" rev-parse --git-common-dir)
  [ "$gd" != "$gcd" ] || fail "leased-home fixture must be a linked worktree (git-dir != git-common-dir), got equal: $gd"
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must GUARD a treehouse-leased (linked) secondmate home via its marker when unhealthy"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  assert_contains "$out" "TURN WOULD END BLIND" "block banner must read as an alarm"
  pass "fm-turnend-guard: blocks a blind turn end in a treehouse-leased LINKED secondmate home (marker force-include)"
}

# Anti-spoof: a linked worktree with an INVALID (empty) marker must NOT be
# force-included. Marker validation rejects it, so it falls through to the
# linked-worktree exemption and stays exempt - a stray/empty marker file can
# never spoof a child worktree into being guarded.
test_hook_exempts_linked_worktree_with_stray_marker() {
  local base dir out status
  base="$TMP_ROOT/hook-stray-marker-base"
  dir="$TMP_ROOT/hook-stray-marker-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/.fm-secondmate-home"
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "an empty/invalid marker must not spoof force-inclusion in a linked worktree"
  [ -z "$out" ] || fail "stray empty marker wrongly force-included a linked worktree: $out"
  pass "fm-turnend-guard: an invalid (empty) marker cannot spoof inclusion; linked worktree stays exempt"
}

# Anti-spoof under any locale: a NON-ASCII marker id must be REJECTED by the
# ASCII-only (C-collation) allowlist, so it can never force-include a linked
# worktree even where the ambient locale's collation would treat it as a letter.
# Rejection -> git-dir exemption -> the linked worktree stays exempt.
test_hook_exempts_linked_worktree_with_non_ascii_marker() {
  local base dir out status
  base="$TMP_ROOT/hook-nonascii-marker-base"
  dir="$TMP_ROOT/hook-nonascii-marker-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  printf 'caf\xc3\xa9\n' > "$dir/.fm-secondmate-home"
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "a non-ASCII marker id must not spoof force-inclusion in a linked worktree"
  [ -z "$out" ] || fail "non-ASCII marker wrongly force-included a linked worktree: $out"
  pass "fm-turnend-guard: a non-ASCII marker cannot spoof inclusion; linked worktree stays exempt"
}

test_hook_silent_in_crewmate_worktree() {
  local base dir out status
  base="$TMP_ROOT/hook-crew-base"
  dir="$TMP_ROOT/hook-crew-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "hook must never block inside a crewmate task worktree"
  [ -z "$out" ] || fail "hook produced output inside a crewmate task worktree: $out"
  pass "fm-turnend-guard: inert in a crewmate/scout task worktree (linked git worktree) even when unhealthy"
}

test_hook_silent_without_jq() {
  local dir out status fakebin tool tool_path
  dir=$(make_primary_dir "$TMP_ROOT/hook-nojq")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/hook-nojq-fake")
  for tool in bash sh git cat printf date uname stat mkdir dirname; do
    tool_path=$(command -v "$tool") || fail "test host must provide $tool"
    ln -s "$tool_path" "$fakebin/$tool"
  done
  out=$(printf '{"stop_hook_active":false}' | PATH="$fakebin" bash "$dir/bin/fm-turnend-guard.sh" 2>&1)
  status=$?
  expect_code 0 "$status" "hook must fail open (exit 0) when jq is unavailable"
  [ -z "$out" ] || fail "hook produced output without jq: $out"
  pass "fm-turnend-guard: fails open (never blocks) when jq is missing"
}

test_hook_silent_without_stdin() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-nostdin")
  : > "$dir/state/task1.meta"
  out=$(bash "$dir/bin/fm-turnend-guard.sh" < /dev/null 2>&1); status=$?
  expect_code 0 "$status" "hook must exit 0 on empty/absent stdin"
  [ -z "$out" ] || fail "hook produced output on empty stdin: $out"
  pass "fm-turnend-guard: silent no-op on empty stdin"
}

test_hook_runs_fast() {
  local dir start elapsed_s
  dir=$(make_primary_dir "$TMP_ROOT/hook-timing")
  : > "$dir/state/task1.meta"
  start=$SECONDS
  run_hook "$dir" false >/dev/null
  elapsed_s=$((SECONDS - start))
  [ "$elapsed_s" -lt 3 ] || fail "hook took ${elapsed_s}s, expected well under a second (generous 3s CI margin)"
  pass "fm-turnend-guard: runs well under the generous timing margin (${elapsed_s}s)"
}

test_grok_adapter_forces_one_resume_when_unhealthy() {
  local dir fakebin log out status
  dir=$(make_primary_dir "$TMP_ROOT/grok-adapter-block")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-adapter-fakebin")
  log="$TMP_ROOT/grok-adapter-call.log"
  cat > "$fakebin/grok" <<EOF
#!/usr/bin/env bash
{
  printf 'active=%s\n' "\${GROK_TURNEND_GUARD_ACTIVE:-}"
  printf 'home=%s\n' "\${GROK_HOME:-}"
  printf 'args:'
  for arg in "\$@"; do
    printf ' <%s>' "\$arg"
  done
  printf '\n'
} >> "$log"
EOF
  chmod +x "$fakebin/grok"
  out=$(printf '{"sessionId":"session-test","hookEventName":"stop"}' | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 0 "$status" "grok adapter must fail open after queuing a forced resume"
  [ -z "$out" ] || fail "grok adapter printed output: $out"
  assert_contains "$(cat "$log")" 'active=1' "grok adapter must mark its forced resume as loop-guarded"
  assert_contains "$(cat "$log")" '<--resume>' "grok adapter must resume the current session"
  assert_contains "$(cat "$log")" '<session-test>' "grok adapter must pass the hook session id"
  assert_not_contains "$(cat "$log")" '<--permission-mode>' "grok adapter must not add a stronger permission mode"
  assert_not_contains "$(cat "$log")" '<bypassPermissions>' "grok adapter must not bypass permissions on forced resume"
  assert_contains "$(cat "$log")" 'FIRSTMATE_OP: v1 turn-end-guard: TURN WOULD END BLIND' "grok adapter must retain the typed guard kind"
  pass "fm-turnend-guard-grok: forces one explicitly marked same-session resume when the shared predicate blocks"
}

test_grok_adapter_loop_guard_skips_resume() {
  local dir fakebin log out status
  dir=$(make_primary_dir "$TMP_ROOT/grok-adapter-loop")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-adapter-loop-fakebin")
  log="$TMP_ROOT/grok-adapter-loop-call.log"
  cat > "$fakebin/grok" <<EOF
#!/usr/bin/env bash
printf 'called\n' >> "$log"
EOF
  chmod +x "$fakebin/grok"
  out=$(printf '{"sessionId":"session-test","hookEventName":"stop"}' | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" GROK_TURNEND_GUARD_ACTIVE=1 bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 0 "$status" "grok adapter must allow its own forced resume turn to end"
  [ -z "$out" ] || fail "grok adapter printed output while loop-guarded: $out"
  [ ! -e "$log" ] || fail "grok adapter spawned another resume while loop-guarded: $(cat "$log")"
  pass "fm-turnend-guard-grok: loop guard prevents a nested resume loop"
}

test_settings_hook_uses_claude_project_dir() {
  local settings command
  settings="$ROOT/.claude/settings.json"
  [ -f "$settings" ] || fail "tracked .claude/settings.json is missing"
  command=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "Stop hook command is missing from .claude/settings.json"
  assert_contains "$command" 'CLAUDE_PROJECT_DIR' "Stop hook must resolve via CLAUDE_PROJECT_DIR, not a cwd-relative path"
  assert_contains "$command" 'fm-turnend-guard.sh' "Stop hook must still invoke fm-turnend-guard.sh"
  case "$command" in
    bin/fm-turnend-guard.sh|./bin/fm-turnend-guard.sh)
      fail "Stop hook must not use a bare relative path (cwd-dependent): $command"
      ;;
  esac
  pass ".claude/settings.json: Stop hook uses CLAUDE_PROJECT_DIR-anchored command"
}

test_codex_hook_invokes_shared_guard() {
  local settings command
  settings="$ROOT/.codex/hooks.json"
  [ -f "$settings" ] || fail "tracked .codex/hooks.json is missing"
  command=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "Stop hook command is missing from .codex/hooks.json"
  assert_contains "$command" 'pwd -P' "codex hook must anchor from the hook process working directory"
  assert_contains "$command" '.codex/hooks.json' "codex hook must verify the hook-loaded firstmate root"
  assert_contains "$command" 'fm-turnend-guard.sh' "codex hook must invoke the shared guard"
  assert_not_contains "$command" '.cwd' "codex hook must not use payload cwd to select the guard executable"
  pass ".codex/hooks.json: Stop hook invokes the shared primary guard"
}

test_codex_hook_uses_process_pwd_when_payload_cwd_is_outside_root() {
  local settings command dir expected_root outside payload out status
  settings="$ROOT/.codex/hooks.json"
  [ -f "$settings" ] || fail "tracked .codex/hooks.json is missing"
  command=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "Stop hook command is missing from .codex/hooks.json"
  dir=$(make_primary_dir "$TMP_ROOT/codex-hook-root")
  mark_codex_hook_root "$dir"
  expected_root=$(cd "$dir" && pwd -P)
  outside="$TMP_ROOT/codex-hook-outside"
  mkdir -p "$outside"
  cat > "$dir/bin/fm-turnend-guard.sh" <<'EOF'
#!/usr/bin/env bash
printf 'guard=%s\n' "$0"
cat
EOF
  chmod +x "$dir/bin/fm-turnend-guard.sh"
  payload=$(jq -cn --arg cwd "$outside" '{cwd:$cwd,stop_hook_active:false}')
  out=$(printf '%s' "$payload" | (cd "$dir" && bash -c "$command") 2>&1); status=$?
  expect_code 0 "$status" "codex hook must execute successfully when payload cwd is outside the firstmate root"
  assert_contains "$out" "guard=$expected_root/bin/fm-turnend-guard.sh" "codex hook must use the hook process root"
  assert_contains "$out" "$payload" "codex hook must pass the original payload to the guard"
  pass ".codex/hooks.json: Stop hook uses hook process root when payload cwd is outside"
}

test_codex_hook_ignores_nested_git_root_guard() {
  local settings command dir nested subdir expected_root payload out status
  settings="$ROOT/.codex/hooks.json"
  [ -f "$settings" ] || fail "tracked .codex/hooks.json is missing"
  command=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "Stop hook command is missing from .codex/hooks.json"
  dir=$(make_primary_dir "$TMP_ROOT/codex-hook-outer")
  mark_codex_hook_root "$dir"
  expected_root=$(cd "$dir" && pwd -P)
  nested="$dir/projects/other"
  mkdir -p "$nested"
  git init -q "$nested"
  git -C "$nested" commit -q --allow-empty -m init
  mkdir -p "$nested/bin" "$nested/.codex"
  : > "$nested/AGENTS.md"
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"fm-turnend-guard.sh"}]}]}}\n' > "$nested/.codex/hooks.json"
  cat > "$nested/bin/fm-turnend-guard.sh" <<'EOF'
#!/usr/bin/env bash
printf 'nested guard executed\n'
exit 99
EOF
  chmod +x "$nested/bin/fm-turnend-guard.sh"
  cat > "$dir/bin/fm-turnend-guard.sh" <<'EOF'
#!/usr/bin/env bash
printf 'guard=%s\n' "$0"
cat
EOF
  chmod +x "$dir/bin/fm-turnend-guard.sh"
  subdir="$nested/deep/path"
  mkdir -p "$subdir"
  payload=$(jq -cn --arg cwd "$subdir" '{cwd:$cwd,stop_hook_active:false}')
  out=$(printf '%s' "$payload" | (cd "$dir" && bash -c "$command") 2>&1); status=$?
  expect_code 0 "$status" "codex hook must not execute a nested project guard"
  assert_contains "$out" "guard=$expected_root/bin/fm-turnend-guard.sh" "codex hook must keep using the outer firstmate guard"
  assert_not_contains "$out" "nested guard executed" "codex hook must not execute nested project code"
  pass ".codex/hooks.json: Stop hook ignores nested git root guard scripts"
}

test_opencode_plugin_forces_followup() {
  local plugin content
  plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  [ -f "$plugin" ] || fail "tracked OpenCode primary plugin is missing"
  content=$(cat "$plugin")
  assert_contains "$content" 'session.idle' "OpenCode plugin must run on session.idle"
  assert_contains "$content" 'fm-turnend-guard.sh' "OpenCode plugin must invoke the shared guard"
  assert_contains "$content" 'promptAsync' "OpenCode plugin must force a follow-up turn"
  assert_contains "$content" 'encodeFirstmateOperationalInput' "OpenCode plugin must use the typed operational-input constructor"
  assert_contains "$content" 'skipNextIdle' "OpenCode plugin must carry a loop guard"
  assert_contains "$content" 'worktree' "OpenCode plugin must anchor the guard from the git worktree path"
  assert_contains "$content" 'watcher cycle is missing, failed, or unhealthy' "OpenCode plugin must identify a blind turn as watcher recovery"
  assert_contains "$content" 'harness recovery instruction below' "OpenCode plugin must delegate recovery action to the shared guard line"
  assert_not_contains "$content" 'Resume supervision according to the session-start operating block' "OpenCode plugin must not route a blind turn through ordinary continuity"
  pass ".opencode primary plugin: session.idle forces one follow-up through the shared guard"
}

test_opencode_plugin_anchors_guard_to_worktree() {
  local plugin parent worktree_dir wrong_dir out status
  plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  [ -f "$plugin" ] || fail "tracked OpenCode primary plugin is missing"
  parent="$TMP_ROOT/opencode-plugin-parent"
  git init -q "$parent"
  worktree_dir="$parent/nested/opencode-plugin-worktree"
  wrong_dir="$TMP_ROOT/opencode-plugin-cwd/subdir"
  mkdir -p "$worktree_dir/bin" "$wrong_dir"
  cat > "$worktree_dir/bin/fm-turnend-guard.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'guard-fired\n' >&2
exit 2
EOF
  chmod +x "$worktree_dir/bin/fm-turnend-guard.sh"
  # Runtime module-format warnings are host noise; this assertion owns plugin output only.
  out=$(NODE_NO_WARNINGS=1 PLUGIN="$plugin" DIRECTORY="$wrong_dir" WORKTREE="$worktree_dir" node 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let promptBody = "";
const client = {
  session: {
    promptAsync: async (request) => {
      promptBody = request.body.parts[0].text;
    },
  },
};
const hooks = await mod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.DIRECTORY,
  worktree: process.env.WORKTREE,
});
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
if (!promptBody.startsWith("\u2063FIRSTMATE_OP: v1 turn-end-guard: ")) {
  console.error(`untyped operational prompt: ${promptBody}`);
  process.exit(1);
}
if (!promptBody.includes("guard-fired")) {
  console.error(`missing prompt body: ${promptBody}`);
  process.exit(1);
}
if (!promptBody.includes("watcher cycle is missing, failed, or unhealthy")) {
  console.error(`missing recovery-only preamble: ${promptBody}`);
  process.exit(1);
}
if (promptBody.includes("Resume supervision according to the session-start operating block")) {
  console.error(`ordinary continuity leaked into guard follow-up: ${promptBody}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode plugin must run the guard from worktree even when directory is elsewhere"
  [ -z "$out" ] || fail "OpenCode plugin worktree-root test printed output: $out"
  pass ".opencode primary plugin: guard path is anchored to worktree, not directory"
}

test_pi_extension_forces_followup() {
  local ext content
  ext="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  [ -f "$ext" ] || fail "tracked pi primary extension is missing"
  content=$(cat "$ext")
  assert_contains "$content" 'agent_settled' "pi extension must run after one logical agent run settles"
  assert_contains "$content" 'fm-turnend-guard.sh' "pi extension must invoke the shared guard"
  assert_contains "$content" 'sendUserMessage' "pi extension must force a follow-up turn"
  assert_contains "$content" 'encodeFirstmateOperationalInput' "pi extension must use the typed operational-input constructor"
  assert_contains "$content" 'deliverAs: "followUp"' "pi extension must queue the follow-up safely"
  assert_contains "$content" 'guardFollowupActive' "pi extension must carry a logical-run loop guard"
  assert_not_contains "$content" 'skipNextTurnEnd' "pi extension kept the internal-turn loop guard"
  assert_contains "$content" 'watcher cycle is missing, failed, or unhealthy' "pi extension must identify a blind turn as watcher recovery"
  assert_contains "$content" 'harness recovery instruction below' "pi extension must delegate recovery action to the shared guard line"
  assert_not_contains "$content" 'Resume supervision according to the session-start operating block' "pi extension must not route a blind turn through ordinary continuity"
  assert_contains "$content" '.pi-turnend-extension-loaded' "pi extension must write its loaded marker for session-start diagnostics"
  assert_contains "$content" 'lockOwnership' "pi extension loaded marker must respect the session lock"
  assert_contains "$content" 'const command = String((event.input as { command?: unknown })?.command ?? "")' "pi extension changed bash command extraction for the PreToolUse contract"
  assert_contains "$content" 'runPretoolCheck(command)' "pi extension changed the PreToolUse checker invocation"
  assert_contains "$content" 'return { block: true, reason:' "pi extension changed the checker exit-2 block result"
  assert_not_contains "$content" 'Run bin/fm-watch-arm.sh as a background task' "pi extension must not hardcode the old watcher-arm instruction"
  pass ".pi primary extension: agent_settled forces one follow-up through the shared guard"
}

test_pi_extension_injects_once_per_logical_agent_run() {
  local repo home ext log out status
  repo="$TMP_ROOT/pi-logical-run-root"
  home="$TMP_ROOT/pi-logical-run-home"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  log="$TMP_ROOT/pi-logical-run-guard.log"
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" "$home/state"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ext"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'logical-run guard fired\n' >&2
exit 2
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh" "$repo/bin/fm-arm-pretool-check.sh"
  out=$(PLUGIN="$ext" FM_HOME="$home" FM_GUARD_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let prompts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(message, options) {
    prompts += 1;
    if (!message.startsWith("\u2063FIRSTMATE_OP: v1 turn-end-guard: ")) throw new Error(`untyped operational prompt: ${message}`);
    if (!message.includes("TURN WOULD END BLIND")) throw new Error(`unexpected prompt: ${message}`);
    if (!message.includes("watcher cycle is missing, failed, or unhealthy")) throw new Error(`guard prompt omitted recovery-only state: ${message}`);
    if (message.includes("Resume supervision according to the session-start operating block")) throw new Error(`guard prompt used ordinary continuity: ${message}`);
    if (options?.deliverAs !== "followUp") throw new Error("guard prompt was not a follow-up");
    await handlers.get("agent_settled")?.({ type: "agent_settled" }, {});
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (handlers.has("turn_end")) throw new Error("guard still treats internal Pi turns as logical runs");
const settled = handlers.get("agent_settled");
if (!settled) throw new Error("agent_settled handler was not registered");

await settled({ type: "agent_settled" }, {});
if (prompts !== 1) throw new Error(`no-tool run injected ${prompts} follow-ups`);

for (let i = 0; i < 3; i += 1) {
  await handlers.get("turn_end")?.({ type: "turn_end", turnIndex: i }, {});
}
await settled({ type: "agent_settled" }, {});
if (prompts !== 2) throw new Error(`multi-tool run produced ${prompts - 1} follow-ups`);

const guardRuns = readFileSync(process.env.FM_GUARD_LOG, "utf8").trim().split("\n").length;
if (guardRuns !== 2) throw new Error(`guard predicate ran ${guardRuns} times for two logical runs`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must inject once for no-tool and multi-tool logical runs"
  [ -z "$out" ] || fail "Pi logical-run guard test printed output: $out"
  pass ".pi primary extension: no-tool and multi-tool runs each inject exactly one guard follow-up"
}

test_pi_extension_retries_after_followup_delivery_failure() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-delivery-failure-root"
  home="$TMP_ROOT/pi-delivery-failure-home"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" "$home/state"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ext"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'delivery failure guard\n' >&2
exit 2
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh" "$repo/bin/fm-arm-pretool-check.sh"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
let attempts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage() {
    attempts += 1;
    if (attempts === 1) throw new Error("synthetic delivery failure");
    await handlers.get("agent_settled")?.({ type: "agent_settled" }, {});
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const settled = handlers.get("agent_settled");
await settled({ type: "agent_settled" }, {});
await settled({ type: "agent_settled" }, {});
if (attempts !== 2) throw new Error(`expected delivery retry, saw ${attempts} attempts`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard latch must reset after follow-up delivery failure"
  [ -z "$out" ] || fail "Pi delivery-failure guard test printed output: $out"
  pass ".pi primary extension: delivery failure resets the logical-run latch"
}

test_grok_hook_invokes_adapter() {
  local settings command
  settings="$ROOT/.grok/hooks/fm-primary-turnend-guard.json"
  [ -f "$settings" ] || fail "tracked grok primary hook config is missing"
  command=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "Stop hook command is missing from grok primary hook config"
  assert_contains "$command" 'GROK_WORKSPACE_ROOT' "grok hook must anchor from GROK_WORKSPACE_ROOT"
  assert_contains "$command" 'fm-turnend-guard-grok.sh' "grok hook must invoke the adapter"
  pass ".grok primary hook: Stop hook invokes the grok adapter"
}

# --- HOOK: away mode, daemon-owned vs daemon-free ---------------------------
#
# Away mode alone never means a daemon owns supervision. A home whose captain
# session runs outside any injectable supervisor pane runs away mode with NO
# daemon, and its own watcher stays the real supervision mechanism.

AFK_REASON='Away mode owns watcher supervision; load /afk'

record_daemon_lock() {
  local dir=$1 pid=$2 identity=$3
  mkdir -p "$dir/state/.supervise-daemon.lock"
  printf '%s\n' "$pid" > "$dir/state/.supervise-daemon.lock/pid"
  printf '%s\n' "$identity" > "$dir/state/.supervise-daemon.lock/pid-identity"
}

# --- OWNERSHIP STATE: bin/fm-afk-daemon-lib.sh ------------------------------
#
# fm_afk_daemon_supervision_state has three outcomes, and the fail direction
# matters: an unprobeable lock must read as still daemon-owned so the watcher
# never runs its own triage alongside a live daemon.

daemon_supervision_state() {  # <dir> [path] [proc-root]
  local dir=$1 path_override=${2:-$PATH} proc_override=${3:-}
  PATH="$path_override" FM_PROC_ROOT_OVERRIDE="$proc_override" \
    bash -c '. "$1"; fm_afk_daemon_supervision_state "$2" "$3"' \
    _ "$dir/bin/fm-afk-daemon-lib.sh" "$dir/state" "$dir/bin"
}

daemon_owns_supervision() {  # <dir> [path] [proc-root]
  local dir=$1 path_override=${2:-$PATH} proc_override=${3:-}
  PATH="$path_override" FM_PROC_ROOT_OVERRIDE="$proc_override" \
    bash -c '. "$1"; fm_afk_daemon_owns_supervision "$2" "$3"' \
    _ "$dir/bin/fm-afk-daemon-lib.sh" "$dir/state" "$dir/bin"
}

test_supervision_state_free_without_lock() {
  local dir state
  dir=$(make_primary_dir "$TMP_ROOT/state-no-lock")
  : > "$dir/state/.afk"
  state=$(daemon_supervision_state "$dir")
  [ "$state" = free ] || fail "away mode with no daemon lock must read as free, got '$state'"
  daemon_owns_supervision "$dir" && fail "no daemon lock must not read as daemon-owned"
  pass "fm-afk-daemon-lib: away mode with no daemon lock reads daemon-free"
}

test_supervision_state_owned_with_live_daemon() {
  local dir pid identity state owned
  dir=$(make_primary_dir "$TMP_ROOT/state-live-daemon")
  : > "$dir/state/.afk"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live daemon holder"
  }
  record_daemon_lock "$dir" "$pid" "$identity"
  state=$(daemon_supervision_state "$dir")
  owned=0
  daemon_owns_supervision "$dir" && owned=1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$state" = owned ] || fail "a live identity-matched daemon must read as owned, got '$state'"
  [ "$owned" -eq 1 ] || fail "a live identity-matched daemon must own supervision"
  pass "fm-afk-daemon-lib: a live identity-matched daemon reads daemon-owned"
}

test_supervision_state_free_with_dead_holder() {
  local dir dead state
  dir=$(make_primary_dir "$TMP_ROOT/state-dead-daemon")
  : > "$dir/state/.afk"
  dead=$(nonexistent_pid)
  record_daemon_lock "$dir" "$dead" "linux-starttime=1 cmdline-hex=00"
  state=$(daemon_supervision_state "$dir")
  [ "$state" = free ] || fail "a confidently dead holder must read as free, got '$state'"
  daemon_owns_supervision "$dir" && fail "a confidently dead holder must not own supervision"
  pass "fm-afk-daemon-lib: a confidently dead lock holder reads daemon-free"
}

# A lock link whose owner directory is gone holds nothing and can never become
# probeable again, so it must read as free rather than latching daemon-owned
# over a home whose own watcher is the real supervision mechanism.
test_supervision_state_free_with_dangling_lock() {
  local dir state
  dir=$(make_primary_dir "$TMP_ROOT/state-dangling-lock")
  : > "$dir/state/.afk"
  ln -s "$dir/state/.supervise-daemon.lock.d" "$dir/state/.supervise-daemon.lock"
  state=$(daemon_supervision_state "$dir")
  [ "$state" = free ] || fail "a lock link with no owner directory must read as free, got '$state'"
  daemon_owns_supervision "$dir" && fail "a lock link with no owner directory must not own supervision"
  pass "fm-afk-daemon-lib: a dangling daemon lock reads daemon-free"
}

test_supervision_state_undetermined_without_pid() {
  local dir state
  dir=$(make_primary_dir "$TMP_ROOT/state-unreadable-pid")
  : > "$dir/state/.afk"
  mkdir -p "$dir/state/.supervise-daemon.lock"
  state=$(daemon_supervision_state "$dir")
  [ "$state" = undetermined ] || fail "a held lock with no readable pid must read as undetermined, got '$state'"
  daemon_owns_supervision "$dir" || fail "an undetermined probe must keep supervision daemon-owned"
  pass "fm-afk-daemon-lib: a held lock with an unreadable pid stays daemon-owned"
}

# The identity probe itself fails here (no /proc to read, ps shimmed to fail)
# while the holder is genuinely alive - the transient hiccup that must never be
# mistaken for a departed daemon.
test_supervision_state_undetermined_when_probe_fails() {
  local dir pid fakebin proc_root state owned
  dir=$(make_primary_dir "$TMP_ROOT/state-probe-fails")
  : > "$dir/state/.afk"
  fakebin=$(fm_fakebin "$dir")
  proc_root="$dir/empty-proc"
  mkdir -p "$proc_root"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/ps"
  sleep 60 &
  pid=$!
  record_daemon_lock "$dir" "$pid" "recorded-identity-that-cannot-be-reread"
  state=$(daemon_supervision_state "$dir" "$fakebin:$PATH" "$proc_root")
  owned=0
  daemon_owns_supervision "$dir" "$fakebin:$PATH" "$proc_root" && owned=1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$state" = undetermined ] || fail "a failed liveness probe must read as undetermined, got '$state'"
  [ "$owned" -eq 1 ] || fail "a failed liveness probe must keep supervision daemon-owned"
  pass "fm-afk-daemon-lib: a failed liveness probe stays daemon-owned"
}

test_hook_afk_without_daemon_silent_with_live_watcher() {
  local dir pid identity armpid out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-afk-nodaemon-live")
  : > "$dir/state/task1.meta"
  : > "$dir/state/.afk"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  # Daemon-free away mode keeps this session's own watcher as supervision, so a
  # live this-home arm is the wake-path owner that makes it non-blind.
  armpid=$(launch_fake_arm "$dir")
  out=$(run_hook "$dir" false); status=$?
  kill "$pid" "$armpid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "away mode without a daemon must accept a live watcher with a fresh beacon and a live arm"
  [ -z "$out" ] || fail "hook produced output despite healthy daemon-free away-mode supervision: $out"
  pass "fm-turnend-guard: away mode without a daemon is silent with a live watcher, fresh beacon, and a wake-path owner"
}

test_hook_afk_without_daemon_blocks_with_rearm_reason() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-afk-nodaemon-missing")
  : > "$dir/state/task1.meta"
  : > "$dir/state/.afk"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "away mode without a daemon must still block on a missing watcher"
  assert_contains "$out" "$REQUIRED_REASON" "daemon-free away mode must point at re-arming the watcher"
  case "$out" in
    *"$AFK_REASON"*) fail "daemon-free away mode must not point at the /afk daemon: $out" ;;
  esac
  pass "fm-turnend-guard: away mode without a daemon blocks and names re-arming the watcher"
}

test_hook_afk_without_daemon_fresh_beacon_message_is_consistent() {
  local dir dead out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-afk-nodaemon-fresh")
  dead=$(nonexistent_pid)
  : > "$dir/state/task1.meta"
  : > "$dir/state/.afk"
  record_watcher_lock "$dir" "$dead" "dead watcher identity"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "a dead watcher lock must block even in daemon-free away mode"
  assert_contains "$out" "is no longer holding this home lock" "banner must state the real failure"
  case "$out" in
    *"no live watcher holds this home lock"*)
      fail "banner must not claim no live watcher while printing a fresh beacon age: $out" ;;
  esac
  pass "fm-turnend-guard: daemon-free away-mode banner never contradicts a fresh beacon age"
}

test_hook_afk_with_live_daemon_keeps_daemon_reason() {
  local dir pid identity out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-afk-daemon")
  : > "$dir/state/task1.meta"
  : > "$dir/state/.afk"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live daemon holder"
  }
  record_daemon_lock "$dir" "$pid" "$identity"
  out=$(run_hook "$dir" false); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "away mode with a live daemon keeps blocking on a missing watcher"
  assert_contains "$out" "$AFK_REASON" "a live daemon still owns watcher supervision"
  assert_contains "$out" "no live watcher holds this home lock" "daemon-owned banner must stay unchanged"
  pass "fm-turnend-guard: away mode with a live daemon keeps today's daemon-owned behavior"
}

test_hook_afk_ignores_another_homes_daemon() {
  local dir other pid identity out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-afk-other-home")
  other="$TMP_ROOT/hook-afk-other-home-neighbor"
  mkdir -p "$other/state"
  : > "$dir/state/task1.meta"
  : > "$dir/state/.afk"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live daemon holder"
  }
  record_daemon_lock "$other" "$pid" "$identity"
  out=$(run_hook "$dir" false); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "another home's daemon must not satisfy this home's daemon check"
  assert_contains "$out" "$REQUIRED_REASON" "a neighbor daemon leaves this home in the daemon-free case"
  case "$out" in
    *"$AFK_REASON"*) fail "another home's daemon must not transfer watcher ownership: $out" ;;
  esac
  pass "fm-turnend-guard: another home's away-mode daemon never satisfies this home's check"
}

# No pid-identity file in the lock owner, so fm_afk_daemon_pid_matches must fall
# back to the process command line. That fallback is the only place `strict`
# changes anything: the guard passes strict=1 and accepts only THIS home's own
# daemon path, while fm-afk-start.sh's looser default still accepts a bare
# fm-supervise-daemon.sh command from inside the home it already runs in.
test_hook_afk_strict_rejects_bare_daemon_command() {
  local dir foreign pid out status accepted
  dir=$(make_primary_dir "$TMP_ROOT/hook-afk-strict-fallback")
  foreign="$TMP_ROOT/hook-afk-strict-fallback-foreign"
  mkdir -p "$foreign"
  printf '#!/usr/bin/env bash\nsleep 60\n' > "$foreign/fm-supervise-daemon.sh"
  chmod +x "$foreign/fm-supervise-daemon.sh"
  : > "$dir/state/task1.meta"
  : > "$dir/state/.afk"
  bash "$foreign/fm-supervise-daemon.sh" &
  pid=$!
  mkdir -p "$dir/state/.supervise-daemon.lock"
  printf '%s\n' "$pid" > "$dir/state/.supervise-daemon.lock/pid"
  out=$(run_hook "$dir" false); status=$?
  # The same pid and lock, read WITHOUT strict matching, is accepted - so the
  # rejection below can only come from strict mode, not from a dead process.
  accepted=0
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1"; . "$2"
    fm_afk_daemon_alive "$3" "$4" 0
  ' _ "$dir/bin/fm-pid-lib.sh" "$dir/bin/fm-afk-daemon-lib.sh" \
    "$dir/state/.supervise-daemon.lock" "$dir/bin/fm-supervise-daemon.sh" && accepted=1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$accepted" -eq 1 ] || fail "the loose command-line fallback should accept a bare fm-supervise-daemon.sh command"
  expect_code 2 "$status" "a bare fm-supervise-daemon.sh command must not satisfy the strict daemon check"
  assert_contains "$out" "$REQUIRED_REASON" "strict rejection must leave this home in the daemon-free case"
  case "$out" in
    *"$AFK_REASON"*) fail "strict matching must not accept a foreign daemon path: $out" ;;
  esac
  pass "fm-turnend-guard: strict matching rejects a bare fm-supervise-daemon.sh the loose fallback accepts"
}

test_hook_afk_ignores_another_homes_watcher() {
  local dir pid identity out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-afk-other-watcher")
  : > "$dir/state/task1.meta"
  : > "$dir/state/.afk"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  printf '%s\n' "$TMP_ROOT/some-other-home" > "$dir/state/.watch.lock/fm-home"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "another home's watcher must not satisfy this home's check"
  assert_contains "$out" "$REQUIRED_REASON" "a foreign watcher lock must still demand a re-arm here"
  pass "fm-turnend-guard: another home's watcher never satisfies daemon-free away mode"
}

test_predicate_healthy_no_inflight
test_predicate_unhealthy_no_beacon
test_predicate_unhealthy_stale_beacon
test_predicate_healthy_fresh_beacon
test_predicate_queue_pending_flag
test_hook_silent_when_no_work_in_flight
test_hook_blocks_when_fresh_beacon_has_no_live_lock
test_hook_blocks_when_dead_lock_has_fresh_beacon
test_hook_silent_with_live_lock_and_fresh_beacon
test_blocks_when_watcher_alive_but_no_wake_owner
test_passes_when_present_daemon_owns
test_passes_when_arm_alive
test_hook_blocks_with_live_lock_and_stale_beacon
test_hook_blocks_when_unhealthy_in_primary
test_supervision_state_free_without_lock
test_supervision_state_owned_with_live_daemon
test_supervision_state_free_with_dead_holder
test_supervision_state_free_with_dangling_lock
test_supervision_state_undetermined_without_pid
test_supervision_state_undetermined_when_probe_fails
test_hook_afk_without_daemon_silent_with_live_watcher
test_hook_afk_without_daemon_blocks_with_rearm_reason
test_hook_afk_without_daemon_fresh_beacon_message_is_consistent
test_hook_afk_with_live_daemon_keeps_daemon_reason
test_hook_afk_ignores_another_homes_daemon
test_hook_afk_strict_rejects_bare_daemon_command
test_hook_afk_ignores_another_homes_watcher
test_hook_blocks_from_fm_home_state
test_hook_x_mode_reason_sources_cadence
test_hook_ignores_repo_state_when_fm_home_set
test_hook_uses_state_override
test_hook_loop_guard_allows_retry
test_hook_blocks_in_secondmate_own_home
test_hook_silent_in_idle_secondmate_home
test_hook_secondmate_loop_guard_allows_retry
test_hook_secondmate_reinvoke_recovery_loop
test_hook_silent_in_secondmate_child_worktree
test_hook_blocks_in_treehouse_leased_secondmate_home
test_hook_exempts_linked_worktree_with_stray_marker
test_hook_exempts_linked_worktree_with_non_ascii_marker
test_hook_silent_in_crewmate_worktree
test_hook_silent_without_jq
test_hook_silent_without_stdin
test_hook_runs_fast
test_grok_adapter_forces_one_resume_when_unhealthy
test_grok_adapter_loop_guard_skips_resume
test_settings_hook_uses_claude_project_dir
test_codex_hook_invokes_shared_guard
test_codex_hook_uses_process_pwd_when_payload_cwd_is_outside_root
test_codex_hook_ignores_nested_git_root_guard
test_opencode_plugin_forces_followup
test_opencode_plugin_anchors_guard_to_worktree
test_pi_extension_forces_followup
test_pi_extension_injects_once_per_logical_agent_run
test_pi_extension_retries_after_followup_delivery_failure
test_grok_hook_invokes_adapter
