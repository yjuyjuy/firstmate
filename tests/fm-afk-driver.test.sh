#!/usr/bin/env bash
# Away-mode autonomous driver and reader-liveness regressions.
#
# Covers the 2026-07-30 overnight incident, where the away-mode daemon escalated
# correctly for 9.5 hours while nothing advanced the fleet: no finished lane was
# cleaned up, no lane stalled before its push was nudged, no unblocked ticket was
# started, and the escalation reader had died at 22:33 with nobody able to re-arm
# it. bin/fm-afk-driver.sh owns the queue advancement, bin/fm-afk-reader-check.sh
# owns the reader-liveness report, and both must stay inside firstmate's own
# away-mode authority: no merges, no forcing, no dispatch without complete
# instructions, no work beyond the worker cap.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Source fm_pid_identity once at file scope so seed_live_daemon can record the
# fake daemon's process identity by a direct call, not a per-write subshell.
# shellcheck source=bin/fm-pid-lib.sh
. "$ROOT/bin/fm-pid-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-afk-driver-tests)

# --- fixtures ---------------------------------------------------------------

# A driver case: a home with away mode active, the real driver plus the libraries
# it sources, and recording stubs for every fleet command it may call.
make_case() {  # <name> -> case dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/bin" "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin"
  cp "$ROOT/bin/fm-afk-driver.sh" "$ROOT/bin/fm-afk-reader-check.sh" \
    "$ROOT/bin/fm-afk-outbox-lib.sh" "$ROOT/bin/fm-wake-lib.sh" \
    "$ROOT/bin/fm-mutex-lib.sh" "$ROOT/bin/fm-pid-lib.sh" \
    "$ROOT/bin/fm-classify-lib.sh" "$ROOT/bin/fm-afk-daemon-lib.sh" "$dir/bin/"

  # Reconciled current state comes from one file per task, so a test states the
  # crew state it means instead of simulating a no-mistakes run.
  cat > "$dir/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
id=$1
file="$FM_STATE_OVERRIDE/$id.crewstate"
[ -r "$file" ] || { printf 'state: unknown · source: none · no record\n'; exit 0; }
printf 'state: %s · source: stub · fixture\n' "$(cat "$file")"
SH

  # Teardown records the call and behaves like the real one: it refuses when the
  # case asked it to, and otherwise releases the lane's durable records.
  cat > "$dir/bin/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
id=$1
printf '%s\n' "$*" >> "$FM_HOME/teardown.log"
if [ -e "$FM_STATE_OVERRIDE/.refuse-teardown-$id" ]; then
  printf 'refusing to tear down %s: worktree holds unpushed work\n' "$id" >&2
  exit 1
fi
rm -f "$FM_STATE_OVERRIDE/$id.meta" "$FM_STATE_OVERRIDE/$id.crewstate"
printf 'released %s\n' "$id"
SH

  cat > "$dir/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/send.log"
[ -e "$FM_STATE_OVERRIDE/.fail-send" ] && exit 1
exit 0
SH

  cat > "$dir/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/spawn.log"
if [ -e "$FM_STATE_OVERRIDE/.fail-spawn" ]; then
  printf 'spawn refused: no worktree available\n' >&2
  exit 1
fi
printf 'window=synthetic:fm-%s\nkind=ship\n' "$1" > "$FM_STATE_OVERRIDE/$1.meta"
printf 'working\n' > "$FM_STATE_OVERRIDE/$1.crewstate"
SH

  # Host reading: exit status comes from the case, defaulting to healthy.
  cat > "$dir/bin/fm-resource-check.sh" <<'SH'
#!/usr/bin/env bash
status=0
[ -r "$FM_STATE_OVERRIDE/.resource-status" ] && status=$(cat "$FM_STATE_OVERRIDE/.resource-status")
exit "$status"
SH

  # Pipeline state: `no-mistakes runs` answers from a per-case fixture so a test
  # states the run state it means, exactly like the fm-crew-state stub. The
  # fixture rows copy the real CLI format: "<status> <branch> <short-sha>
  # <date> <time> [<pr-url>]". Absent fixture means no runs at all.
  : > "$dir/home/state/.nm-runs"
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/no-mistakes.log"
[ "${1:-}" = runs ] || exit 0
[ -e "$FM_STATE_OVERRIDE/.nm-fail" ] && exit 1
[ -r "$FM_STATE_OVERRIDE/.nm-runs" ] && cat "$FM_STATE_OVERRIDE/.nm-runs"
exit 0
SH

  # Backlog backend: the ready list is whatever the case wrote.
  cat > "$dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = ready ] || exit 0
file="$FM_STATE_OVERRIDE/.ready"
[ -r "$file" ] || { printf 'count: 0\nready[0]{id,state,kind,repo,title}:\n'; exit 0; }
printf 'count: 1\nready[1]{id,state,kind,repo,title}:\n'
while IFS= read -r id; do
  [ -n "$id" ] || continue
  printf '  %s,queued,ship,alpha,Some title\n' "$id"
done < "$file"
SH

  chmod +x "$dir/bin/"*.sh "$dir/fakebin/tasks-axi" "$dir/fakebin/no-mistakes"
  : > "$dir/home/state/.afk"
  printf 'paneless\n' > "$dir/home/state/.afk-delivery"
  printf '%s\n' "$dir"
}

