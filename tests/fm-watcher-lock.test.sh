#!/usr/bin/env bash
# tests/fm-watcher-lock.test.sh - watcher singleton + lock-primitive races +
# PID identity stability + watch-arm liveness + guard warnings. These are
# safety-critical process invariants (a race bug may not reproduce through an
# e2e), so they stay as focused real-process units.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watcher-lock-tests)

mark_pr_check_migration_complete() {
  local state=$1
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
}


test_singleton_start() {
  local dir state fakebin out1 out2 pid1 pid2 live i
  dir=$(make_case singleton)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out1="$dir/watch-one.out"
  out2="$dir/watch-two.out"
  mark_pr_check_migration_complete "$state"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out1" &
  pid1=$!
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out2" &
  pid2=$!
  i=0
  while [ "$i" -lt 50 ]; do
    live=0
    is_live_non_zombie "$pid1" && live=$((live + 1))
    is_live_non_zombie "$pid2" && live=$((live + 1))
    [ "$live" -eq 1 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$live" -eq 1 ] || fail "expected exactly one live watcher, got $live"
  i=0
  while [ "$i" -lt 50 ] && ! grep -h 'watcher: already running pid ' "$out1" "$out2" >/dev/null 2>&1; do
    sleep 0.02
    i=$((i + 1))
  done
  grep -h 'watcher: already running pid ' "$out1" "$out2" >/dev/null || fail "second watcher did not report existing singleton"
  kill "$pid1" "$pid2" 2>/dev/null || true
  wait "$pid1" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true
  pass "simultaneous watcher starts leave exactly one live process"
}

test_stale_watch_lock_reclaimed() {
  local dir state fakebin out dead_pid pid live lock_pid i
  dir=$(make_case stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
  done
  mkdir "$state/.watch.lock"
  printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  live=0
  lock_pid=
  while [ "$i" -lt 50 ]; do
    live=0
    is_live_non_zombie "$pid" && live=1
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    [ "$live" -eq 1 ] && [ "$lock_pid" != "$dead_pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$live" -eq 1 ] || fail "watcher did not reclaim stale lock and stay alive"
  [ "$lock_pid" != "$dead_pid" ] || fail "stale watch lock pid was not replaced"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "killed watcher stale lock is reclaimed"
}

test_live_stale_watch_lock_is_actionable() {
  local dir state fakebin out err status
  dir=$(make_case live-stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  err="$dir/watch.err"
  mark_pr_check_migration_complete "$state"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  status=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err" || status=$?
  [ "$status" -ne 0 ] || fail "watcher silently no-opped behind a live stale holder"
  grep -F 'heartbeat is stale' "$err" >/dev/null || fail "watcher did not explain the stale live lock"
  pass "live watcher lock with stale heartbeat is actionable"
}

test_guard_warnings() {
  # The guard's two operator-visible states, with resilient substrings instead of
  # four copy-coupled tests:
  #   (1) watcher DOWN + queued wakes: a prominent no-watcher banner leads (alarm
  #       title, in-flight count, beacon age, fix command), the queued-wakes
  #       warning follows it, and the guidance is repair-after-drain (never the
  #       old conflicting "restart NOW first").
  #   (2) a fresh watcher and an empty queue: total silence.
  local dir state err first banner_line queue_line
  dir=$(make_case guard)
  state="$dir/state"
  err="$dir/guard.err"

  # (1) watcher down (no beacon) + two in-flight tasks + a queued wake.
  # FM_ROOT_OVERRIDE points the worktree-tangle check at a non-git dir so it stays
  # inert here; this case is about the watcher-down banner, not the tangle guard.
  # Pin Claude so the host test runner's harness ancestry cannot change this fixture.
  printf 'project=x\n' > "$state/task.meta"
  printf 'project=y\n' > "$state/task2.meta"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "guard heartbeat append failed"
  CLAUDECODE=1 PI_CODING_AGENT='' GROK_AGENT='' FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  first=$(grep -v '^[[:space:]]*$' "$err" | head -1)
  case "$first" in
    '●'*) ;;
    *) fail "no-watcher banner is not the first thing the guard prints (got '$first')" ;;
  esac
  grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$err" >/dev/null || fail "guard banner missing the alarm title"
  grep -F '2 task(s) in flight' "$err" >/dev/null || fail "guard banner missing the in-flight count"
  grep -F 'last beat: never' "$err" >/dev/null || fail "guard banner missing the beacon age"
  grep -F 'guarded operation WILL still run' "$err" >/dev/null || fail "guard banner missing generic continuation wording"
  ! grep -F 'requested message WILL still be sent' "$err" >/dev/null || fail "shared guard used send-specific continuation wording"
  grep -F 'repair missing watcher supervision' "$err" >/dev/null || fail "guard banner missing the harness-aware fix command"
  grep -F 'queued wakes pending - drain them' "$err" >/dev/null || fail "guard did not warn about pending queue"
  grep -F 'After draining queued wakes, repair missing watcher supervision' "$err" >/dev/null || fail "guard did not order supervision repair after drain"
  ! grep -F 'Restart it NOW, before anything else' "$err" >/dev/null || fail "guard still gave conflicting restart-first instruction"
  ! grep -F 'as the harness-tracked background task' "$err" >/dev/null || fail "guard still printed the old universal background-task repair text"
  banner_line=$(grep -n 'WATCHER DOWN' "$err" | head -1 | cut -d: -f1)
  queue_line=$(grep -n 'queued wakes pending - drain them' "$err" | head -1 | cut -d: -f1)
  [ "$banner_line" -lt "$queue_line" ] || fail "queued-wakes warning printed before the no-watcher banner"

  dir=$(make_case guard-xmode)
  state="$dir/state"
  err="$dir/guard.err"
  mkdir -p "$dir/config"
  printf 'project=x\n' > "$state/task.meta"
  : > "$dir/config/x-mode.env"
  CLAUDECODE=1 PI_CODING_AGENT='' GROK_AGENT='' FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  grep -F "source '$dir/config/x-mode.env' first" "$err" >/dev/null || fail "guard repair line did not source the X-mode cadence config"

  # (2) fresh watcher, empty queue -> silence.
  dir=$(make_case guard-fresh)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  touch "$state/.last-watcher-beat"
  # Non-git FM_ROOT keeps the worktree-tangle check inert so "fresh watcher ->
  # total silence" stays a pure assertion about watcher state.
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  [ ! -s "$err" ] || fail "guard warned with a fresh watcher and no queued wakes: $(cat "$err")"
  pass "guard banner leads when down with pending wakes (repair-after-drain) and stays silent when fresh"
}

test_lock_single_winner_under_concurrency() {
  local dir state lockdir marker i pids pid wins
  dir=$(make_case lock-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "$$" >> "$3"
        # Stay alive so the held lock names a live pid for the whole window;
        # otherwise a late contender could legitimately reclaim a dead-pid lock.
        sleep 1
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one lock winner under concurrency, got $wins"
  pass "concurrent fm_lock_try_acquire yields exactly one winner"
}

test_lock_steals_dead_pid_lock() {
  local dir state lockdir dead rc newpid
  dir=$(make_case lock-dead-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  rc=0
  newpid=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then cat "$2/pid"; else exit 7; fi
  ' _ "$LIB" "$lockdir") || rc=$?
  [ "$rc" -eq 0 ] || fail "acquirer failed to steal a dead-pid stale lock (rc=$rc)"
  [ "$newpid" != "$dead" ] || fail "stale dead-pid lock was not replaced (still $dead)"
  [ -n "$newpid" ] || fail "reclaimed lock has no pid recorded"
  pass "dead-pid stale lock is reclaimed by a single acquirer"
}

test_lock_stale_steal_single_winner_under_concurrency() {
  local dir state lockdir dead marker i pids pid wins
  dir=$(make_case lock-stale-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "${BASHPID:-$$}" >> "$3"
        sleep 1
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one stale-lock stealer, got $wins"
  pass "concurrent stale-lock steal yields exactly one winner"
}

test_lock_live_steal_mutex_is_not_reclaimed() {
  local dir state lockdir dead holder_file holder out i lockpid stealpid
  dir=$(make_case lock-live-stealer)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  holder_file="$dir/holder"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2.steal" || exit 7
    printf "%s\n" "${BASHPID:-$$}" > "$3"
    sleep 2
    fm_lock_release "$2.steal"
  ' _ "$LIB" "$lockdir" "$holder_file" &
  holder=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$holder_file" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$holder_file" ] || fail "live steal mutex holder did not start"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s lockpid=%s stealpid=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}" "$(cat "$2/pid" 2>/dev/null || true)" "$(cat "$2.steal/pid" 2>/dev/null || true)"
  ' _ "$LIB" "$lockdir")
  wait "$holder" || fail "live steal mutex holder failed"
  case "$out" in
    *"rc=1"*) ;;
    *) fail "stale lock was stolen while a live stealer held the mutex: $out" ;;
  esac
  lockpid=${out#*lockpid=}; lockpid=${lockpid%% *}
  stealpid=${out#*stealpid=}; stealpid=${stealpid%% *}
  [ "$lockpid" = "$dead" ] || fail "primary lock changed while live steal mutex was held: $out"
  [ "$stealpid" = "$(cat "$holder_file")" ] || fail "live steal mutex owner changed: $out"
  pass "live steal mutex is not reclaimed"
}

test_lock_does_not_steal_live_lock() {
  local dir state lockdir live out lockpid
  dir=$(make_case lock-live-noop)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  sleep 300 &
  live=$!
  mkdir "$lockdir"
  printf '%s\n' "$live" > "$lockdir/pid"
  out=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$out" in
    *"rc=1"*) ;;
    *) fail "live-held lock was acquired instead of refused: $out" ;;
  esac
  case "$out" in
    *"held=$live"*) ;;
    *) fail "live holder pid not reported via FM_LOCK_HELD_PID: $out" ;;
  esac
  lockpid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$lockpid" = "$live" ] || fail "live holder's lock pid was clobbered (got '$lockpid')"
  pass "live-held lock is not stolen"
}

