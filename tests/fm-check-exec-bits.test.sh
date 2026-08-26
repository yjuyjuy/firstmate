#!/usr/bin/env bash
# Behavioral guard for bin/fm-check-exec-bits.sh - the single owner of the
# exec-bit rule for bin/ entrypoints.
#
# These tests exercise the guard against isolated fixture trees (via its
# optional [root] argument) so the pass/fail verdict is directly observable,
# rather than only re-checking parity against the real repo. They pin the two
# rules the guard owns:
#   1. The uniform shell-script rule: every bin/*.sh and bin/backends/*.sh must
#      carry +x, sourced-only *-lib.sh libraries included (a deliberate uniform
#      rule, not an entrypoint-only one - preserved here, not re-litigated).
#   2. The non-.sh entrypoint rule: a shebang-bearing non-.sh file (jira-axi,
#      *.py, *.mjs, *.js) must carry +x, while a non-.sh file with no shebang is
#      data or a sourced-only module and is exempt.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-check-exec-bits.sh"

# build_clean_tree <root>: lay down a fixture bin/ tree where every covered
# entrypoint carries +x and the guard therefore passes. Individual tests copy
# this shape and then strip +x from exactly one file to observe a trip.
build_clean_tree() {
  local root=$1
  mkdir -p "$root/bin/backends"

  # Rule 1 subjects: shell scripts (with and without a shebang), all +x.
  printf '#!/usr/bin/env bash\necho entry\n' > "$root/bin/fm-entry.sh"
  # A sourced-only library: no shebang, still must carry +x under the uniform rule.
  printf '# shellcheck shell=bash\nLIBVAR=1\n' > "$root/bin/fm-thing-lib.sh"
  printf '#!/usr/bin/env bash\necho backend\n' > "$root/bin/backends/some-backend.sh"
  chmod 0755 "$root/bin/fm-entry.sh" "$root/bin/fm-thing-lib.sh" "$root/bin/backends/some-backend.sh"

  # Rule 2 subjects: shebang-bearing non-.sh entrypoints, all +x.
  printf '#!/usr/bin/env python3\nprint("bare")\n' > "$root/bin/bare-axi"            # jira-axi class
  printf '#!/usr/bin/env node\nconsole.log("mjs")\n' > "$root/bin/policy.mjs"
  printf '#!/usr/bin/env node\nconsole.log("js")\n' > "$root/bin/relay.js"
  printf '#!/usr/bin/env python3\nprint("mover")\n' > "$root/bin/backends/mover.py"  # herdr-workspace-move.py class
  chmod 0755 "$root/bin/bare-axi" "$root/bin/policy.mjs" "$root/bin/relay.js" "$root/bin/backends/mover.py"

  # Exempt subject: a non-.sh file with NO shebang (data / sourced-only module).
  # It stays non-executable on purpose so the exemption tests can prove the
  # guard never trips on it.
  printf '{ "config": true }\n' > "$root/bin/config.json"
  chmod 0644 "$root/bin/config.json"
}

# run_guard <root>: run the guard against a fixture root, capturing stdout+stderr
# and the exit code into the globals OUT and RC.
run_guard() {
  RC=0
  OUT=$("$GUARD" "$1" 2>&1) || RC=$?
}

test_guard_exists_and_executable() {
  assert_present "$GUARD" "bin/fm-check-exec-bits.sh is missing"
  [ -x "$GUARD" ] || fail "bin/fm-check-exec-bits.sh must be executable so CI can run it directly"
  pass "exec-bit guard exists and is itself executable"
}

test_passes_on_correct_tree() {
  local tmp
  tmp=$(fm_test_tmproot fm-exec-clean)
  build_clean_tree "$tmp"
  run_guard "$tmp"
  expect_code 0 "$RC" "clean fixture tree"
  assert_not_contains "$OUT" "missing the executable bit" "clean tree must report no offenders"
  pass "guard passes on a tree where every entrypoint carries +x"
}

test_fails_on_sh_entrypoint_missing_x() {
  local tmp
  tmp=$(fm_test_tmproot fm-exec-sh)
  build_clean_tree "$tmp"
  chmod 0644 "$tmp/bin/fm-entry.sh"
  run_guard "$tmp"
  [ "$RC" -ne 0 ] || fail "guard must fail when a bin/*.sh entrypoint lacks +x"$'\n'"$OUT"
  assert_contains "$OUT" "bin/fm-entry.sh" "guard must name the offending .sh entrypoint"
  pass "guard fails on a .sh entrypoint missing +x"
}

test_fails_on_sourced_only_sh_lib_missing_x() {
  # The uniform rule is deliberate: a sourced-only *-lib.sh with no shebang
  # STILL must carry +x. This preserves the existing design (libraries are not
  # exempt) rather than re-litigating it into an entrypoint-only rule.
  local tmp
  tmp=$(fm_test_tmproot fm-exec-lib)
  build_clean_tree "$tmp"
  chmod 0644 "$tmp/bin/fm-thing-lib.sh"
  run_guard "$tmp"
  [ "$RC" -ne 0 ] || fail "uniform rule: a sourced-only *-lib.sh without +x must still trip"$'\n'"$OUT"
  assert_contains "$OUT" "bin/fm-thing-lib.sh" "guard must name the offending sourced-only library"
  pass "guard preserves the uniform rule: a sourced-only .sh library needs +x"
}

