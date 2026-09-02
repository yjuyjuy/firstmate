#!/usr/bin/env bash
# tests/fm-hourly-passes.test.sh - behavior tests for the two session-lifetime
# hourly passes: the session review (bin/fm-session-review.sh), the cleanup
# sweep (bin/fm-cleanup-sweep.sh), their shared arming/cadence contract
# (bin/fm-hourly-lib.sh), and the watcher wiring that runs them.
#
# Coverage:
#   - a clean home is SILENT: both passes print nothing worth waking for
#   - the review reports only things that have not moved: an aging open
#     decision, a silent worker, queued work with nothing running, a batch of
#     unmerged branches
#   - suppression: a finding surfaces once and stays silent while unchanged, a
#     new finding surfaces, and an emptied finding set re-arms silently
#   - the cleanup sweep RECLAIMS only bookkeeping (watcher temp residue, dead
#     suppression markers with nothing in flight) and REPORTS without removing
#     anything that could hold unlanded work
#   - report 1 consults the treehouse pool itself: a slot treehouse reports
#     `available` is pool inventory and is never read as an orphan, while a
#     non-available slot with no task meta still is; with no treehouse signal,
#     a conservative git proxy keeps a clean detached-at-default-tip slot
#     quiet and still flags one that turned dirty
#   - an open decision ages from when it opened, so a later unrelated status
#     append cannot reset its clock, and a blocked or held queue item is never
#     counted as idle dispatch capacity
#   - suppression markers survive while work IS in flight, including for a task
#     whose id or window carries a glob character
#   - fm-session-start.sh arms both passes when it holds the lock and skips
#     arming on the read-only path
#   - the real watcher runs a due pass, wakes once with a "check: session-*"
#     record, and exits - no second supervision cycle, no background process
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REVIEW="$ROOT/bin/fm-session-review.sh"
CLEANUP="$ROOT/bin/fm-cleanup-sweep.sh"
WATCH="$ROOT/bin/fm-watch.sh"
SESSION_START="$ROOT/bin/fm-session-start.sh"
TMP_ROOT=$(fm_test_tmproot fm-hourly-passes-tests)
fm_git_identity fmtest fmtest@example.invalid

# new_home <name>: a bare FM_HOME with state/, data/, projects/.
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/projects"
  printf '%s' "$home"
}

run_review() {  # <home> [extra env...]
  local home=$1
  shift
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$@" "$REVIEW"
}

run_cleanup() {  # <home> [extra env...]
  local home=$1
  shift
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$@" "$CLEANUP"
}

# mtime_of <path>: epoch seconds.
mtime_of() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"
}

# make_fake_ps_claude <fakebin>: bin/fm-lock.sh's harness_pid() walks `ps`
# ancestry looking for a harness command name. CI runners have no harness in
# the test shell's ancestry, so lock acquisition (fm-lock.sh acquire) fails
# with "cannot locate harness process in ancestry" and fm-session-start.sh
# falls into read-only mode, which never arms the hourly passes. This fake
# reports EVERY queried pid as a live `claude` harness so the very first
# ancestry query matches and lock acquisition succeeds deterministically.
# Mirrors fm-session-start.test.sh's make_fake_ps_claude.
make_fake_ps_claude() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"comm="*) printf '/usr/local/bin/claude\n'; exit 0 ;;
  *"args="*) printf 'claude\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

# backdate <path> <seconds>: age a file or directory by <seconds>.
backdate() {
  local path=$1 secs=$2 stamp
  stamp=$(date -r $(( $(date +%s) - secs )) '+%Y%m%d%H%M.%S' 2>/dev/null) \
    || stamp=$(date -d "@$(( $(date +%s) - secs ))" '+%Y%m%d%H%M.%S')
  touch -t "$stamp" "$path"
}

# new_pool_fixture <home> <name>: a clone plus one old detached pool-style slot
# (clean, at the clone's default-branch tip, no task meta). Prints "<clone> <slot>".
new_pool_fixture() {
  local home=$1 name=$2 clone slot
  clone="$home/projects/$name"
  git init -q -b main "$clone"
  git -C "$clone" commit -q --allow-empty -m init
  slot="$TMP_ROOT/$name-pool-1/slot"
  mkdir -p "$(dirname "$slot")"
  git -C "$clone" worktree add -q --detach "$slot" HEAD
  backdate "$slot" 200000
  printf '%s %s' "$clone" "$slot"
}

