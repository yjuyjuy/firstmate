#!/usr/bin/env bash
# Characterization tests for bin/fm-lease-extra-worktree.sh - the helper that
# leases a SECOND treehouse worktree for a task and records it durably in the
# task's meta so teardown can return it.
#
# The safety invariant: a leased slot must never exist without a meta line
# teardown reads, and the helper must never record a line it could not lease.
# The recorded line shape is exactly:
#   extra_worktree=<clone-abs>\t<worktree-abs>
# and bin/fm-teardown.sh reads every such line to return the extra worktree. These
# tests pin that record-on-success behavior and the fail-without-record guards.
#
# treehouse is mocked (a fake on PATH that prints a worktree path to stdout and
# banners to stderr, matching the real contract). No real pool is touched; the
# clone fixtures are throwaway git repos.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

LEASE="$ROOT/bin/fm-lease-extra-worktree.sh"
TMP_ROOT=$(fm_test_tmproot fm-lease-extra-tests)

# A fake treehouse. `treehouse get --lease --lease-holder <id>` prints a banner to
# stderr (which must NOT pollute the captured path) and the worktree path to
# stdout. The path it returns is taken from FM_TEST_TH_WT; if FM_TEST_TH_FAIL is
# set it exits non-zero (a lease failure); if FM_TEST_TH_EMPTY is set it prints no
# path (a treehouse that reported nothing).
make_treehouse() {  # <fakebin-dir>
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/treehouse" <<'SH'
#!/usr/bin/env bash
echo "treehouse: leasing worktree (banner to stderr)" >&2
if [ -n "${FM_TEST_TH_FAIL:-}" ]; then
  echo "treehouse: pool exhausted" >&2
  exit 1
fi
if [ -n "${FM_TEST_TH_EMPTY:-}" ]; then
  exit 0
fi
printf '%s\n' "${FM_TEST_TH_WT}"
SH
  chmod +x "$dir/treehouse"
}

# Write a minimal task meta so the helper finds it.
write_meta() {  # <state> <id>
  local state=$1 id=$2
  mkdir -p "$state"
  cat > "$state/$id.meta" <<EOF
window=test:fm-$id
worktree=/some/primary/$id
project=/some/project/$id
harness=echo
kind=ship
mode=local-only
EOF
}

# Make a throwaway git clone the helper will accept as a clone dir.
make_clone() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
}

RC_FILE="$TMP_ROOT/lease-rc"
# Run the helper. Echoes stdout only (the caller wants the printed path);
# stderr goes to <case_dir>/err. Exit status to $RC_FILE.
run_lease() {  # <case_dir> <home> <id> <clone> [extra-env...]
  local case_dir=$1 home=$2 id=$3 clone=$4; shift 4
  mkdir -p "$case_dir/fakebin"
  make_treehouse "$case_dir/fakebin"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
  FM_TEST_TH_WT="${FM_TEST_TH_WT-}" \
  PATH="$case_dir/fakebin:$PATH" env "$@" \
    "$LEASE" "$id" "$clone" 2>"$case_dir/err"
  printf '%s' "$?" > "$RC_FILE"
}
lease_rc() { cat "$RC_FILE"; }

test_lease_records_and_prints_path() {
  local case_dir="$TMP_ROOT/ok" home="$TMP_ROOT/ok/home"
  local clone="$TMP_ROOT/ok/clone" wt="$TMP_ROOT/ok/leased-wt"
  make_clone "$clone"; mkdir -p "$wt"
  write_meta "$home/state" t1
  local out clone_abs wt_abs
  clone_abs=$(cd "$clone" && pwd -P)
  wt_abs=$(cd "$wt" && pwd -P)
  out=$(FM_TEST_TH_WT="$wt" run_lease "$case_dir" "$home" t1 "$clone")
  expect_code 0 "$(lease_rc)" "a successful lease must exit 0"
  # Only the absolute worktree path is printed to stdout (banners went to stderr).
  [ "$out" = "$wt_abs" ] || fail "stdout must be exactly the leased worktree path, got: '$out'"
  # The durable meta line was appended in the exact tab-separated shape.
  local expected
  expected=$(printf 'extra_worktree=%s\t%s' "$clone_abs" "$wt_abs")
  grep -qxF "$expected" "$home/state/t1.meta" || fail "meta missing the extra_worktree record: $(cat "$home/state/t1.meta")"
  pass "a successful lease records the extra_worktree meta line and prints only the path"
}

test_missing_meta_fails_without_record() {
  local case_dir="$TMP_ROOT/nometa" home="$TMP_ROOT/nometa/home"
  local clone="$TMP_ROOT/nometa/clone"
  make_clone "$clone"; mkdir -p "$home/state"
  FM_TEST_TH_WT="$TMP_ROOT/nometa/wt" run_lease "$case_dir" "$home" ghost "$clone"
  expect_code 1 "$(lease_rc)" "a missing meta must exit 1"
  assert_contains "$(cat "$case_dir/err")" "no meta for task ghost" "the missing meta must be named"
  pass "a missing meta fails before leasing (nothing to record against)"
}

