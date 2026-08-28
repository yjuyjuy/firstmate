#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's jcode launch-profile VERIFY-BEFORE-BRIEF hard
# gate (task fix-jcode-spawn-model-pin; incidents 2026-08-10 "verdict pending +
# brief raced ahead" and 2026-08-23 "MODEL DRIFT INCIDENT").
#
# ROOT CAUSE the gate defends against: jcode DEFERS a /model or /effort change
# behind the agent lock while a turn is running (projects/jcode server
# provider_control.rs handle_set_model / handle_set_reasoning_effort). Submitting
# the brief STARTS a turn, so a /model|/effort sent after the brief queues and
# never applies - the session runs the whole task on the wrong model. While the
# session is IDLE (before the brief) a /model|/effort applies and persists to the
# store immediately.
#
# So for an EXPLICIT model/effort, jcode_post_launch_delivery pins the profile
# while idle, reads the session store back, and delivers the brief ONLY after the
# store CONFIRMS the requested axis values (re-sending the idle slash between
# reads, bounded by FM_SPAWN_JCODE_VERIFY_TRIES=3). A verified profile is stamped
# into the meta as the CONFIRMED model=/effort= (last-write-wins over the
# requested values). If the profile cannot be verified - a lost slash race, an
# unresolvable session, an unreadable store, or missing anchors - the function
# appends `blocked: model-drift wanted=<m>/<e> actual=<m>/<e>` to the status file
# and WITHHOLDS the brief (returns failure), never running wrong-model work. A
# DEFAULT profile has nothing to pin: no verification, brief delivered directly.
#
# These tests extract jcode_post_launch_delivery and jcode_submit_brief_verified
# from bin/fm-spawn.sh verbatim (the same awk-extraction the brief-submit suite
# uses) and drive them against a scriptable fake backend plus a fake jcode
# session store (JCODE_SESSIONS_DIR), so no live jcode server is needed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-jcode-profile-verify)