# fake_treehouse <dir> <slot> <status>: a treehouse binary that answers
# `status --json` with one slot in the real treehouse v2 JSON record shape.
fake_treehouse() {
  local dir=$1 slot=$2 status=$3
  mkdir -p "$dir"
  cat > "$dir/treehouse" <<EOF
#!/usr/bin/env bash
set -u
[ "\${1:-}" = status ] || exit 0
printf '%s\n' "[{\"name\":\"1\",\"path\":\"$slot\",\"status\":\"$status\",\"lease_id\":\"\",\"lease_holder\":\"\",\"leased_at\":null,\"processes\":[]}]"
EOF
  chmod +x "$dir/treehouse"
}

# fake_treehouse_broken <dir>: a treehouse binary that always fails, so the
# sweep must fall back to its git-side proxy for the clone.
fake_treehouse_broken() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/treehouse" <<'SH'
#!/usr/bin/env bash
exit 3
SH
  chmod +x "$dir/treehouse"
}

# --- review: silence on a healthy home ---------------------------------------
t_review_silent_when_clean() {
  local home out
  home=$(new_home review-clean)
  out=$(run_review "$home")
  [ -z "$out" ] || fail "review must be silent on a clean home, got: $out"
  assert_present "$home/state/.hourly-review.latest" "review must still write its report file"
  assert_grep "no findings" "$home/state/.hourly-review.latest" "clean report must say so in the file, not on stdout"
  pass "review is silent on a clean home but still records a report"
}

# --- review: an open decision nobody has answered -----------------------------
t_review_aging_decision() {
  local home out
  home=$(new_home review-decision)
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "kind=ship"
  printf 'working: started\nneeds-decision: pick the delivery mode\n' > "$home/state/alpha.status"
  backdate "$home/state/alpha.status" 7200

  out=$(run_review "$home")
  assert_contains "$out" "alpha waiting on a decision" "an aging open decision must surface"
  assert_grep "pick the delivery mode" "$home/state/.hourly-review.latest" "the report must carry the decision text"

  # Unchanged an hour later: silent.
  out=$(run_review "$home")
  [ -z "$out" ] || fail "an unchanged finding must not surface again, got: $out"

  # Answered: silent, and the marker is cleared so a later decision surfaces.
  printf 'resolved: delivery mode chosen\n' >> "$home/state/alpha.status"
  out=$(run_review "$home")
  [ -z "$out" ] || fail "an answered decision must not surface, got: $out"
  assert_absent "$home/state/.hourly-review-surfaced" "an empty finding set must re-arm the marker"
  pass "review surfaces an aging decision once, then stays silent until it changes"
}

# --- review: a worker that has gone quiet -------------------------------------
t_review_silent_worker() {
  local home out
  home=$(new_home review-stall)
  fm_write_meta "$home/state/beta.meta" "window=firstmate:fm-beta" "kind=ship"
  printf 'working: implementing\n' > "$home/state/beta.status"
  backdate "$home/state/beta.status" 10800

  out=$(run_review "$home")
  assert_contains "$out" "beta silent for" "a worker with no status event for hours must surface"

  # A fresh event clears it.
  printf 'working: still going\n' >> "$home/state/beta.status"
  out=$(run_review "$home")
  [ -z "$out" ] || fail "a worker that reported again must not surface, got: $out"
  pass "review surfaces a long-silent worker and drops it once it reports"
}

# --- review: queued work with nothing running ---------------------------------
t_review_idle_capacity() {
  local home out
  home=$(new_home review-idle)
  cat > "$home/data/backlog.md" <<'MD'
## In flight

## Queued

- one - first queued item
- two - second queued item

## Done
MD
  out=$(run_review "$home")
  assert_contains "$out" "nothing under way with 2 queued" "queued work with no worker must surface"

  fm_write_meta "$home/state/gamma.meta" "window=firstmate:fm-gamma" "kind=ship"
  out=$(run_review "$home")
  [ -z "$out" ] || fail "with work under way the idle-capacity finding must clear, got: $out"
  pass "review surfaces queued work with nothing running"
}

