#!/usr/bin/env bash
# Duplicate-steer suppressor (bin/fm-send.sh + bin/fm-pending-reply-lib.sh).
#
# A supervisor re-sending the SAME correlation-keyed steer ("[key=<slug>]") to a
# worker that has already opened or already answered that keyed request burns a
# full supervisor turn and a full worker turn. fm-send therefore refuses - loudly,
# non-zero, with a pointer to the existing reply - a second send of a key that is
# already pending (already delivered, not yet answered) or already resolved (the
# worker's status shows a resolved/captain-held line for that key). A leading
# --force overrides the refusal. A fresh key or a no-key steer passes through.
#
# These tests pin all five required behaviors end-to-end through the real fm-send
# with a tmux stub, plus the library-level status/state classifier the refusal
# reads.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-duplicate-steer-suppressor)

# tmux stub: logs typed literal text and Enter, and reports an idle composer on
# capture-pane so the submit is confirmed (the box-drawing empty line the strict
# suite uses). Mirrors tests/fm-send-strict.test.sh's stub contract.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    exit 0 ;;
  display-message)
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    printf '\xe2\x94\x82 \xe2\x94\x82\n'
    exit 0 ;;
  list-windows)
    printf 'foreign:fm-lost\n'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# A valid firstmate home with one recorded ship lane.
setup_home() {  # <dir> -> echoes home dir
  local dir=$1 home="$dir/home"
  mkdir -p "$home/data" "$home/state" "$home/config"
  printf '# firstmate\n' > "$home/AGENTS.md"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship" "harness=codex"
  printf '%s\n' "$home"
}

run_send() {  # <home> <fakebin> <errfile> <logfile> <args...>
  local home=$1 fb=$2 err=$3 log=$4
  shift 4
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" "$@" >/dev/null 2>"$err"
}

# --- library-level classifier ----------------------------------------------

test_status_state_open_resolved_absent() {
  local dir state st
  dir="$TMP_ROOT/statestate-$RANDOM"; mkdir -p "$dir"
  state="$dir/state"; mkdir -p "$state"
  st="$state/lane.status"
  printf '%s\n' "needs-decision [key=api]: which shape" > "$st"
  [ "$(fm_steer_key_status_state "$st" api)" = open ] \
    || fail "an unresolved needs-decision for the key must classify as open"
  printf '%s\n' "resolved [key=api]: went with B" >> "$st"
  [ "$(fm_steer_key_status_state "$st" api)" = resolved ] \
    || fail "a resolved line for the key must classify as resolved"
  [ "$(fm_steer_key_status_state "$st" other)" = absent ] \
    || fail "a key that never appears must classify as absent"
  pass "suppressor classifier: open / resolved / absent from the target status fold"
}

# --- end-to-end fm-send behaviors ------------------------------------------

test_fresh_key_sends_and_records() {
  local dir fb home err log rc
  dir="$TMP_ROOT/fresh-$RANDOM"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home "$dir"); err="$dir/e"; log="$dir/l"; : > "$log"
  run_send "$home" "$fb" "$err" "$log" fm-lane-ok "Decision: [key=api-shape] go with B"; rc=$?
  expect_code 0 "$rc" "a fresh keyed steer must send"
  assert_contains "$(cat "$log")" "literal=1 arg=Decision: [key=api-shape] go with B" \
    "fresh keyed steer should type its literal text"
  [ -f "$home/state/steer-keys/lane-ok__api-shape" ] \
    || fail "a delivered keyed steer must be recorded in the steer-key ledger"
  pass "suppressor: a fresh-key steer sends and is recorded"
}

test_no_key_steer_always_passes() {
  local dir fb home err log rc
  dir="$TMP_ROOT/nokey-$RANDOM"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home "$dir"); err="$dir/e"; log="$dir/l"; : > "$log"
  # Send the same no-key text twice; both must pass and neither creates a ledger.
  run_send "$home" "$fb" "$err" "$log" fm-lane-ok "just keep going"; rc=$?
  expect_code 0 "$rc" "a no-key steer must send"
  : > "$log"
  run_send "$home" "$fb" "$err" "$log" fm-lane-ok "just keep going"; rc=$?
  expect_code 0 "$rc" "a repeated no-key steer must still send (no suppression without a key)"
  assert_contains "$(cat "$log")" "literal=1 arg=just keep going" "no-key steer should type its literal text"
  [ ! -d "$home/state/steer-keys" ] || [ -z "$(ls -A "$home/state/steer-keys" 2>/dev/null)" ] \
    || fail "a no-key steer must not create a steer-key record"
  pass "suppressor: a no-key steer always passes and records nothing"
}