# Extract the functions under test from bin/fm-spawn.sh verbatim.
FN_FILE="$TMP_ROOT/jcode_delivery.sh"
SESS_DIR="$TMP_ROOT/sessions"
STATE_DIR="$TMP_ROOT/state"
mkdir -p "$TMP_ROOT" "$SESS_DIR" "$STATE_DIR"
awk '
  /^jcode_post_launch_delivery\(\) \{/ { grab = 1 }
  /^jcode_submit_brief_verified\(\) \{/ { grab = 1 }
  grab { print }
  grab && /^\}/ { grab = 0 }
' "$ROOT/bin/fm-spawn.sh" > "$FN_FILE"
grep -q '^jcode_post_launch_delivery()' "$FN_FILE" \
  || fail "could not extract jcode_post_launch_delivery() from bin/fm-spawn.sh"
grep -q '^jcode_submit_brief_verified()' "$FN_FILE" \
  || fail "could not extract jcode_submit_brief_verified() from bin/fm-spawn.sh"

export FM_ROOT="$ROOT"
export BACKEND=fake
# Zero the settle/wait so the tests run instantly. Keep the retry count at its
# default (3) unless a test overrides it.
export FM_SPAWN_JCODE_READY_POLLS=1
export FM_SPAWN_JCODE_BRIEF_SETTLE=0
export FM_SPAWN_JCODE_BRIEF_SUBMIT_TRIES=3
export FM_SPAWN_JCODE_VERIFY_SETTLE=0
export FM_SPAWN_JCODE_VERIFY_TRIES=3

# The real resolver + store reader run against the fake store dir.
# shellcheck source=bin/fm-token-sessions-lib.sh
. "$ROOT/bin/fm-token-sessions-lib.sh"
export JCODE_SESSIONS_DIR="$SESS_DIR"

# A fake session record the resolver can find: working_dir must realpath-match
# the anchor and created_at must be >= the spawn_ts anchor. The store file stem
# IS the session id (jcode names it <id>.json and the id carries the `session_`
# prefix), so the id field and the filename stem must match.
PROBE_WT="$TMP_ROOT/probe-worktree"
mkdir -p "$PROBE_WT"
SPAWN_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

write_store() {  # <model|-> <effort|->
  local model=$1 effort=$2 sess_file="$SESS_DIR/session_probe.json"
  # A "-" axis becomes a JSON null; a real value is a quoted JSON string.
  if [ "$model" = - ]; then model=null; else model="\"$model\""; fi
  if [ "$effort" = - ]; then effort=null; else effort="\"$effort\""; fi
  cat > "$sess_file" <<EOF
{"id":"session_probe","model":$model,"reasoning_effort":$effort,"working_dir":"$PROBE_WT","created_at":"$SPAWN_TS"}
EOF
}

# --- scriptable fake backend (same contract as the brief-submit suite) ------

SUBMIT_Q="$TMP_ROOT/submit_q"
COMPOSER_Q="$TMP_ROOT/composer_q"
SUBMIT_I="$TMP_ROOT/submit_i"
COMPOSER_I="$TMP_ROOT/composer_i"
CALLS_F="$TMP_ROOT/calls"
STATUS_F="$STATE_DIR/probe.status"
META_F="$STATE_DIR/probe.meta"

_queue_next() {  # <queue-file> <index-file> <default>
  local qf=$1 idxf=$2 def=$3 idx n line
  idx=$(cat "$idxf" 2>/dev/null || printf 0)
  n=$(wc -l < "$qf" 2>/dev/null || printf 0)
  n=${n// /}
  if [ "$n" -eq 0 ]; then
    printf '%s' "$def"
    return 0
  fi
  if [ "$idx" -ge "$n" ]; then
    sed -n "${n}p" "$qf"
    return 0
  fi
  idx=$((idx + 1))
  printf '%s' "$idx" > "$idxf"
  sed -n "${idx}p" "$qf"
}

fm_backend_send_text_submit() {  # <backend> <target> <text> [tries] [alpha] [settle]
  local text=$3 n
  printf 'submit:%s\n' "$text" >> "$CALLS_F"
  # MODEL/MAX are bound by the calling test; when a re-send of the same slash
  # line happens (a RETRY with FIX_ON_RESEND set), apply the profile to the
  # store exactly as a successful slash command would, so the next read verifies.
  if [ -n "${MODEL:-}" ] && [ -n "${FIX_ON_RESEND:-}" ] && [ "$text" = "/model $MODEL" ]; then
    n=$(grep -cF "submit:/model $MODEL" "$CALLS_F")
    if [ "$n" -gt 1 ]; then
      write_store "$MODEL" "${EFFORT:--}"
    fi
  fi
  _queue_next "$SUBMIT_Q" "$SUBMIT_I" unknown
}

fm_backend_composer_state() {  # <backend> <target>
  local v
  v=$(_queue_next "$COMPOSER_Q" "$COMPOSER_I" unknown)
  printf 'composer=%s\n' "$v" >> "$CALLS_F"
  printf '%s' "$v"
}

fm_backend_send_key() {  # <backend> <target> <key>
  printf 'key:%s\n' "$3" >> "$CALLS_F"
  return 0
}

# shellcheck source=/dev/null
. "$FN_FILE"

set_submit_queue() { printf '%s\n' "$@" > "$SUBMIT_Q"; }
set_composer_queue() { printf '%s\n' "$@" > "$COMPOSER_Q"; }

reset_fake() {
  : > "$SUBMIT_Q"; : > "$COMPOSER_Q"; : > "$CALLS_F"
  printf 0 > "$SUBMIT_I"; printf 0 > "$COMPOSER_I"
  : > "$STATUS_F"; : > "$META_F"
  unset MODEL EFFORT FIX_ON_RESEND
}

calls_joined() { paste -sd'|' "$CALLS_F" 2>/dev/null || true; }

count_submit() {  # <text>
  grep -cF "submit:$1" "$CALLS_F" 2>/dev/null || true
}

# The brief rides the canonical launch-brief operational input, so its submit
# line is the only one carrying "launch-brief". Counting it proves whether the
# brief was actually delivered - the crux of the withhold-on-failure contract.
count_brief() {
  grep -cF "launch-brief" "$CALLS_F" 2>/dev/null || true
}

# run_delivery: drive the extracted function with the given profile + anchors.
# Prints the function's stdout/stderr and its exit code as "$rc <output>".
run_delivery() {  # <model> <effort> [<fix-on-resend:0|1>]
  local model=$1 effort=$2 fix=${3:-0} out rc
  [ "$fix" = 1 ] && export FIX_ON_RESEND=1
  export MODEL="$model" EFFORT="$effort"
  out=$(jcode_post_launch_delivery fakepane /tmp/brief.md "$model" "$effort" "" \
    "$PROBE_WT" "$SPAWN_TS" "$STATUS_F" "$META_F" 2>&1)
  rc=$?
  printf '%s|%s' "$rc" "$out"
}

# --- tests ------------------------------------------------------------------

test_verified_profile_delivers_brief_and_stamps_confirmed_meta() {
  # Happy path: the store already shows the requested profile, so the first read
  # verifies. No re-send; the meta gets the CONFIRMED model=/effort= stamp; the
  # brief is delivered (exactly once) only AFTER verification.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  write_store deepseek-v4-flash high
  got=$(run_delivery deepseek-v4-flash high)
  [ "${got%%|*}" = 0 ] || fail "delivery must succeed when the store verifies on the first read; got: $got"
  [ "$(count_submit /model)" = 1 ] || fail "no /model re-send may happen on a verified first read; calls: $(calls_joined)"
  [ "$(count_submit /effort)" = 1 ] || fail "no /effort re-send may happen on a verified first read; calls: $(calls_joined)"
  [ "$(count_brief)" = 1 ] || fail "the brief must be delivered exactly once after a verified profile; calls: $(calls_joined)"
  grep -qx "model=deepseek-v4-flash" "$META_F" \
    || fail "the CONFIRMED model must be stamped into the meta; meta: $(cat "$META_F")"
  grep -qx "effort=high" "$META_F" \
    || fail "the CONFIRMED effort must be stamped into the meta; meta: $(cat "$META_F")"
  [ -s "$STATUS_F" ] && fail "no blocked status may appear on a verified profile; status: $(cat "$STATUS_F")"
  pass "a store that matches on the first read verifies instantly, stamps the confirmed profile, then delivers the brief"
}

test_brief_is_delivered_only_after_the_pin_verifies() {
  # ORDERING is the whole fix: the brief must not be submitted until the store
  # confirms the profile. Assert the first /model submit precedes the brief
  # submit in the recorded call order.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  write_store deepseek-v4-flash high
  got=$(run_delivery deepseek-v4-flash high)
  [ "${got%%|*}" = 0 ] || fail "delivery must succeed; got: $got"
  model_ln=$(grep -nF "submit:/model deepseek-v4-flash" "$CALLS_F" | head -1 | cut -d: -f1)
  brief_ln=$(grep -nF "launch-brief" "$CALLS_F" | head -1 | cut -d: -f1)
  [ -n "$model_ln" ] || fail "the /model pin must be recorded; calls: $(calls_joined)"
  [ -n "$brief_ln" ] || fail "the brief must be recorded; calls: $(calls_joined)"
  [ "$model_ln" -lt "$brief_ln" ] \
    || fail "the /model pin must precede the brief (verify BEFORE brief); calls: $(calls_joined)"
  pass "the brief is submitted only after the model pin, never racing ahead of it"
}

test_lost_slash_recovers_through_idle_retry_then_delivers_brief() {
  # The idle /model lost the popup race (store shows a different model). The
  # re-send (still idle, no brief yet) applies it - FIX_ON_RESEND flips the store
  # on the retry submit, as a successful slash command would - and the SECOND
  # read verifies. Exactly one re-send of each slash line, brief delivered, no
  # blocked status.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  write_store claude-opus-4-8 max
  got=$(run_delivery deepseek-v4-flash high 1)
  [ "${got%%|*}" = 0 ] || fail "delivery must succeed once the retried slash applies; got: $got"
  [ "$(count_submit /model)" = 2 ] || fail "exactly one /model re-send expected on a lost-first-submit; calls: $(calls_joined)"
  [ "$(count_submit /effort)" = 2 ] || fail "exactly one /effort re-send expected on a lost-first-submit; calls: $(calls_joined)"
  [ "$(count_brief)" = 1 ] || fail "the brief must be delivered once the retry verifies; calls: $(calls_joined)"
  grep -qx "model=deepseek-v4-flash" "$META_F" \
    || fail "the confirmed model must be stamped after a successful retry; meta: $(cat "$META_F")"
  [ -s "$STATUS_F" ] && fail "no blocked status may appear when the retry recovers; status: $(cat "$STATUS_F")"
  pass "a slash command lost to the popup race is re-sent while idle and verified on the retry read, then the brief lands"
}

test_persistent_mismatch_fails_loud_and_withholds_the_brief() {
  # The slash commands never land (store keeps a foreign profile across every
  # read). Bounded retries: exactly 3 store reads = the initial idle submit plus
  # 2 re-sends per slash line, then a `blocked: model-drift wanted=<m>/<e>
  # actual=<m>/<e>` status line, the same line on stderr, NO confirmed stamps,
  # and - the point of the fix - the brief is NEVER delivered.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  write_store claude-opus-4-8 max
  out=$(run_delivery deepseek-v4-flash high)
  rc=${out%%|*}
  rest=${out#*|}
  [ "$rc" = 1 ] || fail "delivery must fail after bounded retries still mismatch; rc=$rc out=$out"
  [ "$(count_submit /model)" = 3 ] || fail "bounded retries: exactly 3 /model submits expected (1 initial + 2 re-sends); calls: $(calls_joined)"
  [ "$(count_submit /effort)" = 3 ] || fail "bounded retries: exactly 3 /effort submits expected; calls: $(calls_joined)"
  [ "$(count_brief)" = 0 ] || fail "the brief must be WITHHELD when the profile never verifies; calls: $(calls_joined)"
  grep -qx 'blocked: model-drift wanted=deepseek-v4-flash/high actual=claude-opus-4-8/max' "$STATUS_F" \
    || fail "the blocked model-drift line must be appended to the status file; status: $(cat "$STATUS_F")"
  case "$rest" in
    *"blocked: model-drift wanted=deepseek-v4-flash/high actual=claude-opus-4-8/max"*) : ;;
    *) fail "the same blocked line must reach the spawn caller; output: $rest" ;;
  esac
  grep -q "model=deepseek" "$META_F" \
    && fail "no confirmed stamp may be written for a profile that never verified; meta: $(cat "$META_F")"
  pass "a persistently mismatched profile fails loud with a bounded retry count, a blocked: model-drift status, and NO brief delivered"
}

test_default_profile_skips_verification_and_delivers_brief() {
  # A default profile (no requested axis) must not verify at all: no store file
  # needed, no slash submits, no meta stamps, no blocked status - and the brief
  # is delivered directly, so the normal-spawn path stays byte-identical.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  rm -f "$SESS_DIR"/session_*.json
  got=$(run_delivery default default)
  [ "${got%%|*}" = 0 ] || fail "a default-profile delivery must succeed; got: $got"
  [ "$(count_submit /model)" = 0 ] || fail "a default profile must send no /model; calls: $(calls_joined)"
  [ "$(count_submit /effort)" = 0 ] || fail "a default profile must send no /effort; calls: $(calls_joined)"
  [ "$(count_brief)" = 1 ] || fail "the brief must be delivered for a default profile; calls: $(calls_joined)"
  [ ! -e "$STATUS_F" ] || [ ! -s "$STATUS_F" ] \
    || fail "no blocked status may appear for a default profile; status: $(cat "$STATUS_F")"
  [ ! -s "$META_F" ] || fail "no confirmed stamps may appear for a default profile; meta: $(cat "$META_F")"
  pass "a default profile spawns exactly as before: no verification, no stamps, no escalation, brief delivered"
}

test_unresolvable_session_fails_loud_and_withholds_the_brief() {
  # No session file in the store: the sid cannot be resolved, so an EXPLICIT
  # profile cannot be verified. The fix WITHHOLDS the brief and fails loud with
  # actual=-/- rather than running the task on an unverified (likely wrong)
  # model - the old behavior passed silently here, which is exactly the drift
  # this task removes.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  rm -f "$SESS_DIR"/session_*.json
  out=$(run_delivery deepseek-v4-flash high)
  rc=${out%%|*}
  [ "$rc" = 1 ] || fail "delivery must FAIL when an explicit profile cannot be verified; rc=$rc out=$out"
  [ "$(count_brief)" = 0 ] || fail "the brief must be WITHHELD when the session cannot be resolved; calls: $(calls_joined)"
  grep -qx 'blocked: model-drift wanted=deepseek-v4-flash/high actual=-/-' "$STATUS_F" \
    || fail "an unresolvable session must fail loud with a blocked line and actual=-/-; status: $(cat "$STATUS_F")"
  pass "an unresolvable session fails loud and withholds the brief, never a silent unverified pass"
}

test_missing_anchors_withholds_the_brief_for_an_explicit_profile() {
  # An explicit profile with no worktree/spawn_ts/status anchors cannot be
  # verified at all. The brief is withheld and the call fails, rather than
  # delivering on an unverifiable pin.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  write_store deepseek-v4-flash high
  export MODEL=deepseek-v4-flash EFFORT=high
  out=$(jcode_post_launch_delivery fakepane /tmp/brief.md deepseek-v4-flash high "" \
    "" "" "" "" 2>&1)
  rc=$?
  [ "$rc" = 1 ] || fail "delivery must fail when an explicit profile has no verification anchors; rc=$rc out=$out"
  [ "$(count_brief)" = 0 ] || fail "the brief must be withheld when the profile cannot be verified; calls: $(calls_joined)"
  case "$out" in
    *"the brief is withheld"*) : ;;
    *) fail "a missing-anchor explicit profile must warn that the brief is withheld; output: $out" ;;
  esac
  pass "an explicit profile with no verification anchors withholds the brief and fails loud"
}

