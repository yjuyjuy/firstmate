#!/usr/bin/env bash
# tests/fm-pane-crash-lib.test.sh - immediate herdr pane-exit detection
# (bin/fm-pane-crash-lib.sh fm_pane_crash_capture).
#
# The contract under test (brief acceptance criteria):
#   1. Herdr backend only; on any other backend the path is a silent no-op
#      (no crash-tail, no wake).
#   2. On a confirmed dead herdr pane for a task WITH state/<id>.meta, write the
#      last ~20 pane lines to state/<id>.crash-tail AND enqueue exactly one
#      `check` wake with payload `pane-crashed <id>` through the real
#      fm_wake_append (the queue's one owner - never a hand-written record).
#   3. No state/<id>.meta -> no crash-tail, no wake.
#   4. Idempotent: a second detection for the same dead pane must not
#      double-enqueue or clobber a crash-tail already captured.
# It also pins the fail-safe: an `unknown` (not confidently dead) pane records
# nothing, so a transient read glitch never fabricates a crash.
#
# The dead-pane verdict and the pane tail read are owned by the herdr adapter
# and reached through the fm_backend_* dispatch; the test substitutes those two
# seam functions with deterministic stubs so no real herdr binary is needed. The
# wake-queue owner (fm_wake_append) is the REAL one from bin/fm-wake-lib.sh, so
# the record format asserted here is exactly the one the drain reads.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-pane-crash-lib.sh"
assert_present "$LIB" "bin/fm-pane-crash-lib.sh is missing"

TMP=$(fm_test_tmproot fm-pane-crash)
STATE="$TMP/state"
mkdir -p "$STATE"

# The real durable wake queue owner, pointed at this test's isolated state dir
# so fm_wake_append writes a real queue file we can assert against.
export FM_STATE_OVERRIDE="$STATE"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-pane-crash-lib.sh
. "$LIB"

# --- deterministic backend seam stubs ----------------------------------------
# fm_backend_agent_alive / fm_backend_capture are the two backend-dispatch
# functions the library calls. Stub them so the test controls the dead verdict
# and the pane tail without a herdr binary. STUB_ALIVE and STUB_TAIL are read
# fresh on every call.
STUB_ALIVE=dead
STUB_TAIL=$'line-1\nline-2\nline-3'
fm_backend_agent_alive() { printf '%s' "$STUB_ALIVE"; }
fm_backend_capture() { printf '%s' "$STUB_TAIL"; }

wake_queue_records() {  # echoes the raw queue file, or empty when absent
  cat "$FM_WAKE_QUEUE" 2>/dev/null || true
}

reset_queue() { : > "$FM_WAKE_QUEUE" 2>/dev/null || true; }

# --- case: herdr dead pane WITH meta -> crash-tail + exactly one wake ---------
reset_queue
fm_write_meta "$STATE/taskA.meta" "window=default:w1:p1" "backend=herdr"
STUB_ALIVE=dead
STUB_TAIL=$'evidence-1\nevidence-2\nevidence-3'
out=$(fm_pane_crash_capture herdr "default:w1:p1" taskA "$STATE")
[ "$out" = captured ] || fail "a fresh herdr crash detection must print 'captured' (got: '$out')"
assert_present "$STATE/taskA.crash-tail" "a dead herdr pane with meta must write the crash-tail"
assert_grep "evidence-2" "$STATE/taskA.crash-tail" "crash-tail must hold the captured pane lines"
recs=$(wake_queue_records)
[ "$(printf '%s\n' "$recs" | grep -c 'pane-crashed taskA')" = 1 ] \
  || fail "exactly one 'pane-crashed taskA' wake must be enqueued (got: $recs)"
# The record must be a `check` wake through the real owner (tab-separated:
# epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload).
kind=$(printf '%s' "$recs" | awk -F '\t' '{print $3}')
[ "$kind" = check ] || fail "the wake kind must be 'check' (got: '$kind')"
payload=$(printf '%s' "$recs" | awk -F '\t' '{print $5}')
[ "$payload" = "pane-crashed taskA" ] || fail "the wake payload must be 'pane-crashed taskA' (got: '$payload')"
pass "herdr dead pane with meta records the crash-tail and enqueues exactly one check wake"

# --- case: idempotent second detection ---------------------------------------
# A second call for the same death must NOT print captured, must NOT enqueue a
# second wake, and must NOT clobber the tail already captured.
out=$(fm_pane_crash_capture herdr "default:w1:p1" taskA "$STATE")
[ -z "$out" ] || fail "a second detection of the same death must be a silent no-op (got: '$out')"
[ "$(printf '%s\n' "$(wake_queue_records)" | grep -c 'pane-crashed taskA')" = 1 ] \
  || fail "a second detection must not enqueue a second wake"
assert_grep "evidence-2" "$STATE/taskA.crash-tail" "a second detection must not clobber the captured crash-tail"
pass "a repeat detection of the same dead pane is idempotent - no double wake, no clobber"

# --- case: other backend is a silent no-op -----------------------------------
reset_queue
fm_write_meta "$STATE/taskB.meta" "window=%3" "backend=tmux"
STUB_ALIVE=dead
out=$(fm_pane_crash_capture tmux "%3" taskB "$STATE")
[ -z "$out" ] || fail "a non-herdr backend must be a silent no-op (got: '$out')"
assert_absent "$STATE/taskB.crash-tail" "a non-herdr backend must not write a crash-tail"
[ -z "$(wake_queue_records)" ] || fail "a non-herdr backend must not enqueue any wake"
pass "a non-herdr backend records nothing and enqueues no wake"

# --- case: missing meta is not an incident -----------------------------------
reset_queue
STUB_ALIVE=dead
out=$(fm_pane_crash_capture herdr "default:w9:p9" taskGhost "$STATE")
[ -z "$out" ] || fail "a dead pane with no meta must be a silent no-op (got: '$out')"
assert_absent "$STATE/taskGhost.crash-tail" "no meta means no crash-tail"
[ -z "$(wake_queue_records)" ] || fail "no meta means no wake"
pass "a dead pane with no meta (untracked or torn down) records nothing and wakes nothing"

# --- case: not confidently dead records nothing ------------------------------
reset_queue
fm_write_meta "$STATE/taskC.meta" "window=default:w2:p2" "backend=herdr"
STUB_ALIVE=unknown
out=$(fm_pane_crash_capture herdr "default:w2:p2" taskC "$STATE")
[ -z "$out" ] || fail "an unknown (not-dead) pane must be a silent no-op (got: '$out')"
assert_absent "$STATE/taskC.crash-tail" "an unknown pane must never fabricate a crash-tail"
[ -z "$(wake_queue_records)" ] || fail "an unknown pane must never enqueue a wake"
pass "an unknown (not confidently dead) pane records nothing - no false crash"

echo "ALL fm-pane-crash-lib tests passed"
