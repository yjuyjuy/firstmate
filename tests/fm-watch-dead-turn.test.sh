#!/usr/bin/env bash
# tests/fm-watch-dead-turn.test.sh - Visibility Gap-5, the watcher's dead-turn
# liveness tripwire (bin/fm-watch.sh dead_turn_check), which resumes or
# escalates a lane whose in-flight turn silently died after a reactive 429
# account rotation. Design:
# data/design-visibility-improvements/report.md "Gap 5" (private home record);
# mechanism and evidence: docs/design-visibility-improvements.md.
#
# Contract pinned here:
#   1. FIRST qualifying poll - recent last_429_ts + pane not busy + NO status
#      append since the 429 + not paused/captain-held - sends exactly ONE
#      automatic resume steer via the FM_DEAD_TURN_SEND_BIN seam, records
#      resume_probe_ts= in state/<id>.telemetry, and persists
#      state/.dead-turn-probe-<key> with the episode's last_429_ts. No wake.
#   2. NEXT poll, still not busy and still no status append since the 429:
#      escalates ONCE as `check: dead-turn <task>` via
#      state/.dead-turn-escalated-<key> (durable wake-queue record too).
#   3. NEVER a second probe for the same episode: repeat polls stay silent
#      after the escalation, and the send log stays at exactly one. A later
#      GENUINELY NEW last_429_ts is a new episode and may probe once again.
#   4. Recovery clears the episode silently: a busy pane, or a status append
#      after the 429 (before or after the probe), removes both markers, sends
#      nothing, and wakes nothing. It also records the episode as SPENT in
#      state/.dead-turn-resolved-<key>, so a later idle poll inside the same
#      window stays silent (the lane is healthy, not a new dead turn); only a
#      genuinely new last_429_ts re-arms an episode.
#   5. A declared pause / captain-hold is never probed and never alarmed.
#   6. An OLD last_429_ts (outside FM_DEAD_TURN_WINDOW) never trips: it drops
#      any in-progress episode markers without a wake or a send.
#   7. A send that cannot be confirmed (fm-send exits non-zero) records the
#      episode's single probe, escalates immediately with a delivery-FAILED
#      reason, and never retries into a probe loop.
#   8. The probe keeps sibling telemetry keys (account=, count_429=) intact and
#      pre-records its steer ts in Gap-4's .steer-stuck-<key> marker so Gap-4
#      does not double-escalate the probe steer.
#   9. Secondmate and supervise=off windows are never probed (their own home /
#      hands-off contract owns them).
#  10. dead_turn_check adds NO backend capture to the fast loop: it consumes
#      the stale loop's already-captured tail40 as an argument and its body
#      contains no fm_backend_capture, so the loop keeps exactly one capture
#      per window.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
assert_present "$WATCH" "bin/fm-watch.sh is missing"

# fm_meta_get reads the key=value telemetry file the check writes.
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

TMP=$(fm_test_tmproot fm-watch-dead-turn)
STATE="$TMP/state"
mkdir -p "$STATE"

W="default:w1:p2"
TASK="deadtask"
KEY=$(printf '%s' "$W" | tr ':/.' '___')
TEL="$STATE/$TASK.telemetry"
IDLE_TAIL=$'some idle text\n> no busy footer'
BUSY_TAIL=$'some content\nWorking...'

# A fresh 429, 2 seconds old: young enough to be inside the default
# FM_DEAD_TURN_WINDOW (900s) in every test.
fresh_429() {
  printf 'last_429_ts=%s\n' "$(( $(date +%s) - 2 ))" > "$TEL"
}

# The send seam stub, standing in for bin/fm-send.sh: it logs each invocation
# (target|message), stamps last_steer_ts on the task telemetry exactly like a
# confirmed fm-send submit does, and exits non-zero when STUB_EXIT=1 (mimicking
# an unconfirmed/failed delivery).
STUB="$TMP/fake-send.sh"
STUB_LOG="$TMP/send.log"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\$1" "\$2" >> "\$STUB_LOG"
[ "\${STUB_EXIT:-0}" = 1 ] && exit 1
if [ -f "\$STUB_STATE/\$1.telemetry" ]; then
  printf 'last_steer_ts=%s\n' "\$(date +%s)" >> "\$STUB_STATE/\$1.telemetry"
