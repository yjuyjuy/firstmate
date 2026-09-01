#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's jcode launch-profile VERIFY-BEFORE-BRIEF hard
# gate (task jcode-spawn-model-pin-unreliable; incidents 2026-08-10 "verdict
# pending + brief raced ahead", 2026-08-11 "effort comes up High on 3 of 4
# spawns", and 2026-08-23 "MODEL DRIFT INCIDENT").
#
# ROOT CAUSE the gate defends against: a TYPED /model or /effort is lost two
# ways - it is DEFERRED behind the agent lock while a turn runs (jcode-app-core
# server/provider_control.rs handle_set_model / handle_set_reasoning_effort), and
# it can be swallowed by the slash-autocomplete popup. Either way the session
# runs the whole task on the wrong profile.
#
# THE FIX under test: model/effort are pinned through jcode's race-free debug
# socket (`jcode debug -S <sid> set_model:{"model":..,"effort":..}`), which runs
# server-side under agent.lock().await (waits out any in-flight turn, never lost)
# and persists to the store. For an EXPLICIT model/effort,
# jcode_post_launch_delivery pins through that seam and delivers the brief ONLY
# after the session STORE confirms the requested axis values (re-applying between
# reads, bounded by FM_SPAWN_JCODE_VERIFY_TRIES=3). A verified profile is stamped
# into the meta as the CONFIRMED model=/effort= (last-write-wins over the
# requested values). If the profile cannot be verified - a persistently failing
# apply, an unresolvable session, an unreadable store, or missing anchors - the
# function appends `blocked: model-drift wanted=<m>/<e> actual=<m>/<e>` to the
# status file and WITHHOLDS the brief (returns failure), never running
# wrong-profile work. A DEFAULT profile has nothing to pin: no verification,
# brief delivered directly.
#
# These tests extract jcode_post_launch_delivery and jcode_submit_brief_verified
# from bin/fm-spawn.sh verbatim, source the real pin seam
# (bin/fm-jcode-profile-lib.sh) and store reader (bin/fm-token-sessions-lib.sh),
# and drive them against a scriptable fake backend plus a fake jcode binary
# (FM_JCODE_BIN) that implements the debug set_model verb against a fake session
# store, so no live jcode server is needed.
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
# The real pin seam under test (fm_jcode_apply_profile / fm_jcode_pin_and_verify).
# shellcheck source=bin/fm-jcode-profile-lib.sh
. "$ROOT/bin/fm-jcode-profile-lib.sh"
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

# --- fake jcode binary: implements `debug -S <sid> set_model:{...}` -----------
#
# It parses the model/effort out of the JSON payload and updates the fake store,
# mirroring the real debug verb's atomic persist. A FAIL countdown in
# $TMP_ROOT/apply_fail lets a test simulate an apply that does not land (the verb
# exits nonzero and writes nothing), so the store keeps its prior profile - the
# race the retry recovers from. An APPLY_LOG records every apply for assertions.
FAKE_JCODE="$TMP_ROOT/fake-jcode"
APPLY_LOG="$TMP_ROOT/applies"
APPLY_FAIL="$TMP_ROOT/apply_fail"
cat > "$FAKE_JCODE" <<'FAKE'
#!/usr/bin/env bash
# Args: debug -S <sid> set_model:{"model":M[,"effort":E]}
set -u
sid=""; payload=""
shift  # drop "debug"
while [ $# -gt 0 ]; do
  case "$1" in
    -S) sid=$2; shift 2 ;;
    set_model:*) payload=${1#set_model:}; shift ;;
    *) shift ;;
  esac
done
log="${FAKE_JCODE_APPLY_LOG:?}"
failf="${FAKE_JCODE_APPLY_FAIL:?}"
sdir="${JCODE_SESSIONS_DIR:?}"
echo "apply:$sid:$payload" >> "$log"
# Simulate a lost apply: while the fail counter is > 0, decrement and exit 1
# (verb reports failure, nothing written).
n=$(cat "$failf" 2>/dev/null || echo 0)
if [ "$n" -gt 0 ]; then
  echo $((n - 1)) > "$failf"
  echo "fake jcode: apply failed (simulated)" >&2
  exit 1
