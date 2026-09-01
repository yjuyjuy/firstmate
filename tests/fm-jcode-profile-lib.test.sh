#!/usr/bin/env bash
# Unit tests for bin/fm-jcode-profile-lib.sh (fm_jcode_apply_profile /
# fm_jcode_pin_and_verify) and the bin/fm-jcode-repin.sh drift re-pin, the
# race-free debug-socket pin that replaces the TUI slash-command popup race
# (task jcode-spawn-model-pin-unreliable). These drive the seam against a fake
# jcode binary (FM_JCODE_BIN) implementing the `debug -S <sid> set_model:{...}`
# verb over a fake session store, so no live jcode server is needed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-jcode-profile-lib)
SESS_DIR="$TMP_ROOT/sessions"
STATE_DIR="$TMP_ROOT/state"
mkdir -p "$SESS_DIR" "$STATE_DIR"

export JCODE_SESSIONS_DIR="$SESS_DIR"
# shellcheck source=bin/fm-token-sessions-lib.sh
. "$ROOT/bin/fm-token-sessions-lib.sh"
# shellcheck source=bin/fm-jcode-profile-lib.sh
. "$ROOT/bin/fm-jcode-profile-lib.sh"

SID=session_probe
WT="$TMP_ROOT/wt"
mkdir -p "$WT"
SPAWN_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

write_store() {  # <model|-> <effort|->
  local model=$1 effort=$2 f="$SESS_DIR/$SID.json"
  if [ "$model" = - ]; then model=null; else model="\"$model\""; fi
  if [ "$effort" = - ]; then effort=null; else effort="\"$effort\""; fi
  cat > "$f" <<EOF
{"id":"$SID","model":$model,"reasoning_effort":$effort,"working_dir":"$WT","created_at":"$SPAWN_TS"}
EOF
}

# Fake jcode binary implementing the debug set_model verb against the store.
FAKE_JCODE="$TMP_ROOT/fake-jcode"
APPLY_LOG="$TMP_ROOT/applies"
APPLY_FAIL="$TMP_ROOT/apply_fail"
cat > "$FAKE_JCODE" <<'FAKE'
#!/usr/bin/env bash
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
echo "apply:$sid:$payload" >> "${FAKE_JCODE_APPLY_LOG:?}"
n=$(cat "${FAKE_JCODE_APPLY_FAIL:?}" 2>/dev/null || echo 0)
if [ "$n" -gt 0 ]; then echo $((n - 1)) > "${FAKE_JCODE_APPLY_FAIL}"; exit 1; fi
sdir="${JCODE_SESSIONS_DIR:?}"
model=$(printf '%s' "$payload" | sed -n 's/.*"model":"\([^"]*\)".*/\1/p')
effort=$(printf '%s' "$payload" | sed -n 's/.*"effort":"\([^"]*\)".*/\1/p')
[ -n "$model" ] || { echo "no model" >&2; exit 1; }
f="$sdir/$sid.json"
[ -f "$f" ] || { echo "unknown session" >&2; exit 1; }
if [ -n "$effort" ]; then em="\"$effort\""; else em=null; fi
wd=$(sed -n 's/.*"working_dir":"\([^"]*\)".*/\1/p' "$f")
ca=$(sed -n 's/.*"created_at":"\([^"]*\)".*/\1/p' "$f")
cat > "$f" <<EOF2
{"id":"$sid","model":"$model","reasoning_effort":$em,"working_dir":"$wd","created_at":"$ca"}
EOF2
echo "{\"model\":\"$model\",\"effort\":\"$effort\"}"
exit 0
FAKE
chmod +x "$FAKE_JCODE"
export FM_JCODE_BIN="$FAKE_JCODE" FAKE_JCODE_APPLY_LOG="$APPLY_LOG" FAKE_JCODE_APPLY_FAIL="$APPLY_FAIL"

reset() { : > "$APPLY_LOG"; printf 0 > "$APPLY_FAIL"; }

