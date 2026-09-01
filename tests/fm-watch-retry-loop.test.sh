#!/usr/bin/env bash
# tests/fm-watch-retry-loop.test.sh - the watcher's retry-loop tripwire
# (bin/fm-watch.sh retry_loop_check), which steers and then escalates a
# supervised worker stuck appending the SAME status body over and over without
# progress.
#
# Contract pinned here:
#   1. DETECTION is objective: the task status file's last FM_RETRY_LOOP_MIN
#      (default 3) non-blank lines must be BYTE-IDENTICAL to each other. A
#      worker appending the same failing-command line, error, or retry note
#      three times in a row trips; any variation in the body does not.
#   2. First qualifying poll of a NEW loop body sends exactly ONE auto-steer via
#      the FM_RETRY_LOOP_SEND_BIN seam (`stop retrying, append blocked: with the
#      exact blocker and wait`), records the body hash in
#      state/.retry-loop-<key>, and does NOT wake (the steer is the first quiet
#      intervention).
#   3. The episode is idempotent: repeat polls showing the SAME body never send
#      a second steer.
#   4. A continuing loop past the next grace window escalates ONCE as
#      `check: retry-loop <task>` via state/.retry-loop-escalated-<key>, then
#      stays silent for that episode (never a second escalation).
#   5. A worker that is NOT looping (varied status bodies) is never steered.
#   6. Secondmate and supervise=off windows are NEVER steered.
#   7. A send that cannot be confirmed records the episode's single steer and
#      escalates immediately with a delivery-FAILED reason, never a steer loop.
#   8. retry_loop_check adds NO backend capture: it reads only the status file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
assert_present "$WATCH" "bin/fm-watch.sh is missing"

# fm_meta_get and the watcher functions load by sourcing (its guard returns
# before the lock/loop), so retry_loop_trailing_body is available for the direct
# predicate checks below.
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-watch.sh
. "$WATCH" >/dev/null 2>&1

TMP=$(fm_test_tmproot fm-watch-retry-loop)
STATE="$TMP/state"
mkdir -p "$STATE"

W="default:w1:p2"
TASK="looptask"
KEY=$(printf '%s' "$W" | tr ':/.' '___')
STATUS="$STATE/$TASK.status"

# The send seam stub, standing in for bin/fm-send.sh: logs each invocation
# (target|message) and exits non-zero when STUB_EXIT=1 (a failed delivery).
STUB="$TMP/fake-send.sh"
STUB_LOG="$TMP/send.log"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\$1" "\$2" >> "\$STUB_LOG"
[ "\${STUB_EXIT:-0}" = 1 ] && exit 1
exit 0
EOF
chmod +x "$STUB"
STUB_EXIT=0

seed_meta() {
  printf 'window=%s\nbackend=tmux\n' "$W" > "$STATE/$TASK.meta"
}