test_missing_clone_fails() {
  local case_dir="$TMP_ROOT/noclone" home="$TMP_ROOT/noclone/home"
  write_meta "$home/state" c1
  FM_TEST_TH_WT="$TMP_ROOT/noclone/wt" run_lease "$case_dir" "$home" c1 "$TMP_ROOT/noclone/does-not-exist"
  expect_code 1 "$(lease_rc)" "a missing clone dir must exit 1"
  assert_contains "$(cat "$case_dir/err")" "does not exist" "the missing clone must be named"
  assert_no_grep "extra_worktree=" "$home/state/c1.meta" "no record may be written for a missing clone"
  pass "a missing clone dir fails without recording"
}

test_non_git_clone_fails() {
  local case_dir="$TMP_ROOT/nongit" home="$TMP_ROOT/nongit/home"
  local clone="$TMP_ROOT/nongit/plain"
  mkdir -p "$clone"  # a directory that is NOT a git repo
  write_meta "$home/state" n1
  FM_TEST_TH_WT="$TMP_ROOT/nongit/wt" run_lease "$case_dir" "$home" n1 "$clone"
  expect_code 1 "$(lease_rc)" "a non-git clone dir must exit 1"
  assert_contains "$(cat "$case_dir/err")" "not a git repository" "a non-git clone must be named"
  assert_no_grep "extra_worktree=" "$home/state/n1.meta" "no record may be written for a non-git clone"
  pass "a non-git clone dir fails without recording"
}

test_unsafe_task_id_refused() {
  local case_dir="$TMP_ROOT/badid" home="$TMP_ROOT/badid/home"
  local clone="$TMP_ROOT/badid/clone"
  make_clone "$clone"; mkdir -p "$home/state"
  FM_TEST_TH_WT="$TMP_ROOT/badid/wt" run_lease "$case_dir" "$home" '../escape' "$clone"
  expect_code 2 "$(lease_rc)" "a path-unsafe task id must exit 2 (usage)"
  assert_contains "$(cat "$case_dir/err")" "usage:" "an unsafe id must print usage"
  pass "a path-unsafe task id is refused"
}

test_lease_failure_writes_no_record() {
  local case_dir="$TMP_ROOT/thfail" home="$TMP_ROOT/thfail/home"
  local clone="$TMP_ROOT/thfail/clone"
  make_clone "$clone"; write_meta "$home/state" f1
  FM_TEST_TH_WT="$TMP_ROOT/thfail/wt" FM_TEST_TH_FAIL=1 run_lease "$case_dir" "$home" f1 "$clone"
  expect_code 1 "$(lease_rc)" "a treehouse lease failure must exit 1"
  assert_contains "$(cat "$case_dir/err")" "treehouse get --lease failed" "the lease failure must be named"
  assert_no_grep "extra_worktree=" "$home/state/f1.meta" "a failed lease must record nothing (never lease without recording, never record without leasing)"
  pass "a treehouse lease failure records no meta line"
}

test_empty_worktree_path_writes_no_record() {
  local case_dir="$TMP_ROOT/thempty" home="$TMP_ROOT/thempty/home"
  local clone="$TMP_ROOT/thempty/clone"
  make_clone "$clone"; write_meta "$home/state" e1
  FM_TEST_TH_WT="" FM_TEST_TH_EMPTY=1 run_lease "$case_dir" "$home" e1 "$clone"
  expect_code 1 "$(lease_rc)" "an empty reported path must exit 1"
  assert_contains "$(cat "$case_dir/err")" "did not report a worktree path" "the empty path must be named"
  assert_no_grep "extra_worktree=" "$home/state/e1.meta" "an empty lease path must record nothing"
  pass "a treehouse that reports no path records no meta line"
}

test_two_leases_append_two_records() {
  # Teardown reads EVERY extra_worktree line, so a second lease must APPEND a
  # second record rather than replace the first.
  local case_dir="$TMP_ROOT/two" home="$TMP_ROOT/two/home"
  local clone="$TMP_ROOT/two/clone" wt1="$TMP_ROOT/two/wt1" wt2="$TMP_ROOT/two/wt2"
  make_clone "$clone"; mkdir -p "$wt1" "$wt2"; write_meta "$home/state" m1
  FM_TEST_TH_WT="$wt1" run_lease "$case_dir/a" "$home" m1 "$clone" >/dev/null
  expect_code 0 "$(lease_rc)" "first lease must exit 0"
  FM_TEST_TH_WT="$wt2" run_lease "$case_dir/b" "$home" m1 "$clone" >/dev/null
  expect_code 0 "$(lease_rc)" "second lease must exit 0"
  local n
  n=$(grep -c '^extra_worktree=' "$home/state/m1.meta")
  [ "$n" -eq 2 ] || fail "expected 2 extra_worktree records after two leases, got $n"
  pass "two leases append two distinct extra_worktree records"
}

test_lease_records_and_prints_path
test_missing_meta_fails_without_record
test_missing_clone_fails
test_non_git_clone_fails
test_unsafe_task_id_refused
test_lease_failure_writes_no_record
test_empty_worktree_path_writes_no_record
test_two_leases_append_two_records

echo "# all fm-lease-extra-worktree tests passed"