# The fake /proc root the scripts under test should read, empty for every ordinary
# case. Empty rather than unset is safe because fm-pid-lib.sh reads it as
# ${FM_PROC_ROOT_OVERRIDE:-/proc}, so an empty value still selects the real /proc.
# Only seed_unprobeable_daemon sets it, and each case that does gets its own
# freshly seeded value, so nothing leaks between cases. It cannot be cleared from
# make_case, which every case calls through a command substitution whose subshell
# would swallow the assignment.
FAKE_PROC=

run_driver() {  # <case-dir> [args...]
  local dir=$1
  shift
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_PROC_ROOT_OVERRIDE="$FAKE_PROC" \
    "$dir/bin/fm-afk-driver.sh" "${@:-tick}" 2>&1
}

# A finished lane: real git worktree on its own branch, meta pointing at it, and a
# reconciled done state. Pushing to the fixture origin is the caller's choice, so
# the durable and the never-pushed shapes differ only in that one fact.
seed_done_lane() {  # <case-dir> <id> <push:0|1>
  local dir=$1 id=$2 push=$3 repo="$TMP_ROOT/repos/$2" wt="$TMP_ROOT/worktrees/$2"
  mkdir -p "$TMP_ROOT/repos" "$TMP_ROOT/worktrees"
  # Origin is created BEFORE the task branch exists, so a branch reaches it only
  # by being pushed - the exact distinction the driver's durability probe makes.
  fm_git_init_commit "$repo"
  fm_git_add_origin "$repo" "$TMP_ROOT/repos/$id.git"
  git -C "$repo" worktree add --quiet -b "fm/$id" "$wt"
  if [ "$push" = 1 ]; then
    git -C "$wt" push --quiet origin "fm/$id" 2>/dev/null \
      || fail "fixture could not push fm/$id to the fixture origin"
  fi
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=synthetic:fm-$id" "worktree=$wt" "project=$repo" "kind=ship" "mode=direct-push"
  printf 'done\n' > "$dir/home/state/$id.crewstate"
}

outbox_records() {  # <case-dir>
  cat "$1/home/state/.afk-outbox" 2>/dev/null || true
}

# --- driver: cleanup of finished lanes ---------------------------------------

test_pushed_lane_is_cleaned_up_and_reported() {
  local dir out
  dir=$(make_case pushed-lane)
  seed_done_lane "$dir" alpha 1

  out=$(run_driver "$dir") || fail "the tick failed: $out"
  assert_contains "$out" "cleaned up alpha" "a finished lane whose branch is on origin was not cleaned up: $out"
  assert_grep 'alpha' "$dir/home/teardown.log" "cleanup never called the guarded teardown path"
  assert_no_grep '--force' "$dir/home/teardown.log" "cleanup forced a teardown"
  assert_contains "$(outbox_records "$dir")" "cleaned up alpha" \
    "the cleanup was not reported to the captain's catch-up"
  pass "a finished lane whose branch is durable on origin is cleaned up and reported"
}

