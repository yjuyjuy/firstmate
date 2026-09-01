#!/usr/bin/env bash
# Behavior tests for the secondmate context-window read (fm-secondmate-context-lib.sh)
# and its reporter (fm-secondmate-context.sh). The claude read is evidence-backed
# in docs/secondmate-context-handoff.md; every other harness must fail closed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-secondmate-context-lib.sh
. "$ROOT/bin/fm-secondmate-context-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-context-tests)
mkdir -p "$TMP_ROOT"

# Build a fake claude config dir with a transcript for <home>. Extra args are
# appended verbatim as additional JSONL lines.
write_transcript() {  # <config-dir> <home> <file-basename> <input> <cc> <cr> [extra-line...]
  local config=$1 home=$2 base=$3 input=$4 cc=$5 cr=$6; shift 6
  local dir extra
  dir="$config/projects/$(printf '%s' "$home" | tr '/.' '--')"
  mkdir -p "$dir"
  {
    printf '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' "$input" "$cc" "$cr"
    for extra in "$@"; do printf '%s\n' "$extra"; done
  } > "$dir/$base.jsonl"
  printf '%s' "$dir/$base.jsonl"
}

write_meta() {  # <state> <id> <home> <harness> [kind]
  local state=$1 id=$2 home=$3 harness=$4 kind=${5:-secondmate}
  mkdir -p "$state"
  cat > "$state/$id.meta" <<EOF
window=test:fm-$id
worktree=$home
harness=$harness
kind=$kind
home=$home
EOF
}

test_threshold_default_and_config() {
  local config="$TMP_ROOT/cfg1"
  mkdir -p "$config"
  [ "$(fm_sm_context_threshold "$config")" = 200000 ] || fail "absent config should default to 200000"
  printf '150000\n' > "$config/secondmate-context-threshold"
  [ "$(fm_sm_context_threshold "$config")" = 150000 ] || fail "configured threshold should be honored"
  printf '# comment\n\n  250000  \n' > "$config/secondmate-context-threshold"
  [ "$(fm_sm_context_threshold "$config")" = 250000 ] || fail "comment/blank/whitespace should be skipped/trimmed"
  printf 'garbage\n' > "$config/secondmate-context-threshold"
  [ "$(fm_sm_context_threshold "$config")" = 200000 ] || fail "non-integer threshold should fall back to default"
  printf '0\n' > "$config/secondmate-context-threshold"
  [ "$(fm_sm_context_threshold "$config")" = 200000 ] || fail "non-positive threshold should fall back to default"
  pass "threshold reads config, trims/skips noise, and fails safe on bad values"
}

test_munge_matches_claude() {
  [ "$(fm_sm_munge_path /Users/x/.treehouse/a-b/3/f)" = "-Users-x--treehouse-a-b-3-f" ] \
    || fail "munge must replace / and . with - (verified against real claude dir)"
  pass "path munging matches claude's project-folder rule"
}

test_claude_read_sums_last_mainthread_usage() {
  local config="$TMP_ROOT/cfg-read" home="$TMP_ROOT/home-read" out
  local sidechain='{"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":999999,"cache_creation_input_tokens":999999,"cache_read_input_tokens":999999}}}'
  local trailing='{"type":"mode"}'
  write_transcript "$config" "$home" session 10 20 170000 "$sidechain" "$trailing" >/dev/null
  out=$(CLAUDE_CONFIG_DIR="$config" fm_sm_context_tokens "$home" claude)
  [ "$out" = 170030 ] || fail "should sum input+cache_creation+cache_read of last main-thread turn, got: $out"
  pass "claude read sums the last main-thread usage and ignores sidechain and trailing lines"
}

test_newest_transcript_wins() {
  local config="$TMP_ROOT/cfg-newest" home="$TMP_ROOT/home-newest" f1 f2 out
  f1=$(write_transcript "$config" "$home" old 1 1 1)
  f2=$(write_transcript "$config" "$home" new 5 5 90)
  touch -t 202601010000 "$f1"
  touch -t 202607200000 "$f2"
  out=$(CLAUDE_CONFIG_DIR="$config" fm_sm_context_tokens "$home" claude)
  [ "$out" = 100 ] || fail "newest-mtime transcript should be read, got: $out"
  pass "the active (newest-mtime) transcript is the one read"
}

