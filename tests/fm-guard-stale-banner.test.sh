#!/usr/bin/env bash
# Regression tests for fm-guard's stale-watcher banner deduplication.
#
# The first stale command in one FM_HOME must print the full actionable watcher
# banner.
# Repeated commands in that same stale episode should print only a concise
# reminder, while unrelated alarms such as queued wakes stay independent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-guard-stale-banner)

make_guard_case() {
  local name=$1 dir home root
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  root="$dir/root"
  mkdir -p "$home/state" "$home/config" "$root"
  fm_write_meta "$home/state/task.meta" "window=firstmate:fm-task" "kind=ship"
  printf '%s\n' "$dir"
}

case_home() {
  printf '%s/home\n' "$1"
}

case_root() {
  printf '%s/root\n' "$1"
}

run_guard_case() {
  local dir=$1
  FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

run_guard_case_read_only() {
  local dir=$1
  FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    FM_GUARD_READ_ONLY=1 \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

count_text() {
  local haystack=$1 needle=$2
  awk -v needle="$needle" 'index($0, needle) { c++ } END { print c + 0 }' <<EOF
$haystack
EOF
}

test_first_stale_call_prints_full_banner() {
  local dir out
  dir=$(make_guard_case first-stale)
  out=$(run_guard_case "$dir")
  [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first stale guard call did not print exactly one full banner: $out"
  assert_contains "$out" "Trust the emitted supervision protocol" \
    "full banner must keep the actionable watcher-repair instruction"
  assert_contains "$out" "WILL still run" \
    "full banner must keep the guarded-operation continuation line"
  pass "fm-guard stale banner: first stale call prints the full actionable banner"
}

test_repeated_same_episode_prints_reminder_only() {
  local dir out1 out2 marker lines
  dir=$(make_guard_case repeated-stale)
  out1=$(run_guard_case "$dir")
  out2=$(run_guard_case "$dir")
  [ "$(count_text "$out1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first stale call did not print the full banner: $out1"
  [ "$(count_text "$out2" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 0 ] \
    || fail "second stale call repeated the full banner: $out2"
  assert_contains "$out2" "full banner already printed this episode" \
    "second stale call did not print the concise reminder"
  marker="$(case_home "$dir")/state/.guard-watcher-stale-banner"
  assert_present "$marker" "stale banner marker was not written under the owning home"
  lines=$(awk 'END { print NR + 0 }' "$marker")
  [ "$lines" -le 1 ] || fail "stale banner marker must stay bounded to one line, got $lines"
  pass "fm-guard stale banner: repeated same-episode calls print a concise reminder only"
}

test_healthy_recovery_rearms_next_stale_episode() {
  local dir home out1 healthy out2
  dir=$(make_guard_case healthy-recovery)
  home=$(case_home "$dir")
  out1=$(run_guard_case "$dir")
  [ "$(count_text "$out1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first stale episode did not print the full banner: $out1"

  touch "$home/state/.last-watcher-beat"
  healthy=$(run_guard_case "$dir")
  [ -z "$healthy" ] || fail "guard should be silent after watcher recovery, got: $healthy"
  assert_absent "$home/state/.guard-watcher-stale-banner" \
    "healthy recovery must clear the stale-banner marker"

  rm -f "$home/state/.last-watcher-beat"
  out2=$(run_guard_case "$dir")
  [ "$(count_text "$out2" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "second stale episode did not re-print the full banner: $out2"
  pass "fm-guard stale banner: healthy recovery rearms the next stale episode"
}

test_concurrent_same_episode_prints_one_full_banner() {
  local dir out_dir i pids pid all full reminders
  dir=$(make_guard_case concurrent-stale)
  out_dir="$dir/outs"
  mkdir -p "$out_dir"
  pids=
  i=1
  while [ "$i" -le 30 ]; do
    (
      run_guard_case "$dir" > "$out_dir/$i.out" 2>&1
    ) &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || fail "concurrent guard subprocess failed"
  done
  all=$(cat "$out_dir"/*.out)
  full=$(count_text "$all" "WATCHER DOWN - SUPERVISION IS OFF")
  reminders=$(count_text "$all" "full banner already printed this episode")
  [ "$full" -eq 1 ] || fail "concurrent same-episode calls printed $full full banners"$'\n'"$all"
  [ "$reminders" -eq 29 ] || fail "concurrent same-episode calls printed $reminders reminders, expected 29"$'\n'"$all"
  pass "fm-guard stale banner: concurrent same-episode calls claim exactly one full banner"
}

test_home_isolation() {
  local dir_a dir_b out_a1 out_a2 out_b1
  dir_a=$(make_guard_case home-a)
  dir_b=$(make_guard_case home-b)
  out_a1=$(run_guard_case "$dir_a")
  out_b1=$(run_guard_case "$dir_b")
  out_a2=$(run_guard_case "$dir_a")
  [ "$(count_text "$out_a1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "home A first stale call did not print a full banner: $out_a1"
  [ "$(count_text "$out_b1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "home B first stale call was suppressed by home A: $out_b1"
  assert_contains "$out_a2" "full banner already printed this episode" \
    "home A repeated stale call did not remember its own episode"
  pass "fm-guard stale banner: deduplication is isolated per FM_HOME"
}

test_queued_wake_warning_stays_independent() {
  local dir home out1 out2
  dir=$(make_guard_case queued-wake)
  home=$(case_home "$dir")
  out1=$(run_guard_case "$dir")
  [ "$(count_text "$out1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first stale call did not print the full banner before queued wake case: $out1"
  printf 'signal: %s/state/task.status\n' "$home" > "$home/state/.wake-queue"
  out2=$(run_guard_case "$dir")
  assert_contains "$out2" "full banner already printed this episode" \
    "same-episode stale call should still print its concise reminder"
  assert_contains "$out2" "queued wakes pending" \
    "queued wake warning must not be suppressed by stale-banner deduplication"
  pass "fm-guard stale banner: queued-wake warning remains independent"
}

test_read_only_before_writable_does_not_consume_full_banner() {
  local dir home marker lock out_ro out_rw
  dir=$(make_guard_case read-only-before-writable)
  home=$(case_home "$dir")
  marker="$home/state/.guard-watcher-stale-banner"
  lock="$home/state/.guard-watcher-stale-banner.lock"

  out_ro=$(run_guard_case_read_only "$dir")
  [ "$(count_text "$out_ro" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "read-only stale call should print the advisory full banner: $out_ro"
  assert_absent "$marker" "read-only stale call must not create the stale-banner marker"
  assert_absent "$lock" "read-only stale call must not create the stale-banner lock"

  out_rw=$(run_guard_case "$dir")
  [ "$(count_text "$out_rw" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "writable stale call should still receive the full banner after read-only: $out_rw"
  assert_present "$marker" "writable stale call should claim the stale-banner marker"
  pass "fm-guard stale banner: read-only before writable does not consume full banner"
}

test_read_only_during_episode_observes_without_mutating_marker() {
  local dir home marker before after out_ro
  dir=$(make_guard_case read-only-during-episode)
  home=$(case_home "$dir")
  marker="$home/state/.guard-watcher-stale-banner"

  run_guard_case "$dir" >/dev/null
  before=$(cat "$marker")
  out_ro=$(run_guard_case_read_only "$dir")
  after=$(cat "$marker")
  assert_contains "$out_ro" "full banner already printed this episode" \
    "read-only stale call during a claimed episode should print the concise reminder"
  [ "$after" = "$before" ] || fail "read-only stale call must not update an existing marker"
  pass "fm-guard stale banner: read-only during episode observes without mutating marker"
}

test_healthy_read_only_does_not_clear_marker() {
  local dir home marker before after healthy
  dir=$(make_guard_case healthy-read-only)
  home=$(case_home "$dir")
  marker="$home/state/.guard-watcher-stale-banner"

  run_guard_case "$dir" >/dev/null
  before=$(cat "$marker")
  touch "$home/state/.last-watcher-beat"
  healthy=$(run_guard_case_read_only "$dir")
  [ -z "$healthy" ] || fail "healthy read-only guard should stay silent, got: $healthy"
  assert_present "$marker" "healthy read-only guard must not clear the stale-banner marker"
  after=$(cat "$marker")
  [ "$after" = "$before" ] || fail "healthy read-only guard must not update the marker"
  pass "fm-guard stale banner: healthy read-only does not clear marker"
}

test_read_only_never_mutates_stale_banner_state_files() {
  local dir home marker lock before after no_work
  dir=$(make_guard_case read-only-state-nonmutation)
  home=$(case_home "$dir")
  marker="$home/state/.guard-watcher-stale-banner"
  lock="$home/state/.guard-watcher-stale-banner.lock"
  printf '%s\n' "sentinel-marker" > "$marker"

  before=$(find "$home/state" -maxdepth 1 -mindepth 1 -name '.guard-watcher-stale-banner*' -print | sort)
  run_guard_case_read_only "$dir" >/dev/null
  after=$(find "$home/state" -maxdepth 1 -mindepth 1 -name '.guard-watcher-stale-banner*' -print | sort)
  [ "$after" = "$before" ] || fail "stale read-only guard changed stale-banner state files"$'\n'"before: $before"$'\n'"after: $after"
  [ "$(cat "$marker")" = "sentinel-marker" ] || fail "stale read-only guard updated the marker content"
  assert_absent "$lock" "stale read-only guard must not create the stale-banner lock"

  rm -f "$home/state/task.meta"
  no_work=$(run_guard_case_read_only "$dir")
  [ -z "$no_work" ] || fail "read-only guard with no in-flight work should stay silent, got: $no_work"
  after=$(find "$home/state" -maxdepth 1 -mindepth 1 -name '.guard-watcher-stale-banner*' -print | sort)
  [ "$after" = "$before" ] || fail "no-work read-only guard changed stale-banner state files"$'\n'"before: $before"$'\n'"after: $after"
  [ "$(cat "$marker")" = "sentinel-marker" ] || fail "no-work read-only guard updated the marker content"
  pass "fm-guard stale banner: read-only never mutates stale-banner state files"
}

# hold_afk_daemon_lock <home>: hold this home's away-mode daemon lock with a real
# live process and print its pid. The recorded pid identity is what the strict
# ownership check matches, so the holder need not be the daemon script itself.
hold_afk_daemon_lock() {
  local home=$1 pid identity
  sleep 120 >/dev/null 2>&1 &
  pid=$!
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-pid-lib.sh" "$pid") || {
    kill "$pid" 2>/dev/null || true
    return 1
  }
  mkdir -p "$home/state/.supervise-daemon.lock"
  printf '%s\n' "$pid" > "$home/state/.supervise-daemon.lock/pid"
  printf '%s\n' "$identity" > "$home/state/.supervise-daemon.lock/pid-identity"
  printf '%s\n' "$pid"
}

# A live daemon really does own supervision, so the banner keeps naming the
# daemon as the repair path and says nothing about a daemon-free away mode.
test_banner_with_live_daemon_names_the_daemon() {
  local dir home pid out
  dir=$(make_guard_case afk-live-daemon)
  home=$(case_home "$dir")
  date '+%s' > "$home/state/.afk"
  pid=$(hold_afk_daemon_lock "$home") || fail "could not hold the away-mode daemon lock"
  out=$(run_guard_case "$dir")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_contains "$out" "task(s) in flight, but no watcher has a fresh beacon" \
    "a daemon-owned home must keep the original banner situation line"
  assert_contains "$out" "load /afk and ensure the daemon is running" \
    "a daemon-owned home must keep the daemon repair line"
  assert_not_contains "$out" "away mode is on with no supervision daemon" \
    "a daemon-owned home must not claim the daemon-free away context"
  pass "fm-guard stale banner: a live daemon keeps the daemon-owned banner and repair line"
}

# Away mode with no live daemon is the away POSTURE only; the banner must say so
# and point at re-arming this session's own watcher, never at starting a daemon
# that has no pane to reach.
test_banner_without_daemon_names_the_watcher() {
  local dir home out
  dir=$(make_guard_case afk-no-daemon)
  home=$(case_home "$dir")
  date '+%s' > "$home/state/.afk"
  out=$(run_guard_case "$dir")
  assert_contains "$out" "away mode is on with no supervision daemon" \
    "a daemon-free away home must say why the daemon is not the repair path"
  assert_contains "$out" "repair missing watcher supervision" \
    "a daemon-free away home must be told to re-arm its own watcher"
  assert_not_contains "$out" "ensure the daemon is running" \
    "a daemon-free away home must not be sent to start a daemon"
  pass "fm-guard stale banner: daemon-free away mode names the watcher repair path"
}

# --- P4: wake-path ownership warn-only mirror -------------------------------
# fm-guard's fresh-watcher branch must also verify a wake path is owned. When a
# watcher is alive but NO owner exists (no present daemon, away daemon, or live
# this-home arm), it warns - but only behind a grace/dedup gate, so a sub-second
# wake-handoff gap never trips a spurious warning.

# Record a live, identity-matched, fresh-beacon watcher lock for a guard case, so
# the fresh-watcher branch (not the stale banner) runs. Echoes the watcher pid.
seed_fresh_watcher() {  # <dir>
  local dir=$1 home root pid identity
  home=$(case_home "$dir")
  root=$(case_root "$dir")
  # Redirect the placeholder's fds off the command-substitution pipe, or
  # $(seed_fresh_watcher) would block until this sleep exits.
  sleep 60 >/dev/null 2>&1 &
  pid=$!
  identity=$(FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-pid-lib.sh" "$pid")
  mkdir -p "$home/state/.watch.lock"
  printf '%s\n' "$pid" > "$home/state/.watch.lock/pid"
  printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
  printf '%s\n' "$root/bin/fm-watch.sh" > "$home/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$home/state/.watch.lock/pid-identity"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$pid"
}

# Launch a stand-in this-home arm whose cmdline carries <root>/bin/fm-watch-arm.sh
# (the absolute path fm_home_arm_pids matches, since the guard copy resolves its
# own SCRIPT_DIR to <root>/bin). Echoes the pid.
seed_fresh_arm() {  # <dir>
  local dir=$1 root arm_path pid
  root=$(case_root "$dir")
  mkdir -p "$root/bin"
  arm_path="$(cd "$root/bin" && pwd)/fm-watch-arm.sh"
  printf '#!/usr/bin/env bash\nsleep 120\n' > "$arm_path"
  chmod +x "$arm_path"
  bash "$arm_path" </dev/null >/dev/null 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  printf '%s\n' "$pid"
}

# fm-guard.sh resolves SCRIPT_DIR to its own directory, so run a copy under
# <root>/bin for the arm-path scoping to line up with seed_fresh_arm.
run_guard_case_own_bin() {  # <dir> <wake-path-grace>
  local dir=$1 grace=$2 root
  root=$(case_root "$dir")
  mkdir -p "$root/bin" "$root/docs"
  cp "$ROOT"/bin/fm-guard.sh "$root/bin/" 2>/dev/null || true
  cp "$ROOT"/bin/fm-*-lib.sh "$root/bin/" 2>/dev/null || true
  cp "$ROOT"/bin/fm-supervision-instructions.sh "$ROOT"/bin/fm-harness.sh "$root/bin/" 2>/dev/null || true
  cp -R "$ROOT/docs/supervision-protocols" "$root/docs/supervision-protocols" 2>/dev/null || true
  FM_ROOT_OVERRIDE="$root" FM_HOME="$(case_home "$dir")" FM_GUARD_GRACE=999 \
    FM_GUARD_WAKE_PATH_GRACE="$grace" "$root/bin/fm-guard.sh" 2>&1
}

test_wake_path_warns_when_watcher_alive_but_unowned() {
  local dir wpid out
  dir=$(make_guard_case wake-path-unowned)
  wpid=$(seed_fresh_watcher "$dir")
  # First call with grace 0 records the sighting and stays silent (grace); the
  # second call, now past the (zero) grace on a persistent unowned state, warns.
  run_guard_case_own_bin "$dir" 0 >/dev/null 2>&1
  out=$(run_guard_case_own_bin "$dir" 0)
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  assert_contains "$out" "WATCHER ALIVE BUT NO WAKE-PATH OWNER" \
    "a fresh watcher with a persistent unowned wake path must warn"
  pass "fm-guard: warns when a watcher is alive but no wake-path owner exists"
}

test_wake_path_silent_when_arm_alive() {
  local dir wpid apid out
  dir=$(make_guard_case wake-path-arm)
  wpid=$(seed_fresh_watcher "$dir")
  apid=$(seed_fresh_arm "$dir")
  out=$(run_guard_case_own_bin "$dir" 0)
  kill "$wpid" "$apid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  assert_not_contains "$out" "WATCHER ALIVE BUT NO WAKE-PATH OWNER" \
    "a live this-home arm owns the wake path, so no warning"
  pass "fm-guard: silent when a live this-home arm owns the wake path"
}

test_wake_path_grace_suppresses_first_sighting() {
  local dir wpid out
  dir=$(make_guard_case wake-path-grace)
  wpid=$(seed_fresh_watcher "$dir")
  # Default long grace: the FIRST observation of the unowned state only records
  # the epoch and stays silent, so a transient handoff gap never warns.
  out=$(run_guard_case_own_bin "$dir" 600)
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  assert_not_contains "$out" "WATCHER ALIVE BUT NO WAKE-PATH OWNER" \
    "the first unowned sighting within the grace window must stay silent"
  pass "fm-guard: a first unowned sighting within grace stays silent (handoff gap never warns)"
}

# --- benign-only queued-wake nag suppression --------------------------------
# The drain-first advisory ("queued wakes pending - drain them ...") is context
# noise when the ONLY pending records are benign ones firstmate has already been
# shown: a signal whose status file's current size:mtime signature still equals
# the watcher's .seen-* signature (already surfaced/absorbed) and whose last line
# is not captain-relevant. It must DROP for a benign-only queue but keep firing
# whenever any pending record is genuinely actionable (a captain-relevant status,
# an un-surfaced newer signature, or any non-signal record such as a heartbeat).

# stat_sig <file>: the size:mtime signature exactly as bin/fm-watch.sh records it
# into .seen-*, so a test-built .seen file matches what the guard reads back.
guard_test_stat_sig() {
  if [ "$(uname)" = Darwin ]; then
    stat -f '%z:%Fm' "$1" 2>/dev/null
  else
    stat -c '%s:%Y' "$1" 2>/dev/null
  fi
}

# append_wake <state> <kind> <key> <payload>: enqueue a wake record with the
# production wake library, in a subshell scoped to <state>. Local copy so this
# suite need not pull the whole wake-helpers harness.
guard_append_wake() {
  local state=$1 kind=$2 key=$3 payload=$4 lib="$ROOT/bin/fm-wake-lib.sh"
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    fm_wake_append "$2" "$3" "$4"
  ' _ "$lib" "$kind" "$key" "$payload"
}

# seed a fresh watcher beacon so the guard's stale banner stays silent and the
# only thing under test is the queued-wake nag block.
guard_seed_fresh_watcher() {  # <home>
  touch "$1/state/.last-watcher-beat"
}

# write a status file plus a MATCHING .seen-* signature (already surfaced) and
# enqueue a signal wake for it. This is the benign already-absorbed shape.
guard_seed_surfaced_signal() {  # <home> <id> <last-line>
  local home=$1 id=$2 last=$3 statusf seenf
  statusf="$home/state/$id.status"
  printf 'working: setup\n%s\n' "$last" > "$statusf"
  seenf="$home/state/.seen-$(basename "$statusf" | tr '.' '_')"
  guard_test_stat_sig "$statusf" > "$seenf"
  guard_append_wake "$home/state" signal "$id.status" "signal: $statusf" \
    || fail "could not enqueue the signal wake for $id"
}

test_benign_only_queue_drops_the_drain_nag() {
  local dir home out
  dir=$(make_guard_case benign-only-nag)
  home=$(case_home "$dir")
  guard_seed_fresh_watcher "$home"
  guard_seed_surfaced_signal "$home" task "working: still building"
  out=$(run_guard_case "$dir")
  assert_not_contains "$out" "queued wakes pending" \
    "a benign-only, already-surfaced queue must not trip the drain-first nag"
  pass "fm-guard: benign-only already-surfaced queue drops the drain-first nag"
}

test_captain_relevant_queue_still_nags() {
  local dir home out
  dir=$(make_guard_case captain-relevant-nag)
  home=$(case_home "$dir")
  guard_seed_fresh_watcher "$home"
  # Surfaced signature, but a captain-relevant last line is actionable regardless.
  guard_seed_surfaced_signal "$home" task "done: shipped"
  out=$(run_guard_case "$dir")
  assert_contains "$out" "queued wakes pending - drain them" \
    "a captain-relevant queued signal must still trip the drain-first nag"
  pass "fm-guard: a captain-relevant queued signal still nags"
}

test_unsurfaced_newer_signature_still_nags() {
  local dir home out statusf seenf
  dir=$(make_guard_case unsurfaced-nag)
  home=$(case_home "$dir")
  guard_seed_fresh_watcher "$home"
  statusf="$home/state/task.status"
  seenf="$home/state/.seen-task_status"
  # A stale .seen signature (records an OLD size) means the worker wrote a newer,
  # not-yet-surfaced line: genuinely actionable, so the nag must fire.
  printf 'working: building\n' > "$statusf"
  printf '1:1\n' > "$seenf"
  guard_append_wake "$home/state" signal task.status "signal: $statusf" \
    || fail "could not enqueue the signal wake"
  out=$(run_guard_case "$dir")
  assert_contains "$out" "queued wakes pending - drain them" \
    "a queued signal whose file changed since it was surfaced must still nag"
  pass "fm-guard: an un-surfaced newer signature still nags"
}

test_non_signal_record_still_nags() {
  local dir home out
  dir=$(make_guard_case heartbeat-nag)
  home=$(case_home "$dir")
  guard_seed_fresh_watcher "$home"
  guard_append_wake "$home/state" heartbeat heartbeat heartbeat \
    || fail "could not enqueue the heartbeat wake"
  out=$(run_guard_case "$dir")
  assert_contains "$out" "queued wakes pending - drain them" \
    "a queued heartbeat (non-signal) record must still trip the drain-first nag"
  pass "fm-guard: a non-signal queued record still nags"
}

test_mixed_queue_with_one_actionable_still_nags() {
  local dir home out
  dir=$(make_guard_case mixed-nag)
  home=$(case_home "$dir")
  guard_seed_fresh_watcher "$home"
  guard_seed_surfaced_signal "$home" task "working: still building"
  guard_seed_surfaced_signal "$home" other "done: shipped"
  out=$(run_guard_case "$dir")
  assert_contains "$out" "queued wakes pending - drain them" \
    "a queue mixing a benign and an actionable record must still nag"
  pass "fm-guard: a mixed queue with any actionable record still nags"
}

test_read_only_benign_queue_keeps_its_notice() {
  local dir home out
  dir=$(make_guard_case read-only-benign-nag)
  home=$(case_home "$dir")
  guard_seed_fresh_watcher "$home"
  guard_seed_surfaced_signal "$home" task "working: still building"
  out=$(run_guard_case_read_only "$dir")
  assert_contains "$out" "queued wakes pending - left untouched for the session holding the fleet lock" \
    "a read-only session must still report a benign queue to the lock holder"
  pass "fm-guard: a read-only session keeps its queued-wake notice even for a benign queue"
}

test_first_stale_call_prints_full_banner
test_repeated_same_episode_prints_reminder_only
test_healthy_recovery_rearms_next_stale_episode
test_concurrent_same_episode_prints_one_full_banner
test_home_isolation
test_queued_wake_warning_stays_independent
test_read_only_before_writable_does_not_consume_full_banner
test_read_only_during_episode_observes_without_mutating_marker
test_healthy_read_only_does_not_clear_marker
test_read_only_never_mutates_stale_banner_state_files
test_banner_with_live_daemon_names_the_daemon
test_banner_without_daemon_names_the_watcher
test_wake_path_warns_when_watcher_alive_but_unowned
test_wake_path_silent_when_arm_alive
test_wake_path_grace_suppresses_first_sighting
test_benign_only_queue_drops_the_drain_nag
test_captain_relevant_queue_still_nags
test_unsurfaced_newer_signature_still_nags
test_non_signal_record_still_nags
test_mixed_queue_with_one_actionable_still_nags
test_read_only_benign_queue_keeps_its_notice
