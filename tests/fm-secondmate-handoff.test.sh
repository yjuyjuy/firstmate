#!/usr/bin/env bash
# Behavior tests for the secondmate context-handoff orchestrator
# (fm-secondmate-handoff.sh): fail-closed refusals, the threshold gate, the
# dry-run action sequence, and capture idempotency. The steering/exit/respawn
# side effects are exercised through FM_SM_HANDOFF_DRY_RUN so no live backend or
# real agent is needed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-handoff-tests)
mkdir -p "$TMP_ROOT"

# Fresh FM_HOME + claude config per case, wired so fm_sm_context_tokens reads a
# controllable token count for the secondmate.
setup_home() {  # <name> <tokens|-> [kind] [with_window] [with_homedir]
  local name=$1 tokens=$2 kind=${3:-secondmate} with_window=${4:-1} with_homedir=${5:-1}
  local fmhome="$TMP_ROOT/$name" home="$TMP_ROOT/$name-home" config="$TMP_ROOT/$name-cfg"
  mkdir -p "$fmhome/config" "$fmhome/state"
  [ "$with_homedir" = 1 ] && mkdir -p "$home/data"
  {
    [ "$with_window" = 1 ] && printf 'window=test:fm-%s\n' sm
    printf 'worktree=%s\nharness=claude\nkind=%s\nhome=%s\n' "$home" "$kind" "$home"
  } > "$fmhome/state/sm.meta"
  if [ "$tokens" != - ]; then
    local dir
    dir="$config/projects/$(printf '%s' "$home" | tr '/.' '--')"
    mkdir -p "$dir"
    printf '{"type":"assistant","message":{"usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' "$tokens" > "$dir/s.jsonl"
  fi
  printf '%s\t%s\t%s\n' "$fmhome" "$home" "$config"
}

# run_handoff sets STATUS and OUT in the parent shell (no command-substitution
# subshell, which would strip the assignments).
run_handoff() {  # <fmhome> <config> <args...>
  local fmhome=$1 config=$2; shift 2
  FM_HOME="$fmhome" CLAUDE_CONFIG_DIR="$config" FM_SM_HANDOFF_DRY_RUN=1 \
    "$ROOT/bin/fm-secondmate-handoff.sh" "$@" > "$TMP_ROOT/out" 2>&1
  STATUS=$?
  OUT=$(cat "$TMP_ROOT/out")
}

test_refuse_missing_and_non_secondmate() {
  local fmhome home config out
  IFS=$'\t' read -r fmhome home config < <(setup_home refuse-ship 210000 ship)
  run_handoff "$fmhome" "$config" sm; out=$OUT; expect_code 1 "$STATUS" "non-secondmate must refuse"
  assert_contains "$out" "is not a secondmate" "non-secondmate refusal message"

  out=$(FM_HOME="$fmhome" FM_SM_HANDOFF_DRY_RUN=1 "$ROOT/bin/fm-secondmate-handoff.sh" nope 2>&1)
  expect_code 1 "$?" "unknown id must refuse"
  assert_contains "$out" "no metadata" "unknown id refusal message"

  expect_code 2 "$(FM_HOME="$fmhome" "$ROOT/bin/fm-secondmate-handoff.sh" >/dev/null 2>&1; echo $?)" "no id is a usage error"
  pass "refuses missing metadata, non-secondmate tasks, and missing id"
}

test_refuse_no_window_or_home() {
  local fmhome home config out
  IFS=$'\t' read -r fmhome home config < <(setup_home refuse-nowin 210000 secondmate 0 1)
  run_handoff "$fmhome" "$config" sm; out=$OUT; expect_code 1 "$STATUS" "no window must refuse"
  assert_contains "$out" "no window recorded" "no-window refusal is a recovery case, not a handoff"

  IFS=$'\t' read -r fmhome home config < <(setup_home refuse-nohome 210000 secondmate 1 0)
  run_handoff "$fmhome" "$config" sm; out=$OUT; expect_code 1 "$STATUS" "missing home dir must refuse"
  assert_contains "$out" "home for 'sm' is missing" "missing-home refusal message"
  pass "refuses when the window or home is missing"
}

