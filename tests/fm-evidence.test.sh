#!/usr/bin/env bash
# Behavior tests for bin/fm-evidence.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-evidence)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data"

run_evidence() {
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-evidence.sh" "$@"
}

test_writes_stdin_to_evidence_file_and_prints_path() {
  local out
  out=$(printf 'big test output\nline two\n' | run_evidence taskone suite-run) \
    || fail "fm-evidence.sh failed on stdin input"
  [ "$out" = "$HOME_DIR/data/taskone/evidence/suite-run.txt" ] \
    || fail "printed path was '$out', not the expected evidence path"
  assert_present "$out" "evidence file was not created"
  assert_grep "big test output" "$out" "evidence file lost stdin content"
  pass "fm-evidence.sh: writes stdin to data/<id>/evidence/<name>.txt and prints the path"
}

test_creates_evidence_dir_as_needed() {
  local out
  [ ! -d "$HOME_DIR/data/fresh/evidence" ] || fail "evidence dir already existed"
  out=$(printf 'x\n' | run_evidence fresh first) || fail "fm-evidence.sh failed to create dir"
  assert_present "$HOME_DIR/data/fresh/evidence" "evidence directory was not created"
  assert_present "$out" "evidence file was not created in fresh dir"
  pass "fm-evidence.sh: creates the data/<id>/evidence/ directory as needed"
}

test_reads_from_source_path() {
  local src out
  src="$TMP_ROOT/source-diff.txt"
  printf 'diff --git a b\n' > "$src"
  out=$(run_evidence tasktwo thediff "$src") || fail "fm-evidence.sh failed on source path"
  assert_grep "diff --git a b" "$out" "evidence file lost source-path content"
  pass "fm-evidence.sh: reads evidence from a source path when given"
}

test_rejects_unsafe_task_id() {
  local out rc
  out=$(printf 'x\n' | run_evidence "../evil" name 2>&1)
  rc=$?
  expect_code 2 "$rc" "unsafe task id"
  assert_contains "$out" "invalid task id" "did not report an invalid task id"
  pass "fm-evidence.sh: rejects a path-unsafe task id"
}

test_rejects_unsafe_name() {
  local out rc
  out=$(printf 'x\n' | run_evidence tasktwo "../evil" 2>&1)
  rc=$?
  expect_code 2 "$rc" "unsafe evidence name"
  assert_contains "$out" "invalid evidence name" "did not report an invalid evidence name"
  pass "fm-evidence.sh: rejects a path-unsafe evidence name"
}

test_fails_closed_when_data_dir_missing() {
  local out rc
  out=$(FM_HOME="$TMP_ROOT/no-such-home" "$ROOT/bin/fm-evidence.sh" taskone n <<<'x' 2>&1)
  rc=$?
  expect_code 1 "$rc" "missing data directory"
  assert_contains "$out" "data directory is unavailable" "did not fail closed on a missing home data dir"
  pass "fm-evidence.sh: fails closed when the home data directory is unavailable"
}

test_rejects_missing_source_path() {
  local out rc
  out=$(run_evidence taskone n "$TMP_ROOT/no-such-source.txt" 2>&1)
  rc=$?
  expect_code 1 "$rc" "missing source path"
  assert_contains "$out" "source path is not a readable file" "did not report an unreadable source path"
  pass "fm-evidence.sh: rejects a missing source path"
}

test_rejects_wrong_arg_count() {
  local rc
  printf 'x\n' | run_evidence onlyid >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "too few arguments"
  pass "fm-evidence.sh: rejects a wrong argument count"
}

test_writes_stdin_to_evidence_file_and_prints_path
test_creates_evidence_dir_as_needed
test_reads_from_source_path
test_rejects_unsafe_task_id
test_rejects_unsafe_name
test_fails_closed_when_data_dir_missing
test_rejects_missing_source_path
test_rejects_wrong_arg_count
