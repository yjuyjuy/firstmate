#!/usr/bin/env bash
# Static regression tests for the PR-1 AGENTS.md floor trim.
#
# Guard scope (design: data/design-token-efficiency/report.md PR-1):
#   1. Every safety-critical literal survives byte-for-byte. These are the
#      contract strings no trim may touch: the 5 prime directives, every
#      "Never merge" / "never merge a red PR", the drain-before-peek contract,
#      the read-once reminder, the one-live-supervision-cycle contract, the
#      section-9 translation rows, the project-write boundary, and the
#      unlanded-work protections.
#   2. Byte size stays under a fixed floor so mechanism prose cannot silently
#      re-bloat. The floor is set from the PR-1 trim that moved section-2
#      config/data/state mechanism prose to pointers (pre-trim baseline was
#      69,064 bytes; a future re-bloat of roughly 3KB of mechanism prose trips
#      it and forces review instead of silent growth).
#
# This is a string-presence guard, not end-to-end proof that no MEANING was
# lost; the real acceptance is the human review confirming semantic losslessness
# (called out explicitly in the PR-1 delivery note).
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"
AGENTS_BYTES_FLOOR=66200

test_five_prime_directives_survive_verbatim() {
  local contents
  contents=$(cat "$AGENTS")
  assert_contains "$contents" "Never write to a project." \
    "directive 1 (Never write to a project) was trimmed"
  assert_contains "$contents" "Never merge a PR without the captain's explicit word." \
    "directive 2 (Never merge a PR without explicit word) was trimmed"
  assert_contains "$contents" "Never tear down unlanded work." \
    "directive 3 (Never tear down unlanded work) was trimmed"
  assert_contains "$contents" "Crewmates never address the captain." \
    "directive 4 (Crewmates never address the captain) was trimmed"
  assert_contains "$contents" "Report outcomes faithfully." \
    "directive 5 (Report outcomes faithfully) was trimmed"
  pass "the 5 prime directives survive verbatim"
}

test_never_merge_strings_survive_verbatim() {
  local contents
  contents=$(cat "$AGENTS")
  assert_contains "$contents" "Never merge a red PR." \
    "Never merge a red PR was trimmed"
  assert_contains "$contents" "Never force teardown without explicit discard authority." \
    "explicit-discard teardown gate was trimmed"
  assert_contains "$contents" "Uncommitted changes are never landed" \
    "uncommitted-are-never-landed rule was trimmed"
  pass "'never merge' and discard-gate strings survive verbatim"
}

test_drain_contract_survives_verbatim() {
  local contents
  contents=$(cat "$AGENTS")
  assert_contains "$contents" "At the start of every wake-handling turn, drain the durable wake queue before peeking, reading beyond the reason line, steering, or starting work." \
    "drain-before-peek contract was trimmed"
  assert_contains "$contents" "Queued wakes must be drained before other action, stale liveness must be repaired through the emitted protocol, and the worktree-tangle warning must be resolved without touching unlanded work." \
    "drain-before-other-action contract was trimmed"
  pass "the drain-before-peek contract survives verbatim"
}

test_read_once_reminder_survives_verbatim() {
  local contents
  contents=$(cat "$AGENTS")
  assert_contains "$contents" "Read the complete digest once and trust it as this turn's startup and recovery input." \
    "read-once digest rule was trimmed"
  assert_contains "$contents" "preserves only the lock, afk, X-mode, and read-once reminders" \
    "read-once reminder clause was trimmed"
  assert_contains "$contents" "Do not reimplement it by separately running its lock, bootstrap, or initial wake-drain components." \
    "read-once reimplementation guard was trimmed"
  pass "the read-once reminder survives verbatim"
}

test_one_live_supervision_cycle_survives_verbatim() {
  local contents
  contents=$(cat "$AGENTS")
  assert_contains "$contents" "Whenever work is under way, keep exactly one live supervision cycle using the emitted protocol for this primary harness." \
    "one-live-supervision-cycle contract was trimmed"
  assert_contains "$contents" "An X-only home still requires the live supervision cycle so mentions can wake it without fleet work." \
    "X-only live-cycle requirement was trimmed"
  pass "the one-live-supervision-cycle contract survives verbatim"
}

test_section9_translation_rows_survive_verbatim() {
  local contents
  contents=$(cat "$AGENTS")
  for row in \
    "worktree, checkout, primary checkout, or local-main -> local copy" \
    "teardown -> cleanup" \
    "wake, watcher, heartbeat, stale, signal, or check -> notification" \
    "hold, gate, ask-user, needs-decision, blocked, or paused -> the concrete decision" \
    "done, failed, fix-review, checks-passed, cancelled, validation step, or pipeline state -> the concrete result" \
    "brief -> instructions" \
    "crewmate -> worker" \
    "harness, backend, runtime, or adapter -> worker runtime or tool" \
    "status file, metadata, state, task id, or raw path -> durable record"; do
    assert_contains "$contents" "$row" \
      "section-9 translation row was trimmed: $row"
  done
  pass "every section-9 translation row survives verbatim"
}