# --- fm_jcode_bin -----------------------------------------------------------

test_fm_jcode_bin_prefers_override() {
  out=$(fm_jcode_bin)
  [ "$out" = "$FAKE_JCODE" ] || fail "fm_jcode_bin must honor FM_JCODE_BIN; got '$out'"
  pass "fm_jcode_bin returns the FM_JCODE_BIN override"
}

# --- fm_jcode_apply_profile -------------------------------------------------

test_apply_model_and_effort_writes_store() {
  reset; write_store claude-opus-4-8 low
  fm_jcode_apply_profile "$SID" claude-opus-4-8 medium || fail "apply must succeed"
  p=$(fm_session_store_profile "$SID")
  case "$p" in *"effort=medium"*) : ;; *) fail "store must show medium; got: $p" ;; esac
  pass "fm_jcode_apply_profile applies model+effort and persists to the store"
}

test_apply_effort_only_reuses_current_model() {
  reset; write_store claude-opus-4-8 low
  fm_jcode_apply_profile "$SID" - high || fail "effort-only apply must succeed"
  p=$(fm_session_store_profile "$SID")
  case "$p" in *"model=claude-opus-4-8"*) : ;; *) fail "model must be preserved; got: $p" ;; esac
  case "$p" in *"effort=high"*) : ;; *) fail "effort must be high; got: $p" ;; esac
  # The apply payload must carry the current model, not a bare effort.
  grep -q 'claude-opus-4-8' "$APPLY_LOG" || fail "effort-only apply must send the current model; log: $(cat "$APPLY_LOG")"
  pass "fm_jcode_apply_profile with model=- reuses the store's current model"
}

test_apply_effort_only_fails_without_a_store() {
  reset; rm -f "$SESS_DIR/$SID.json"
  fm_jcode_apply_profile "$SID" - high && fail "effort-only apply must fail with no readable store"
  pass "fm_jcode_apply_profile with model=- fails closed when the session store is unreadable"
}

test_apply_empty_sid_fails() {
  reset
  fm_jcode_apply_profile "" claude-opus-4-8 high && fail "apply with an empty sid must fail"
  pass "fm_jcode_apply_profile fails closed on an empty session id"
}

# --- fm_jcode_pin_and_verify ------------------------------------------------

test_pin_verify_success_prints_confirmed() {
  reset; write_store claude-opus-4-8 low
  out=$(fm_jcode_pin_and_verify "$SID" claude-opus-4-8 medium 3 0) || fail "pin+verify must succeed; out=$out"
  case "$out" in *"model=claude-opus-4-8"*) : ;; *) fail "must print confirmed model; out: $out" ;; esac
  case "$out" in *"effort=medium"*) : ;; *) fail "must print confirmed effort; out: $out" ;; esac
  pass "fm_jcode_pin_and_verify prints the confirmed store values on success"
}

test_pin_verify_retries_a_lost_apply() {
  reset; write_store claude-opus-4-8 max; printf 1 > "$APPLY_FAIL"
  out=$(fm_jcode_pin_and_verify "$SID" claude-opus-4-8 medium 3 0) || fail "pin+verify must recover from one lost apply; out=$out"
  n=$(wc -l < "$APPLY_LOG" | tr -d ' ')
  [ "$n" -ge 2 ] || fail "a lost apply must be retried; applies: $n"
  case "$out" in *"effort=medium"*) : ;; *) fail "must confirm the retried effort; out: $out" ;; esac
  pass "fm_jcode_pin_and_verify retries a lost apply and verifies on the next read"
}

test_pin_verify_exhausts_on_persistent_failure() {
  reset; write_store claude-opus-4-8 max; printf 99 > "$APPLY_FAIL"
  out=$(fm_jcode_pin_and_verify "$SID" deepseek-v4-flash high 3 0) && fail "pin+verify must fail when the apply never lands; out=$out"
  [ -z "$out" ] || fail "a failed pin+verify must print nothing; got: $out"
  pass "fm_jcode_pin_and_verify returns failure and prints nothing when the pin never verifies"
}

