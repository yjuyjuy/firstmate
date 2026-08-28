#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's jcode post-launch delivery, specifically the
# brief-submit race fix (task fix-fm-spawn-brief-submit-race).
#
# The bug (observed twice 2026-08-10, data/learnings.md): the initial spawn
# submitted /model, /effort, AND the brief as a run of messages. The FIRST slash
# command's submit verified as `pending` (jcode opens a slash-autocomplete popup
# and races the Enter), the old loop treated that as fatal and returned early,
# and the brief - the last and longest message - was never even typed. The pane
# was left idle holding nothing while effort sometimes landed wrong too.
#
# The fix splits delivery: slash commands are best-effort (a pending verdict is
# warned about but never aborts), and the brief is submitted as its own
# separately-verified step (jcode_submit_brief_verified) that re-submits Enter
# until the composer actually clears - the verified-submit model fm-send.sh uses.
#
# These tests extract the two functions from bin/fm-spawn.sh (the same
# awk-extraction fm-jcode-harness.test.sh uses for launch_template) and drive
# them against a scriptable fake backend, so no live jcode server is needed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-jcode-brief-submit)

# Extract the two functions under test from bin/fm-spawn.sh verbatim.
FN_FILE="$TMP_ROOT/jcode_delivery.sh"
mkdir -p "$TMP_ROOT"
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

# The functions read these; FM_ROOT points at the real repo so the real
# operational-input encoder runs (deterministic). BACKEND names the fake below.
export FM_ROOT="$ROOT"
export BACKEND=fake
# Zero the settle/wait so the tests run instantly. Keep the retry count at its
# default (3) unless a test overrides it.
export FM_SPAWN_JCODE_READY_POLLS=1
export FM_SPAWN_JCODE_BRIEF_SETTLE=0
export FM_SPAWN_JCODE_BRIEF_SUBMIT_TRIES=3
export FM_SPAWN_JCODE_VERIFY_SETTLE=0
export FM_SPAWN_JCODE_VERIFY_TRIES=3

# The real session resolver + store reader back the verify-before-brief gate, so
# the one test that pins an explicit model needs a fake store to verify against.
# shellcheck source=bin/fm-token-sessions-lib.sh
. "$ROOT/bin/fm-token-sessions-lib.sh"
SESS_DIR="$TMP_ROOT/sessions"
mkdir -p "$SESS_DIR"
export JCODE_SESSIONS_DIR="$SESS_DIR"
PROBE_WT="$TMP_ROOT/probe-worktree"
mkdir -p "$PROBE_WT"
SPAWN_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
write_store() {  # <model|-> <effort|->
  local model=$1 effort=$2 sess_file="$SESS_DIR/session_probe.json"
  if [ "$model" = - ]; then model=null; else model="\"$model\""; fi
  if [ "$effort" = - ]; then effort=null; else effort="\"$effort\""; fi
  cat > "$sess_file" <<EOF
{"id":"session_probe","model":$model,"reasoning_effort":$effort,"working_dir":"$PROBE_WT","created_at":"$SPAWN_TS"}
EOF
}

# --- scriptable fake backend ------------------------------------------------
#
# A test sets these queues (newline-delimited files), then calls the extracted
# functions. Every fake primitive appends to a CALLS file so a test can assert
# the exact delivery sequence afterwards. Files are used deliberately: the real
# functions call these primitives inside command substitution (a subshell), so
# in-memory array/index mutations would not survive back to the parent. Each
# queue's LAST value is sticky once the queue is exhausted, so a test lists only
# the transitions it cares about.

SUBMIT_Q="$TMP_ROOT/submit_q"
COMPOSER_Q="$TMP_ROOT/composer_q"
SUBMIT_I="$TMP_ROOT/submit_i"
COMPOSER_I="$TMP_ROOT/composer_i"
CALLS_F="$TMP_ROOT/calls"

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
    # exhausted: return the sticky last value, do not advance
    sed -n "${n}p" "$qf"
    return 0
  fi
  line=$(sed -n "$((idx + 1))p" "$qf")
  printf '%s' "$((idx + 1))" > "$idxf"
  printf '%s' "$line"
}

fm_backend_send_text_submit() {  # <backend> <target> <text> <retries> <sleep> <settle>
  local text=$3 v
  v=$(_queue_next "$SUBMIT_Q" "$SUBMIT_I" unknown)
  printf 'submit:%s=%s\n' "$text" "$v" >> "$CALLS_F"
  printf '%s' "$v"
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
}

calls_joined() { paste -sd'|' "$CALLS_F" 2>/dev/null || true; }