test_lock_empty_pid_uses_minimum_grace() {
  local dir state lockdir out
  dir=$(make_case lock-empty-grace)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  mkdir "$lockdir"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"rc=1"*) ;;
    *) fail "empty mid-acquire lock was stolen with zero stale threshold: $out" ;;
  esac
  [ -d "$lockdir" ] || fail "empty mid-acquire lock dir was removed during grace"
  [ ! -e "$lockdir/pid" ] || fail "empty mid-acquire lock gained a pid during grace"
  pass "empty mid-acquire lock keeps a minimum grace"
}

test_lock_late_claim_loses_after_recreate() {
  local dir state lockdir out
  dir=$(make_case lock-late-claim)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner1=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner1" "$2" || exit 21
    touch -h -t 200001010000 "$2" 2>/dev/null || sleep 2
    if ! fm_lock_try_acquire "$2"; then exit 22; fi
    before=$(cat "$2/pid" 2>/dev/null || true)
    if fm_lock_claim "$2" "$owner1"; then late=won; else late=lost; fi
    after=$(cat "$2/pid" 2>/dev/null || true)
    current_owner=$(readlink "$2" 2>/dev/null || true)
    printf "late=%s before=%s after=%s owner_changed=%s\n" "$late" "$before" "$after" "$([ "$current_owner" != "$owner1" ] && echo yes || echo no)"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "late original claimant succeeded after lock recreation: $out" ;;
  esac
  case "$out" in
    *"owner_changed=yes"*) ;;
    *) fail "stale owner was not replaced before late claim: $out" ;;
  esac
  before=${out#*before=}; before=${before%% *}
  after=${out#*after=}; after=${after%% *}
  [ -n "$before" ] || fail "recreated lock did not record a pid: $out"
  [ "$before" = "$after" ] || fail "late claim changed the recreated lock pid: $out"
  pass "late original claimant cannot claim a recreated lock"
}

test_lock_paused_mid_acquire_claim_fails_during_steal() {
  local dir state lockdir out pid
  dir=$(make_case lock-paused-claim-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner" "$2" || exit 21
    fm_lock_try_acquire "$2.steal" || exit 22
    steal_owner=${FM_LOCK_OWNER_DIR:-}
    if fm_lock_claim "$2" "$owner"; then late=won; else late=lost; fi
    if fm_lock_try_create "$2" "$steal_owner"; then stealer=won; else stealer=lost; fi
    pid=$(cat "$2/pid" 2>/dev/null || true)
    printf "late=%s stealer=%s pid=%s\n" "$late" "$stealer" "$pid"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "paused claimant succeeded while steal mutex was held: $out" ;;
  esac
  case "$out" in
    *"stealer=won"*) ;;
    *) fail "stealer could not claim after paused claimant backed off: $out" ;;
  esac
  pid=${out#*pid=}; pid=${pid%% *}
  [ -n "$pid" ] || fail "stealer claim did not record a pid: $out"
  pass "paused mid-acquire claimant backs off to active stealer"
}

test_watch_restart_rejects_reused_pid() {
  local dir state fakebin out live pid i lock_pid
  dir=$(make_case restart-reused-pid)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  mark_pr_check_migration_complete "$state"
  sleep 300 &
  live=$!
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "stale watcher identity" > "$state/.watch.lock/pid-identity"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" --restart > "$out" &
  pid=$!
  # The honest arm forks the fresh watcher as a tracked child and waits on it, so
  # the lock now names that child, not the arm invocation. The property is the
  # same: the stale reused-pid lock is replaced by a genuinely live watcher, which
  # the arm confirms before reporting it. Wait for that confirmation, not just for
  # the lock pid to appear (identity and beacon land a beat later).
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  { [ -n "$lock_pid" ] && [ "$lock_pid" != "$live" ] && kill -0 "$lock_pid" 2>/dev/null; } \
    || fail "restart did not replace stale reused-pid lock with a live watcher (got '$lock_pid')"
  grep -F "watcher: started pid=$lock_pid" "$out" >/dev/null || fail "restart did not report the fresh watcher it confirmed"
  is_live_non_zombie "$live" || fail "restart killed a reused unrelated pid"
  kill "$pid" "$lock_pid" "$live" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "watch restart refuses to signal a reused pid"
}

test_watch_restart_attaches_to_healthy_peer() {
  local dir state fakebin out peer identity armpid status i
  dir=$(make_case restart-healthy-peer)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  mark_pr_check_migration_complete "$state"
  node -e 'process.on("SIGTERM", () => {}); setTimeout(() => {}, 300000)' &
  peer=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" --restart > "$out" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$peer" "$out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$peer" "$out" || fail "restart did not attach to the verified healthy peer: $(cat "$out")"
  is_live_non_zombie "$armpid" || fail "restart arm exited instead of following the healthy peer"
  is_live_non_zombie "$peer" || fail "restart killed a TERM-resistant peer unexpectedly"
  kill -KILL "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "restart arm did not fail after its attached peer ended without a successor (status $status)"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$out" || fail "restart arm did not surface the attached cycle end"
  pass "watch restart attaches to a verified healthy peer and later surfaces a successor gap"
}

test_watch_restart_force_clears_wedged_watcher() {
  local dir state fakebin out peer identity armpid i lock_pid back
  dir=$(make_case restart-wedged)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  mark_pr_check_migration_complete "$state"
  # A genuinely wedged watcher: its identity matches the lock, but it ignores
  # SIGTERM and its beacon is stale past the grace (the recovery scenario the
  # operator hit - live PID, stale beacon, TERM cannot land).
  node -e 'process.on("SIGTERM", () => {}); setTimeout(() => {}, 300000)' &
  peer=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  back=$(( $(date +%s) - 500 ))
  touch "$state/.last-watcher-beat"
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$state/.last-watcher-beat"
  else touch -m -d "@$back" "$state/.last-watcher-beat"; fi
  # Pin the grace hermetically (the ambient env may raise it well past the
  # backdated beacon age): a 500s-stale beacon with a 2s grace is unambiguously wedged.
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_GUARD_GRACE=2 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" --restart > "$out" &
  armpid=$!
  i=0
  while [ "$i" -lt 120 ]; do
    grep -qF 'watcher: started pid=' "$out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$out" || fail "restart did not start a fresh watcher after force-clearing the wedged one: $(cat "$out")"
  is_live_non_zombie "$peer" && fail "restart did not force-kill the TERM-resistant wedged watcher"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  { [ -n "$lock_pid" ] && [ "$lock_pid" != "$peer" ] && kill -0 "$lock_pid" 2>/dev/null; } \
    || fail "the lock was stranded or not taken over by a live fresh watcher (got '$lock_pid')"
  kill "$armpid" "$lock_pid" "$peer" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  pass "watch restart force-clears a wedged TERM-resistant watcher and never strands the lock"
}

test_watcher_self_evicts_on_lock_takeover() {
  local dir state fakebin out pid i lock_pid
  dir=$(make_case self-evict)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &  # integer-only cadence: a fractional poll falls back to 300s (fm-cadence-lib.sh)
  pid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] \
      && [ -s "$state/.watch.lock/pid-identity" ] \
      && [ -e "$state/.last-watcher-beat" ] \
      && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] \
    && [ -s "$state/.watch.lock/pid-identity" ] \
    && [ -e "$state/.last-watcher-beat" ] \
    || fail "watcher did not finish publishing its lock ownership"
  # Simulate a second watcher taking over the singleton lock. $$ (the test
  # runner) is a live pid that is not the watcher.
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  wait_for_exit "$pid" 60 || fail "watcher did not self-evict after lock takeover"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$$" ] || fail "self-evicting watcher clobbered the new holder's lock (got '$lock_pid')"
  pass "watcher self-evicts when the lock pid no longer names it"
}