test_project_write_boundary_survives_verbatim() {
  local contents
  contents=$(cat "$AGENTS")
  assert_contains "$contents" "firstmate reads projects and crewmates change them." \
    "project-write boundary read line was trimmed"
  assert_contains "$contents" "Those paths never authorize forcing, stashing, discarding unlanded work, or hand-writing a project's \`AGENTS.md\`." \
    "project-write boundary exception guard was trimmed"
  assert_contains "$contents" "Firstmate never writes a project's \`AGENTS.md\` directly." \
    "AGENTS.md direct-write prohibition was trimmed"
  assert_contains "$contents" "project removal never bypasses the project-write boundary or unlanded-work checks" \
    "project-removal boundary guard was trimmed"
  assert_contains "$contents" "clones that are read-only to firstmate" \
    "projects read-only declaration was trimmed"
  pass "the project-write boundary survives verbatim"
}

test_unlanded_work_protections_survive_verbatim() {
  local contents
  contents=$(cat "$AGENTS")
  assert_contains "$contents" "Never bypass a refusal or use \`--force\` unless the captain explicitly authorized discarding that work." \
    "forced-discard guard was trimmed"
  assert_contains "$contents" "A teardown refusal for uncommitted or genuinely unpushed-and-unlanded work is a stop-and-investigate result, never an obstacle to bypass." \
    "teardown-refusal investigation rule was trimmed"
  assert_contains "$contents" "preserve the recorded worktree and unlanded work while reconciling ownership" \
    "recovery unlanded-work preservation was trimmed"
  pass "the unlanded-work protections survive verbatim"
}

test_supervision_safety_strings_survive_verbatim() {
  local contents
  contents=$(cat "$AGENTS")
  for phrase in \
    "never judge memory by resident size" \
    "never a live lane's and never the agent or worktree" \
    "ask the captain before shedding work; never stop or kill anything automatically on a resource reading" \
    "Never broadly kill watchers, especially never \`pkill -f bin/fm-watch.sh\`, because that can kill sibling firstmate homes." \
    "never report an unchanged fleet as progress" \
    "No turn ends blind while work is under way" \
    "Harness-aware turn-end guards are structural backstops, not permission to omit the live cycle." \
    "The spawn assertion and generated ship brief must both enforce that project work starts in an isolated disposable worktree, never the primary checkout." \
    "do not arm a separate watcher" \
    "Away mode never expands approval authority for merges, ask-user findings, destructive actions, irreversible actions, or security-sensitive choices." \
    "watcher internals; never touch" \
    "sub-supervisor internals; never touch" \
    "NEVER-pruned" \
    "survives teardown" \
    "never edit by hand"; do
    assert_contains "$contents" "$phrase" \
      "supervision safety string was trimmed: $phrase"
  done
  pass "supervision safety strings survive verbatim"
}

test_section2_owner_pointer_survives_verbatim() {
  # This is also asserted by fm-instruction-owners so it must never move.
  local contents
  contents=$(cat "$AGENTS")
  assert_contains "$contents" "\`docs/configuration.md\` is the single owner of the top-level operational-home layout" \
    "section-2 layout owner pointer was trimmed"
  pass "the section-2 layout owner pointer survives verbatim"
}

test_agents_md_bytes_stay_under_floor() {
  local bytes
  bytes=$(wc -c < "$AGENTS" | tr -d ' ')
  [ -n "$bytes" ] && [ "$bytes" -gt 0 ] || fail "could not measure AGENTS.md byte size"
  if [ "$bytes" -gt "$AGENTS_BYTES_FLOOR" ]; then
    fail "AGENTS.md is $bytes bytes; PR-1 floor is $AGENTS_BYTES_FLOOR (mechanism prose re-bloated)"
  fi
  pass "AGENTS.md is $bytes bytes, under the $AGENTS_BYTES_FLOOR-byte floor"
}

test_five_prime_directives_survive_verbatim
test_never_merge_strings_survive_verbatim
test_drain_contract_survives_verbatim
test_read_once_reminder_survives_verbatim
test_one_live_supervision_cycle_survives_verbatim
test_section9_translation_rows_survive_verbatim
test_project_write_boundary_survives_verbatim
test_unlanded_work_protections_survive_verbatim
test_supervision_safety_strings_survive_verbatim
test_section2_owner_pointer_survives_verbatim
test_agents_md_bytes_stay_under_floor