# --- review: a batch of finished-but-unmerged branches ------------------------
t_review_merge_batch() {
  local home out i
  home=$(new_home review-merge)
  : > "$home/data/merge-queue.tsv"
  for i in 1 2 3; do
    printf 'task%s\tproj\tfm/branch%s\tdeadbeef\tmain\thttps://example.test/compare/%s\n' \
      "$i" "$i" "$i" >> "$home/data/merge-queue.tsv"
  done
  out=$(run_review "$home")
  assert_contains "$out" "finished branches waiting to merge" "an accumulated merge batch must surface"
  pass "review surfaces an accumulated batch of unmerged branches"
}

# --- cleanup: silent reclaim of bookkeeping -----------------------------------
t_cleanup_reclaims_quietly() {
  local home out
  home=$(new_home cleanup-reclaim)
  : > "$home/state/.fm-check-output.abc123"
  backdate "$home/state/.fm-check-output.abc123" 7200
  : > "$home/state/.seen-gone_status"
  backdate "$home/state/.seen-gone_status" 200000

  out=$(run_cleanup "$home")
  [ -z "$out" ] || fail "reclaiming bookkeeping is not captain-facing, expected silence, got: $out"
  assert_absent "$home/state/.fm-check-output.abc123" "stale watcher temp residue must be reclaimed"
  assert_absent "$home/state/.seen-gone_status" "a dead suppression marker must be reclaimed with nothing in flight"
  assert_grep "removed stale watcher temp file" "$home/state/.hourly-cleanup.log" "reclaim actions must be logged"
  pass "cleanup reclaims bookkeeping silently and logs what it did"
}

# --- cleanup: markers survive while work is in flight -------------------------
t_cleanup_keeps_markers_in_flight() {
  local home out
  home=$(new_home cleanup-inflight)
  fm_write_meta "$home/state/delta.meta" "window=firstmate:fm-delta" "kind=ship"
  : > "$home/state/.hash-firstmate_fm-delta"
  backdate "$home/state/.hash-firstmate_fm-delta" 200000

  out=$(run_cleanup "$home")
  [ -z "$out" ] || fail "expected silence, got: $out"
  assert_present "$home/state/.hash-firstmate_fm-delta" "suppression markers must survive while work is in flight"
  pass "cleanup leaves suppression markers alone while work is under way"
}

# --- cleanup: reports orphan copies, removes nothing ---------------------------
t_cleanup_reports_orphan_worktree() {
  local home clone wt out
  home=$(new_home cleanup-orphan)
  clone="$home/projects/alpha"
  git init -q -b main "$clone"
  git -C "$clone" commit -q --allow-empty -m init
  wt="$TMP_ROOT/cleanup-orphan-wt"
  git -C "$clone" worktree add -q -b fm/orphan "$wt" >/dev/null 2>&1
  backdate "$wt" 200000

  out=$(run_cleanup "$home")
  assert_contains "$out" "outlived its task" "an orphan isolated copy must be reported"
  assert_contains "$out" "nothing was removed" "the headline must say nothing was removed"
  assert_present "$wt" "cleanup must never remove an isolated copy itself"
  assert_grep "bin/fm-teardown.sh" "$home/state/.hourly-cleanup.latest" "the report must point at the owner of the landed-work test"

  out=$(run_cleanup "$home")
  [ -z "$out" ] || fail "an unchanged cleanup candidate must not surface again, got: $out"
  pass "cleanup reports an orphan copy once and never removes it"
}

# --- cleanup: an available treehouse pool slot is inventory, never an orphan ---
# The pool's own status is authoritative: a slot treehouse reports `available`
# (clean, idle, at the reset target) is pool inventory with no task meta by
# definition, so report 1 must not read it as a leftover task copy.
t_cleanup_skips_available_pool_slot() {
  local home out clone slot
  home=$(new_home cleanup-pool-available)
  read -r clone slot <<EOF
$(new_pool_fixture "$home" alpha)
EOF
  fake_treehouse "$TMP_ROOT/cleanup-pool-available-bin" "$slot" available

  out=$(run_cleanup "$home" PATH="$TMP_ROOT/cleanup-pool-available-bin:$PATH")
  [ -z "$out" ] || fail "an available treehouse pool slot is pool inventory, not an orphan, got: $out"
  assert_grep "no candidates" "$home/state/.hourly-cleanup.latest" "the report must not list the available slot"
  assert_present "$slot" "cleanup must never remove a pool slot"
  pass "cleanup skips a treehouse pool slot reported available"
}