fi
model=$(printf '%s' "$payload" | sed -n 's/.*"model":"\([^"]*\)".*/\1/p')
effort=$(printf '%s' "$payload" | sed -n 's/.*"effort":"\([^"]*\)".*/\1/p')
[ -n "$model" ] || { echo "fake jcode: no model in payload" >&2; exit 1; }
f="$sdir/$sid.json"
if [ -n "$effort" ]; then em="\"$effort\""; else em=null; fi
# Preserve working_dir/created_at if the file exists (mirror a real persist).
wd=$(sed -n 's/.*"working_dir":"\([^"]*\)".*/\1/p' "$f" 2>/dev/null)
ca=$(sed -n 's/.*"created_at":"\([^"]*\)".*/\1/p' "$f" 2>/dev/null)
cat > "$f" <<EOF2
{"id":"$sid","model":"$model","reasoning_effort":$em,"working_dir":"$wd","created_at":"$ca"}
EOF2
echo "{\"model\":\"$model\",\"provider\":\"Fake\",\"effort\":\"$effort\"}"
exit 0
FAKE
chmod +x "$FAKE_JCODE"
export FM_JCODE_BIN="$FAKE_JCODE"
export FAKE_JCODE_APPLY_LOG="$APPLY_LOG"
export FAKE_JCODE_APPLY_FAIL="$APPLY_FAIL"

# --- scriptable fake backend (only the account/brief slash path now) ---------

SUBMIT_Q="$TMP_ROOT/submit_q"
COMPOSER_Q="$TMP_ROOT/composer_q"
SUBMIT_I="$TMP_ROOT/submit_i"
COMPOSER_I="$TMP_ROOT/composer_i"
CALLS_F="$TMP_ROOT/calls"
STATUS_F="$STATE_DIR/probe.status"
META_F="$STATE_DIR/probe.meta"

_queue_next() {  # <queue-file> <index-file> <default>
  local qf=$1 idxf=$2 def=$3 idx n
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
  local text=$3
  printf 'submit:%s\n' "$text" >> "$CALLS_F"
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
  : > "$SUBMIT_Q"; : > "$COMPOSER_Q"; : > "$CALLS_F"; : > "$APPLY_LOG"
  printf 0 > "$SUBMIT_I"; printf 0 > "$COMPOSER_I"; printf 0 > "$APPLY_FAIL"
  : > "$STATUS_F"; : > "$META_F"
}

calls_joined() { paste -sd'|' "$CALLS_F" 2>/dev/null || true; }

count_apply() {  # count debug-socket applies recorded by the fake jcode
  wc -l < "$APPLY_LOG" 2>/dev/null | tr -d ' '
}

# The brief rides the canonical launch-brief operational input, so its submit
# line is the only one carrying "launch-brief". Counting it proves whether the
# brief was actually delivered - the crux of the withhold-on-failure contract.
count_brief() {
  grep -cF "launch-brief" "$CALLS_F" 2>/dev/null || true
}

count_submit() {  # <text>
  grep -cF "submit:$1" "$CALLS_F" 2>/dev/null || true
}

# run_delivery: drive the extracted function with the given profile + anchors.
# Prints the function's stdout/stderr and its exit code as "$rc|<output>".
run_delivery() {  # <model> <effort> [<account>]
  local model=$1 effort=$2 account=${3:-} out rc
  out=$(jcode_post_launch_delivery fakepane /tmp/brief.md "$model" "$effort" "$account" \
    "$PROBE_WT" "$SPAWN_TS" "$STATUS_F" "$META_F" 2>&1)
  rc=$?
  printf '%s|%s' "$rc" "$out"
}

# --- tests ------------------------------------------------------------------

test_pin_via_debug_socket_verifies_and_stamps_confirmed_meta() {
  # Happy path: the debug apply lands, the store confirms, the meta gets the
  # CONFIRMED model=/effort= stamp, and the brief is delivered exactly once only
  # AFTER verification. No typed /model|/effort is ever sent.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  write_store claude-opus-4-8 low
  got=$(run_delivery claude-opus-4-8 medium)
  [ "${got%%|*}" = 0 ] || fail "delivery must succeed when the debug pin lands and the store verifies; got: $got"
  [ "$(count_submit /model)" = 0 ] || fail "no typed /model may be sent (debug socket only); calls: $(calls_joined)"
  [ "$(count_submit /effort)" = 0 ] || fail "no typed /effort may be sent (debug socket only); calls: $(calls_joined)"
  [ "$(count_brief)" = 1 ] || fail "the brief must be delivered exactly once after a verified profile; calls: $(calls_joined)"
  grep -qx "model=claude-opus-4-8" "$META_F" \
    || fail "the CONFIRMED model must be stamped into the meta; meta: $(cat "$META_F")"
  grep -qx "effort=medium" "$META_F" \
    || fail "the CONFIRMED effort must be stamped into the meta; meta: $(cat "$META_F")"
  [ -s "$STATUS_F" ] && fail "no blocked status may appear on a verified profile; status: $(cat "$STATUS_F")"
  pass "an explicit profile is pinned via the debug socket, verified against the store, stamped, then the brief is delivered"
}