test_threshold_gate() {
  local fmhome home config out
  # Under threshold, non-force: no-op success.
  IFS=$'\t' read -r fmhome home config < <(setup_home gate-under 50000)
  run_handoff "$fmhome" "$config" sm; out=$OUT; expect_code 0 "$STATUS" "under-threshold is a clean no-op"
  assert_contains "$out" "no handoff needed" "under-threshold no-op message"
  assert_not_contains "$out" "DRY-RUN" "under-threshold must not start the sequence"

  # Unknown read, non-force: fail closed.
  IFS=$'\t' read -r fmhome home config < <(setup_home gate-unknown -)
  run_handoff "$fmhome" "$config" sm; out=$OUT; expect_code 1 "$STATUS" "unknown context must refuse without --force"
  assert_contains "$out" "unreadable" "unknown-context refusal message"
  pass "threshold gate no-ops under threshold and fails closed on an unreadable read"
}

test_dry_run_full_sequence_over_threshold() {
  local fmhome home config out
  IFS=$'\t' read -r fmhome home config < <(setup_home seq-over 260000)
  run_handoff "$fmhome" "$config" sm; out=$OUT; expect_code 0 "$STATUS" "over-threshold dry-run should complete"
  assert_contains "$out" ">= threshold" "should announce the crossing"
  assert_contains "$out" "fm-send.sh" "should steer the secondmate to write the doc"
  assert_contains "$out" "handoff-latest.md" "should target the durable in-home doc, not temp"
  assert_contains "$out" "exit agent" "should exit the old agent"
  assert_contains "$out" "fm-spawn.sh sm --secondmate" "should respawn a fresh secondmate"
  assert_contains "$out" "handoff complete" "should report completion"
  pass "over-threshold dry-run runs the full steer/exit/respawn sequence"
}

# Regression: the post-respawn steer must reference only files that exist. A
# prior version pointed the (about-to-be-exited) agent at
# data/.handoff-instructions.md, a transient file deleted at cleanup, which
# opened a parent pending-reply expectation the dead agent could never answer
# and escalated a phantom "blocked: pending-reply-missed" on every handoff. The
# handoff steer now names the durable data/handoff-latest.md inline.
test_no_stale_instruction_reference() {
  local fmhome home config out
  IFS=$'\t' read -r fmhome home config < <(setup_home no-stale-instr 260000)
  run_handoff "$fmhome" "$config" sm; out=$OUT; expect_code 0 "$STATUS" "over-threshold dry-run should complete"
  assert_not_contains "$out" ".handoff-instructions.md" "no message may reference the transient instruction file"
  assert_contains "$out" "data/handoff-latest.md" "the handoff steer must name the durable in-home doc"
  pass "the post-respawn steer references only the durable handoff doc, never a transient file"
}

test_force_bypasses_threshold() {
  local fmhome home config out
  # Force with an unreadable context still proceeds.
  IFS=$'\t' read -r fmhome home config < <(setup_home force-unknown -)
  run_handoff "$fmhome" "$config" sm --force; out=$OUT; expect_code 0 "$STATUS" "--force proceeds despite unknown read"
  assert_contains "$out" "forced" "forced handoff should announce itself"
  assert_contains "$out" "fm-spawn.sh sm --secondmate" "forced handoff still respawns"
  pass "--force bypasses the threshold and unknown-read gate"
}

test_env_force_bypasses_threshold() {
  local fmhome home config out
  # FM_SM_HANDOFF_FORCE=1 must behave exactly like --force (documented env knob).
  IFS=$'\t' read -r fmhome home config < <(setup_home env-force -)
  out=$(FM_HOME="$fmhome" CLAUDE_CONFIG_DIR="$config" FM_SM_HANDOFF_DRY_RUN=1 \
    FM_SM_HANDOFF_FORCE=1 "$ROOT/bin/fm-secondmate-handoff.sh" sm 2>&1)
  expect_code 0 "$?" "FM_SM_HANDOFF_FORCE=1 proceeds despite unknown read"
  assert_contains "$out" "forced" "env-forced handoff should announce itself"
  assert_contains "$out" "fm-spawn.sh sm --secondmate" "env-forced handoff still respawns"
  pass "FM_SM_HANDOFF_FORCE env bypasses the threshold like --force"
}