# --- cleanup: a NON-available pool slot with no meta is still a real orphan ----
t_cleanup_still_flags_non_available_pool_slot() {
  local home out clone slot
  home=$(new_home cleanup-pool-dirty)
  read -r clone slot <<EOF
$(new_pool_fixture "$home" beta)
EOF
  fake_treehouse "$TMP_ROOT/cleanup-pool-dirty-bin" "$slot" dirty

  out=$(run_cleanup "$home" PATH="$TMP_ROOT/cleanup-pool-dirty-bin:$PATH")
  assert_contains "$out" "outlived its task" "a dirty pool slot with no task meta must still be reported as an orphan"
  assert_present "$slot" "cleanup must never remove it itself"
  pass "cleanup still flags a pool slot treehouse does not report available"
}

# --- cleanup: no treehouse signal, a pool-like slot stays quiet -----------------
# When `treehouse status` cannot answer, report 1 falls back to a conservative
# git proxy that mirrors treehouse's own notion of available: clean, detached,
# at the default tip. A slot that looks exactly like that is not spammed.
t_cleanup_fallback_suppresses_pool_like_slot() {
  local home out clone slot
  home=$(new_home cleanup-pool-fallback)
  read -r clone slot <<EOF
$(new_pool_fixture "$home" gamma)
EOF
  fake_treehouse_broken "$TMP_ROOT/cleanup-pool-fallback-bin"

  out=$(run_cleanup "$home" PATH="$TMP_ROOT/cleanup-pool-fallback-bin:$PATH")
  [ -z "$out" ] || fail "a clean detached slot at the default tip is pool inventory even without a treehouse signal, got: $out"
  assert_present "$slot" "cleanup must never remove a pool slot"
  pass "cleanup's fallback keeps a clean detached pool-like slot quiet"
}

# --- cleanup: the fallback still flags a slot that holds unlanded work ---------
# Same fixture as above, but the slot is now dirty: unlanded work makes it a
# real orphan, and the fallback must keep flagging it after the first silent
# (clean) run.
t_cleanup_fallback_still_flags_dirty_slot() {
  local home out clone slot
  home=$(new_home cleanup-pool-fallback-dirty)
  read -r clone slot <<EOF
$(new_pool_fixture "$home" delta)
EOF
  fake_treehouse_broken "$TMP_ROOT/cleanup-pool-fallback-dirty-bin"

  out=$(run_cleanup "$home" PATH="$TMP_ROOT/cleanup-pool-fallback-dirty-bin:$PATH")
  [ -z "$out" ] || fail "a clean detached slot must stay quiet before it turns dirty, got: $out"

  printf 'unlanded\n' > "$slot/junk.txt"
  # The new entry refreshed the slot directory's mtime, so re-age it or the
  # age gate hides the finding.
  backdate "$slot" 200000
  out=$(run_cleanup "$home" PATH="$TMP_ROOT/cleanup-pool-fallback-dirty-bin:$PATH")
  assert_contains "$out" "outlived its task" "a dirty slot can hold unlanded work, so the fallback must flag it"
  pass "cleanup's fallback still flags a slot that became dirty"
}

# --- cleanup: a project clone is never written to -------------------------------
# The merged test in the merge queue fetches into a clone, so an unattended poll
# must not sweep it: the sweep stays firstmate's own action.
t_cleanup_never_sweeps_merge_queue() {
  local home out i
  home=$(new_home cleanup-mergequeue)
  for i in 1 2 3; do
    printf 'task%s\tproj\tfm/branch%s\tdeadbeef\tmain\thttps://example.test/compare/%s\n' \
      "$i" "$i" "$i" >> "$home/data/merge-queue.tsv"
  done
  out=$(run_cleanup "$home")
  [ -z "$out" ] || fail "expected silence, got: $out"
  assert_grep "task1" "$home/data/merge-queue.tsv" "the cleanup pass must leave the merge queue alone"
  assert_no_grep 'fm-merge-queue.sh" sweep' "$ROOT/bin/fm-cleanup-sweep.sh" "the cleanup pass must never run a merge-queue sweep"
  pass "cleanup never sweeps the merge queue, so it never fetches into a clone"
}