test_arm_self_eviction_is_loud_without_successor() {
  local dir state fakebin armout armpid watcher_pid status i
  dir=$(make_case arm-self-evict)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  mark_pr_check_migration_complete "$state"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" > "$armout" &  # integer-only cadence: a fractional poll falls back to 300s (fm-cadence-lib.sh)
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$watcher_pid" "$armout" || fail "arm did not start before self-eviction check"

  # A live but identity-mismatched replacement lock makes the owned watcher
  # self-evict normally. With no verified successor, the arm must turn that
  # otherwise clean empty close into the typed nonzero failure.
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "self-evicted arm did not fail nonzero (status $status)"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" || fail "self-evicted arm omitted the typed cycle-end failure"
  grep -q "reason=unexpected-clean-exit" "$state/.watch-cycle-exits.log" || fail "self-evicted cycle was not classified in the lifecycle ledger"
  pass "arm turns clean self-eviction without a successor into a typed failure"
}

test_arm_classifies_tick_close_as_benign_completion() {
  local dir state fakebin armout armpid status
  dir=$(make_case arm-tick)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  mark_pr_check_migration_complete "$state"
  # A quiet fleet with work under way (the tick fires only then), a fast heartbeat
  # cadence, and the proof-of-life knob on: the child ends its cycle with a "tick:"
  # line only. The arm must treat that clean close as a benign completion, not as the
  # empty-cycle failure.
  printf 'window=task\n' > "$state/task.meta"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_WATCH_ABSORB_TICK=1 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 0 ] || fail "arm did not return success for a benign tick close (status $status): $(cat "$armout")"
  grep -Eq '^tick:' "$armout" || fail "arm did not print the tick line to the session: $(cat "$armout")"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm took the failure path for a benign tick close: $(cat "$armout")"
  grep -q 'reason=tick' "$state/.watch-cycle-exits.log" || fail "tick close was not recorded as reason=tick in the cycle ledger"
  pass "arm classifies a clean tick-only child close as a benign completion"

  # Negative: with the same knob on, a clean close carrying NO reason line at all must
  # still take the empty-cycle failure path, so the tick branch did not weaken the guard.
  local dir2 state2 fakebin2 armout2 armpid2 status2 i
  dir2=$(make_case arm-tick-empty-close)
  state2="$dir2/state"
  fakebin2="$dir2/fakebin"
  armout2="$dir2/arm.out"
  mark_pr_check_migration_complete "$state2"
  # integer-only cadence: a fractional poll falls back to 300s (fm-cadence-lib.sh).
  PATH="$fakebin2:$PATH" FM_STATE_OVERRIDE="$state2" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_ABSORB_TICK=1 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" > "$armout2" &
  armpid2=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout2" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$armout2" || fail "arm did not start before the empty-close check"
  printf '%s\n' "$$" > "$state2/.watch.lock/pid"
  wait_for_exit "$armpid2" 80
  status2=$?
  [ "$status2" -ne 0 ] && [ "$status2" -ne 124 ] || fail "reasonless clean close returned success with the tick knob on (status $status2)"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout2" || fail "reasonless clean close lost the typed cycle-end failure"
  ! grep -q 'reason=tick' "$state2/.watch-cycle-exits.log" || fail "reasonless clean close was misrecorded as a tick"
  pass "a clean close with no reason line still fails loudly with the tick knob on"
}