# run_poll -> OUT (the wake reason on stdout, or NOWAKE). Drive
# retry_loop_check in a subshell over the persisted STATE directory, exactly as
# consecutive real watcher polls would. wake() exits 0 after printing, so an
# escalation ends the subshell with the reason on stdout; a calm case echoes
# NOWAKE.
run_poll() {
  OUT=$(FM_STATE_OVERRIDE="$STATE" FM_WAKE_QUEUE="$STATE/.wake-queue" \
        FM_WAKE_QUEUE_LOCK="$STATE/.wake-queue.lock" \
        FM_RETRY_LOOP_SEND_BIN="$STUB" \
        STUB_LOG="$STUB_LOG" STUB_EXIT="$STUB_EXIT" \
        bash -c '
        . "'"$WATCH"'" >/dev/null 2>&1
        STATE="'"$STATE"'"
        retry_loop_check "'"$W"'" "'"$TASK"'"
        echo "NOWAKE"
      ' 2>&1)
}

send_count() {
  wc -l < "$STUB_LOG" 2>/dev/null | tr -d '[:space:]'
}

fresh_state() {
  rm -rf "$STATE"; mkdir -p "$STATE"
  seed_meta
  : > "$STUB_LOG"
}

# The looping body: the same failing-command status line, appended over and over.
# shellcheck disable=SC2016  # the backticks are a literal part of the status line, no expansion intended.
LOOP_LINE='working: retrying `npm test` after ECONNRESET'
append_loop() {  # <count>
  local i
  for ((i = 0; i < $1; i++)); do printf '%s\n' "$LOOP_LINE" >> "$STATUS"; done
}

# --- (0) the identical-trailing predicate is objective ------------------------
fresh_state
append_loop 3
[ -n "$(retry_loop_trailing_body "$STATUS")" ] \
  || fail "three identical trailing lines must satisfy retry_loop_trailing_body"
# Two identical lines is below the default threshold.
: > "$STATUS"; append_loop 2
[ -z "$(retry_loop_trailing_body "$STATUS")" ] \
  || fail "two identical lines must NOT satisfy the 3+ threshold"
# Three lines where the last differs breaks the run.
: > "$STATUS"; append_loop 2; printf 'working: made progress, moving on\n' >> "$STATUS"
[ -z "$(retry_loop_trailing_body "$STATUS")" ] \
  || fail "a varied last line must break the identical run"
pass "the identical-trailing-body predicate is objective (3+ byte-identical lines)"

# --- (1) the steer fires ONCE on the first qualifying poll --------------------
fresh_state
append_loop 3
run_poll
assert_contains "$OUT" "NOWAKE" "the first steer poll must not wake"
[ "$(send_count)" = 1 ] || fail "a 3x-identical loop must send exactly one steer, sent $(send_count)"
grep -q 'stop retrying, append blocked:' "$STUB_LOG" \
  || fail "the steer must carry the documented stop-retrying message"
[ -n "$(cat "$STATE/.retry-loop-$KEY" 2>/dev/null || true)" ] \
  || fail "the episode steer marker must record the loop body hash"
assert_absent "$STATE/.retry-loop-escalated-$KEY" "the steer poll must not escalate yet"
pass "3+ identical status appends trigger exactly ONE stop-retrying steer, no wake"

# --- (2) idempotent: the SAME loop never re-steers ----------------------------
append_loop 2   # the worker keeps looping (more identical appends)
run_poll
assert_contains "$OUT" "check: retry-loop $TASK" "a still-looping worker must escalate on the next poll"
assert_contains "$OUT" "still looping after the stop-retrying steer" "the escalation must carry the continuing-loop context"
[ "$(send_count)" = 1 ] || fail "the escalation poll must NOT send a second steer, sent $(send_count)"
[ -n "$(cat "$STATE/.retry-loop-escalated-$KEY" 2>/dev/null || true)" ] \
  || fail "the escalation marker must be written"
grep -q 'retry-loop' "$STATE/.wake-queue" 2>/dev/null \
  || fail "the escalation must leave a durable wake-queue record"
pass "a continuing loop escalates check: retry-loop once, with no second steer"

# --- (3) no second escalation: repeat polls stay silent -----------------------
append_loop 2
run_poll
assert_contains "$OUT" "NOWAKE" "a repeat poll after the escalation must stay silent"
[ "$(send_count)" = 1 ] || fail "repeat polls must never send a second steer, sent $(send_count)"
pass "no second escalation and no second steer for the same episode"

# --- (4) a broken loop clears the episode; a NEW loop steers again ------------
printf 'working: fixed the connection, tests running\n' >> "$STATUS"
run_poll   # trailing body now varies: run breaks, episode clears
assert_contains "$OUT" "NOWAKE" "a broken loop must not wake"
assert_absent "$STATE/.retry-loop-$KEY" "a broken loop must clear the steer marker"
assert_absent "$STATE/.retry-loop-escalated-$KEY" "a broken loop must clear the escalation marker"
# A genuinely NEW loop body steers once again.
# shellcheck disable=SC2016  # the backticks are a literal part of the status line, no expansion intended.
printf 'working: retrying `pytest` after timeout\nworking: retrying `pytest` after timeout\nworking: retrying `pytest` after timeout\n' >> "$STATUS"
run_poll
[ "$(send_count)" = 2 ] || fail "a new distinct loop must steer once again, sent $(send_count)"
pass "a broken loop clears the episode and a new distinct loop steers once more"

# --- (5) a NON-looping worker (varied bodies) is never steered ----------------
fresh_state
printf 'working: step one done\nworking: step two done\nworking: step three done\n' >> "$STATUS"
run_poll
assert_contains "$OUT" "NOWAKE" "a varied-status worker must not wake"
[ "$(send_count)" = 0 ] || fail "a non-looping worker must never be steered, sent $(send_count)"
pass "a worker with varied status bodies is never steered"

# --- (6) secondmate and supervise=off windows are never steered ---------------
fresh_state
rm -f "$STATE/$TASK.meta"
printf 'window=%s\nbackend=tmux\nkind=secondmate\n' "$W" > "$STATE/$TASK.meta"
append_loop 3
run_poll
assert_contains "$OUT" "NOWAKE" "a secondmate window must never be steered"
[ "$(send_count)" = 0 ] || fail "a secondmate window must not be steered, sent $(send_count)"
fresh_state
rm -f "$STATE/$TASK.meta"
printf 'window=%s\nbackend=tmux\nsupervise=off\n' "$W" > "$STATE/$TASK.meta"
append_loop 3
run_poll
assert_contains "$OUT" "NOWAKE" "a supervise=off window must never be steered"
[ "$(send_count)" = 0 ] || fail "a supervise=off window must not be steered, sent $(send_count)"
pass "secondmate and supervise=off windows are never steered"

# --- (7) a send that cannot be confirmed escalates immediately ----------------
fresh_state
append_loop 3
STUB_EXIT=1 run_poll
assert_contains "$OUT" "check: retry-loop $TASK" "a failed steer delivery must escalate immediately"
assert_contains "$OUT" "steer delivery FAILED" "the escalation must name the failed delivery"
[ "$(send_count)" = 1 ] || fail "the failed-send path must still record exactly one send attempt, sent $(send_count)"
[ -n "$(cat "$STATE/.retry-loop-$KEY" 2>/dev/null || true)" ] \
  || fail "the failed-send path must still record the episode steer marker"
[ -n "$(cat "$STATE/.retry-loop-escalated-$KEY" 2>/dev/null || true)" ] \
  || fail "the failed-send path must record the escalation marker (no retry loop)"
# And a later poll stays silent - the failed send did not open a steer loop.
STUB_EXIT=0 run_poll
assert_contains "$OUT" "NOWAKE" "after a failed-send escalation, later polls stay silent"
[ "$(send_count)" = 1 ] || fail "after a failed-send escalation, no further steer is sent, sent $(send_count)"
pass "a failed steer delivery escalates once and never retries into a steer loop"

# --- (8) retry_loop_check reads only the status file (no backend capture) ------
fresh_state
append_loop 3
CAP_LOG="$STATE/.capture-log"
: > "$CAP_LOG"
FM_STATE_OVERRIDE="$STATE" FM_WAKE_QUEUE="$STATE/.wake-queue" \
      FM_WAKE_QUEUE_LOCK="$STATE/.wake-queue.lock" \
      FM_RETRY_LOOP_SEND_BIN="$STUB" STUB_LOG="$STUB_LOG" STUB_EXIT=0 \
      bash -c '
      . "'"$WATCH"'" >/dev/null 2>&1
      STATE="'"$STATE"'"
      fm_backend_capture() { printf "call\n" >> "'"$CAP_LOG"'"; }
      retry_loop_check "'"$W"'" "'"$TASK"'"
    ' >/dev/null 2>&1
CAPS=$(wc -l < "$CAP_LOG" | tr -d '[:space:]')
[ "$CAPS" = 0 ] || fail "retry_loop_check must add NO fm_backend_capture, found $CAPS call(s)"
pass "retry_loop_check reads only the status file, adding zero backend captures"

pass "fm-watch-retry-loop.test.sh: all checks passed"