# --- a persistent secondmate is idle by contract --------------------------------
t_secondmate_is_not_work_under_way() {
  local home out
  home=$(new_home secondmate-idle)
  fm_write_meta "$home/state/sm.meta" "window=firstmate:fm-sm" "kind=secondmate"
  printf 'working: standing by\n' > "$home/state/sm.status"
  backdate "$home/state/sm.status" 200000
  cat > "$home/data/backlog.md" <<'MD'
## Queued

- one - first queued item
MD

  out=$(run_review "$home")
  assert_not_contains "$out" "silent for" "an idle secondmate must never read as a stalled worker"
  assert_contains "$out" "nothing under way with 1 queued" "an idle secondmate must not count as work under way"

  : > "$home/state/.seen-gone_status"
  backdate "$home/state/.seen-gone_status" 200000
  out=$(run_cleanup "$home")
  assert_absent "$home/state/.seen-gone_status" "a registered secondmate must not disable dead-marker reclaim"
  assert_present "$home/state/sm.meta" "the secondmate's own record is untouched"
  pass "a persistent secondmate is neither work under way nor a stall"
}

# --- a worker that wedged before its first status line --------------------------
t_review_stall_without_status_file() {
  local home out
  home=$(new_home review-nostatus)
  fm_write_meta "$home/state/theta.meta" "window=firstmate:fm-theta" "kind=ship"
  backdate "$home/state/theta.meta" 10800

  out=$(run_review "$home")
  assert_contains "$out" "theta silent for" "a worker that never wrote a status line must still surface"
  pass "review sees a worker that wedged before its first status line"
}

# --- a decision is aged from when it opened, not from the last status write -----
t_review_decision_age_survives_later_append() {
  local home out
  home=$(new_home review-decision-age)
  fm_write_meta "$home/state/iota.meta" "window=firstmate:fm-iota" "kind=ship"
  printf 'needs-decision: pick the delivery mode\n' > "$home/state/iota.status"
  backdate "$home/state/iota.status" 7200

  out=$(run_review "$home")
  assert_contains "$out" "iota waiting on a decision" "the aging decision must surface first"
  rm -f "$home/state/.hourly-review-surfaced"

  # An unrelated later event must NOT reset the decision's clock.
  printf 'working: still on it\n' >> "$home/state/iota.status"
  out=$(run_review "$home")
  assert_contains "$out" "iota waiting on a decision" \
    "a later unrelated status append must not reset an open decision's age"

  # Resolving it clears the first-seen record, so a new decision ages afresh.
  printf 'resolved: delivery mode chosen\n' >> "$home/state/iota.status"
  out=$(run_review "$home")
  [ -z "$out" ] || fail "a resolved decision must not surface, got: $out"
  printf 'needs-decision: a brand new question\n' >> "$home/state/iota.status"
  out=$(run_review "$home")
  [ -z "$out" ] || fail "a decision opened just now is not yet aging, got: $out"
  pass "an open decision ages from when it opened, not from the status file"
}

# --- resolving a decision removes its first-seen record -------------------------
t_review_decision_marker_cleared_on_resolve() {
  local home out marker
  home=$(new_home review-decision-marker)
  fm_write_meta "$home/state/svc..api.meta" "window=firstmate:fm-svc" "kind=ship"
  printf 'needs-decision[key=a..b]: pick the delivery mode\n' > "$home/state/svc..api.status"
  backdate "$home/state/svc..api.status" 7200

  out=$(run_review "$home")
  assert_contains "$out" "waiting on a decision" "the aging decision must surface first"
  marker=$(find "$home/state" -maxdepth 1 -name '.hourly-decision-*' | head -1)
  [ -n "$marker" ] || fail "an open decision must leave a first-seen record"
  rm -f "$home/state/.hourly-review-surfaced"

  # A still-open decision keeps the SAME record, even when the id and key both
  # mangle to names carrying extra underscores.
  out=$(run_review "$home")
  assert_present "$marker" "a still-open decision must keep its first-seen record"

  printf 'resolved[key=a..b]: delivery mode chosen\n' >> "$home/state/svc..api.status"
  out=$(run_review "$home")
  assert_absent "$marker" "resolving a decision must clear its first-seen record"

  printf 'needs-decision[key=a..b]: a brand new question\n' >> "$home/state/svc..api.status"
  out=$(run_review "$home")
  [ -z "$out" ] || fail "a re-opened decision must age from the new opening, got: $out"
  pass "resolving a decision clears its first-seen record"
}

