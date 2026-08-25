#!/usr/bin/env bash
# tests/fm-resume-fleet.test.sh - contract tests for bin/fm-resume-fleet.sh, the
# PACED, VERIFIED fleet re-warm that stops a bulk resume from bursting a
# provider's per-minute rate limit.
#
# WHY this exists (incident 2026-08-25): after an account rotation every lane's
# first turn re-sends its full cold-cache context. Firing a resume steer into all
# lanes at once made five ~120-180K-token turns start together and tripped the
# claude-1 per-minute rate limit (147 HTTP 429s in ~2 minutes). The script paces
# the STARTS one lane at a time with a jittered 60-90s gap and verifies each turn
# actually started before advancing, escalating (never silently dropping) a lane
# that fails to start. These tests pin every one of those guarantees.
#
# Everything is injected: a fake repo layout (bin/ + state/) plus fake
# fm-tmux-lib.sh (the busy-regex var) and fm-backend.sh (scripted meta/composer/
# busy/send primitives), so no assertion depends on any real pane, task, backend,
# or account. The fake backend deliberately reuses the SAME vocabulary the real
# one echoes (empty|pending|unknown|send-failed for submit; empty|pending|unknown
# for composer; busy|idle|unknown for busy_state) so a case is a genuine behavior
# guard, not a string check.
#
# Cases:
#   1. --help exits 0 and touches nothing.
#   2. dry-run resolves the order (meta priority first) and sends nothing.
#   3. dry-run --priority <id> puts that lane first.
#   4. a normal lane is sent and CONFIRMED via a native busy turn-start.
#   5. verify via a fresh status-file append (worker signalled, pane not "busy").
#   6. a lane that never starts a turn is ESCALATED: a blocked: line is appended
#      to its status file, it is listed FAILED, exit is 3, and the OTHER lanes
#      still run (one wedged lane never blocks the fleet).
#   7. an already-busy lane is SKIPPED, never double-poked (idempotent re-run).
#   8. a stubbornly-pending composer is SKIPPED, never garbled; unknown SKIPPED.
#   9. a dead endpoint is SKIPPED (recovery's job, not a re-warm).
#  10. the jittered gap between two real sends is within [min,max] and there is
#      exactly ONE gap for two sends (paced between requests, no trailing wait).
#  11. a send that does not land is escalated and does NOT pace the next lane.
#  12. an explicit --priority id is resumed before a meta-priority lane.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SRC="$ROOT/bin/fm-resume-fleet.sh"
assert_present "$SRC" "bin/fm-resume-fleet.sh is missing"
[ -x "$SRC" ] || fail "bin/fm-resume-fleet.sh must be executable"

TMPROOT=$(fm_test_tmproot fm-resume-fleet)

# Fake repo the script cds into: bin/<script> + bin/fm-tmux-lib.sh +
# bin/fm-backend.sh + state/*.meta. The script resolves its root as dirname/.. of
# its own path and sources both libs from its own bin dir, so fakes next to it
# control every primitive.
REPO="$TMPROOT/repo"
mkdir -p "$REPO/bin" "$REPO/state"
cp "$SRC" "$REPO/bin/fm-resume-fleet.sh"
chmod +x "$REPO/bin/fm-resume-fleet.sh"

# Minimal fake fm-tmux-lib.sh: only the busy-footer regex var the script reads.
cat > "$REPO/bin/fm-tmux-lib.sh" <<'SH'
#!/usr/bin/env bash
FM_TMUX_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel|^[0-9]+…'
SH

# Control dirs consumed by the fake backend (one file per sanitized target):
#   EXISTS/<t>    "0" -> endpoint dead; anything else / missing -> alive.
#   BUSY/<t>      newline list of busy_state verdicts, one consumed per call,
#                 default "idle" when missing or exhausted.
#   CAPTURE/<t>   text fm_backend_capture returns (default a non-busy line).
#   COMPOSER/<t>  newline list of composer verdicts, one per call, default empty.
#   SENDVERDICT/<t> the verdict fm_backend_send_text_submit echoes (default empty).
#   SENDAPPEND/<t>  present -> a landed send appends a worker status line to the
#                   lane's state/<id>.status (simulating a turn that signals via
#                   the status channel rather than a busy pane).
# BACKEND_LOG records every send/key. GAPLOG records every pacing sleep arg.
EXISTS="$TMPROOT/exists"
BUSY="$TMPROOT/busy"
CAPTURE="$TMPROOT/capture"
COMPOSER="$TMPROOT/composer"
SENDVERDICT="$TMPROOT/sendverdict"
SENDAPPEND="$TMPROOT/sendappend"
BACKEND_LOG="$TMPROOT/backend.log"
GAPLOG="$TMPROOT/gap.log"
mkdir -p "$EXISTS" "$BUSY" "$CAPTURE" "$COMPOSER" "$SENDVERDICT" "$SENDAPPEND"