test_unpushed_lane_is_not_torn_down_and_is_steered_once() {
  local dir out second sends
  dir=$(make_case unpushed-lane)
  seed_done_lane "$dir" beta 0

  out=$(run_driver "$dir") || fail "the tick failed: $out"
  [ ! -e "$dir/home/teardown.log" ] \
    || fail "a lane whose branch never reached origin was handed to cleanup: $(cat "$dir/home/teardown.log")"
  assert_contains "$out" "steered beta" "an unpushed finished lane was not asked to finish its push: $out"
  assert_grep 'push it and report' "$dir/home/send.log" "the steer did not ask the lane to push"
  [ -e "$dir/home/state/beta.meta" ] || fail "the driver discarded the lane's durable record"

  # Second tick over unchanged state: the steer must not be re-sent, and nothing
  # new may be reported.
  second=$(run_driver "$dir") || fail "the second tick failed: $second"
  sends=$(wc -l < "$dir/home/send.log" | tr -d ' ')
  [ "$sends" -eq 1 ] || fail "the lane was steered $sends times instead of once"
  [ "$(outbox_records "$dir" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "an unchanged second tick reported again: $(outbox_records "$dir")"
  pass "a finished lane that never pushed is steered exactly once and never torn down"
}

test_teardown_refusal_is_reported_and_never_forced() {
  local dir out
  dir=$(make_case teardown-refusal)
  seed_done_lane "$dir" gamma 1
  : > "$dir/home/state/.refuse-teardown-gamma"

  out=$(run_driver "$dir") || fail "the tick failed: $out"
  assert_contains "$out" "cleanup refused for gamma" "a refused cleanup was not reported: $out"
  assert_contains "$(outbox_records "$dir")" "cleanup refused for gamma" \
    "a refused cleanup never reached the captain's catch-up"
  assert_no_grep '--force' "$dir/home/teardown.log" "a refusal was worked around with --force"
  [ -e "$dir/home/state/gamma.meta" ] || fail "a refused cleanup still released the lane's record"
  pass "a teardown refusal is reported as a fact and never forced"
}

test_active_lane_is_left_alone() {
  local dir out
  dir=$(make_case active-lane)
  seed_done_lane "$dir" delta 1
  printf 'working\n' > "$dir/home/state/delta.crewstate"

  out=$(run_driver "$dir") || fail "the tick failed: $out"
  [ ! -e "$dir/home/teardown.log" ] || fail "a working lane was torn down"
  [ ! -e "$dir/home/send.log" ] || fail "a working lane was steered"
  pass "a lane still working is never cleaned up or steered"
}

# --- driver: active no-mistakes pipeline guard ------------------------------

# A done + pushed lane whose no-mistakes run is STILL ACTIVE and has not opened
# a PR yet is mid-delivery, not finished: the doclint two-run pass pushes the
# branch in its delivery run and only opens the PR steps later, so a branch on
# origin is not proof of durable delivery. Seeding the pipeline fixture with the
# lane's own head sha keeps the attribution deterministic.
seed_active_pipeline() {  # <case-dir> <id> <status> [--no-pr|--pr]
  local dir=$1 id=$2 status=$3 pr=$4 wt="$TMP_ROOT/worktrees/$2"
  local head
  head=$(git -C "$wt" rev-parse --short HEAD)
  if [ "$pr" = --pr ]; then
    printf '%s %s %s 2026-09-02 00:00 https://github.com/yjuyjuy/firstmate/pull/1\n' \
      "$status" "fm/$id" "$head" > "$dir/home/state/.nm-runs"
  else
    printf '%s %s %s 2026-09-02 00:00\n' \
      "$status" "fm/$id" "$head" > "$dir/home/state/.nm-runs"
  fi
}

test_done_lane_with_active_pipeline_is_never_torn_down() {
  local dir out
  dir=$(make_case active-pipeline)
  seed_done_lane "$dir" rho 1
  seed_active_pipeline "$dir" rho running --no-pr

  out=$(run_driver "$dir") || fail "the tick failed: $out"
  [ ! -e "$dir/home/teardown.log" ] \
    || fail "a lane whose no-mistakes run is still mid-delivery was torn down: $(cat "$dir/home/teardown.log")"
  assert_contains "$out" "held cleanup for rho" \
    "an active undelivered pipeline was not reported as held: $out"
  [ -e "$dir/home/state/rho.meta" ] || fail "the held lane's durable record was discarded"
  assert_contains "$(outbox_records "$dir")" "held cleanup for rho" \
    "the held cleanup was not reported to the captain's catch-up"

  # Second tick over unchanged state: the hold must not be re-reported.
  out=$(run_driver "$dir") || fail "the second tick failed: $out"
  [ "$(outbox_records "$dir" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "an unchanged second tick reported the held lane again: $(outbox_records "$dir")"
  pass "a done + pushed lane whose pipeline is still active is held, never torn down"
}

test_done_lane_with_open_pr_still_cleans_up() {
  local dir out
  dir=$(make_case pipeline-pr-open)
  seed_done_lane "$dir" sigma 1
  seed_active_pipeline "$dir" sigma running --pr

  out=$(run_driver "$dir") || fail "the tick failed: $out"
  assert_contains "$out" "cleaned up sigma" \
    "a lane whose active run already opened its PR was not cleaned up: $out"
  assert_grep 'sigma' "$dir/home/teardown.log" "cleanup never called the guarded teardown path"
  pass "a done lane whose pipeline already opened its PR cleans up exactly as before"
}

test_done_lane_with_terminal_run_still_cleans_up() {
  local dir out
  dir=$(make_case pipeline-terminal)
  seed_done_lane "$dir" tau 1
  seed_active_pipeline "$dir" tau completed --no-pr

  out=$(run_driver "$dir") || fail "the tick failed: $out"
  assert_contains "$out" "cleaned up tau" \
    "a lane whose run reached a terminal state was not cleaned up: $out"
  assert_grep 'tau' "$dir/home/teardown.log" "cleanup never called the guarded teardown path"
  pass "a done lane whose run is terminal cleans up exactly as before"
}

test_unreadable_pipeline_state_holds_cleanup() {
  local dir out
  dir=$(make_case pipeline-unreadable)
  seed_done_lane "$dir" upsilon 1
  : > "$dir/home/state/.nm-fail"

  out=$(run_driver "$dir") || fail "the tick failed: $out"
  [ ! -e "$dir/home/teardown.log" ] \
    || fail "a lane whose pipeline state could not be read was torn down: $(cat "$dir/home/teardown.log")"
  assert_contains "$out" "held cleanup for upsilon" \
    "an unreadable pipeline state was not held and reported: $out"
  pass "a pipeline state that cannot be read holds cleanup rather than risking a mid-run teardown"
}

# --- driver: dispatch --------------------------------------------------------

seed_ready_item() {  # <case-dir> <id> [--brief-complete] [--recipe]
  local dir=$1 id=$2
  shift 2
  printf '%s\n' "$id" >> "$dir/home/state/.ready"
  mkdir -p "$dir/home/data/$id"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --brief-complete)
        printf '# Task\n\nFix the thing.\n' > "$dir/home/data/$id/brief.md" ;;
      --brief-placeholder)
        printf '# Task\n\n{TASK}\n' > "$dir/home/data/$id/brief.md" ;;
      --recipe)
        mkdir -p "$dir/home/projects/alpha"
        printf 'project=projects/alpha\nharness=claude\neffort=low\n' \
          > "$dir/home/data/$id/dispatch" ;;
    esac
    shift
  done
}