test_brief_is_delivered_only_after_the_pin_verifies() {
  # ORDERING is the whole fix: the brief must not be submitted until the store
  # confirms the profile. Assert the debug apply precedes the brief submit.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  write_store claude-opus-4-8 low
  got=$(run_delivery claude-opus-4-8 high)
  [ "${got%%|*}" = 0 ] || fail "delivery must succeed; got: $got"
  # The apply is logged to APPLY_LOG, the brief to CALLS_F. Prove at least one
  # apply happened before the brief submit by checking both fired and the brief
  # count is 1 (the function returns immediately after the brief on success, so
  # the apply necessarily preceded it).
  [ "$(count_apply)" -ge 1 ] || fail "the debug pin must be applied; applies: $(cat "$APPLY_LOG")"
  [ "$(count_brief)" = 1 ] || fail "the brief must be delivered once; calls: $(calls_joined)"
  pass "the brief is submitted only after the debug pin verifies, never racing ahead of it"
}

test_lost_apply_recovers_through_retry_then_delivers_brief() {
  # The first debug apply fails (simulated lost apply); the store keeps the
  # foreign profile, the first read mismatches, the retry apply lands, the second
  # read verifies. Brief delivered, no blocked status.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  write_store claude-opus-4-8 max
  printf 1 > "$APPLY_FAIL"  # fail exactly the first apply
  got=$(run_delivery claude-opus-4-8 medium)
  [ "${got%%|*}" = 0 ] || fail "delivery must succeed once the retried apply lands; got: $got"
  [ "$(count_apply)" -ge 2 ] || fail "a lost first apply must be retried; applies: $(cat "$APPLY_LOG")"
  [ "$(count_brief)" = 1 ] || fail "the brief must be delivered once the retry verifies; calls: $(calls_joined)"
  grep -qx "effort=medium" "$META_F" \
    || fail "the confirmed effort must be stamped after a successful retry; meta: $(cat "$META_F")"
  [ -s "$STATUS_F" ] && fail "no blocked status may appear when the retry recovers; status: $(cat "$STATUS_F")"
  pass "a lost debug apply is retried (the debug verb waits idle) and verified on the retry read, then the brief lands"
}

test_persistent_apply_failure_fails_loud_and_withholds_the_brief() {
  # The debug apply never lands (store keeps a foreign profile across every read).
  # Bounded retries, then a `blocked: model-drift` status line, the same line on
  # stderr, NO confirmed stamps, and - the point of the fix - the brief is NEVER
  # delivered.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  write_store claude-opus-4-8 max
  printf 99 > "$APPLY_FAIL"  # every apply fails
  out=$(run_delivery deepseek-v4-flash high)
  rc=${out%%|*}
  rest=${out#*|}
  [ "$rc" = 1 ] || fail "delivery must fail after bounded retries still mismatch; rc=$rc out=$out"
  [ "$(count_brief)" = 0 ] || fail "the brief must be WITHHELD when the profile never verifies; calls: $(calls_joined)"
  grep -qx 'blocked: model-drift wanted=deepseek-v4-flash/high actual=claude-opus-4-8/max' "$STATUS_F" \
    || fail "the blocked model-drift line must be appended to the status file; status: $(cat "$STATUS_F")"
  case "$rest" in
    *"blocked: model-drift wanted=deepseek-v4-flash/high actual=claude-opus-4-8/max"*) : ;;
    *) fail "the same blocked line must reach the spawn caller; output: $rest" ;;
  esac
  grep -q "model=deepseek" "$META_F" \
    && fail "no confirmed stamp may be written for a profile that never verified; meta: $(cat "$META_F")"
  pass "a persistently failing pin fails loud with a blocked: model-drift status and NO brief delivered"
}