# --- blocked or held queue items are not idle capacity --------------------------
t_review_idle_capacity_ignores_blocked() {
  local home out
  home=$(new_home review-idle-blocked)
  cat > "$home/data/backlog.md" <<'MD'
## In flight

## Queued

- [ ] one - first queued item (blocked-by: two - waiting on the fix)
- [ ] two - second queued item (hold: captain decision)

## Done
MD
  out=$(run_review "$home")
  [ -z "$out" ] \
    || fail "an entirely blocked or held queue is not idle dispatch capacity, got: $out"

  cat > "$home/data/backlog.md" <<'MD'
## In flight

## Queued

- [ ] one - first queued item (blocked-by: two - waiting on the fix)
- [ ] two - second queued item (hold: captain decision)
- [ ] three - actually dispatchable

## Done
MD
  out=$(run_review "$home")
  assert_contains "$out" "nothing under way with 1 queued" \
    "only the dispatchable item may count as idle capacity"
  pass "blocked and captain-held queue items never count as idle capacity"
}

# --- a live task id carrying a glob character keeps its markers -----------------
t_cleanup_protects_glob_keys() {
  local home out
  home=$(new_home cleanup-globkey)
  fm_write_meta "$home/state/epsilon.meta" "window=firstmate:fm-*-epsilon" "kind=secondmate"
  : > "$home/state/.hash-firstmate_fm-*-epsilon"
  backdate "$home/state/.hash-firstmate_fm-*-epsilon" 200000

  out=$(run_cleanup "$home")
  [ -z "$out" ] || fail "expected silence, got: $out"
  assert_present "$home/state/.hash-firstmate_fm-*-epsilon" \
    "a live key containing a glob character must still protect its marker"
  pass "marker protection survives a task id or window carrying a glob character"
}

# --- arming is idempotent across restarts ---------------------------------------
t_arm_keeps_existing_stamp() {
  local home before after
  home=$(new_home arm-idempotent)
  ( . "$ROOT/bin/fm-hourly-lib.sh"; fm_hourly_arm "$home/state" )
  backdate "$home/state/.last-hourly-review" 3000
  before=$(mtime_of "$home/state/.last-hourly-review")
  ( . "$ROOT/bin/fm-hourly-lib.sh"; fm_hourly_arm "$home/state" )
  after=$(mtime_of "$home/state/.last-hourly-review")
  [ "$before" = "$after" ] \
    || fail "a second arm must leave an existing cadence stamp alone (was $before, now $after)"
  assert_present "$home/state/.hourly-armed" "arming still writes the armed marker"
  pass "arming is idempotent, so elapsed time survives a session restart"
}

# --- arming ---------------------------------------------------------------------
t_session_start_arms() {
  local home root out holder_pid fakebin
  home=$(new_home arm-home)
  root="$TMP_ROOT/arm-root"
  fakebin="$TMP_ROOT/arm-fakebin"
  mkdir -p "$root"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  # The lock is acquirable only when a harness shows up in `ps` ancestry; CI
  # has none, so fake every queried pid as a harness (see make_fake_ps_claude).
  make_fake_ps_claude "$fakebin"

  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$PATH" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$SESSION_START")
  assert_contains "$out" "HOURLY PASSES" "session start must report the hourly passes"
  assert_contains "$out" "armed:" "session start must arm the hourly passes when it holds the lock"
  assert_present "$home/state/.hourly-armed" "arming must write the durable armed marker"
  assert_present "$home/state/.last-hourly-review" "arming must stamp the review cadence"
  assert_present "$home/state/.last-hourly-cleanup" "arming must stamp the cleanup cadence"
  pass "session start arms both hourly passes"
}

t_session_start_read_only_does_not_arm() {
  local home root out holder_pid
  home=$(new_home arm-readonly)
  root="$TMP_ROOT/arm-readonly-root"
  mkdir -p "$root"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  # A live process that LOOKS like a harness (bin/fm-lock.sh only honors a
  # holder whose command name matches a known harness) makes this session
  # read-only.
  printf '#!/bin/sh\nsleep 300\n' > "$TMP_ROOT/claude"
  chmod +x "$TMP_ROOT/claude"
  # Detached from this suite's stdout: an inherited pipe would keep the suite's
  # own output open until the holder's sleep expired.
  "$TMP_ROOT/claude" >/dev/null 2>&1 &
  holder_pid=$!
  printf '%s\n' "$holder_pid" > "$home/state/.lock"

  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$SESSION_START")
  pkill -P "$holder_pid" 2>/dev/null || true
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  assert_contains "$out" "skipped (read-only session)" "a read-only session must not arm the hourly passes"
  assert_absent "$home/state/.hourly-armed" "a read-only session must not write the armed marker"
  pass "a read-only session leaves arming to the session holding the lock"
}