test_ready_item_with_brief_and_recipe_is_started() {
  local dir out
  dir=$(make_case dispatch-ready)
  seed_ready_item "$dir" epsilon --brief-complete --recipe

  out=$(run_driver "$dir") || fail "the tick failed: $out"
  assert_contains "$out" "started epsilon" "a fully prepared ready item was not started: $out"
  assert_grep 'epsilon' "$dir/home/spawn.log" "the item was reported started without a spawn"
  assert_grep '--harness claude' "$dir/home/spawn.log" "the recorded recipe's harness was not used"
  assert_grep '--effort low' "$dir/home/spawn.log" "the recorded recipe's effort was not used"
  assert_contains "$(outbox_records "$dir")" "started epsilon" \
    "the dispatch was not reported to the captain's catch-up"
  pass "a ready item with a complete brief and a recorded recipe is started and reported"
}

test_incomplete_brief_is_never_dispatched() {
  local dir out
  dir=$(make_case dispatch-placeholder-brief)
  seed_ready_item "$dir" zeta --brief-placeholder --recipe

  out=$(run_driver "$dir") || fail "the tick failed: $out"
  [ ! -e "$dir/home/spawn.log" ] || fail "an item whose instructions were never written was started"
  assert_contains "$out" "zeta is ready to start but still needs instructions" \
    "the unwritten instructions were not reported: $out"
  pass "a ready item whose brief still holds a placeholder is reported, never dispatched"
}

test_missing_recipe_is_never_dispatched() {
  local dir out
  dir=$(make_case dispatch-no-recipe)
  seed_ready_item "$dir" eta --brief-complete

  out=$(run_driver "$dir") || fail "the tick failed: $out"
  [ ! -e "$dir/home/spawn.log" ] || fail "an item with no recorded dispatch recipe was started"
  assert_contains "$out" "has not recorded how to start it" \
    "the missing dispatch recipe was not reported: $out"
  pass "a ready item with no recorded dispatch recipe is reported, never dispatched"
}