test_fails_on_backends_sh_missing_x() {
  local tmp
  tmp=$(fm_test_tmproot fm-exec-backend-sh)
  build_clean_tree "$tmp"
  chmod 0644 "$tmp/bin/backends/some-backend.sh"
  run_guard "$tmp"
  [ "$RC" -ne 0 ] || fail "guard must fail when a bin/backends/*.sh lacks +x"$'\n'"$OUT"
  assert_contains "$OUT" "bin/backends/some-backend.sh" "guard must name the offending backend adapter"
  pass "guard fails on a bin/backends/*.sh missing +x"
}

test_fails_on_bare_interpreter_entrypoint_missing_x() {
  # jira-axi class: a shebang-bearing entrypoint with NO extension. Before the
  # extension-agnostic rule, the *.sh-only glob missed this entirely.
  local tmp
  tmp=$(fm_test_tmproot fm-exec-bare)
  build_clean_tree "$tmp"
  chmod 0644 "$tmp/bin/bare-axi"
  run_guard "$tmp"
  [ "$RC" -ne 0 ] || fail "guard must fail when a bare (no-extension) shebang entrypoint lacks +x"$'\n'"$OUT"
  assert_contains "$OUT" "bin/bare-axi" "guard must name the offending bare entrypoint"
  pass "guard fails on a bare shebang entrypoint (jira-axi class) missing +x"
}

test_fails_on_extensioned_non_sh_entrypoints_missing_x() {
  # herdr-workspace-move.py / *.mjs / *.js class: shebang-bearing entrypoints
  # whose extension is not .sh. Each must trip independently.
  local tmp target
  for target in bin/backends/mover.py bin/policy.mjs bin/relay.js; do
    tmp=$(fm_test_tmproot fm-exec-ext)
    build_clean_tree "$tmp"
    chmod 0644 "$tmp/$target"
    run_guard "$tmp"
    [ "$RC" -ne 0 ] || fail "guard must fail when $target lacks +x"$'\n'"$OUT"
    assert_contains "$OUT" "$target" "guard must name the offending non-.sh entrypoint $target"
  done
  pass "guard fails on extensioned non-.sh entrypoints (.py/.mjs/.js) missing +x"
}

test_non_sh_without_shebang_is_exempt() {
  # A non-.sh file with no shebang is data or a sourced-only module: it is NOT a
  # directly-invoked entrypoint, so a missing +x must NOT trip the guard. The
  # clean tree already ships bin/config.json at 0644; the guard must still pass.
  local tmp
  tmp=$(fm_test_tmproot fm-exec-exempt)
  build_clean_tree "$tmp"
  [ ! -x "$tmp/bin/config.json" ] || fail "fixture bug: config.json should be non-executable"
  run_guard "$tmp"
  expect_code 0 "$RC" "non-.sh no-shebang file must not trip the guard"
  assert_not_contains "$OUT" "bin/config.json" "guard must not flag a non-.sh no-shebang file"
  pass "guard exempts a non-.sh file with no shebang even without +x"
}

test_counts_all_offenders() {
  # Multiple missing bits across both rules must all be reported and counted, so
  # a batch of losses surfaces in one run rather than one-at-a-time.
  local tmp
  tmp=$(fm_test_tmproot fm-exec-many)
  build_clean_tree "$tmp"
  chmod 0644 "$tmp/bin/fm-entry.sh" "$tmp/bin/bare-axi" "$tmp/bin/backends/mover.py"
  run_guard "$tmp"
  [ "$RC" -ne 0 ] || fail "guard must fail when several entrypoints lack +x"$'\n'"$OUT"
  assert_contains "$OUT" "bin/fm-entry.sh" "guard must name the .sh offender"
  assert_contains "$OUT" "bin/bare-axi" "guard must name the bare offender"
  assert_contains "$OUT" "bin/backends/mover.py" "guard must name the .py offender"
  assert_contains "$OUT" "3 bin entrypoint(s) lack +x" "guard must summarize the offender count"
  pass "guard reports and counts every offender in one run"
}

test_real_repo_tree_is_clean() {
  # The guard must pass on the actual repo (default root, no argument), so the
  # committed tree stays green and this exercises the real jira-axi / *.py /
  # *.mjs / *.js entrypoints, not only synthetic fixtures.
  local out rc=0
  out=$("$GUARD" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "guard must pass on the real repo tree (exit $rc)"$'\n'"$out"
  pass "guard passes on the real committed bin/ tree"
}

test_guard_exists_and_executable
test_passes_on_correct_tree
test_fails_on_sh_entrypoint_missing_x
test_fails_on_sourced_only_sh_lib_missing_x
test_fails_on_backends_sh_missing_x
test_fails_on_bare_interpreter_entrypoint_missing_x
test_fails_on_extensioned_non_sh_entrypoints_missing_x
test_non_sh_without_shebang_is_exempt
test_counts_all_offenders
test_real_repo_tree_is_clean
