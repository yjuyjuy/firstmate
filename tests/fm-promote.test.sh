#!/usr/bin/env bash
# Behavior tests for the scout->ship promote context gate (bin/fm-promote.sh).
# The gate reuses the shared context reader (fm_sm_context_tokens) from
# fm-secondmate-context-lib.sh; here we drive the whole script end to end:
#   - context <= threshold: promotes IN PLACE (flips kind=scout -> kind=ship).
#   - context >  threshold: REFUSES in place (kind stays scout) and emits the
#     fresh-handoff next step.
#   - context unreadable: FAILS CLOSED to in-place promote but prints a notice.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-promote-tests)
mkdir -p "$TMP_ROOT"

# Build a fake claude transcript for <cwd> reporting <input>+<cc>+<cr> tokens on
# its last main-thread turn, under <config>/projects (claude's munged dir).
write_transcript() {  # <config-dir> <cwd> <input> <cc> <cr>
  local config=$1 cwd=$2 input=$3 cc=$4 cr=$5 dir
  dir="$config/projects/$(printf '%s' "$cwd" | tr '/.' '--')"
  mkdir -p "$dir"
  printf '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' \
    "$input" "$cc" "$cr" > "$dir/session.jsonl"
}

# Write a scout meta at <state>/<id>.meta pointing at <cwd> with <harness>.
write_scout_meta() {  # <state> <id> <cwd> <harness> [kind]
  local state=$1 id=$2 cwd=$3 harness=$4 kind=${5:-scout}
  mkdir -p "$state"
  cat > "$state/$id.meta" <<EOF
window=test:fm-$id
worktree=$cwd
project=/some/project/$id
harness=$harness
kind=$kind
EOF
}

# Run fm-promote.sh for <id> in a fresh home rooted at <home>, with a claude
# config at <config>. Echoes combined stdout+stderr on stdout so a caller can
# capture it with $(...); the exit status is written to $RC_FILE (read after the
# capture) because a $(...) subshell cannot export a variable back to the caller.
RC_FILE="$TMP_ROOT/promote-rc"
run_promote() {  # <home> <config> <id>
  local home=$1 config=$2 id=$3
  CLAUDE_CONFIG_DIR="$config" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-promote.sh" "$id" 2>&1
  printf '%s' "$?" > "$RC_FILE"
}
promote_rc() { cat "$RC_FILE"; }

test_threshold_default_and_config() {
  local out
  # The threshold reader is defined inside fm-promote.sh; drive it by observing
  # the boundary behavior through the script rather than sourcing a private fn.
  # Default 100000: a 90000 read promotes in place, a 110000 read hands off.
  local home="$TMP_ROOT/th-home" config="$TMP_ROOT/th-cfg" cwd="$TMP_ROOT/th-cwd"
  mkdir -p "$home/config"
  write_scout_meta "$home/state" s-def "$cwd" claude
  write_transcript "$config" "$cwd" 0 0 90000
  out=$(run_promote "$home" "$config" s-def)
  assert_contains "$out" "promoting in place" "90000 <= default 100000 must promote in place"

  write_scout_meta "$home/state" s-over "$cwd" claude
  write_transcript "$config" "$cwd" 0 0 110000
  out=$(run_promote "$home" "$config" s-over)
  assert_contains "$out" "refusing in-place promote" "110000 > default 100000 must refuse in place"

  # A configured lower threshold flips a mid read to the handoff path.
  printf '50000\n' > "$home/config/promote-context-threshold"
  write_scout_meta "$home/state" s-cfg "$cwd" claude
  write_transcript "$config" "$cwd" 0 0 60000
  out=$(run_promote "$home" "$config" s-cfg)
  assert_contains "$out" "refusing in-place promote" "60000 > configured 50000 must refuse in place"

  # A garbage threshold falls back to the 100000 default (60000 promotes).
  printf 'garbage\n' > "$home/config/promote-context-threshold"
  write_scout_meta "$home/state" s-bad "$cwd" claude
  write_transcript "$config" "$cwd" 0 0 60000
  out=$(run_promote "$home" "$config" s-bad)
  assert_contains "$out" "promoting in place" "garbage threshold must fall back to 100000 (60000 promotes)"
  pass "promote threshold defaults to 100000, honors config, and fails safe on bad values"
}