test_arm_attaches_and_waits_for_live_fresh_watcher() {
  local dir state fakebin out armout i wpid armpid status
  dir=$(make_case arm-attach)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  # A genuinely live watcher with a fresh beacon already holds the singleton.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  # Arming must attach to the existing watcher, NOT start a second one, and NOT
  # exit while the seed still holds the healthy lock.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$wpid" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm did not report attach to the live watcher"
  ! grep -qF 'watcher: started' "$armout" || fail "arm started a second watcher behind a healthy one"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm reported FAILED for a healthy watcher"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "arm disturbed the healthy watcher's lock"
  is_live_non_zombie "$armpid" || fail "arm exited while the seed watcher was still healthy"
  # After the seed dies without a successor, the attached arm must fail loudly.
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "attached arm did not fail after seed died (status $status)"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" || fail "attached arm did not emit the typed cycle-end failure"
  pass "arm attaches to a live fresh watcher and fails loudly when that cycle has no successor"
}

test_attached_arm_signal_is_recorded_in_cycle_ledger() {
  local dir state fakebin out armout i wpid armpid status
  dir=$(make_case attached-arm-signal-ledger)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$wpid" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm did not report attach before signal"
  kill -TERM "$armpid" 2>/dev/null || fail "could not signal the attached arm"
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 143 ] || fail "attached arm did not exit with TERM status (got $status)"
  grep -q "arm_pid=$armpid.*watcher_pid=$wpid.*origin=attached.*exit_code=143.*signal=TERM.*reason=arm-interrupted" "$state/.watch-cycle-exits.log" \
    || fail "attached arm signal was not recorded in the lifecycle ledger"
  is_live_non_zombie "$wpid" || fail "signaling an attached arm terminated the peer watcher"
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  pass "attached arm signals record a classified lifecycle entry"
}

# THE regression the incident's missing test would have caught: an origin=attached
# arm that never completes on a wake is exactly the wake-blind state that took
# supervision down for ~1 hour. When the followed watcher enqueues a new durable
# wake, the attached arm must COMPLETE (exit 0, wake-shaped) so the harness
# re-drives the idle model, mirroring the started path's actionable exit.
test_attached_arm_completes_on_wake() {
  local dir state fakebin out armout i wpid armpid status
  dir=$(make_case attached-arm-completes-on-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  # A genuinely live watcher with a fresh beacon already holds the singleton, with
  # long intervals so it never enqueues a wake of its own during the test.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  # The arm attaches to the live watcher and stays resident.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$wpid" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm did not report attach before the wake"
  is_live_non_zombie "$armpid" || fail "arm exited before any wake was enqueued"
  # Enqueue a NEW durable wake (bumps the monotonic queue seq). The attached arm
  # must now COMPLETE (exit 0) with the wake-shaped surfaced line - the exact
  # completion that re-drives an idle jcode/claude/grok session.
  append_wake "$state" check testkey "check: synthetic" || fail "could not enqueue the wake"
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 0 ] || fail "attached arm did not complete cleanly on a new wake (status $status): $(cat "$armout")"
  grep -qF 'watcher: attached wake surfaced' "$armout" || fail "attached arm did not emit the wake-surfaced completion line: $(cat "$armout")"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "attached arm reported FAILED for a real wake"
  grep -q "arm_pid=$armpid.*origin=attached.*reason=attached-wake-surfaced" "$state/.watch-cycle-exits.log" \
    || fail "attached-wake-surfaced row was not recorded in the lifecycle ledger"
  is_live_non_zombie "$wpid" || fail "completing the attached arm terminated the peer watcher"
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  pass "attached arm completes (exit 0, wake-shaped) the instant the followed watcher enqueues a wake"
}

# Drain-immunity: after the arm attaches, a wake enqueued and then IMMEDIATELY
# drained (queue truncated) before the arm's next poll still completes it, because
# the monotonic seq stays bumped even though the queue record is gone. This proves
# the fix reads the seq, not the queue content a drain races away - the exact race
# that would let a wake slip past a content-reading arm and hang it again.
test_attached_arm_survives_drain_race() {
  local dir state fakebin out armout i wpid armpid status
  dir=$(make_case attached-arm-drain-race)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  mark_pr_check_migration_complete "$state"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  # Attach first (the arm snapshots its baseline seq at entry), with a slow attach
  # poll so the enqueue+drain below both land before the arm's next iteration.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=2 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$wpid" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm did not report attach before the drain race"
  # Enqueue a wake (bumps seq past the arm's baseline) and drain it right away:
  # the queue file is truncated but the seq stays bumped. The arm must still
  # complete on its next poll purely from the seq.
  append_wake "$state" check testkey "check: raced" || fail "could not enqueue the raced wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "drain of the raced wake failed"
  [ ! -s "$state/.wake-queue" ] || fail "drain did not truncate the queue"
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 0 ] || fail "arm did not complete on a wake after a drain race (status $status): $(cat "$armout")"
  grep -qF 'watcher: attached wake surfaced' "$armout" || fail "arm did not surface the raced-and-drained wake: $(cat "$armout")"
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  pass "attached arm completes on a wake whose queue record was already drained (seq is drain-immune)"
}

# Negative: with NO new wake after attach, the arm must NOT busy-complete; it
# stays resident, following the healthy watcher, until a real wake or failure.
test_attached_arm_waits_when_no_wake() {
  local dir state fakebin out armout i wpid armpid
  dir=$(make_case attached-arm-waits-no-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$wpid" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm did not report attach"
  # Give it a bounded interval with no new wake: it must remain live and never
  # emit a wake-surfaced completion.
  sleep 1
  is_live_non_zombie "$armpid" || fail "attached arm spuriously completed with no new wake: $(cat "$armout")"
  ! grep -qF 'watcher: attached wake surfaced' "$armout" || fail "attached arm surfaced a wake that never happened"
  kill "$armpid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  pass "attached arm stays resident when no new wake is enqueued (no busy-complete)"
}

test_arm_starts_and_self_heals() {
  # Arming with no confirmable watcher must FORK one and confirm it live + fresh
  # before reporting 'started' - whether the lock is empty (clean start) or held
  # by a dead pid with a fresh-looking leftover beacon (self-heal). It must never
  # report 'healthy' off a dead pid. One row per pre-state, one assertion block.
  local row dir state fakebin armout armpid i lock_pid dead_pid
  for row in clean dead-pid; do
    dir=$(make_case "arm-$row")
    state="$dir/state"
    fakebin="$dir/fakebin"
    armout="$dir/arm.out"
    dead_pid=
    if [ "$row" = dead-pid ]; then
      dead_pid=999999
      while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
      mkdir "$state/.watch.lock"
      printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
      printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
      printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
      printf '%s\n' "dead watcher identity" > "$state/.watch.lock/pid-identity"
      touch "$state/.last-watcher-beat"
    fi
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
    armpid=$!
    i=0
    while [ "$i" -lt 80 ]; do
      grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
      sleep 0.1; i=$((i + 1))
    done
    grep -qF 'watcher: started pid=' "$armout" || fail "arm ($row) did not report a started watcher"
    ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm ($row) wrongly reported attached/healthy instead of starting a fresh watcher"
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    # The 'started' line prints only after the fresh watcher passed (live pid +
    # fresh beacon), so it doubles as proof the beacon was confirmed fresh.
    grep -F "watcher: started pid=$lock_pid (beacon fresh)" "$armout" >/dev/null \
      || fail "arm ($row) started line did not name the confirmed live watcher (lock '$lock_pid')"
    kill -0 "$lock_pid" 2>/dev/null || fail "arm ($row) confirmed-started watcher is not actually alive"
    [ -z "$dead_pid" ] || [ "$lock_pid" != "$dead_pid" ] || fail "arm ($row) did not replace the dead-pid lock with a live watcher"
    kill "$armpid" "$lock_pid" 2>/dev/null || true
    wait "$armpid" 2>/dev/null || true
  done
  pass "arm starts+confirms a fresh watcher on a clean lock and self-heals a dead-pid lock (never healthy off a dead pid)"
}

test_arm_hup_cleans_child_and_temp_output() {
  local dir state fakebin armout i armpid lock_pid status
  dir=$(make_case arm-hup-cleanup)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$armout" || fail "arm did not start before HUP cleanup check"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill -HUP "$armpid" 2>/dev/null || fail "could not send HUP to arm"
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 129 ] || fail "arm did not exit with HUP status (got $status)"
  i=0
  while [ "$i" -lt 80 ] && is_live_non_zombie "$lock_pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  ! is_live_non_zombie "$lock_pid" || fail "HUP cleanup left watcher child running"
  ! ls "$state"/.watch-arm-output.* >/dev/null 2>&1 || fail "HUP cleanup left temp output behind"
  pass "arm cleans child watcher and temp output on HUP"
}