test_pin_verify_effort_only_ignores_model_axis() {
  reset; write_store claude-opus-4-8 low
  out=$(fm_jcode_pin_and_verify "$SID" - high 3 0) || fail "effort-only pin+verify must succeed; out=$out"
  case "$out" in *"model="*) fail "the model axis must not be printed when not requested; out: $out" ;; esac
  case "$out" in *"effort=high"*) : ;; *) fail "must confirm the effort axis; out: $out" ;; esac
  pass "fm_jcode_pin_and_verify verifies and prints only the requested axis"
}

# --- fm-jcode-repin.sh ------------------------------------------------------

REPIN="$ROOT/bin/fm-jcode-repin.sh"

run_repin() {  # <id>  (uses STATE_DIR as the home state)
  FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$STATE_DIR" \
    FM_SPAWN_JCODE_VERIFY_SETTLE=0 FM_SPAWN_JCODE_VERIFY_TRIES=3 \
    bash "$REPIN" "$1" 2>&1
}

test_repin_succeeds_when_store_can_be_pinned() {
  reset; write_store claude-opus-4-8 low
  fm_write_meta "$STATE_DIR/drifted.meta" \
    "harness=jcode" "model=claude-opus-4-8" "effort=medium" "session_id=$SID"
  out=$(run_repin drifted) || fail "repin must succeed; out=$out"
  case "$out" in *"re-pinned drifted"*) : ;; *) fail "repin must confirm success; out: $out" ;; esac
  p=$(fm_session_store_profile "$SID")
  case "$p" in *"effort=medium"*) : ;; *) fail "store must now show medium; got: $p" ;; esac
  pass "fm-jcode-repin.sh re-pins a drifted lane's recorded profile and confirms it"
}

test_repin_refuses_non_jcode() {
  reset
  fm_write_meta "$STATE_DIR/other.meta" "harness=claude" "model=x" "effort=y"
  run_repin other && fail "repin must refuse a non-jcode task"
  pass "fm-jcode-repin.sh refuses a non-jcode task"
}

test_repin_refuses_default_profile() {
  reset
  fm_write_meta "$STATE_DIR/def.meta" "harness=jcode" "model=default" "effort=default" "session_id=$SID"
  run_repin def && fail "repin must refuse a default profile"
  pass "fm-jcode-repin.sh refuses a default profile (nothing to pin)"
}

test_repin_fails_loud_when_unpinnable() {
  reset; write_store claude-opus-4-8 low; printf 99 > "$APPLY_FAIL"
  fm_write_meta "$STATE_DIR/stuck.meta" \
    "harness=jcode" "model=deepseek-v4-flash" "effort=high" "session_id=$SID"
  out=$(run_repin stuck) && fail "repin must fail when the pin never verifies; out=$out"
  case "$out" in *"did not verify"*) : ;; *) fail "repin must report the failure; out: $out" ;; esac
  case "$out" in *"escalate"*) : ;; *) fail "repin must tell the caller to escalate; out: $out" ;; esac
  pass "fm-jcode-repin.sh fails loud with an actionable diagnostic when it cannot re-pin"
}

test_fm_jcode_bin_prefers_override
test_apply_model_and_effort_writes_store
test_apply_effort_only_reuses_current_model
test_apply_effort_only_fails_without_a_store
test_apply_empty_sid_fails
test_pin_verify_success_prints_confirmed
test_pin_verify_retries_a_lost_apply
test_pin_verify_exhausts_on_persistent_failure
test_pin_verify_effort_only_ignores_model_axis
test_repin_succeeds_when_store_can_be_pinned
test_repin_refuses_non_jcode
test_repin_refuses_default_profile
test_repin_fails_loud_when_unpinnable