test_non_claude_and_missing_fail_closed() {
  local config="$TMP_ROOT/cfg-fc" home="$TMP_ROOT/home-fc"
  write_transcript "$config" "$home" session 10 20 170000 >/dev/null
  [ -z "$(CLAUDE_CONFIG_DIR="$config" fm_sm_context_tokens "$home" codex)" ] || fail "codex must read empty (fail closed)"
  [ -z "$(CLAUDE_CONFIG_DIR="$config" fm_sm_context_tokens "$home" opencode)" ] || fail "opencode must read empty"
  [ -z "$(CLAUDE_CONFIG_DIR="$config" fm_sm_context_tokens "$home" pi)" ] || fail "pi must read empty"
  [ -z "$(CLAUDE_CONFIG_DIR="$config" fm_sm_context_tokens "$home" grok)" ] || fail "grok must read empty"
  [ -z "$(CLAUDE_CONFIG_DIR="$config" fm_sm_context_tokens "/no/such/home" claude)" ] || fail "missing transcript must read empty"
  [ -z "$(fm_sm_context_tokens "" claude)" ] || fail "empty cwd must read empty"
  pass "unsupported harness, missing transcript, and empty cwd all fail closed"
}

test_no_jq_fails_closed() {
  local config="$TMP_ROOT/cfg-jq" home="$TMP_ROOT/home-jq" nojqbin tool out
  write_transcript "$config" "$home" session 10 20 170000 >/dev/null
  # A PATH holding only the read's non-jq tools, so `command -v jq` fails.
  nojqbin="$TMP_ROOT/nojqbin"
  mkdir -p "$nojqbin"
  for tool in bash grep tr; do ln -sf "$(command -v "$tool")" "$nojqbin/$tool"; done
  PATH="$nojqbin" command -v jq >/dev/null 2>&1 && fail "test PATH must not resolve jq"
  out=$(PATH="$nojqbin" CLAUDE_CONFIG_DIR="$config" bash -c '. "'"$ROOT"'/bin/fm-secondmate-context-lib.sh"; fm_sm_context_tokens "'"$home"'" claude')
  [ -z "$out" ] || fail "without jq the read must fail closed (empty), got: $out"
  pass "an absent jq fails the read closed instead of guessing"
}

test_reporter_over_under_unknown() {
  local config="$TMP_ROOT/cfg-rep" home="$TMP_ROOT/home-rep" fmhome out
  fmhome="$TMP_ROOT/fmhome-rep"
  mkdir -p "$fmhome/config"
  write_meta "$fmhome/state" sm-x "$home" claude
  write_transcript "$config" "$home" session 10 20 170000 >/dev/null

  printf '100000\n' > "$fmhome/config/secondmate-context-threshold"
  out=$(CLAUDE_CONFIG_DIR="$config" FM_HOME="$fmhome" "$ROOT/bin/fm-secondmate-context.sh" sm-x)
  assert_contains "$out" "context_tokens=170030" "reporter should print the token count"
  assert_contains "$out" "over_threshold=yes" "170030 over 100000 should report yes"

  printf '200000\n' > "$fmhome/config/secondmate-context-threshold"
  out=$(CLAUDE_CONFIG_DIR="$config" FM_HOME="$fmhome" "$ROOT/bin/fm-secondmate-context.sh" sm-x)
  assert_contains "$out" "over_threshold=no" "170030 under 200000 should report no"

  # codex meta -> unknown read -> unknown verdict, still exit 0.
  write_meta "$fmhome/state" sm-c "$home" codex
  out=$(CLAUDE_CONFIG_DIR="$config" FM_HOME="$fmhome" "$ROOT/bin/fm-secondmate-context.sh" sm-c)
  assert_contains "$out" "context_tokens=unknown" "codex read should be unknown"
  assert_contains "$out" "over_threshold=unknown" "unknown read verdict should be unknown"
  pass "reporter classifies over/under/unknown against the configured threshold"
}

test_reporter_refuses_non_secondmate() {
  local fmhome="$TMP_ROOT/fmhome-refuse" status
  write_meta "$fmhome/state" ship1 "$TMP_ROOT/whatever" claude ship
  FM_HOME="$fmhome" "$ROOT/bin/fm-secondmate-context.sh" ship1 >/dev/null 2>&1
  status=$?
  expect_code 2 "$status" "a non-secondmate task must be refused"
  FM_HOME="$fmhome" "$ROOT/bin/fm-secondmate-context.sh" nope >/dev/null 2>&1
  status=$?
  expect_code 2 "$status" "an unknown id must be refused"
  pass "reporter refuses non-secondmate and unknown ids"
}