test_arm_propagates_immediate_wake_before_confirmation() {
  local dir state fakebin armout drain_out check_file rc
  dir=$(make_case arm-immediate-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/7\n'
SH
  chmod 0700 "$check_file"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register immediate-wake custom check"
  rc=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=0 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" || rc=$?
  [ "$rc" -eq 0 ] || fail "arm returned non-zero for an immediate wake (status $rc): $(cat "$armout")"
  grep -F "check: $check_file: merged: https://example.test/pr/7" "$armout" >/dev/null || fail "arm did not propagate the immediate check wake"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm printed FAILED after a valid immediate wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after immediate arm wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "$check_file" | grep -F 'merged: https://example.test/pr/7' >/dev/null || fail "immediate check wake was not queued"
  pass "arm propagates an immediate watcher wake before confirmation"
}

# --- batched drain-and-arm (fm-watch-arm.sh --drain) ------------------------
# One logical supervision step must be one call: --drain folds the mandatory
# pre-arm wake drain into the arm invocation, empties the durable queue, prints
# its records, then leaves exactly one live watcher. It must never weaken the
# continuity/turn-end guard: a home with tasks in flight and no live watcher must
# still fail the turn-end guard, and once --drain arms a watcher that guard must
# pass. --drain never starts a second watcher behind a healthy one.
GUARD_TURNEND="$ROOT/bin/fm-turnend-guard.sh"

test_drain_and_arm_empties_queue_and_leaves_one_watcher() {
  local dir state fakebin armout check_file rc
  dir=$(make_case drain-and-arm)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  check_file="$state/task.check.sh"
  mark_pr_check_migration_complete "$state"
  # Seed the durable queue with a stale wake the batched call must drain, and an
  # immediate check so the armed watcher returns promptly with a real wake.
  append_wake "$state" heartbeat heartbeat heartbeat || fail "could not seed drain-and-arm queue"
  [ -s "$state/.wake-queue" ] || fail "seeded wake did not land on the queue"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/9\n'
SH
  chmod 0700 "$check_file"
  printf 'window=task\n' > "$state/task.meta"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register drain-and-arm custom check"
  rc=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$dir" FM_GUARD_GRACE=0 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH_ARM" --drain > "$armout" 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] || fail "batched drain-and-arm returned non-zero (status $rc): $(cat "$armout")"
  grep -qF '=== WAKE QUEUE (drained) ===' "$armout" || fail "batched call did not print the drained-queue header"
  grep -qF 'heartbeat' "$armout" || fail "batched call did not print the drained seed wake"
  grep -qF '=== ARM ===' "$armout" || fail "batched call did not print the arm section marker"
  grep -qF "check: $check_file: merged: https://example.test/pr/9" "$armout" || fail "batched call did not surface the armed watcher's wake"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "batched call reported FAILED for a valid arm"
  # The seed wake is gone. The queue holds only the new wake the watcher itself
  # queued on surfacing (the immediate check), never the drained heartbeat.
  ! grep -qF 'heartbeat' "$state/.wake-queue" 2>/dev/null || fail "batched drain left the seed wake on the queue"
  pass "batched drain-and-arm empties the queue, prints its records, and arms one watcher"
}

test_drain_and_arm_does_not_double_arm_behind_healthy_watcher() {
  local dir state fakebin out armout i wpid armpid status
  dir=$(make_case drain-and-arm-attach)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  mark_pr_check_migration_complete "$state"
  # A genuinely live+fresh watcher already holds the singleton lock.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  # Seed a wake so the batched call has something to drain, then arm --drain: it
  # must drain, ATTACH to the existing healthy watcher, and NOT start a second one.
  # Both processes inherit FM_HOME from the global inert FM_ROOT_OVERRIDE (set in
  # wake-helpers.sh), so the arm's healthy-watcher home match succeeds; a per-call
  # FM_ROOT_OVERRIDE here would change only the arm's FM_HOME and break attach.
  append_wake "$state" heartbeat heartbeat heartbeat || fail "could not seed attach-case queue"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" --drain > "$armout" 2>/dev/null &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$wpid" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF '=== WAKE QUEUE (drained) ===' "$armout" || fail "batched attach call did not drain first"
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "batched call did not attach to the live watcher: $(cat "$armout")"
  ! grep -qF 'watcher: started' "$armout" || fail "batched call started a second watcher behind a healthy one"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "batched call disturbed the healthy watcher's lock"
  is_live_non_zombie "$armpid" || fail "batched arm exited while the seed watcher was still healthy"
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "attached batched arm did not fail after seed died (status $status)"
  pass "batched drain-and-arm attaches to a healthy watcher instead of double-arming"
}