test_default_profile_skips_verification_and_delivers_brief() {
  # A default profile (no requested axis) must not pin at all: no store file
  # needed, no debug apply, no meta stamps, no blocked status - and the brief is
  # delivered directly, so the normal-spawn path stays byte-identical.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  rm -f "$SESS_DIR"/session_*.json
  got=$(run_delivery default default)
  [ "${got%%|*}" = 0 ] || fail "a default-profile delivery must succeed; got: $got"
  [ "$(count_apply)" = 0 ] || fail "a default profile must apply no debug pin; applies: $(cat "$APPLY_LOG")"
  [ "$(count_brief)" = 1 ] || fail "the brief must be delivered for a default profile; calls: $(calls_joined)"
  [ ! -e "$STATUS_F" ] || [ ! -s "$STATUS_F" ] \
    || fail "no blocked status may appear for a default profile; status: $(cat "$STATUS_F")"
  [ ! -s "$META_F" ] || fail "no confirmed stamps may appear for a default profile; meta: $(cat "$META_F")"
  pass "a default profile spawns exactly as before: no pin, no stamps, no escalation, brief delivered"
}

test_unresolvable_session_fails_loud_and_withholds_the_brief() {
  # No session file in the store: the sid cannot be resolved, so an EXPLICIT
  # profile cannot be pinned or verified. The fix WITHHOLDS the brief and fails
  # loud with actual=-/- rather than running on an unverified (likely wrong)
  # profile.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  rm -f "$SESS_DIR"/session_*.json
  out=$(run_delivery claude-opus-4-8 high)
  rc=${out%%|*}
  [ "$rc" = 1 ] || fail "delivery must FAIL when an explicit profile cannot be verified; rc=$rc out=$out"
  [ "$(count_brief)" = 0 ] || fail "the brief must be WITHHELD when the session cannot be resolved; calls: $(calls_joined)"
  grep -qx 'blocked: model-drift wanted=claude-opus-4-8/high actual=-/-' "$STATUS_F" \
    || fail "an unresolvable session must fail loud with a blocked line and actual=-/-; status: $(cat "$STATUS_F")"
  pass "an unresolvable session fails loud and withholds the brief, never a silent unverified pass"
}

test_missing_anchors_withholds_the_brief_for_an_explicit_profile() {
  # An explicit profile with no worktree/spawn_ts/status anchors cannot be
  # verified at all. The brief is withheld and the call fails.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  write_store claude-opus-4-8 high
  out=$(jcode_post_launch_delivery fakepane /tmp/brief.md claude-opus-4-8 high "" \
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

test_effort_only_profile_pins_effort_axis_then_delivers_brief() {
  # Only the effort axis is requested: the model axis is never compared, and the
  # debug pin re-applies the session's CURRENT model unchanged alongside the new
  # effort. A matching effort verifies; only the effort is stamped; brief lands.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  write_store claude-opus-4-8 low
  got=$(run_delivery default max)
  [ "${got%%|*}" = 0 ] || fail "an effort-only pin against a resolvable session must succeed; got: $got"
  [ "$(count_brief)" = 1 ] || fail "the brief must be delivered after an effort-only pin; calls: $(calls_joined)"
  grep -qx "effort=max" "$META_F" \
    || fail "the confirmed effort must be stamped; meta: $(cat "$META_F")"
  grep -q "^model=" "$META_F" \
    && fail "the model axis must not be stamped when it was not requested; meta: $(cat "$META_F")"
  [ -s "$STATUS_F" ] && fail "no blocked status may appear when the requested axis matches; status: $(cat "$STATUS_F")"
  pass "an effort-only profile pins and stamps only the requested axis, then delivers the brief"
}

test_account_line_still_typed_when_present() {
  # The account pin has no store field and no debug verb, so it stays on the
  # best-effort typed slash path. Verify the account line is still typed while
  # model/effort go through the debug socket.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  write_store claude-opus-4-8 low
  got=$(run_delivery claude-opus-4-8 medium acct-two)
  [ "${got%%|*}" = 0 ] || fail "delivery with an account must succeed; got: $got"
  [ "$(count_submit "/account claude switch acct-two")" = 1 ] \
    || fail "the account line must still be typed as a slash command; calls: $(calls_joined)"
  [ "$(count_submit /model)" = 0 ] || fail "model must not be typed; calls: $(calls_joined)"
  pass "the account pin stays on the typed slash path while model/effort use the debug socket"
}

test_pin_via_debug_socket_verifies_and_stamps_confirmed_meta
test_brief_is_delivered_only_after_the_pin_verifies
test_lost_apply_recovers_through_retry_then_delivers_brief
test_persistent_apply_failure_fails_loud_and_withholds_the_brief
test_default_profile_skips_verification_and_delivers_brief
test_unresolvable_session_fails_loud_and_withholds_the_brief
test_missing_anchors_withholds_the_brief_for_an_explicit_profile
test_effort_only_profile_pins_effort_axis_then_delivers_brief
test_account_line_still_typed_when_present