test_pending_key_refused_with_pointer() {
  local dir fb home err log rc rec
  dir="$TMP_ROOT/pending-$RANDOM"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home "$dir"); err="$dir/e"; log="$dir/l"; : > "$log"
  run_send "$home" "$fb" "$err" "$log" fm-lane-ok "Decision: [key=api-shape] go with B"; rc=$?
  expect_code 0 "$rc" "first keyed steer must send"
  rec="$home/state/steer-keys/lane-ok__api-shape"
  [ -f "$rec" ] || fail "first keyed steer must record the pending ledger entry"
  : > "$log"; : > "$err"
  run_send "$home" "$fb" "$err" "$log" fm-lane-ok "Decision: [key=api-shape] go with B"; rc=$?
  [ "$rc" -ne 0 ] || fail "a second send of a pending key must be refused"
  assert_contains "$(cat "$err")" "already pending" "pending refusal must say the key is already pending"
  assert_contains "$(cat "$err")" "$rec" "pending refusal must point at the existing ledger record"
  assert_contains "$(cat "$err")" "--force" "pending refusal must mention the --force override"
  [ ! -s "$log" ] || fail "a refused pending steer must not reach the composer"$'\n'"$(cat "$log")"
  pass "suppressor: a pending-key duplicate is refused with a pointer, no send"
}

test_resolved_key_refused_with_pointer() {
  local dir fb home err log rc st
  dir="$TMP_ROOT/resolved-$RANDOM"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home "$dir"); err="$dir/e"; log="$dir/l"; : > "$log"
  run_send "$home" "$fb" "$err" "$log" fm-lane-ok "Decision: [key=api-shape] go with B"; rc=$?
  expect_code 0 "$rc" "first keyed steer must send"
  # Worker answers the key in its own status file.
  st="$home/state/lane-ok.status"
  printf '%s\n' "resolved [key=api-shape]: applied B" > "$st"
  : > "$log"; : > "$err"
  run_send "$home" "$fb" "$err" "$log" fm-lane-ok "Decision: [key=api-shape] reconsider"; rc=$?
  [ "$rc" -ne 0 ] || fail "a send of an already-resolved key must be refused"
  assert_contains "$(cat "$err")" "already answered" "resolved refusal must say the key was already answered"
  assert_contains "$(cat "$err")" "$st" "resolved refusal must point at the status file that answered it"
  assert_contains "$(cat "$err")" "--force" "resolved refusal must mention the --force override"
  [ ! -s "$log" ] || fail "a refused resolved steer must not reach the composer"$'\n'"$(cat "$log")"
  pass "suppressor: a resolved-key duplicate is refused with a status pointer, no send"
}

test_force_overrides_refusal() {
  local dir fb home err log rc
  dir="$TMP_ROOT/force-$RANDOM"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home "$dir"); err="$dir/e"; log="$dir/l"; : > "$log"
  run_send "$home" "$fb" "$err" "$log" fm-lane-ok "Decision: [key=api-shape] go with B"; rc=$?
  expect_code 0 "$rc" "first keyed steer must send"
  : > "$log"; : > "$err"
  # Second send would be refused (pending), but --force sends anyway.
  run_send "$home" "$fb" "$err" "$log" fm-lane-ok --force "Decision: [key=api-shape] go with B"; rc=$?
  expect_code 0 "$rc" "--force must override the pending refusal"
  assert_contains "$(cat "$log")" "literal=1 arg=Decision: [key=api-shape] go with B" \
    "--force must deliver the steer text without the --force flag"
  assert_not_contains "$(cat "$log")" "--force" "--force flag must be consumed, never typed as text"
  pass "suppressor: --force overrides the refusal and delivers the steer"
}

test_status_state_open_resolved_absent
test_fresh_key_sends_and_records
test_no_key_steer_always_passes
test_pending_key_refused_with_pointer
test_resolved_key_refused_with_pointer
test_force_overrides_refusal