test_dispatch_respects_the_worker_cap() {
  local dir out i
  dir=$(make_case dispatch-cap)
  for i in 1 2 3 4; do
    fm_write_meta "$dir/home/state/live$i.meta" \
      "window=synthetic:fm-live$i" "worktree=$dir/home/wt$i" "kind=ship"
    printf 'working\n' > "$dir/home/state/live$i.crewstate"
  done
  seed_ready_item "$dir" theta --brief-complete --recipe

  out=$(run_driver "$dir") || fail "the tick failed: $out"
  [ ! -e "$dir/home/spawn.log" ] || fail "the driver started work past the four-worker cap"
  assert_contains "$out" "already at its worker limit" "the held queue was not reported: $out"
  pass "dispatch stops at the worker cap and reports what is waiting"
}

test_dispatch_holds_while_the_host_is_under_pressure() {
  local dir out
  dir=$(make_case dispatch-host-pressure)
  seed_ready_item "$dir" iota --brief-complete --recipe
  printf '2\n' > "$dir/home/state/.resource-status"

  out=$(run_driver "$dir") || fail "the tick failed: $out"
  [ ! -e "$dir/home/spawn.log" ] || fail "the driver started work while the host read critical"
  assert_contains "$out" "machine is under pressure" "the host pressure was not reported: $out"
  pass "dispatch waits while the host reads degraded or critical"
}

# --- driver: idempotence and refusal ----------------------------------------

test_quiet_fleet_tick_is_a_silent_no_op() {
  local dir out
  dir=$(make_case quiet-fleet)

  out=$(run_driver "$dir") || fail "the tick failed: $out"
  [ -z "$out" ] || fail "a tick over an empty fleet reported something: $out"
  [ ! -s "$dir/home/state/.afk-outbox" ] \
    || fail "a tick over an empty fleet appended a record: $(outbox_records "$dir")"
  pass "a tick over an unchanged quiet fleet takes no action and appends no record"
}