test_drain_and_arm_satisfies_turnend_guard_without_weakening_it() {
  local dir state fakebin armout before after i lock_pid armpid
  dir=$(make_case drain-and-arm-guard)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  mark_pr_check_migration_complete "$state"
  printf 'window=task\n' > "$state/task.meta"
  # The turn-end guard only engages inside a genuine primary home. Make this
  # fixture a valid secondmate home (marker + AGENTS.md + bin/) so the guard
  # actually runs its predicate here instead of silently no-opping as "not a
  # primary checkout", which would make the before/after assertions vacuous.
  printf 'fm-drain-guard\n' > "$dir/.fm-secondmate-home"
  printf '# fixture\n' > "$dir/AGENTS.md"
  mkdir -p "$dir/bin"
  # BEFORE: tasks in flight, no live watcher -> the turn-end guard MUST block
  # (exit 2). This proves the batched helper is not silently relaxing the guard.
  before=0
  printf '{"stop_hook_active":false}' | CLAUDECODE=1 PI_CODING_AGENT='' GROK_AGENT='' \
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$GUARD_TURNEND" >/dev/null 2>&1 || before=$?
  [ "$before" -eq 2 ] || fail "turn-end guard did not block with work in flight and no watcher (exit $before)"
  # Now batch-arm a real watcher. Long poll so it stays resident (no immediate wake).
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" --drain > "$armout" 2>/dev/null &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$armout" || fail "batched call did not start a resident watcher: $(cat "$armout")"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  # AFTER: the same guard now PASSES (exit 0) because a live watcher holds the lock.
  after=0
  printf '{"stop_hook_active":false}' | CLAUDECODE=1 PI_CODING_AGENT='' GROK_AGENT='' \
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=900 "$GUARD_TURNEND" >/dev/null 2>&1 || after=$?
  [ "$after" -eq 0 ] || fail "turn-end guard still blocked after a batched arm left a live watcher (exit $after)"
  kill "$armpid" "$lock_pid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  pass "batched drain-and-arm satisfies the turn-end guard without weakening it"
}

# --- converge: multi-watcher tangle collapse (fm-watch-arm.sh --converge) -----
# --restart can only stop the single pid recorded in the lock; --converge must
# collapse ALL of THIS home's watchers and stale arm-loops, home-scoped by
# absolute path, and leave exactly one owner. The cross-home-safety regression:
# a decoy watcher launched from a DIFFERENT absolute path (a sibling home) must
# stay ALIVE.

home_watcher_pids() {  # <bin-dir>
  bash -c '. "$1"; fm_home_watcher_pids "$2"' _ "$ROOT/bin/fm-watch-scope-lib.sh" "$1"
}