sanitize() { printf '%s' "$1" | tr ':/' '__'; }

cat > "$REPO/bin/fm-backend.sh" <<'SH'
#!/usr/bin/env bash
# Fake backend for fm-resume-fleet tests. Reads the control dirs exported by the
# test and logs every send. cwd is the fake repo, so state/*.meta is reachable
# for the target->id reverse lookup the status-append simulation needs.
fm_meta_get() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
fm_backend_of_meta() { local v; v=$(fm_meta_get "$1" backend); printf '%s' "${v:-tmux}"; }
fm_backend_target_of_meta() {
  local meta=$1 window
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] && printf '%s' "$window"
}
_san() { printf '%s' "$1" | tr ':/' '__'; }

fm_backend_target_exists() {  # <backend> <target> [label]
  local f; f="$EXISTS/$(_san "$2")"
  [ -f "$f" ] && [ "$(cat "$f")" = 0 ] && return 1
  return 0
}

fm_backend_busy_state() {  # <backend> <target> -> busy|idle|unknown
  local f line; f="$BUSY/$(_san "$2")"
  if [ ! -f "$f" ]; then printf 'idle'; return 0; fi
  line=$(head -1 "$f" 2>/dev/null)
  sed -i '1d' "$f" 2>/dev/null || { tail -n +2 "$f" > "$f.n" && mv "$f.n" "$f"; }
  printf '%s' "${line:-idle}"
}

fm_backend_capture() {  # <backend> <target> <lines> [label]
  local f; f="$CAPTURE/$(_san "$2")"
  if [ -f "$f" ]; then cat "$f"; else printf 'idle pane, nothing to see\n'; fi
}

fm_backend_composer_state() {  # <backend> <target> -> empty|pending|unknown
  local f line; f="$COMPOSER/$(_san "$2")"
  [ -f "$f" ] || { printf 'empty'; return 0; }
  line=$(head -1 "$f" 2>/dev/null)
  sed -i '1d' "$f" 2>/dev/null || { tail -n +2 "$f" > "$f.n" && mv "$f.n" "$f"; }
  printf '%s' "${line:-empty}"
}

fm_backend_send_key() {  # <backend> <target> <key>
  printf 'send_key %s %s %s\n' "$1" "$2" "$3" >> "$BACKEND_LOG"
}