fi
exit 0
EOF
chmod +x "$STUB"
STUB_EXIT=0

seed_meta() {
  printf 'window=%s\nbackend=tmux\n' "$W" > "$STATE/$TASK.meta"
}

# run_check <tail> -> OUT (the wake reason on stdout, or NOWAKE).
# Drive dead_turn_check in a subshell: source the watcher (its guard returns
# before the lock/loop, loading only functions and libs), override STATE and
# the wake queue path, point the send seam at the stub, then call the
# function. wake() exits 0 after printing its reason, so an escalation ends the
# subshell with the reason on stdout; a calm case returns and we echo a
# sentinel. The state directory PERSISTS across calls, exactly like the real
# watcher's polls, so the episode state machine spans consecutive run_check
# calls.
run_check() {  # <tail>
  OUT=$(FM_STATE_OVERRIDE="$STATE" FM_WAKE_QUEUE="$STATE/.wake-queue" \
        FM_WAKE_QUEUE_LOCK="$STATE/.wake-queue.lock" \
        FM_DEAD_TURN_SEND_BIN="$STUB" \
        STUB_LOG="$STUB_LOG" STUB_STATE="$STATE" STUB_EXIT="$STUB_EXIT" \
        bash -c '
        . "'"$WATCH"'" >/dev/null 2>&1
        STATE="'"$STATE"'"
        dead_turn_check "'"$W"'" "'"$TASK"'" "$1"
        echo "NOWAKE"
      ' _ "$1" 2>&1)
}

send_count() {
  wc -l < "$STUB_LOG" | tr -d '[:space:]'
}

fresh_state() {
  rm -rf "$STATE"; mkdir -p "$STATE"
  seed_meta
  : > "$STUB_LOG"
  fresh_429
}

# --- (1) dead-turn probe fires ONCE on the first qualifying poll --------------
fresh_state
run_check "$IDLE_TAIL"
assert_contains "$OUT" "NOWAKE" "the probe poll must not wake"
[ "$(send_count)" = 1 ] || fail "the first qualifying poll must send exactly one resume steer, sent $(send_count)"
grep -q 'Resume your turn' "$STUB_LOG" \
  || fail "the resume steer must carry the resume-your-turn nudge"
[ -n "$(fm_meta_get "$TEL" resume_probe_ts)" ] \
  || fail "the probe must record resume_probe_ts in telemetry"
case "$(fm_meta_get "$TEL" resume_probe_ts)" in
  ''|*[!0-9]*) fail "resume_probe_ts must be numeric" ;;
esac
[ "$(cat "$STATE/.dead-turn-probe-$KEY" 2>/dev/null || true)" = "$(fm_meta_get "$TEL" last_429_ts)" ] \
  || fail "the episode probe marker must hold the probed-for last_429_ts"
assert_absent "$STATE/.dead-turn-escalated-$KEY" "the probe poll must not write the escalation marker"
pass "the first qualifying poll sends one resume steer and records the probe without waking"

# --- (2) escalation fires on the NEXT poll when the lane is STILL dead --------
run_check "$IDLE_TAIL"
assert_contains "$OUT" "check: dead-turn $TASK" "a still-dead lane on the next poll must escalate"
assert_contains "$OUT" "pane still idle, no status append since 429" "the escalation must carry the dead-turn context"
[ "$(send_count)" = 1 ] || fail "the escalation poll must NOT send a second steer, sent $(send_count)"
[ "$(cat "$STATE/.dead-turn-escalated-$KEY" 2>/dev/null || true)" = "$(fm_meta_get "$TEL" last_429_ts)" ] \
  || fail "the escalation marker must hold the escalated-for last_429_ts"
grep -q 'check' "$STATE/.wake-queue" 2>/dev/null \
  || fail "the escalation must leave a durable wake-queue record"
grep -q "dead-turn" "$STATE/.wake-queue" 2>/dev/null \
  || fail "the wake-queue record must name the dead-turn check"
pass "the next poll escalates check: dead-turn exactly once via the durable wake queue"

# --- (3) NO second probe: repeat polls stay silent ---------------------------
run_check "$IDLE_TAIL"
assert_contains "$OUT" "NOWAKE" "a repeat poll after the escalation must stay silent"
[ "$(send_count)" = 1 ] || fail "repeat polls must never send a second probe, sent $(send_count)"
pass "no second probe after the escalation (the episode stays silent, never a probe loop)"