# Build a fake jcode home with a journal for <home>. jcode stores the RAW
# absolute working_dir (no munging) on the first line's .meta, and per-turn
# usage under append_messages[].token_usage. When <active> is "active" the
# session basename is also placed in active_pids/. Extra args are appended
# verbatim as additional JSONL records.
write_jcode_journal() {  # <jcode-home> <home> <session-id> <input> <cc> <cr> <active> [extra-record...]
  local jhome=$1 home=$2 sid=$3 input=$4 cc=$5 cr=$6 active=$7; shift 7
  local sessions="$jhome/sessions" pids="$jhome/active_pids" f extra
  mkdir -p "$sessions"
  f="$sessions/$sid.journal.jsonl"
  {
    printf '{"type":"meta_init","meta":{"working_dir":"%s","status":"Active"}}\n' "$home"
    printf '{"type":"record","append_messages":[{"token_usage":{"input_tokens":%s,"output_tokens":5,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}]}\n' "$input" "$cc" "$cr"
    for extra in "$@"; do printf '%s\n' "$extra"; done
  } > "$f"
  if [ "$active" = active ]; then
    mkdir -p "$pids"
    : > "$pids/$sid"
  fi
  printf '%s' "$f"
}

test_jcode_reads_journal_token_usage() {
  # jcode persists usage in its OWN journal (NOT claude's projects dir), summing
  # the last append_messages[].token_usage input components (verified 2026-08-01,
  # docs/secondmate-context-handoff.md).
  local jhome="$TMP_ROOT/jcode-read" home="/root/some/live/home" out
  # An earlier low-usage record written first, the most recent high-usage turn
  # last: the reader must take the LAST token_usage line, not the first.
  local latest='{"type":"record","append_messages":[{"token_usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":170000}}]}'
  write_jcode_journal "$jhome" "$home" session_live_1 1 1 1 active "$latest" >/dev/null
  out=$(JCODE_HOME="$jhome" fm_sm_context_tokens "$home" jcode)
  [ "$out" = 170030 ] || fail "jcode must sum the LAST token_usage input components, got: $out"
  pass "jcode read sums the last journal token_usage and prefers the latest turn"
}

test_jcode_ignores_stale_same_home_session() {
  # A stale same-home leftover with no active_pid and zero usage must never
  # shadow the live active-pid-confirmed session, even if it is newer on disk.
  local jhome="$TMP_ROOT/jcode-stale" home="/root/stale/home" live stale out
  live=$(write_jcode_journal "$jhome" "$home" session_live_2 10 20 170000 active)
  stale=$(write_jcode_journal "$jhome" "$home" session_stale_2 0 0 0 inactive)
  # Make the stale one NEWER on disk to prove active-pid selection wins over mtime.
  touch -t 202601010000 "$live"
  touch -t 202607200000 "$stale"
  out=$(JCODE_HOME="$jhome" fm_sm_context_tokens "$home" jcode)
  [ "$out" = 170030 ] || fail "active-pid session must win over a newer stale same-home leftover, got: $out"
  pass "the live active-pid journal wins over a newer stale same-home session"
}

test_jcode_ignores_trailing_degenerate_turn() {
  # REGRESSION: a real jcode journal can end on a degenerate token_usage record -
  # {"input_tokens":0,"output_tokens":0} with NO cache fields (an interrupted,
  # placeholder, or system turn) - after many high-usage turns. Observed live in
  # session_unicorn_...: 28 token_usage records climbing to 84661, then a final
  # {"input_tokens":0,"output_tokens":0}. A naive tail-1 read sums that last record
  # to 0, fails the >0 guard, and returns unknown - so a 500k session reads as
  # unknown and NO handoff fires. The read must instead take the last POSITIVE
  # per-record sum, so real occupancy is reported.
  local jhome="$TMP_ROOT/jcode-degen" home="/root/degen/home" out
  # A high-usage turn, then a degenerate zero-usage placeholder turn LAST.
  local high='{"type":"record","append_messages":[{"token_usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":170000}}]}'
  local degenerate='{"type":"record","append_messages":[{"token_usage":{"input_tokens":0,"output_tokens":0}}]}'
  # write_jcode_journal seeds one record (1+1+1=3), then we append high then degenerate.
  write_jcode_journal "$jhome" "$home" session_degen 1 1 1 active "$high" "$degenerate" >/dev/null
  out=$(JCODE_HOME="$jhome" fm_sm_context_tokens "$home" jcode)
  [ "$out" = 170030 ] || fail "a trailing degenerate zero-usage turn must not mask the last real occupancy, got: $out"
  pass "jcode read skips a trailing degenerate zero-usage turn and reports the last real occupancy"
}

