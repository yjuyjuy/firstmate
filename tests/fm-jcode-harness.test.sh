#!/usr/bin/env bash
# Behavior tests for jcode-harness self-detection and session-lock holder detection.
# jcode (github.com/1jehuang/jcode) is a Claude-Agent-SDK runtime that does NOT set
# CLAUDECODE; it sets JCODE_ACTIVE_PROVIDER / JCODE_RUNTIME_PROVIDER and runs as comm
# "jcode". Without recognition, fm-lock.sh could not find a harness in the ancestry and
# every jcode-run session fell into read-only mode (verified 2026-07-30).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-jcode-harness)

test_harness_detects_jcode_by_env_marker() {
  local out
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    JCODE_ACTIVE_PROVIDER=claude "$ROOT/bin/fm-harness.sh")
  assert_contains "$out" "jcode" "fm-harness did not detect jcode via JCODE_ACTIVE_PROVIDER"
  pass "fm-harness detects jcode via env marker"
}

test_fm_lock_recognizes_jcode_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/Users/cyuan/.jcode/builds/shared-server/jcode'; exit 0 ;;
  *"args="*) printf '%s\n' 'jcode'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize jcode as a live holder"
  pass "fm-lock recognizes jcode harness processes"
}

test_harness_detects_jcode_by_env_marker
test_fm_lock_recognizes_jcode_holder