# Count how many CALLS entries submit the brief (the launch-brief-encoded line,
# never a "/"-prefixed slash command).
count_brief_submits() {
  local c=0 e
  while IFS= read -r e; do
    case "$e" in
      submit:/*) ;;                 # slash command, not the brief
      submit:*=*) c=$((c + 1)) ;;   # brief submit
    esac
  done < "$CALLS_F"
  printf '%s' "$c"
}

has_call() {  # <substring>
  grep -qF "$1" "$CALLS_F"
}

# --- tests ------------------------------------------------------------------

test_brief_delivered_even_when_slash_verifies_pending() {
  # THE REGRESSION: /model verifies `pending` (the slash-popup race). The brief
  # must STILL be delivered once the store confirms the pin, and delivery must
  # succeed. The store is pre-seeded with the requested model, so the pre-brief
  # verify passes on the first read even though the slash submit itself reported
  # pending - proving a pending verdict is not treated as fatal.
  reset_fake
  write_store claude-opus-4-8 -
  # ready poll (composer_state) -> non-unknown so delivery proceeds; then the
  # slash /model submit -> pending; then brief submit -> empty (clean).
  set_composer_queue empty
  set_submit_queue pending empty
  jcode_post_launch_delivery fakepane /tmp/brief.md claude-opus-4-8 default "" \
    "$PROBE_WT" "$SPAWN_TS" "$TMP_ROOT/pending.status" "$TMP_ROOT/pending.meta" \
    || fail "delivery must succeed despite a pending slash-command verdict, got failure"
  [ "$(count_brief_submits)" -ge 1 ] \
    || fail "the brief must be submitted even when the slash command verified pending; calls: $(calls_joined)"
  pass "a pending /model verdict no longer aborts delivery: the store confirms the pin and the brief is still submitted"
}

test_brief_resubmitted_until_composer_clears() {
  # The brief's first submit is swallowed (composer still `pending`); a retry
  # Enter clears it (`empty`). The brief must be typed ONCE and Enter re-sent.
  reset_fake
  # composer queue: ready poll -> empty; attempt1 read -> pending; attempt2 read -> empty
  set_composer_queue empty pending empty
  set_submit_queue pending             # brief type+submit -> swallowed
  jcode_post_launch_delivery fakepane /tmp/brief.md default default \
    || fail "delivery must succeed once a retry Enter clears the composer"
  [ "$(count_brief_submits)" -eq 1 ] \
    || fail "the brief must be typed exactly once (retype would duplicate it); calls: $(calls_joined)"
  has_call "key:Enter" \
    || fail "a swallowed brief must trigger a retry Enter, not a retype; calls: $(calls_joined)"
  pass "a swallowed brief is re-submitted with Enter only (never retyped) until the composer clears"
}

test_brief_submit_failure_reported_when_never_clears() {
  # The composer NEVER clears (stays pending across every attempt). Delivery must
  # report failure so firstmate inspects the pane, not silently succeed.
  reset_fake
  set_submit_queue pending
  set_composer_queue empty pending pending pending pending
  if jcode_post_launch_delivery fakepane /tmp/brief.md default default 2>/dev/null; then
    fail "delivery must FAIL when the composer never clears after all retries; calls: $(calls_joined)"
  fi
  pass "a brief that never submits after all retries is reported as a failure, not a silent success"
}

test_unreadable_pane_is_lenient() {
  # After typing, the pane is unreadable (unknown) - a read failure, not a
  # positively-confirmed swallow. Treated leniently as delivered, like fm-send.
  reset_fake
  set_submit_queue unknown
  set_composer_queue empty unknown unknown unknown unknown
  jcode_post_launch_delivery fakepane /tmp/brief.md default default \
    || fail "an unreadable composer after submit must be treated leniently as delivered"
  pass "an unreadable pane after brief submit is assumed delivered (only a confirmed swallow is an error)"
}

test_clean_first_submit_needs_no_retry() {
  # The common happy path: the brief's first submit returns empty immediately.
  # No retry Enter needed.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  jcode_post_launch_delivery fakepane /tmp/brief.md default default \
    || fail "a clean first brief submit must succeed"
  ! has_call "key:Enter" \
    || fail "a clean first submit must not send a retry Enter; calls: $(calls_joined)"
  [ "$(count_brief_submits)" -eq 1 ] \
    || fail "exactly one brief submit expected on the happy path; calls: $(calls_joined)"
  pass "a brief that submits cleanly on the first try needs no retry Enter"
}

test_composer_never_ready_skips_delivery() {
  # If the composer never appears (always unknown), nothing is typed at all.
  reset_fake
  set_composer_queue unknown
  : > "$SUBMIT_Q"
  if jcode_post_launch_delivery fakepane /tmp/brief.md default default 2>/dev/null; then
    fail "delivery must fail when the composer never appears"
  fi
  [ "$(count_brief_submits)" -eq 0 ] \
    || fail "no brief may be typed before the composer exists; calls: $(calls_joined)"
  pass "no message is typed until the composer appears; a never-ready composer fails cleanly"
}

test_brief_delivered_even_when_slash_verifies_pending
test_brief_resubmitted_until_composer_clears
test_brief_submit_failure_reported_when_never_clears
test_unreadable_pane_is_lenient
test_clean_first_submit_needs_no_retry
test_composer_never_ready_skips_delivery