test_jcode_fails_closed() {
  local jhome="$TMP_ROOT/jcode-fc" home="/root/fc/home" nojqbin tool out
  write_jcode_journal "$jhome" "$home" session_fc 10 20 170000 active >/dev/null
  # working_dir mismatch -> unknown, never a wrong number.
  [ -z "$(JCODE_HOME="$jhome" fm_sm_context_tokens "/root/other/home" jcode)" ] \
    || fail "a working_dir mismatch must read empty (fail closed)"
  # absent sessions dir -> unknown.
  [ -z "$(JCODE_HOME="$TMP_ROOT/jcode-absent" fm_sm_context_tokens "$home" jcode)" ] \
    || fail "an absent jcode sessions dir must read empty"
  # absent jq -> unknown (never guesses).
  nojqbin="$TMP_ROOT/nojqbin-jcode"
  mkdir -p "$nojqbin"
  for tool in bash grep tr head basename; do ln -sf "$(command -v "$tool")" "$nojqbin/$tool"; done
  PATH="$nojqbin" command -v jq >/dev/null 2>&1 && fail "test PATH must not resolve jq"
  out=$(PATH="$nojqbin" JCODE_HOME="$jhome" bash -c '. "'"$ROOT"'/bin/fm-secondmate-context-lib.sh"; fm_sm_context_tokens "'"$home"'" jcode')
  [ -z "$out" ] || fail "without jq the jcode read must fail closed (empty), got: $out"
  pass "jcode fails closed on working_dir mismatch, absent dir, and absent jq"
}

test_context_stow_threshold_default_and_config() {
  local config="$TMP_ROOT/cfg-stow"
  mkdir -p "$config"
  [ "$(fm_context_stow_threshold "$config")" = 200000 ] \
    || fail "absent config/context-stow-threshold should default to 200000"
  printf '150000\n' > "$config/context-stow-threshold"
  [ "$(fm_context_stow_threshold "$config")" = 150000 ] \
    || fail "configured stow threshold should be honored"
  printf '# comment\n\n  120000  \n' > "$config/context-stow-threshold"
  [ "$(fm_context_stow_threshold "$config")" = 120000 ] \
    || fail "comment/blank/whitespace should be skipped/trimmed"
  printf 'garbage\n' > "$config/context-stow-threshold"
  [ "$(fm_context_stow_threshold "$config")" = 200000 ] \
    || fail "non-integer stow threshold should fall back to default"
  printf '0\n' > "$config/context-stow-threshold"
  [ "$(fm_context_stow_threshold "$config")" = 200000 ] \
    || fail "non-positive stow threshold should fall back to default"
  pass "stow threshold reads config/context-stow-threshold, trims noise, and fails safe on bad values"
}

# The shared crossing/marker/hysteresis state machine both supervision paths use
# (the away-mode daemon's context_stow_check and the watcher's context_stow_sweep).
# Proving it here once means the two callers cannot fork this logic.
test_context_stow_should_nudge_state_machine() {
  local dir marker
  dir=$(mktemp -d "$TMP_ROOT/should-nudge.XXXXXX")
  marker="$dir/.context-stow-nudged"
  # Below threshold: no nudge, no marker.
  fm_context_stow_should_nudge 100000 200000 20000 "$marker" \
    && fail "below threshold must not nudge"
  [ -e "$marker" ] && fail "below threshold must record no marker"
  # First crossing: nudge once and record the marker.
  fm_context_stow_should_nudge 250000 200000 20000 "$marker" \
    || fail "first crossing must nudge"
  [ -e "$marker" ] || fail "first crossing must record the marker"
  # Second poll still over: deduped, no re-nudge, marker stays.
  fm_context_stow_should_nudge 250000 200000 20000 "$marker" \
    && fail "a still-over-threshold poll must not re-nudge"
  [ -e "$marker" ] || fail "dedupe must keep the marker"
  # Dip into the hysteresis band (below 200000 but above 180000): stay armed.
  fm_context_stow_should_nudge 190000 200000 20000 "$marker" \
    && fail "a hysteresis-band dip must not nudge"
  [ -e "$marker" ] || fail "a hysteresis-band dip must keep the marker armed"
  # Drop below (threshold - hysteresis)=180000: re-arm (clear the marker).
  fm_context_stow_should_nudge 100000 200000 20000 "$marker" \
    && fail "a below-hysteresis poll must not nudge"
  [ -e "$marker" ] && fail "dropping below the hysteresis band must clear the marker"
  # Re-crossing after re-arm nudges again.
  fm_context_stow_should_nudge 250000 200000 20000 "$marker" \
    || fail "re-crossing after re-arm must nudge again"
  [ -e "$marker" ] || fail "re-crossing must re-record the marker"
  pass "shared should-nudge helper drives crossing, dedupe, hysteresis, and re-arm"
}