# A genuinely NEW 429 episode may probe once again. Sleep 1s so the new
# last_429_ts is a DISTINCT timestamp (same-second writes would key as the
# same episode, which is exactly the idempotence this asserts against).
sleep 1
fresh_429
run_check "$IDLE_TAIL"
assert_contains "$OUT" "NOWAKE" "a fresh new episode's probe poll must not wake"
[ "$(send_count)" = 2 ] || fail "a genuinely new last_429_ts is a new episode that may probe once, sent $(send_count)"
pass "a genuinely new 429 episode starts fresh and probes once again"

# --- (4) recovery via a busy pane clears silently ----------------------------
fresh_state
run_check "$IDLE_TAIL"          # probe
[ "$(send_count)" = 1 ] || fail "setup probe must send once"
run_check "$BUSY_TAIL"          # lane went busy: the probe worked
assert_contains "$OUT" "NOWAKE" "a busy pane must not escalate and must not wake"
[ "$(send_count)" = 1 ] || fail "a recovered lane must not be probed again, sent $(send_count)"
assert_absent "$STATE/.dead-turn-probe-$KEY" "recovery must clear the probe marker"
assert_absent "$STATE/.dead-turn-escalated-$KEY" "recovery must clear the escalation marker"
[ "$(cat "$STATE/.dead-turn-resolved-$KEY" 2>/dev/null || true)" = "$(fm_meta_get "$TEL" last_429_ts)" ] \
  || fail "recovery must record the episode as spent for the stay-silent rule"
pass "recovery via a busy pane clears the episode silently"

# A RECOVERED episode stays silent: the lane idles again inside the same window
# after its busy recovery, and must NOT be re-probed (it is healthy, not a new
# dead turn). Only a fresh last_429_ts re-arms an episode.
run_check "$IDLE_TAIL"
assert_contains "$OUT" "NOWAKE" "an idle poll after a recovered episode must stay silent"
[ "$(send_count)" = 1 ] || fail "a recovered episode must never re-probe in the same window, sent $(send_count)"
assert_absent "$STATE/.dead-turn-probe-$KEY" "a spent episode must not re-arm the probe marker"
pass "a recovered episode stays silent when the pane idles again"

# A pane busy BEFORE any probe is simply never probed --------------------------
fresh_state
run_check "$BUSY_TAIL"
assert_contains "$OUT" "NOWAKE" "a busy pane with a fresh 429 must never probe"
[ "$(send_count)" = 0 ] || fail "a busy pane must not be probed, sent $(send_count)"
assert_absent "$STATE/.dead-turn-probe-$KEY" "a busy pane must not write the probe marker"
run_check "$IDLE_TAIL"          # idles again inside the window: still never probed
assert_contains "$OUT" "NOWAKE" "a pane that recovered on its own must stay silent when it idles again"
[ "$(send_count)" = 0 ] || fail "a self-recovered pane must never be probed, sent $(send_count)"
pass "a pane busy since its 429 is never probed, and stays silent when it idles again"

# --- (5) recovery via a NEW status append clears silently --------------------
fresh_state
run_check "$IDLE_TAIL"          # probe
[ "$(send_count)" = 1 ] || fail "setup probe must send once"
printf 'working: resumed after rotation\n' > "$STATE/$TASK.status"   # mtime now > last_429_ts
run_check "$IDLE_TAIL"
assert_contains "$OUT" "NOWAKE" "a status append after the 429 must clear the episode silently"
[ "$(send_count)" = 1 ] || fail "a recovered lane must not be probed again, sent $(send_count)"
assert_absent "$STATE/.dead-turn-probe-$KEY" "a status append must clear the probe marker"
assert_absent "$STATE/.dead-turn-escalated-$KEY" "a status append must clear the escalation marker"
[ "$(cat "$STATE/.dead-turn-resolved-$KEY" 2>/dev/null || true)" = "$(fm_meta_get "$TEL" last_429_ts)" ] \
  || fail "a status append must record the episode as spent"