test_effort_only_profile_verifies_effort_axis_then_delivers_brief() {
  # Only the effort axis is requested: the model axis is never compared, and a
  # mismatch on it alone must not block (the sweep enforces only requested
  # axes). A matching effort verifies; the confirmed effort is stamped; the brief
  # is delivered.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  write_store claude-opus-4-8 max
  got=$(run_delivery default max)
  [ "${got%%|*}" = 0 ] || fail "an effort-only verification against a matching store must succeed; got: $got"
  [ "$(count_brief)" = 1 ] || fail "the brief must be delivered after an effort-only verify; calls: $(calls_joined)"
  grep -qx "effort=max" "$META_F" \
    || fail "the confirmed effort must be stamped; meta: $(cat "$META_F")"
  grep -q "^model=" "$META_F" \
    && fail "the model axis must not be stamped when it was not requested; meta: $(cat "$META_F")"
  [ -s "$STATUS_F" ] && fail "no blocked status may appear when the requested axis matches; status: $(cat "$STATUS_F")"
  pass "an effort-only profile verifies and stamps only the requested axis, then delivers the brief"
}

test_verified_profile_delivers_brief_and_stamps_confirmed_meta
test_brief_is_delivered_only_after_the_pin_verifies
test_lost_slash_recovers_through_idle_retry_then_delivers_brief
test_persistent_mismatch_fails_loud_and_withholds_the_brief
test_default_profile_skips_verification_and_delivers_brief
test_unresolvable_session_fails_loud_and_withholds_the_brief
test_missing_anchors_withholds_the_brief_for_an_explicit_profile
test_effort_only_profile_verifies_effort_axis_then_delivers_brief