# Regression: the internal fm-send calls must inherit FM_HOME. The script
# resolves FM_HOME but a prior version never EXPORTED it, so a bare invocation
# (no FM_HOME in env) left it unset in the child fm-send, which fails closed
# (bin/fm-send.sh) and aborted the handoff mid-sequence. The dry-run tests above
# never catch this because dry-run does not exec the child fm-send. This builds a
# real firstmate home whose bin/ shadows fm-send.sh and fm-spawn.sh with
# recorders that capture the FM_HOME they were invoked with, then drives the
# idempotent-resume path (capture already complete) so the child calls run for
# real without a live backend.
#
# fm_setup_shadow_home <name> echoes: <fmhome> <smhome>. The fmhome bin/ is a
# symlink farm of the real bin (so fm-backend.sh and the adapters resolve) with
# fm-send.sh / fm-spawn.sh replaced by FM_HOME recorders writing to
# <fmhome>/data/fm-send.env and fm-spawn.env.
fm_setup_shadow_home() {  # <name>
  local name=$1 f fmhome smhome
  fmhome="$TMP_ROOT/$name"; smhome="$TMP_ROOT/$name-sm"
  mkdir -p "$fmhome/data" "$fmhome/state" "$fmhome/config" "$fmhome/bin" "$smhome/data"
  : > "$fmhome/AGENTS.md"
  for f in "$ROOT/bin"/*; do
    ln -s "$f" "$fmhome/bin/$(basename "$f")"
  done
  # Recorders: capture the FM_HOME the internal call inherited. A missing
  # FM_HOME (the pre-fix bug) records the literal token UNSET so the assertion
  # fails loudly instead of on an empty string.
  for f in fm-send fm-spawn; do
    rm -f "$fmhome/bin/$f.sh"
    cat > "$fmhome/bin/$f.sh" <<REC
#!/usr/bin/env bash
printf '%s\n' "\${FM_HOME:-UNSET}" >> "$fmhome/data/$f.env"
exit 0
REC
    chmod +x "$fmhome/bin/$f.sh"
  done
  # Secondmate meta + a completed prior capture so capture_complete() is true and
  # the run resumes straight at the child fm-spawn/fm-send calls.
  {
    printf 'window=test:fm-sm\n'
    printf 'worktree=%s\nharness=claude\nkind=secondmate\nhome=%s\n' "$smhome" "$smhome"
  } > "$fmhome/state/sm.meta"
  printf 'continuation\n' > "$smhome/data/handoff-latest.md"
  : > "$smhome/data/.handoff-done"
  printf '%s\t%s\n' "$fmhome" "$smhome"
}

test_bare_invocation_exports_fm_home_to_children() {
  local fmhome smhome status
  IFS=$'\t' read -r fmhome smhome < <(fm_setup_shadow_home export-bare)
  # BARE: no FM_HOME in env. The script must resolve and export it from its own
  # root so the child fm-send/fm-spawn inherit it. FM_SM_HANDOFF_POLL keeps the
  # post-respawn sleep short.
  ( unset FM_HOME
    FM_SM_HANDOFF_POLL=0 FM_SM_HANDOFF_EXIT_TIMEOUT=1 \
      "$fmhome/bin/fm-secondmate-handoff.sh" sm --force >/dev/null 2>&1 )
  status=$?
  expect_code 0 "$status" "bare handoff should complete"
  [ -f "$fmhome/data/fm-send.env" ] || fail "bare invocation never reached the child fm-send"
  [ -f "$fmhome/data/fm-spawn.env" ] || fail "bare invocation never reached the child fm-spawn"
  assert_not_contains "$(cat "$fmhome/data/fm-send.env")" "UNSET" "child fm-send must inherit FM_HOME, never unset"
  assert_contains "$(cat "$fmhome/data/fm-send.env")" "$fmhome" "child fm-send must inherit THIS home"
  assert_contains "$(cat "$fmhome/data/fm-spawn.env")" "$fmhome" "child fm-spawn must inherit THIS home"
  pass "a bare invocation exports FM_HOME so the internal fm-send/fm-spawn never fail closed"
}

test_caller_fm_home_preserved() {
  local scripthome caller smhome status f
  # Split the two homes so a wrong override is observable: the SCRIPT lives in
  # scripthome (its own root), but the secondmate meta + completed capture live
  # in a DIFFERENT caller home. If the script respected its own root instead of
  # the caller's FM_HOME, state resolution would miss the meta and fail
  # "no metadata"; a clean completion proves the caller's FM_HOME won.
  scripthome="$TMP_ROOT/caller-script"; caller="$TMP_ROOT/caller-home"; smhome="$TMP_ROOT/caller-sm"
  mkdir -p "$scripthome/data" "$scripthome/state" "$scripthome/config" "$scripthome/bin" \
           "$caller/data" "$caller/state" "$caller/config" "$smhome/data"
  : > "$scripthome/AGENTS.md"; : > "$caller/AGENTS.md"
  for f in "$ROOT/bin"/*; do ln -s "$f" "$scripthome/bin/$(basename "$f")"; done
  for f in fm-send fm-spawn; do
    rm -f "$scripthome/bin/$f.sh"
    cat > "$scripthome/bin/$f.sh" <<REC
#!/usr/bin/env bash
printf '%s\n' "\${FM_HOME:-UNSET}" >> "$caller/data/$f.env"
exit 0
REC
    chmod +x "$scripthome/bin/$f.sh"
  done
  # Meta + completed capture in the CALLER home only.
  {
    printf 'window=test:fm-sm\n'
    printf 'worktree=%s\nharness=claude\nkind=secondmate\nhome=%s\n' "$smhome" "$smhome"
  } > "$caller/state/sm.meta"
  printf 'continuation\n' > "$smhome/data/handoff-latest.md"; : > "$smhome/data/.handoff-done"
  ( FM_HOME="$caller" FM_SM_HANDOFF_POLL=0 FM_SM_HANDOFF_EXIT_TIMEOUT=1 \
      "$scripthome/bin/fm-secondmate-handoff.sh" sm --force >/dev/null 2>&1 )
  status=$?
  expect_code 0 "$status" "caller-FM_HOME handoff should complete (meta found in the caller home)"
  assert_contains "$(cat "$caller/data/fm-send.env")" "$caller" "child fm-send must inherit the caller's FM_HOME"
  assert_not_contains "$(cat "$caller/data/fm-send.env")" "$scripthome" "must not override the caller's valid FM_HOME with the script root"
  pass "a caller-provided FM_HOME is preserved and passed to the internal calls"
}

test_capture_idempotent() {
  local fmhome home config out
  IFS=$'\t' read -r fmhome home config < <(setup_home idem 260000)
  # A completed capture from a prior run: doc + done marker, no pending request.
  printf 'continuation\n' > "$home/data/handoff-latest.md"
  : > "$home/data/.handoff-done"
  run_handoff "$fmhome" "$config" sm --force; out=$OUT; expect_code 0 "$STATUS" "idempotent resume should succeed"
  assert_contains "$out" "already captured" "a completed capture must not be repeated"
  assert_not_contains "$out" "write" "must not rewrite the instruction file when capture is complete"
  pass "a completed capture is detected and not repeated (idempotent resume)"
}

test_refuse_missing_and_non_secondmate
test_refuse_no_window_or_home
test_threshold_gate
test_dry_run_full_sequence_over_threshold
test_no_stale_instruction_reference
test_force_bypasses_threshold
test_env_force_bypasses_threshold
test_bare_invocation_exports_fm_home_to_children
test_caller_fm_home_preserved
test_capture_idempotent

echo "# all fm-secondmate-handoff tests passed"