test_under_threshold_promotes_in_place() {
  local home="$TMP_ROOT/under-home" config="$TMP_ROOT/under-cfg" cwd="$TMP_ROOT/under-cwd" out
  mkdir -p "$home/config"
  write_scout_meta "$home/state" u1 "$cwd" claude
  write_transcript "$config" "$cwd" 10 20 50000  # 50030 <= 100000
  out=$(run_promote "$home" "$config" u1)
  expect_code 0 "$(promote_rc)" "in-place promote must exit 0"
  assert_contains "$out" "promoted u1 to ship in place" "under threshold must promote in place"
  assert_contains "$out" "bin/fm-send.sh fm-u1" "in-place promote must emit the fm-send next step"
  grep -qx 'kind=ship' "$home/state/u1.meta" || fail "meta kind must be flipped to ship"
  grep -qx 'kind=scout' "$home/state/u1.meta" && fail "the old kind=scout line must be gone"
  pass "at/under threshold: promotes in place and flips kind=scout -> kind=ship"
}

test_over_threshold_hands_off_and_keeps_scout() {
  local home="$TMP_ROOT/over-home" config="$TMP_ROOT/over-cfg" cwd="$TMP_ROOT/over-cwd" out
  mkdir -p "$home/config"
  write_scout_meta "$home/state" o1 "$cwd" claude
  write_transcript "$config" "$cwd" 10 20 150000  # 150030 > 100000
  out=$(run_promote "$home" "$config" o1)
  expect_code 0 "$(promote_rc)" "over-threshold handoff must exit 0"
  assert_contains "$out" "refusing in-place promote" "over threshold must refuse in place"
  assert_contains "$out" "data/o1/report.md" "handoff must reference the scout report"
  assert_contains "$out" "fm-spawn.sh" "handoff must emit a fresh-spawn next step"
  assert_contains "$out" "fm-teardown.sh o1" "handoff must reference tearing down the old scout worktree"
  grep -qx 'kind=scout' "$home/state/o1.meta" || fail "over threshold must NOT flip kind (stays scout)"
  grep -qx 'kind=ship' "$home/state/o1.meta" && fail "over threshold must not write kind=ship"
  pass "above threshold: refuses in place, keeps kind=scout, and emits the fresh-handoff path"
}

test_unreadable_context_fails_closed_with_notice() {
  local home="$TMP_ROOT/fc-home" config="$TMP_ROOT/fc-cfg" cwd="$TMP_ROOT/fc-cwd" out
  mkdir -p "$home/config" "$config"
  # codex harness -> the shared reader returns empty (unsupported) -> unreadable.
  write_scout_meta "$home/state" f1 "$cwd" codex
  out=$(run_promote "$home" "$config" f1)
  expect_code 0 "$(promote_rc)" "fail-closed promote must exit 0"
  assert_contains "$out" "could not read scout f1 context" "unreadable context must print a notice"
  assert_contains "$out" "promoted f1 to ship in place" "unreadable context must fall back to in-place promote"
  grep -qx 'kind=ship' "$home/state/f1.meta" || fail "fail-closed must still flip kind to ship"
  pass "unreadable context: prints a notice and fails closed to in-place promote"
}

test_refuses_non_scout() {
  local home="$TMP_ROOT/ns-home" config="$TMP_ROOT/ns-cfg" cwd="$TMP_ROOT/ns-cwd" out
  mkdir -p "$home/config"
  write_scout_meta "$home/state" ship1 "$cwd" claude ship
  out=$(run_promote "$home" "$config" ship1)
  expect_code 1 "$(promote_rc)" "a non-scout task must be refused"
  assert_contains "$out" "is not a scout task" "refusal must name the reason"
  out=$(run_promote "$home" "$config" nope)
  expect_code 1 "$(promote_rc)" "an unknown id must be refused"
  pass "promote refuses a non-scout task and an unknown id"
}

test_threshold_default_and_config
test_under_threshold_promotes_in_place
test_over_threshold_hands_off_and_keeps_scout
test_unreadable_context_fails_closed_with_notice
test_refuses_non_scout

echo "# all fm-promote tests passed"