t_unarmed_home_never_runs_a_pass() {
  local home out pid
  home=$(new_home unarmed)
  fm_write_meta "$home/state/zeta.meta" "window=firstmate:fm-zeta" "kind=ship"
  printf 'needs-decision: something old\n' > "$home/state/zeta.status"
  backdate "$home/state/zeta.status" 200000
  out="$TMP_ROOT/unarmed.out"

  FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  sleep 3
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_not_contains "$(cat "$out")" "check: session-" "an unarmed home must never run an hourly pass"
  pass "an unarmed home never runs an hourly pass"
}

# --- watcher wiring -------------------------------------------------------------
# The real watcher, one poll: a due, armed review pass wakes exactly once with a
# "check: session-review" record and the process EXITS. Nothing is backgrounded
# and no watcher is armed by the pass, so the single supervision cycle stays
# single.
t_watcher_runs_due_pass_and_exits() {
  local home out pid waited queue
  home=$(new_home watch-armed)
  fm_write_meta "$home/state/eta.meta" "window=firstmate:fm-eta" "kind=ship"
  printf 'needs-decision: which base branch\n' > "$home/state/eta.status"
  backdate "$home/state/eta.status" 200000
  touch "$home/state/.hourly-armed"
  : > "$home/state/.last-hourly-review"
  backdate "$home/state/.last-hourly-review" 7200
  : > "$home/state/.last-hourly-cleanup"
  out="$TMP_ROOT/watch-armed.out"

  FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_HOURLY_CLEANUP_INTERVAL=999999 \
    "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 30 ]; do
    sleep 1
    waited=$(( waited + 1 ))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "the watcher must EXIT after reporting an hourly-pass wake, it was still running"
  fi
  wait "$pid" 2>/dev/null || true

  assert_contains "$(cat "$out")" "check: session-review" "a due review pass must wake the watcher"
  queue=$(cat "$home/state/.wake-queue" 2>/dev/null || printf '')
  assert_contains "$queue" "session-review" "the wake must be recorded durably in the wake queue"
  pass "the watcher runs a due hourly pass, wakes once, and exits"
}

# --- structural: no second supervision cycle ------------------------------------
# A behavioral test proves the watcher exits; this proves the passes themselves
# cannot start a rival cycle - they never arm a watcher, never background a
# process, and never spawn a daemon.
t_passes_start_nothing() {
  local f
  for f in "$ROOT/bin/fm-session-review.sh" "$ROOT/bin/fm-cleanup-sweep.sh" "$ROOT/bin/fm-hourly-lib.sh"; do
    assert_no_grep "fm-watch-arm.sh" "$f" "$(basename "$f") must never arm a watcher"
    assert_no_grep "fm-supervise-daemon.sh" "$f" "$(basename "$f") must never start the supervision daemon"
    assert_no_grep "nohup" "$f" "$(basename "$f") must never background a process"
  done
  assert_no_grep "fm-teardown.sh\"" "$ROOT/bin/fm-cleanup-sweep.sh" "the cleanup pass must never run a teardown"
  pass "the hourly passes start no rival supervision cycle and run no teardown"
}