run_check "$IDLE_TAIL"
assert_contains "$OUT" "NOWAKE" "an idle poll after a status-append recovery must stay silent"
[ "$(send_count)" = 1 ] || fail "a recovered episode must not re-probe, sent $(send_count)"
pass "recovery via a new status append clears the episode silently"

# A status append BEFORE any probe means no dead turn: never probed ------------
fresh_state
printf 'working: retrying after rate limit\n' > "$STATE/$TASK.status"
run_check "$IDLE_TAIL"
assert_contains "$OUT" "NOWAKE" "a lane that appended status after the 429 must never probe"
[ "$(send_count)" = 0 ] || fail "a lane with a fresh status append must not be probed, sent $(send_count)"
assert_absent "$STATE/.dead-turn-probe-$KEY" "a fresh status append must not write the probe marker"
pass "a lane with a status append since the 429 is never probed"

# --- (6) a paused / captain-held lane is never alarmed -----------------------
fresh_state
printf 'paused: waiting for rate-limit reset\n' > "$STATE/$TASK.status"
run_check "$IDLE_TAIL"
assert_contains "$OUT" "NOWAKE" "a paused lane must never be probed or alarmed"
[ "$(send_count)" = 0 ] || fail "a paused lane must not be probed, sent $(send_count)"
assert_absent "$STATE/.dead-turn-probe-$KEY" "a paused lane must not write the probe marker"
assert_absent "$STATE/.dead-turn-escalated-$KEY" "a paused lane must not write the escalation marker"
fresh_state
printf 'captain-held [key=k1]: awaiting captain decision\n' > "$STATE/$TASK.status"
run_check "$IDLE_TAIL"
assert_contains "$OUT" "NOWAKE" "a captain-held lane must never be probed or alarmed"
[ "$(send_count)" = 0 ] || fail "a captain-held lane must not be probed, sent $(send_count)"
pass "a declared pause or captain-hold is never probed and never alarmed"

# --- (7) an OLD last_429_ts never trips, and expiry drops episode state -------
fresh_state
run_check "$IDLE_TAIL"          # probe an episode
[ "$(send_count)" = 1 ] || fail "setup probe must send once"
assert_present "$STATE/.dead-turn-probe-$KEY" "the episode marker must exist before expiry"
printf 'last_429_ts=1\n' > "$TEL"   # long past the default 900s window
run_check "$IDLE_TAIL"
assert_contains "$OUT" "NOWAKE" "an old 429 outside the window must never trip"
[ "$(send_count)" = 1 ] || fail "an old 429 must not probe, sent $(send_count)"
assert_absent "$STATE/.dead-turn-probe-$KEY" "window expiry must drop the probe marker"
assert_absent "$STATE/.dead-turn-escalated-$KEY" "window expiry must drop the escalation marker"
assert_absent "$STATE/.dead-turn-resolved-$KEY" "window expiry must drop the resolved marker"
pass "an old 429 outside FM_DEAD_TURN_WINDOW never trips and expiry cleans the episode markers"

# --- (8) a failed send escalates immediately and never loops ------------------
STUB_EXIT=1
fresh_state
run_check "$IDLE_TAIL"
assert_contains "$OUT" "check: dead-turn $TASK" "a send that cannot be confirmed must escalate immediately"
assert_contains "$OUT" "delivery FAILED" "the escalation must say the resume steer could not be delivered"
[ "$(send_count)" = 1 ] || fail "the failed send still records the episode's single probe, sent $(send_count)"
assert_present "$STATE/.dead-turn-probe-$KEY" "a failed send must still record the probe marker"
assert_present "$STATE/.dead-turn-escalated-$KEY" "a failed send must still record the escalation marker"
run_check "$IDLE_TAIL"
assert_contains "$OUT" "NOWAKE" "a repeat poll after the failed-send escalation must stay silent"
[ "$(send_count)" = 1 ] || fail "a failed send must never retry into a probe loop, sent $(send_count)"
STUB_EXIT=0
pass "an unconfirmed resume steer escalates immediately and never retries into a probe loop"