test_converge_home_scoped() {
  local dir state fakebin decoy_home armout i decoy_pid seed_pid armpid pid
  dir=$(make_case converge-home-scoped)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  # A decoy watcher for a DIFFERENT home: same script NAME, different absolute
  # path. --converge must never touch it. A stable sleep stand-in isolates the
  # cross-home-safety property from the real watcher's own exit lifecycle.
  decoy_home="$dir/decoy"
  mkdir -p "$decoy_home/bin"
  cat > "$decoy_home/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
sleep 120
SH
  chmod +x "$decoy_home/bin/fm-watch.sh"
  bash "$decoy_home/bin/fm-watch.sh" </dev/null >/dev/null 2>&1 &
  decoy_pid=$!
  disown "$decoy_pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 50 ] && ! kill -0 "$decoy_pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  is_live_non_zombie "$decoy_pid" || fail "decoy sibling-home watcher did not start"
  # Seed a genuine multi-watcher tangle for THIS home (real fm-watch.sh from
  # $ROOT/bin) plus a stale arm-loop, so converge has something to collapse.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" </dev/null >/dev/null 2>&1 &
  seed_pid=$!
  disown "$seed_pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 60 ]; do
    [ -e "$state/.watch.lock/pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  # Now collapse THIS home's tangle and arm one owner. The arm resolves its own
  # SCRIPT_DIR = $ROOT/bin, so its watchers run from $ROOT/bin/fm-watch.sh.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" --converge > "$armout" 2>/dev/null &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qE 'watcher: (started|attached) pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'converge collapsed tangle' "$armout" || fail "converge did not report collapsing the tangle: $(cat "$armout")"
  grep -qE 'watcher: (started|attached) pid=' "$armout" || fail "converge did not arm one owner: $(cat "$armout")"
  # The decoy from another absolute path MUST still be alive.
  is_live_non_zombie "$decoy_pid" || fail "converge WRONGLY killed a decoy sibling-home watcher (cross-home kill)"
  kill "$decoy_pid" "$seed_pid" "$armpid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  for pid in $(home_watcher_pids "$ROOT/bin"); do
    kill "$pid" 2>/dev/null || true
  done
  pass "converge collapses this home's tangle by absolute path and never touches a decoy sibling-home watcher"
}

test_converge_arms_from_empty() {
  local dir state fakebin armout i armpid lock_pid
  dir=$(make_case converge-from-empty)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  # No watcher running at all: --converge must simply start exactly one.
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" --converge > "$armout" 2>/dev/null &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'converge collapsed tangle' "$armout" || fail "converge-from-empty did not report the converge step: $(cat "$armout")"
  grep -qF 'watcher: started pid=' "$armout" || fail "converge-from-empty did not start a watcher: $(cat "$armout")"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill -0 "$lock_pid" 2>/dev/null || fail "converge-from-empty armed watcher is not alive"
  kill "$armpid" "$lock_pid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  pass "converge starts exactly one watcher when none is running"
}

test_arm_waits_for_peer_beacon_after_child_stands_down() {
  local dir state fakebin armout peer identity armpid status i
  dir=$(make_case arm-peer-startup-race)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  mark_pr_check_migration_complete "$state"
  sleep 300 &
  peer=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=1 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  # Synchronize on the owned child declining the live peer lock before making
  # the peer healthy. Sleeping for the same one-second budget as the arm made
  # this regression fixture race the confirmation deadline under full-suite
  # load, rather than testing the intended successor-handshake boundary.
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: already running pid $peer" "$state"/.watch-arm-output.* 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: already running pid $peer" "$state"/.watch-arm-output.* 2>/dev/null \
    || fail "arm child did not stand down behind the peer watcher"
  touch "$state/.last-watcher-beat"
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$peer" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$peer" "$armout" || fail "arm did not wait for and attach to the peer watcher: $(cat "$armout")"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm falsely reported FAILED during peer startup race"
  is_live_non_zombie "$armpid" || fail "arm exited while the peer was still healthy"
  # After the peer dies without a successor, the attached arm must fail loudly.
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "attached arm did not fail after peer died (status $status): $(cat "$armout")"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" || fail "peer-attached arm did not emit the typed cycle-end failure"
  pass "arm attaches to a peer watcher after child stands down and surfaces a missing successor"
}

test_arm_fails_loud_when_no_fresh_watcher_confirmable() {
  local dir state fakebin armout live armpid status
  dir=$(make_case arm-failed-stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  mark_pr_check_migration_complete "$state"
  sleep 300 &
  live=$!
  # A live process holds the lock but is NOT a confirmable watcher (no identity),
  # and the beacon is stale. The fresh child cannot steal a LIVE lock, so no
  # watcher can ever be confirmed - the honest answer is FAILED, not healthy.
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=3 "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for_exit "$armpid" 120
  status=$?
  [ "$status" -ne 124 ] || fail "arm never returned for an unconfirmable watcher"
  [ "$status" -ne 0 ] || fail "arm exited zero when no fresh watcher could be confirmed"
  grep -F 'watcher: FAILED' "$armout" >/dev/null || fail "arm did not print a typed FAILED line"
  ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm reported attached/healthy off a stale beacon"
  ! grep -qF 'watcher: started' "$armout" || fail "arm falsely reported started"
  is_live_non_zombie "$live" || fail "arm killed the unrelated live lock holder"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "arm reports FAILED and exits non-zero when no fresh watcher can be confirmed"
}

test_cycle_exit_ledger_links_successor_and_stays_bounded() {
  local dir state fakebin armout check_file first_arm successor_arm successor_pid i size iteration
  dir=$(make_case cycle-ledger)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/first-arm.out"
  check_file="$state/task.check.sh"
  mark_pr_check_migration_complete "$state"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'done: synthetic cycle\n'
SH
  chmod 0700 "$check_file"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register cycle-ledger check"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=0 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  first_arm=$!
  wait "$first_arm" || fail "first ledger cycle did not surface its actionable wake"
  grep -q "arm_pid=$first_arm.*reason=actionable-check.*successor=none" "$state/.watch-cycle-exits.log" \
    || fail "first ledger record omitted its actionable classification"

  rm -f "$check_file" "$state/task.check-trust"
  armout="$dir/successor-arm.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WATCH_PREDECESSOR_ARM_PID="$first_arm" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  successor_arm=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  successor_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$successor_pid" "$armout" || fail "successor ledger cycle did not start"
  grep -q "arm_pid=$first_arm.*successor=started:$successor_pid" "$state/.watch-cycle-exits.log" \
    || fail "predecessor ledger record was not linked to its verified successor"
  kill -HUP "$successor_arm" 2>/dev/null || true
  wait "$successor_arm" 2>/dev/null || true

  # Produce enough short cycles to cross a deliberately small cap. The cap is
  # applied by the arm layer itself and keeps only complete ledger records.
  iteration=0
  while [ "$iteration" -lt 6 ]; do
    armout="$dir/bounded-$iteration.out"
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WATCH_CYCLE_LOG_MAX_BYTES=1400 FM_WATCH_CYCLE_LOG_KEEP_LINES=2 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
    successor_arm=$!
    i=0
    while [ "$i" -lt 80 ]; do
      grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
      sleep 0.1
      i=$((i + 1))
    done
    grep -qF 'watcher: started pid=' "$armout" || fail "bounded ledger cycle $iteration did not start"
    kill -HUP "$successor_arm" 2>/dev/null || true
    wait "$successor_arm" 2>/dev/null || true
    iteration=$((iteration + 1))
  done
  size=$(wc -c < "$state/.watch-cycle-exits.log" | tr -d '[:space:]')
  [ "$size" -le 1400 ] || fail "cycle ledger exceeded its configured cap ($size bytes)"
  ! grep -v '^arm_pid=.*watcher_pid=.*started_at=.*ended_at=.*exit_code=.*signal=.*reason=.*beacon_age=.*lock_before=.*lock_after=.*successor=' "$state/.watch-cycle-exits.log" | grep . >/dev/null \
    || fail "bounded lifecycle ledger contains a partial or malformed record"
  pass "cycle-exit ledger links a verified successor and remains size-capped"
}

test_stopped_watcher_is_live_but_stale_then_exit_is_classified() {
  local dir state fakebin armout armpid watcher_pid i status
  dir=$(make_case stopped-watcher)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  mark_pr_check_migration_complete "$state"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$watcher_pid" "$armout" || fail "load counterfactual watcher did not start"

  kill -STOP "$watcher_pid" 2>/dev/null || fail "could not SIGSTOP watcher"
  touch -t 200001010000 "$state/.last-watcher-beat"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_alive "$2"' _ "$LIB" "$watcher_pid" \
    || fail "SIGSTOP watcher was not classified as a live pid"
  if FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_watcher_healthy "$2" "$3" 300 "$4"' _ "$LIB" "$state" "$WATCH" "$dir"; then
    fail "SIGSTOP watcher with a stale beacon was classified healthy"
  fi

  kill -CONT "$watcher_pid" 2>/dev/null || true
  kill -TERM "$watcher_pid" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "terminated stopped-watcher cycle did not surface nonzero (status $status)"
  grep -Eq 'reason=(nonzero-exit|signal-exit)' "$state/.watch-cycle-exits.log" \
    || fail "terminated watcher exit was not classified in the lifecycle ledger"
  pass "SIGSTOP distinguishes live PID from stale beacon and termination records the exit class"
}

test_pid_identity_is_locale_invariant() {
  # The portable fallback records its process identity under one locale, then
  # arm/guard/turn-end re-read it under the machine's ambient locale. ps's lstart
  # date format follows LC_TIME, so an unpinned read on a non-C locale (e.g. ko_KR)
  # would reject a genuinely live watcher. The fallback pins LC_ALL=C inside
  # fm_pid_identity, so its output must be byte-identical regardless of the caller's
  # exported LC_ALL/LC_TIME. This stays deterministic on CI even where an alternate
  # locale like ko_KR.UTF-8 is not installed (the equality then holds trivially).
  local live no_proc baseline via_lc_all via_lc_time
  sleep 300 &
  live=$!
  no_proc="$TMP_ROOT/no-proc"
  baseline=$(FM_PROC_ROOT_OVERRIDE="$no_proc" LC_ALL=C bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_all=$(FM_PROC_ROOT_OVERRIDE="$no_proc" LC_ALL=ko_KR.UTF-8 bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_time=$(FM_PROC_ROOT_OVERRIDE="$no_proc" LC_TIME=ko_KR.UTF-8 bash -c 'unset LC_ALL; . "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ -n "$baseline" ] || fail "fm_pid_identity produced no baseline identity under LC_ALL=C"
  [ "$via_lc_all" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_ALL (got '$via_lc_all', want '$baseline')"
  [ "$via_lc_time" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_TIME (got '$via_lc_time', want '$baseline')"
  pass "fm_pid_identity is locale-invariant across LC_ALL/LC_TIME"
}

write_fake_proc_identity() {
  local proc_root=$1 pid=$2 starttime=$3
  mkdir -p "$proc_root/$pid"
  printf '%s\n' "$pid (watcher ) with spaces) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 $starttime 20 21 22" > "$proc_root/$pid/stat"
  printf 'bash\0/path with spaces/fm-watch.sh\0--flag\0' > "$proc_root/$pid/cmdline"
}

test_linux_pid_identity_ignores_wall_clock_and_detects_pid_reuse() {
  local dir state proc_root pid before after_time_jump after_pid_reuse
  [ "$(uname)" = Linux ] || {
    pass "Linux process identity clock-step regression skipped on non-Linux host"
    return
  }
  dir=$(make_case linux-pid-identity)
  state="$dir/state"
  proc_root="$dir/proc"
  pid=4242
  mkdir -p "$proc_root"
  printf 'btime 1784094040\n' > "$proc_root/stat"
  write_fake_proc_identity "$proc_root" "$pid" 987654

  before=$(FM_PROC_ROOT_OVERRIDE="$proc_root" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid") \
    || fail "could not read initial fake Linux process identity"
  printf 'btime 1784094016\n' > "$proc_root/stat"
  after_time_jump=$(FM_PROC_ROOT_OVERRIDE="$proc_root" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid") \
    || fail "could not re-read fake Linux process identity after btime change"

  [ "$after_time_jump" = "$before" ] \
    || fail "Linux process identity changed with btime (before '$before', after '$after_time_jump')"
  [ "$before" = 'linux-starttime=987654 cmdline-hex=62617368002f706174682077697468207370616365732f666d2d77617463682e7368002d2d666c616700' ] \
    || fail "Linux process identity did not combine parsed starttime field 22 with the full cmdline ('$before')"
  pass "Linux process identity ignores simulated btime changes"

  write_fake_proc_identity "$proc_root" "$pid" 987655
  after_pid_reuse=$(FM_PROC_ROOT_OVERRIDE="$proc_root" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid") \
    || fail "could not read reused fake Linux pid identity"
  [ "$after_pid_reuse" != "$before" ] || fail "Linux process identity missed changed starttime for reused pid"
  pass "Linux process identity detects pid reuse"
}

# Zombie/defunct guard: a bare kill -0 succeeds on a defunct (STAT Z) process
# because its pid still exists in the table, so fm_pid_alive and holder_alive
# must read the process state and treat Z as dead. Without this a day-dead
# firstmate/jcode zombie pins the session lock READ-ONLY and wedges the
# heavy-run queue forever. Fake /proc/<pid>/stat via FM_PROC_ROOT_OVERRIDE
# rather than trying to spawn a real unreapable zombie.
LOCK_LIB="$ROOT/bin/fm-lock.sh"
PID_LIB="$ROOT/bin/fm-pid-lib.sh"

write_fake_proc_stat_state() {  # <proc_root> <pid> <state-char>
  local proc_root=$1 pid=$2 state=$3
  mkdir -p "$proc_root/$pid"
  printf '%s (jcode) %s 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22\n' \
    "$pid" "$state" > "$proc_root/$pid/stat"
}

test_pid_alive_live_dead_and_zombie() {
  local dir proc_root live_pid
  dir=$(make_case pid-alive-zombie)
  proc_root="$dir/proc"

  # A genuinely live process reads alive.
  sleep 30 &
  live_pid=$!
  fm_alive() { FM_PROC_ROOT_OVERRIDE="$1" bash -c '. "$1"; fm_pid_alive "$2"' _ "$PID_LIB" "$2"; }

  fm_alive "$proc_root" "$live_pid" \
    || fail "fm_pid_alive rejected a genuinely live pid $live_pid"

  # A non-existent pid reads dead (kill -0 fails, no /proc entry needed).
  local dead_pid=$live_pid
  kill "$live_pid" 2>/dev/null || true
  wait "$live_pid" 2>/dev/null || true
  if fm_alive "$proc_root" "$dead_pid"; then
    fail "fm_pid_alive treated a reaped pid $dead_pid as alive"
  fi

  # A defunct (STAT Z) pid: kill -0 would succeed, but fake /proc marks it Z.
  # Use our own live pid so kill -0 succeeds, then override state to Z.
  sleep 30 &
  local zpid=$!
  write_fake_proc_stat_state "$proc_root" "$zpid" Z
  if fm_alive "$proc_root" "$zpid"; then
    kill "$zpid" 2>/dev/null || true
    fail "fm_pid_alive treated a defunct STAT Z pid $zpid as alive"
  fi
  # Same pid, live state char, reads alive through the fake /proc.
  write_fake_proc_stat_state "$proc_root" "$zpid" S
  fm_alive "$proc_root" "$zpid" \
    || fail "fm_pid_alive rejected a live-state pid $zpid via fake /proc"
  kill "$zpid" 2>/dev/null || true
  wait "$zpid" 2>/dev/null || true
  pass "fm_pid_alive: live alive, reaped dead, defunct STAT Z dead"
}

test_holder_alive_treats_zombie_harness_as_dead() {
  local dir proc_root zpid livepid
  dir=$(make_case holder-alive-zombie)
  proc_root="$dir/proc"
  holder() { FM_PROC_ROOT_OVERRIDE="$proc_root" bash -c '. "$1"; holder_alive "$2"' _ "$LOCK_LIB" "$1"; }

  # A live harness-named pid (this test host runs bash; force a harness match by
  # using a real live pid whose args grep the harness regex is impractical, so
  # assert the guard directly: a Z-state pid is never a live holder even though
  # kill -0 succeeds and comm may read a harness name).
  sleep 30 &
  zpid=$!
  write_fake_proc_stat_state "$proc_root" "$zpid" Z
  if holder "$zpid"; then
    kill "$zpid" 2>/dev/null || true
    fail "holder_alive treated a defunct STAT Z pid $zpid as a live holder"
  fi
  kill "$zpid" 2>/dev/null || true
  wait "$zpid" 2>/dev/null || true

  # A non-existent pid is not a live holder.
  sleep 5 &
  livepid=$!
  kill "$livepid" 2>/dev/null || true
  wait "$livepid" 2>/dev/null || true
  if holder "$livepid"; then
    fail "holder_alive treated a reaped pid $livepid as a live holder"
  fi
  pass "holder_alive: defunct STAT Z and reaped pids are not live holders"
}

test_pid_alive_live_dead_and_zombie
test_holder_alive_treats_zombie_harness_as_dead
test_singleton_start
test_pid_identity_is_locale_invariant
test_linux_pid_identity_ignores_wall_clock_and_detects_pid_reuse
test_stale_watch_lock_reclaimed
test_live_stale_watch_lock_is_actionable
test_guard_warnings
test_lock_single_winner_under_concurrency
test_lock_steals_dead_pid_lock
test_lock_stale_steal_single_winner_under_concurrency
test_lock_live_steal_mutex_is_not_reclaimed
test_lock_does_not_steal_live_lock
test_lock_empty_pid_uses_minimum_grace
test_lock_late_claim_loses_after_recreate
test_lock_paused_mid_acquire_claim_fails_during_steal
test_watch_restart_rejects_reused_pid
test_watch_restart_attaches_to_healthy_peer
test_watch_restart_force_clears_wedged_watcher
test_watcher_self_evicts_on_lock_takeover
test_arm_self_eviction_is_loud_without_successor
test_arm_classifies_tick_close_as_benign_completion
test_arm_attaches_and_waits_for_live_fresh_watcher
test_attached_arm_signal_is_recorded_in_cycle_ledger
test_attached_arm_completes_on_wake
test_attached_arm_survives_drain_race
test_attached_arm_waits_when_no_wake
test_arm_starts_and_self_heals
test_arm_hup_cleans_child_and_temp_output
test_arm_propagates_immediate_wake_before_confirmation
test_drain_and_arm_empties_queue_and_leaves_one_watcher
test_drain_and_arm_does_not_double_arm_behind_healthy_watcher
test_drain_and_arm_satisfies_turnend_guard_without_weakening_it
test_converge_home_scoped
test_converge_arms_from_empty
test_arm_waits_for_peer_beacon_after_child_stands_down
test_arm_fails_loud_when_no_fresh_watcher_confirmable
test_cycle_exit_ledger_links_successor_and_stays_bounded
test_stopped_watcher_is_live_but_stale_then_exit_is_classified