# --- review: shared-credential exhaustion rollup ------------------------------
# Two or more workers stalled on the same shared account (an auth/quota/token
# exhaustion pause) must aggregate into ONE fleet-wide escalation, not N silent
# local waits. A single such task, or two workers naming DIFFERENT accounts, must
# NOT aggregate.
t_review_auth_exhaustion_rollup() {
  local home out
  home=$(new_home review-auth-rollup)
  fm_write_meta "$home/state/a.meta" "window=firstmate:fm-a" "kind=ship"
  fm_write_meta "$home/state/b.meta" "window=firstmate:fm-b" "kind=ship"
  fm_write_meta "$home/state/c.meta" "window=firstmate:fm-c" "kind=ship"
  # a and b are the SAME shared account phrased differently; c is a benign wait.
  printf 'working: started\npaused: hit Claude usage limit, resets ~5pm\n' > "$home/state/a.status"
  printf 'working: go\npaused: Claude usage window limit reached\n' > "$home/state/b.status"
  printf 'working: go\npaused: waiting on upstream release\n' > "$home/state/c.status"

  out=$(run_review "$home")
  assert_contains "$out" "2 pipelines stalled on the shared account" "2+ same-account exhaustion tasks must raise one aggregated escalation"
  assert_grep "same shared credential" "$home/state/.hourly-review.latest" "the report must name the shared credential"
  assert_grep "resets ~5pm" "$home/state/.hourly-review.latest" "the report must carry the reset hint the worker recorded"
  assert_grep "stalled: a, b" "$home/state/.hourly-review.latest" "the report must list the stalled tasks"
  # The benign upstream-release pause must never join the cluster.
  assert_no_grep "stalled: a, b, c" "$home/state/.hourly-review.latest" "a benign pause must not be aggregated as an exhaustion stall"

  # Unchanged an hour later: silent.
  out=$(run_review "$home")
  [ -z "$out" ] || fail "an unchanged aggregated escalation must not surface again, got: $out"
  pass "review aggregates 2+ same-account exhaustion stalls into one escalation, once"
}

# --- review: a single exhaustion pause is NOT aggregated ----------------------
# classify-auth-limit already surfaces one exhaustion pause as its own blocker;
# this rollup is purely the N>=2 aggregation and must not fire for N=1.
t_review_auth_exhaustion_single_not_aggregated() {
  local home out
  home=$(new_home review-auth-single)
  fm_write_meta "$home/state/a.meta" "window=firstmate:fm-a" "kind=ship"
  fm_write_meta "$home/state/b.meta" "window=firstmate:fm-b" "kind=ship"
  printf 'working: go\npaused: hit Claude usage limit\n' > "$home/state/a.status"
  printf 'working: still going\n' > "$home/state/b.status"

  out=$(run_review "$home")
  assert_not_contains "$out" "stalled on the shared account" "a single exhaustion task must not raise the fleet rollup"
  assert_not_contains "$out" "stalled on account" "a single exhaustion task must not raise the fleet rollup"
  pass "review does not aggregate a single exhaustion stall"
}

# --- review: two DIFFERENT named accounts do NOT aggregate --------------------
# Grouping is strict: only an explicit different account token proves the stalls
# are on distinct credentials, and those must stay separate.
t_review_auth_exhaustion_distinct_accounts_not_aggregated() {
  local home out
  home=$(new_home review-auth-distinct)
  fm_write_meta "$home/state/a.meta" "window=firstmate:fm-a" "kind=ship"
  fm_write_meta "$home/state/b.meta" "window=firstmate:fm-b" "kind=ship"
  printf 'working: go\npaused: account=claude-1 hit usage limit\n' > "$home/state/a.status"
  printf 'working: go\npaused: account=claude-2 hit usage limit\n' > "$home/state/b.status"

  out=$(run_review "$home")
  assert_not_contains "$out" "stalled on the shared account" "distinct named accounts must not aggregate together"
  assert_not_contains "$out" "2 pipelines" "distinct named accounts must not aggregate into a count of 2"
  pass "review keeps distinct named accounts as separate credentials, no false aggregation"
}

t_review_silent_when_clean
t_review_aging_decision
t_review_silent_worker
t_review_idle_capacity
t_review_merge_batch
t_review_auth_exhaustion_rollup
t_review_auth_exhaustion_single_not_aggregated
t_review_auth_exhaustion_distinct_accounts_not_aggregated
t_cleanup_reclaims_quietly
t_cleanup_keeps_markers_in_flight
t_cleanup_reports_orphan_worktree
t_cleanup_skips_available_pool_slot
t_cleanup_still_flags_non_available_pool_slot
t_cleanup_fallback_suppresses_pool_like_slot
t_cleanup_fallback_still_flags_dirty_slot
t_cleanup_never_sweeps_merge_queue
t_secondmate_is_not_work_under_way
t_review_stall_without_status_file
t_review_decision_age_survives_later_append
t_review_decision_marker_cleared_on_resolve
t_review_idle_capacity_ignores_blocked
t_cleanup_protects_glob_keys
t_arm_keeps_existing_stamp
t_session_start_arms
t_session_start_read_only_does_not_arm
t_unarmed_home_never_runs_a_pass
t_watcher_runs_due_pass_and_exits
t_passes_start_nothing