test_second_tick_after_cleanup_is_a_no_op() {
  local dir first second
  dir=$(make_case idempotent-cleanup)
  seed_done_lane "$dir" kappa 1

  first=$(run_driver "$dir") || fail "the first tick failed: $first"
  assert_contains "$first" "cleaned up kappa" "the first tick did not clean the lane up: $first"
  second=$(run_driver "$dir") || fail "the second tick failed: $second"
  [ -z "$second" ] || fail "the second tick acted again on an already-clean fleet: $second"
  [ "$(outbox_records "$dir" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "the second tick appended another record: $(outbox_records "$dir")"
  pass "a second tick over the state the first tick produced is a no-op"
}

test_driver_refuses_when_away_mode_is_absent() {
  local dir out rc=0
  dir=$(make_case no-afk)
  seed_done_lane "$dir" lambda 1
  rm -f "$dir/home/state/.afk"

  out=$(run_driver "$dir") || rc=$?
  expect_code 3 "$rc" "the driver ran outside away mode"
  assert_contains "$out" "away mode is not active" "the refusal did not name away mode: $out"
  [ ! -e "$dir/home/teardown.log" ] || fail "a refused tick still tore a lane down"
  [ ! -s "$dir/home/state/.afk-outbox" ] || fail "a refused tick appended a record"
  pass "the driver refuses to run when away mode is not active"
}

test_dry_run_reports_without_touching_the_fleet() {
  local dir out
  dir=$(make_case dry-run)
  seed_done_lane "$dir" mu 1
  seed_ready_item "$dir" nu --brief-complete --recipe

  out=$(run_driver "$dir" tick --dry-run) || fail "the dry run failed: $out"
  assert_contains "$out" "would clean up mu" "the dry run did not report the cleanup it would do: $out"
  assert_contains "$out" "would start nu" "the dry run did not report the dispatch it would do: $out"
  [ ! -e "$dir/home/teardown.log" ] || fail "a dry run tore a lane down"
  [ ! -e "$dir/home/spawn.log" ] || fail "a dry run started work"
  [ ! -s "$dir/home/state/.afk-outbox" ] || fail "a dry run appended a record"
  pass "a dry run reports its intended actions and mutates nothing"
}

test_secondmate_home_is_never_advanced() {
  local dir out
  dir=$(make_case secondmate-untouched)
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home/second"
  printf 'done\n' > "$dir/home/state/domain.crewstate"

  out=$(run_driver "$dir") || fail "the tick failed: $out"
  [ ! -e "$dir/home/teardown.log" ] || fail "the driver retired a secondmate home"
  [ -z "$out" ] || fail "the driver acted on a secondmate: $out"
  pass "a persistent secondmate is never cleaned up or steered by the driver"
}

test_facts_from_a_stopped_tick_are_reported_by_the_next_one() {
  local dir out
  dir=$(make_case spooled-facts)
  # The shape a watchdog-stopped tick leaves behind: the actions happened, so their
  # facts are already on the durable spool, but the process never got to report.
  printf 'cleaned up omicron (branch fm/omicron durable on origin)\n' \
    > "$dir/home/state/.afk-driver-facts"

  out=$(run_driver "$dir") || fail "the tick failed: $out"
  assert_contains "$(outbox_records "$dir")" "cleaned up omicron" \
    "facts from a stopped tick never reached the captain's catch-up"
  [ ! -e "$dir/home/state/.afk-driver-facts" ] \
    || fail "the spool survived a successful report and will be reported twice"
  pass "actions a stopped tick already performed are reported by the next tick"
}

test_unreadable_lanes_still_count_against_the_cap() {
  local dir out i
  dir=$(make_case cap-unknown-lanes)
  # Three working lanes plus one whose state cannot be reconciled. The fourth may
  # still be holding a live endpoint, so the cap must count it.
  for i in 1 2 3; do
    fm_write_meta "$dir/home/state/live$i.meta" "window=synthetic:fm-live$i" "kind=ship"
    printf 'working\n' > "$dir/home/state/live$i.crewstate"
  done
  fm_write_meta "$dir/home/state/murky.meta" "window=synthetic:fm-murky" "kind=ship"
  seed_ready_item "$dir" upsilon --brief-complete --recipe

  out=$(run_driver "$dir") || fail "the tick failed: $out"
  [ ! -e "$dir/home/spawn.log" ] \
    || fail "a lane whose state could not be read was not counted against the cap"
  assert_contains "$out" "already at its worker limit" "the held queue was not reported: $out"
  pass "a lane whose state cannot be reconciled counts against the worker cap"
}

# --- reader liveness --------------------------------------------------------

# A live away-mode daemon for this home: the reader check must be able to tell
# "the writer is fine and only the reader died" from "away supervision is down",
# so the lock is held by a real live process with a recorded identity, exactly as
# the daemon lock records it.
DAEMON_SLEEPERS=()
seed_live_daemon() {  # <case-dir>
  local dir=$1 lock="$1/home/state/.supervise-daemon.lock" pid i
  sleep 120 &
  pid=$!
  DAEMON_SLEEPERS+=("$pid")
  mkdir -p "$lock"
  printf '%s\n' "$pid" > "$lock/pid"
  # Record the daemon's process identity the same way a settled daemon holds it,
  # and make the write reliable rather than best-effort. A brand-new forked
  # sleeper's /proc entry can momentarily lose a stat race under CI fork pressure,
  # so a single best-effort read truncates pid-identity to empty; the liveness
  # probe then falls back to the command line, sees a bare 'sleep 120' instead of
  # the daemon path, reads the daemon as DEAD, and the reader-check returns early
  # with no AFK_READER line - the exact intermittent failure. Retry until the
  # process has settled and the identity is non-empty (a real daemon is always
  # settled by the time reader-check runs), so the stored identity matches the
  # stable re-read the probe performs.
  i=0
  while [ "$i" -lt 50 ]; do
    if fm_pid_identity "$pid" > "$lock/pid-identity" 2>/dev/null \
      && [ -s "$lock/pid-identity" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  fail "seed_live_daemon could not record a stable daemon identity for pid $pid"
}

stop_daemon_sleepers() {
  local pid
  for pid in "${DAEMON_SLEEPERS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
  done
}
trap 'stop_daemon_sleepers; fm_test_cleanup' EXIT

run_reader_check() {  # <case-dir>
  local dir=$1
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_PROC_ROOT_OVERRIDE="$FAKE_PROC" \
    "$dir/bin/fm-afk-reader-check.sh" 2>&1
}

seed_unread_record() {  # <case-dir> <age-seconds>
  local dir=$1 age=$2
  printf '%s\t1\tescalation\tSupervisor escalate (1 event(s)): alpha.status: done: PR 7\n' \
    "$(( $(date +%s) - age ))" > "$dir/home/state/.afk-outbox"
}

test_tick_surfaces_a_dead_reader_without_consuming_records() {
  local dir out before
  dir=$(make_case tick-reader-dead)
  seed_live_daemon "$dir"
  seed_unread_record "$dir" 4000
  touch -t 197001020000 "$dir/home/state/.afk-inbox.beat"
  before=$(outbox_records "$dir")

  out=$(run_driver "$dir") || fail "the tick failed: $out"
  assert_contains "$out" "AFK_READER:" \
    "a tick found a dead escalation reader and said nothing where an operator would see it: $out"
  assert_contains "$(outbox_records "$dir")" "$before" \
    "the tick consumed or rewrote the records still waiting for the reader"
  pass "a tick surfaces a dead escalation reader on the daemon log and consumes nothing"
}

test_reader_check_reports_a_dead_reader_with_records_waiting() {
  local dir out
  dir=$(make_case reader-dead)
  seed_live_daemon "$dir"
  seed_unread_record "$dir" 4000
  # The incident's exact shape: a beacon that EXISTS but has not been stamped for
  # hours, which is a reader that died rather than one that was never armed.
  touch -t 197001020000 "$dir/home/state/.afk-inbox.beat"

  out=$(run_reader_check "$dir")
  assert_contains "$out" "AFK_READER:" "a dead reader with records waiting was not reported: $out"
  assert_contains "$out" "1 escalation record(s) are waiting" \
    "the report does not say how many records are waiting: $out"
  assert_contains "$out" "arm bin/fm-afk-inbox-arm.sh" \
    "the report does not instruct firstmate to arm the reader: $out"
  pass "a stale reader beacon with unread records is reported with the re-arm instruction"
}

test_reader_check_is_silent_for_a_live_reader() {
  local dir out
  dir=$(make_case reader-live)
  seed_live_daemon "$dir"
  seed_unread_record "$dir" 4000
  touch "$dir/home/state/.afk-inbox.beat"

  out=$(run_reader_check "$dir")
  [ -z "$out" ] || fail "a reader that is stamping its beacon was reported dead: $out"
  pass "a live reader mid-turn is never reported, however old the pending record is"
}

test_reader_check_is_silent_with_nothing_waiting() {
  local dir out
  dir=$(make_case reader-nothing-pending)
  seed_live_daemon "$dir"
  touch -t 197001020000 "$dir/home/state/.afk-inbox.beat"

  out=$(run_reader_check "$dir")
  [ -z "$out" ] || fail "an unarmed reader with an empty outbox was reported: $out"
  pass "an unarmed reader with nothing waiting for it is not an incident"
}

# Stand in for the transient /proc read failure that makes fm_pid_identity return
# non-zero for a process that is genuinely alive. A truncated stat field list is
# the exact shape the real failure takes on a loaded host, and building it from a
# fake proc root is deterministic, where racing a real fork is not.
#
# The fake proc root is published in the FAKE_PROC global rather than on stdout,
# because seed_live_daemon forks a background sleeper that inherits this
# function's stdout: a command substitution around it would hold its pipe open
# until that sleeper exits, and would also lose the sleeper's pid from the
# cleanup list, since the substitution's subshell owns the array append.
seed_unprobeable_daemon() {  # <case-dir>, sets FAKE_PROC
  local dir=$1 lock="$1/home/state/.supervise-daemon.lock" proc="$1/fakeproc" pid
  seed_live_daemon "$dir"
  pid=$(cat "$lock/pid")
  mkdir -p "$proc/$pid"
  # State char S, so fm_pid_alive - which reads the same proc root - still sees a
  # live non-zombie process. Only four fields follow the comm delimiter, so
  # fm_pid_identity's field-count guard rejects the line and returns non-zero.
  # That is exactly the shape of the failure: a LIVE daemon whose identity cannot
  # be re-derived, not a dead one.
  printf '%s (sleep) S 1 2 3\n' "$pid" > "$proc/$pid/stat"
  printf 'sleep\000120\000' > "$proc/$pid/cmdline"
  FAKE_PROC=$proc
}

# The flake this closes: on a loaded host the away-mode daemon's identity re-read
# can fail transiently for a daemon that is running, and the reader check used to
# fold that undetermined probe into "no daemon" and return SILENTLY. Silence is
# the one outcome this alarm can never afford, because a dead reader cannot
# announce itself through the channel it owns.
test_reader_check_reports_when_the_daemon_probe_cannot_complete() {
  local dir out
  dir=$(make_case reader-daemon-unprobeable)
  seed_unprobeable_daemon "$dir"
  seed_unread_record "$dir" 4000
  touch -t 197001020000 "$dir/home/state/.afk-inbox.beat"

  out=$(run_reader_check "$dir")
  assert_contains "$out" "AFK_READER:" \
    "an unreadable daemon probe silenced the reader alarm instead of reporting it: $out"
  pass "a daemon whose liveness probe cannot complete still reports a dead reader"
}

test_tick_reports_a_dead_reader_when_the_daemon_probe_cannot_complete() {
  local dir out before
  dir=$(make_case tick-daemon-unprobeable)
  seed_unprobeable_daemon "$dir"
  seed_unread_record "$dir" 4000
  touch -t 197001020000 "$dir/home/state/.afk-inbox.beat"
  before=$(outbox_records "$dir")

  out=$(run_driver "$dir") || fail "the tick failed: $out"
  assert_contains "$out" "AFK_READER:" \
    "a tick with an unreadable daemon probe said nothing about the dead reader: $out"
  assert_contains "$(outbox_records "$dir")" "$before" \
    "the tick consumed or rewrote the records still waiting for the reader"
  pass "a tick still surfaces a dead reader when the daemon probe cannot complete"
}

test_reader_check_is_silent_when_the_daemon_itself_is_gone() {
  local dir out
  dir=$(make_case reader-daemon-gone)
  seed_unread_record "$dir" 4000
  touch -t 197001020000 "$dir/home/state/.afk-inbox.beat"

  out=$(run_reader_check "$dir")
  [ -z "$out" ] || fail "a home whose away-mode daemon is gone was told to arm a reader: $out"
  pass "a home with no live away-mode daemon is left to the daemon revive sweep"
}

test_reader_check_is_silent_outside_paneless_away_mode() {
  local dir out
  dir=$(make_case reader-pane-mode)
  seed_live_daemon "$dir"
  seed_unread_record "$dir" 4000
  touch -t 197001020000 "$dir/home/state/.afk-inbox.beat"
  printf 'pane\n' > "$dir/home/state/.afk-delivery"

  out=$(run_reader_check "$dir")
  [ -z "$out" ] || fail "a pane-delivery home was told to arm a reader it does not use: $out"

  printf 'paneless\n' > "$dir/home/state/.afk-delivery"
  rm -f "$dir/home/state/.afk"
  out=$(run_reader_check "$dir")
  [ -z "$out" ] || fail "a home that is not in away mode was told to arm a reader: $out"
  pass "the reader report is limited to a paneless home that is actually in away mode"
}

test_pushed_lane_is_cleaned_up_and_reported
test_unpushed_lane_is_not_torn_down_and_is_steered_once
test_teardown_refusal_is_reported_and_never_forced
test_active_lane_is_left_alone
test_done_lane_with_active_pipeline_is_never_torn_down
test_done_lane_with_open_pr_still_cleans_up
test_done_lane_with_terminal_run_still_cleans_up
test_unreadable_pipeline_state_holds_cleanup
test_ready_item_with_brief_and_recipe_is_started
test_incomplete_brief_is_never_dispatched
test_missing_recipe_is_never_dispatched
test_dispatch_respects_the_worker_cap
test_dispatch_holds_while_the_host_is_under_pressure
test_quiet_fleet_tick_is_a_silent_no_op
test_second_tick_after_cleanup_is_a_no_op
test_driver_refuses_when_away_mode_is_absent
test_dry_run_reports_without_touching_the_fleet
test_secondmate_home_is_never_advanced
test_facts_from_a_stopped_tick_are_reported_by_the_next_one
test_unreadable_lanes_still_count_against_the_cap
test_tick_surfaces_a_dead_reader_without_consuming_records
test_reader_check_reports_a_dead_reader_with_records_waiting
test_reader_check_is_silent_for_a_live_reader
test_reader_check_is_silent_with_nothing_waiting
test_reader_check_is_silent_when_the_daemon_itself_is_gone
test_reader_check_reports_when_the_daemon_probe_cannot_complete
test_tick_reports_a_dead_reader_when_the_daemon_probe_cannot_complete
test_reader_check_is_silent_outside_paneless_away_mode