# The single canonical directive both paths deliver. It must be self-executing
# (stow -> compact -> re-arm) and keep the substrings callers and tests key on.
test_context_stow_directive_is_self_executing() {
  local out
  out=$(fm_context_stow_directive 250000 200000)
  case "$out" in
    *"/stow now"*) : ;;
    *) fail "directive must tell firstmate to /stow now, got: $out" ;;
  esac
  case "$out" in
    *"/compact"*) : ;;
    *) fail "directive must tell firstmate to /compact, got: $out" ;;
  esac
  case "$out" in
    *"re-arm supervision"*) : ;;
    *) fail "directive must tell firstmate to re-arm supervision, got: $out" ;;
  esac
  case "$out" in
    *"stow threshold 200000"*) : ;;
    *) fail "directive must carry the 'stow threshold <n>' substring, got: $out" ;;
  esac
  case "$out" in
    *"250000 tokens"*) : ;;
    *) fail "directive must carry the live token count, got: $out" ;;
  esac
  pass "shared directive is self-executing (stow -> compact -> re-arm) and keeps its key substrings"
}

test_auto_handoff_flag_opt_in_and_fail_closed() {
  local cfg
  cfg="$TMP_ROOT/auto-cfg"; mkdir -p "$cfg"
  # Absent flag = disabled (fail-closed default, today's escalate-only behavior).
  fm_sm_auto_handoff_enabled "$cfg" && fail "absent config/secondmate-auto-handoff must be DISABLED (return 1)"
  # Present-empty = enabled (presence is consent).
  : > "$cfg/secondmate-auto-handoff"
  fm_sm_auto_handoff_enabled "$cfg" || fail "present-empty flag must be ENABLED"
  # Comment-only = enabled (presence is consent).
  printf '# just a note\n' > "$cfg/secondmate-auto-handoff"
  fm_sm_auto_handoff_enabled "$cfg" || fail "comment-only flag must be ENABLED (presence is consent)"
  # First non-empty line "off" = force-disabled.
  printf 'off\n' > "$cfg/secondmate-auto-handoff"
  fm_sm_auto_handoff_enabled "$cfg" && fail "an 'off' flag must be DISABLED"
  # Any other content = enabled.
  printf 'on\n' > "$cfg/secondmate-auto-handoff"
  fm_sm_auto_handoff_enabled "$cfg" || fail "a non-off content flag must be ENABLED"
  pass "auto-handoff flag is opt-in, fail-closed by default, and 'off' force-disables"
}

test_marker_key_transform() {
  local k
  k=$(fm_sm_context_marker_key 'sess:win.2/p3')
  [ "$k" = 'sess_win_2_p3' ] || fail "marker key must map :/. to _, got: $k"
  pass "marker-key transform maps ':' '/' '.' to '_'"
}

test_threshold_default_and_config
test_munge_matches_claude
test_claude_read_sums_last_mainthread_usage
test_newest_transcript_wins
test_non_claude_and_missing_fail_closed
test_no_jq_fails_closed
test_reporter_over_under_unknown
test_reporter_refuses_non_secondmate
test_jcode_reads_journal_token_usage
test_jcode_ignores_stale_same_home_session
test_jcode_ignores_trailing_degenerate_turn
test_jcode_fails_closed
test_context_stow_threshold_default_and_config
test_context_stow_should_nudge_state_machine
test_context_stow_directive_is_self_executing
test_auto_handoff_flag_opt_in_and_fail_closed
test_marker_key_transform

echo "# all fm-secondmate-context tests passed"