# --- (9) sibling telemetry keys survive, Gap-4 marker pre-recorded ------------
rm -rf "$STATE"; mkdir -p "$STATE"
seed_meta
: > "$STUB_LOG"
# Seed sibling keys AND the fresh 429 in one write; a later fresh_429 would
# truncate the file and erase them (writing telemetry in place is exactly the
# fm_telemetry_set contract this case asserts).
printf 'account=claude-2\ncount_429=7\nlast_429_ts=%s\n' "$(( $(date +%s) - 2 ))" > "$TEL"
run_check "$IDLE_TAIL"
[ "$(fm_meta_get "$TEL" account)" = claude-2 ] || fail "the probe must not clobber account="
[ "$(fm_meta_get "$TEL" count_429)" = 7 ] || fail "the probe must not clobber count_429="
[ -n "$(fm_meta_get "$TEL" last_steer_ts)" ] \
  || fail "the probe steer must stamp last_steer_ts like confirmed fm-send delivery"
[ "$(cat "$STATE/.steer-stuck-$KEY" 2>/dev/null || true)" = "$(fm_meta_get "$TEL" last_steer_ts)" ] \
  || fail "the probe must pre-record its steer ts in Gap-4's .steer-stuck marker"
pass "the probe preserves sibling telemetry keys and pre-records Gap-4's warned marker"

# --- (10) secondmate and supervise=off windows are never probed ---------------
fresh_state
rm -f "$STATE/$TASK.meta"
printf 'window=%s\nbackend=tmux\nkind=secondmate\n' "$W" > "$STATE/$TASK.meta"
run_check "$IDLE_TAIL"
assert_contains "$OUT" "NOWAKE" "a secondmate window must never be probed or alarmed"
[ "$(send_count)" = 0 ] || fail "a secondmate window must not be probed, sent $(send_count)"
seed_meta
rm -f "$STATE/$TASK.meta"
printf 'window=%s\nbackend=tmux\nsupervise=off\n' "$W" > "$STATE/$TASK.meta"
run_check "$IDLE_TAIL"
assert_contains "$OUT" "NOWAKE" "a supervise=off window must never be probed or alarmed"
[ "$(send_count)" = 0 ] || fail "a supervise=off window must not be probed, sent $(send_count)"
pass "secondmate and supervise=off windows are never probed"

# --- (11) ZERO new backend capture in the fast loop ---------------------------
# Mock fm_backend_capture to log invocations, then drive dead_turn_check on the
# existing fresh-429 fixture: it must perform zero captures, since it consumes
# the loop's already-captured tail40 as its argument.
fresh_state
CAP_LOG="$STATE/.capture-log"
: > "$CAP_LOG"
FM_STATE_OVERRIDE="$STATE" FM_WAKE_QUEUE="$STATE/.wake-queue" \
      FM_WAKE_QUEUE_LOCK="$STATE/.wake-queue.lock" \
      FM_DEAD_TURN_SEND_BIN="$STUB" \
      STUB_LOG="$STUB_LOG" STUB_STATE="$STATE" STUB_EXIT=0 \
      bash -c '
      . "'"$WATCH"'" >/dev/null 2>&1
      STATE="'"$STATE"'"
      fm_backend_capture() { printf "call\n" >> "'"$CAP_LOG"'"; }
      dead_turn_check "'"$W"'" "'"$TASK"'" "$1"
    ' _ "$IDLE_TAIL" >/dev/null 2>&1
CAPS=$(wc -l < "$CAP_LOG" | tr -d '[:space:]')
[ "$CAPS" = 0 ] \
  || fail "dead_turn_check must add NO fm_backend_capture, found $CAPS call(s)"
# The function body must also contain no capture call of its own.
check_body=$(awk '/^dead_turn_check\(\)/{f=1} f{print} f&&/^}/{exit}' "$WATCH")
if printf '%s' "$check_body" | grep -q 'fm_backend_capture'; then
  fail "dead_turn_check must add NO fm_backend_capture (it reuses the passed tail40)"
fi
# And the stale loop must still have exactly one per-window fm_backend_capture.
# shellcheck disable=SC2016  # literal grep pattern, no expansion intended.
caps=$(grep -c 'fm_backend_capture "\$(window_backend' "$WATCH" || true)
[ "$caps" = 1 ] || fail "the stale loop must keep exactly one per-window fm_backend_capture, found $caps"
pass "dead_turn_check adds zero backend captures; the loop keeps its single capture"

pass "fm-watch-dead-turn.test.sh: all checks passed"