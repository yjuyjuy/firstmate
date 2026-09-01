#!/usr/bin/env bash
# Behavior tests for bin/fm-status-append.sh - the capped write point for crew
# status appends.
#
# The helper is the single place a crew status line is truncated before it
# reaches state/<id>.status, so a reader never sees an untruncated giant line
# that would bloat every wake, digest, and status tail. A long body spills to an
# overflow file the truncated line points at, and the state verb prefix stays at
# the front so bin/fm-classify-lib.sh's verb-keyed triage is unaffected.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SA="$ROOT/bin/fm-status-append.sh"
TMP_ROOT=$(fm_test_tmproot fm-status-append)
HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$HOME_DIR/state"
STATUS_FILE="$STATE_DIR/mytask.status"
OVERFLOW_DIR="$HOME_DIR/data/mytask/status-overflow"
mkdir -p "$STATE_DIR"

# Fresh status file and overflow dir per test, so each test asserts only its own
# writes.
reset_state() {
  rm -f "$STATUS_FILE"
  rm -rf "$OVERFLOW_DIR"
  mkdir -p "$STATE_DIR"
}

test_script_parses() {
  local out rc
  out=$(bash -n "$SA" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-status-append.sh must parse cleanly (got: $out)"
  pass "fm-status-append.sh: bash -n succeeds"
}

# An append at or under the cap is written UNCHANGED, byte for byte, and creates
# no overflow file.
test_under_cap_passthrough() {
  reset_state
  local line="working: setup done, branch created"
  "$SA" "$STATUS_FILE" "$line" || fail "under-cap append exited non-zero"
  local got
  got=$(cat "$STATUS_FILE")
  [ "$got" = "$line" ] || fail "under-cap line altered: got '$got'"
  assert_absent "$OVERFLOW_DIR" "under-cap append must not create an overflow dir"
  pass "fm-status-append.sh: under-cap line written unchanged, no overflow"
}

# A line exactly at the cap is still passthrough (boundary: <= cap is unchanged).
test_exact_cap_passthrough() {
  reset_state
  local body head line
  head="working: "
  # Build a line exactly 300 chars long.
  body=$(printf 'a%.0s' $(seq 1 $((300 - ${#head}))))
  line="$head$body"
  [ "${#line}" -eq 300 ] || fail "test setup: line is ${#line} chars, expected 300"
  "$SA" "$STATUS_FILE" "$line" || fail "exact-cap append exited non-zero"
  local got
  got=$(cat "$STATUS_FILE")
  [ "$got" = "$line" ] || fail "exact-cap line altered"
  assert_absent "$OVERFLOW_DIR" "exact-cap append must not overflow"
  pass "fm-status-append.sh: exact-cap (300) line written unchanged"
}

# A line over the cap: full body spills to the overflow file, and the truncated
# status line ends with the pointer suffix and is capped at the cap length.
test_over_cap_truncates_and_points() {
  reset_state
  local giant
  giant="needs-decision: $(printf 'x%.0s' $(seq 1 600)) END"
  [ "${#giant}" -gt 300 ] || fail "test setup: giant line not over cap"
  "$SA" "$STATUS_FILE" "$giant" || fail "over-cap append exited non-zero"

  local written
  written=$(cat "$STATUS_FILE")
  # Truncated line is capped at the cap length (300).
  [ "${#written}" -eq 300 ] || fail "truncated line is ${#written} chars, expected 300"
  # Pointer suffix present.
  assert_contains "$written" " ... [full: " "truncated line must carry the overflow pointer suffix"
  # State verb prefix preserved at the front for the classifier.
  case "$written" in
    "needs-decision: "*) : ;;
    *) fail "state verb prefix lost from truncated line: '$written'" ;;
  esac
  # The full untruncated body never reached the status file.
  assert_no_grep " END" "$STATUS_FILE" "the untruncated body must NOT appear in the status file"
  pass "fm-status-append.sh: over-cap line truncated with pointer, verb prefix intact"
}

# The overflow file exists and contains the COMPLETE original text verbatim.
test_overflow_file_content_integrity() {
  reset_state
  local giant
  giant="blocked: $(printf 'y%.0s' $(seq 1 500)) TAIL_MARKER"
  "$SA" "$STATUS_FILE" "$giant" || fail "over-cap append exited non-zero"

  assert_present "$OVERFLOW_DIR" "overflow dir must be created for an over-cap line"
  local files
  files=$(find "$OVERFLOW_DIR" -maxdepth 1 -name '*.txt' | wc -l)
  [ "$files" -eq 1 ] || fail "expected exactly 1 overflow file, found $files"

  local overflow_file body
  overflow_file=$(find "$OVERFLOW_DIR" -maxdepth 1 -name '*.txt')
  body=$(cat "$overflow_file")
  [ "$body" = "$giant" ] || fail "overflow file does not match the original body verbatim"

  # The pointer in the status file names that exact overflow file.
  assert_grep "$overflow_file" "$STATUS_FILE" "status line pointer must name the overflow file"
  pass "fm-status-append.sh: overflow file holds the complete original text"
}

# The full body is durable BEFORE the truncated line is visible: at no point does
# the status file carry a pointer to an overflow file that does not yet exist.
# We assert the end state (both present and consistent) plus that the pointer
# path resolves to a real file.
test_full_body_written_before_pointer_resolves() {
  reset_state
  local giant
  giant="failed: $(printf 'z%.0s' $(seq 1 400))"
  "$SA" "$STATUS_FILE" "$giant" || fail "over-cap append exited non-zero"
  # Extract the path from the pointer suffix and confirm the file exists.
  local ptr
  ptr=$(sed -n 's/.*\[full: \(.*\)\]$/\1/p' "$STATUS_FILE")
  [ -n "$ptr" ] || fail "could not parse pointer path from status line"
  assert_present "$ptr" "the overflow file named by the pointer must exist"
  pass "fm-status-append.sh: pointer resolves to a durable overflow file"
}

# Two over-cap appends in quick succession get distinct overflow files (no
# clobber).
test_concurrent_overflow_files_are_distinct() {
  reset_state
  local a b
  a="working: $(printf 'a%.0s' $(seq 1 400))"
  b="working: $(printf 'b%.0s' $(seq 1 400))"
  "$SA" "$STATUS_FILE" "$a"
  "$SA" "$STATUS_FILE" "$b"
  local files
  files=$(find "$OVERFLOW_DIR" -maxdepth 1 -name '*.txt' | wc -l)
  [ "$files" -eq 2 ] || fail "expected 2 distinct overflow files, found $files"
  pass "fm-status-append.sh: successive over-cap appends do not clobber"
}

# The cap is configurable via FM_STATUS_APPEND_CAP and --cap.
test_cap_is_configurable() {
  reset_state
  local line="working: this is a medium length status line well under three hundred"
  FM_STATUS_APPEND_CAP=20 "$SA" "$STATUS_FILE" "$line"
  local written
  written=$(cat "$STATUS_FILE")
  assert_contains "$written" " ... [full: " "cap=20 must force truncation of a normally-short line"
  pass "fm-status-append.sh: FM_STATUS_APPEND_CAP overrides the cap"
}

test_script_parses
test_under_cap_passthrough
test_exact_cap_passthrough
test_over_cap_truncates_and_points
test_overflow_file_content_integrity
test_full_body_written_before_pointer_resolves
test_concurrent_overflow_files_are_distinct
test_cap_is_configurable