# Reverse-map a target to its task id by scanning the fake repo's state metas.
_id_for_target() {  # <target>
  local m w
  for m in state/*.meta; do
    [ -e "$m" ] || continue
    w=$(fm_meta_get "$m" window)
    [ "$w" = "$1" ] && { basename "$m" .meta; return 0; }
  done
  return 1
}

fm_backend_send_text_submit() {  # <backend> <target> <text> ...
  local verdict f id
  printf 'send_text %s %s %s\n' "$1" "$2" "$3" >> "$BACKEND_LOG"
  # A landed send may signal the started turn via a status-file append.
  if [ -f "$SENDAPPEND/$(_san "$2")" ]; then
    id=$(_id_for_target "$2" || true)
    [ -n "$id" ] && printf 'working: turn started (simulated)\n' >> "state/$id.status"
  fi
  f="$SENDVERDICT/$(_san "$2")"
  if [ -f "$f" ]; then verdict=$(cat "$f"); else verdict=empty; fi
  printf '%s' "$verdict"
}
SH

export EXISTS BUSY CAPTURE COMPOSER SENDVERDICT SENDAPPEND BACKEND_LOG GAPLOG

# A sleep stub that records the requested pacing gap without waiting, so the
# jitter bound can be asserted deterministically. Both the pacing sleep and the
# verify poll route here; only the pacing sleep is asserted (verify uses a 0
# timeout below so it never actually sleeps).
GAP_SLEEP="$TMPROOT/gap-sleep.sh"
cat > "$GAP_SLEEP" <<SH
#!/usr/bin/env bash
printf '%s\n' "\${1:-}" >> "$GAPLOG"
exit 0
SH
chmod +x "$GAP_SLEEP"

# Fast, deterministic defaults for every run: no real waits, verify checks once.
export FM_RESUME_SLEEP_CMD="$GAP_SLEEP"
export FM_RESUME_VERIFY_SLEEP_CMD="$GAP_SLEEP"
export FM_RESUME_VERIFY_TIMEOUT=0
export FM_RESUME_SEND_SETTLE=0
export FM_RESUME_CLEAR_SETTLE=0
export FM_RESUME_MESSAGE='resume {id} now'

reset_controls() {
  rm -rf "$EXISTS" "$BUSY" "$CAPTURE" "$COMPOSER" "$SENDVERDICT" "$SENDAPPEND"
  mkdir -p "$EXISTS" "$BUSY" "$CAPTURE" "$COMPOSER" "$SENDVERDICT" "$SENDAPPEND"
  : > "$BACKEND_LOG"
  : > "$GAPLOG"
}

# Rewrite the fake state/ from scratch: one meta per "id[:priority]" spec, each
# with window=w<n>:p<n>. A trailing ":prio" marks priority=1.
seed_state() {  # <id[:prio]> ...
  rm -f "$REPO"/state/*.meta "$REPO"/state/*.status 2>/dev/null || true
  local n=0 spec id prio
  for spec in "$@"; do
    n=$((n + 1))
    id=${spec%%:*}
    prio=0
    case "$spec" in *:prio) prio=1 ;; esac
    if [ "$prio" = 1 ]; then
      fm_write_meta "$REPO/state/$id.meta" "window=w$n:p$n" "project=$id" "priority=1"
    else
      fm_write_meta "$REPO/state/$id.meta" "window=w$n:p$n" "project=$id"
    fi
  done
}

run_resume() {  # <args...> -> sets OUT / RC
  OUT=$(cd "$REPO" && ./bin/fm-resume-fleet.sh "$@" 2>&1)
  RC=$?
}

target_of() {  # <id> -> the window target seeded for it
  grep '^window=' "$REPO/state/$1.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# --- case 1: --help exits 0 and touches nothing -------------------------------
reset_controls
seed_state alpha
run_resume --help
expect_code 0 "$RC" "--help must exit 0"
assert_contains "$OUT" "usage:" "--help must print usage"
[ -s "$BACKEND_LOG" ] && fail "--help must never touch a backend" || true
pass "--help prints usage and touches nothing"

# --- case 2: dry-run resolves the order (meta priority first), sends nothing ---
reset_controls
seed_state alpha bravo:prio charlie
run_resume --dry-run
expect_code 0 "$RC" "dry-run must exit 0"
assert_contains "$OUT" "dry-run" "dry-run must announce itself"
# bravo has priority= so it must be listed before alpha and charlie.
first=$(printf '%s\n' "$OUT" | grep -E '  (alpha|bravo|charlie)  ' | head -1)
assert_contains "$first" "bravo" "the meta-priority lane must be resumed first in dry-run order"
assert_contains "$OUT" "[priority]" "the priority lane must be flagged"
[ -s "$BACKEND_LOG" ] && fail "dry-run must send nothing" || true
pass "dry-run lists the priority-first order and sends nothing"

# --- case 3: dry-run --priority <id> puts that lane first ----------------------
reset_controls
seed_state alpha bravo charlie
run_resume --priority charlie --dry-run
expect_code 0 "$RC" "dry-run --priority must exit 0"
first=$(printf '%s\n' "$OUT" | grep -E '  (alpha|bravo|charlie)  ' | head -1)
assert_contains "$first" "charlie" "--priority <id> must resume that lane first"
pass "--priority <id> orders that lane first"

# --- case 4: a normal lane is sent and CONFIRMED via a native busy turn --------
reset_controls
seed_state alpha
# pre-check idle, then the verify read sees a busy turn.
printf 'idle\nbusy\n' > "$BUSY/$(sanitize "$(target_of alpha)")"
run_resume
expect_code 0 "$RC" "a confirmed lane must exit 0"
assert_grep "send_text tmux $(target_of alpha) resume alpha now" "$BACKEND_LOG" "the lane must be sent its resume steer with {id} expanded"
assert_contains "$OUT" "confirmed" "a lane whose turn starts must be reported confirmed"
pass "a normal lane is sent and confirmed via a native busy turn"

# --- case 5: verify via a fresh status-file append -----------------------------
reset_controls
seed_state alpha
# busy_state stays idle throughout; the send appends a worker status line, which
# the verify gate accepts as positive evidence the turn started.
: > "$SENDAPPEND/$(sanitize "$(target_of alpha)")"
run_resume
expect_code 0 "$RC" "a status-append-confirmed lane must exit 0"
assert_contains "$OUT" "confirmed" "a fresh status append must confirm the turn start"
pass "a turn signalled only by a status-file append is confirmed"

# --- case 6: a lane that never starts a turn is ESCALATED, others still run -----
reset_controls
seed_state alpha bravo
# alpha: no busy, no append -> verify times out -> escalate. bravo: confirmed.
printf 'idle\nbusy\n' > "$BUSY/$(sanitize "$(target_of bravo)")"
run_resume
expect_code 3 "$RC" "a fleet with a failed lane must exit 3"
assert_contains "$OUT" "FAILED" "the wedged lane must be reported failed"
assert_grep "blocked:" "$REPO/state/alpha.status" "the wedged lane must get a durable blocked: escalation in its status file"
assert_grep "fm-resume-fleet" "$REPO/state/alpha.status" "the escalation must attribute itself"
assert_grep "send_text tmux $(target_of bravo) " "$BACKEND_LOG" "the other lane must still be resumed despite the wedged one"
assert_contains "$OUT" "confirmed: bravo" "the healthy lane must still confirm"
pass "a wedged lane is escalated (never dropped) and the rest of the fleet still runs"

# --- case 7: an already-busy lane is SKIPPED, never double-poked ---------------
reset_controls
seed_state alpha
printf 'busy\n' > "$BUSY/$(sanitize "$(target_of alpha)")"
run_resume
expect_code 0 "$RC" "an all-skipped fleet must exit 0"
assert_contains "$OUT" "already mid-turn" "an already-busy lane must be reported skipped as mid-turn"
assert_no_grep "send_text tmux $(target_of alpha) " "$BACKEND_LOG" "an already-busy lane must never be sent (idempotent re-run safety)"
pass "an already-busy lane is skipped, never double-poked"

# --- case 8: a stubborn pending composer is SKIPPED; unknown is SKIPPED ---------
reset_controls
seed_state alpha bravo
# alpha composer stays pending across the Escape re-check -> skip, never garbled.
printf 'pending\npending\n' > "$COMPOSER/$(sanitize "$(target_of alpha)")"
# bravo composer reads unknown -> skip, never blind-injected.
printf 'unknown\n' > "$COMPOSER/$(sanitize "$(target_of bravo)")"
run_resume
expect_code 0 "$RC" "skip-only fleet must exit 0"
assert_grep "send_key tmux $(target_of alpha) Escape" "$BACKEND_LOG" "a pending composer must get one Escape try"
assert_no_grep "send_text tmux $(target_of alpha) " "$BACKEND_LOG" "a stubborn pending composer must never be sent (never garble human typing)"
assert_no_grep "send_text tmux $(target_of bravo) " "$BACKEND_LOG" "an unknown composer must never be blind-injected"
assert_contains "$OUT" "pending human input" "the pending lane must be reported skipped for pending input"
assert_contains "$OUT" "unknown composer" "the unknown lane must be reported skipped for an unknown composer"
pass "a stubborn pending composer and an unknown composer are both skipped, never poked"

# --- case 9: a dead endpoint is SKIPPED ---------------------------------------
reset_controls
seed_state alpha
printf '0\n' > "$EXISTS/$(sanitize "$(target_of alpha)")"
run_resume
expect_code 0 "$RC" "a dead-only fleet must exit 0"
assert_contains "$OUT" "endpoint not live" "a dead endpoint must be reported skipped"
assert_no_grep "send_text tmux $(target_of alpha) " "$BACKEND_LOG" "a dead endpoint must never be sent"
pass "a dead endpoint is skipped, never resumed"

# --- case 10: the jittered gap is within [min,max]; exactly one gap for 2 sends -
reset_controls
seed_state alpha bravo
# Both lanes confirm, so both send -> exactly one pacing gap between them.
printf 'idle\nbusy\n' > "$BUSY/$(sanitize "$(target_of alpha)")"
printf 'idle\nbusy\n' > "$BUSY/$(sanitize "$(target_of bravo)")"
FM_RESUME_MIN_GAP=60 FM_RESUME_MAX_GAP=90 run_resume
expect_code 0 "$RC" "two confirmed lanes must exit 0"
gaps=$(grep -cE '^[0-9]+$' "$GAPLOG" || true)
[ "$gaps" = 1 ] || fail "two sends must produce exactly one pacing gap (got $gaps)"$'\n'"gaps:"$'\n'"$(cat "$GAPLOG")"
gapval=$(grep -E '^[0-9]+$' "$GAPLOG" | head -1)
{ [ "$gapval" -ge 60 ] && [ "$gapval" -le 90 ]; } || fail "the jittered gap must be within 60-90s (got $gapval)"
pass "two sends pace exactly one jittered 60-90s gap between them"

# --- case 10b: the pacing gap honors a custom window ---------------------------
reset_controls
seed_state alpha bravo
printf 'idle\nbusy\n' > "$BUSY/$(sanitize "$(target_of alpha)")"
printf 'idle\nbusy\n' > "$BUSY/$(sanitize "$(target_of bravo)")"
FM_RESUME_MIN_GAP=5 FM_RESUME_MAX_GAP=5 run_resume
expect_code 0 "$RC" "custom-window run must exit 0"
gapval=$(grep -E '^[0-9]+$' "$GAPLOG" | head -1)
[ "$gapval" = 5 ] || fail "a min==max window must pick exactly that gap (got $gapval)"
pass "the pacing window is configurable and respected"

# --- case 11: a send that does not land is escalated and does NOT pace next -----
reset_controls
seed_state alpha bravo
# alpha's send is swallowed (pending); bravo then confirms. The swallowed send
# must NOT have spent the per-minute budget, so no pacing gap precedes bravo.
printf 'pending\n' > "$SENDVERDICT/$(sanitize "$(target_of alpha)")"
printf 'idle\nbusy\n' > "$BUSY/$(sanitize "$(target_of bravo)")"
run_resume
expect_code 3 "$RC" "a fleet with a non-landing send must exit 3"
assert_grep "blocked:" "$REPO/state/alpha.status" "a non-landing send must escalate the lane durably"
gaps=$(grep -cE '^[0-9]+$' "$GAPLOG" || true)
[ "$gaps" = 0 ] || fail "a swallowed send must not pace the next lane (got $gaps gaps)"
assert_contains "$OUT" "confirmed: bravo" "the next lane must still run after a swallowed send"
pass "a send that does not land is escalated and does not pace the next lane"

# --- case 12: an explicit --priority id beats a meta-priority lane -------------
reset_controls
seed_state alpha bravo:prio charlie
run_resume --priority charlie --dry-run
first=$(printf '%s\n' "$OUT" | grep -E '  (alpha|bravo|charlie)  ' | head -1)
assert_contains "$first" "charlie" "an explicit --priority id must outrank a meta-priority lane"
second=$(printf '%s\n' "$OUT" | grep -E '  (alpha|bravo|charlie)  ' | sed -n 2p)
assert_contains "$second" "bravo" "the meta-priority lane must still come before ordinary lanes"
pass "an explicit --priority id outranks a meta-priority lane"

# --- case 13: no resumable lanes is a clean no-op ------------------------------
reset_controls
rm -f "$REPO"/state/*.meta 2>/dev/null || true
fm_write_meta "$REPO/state/.lavish-lan.meta" "port=4388" "bind=0.0.0.0"
run_resume
expect_code 0 "$RC" "a home with no resumable lanes must exit 0"
assert_contains "$OUT" "no resumable lanes" "an empty fleet must report nothing to do"
[ -s "$BACKEND_LOG" ] && fail "an empty fleet must send nothing" || true
pass "a home with only a sidecar meta resumes nothing and exits 0"

# --- case 14: secondmate and supervise=off lanes are skipped from discovery ----
reset_controls
rm -f "$REPO"/state/*.meta 2>/dev/null || true
fm_write_meta "$REPO/state/alpha.meta" "window=w1:p1" "project=alpha"
fm_write_meta "$REPO/state/second.meta" "window=w2:p2" "project=second" "kind=secondmate"
fm_write_meta "$REPO/state/unsup.meta" "window=w3:p3" "project=unsup" "supervise=off"
run_resume --dry-run
expect_code 0 "$RC" "dry-run must exit 0"
assert_contains "$OUT" "1 lane" "only the ordinary lane must be discovered"
assert_not_contains "$OUT" "second" "a secondmate lane must be excluded from the re-warm"
assert_not_contains "$OUT" "unsup" "an unsupervised lane must be excluded from the re-warm"
pass "secondmate and unsupervised lanes are excluded from the re-warm set"

pass "fm-resume-fleet.sh: all checks passed"
