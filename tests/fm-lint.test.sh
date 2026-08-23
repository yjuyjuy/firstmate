#!/usr/bin/env bash
# Parity guard for firstmate's shell-lint definition.
#
# bin/fm-lint.sh must be the single owner that BOTH CI
# (.github/workflows/ci.yml) and the pre-push gate (.no-mistakes.yaml
# commands.lint) invoke, so the local lint can never diverge from CI again.
# Regression origin: with no commands.lint configured, the local no-mistakes
# lint step never ran the deterministic
# `shellcheck bin/*.sh bin/backends/*.sh tests/*.sh`, so PRs passed local
# validation yet failed that exact check in CI on info/warning findings such as
# SC2015, SC1007, and SC2034. A second axis was tool-version skew: CI's
# ShellCheck floated with the runner image and still emitted SC2015, which
# ShellCheck retired in 0.11.0. fm-lint.sh now pins one exact version and both
# gates resolve it, so command, file set, config, AND version all match.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-lint.sh"
CI="$ROOT/.github/workflows/ci.yml"
NM="$ROOT/.no-mistakes.yaml"
INSTALLER="$ROOT/bin/fm-install-shellcheck.sh"
# The authoritative file set the one owner must run. It resolves this glob set
# into an array now (for per-file caching and parallelism) rather than passing
# it to one `shellcheck` invocation, but the set itself is unchanged.
CANON='files=(bin/*.sh bin/backends/*.sh tests/*.sh)'
# The pinned version, read from the single source (the one owner itself).
REQUIRED=$("$LINT" --required-version)

# True only when the resolved shellcheck is exactly the pinned version, so the
# lint-running tests below match what CI enforces instead of a runner default.
pinned_ready() {
  command -v shellcheck >/dev/null 2>&1 || return 1
  [ "$(shellcheck --version | awk '/^version:/ {print $2; exit}')" = "$REQUIRED" ]
}

test_owner_exists_and_executable() {
  assert_present "$LINT" "bin/fm-lint.sh is missing"
  [ -x "$LINT" ] || fail "bin/fm-lint.sh must be executable so CI/gate can run it directly"
  pass "one-owner lint script exists and is executable"
}

test_owner_defines_canonical_set() {
  assert_grep "$CANON" "$LINT" "fm-lint.sh must run the canonical shellcheck file set"
  # It must not weaken CI: no severity downgrade and no blanket disable/exclude
  # that would hide findings CI fails on.
  assert_no_grep '--severity' "$LINT" "fm-lint.sh must not lower severity below the CI default"
  assert_no_grep '--exclude' "$LINT" "fm-lint.sh must not blanket-exclude checks CI enforces"
  # Every ShellCheck invocation must ignore ambient configuration (--norc) and
  # follow sourced files (-x) so a single-file lint matches the old whole-set
  # batch verdict; the flags live in one array so they cannot drift.
  assert_grep 'LINT_FLAGS=(--norc -x)' "$LINT" "fm-lint.sh must lint with --norc -x for CI/batch parity"
  pass "fm-lint.sh is the sole authoritative definition at CI-default severity"
}

test_ci_invokes_the_owner() {
  grep -Eq '^      - run: bin/fm-lint\.sh$' "$CI" || fail "CI lint job must invoke the one-owner script as a run step"
  # Guard against regression to an inline re-spelling of the command.
  assert_no_grep 'run: shellcheck' "$CI" "CI must call fm-lint.sh, not re-spell shellcheck inline"
  pass "CI lint job calls the one-owner script, not an inline command"
}

test_nomistakes_invokes_the_owner() {
  grep -Fqx "  lint: 'bin/fm-lint.sh'" "$NM" || fail "no-mistakes commands.lint must map exactly to the one-owner script"
  pass "no-mistakes pre-push lint calls the one-owner script"
}

test_exec_bit_guard_owned_and_wired() {
  # ShellCheck does not inspect file modes, so lost +x on a bin script lints
  # clean and only fails silently at spawn time. The guard must exist, be
  # runnable directly, and run in the same CI lint job as the lint owner.
  local guard
  guard="$ROOT/bin/fm-check-exec-bits.sh"
  assert_present "$guard" "bin/fm-check-exec-bits.sh is missing"
  [ -x "$guard" ] || fail "bin/fm-check-exec-bits.sh must be executable so CI can run it directly"
  grep -Eq '^        run: bin/fm-check-exec-bits\.sh$' "$CI" || fail "CI lint job must run the exec-bit guard"
  pass "exec-bit guard exists, is executable, and runs in the CI lint job"
}

test_pins_an_explicit_version() {
  [ -n "$REQUIRED" ] || fail "fm-lint.sh --required-version printed nothing"
  # The captain-agreed pin: adopt ShellCheck 0.11.0's rule set consistently,
  # which is also what drops the upstream-retired, false-positive-prone SC2015.
  assert_contains "$REQUIRED" "0.11.0" "fm-lint.sh must pin ShellCheck 0.11.0"
  pass "fm-lint.sh pins an explicit ShellCheck version ($REQUIRED)"
}

test_ci_installs_and_logs_the_pinned_version() {
  # CI must derive the version from the one owner (never hardcode a divergent
  # number) and log the resolved version as parity evidence.
  assert_grep "VERSION=\"\$(\"\$ROOT/bin/fm-lint.sh\" --required-version)\"" "$INSTALLER" "installer must read the version fm-lint.sh pins"
  [ "$(grep -Fc "bin/fm-install-shellcheck.sh \"\$RUNNER_TEMP/bin\"" "$CI")" -eq 4 ] || fail "lint and all three portable behavior jobs must use the shared ShellCheck installer"
  assert_grep "ACTUAL_SHA256=\$(sha256sum" "$INSTALLER" "installer must calculate the ShellCheck archive checksum"
  assert_grep "[ \"\$ACTUAL_SHA256\" = \"\$SHA256\" ]" "$INSTALLER" "installer must verify the ShellCheck archive checksum"
  assert_grep "\"\$DESTINATION/shellcheck\" --version" "$INSTALLER" "installer must log the resolved ShellCheck version as evidence"
  pass "CI installs and logs the pinned ShellCheck version from the one owner"
}

test_installer_retries_transient_download_failure() {
  local tmp fakebin destination out
  tmp=$(fm_test_tmproot fm-shellcheck-download)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"

  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$CURL_COUNT" ] || count=$(cat "$CURL_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$CURL_COUNT"
[ "$count" -gt 1 ] || exit 35
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    : > "$2"
    exit 0
  fi
  shift
done
exit 2
SH
  cat > "$fakebin/sha256sum" <<'SH'
#!/usr/bin/env bash
printf '8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198  %s\n' "$1"
SH
  cat > "$fakebin/tar" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-C" ]; then
    mkdir -p "$2/shellcheck-v0.11.0"
    cat > "$2/shellcheck-v0.11.0/shellcheck" <<'EOF'
#!/usr/bin/env bash
printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
EOF
    chmod +x "$2/shellcheck-v0.11.0/shellcheck"
    exit 0
  fi
  shift
done
exit 2
SH
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/curl" "$fakebin/sha256sum" "$fakebin/tar" "$fakebin/sleep"

  out=$(CURL_COUNT="$tmp/curl-count" PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) \
    || fail "installer did not recover from a transient download failure"$'\n'"$out"
  [ "$(cat "$tmp/curl-count")" -eq 2 ] || fail "installer did not retry exactly once after recovery"
  assert_contains "$out" "download attempt 1 failed; retrying" "installer did not disclose its retry"
  [ -x "$destination/shellcheck" ] || fail "installer did not install ShellCheck after retrying"
  pass "ShellCheck installer retries a transient download failure"
}

test_rejects_wrong_shellcheck_version() {
  # Version-independent: a fake shellcheck reporting a different version must be
  # refused before any lint, proving local and CI cannot silently diverge.
  local tmp fakebin out rc
  tmp=$(fm_test_tmproot fm-lint-ver)
  fakebin=$(fm_fakebin "$tmp")
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.9.9\nlicense: x\nwebsite: y\n'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/shellcheck"
  rc=0
  out=$(PATH="$fakebin:$PATH" "$LINT" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh accepted a shellcheck version other than the pin"$'\n'"$out"
  assert_contains "$out" "$REQUIRED" "fm-lint.sh did not name the required version on mismatch"
  assert_contains "$out" "0.9.9" "fm-lint.sh did not report the resolved (wrong) version"
  pass "fm-lint.sh refuses to lint under a non-pinned ShellCheck version"
}

test_catches_a_real_lint_defect() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): lint-defect regression check"
    return
  fi
  # A script with a genuine ShellCheck finding must make the one owner exit
  # non-zero, proving local now runs real shellcheck instead of the old no-op
  # lint step. We deliberately do NOT assert SC2015 (PR 475's actual failure):
  # ShellCheck removed SC2015 in the pinned 0.11.0, so asserting it would make
  # this test itself version-fragile - the very trap being fixed. SC1007 is a
  # warning present at default severity (and is itself one of the recurring
  # classes that slipped through, PR 474).
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-bad)
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$("$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh passed a known-bad fixture"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not report the expected ShellCheck finding"
  pass "fm-lint.sh catches a real lint defect the old no-op gate passed"
}

test_ignores_ambient_shellcheck_opts() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): ambient options regression check"
    return
  fi
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-opts)
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$(SHELLCHECK_OPTS='--exclude=SC1007' "$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh allowed ambient SHELLCHECK_OPTS to hide a finding"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not neutralize ambient SHELLCHECK_OPTS"
  pass "fm-lint.sh ignores ambient ShellCheck options"
}

test_clean_fixture_passes() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): clean fixture check"
    return
  fi
  local tmp good rc
  tmp=$(fm_test_tmproot fm-lint-good)
  mkdir -p "$tmp"
  good="$tmp/good.sh"
  cat > "$good" <<'SH'
#!/usr/bin/env bash
set -eu
if [ -n "${1:-}" ] && [ -d "$1" ]; then
  printf 'ok\n'
fi
SH
  rc=0
  "$LINT" "$good" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "fm-lint.sh flagged a clean fixture (exit $rc)"
  pass "fm-lint.sh passes a clean fixture"
}

# --- speed rework: content-hash cache + parallelism -------------------------
#
# These prove the cache decides WHICH files re-lint without ever changing the
# verdict, per the approved proposal's correctness requirements. Each uses an
# isolated FM_LINT_CACHE_ROOT so a test never touches the real repo cache, and
# spy shellchecks that count invocations so "was this file actually linted?" is
# directly observable rather than inferred from timing.

# A counting shellcheck spy: it records each linted file into $SC_CALLS and
# passes/fails exactly as the pinned real shellcheck would for the fixtures used
# here (a file containing the token SC_FAIL_TOKEN fails; everything else passes).
# This makes the cache-vs-lint decision observable without depending on the real
# tool being installed at the pin.
fm_lint_spy_shellcheck() {
  local fakebin=$1 calls=$2
  cat > "$fakebin/shellcheck" <<SH
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: $REQUIRED\n'
  exit 0
fi
# Drop leading flags; the last argument is the file (parent passes one file).
file=""
for a in "\$@"; do file="\$a"; done
printf '%s\n' "\$file" >> "$calls"
if grep -q SC_FAIL_TOKEN "\$file" 2>/dev/null; then
  printf 'In %s: fake finding\n' "\$file"
  exit 1
fi
exit 0
SH
  chmod +x "$fakebin/shellcheck"
}

test_cache_hit_skips_relint() {
  local tmp fakebin calls cache a rc n1 n2
  tmp=$(fm_test_tmproot fm-lint-cache-hit)
  fakebin=$(fm_fakebin "$tmp")
  calls="$tmp/calls"
  cache="$tmp/cache"
  fm_lint_spy_shellcheck "$fakebin" "$calls"
  a="$tmp/a.sh"
  printf '#!/usr/bin/env bash\necho hi\n' > "$a"

  : > "$calls"
  rc=0
  PATH="$fakebin:$PATH" FM_LINT_CACHE_ROOT="$cache" "$LINT" "$a" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "first cache run failed on a clean file (exit $rc)"
  n1=$(wc -l < "$calls")
  [ "$n1" -eq 1 ] || fail "first run should lint the file exactly once, linted $n1"

  rc=0
  PATH="$fakebin:$PATH" FM_LINT_CACHE_ROOT="$cache" "$LINT" "$a" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "warm cache run failed (exit $rc)"
  n2=$(wc -l < "$calls")
  [ "$n2" -eq 1 ] || fail "unchanged file must not re-lint on a cache hit, total lints $n2"
  pass "cache hit skips re-linting an unchanged file"
}

test_content_change_forces_relint() {
  local tmp fakebin calls cache a n1 n2
  tmp=$(fm_test_tmproot fm-lint-cache-change)
  fakebin=$(fm_fakebin "$tmp")
  calls="$tmp/calls"
  cache="$tmp/cache"
  fm_lint_spy_shellcheck "$fakebin" "$calls"
  a="$tmp/a.sh"
  printf '#!/usr/bin/env bash\necho one\n' > "$a"

  : > "$calls"
  PATH="$fakebin:$PATH" FM_LINT_CACHE_ROOT="$cache" "$LINT" "$a" >/dev/null 2>&1 || true
  n1=$(wc -l < "$calls")
  # change the file's content
  printf '#!/usr/bin/env bash\necho two\n' > "$a"
  PATH="$fakebin:$PATH" FM_LINT_CACHE_ROOT="$cache" "$LINT" "$a" >/dev/null 2>&1 || true
  n2=$(wc -l < "$calls")
  [ "$n2" -eq $((n1 + 1)) ] || fail "a changed file must re-lint (miss); lints went $n1 -> $n2"
  pass "content change forces a re-lint (hash miss)"
}

test_sourced_lib_change_invalidates_dependent() {
  # Under -x a sourced library can change a file's verdict, so a library edit
  # must re-lint its dependents (cache soundness), while an unrelated file must
  # stay cached (minimality).
  local tmp fakebin calls cache lib a b before mid after
  tmp=$(fm_test_tmproot fm-lint-cache-lib)
  fakebin=$(fm_fakebin "$tmp")
  calls="$tmp/calls"
  cache="$tmp/cache"
  fm_lint_spy_shellcheck "$fakebin" "$calls"
  lib="$tmp/lib.sh"
  a="$tmp/a.sh"
  b="$tmp/b.sh"
  printf '#!/usr/bin/env bash\nLIBVAR=1\n' > "$lib"
  # a.sh sources lib.sh with an absolute source= so the closure resolves the
  # temp lib regardless of the repo-root CWD fm-lint runs from.
  # shellcheck disable=SC2016  # $LIBVAR is fixture source text, not for expansion here
  printf '#!/usr/bin/env bash\n# shellcheck source=%s\n. "%s"\necho "$LIBVAR"\n' "$lib" "$lib" > "$a"
  printf '#!/usr/bin/env bash\necho independent\n' > "$b"

  : > "$calls"
  PATH="$fakebin:$PATH" FM_LINT_CACHE_ROOT="$cache" "$LINT" "$a" "$b" >/dev/null 2>&1 || true
  before=$(wc -l < "$calls")
  [ "$before" -eq 2 ] || fail "cold run should lint both files once, linted $before"

  # warm: both cached, nothing re-lints
  PATH="$fakebin:$PATH" FM_LINT_CACHE_ROOT="$cache" "$LINT" "$a" "$b" >/dev/null 2>&1 || true
  mid=$(wc -l < "$calls")
  [ "$mid" -eq 2 ] || fail "warm run must re-lint nothing, total lints $mid"

  # edit the library: a.sh (dependent) must re-lint, b.sh must not
  printf '#!/usr/bin/env bash\nLIBVAR=2\n' > "$lib"
  PATH="$fakebin:$PATH" FM_LINT_CACHE_ROOT="$cache" "$LINT" "$a" "$b" >/dev/null 2>&1 || true
  after=$(wc -l < "$calls")
  [ "$after" -eq 3 ] || fail "a library edit must re-lint exactly its dependent (a.sh), total lints $after"
  grep -Fq "$a" <(tail -n 1 "$calls") || fail "the re-linted file after a lib edit must be the dependent a.sh"
  pass "a sourced-library change invalidates only its dependents"
}

test_version_change_invalidates_cache() {
  # A ShellCheck version (or lint-context) bump must invalidate every cached
  # pass so an upgrade never serves a stale verdict. The cache key folds the
  # resolved ShellCheck version, the flags, AND the cache-format generation into
  # a single salt; a change to any of those must force a re-lint of unchanged
  # files. FM_LINT_CACHE_FORMAT_OVERRIDE moves the generation, standing in for
  # the version axis (which is pinned at runtime) through the same salt, so this
  # exercises the real invalidation path behaviorally.
  local tmp fakebin calls cache a n1 n2 n3
  tmp=$(fm_test_tmproot fm-lint-cache-ver)
  fakebin=$(fm_fakebin "$tmp")
  calls="$tmp/calls"
  cache="$tmp/cache"
  fm_lint_spy_shellcheck "$fakebin" "$calls"
  a="$tmp/a.sh"
  printf '#!/usr/bin/env bash\necho hi\n' > "$a"

  : > "$calls"
  PATH="$fakebin:$PATH" FM_LINT_CACHE_ROOT="$cache" "$LINT" "$a" >/dev/null 2>&1 || true
  n1=$(wc -l < "$calls")
  [ "$n1" -eq 1 ] || fail "cold run should lint once, linted $n1"

  # Same context: warm hit, no re-lint.
  PATH="$fakebin:$PATH" FM_LINT_CACHE_ROOT="$cache" "$LINT" "$a" >/dev/null 2>&1 || true
  n2=$(wc -l < "$calls")
  [ "$n2" -eq 1 ] || fail "warm run with the same context must not re-lint, total lints $n2"

  # Bump the lint-context generation (the version-bump-equivalent axis): the
  # file is byte-identical but its cache key changed, so it MUST re-lint.
  PATH="$fakebin:$PATH" FM_LINT_CACHE_ROOT="$cache" FM_LINT_CACHE_FORMAT_OVERRIDE=99 \
    "$LINT" "$a" >/dev/null 2>&1 || true
  n3=$(wc -l < "$calls")
  [ "$n3" -eq 2 ] || fail "a lint-context (version) bump must invalidate the cache and re-lint, total lints $n3"
  pass "a version/lint-context bump invalidates the cache and forces a re-lint"
}

test_version_axis_in_key() {
  # Directly assert the salt embeds the resolved ShellCheck version, so an
  # upgrade changes every key. This is the invalidation contract at the source
  # level, complementing the behavioral test above.
  # shellcheck disable=SC2016  # these are literal source-text patterns to grep for, not shell expansions
  assert_grep 'sc=${resolved}' "$LINT" "cache salt must embed the resolved ShellCheck version"
  # shellcheck disable=SC2016
  assert_grep 'flags=${LINT_FLAGS[*]}' "$LINT" "cache salt must embed the exact ShellCheck flags"
  # shellcheck disable=SC2016
  assert_grep 'v${LINT_CACHE_FORMAT}' "$LINT" "cache salt must embed the cache-format generation"
  pass "version, flags, and cache-format all participate in the cache key"
}

test_cache_miss_degrades_to_full_lint() {
  # An unwritable cache location must NOT skip any file: it degrades to a full
  # lint (every file linted), never to a silent pass.
  local tmp fakebin calls cache a b n
  tmp=$(fm_test_tmproot fm-lint-cache-ro)
  fakebin=$(fm_fakebin "$tmp")
  calls="$tmp/calls"
  cache="$tmp/cache-ro"
  fm_lint_spy_shellcheck "$fakebin" "$calls"
  a="$tmp/a.sh"; b="$tmp/b.sh"
  printf '#!/usr/bin/env bash\necho a\n' > "$a"
  printf '#!/usr/bin/env bash\necho b\n' > "$b"
  # Make the cache root unwritable: a file where a directory is needed.
  : > "$cache"

  : > "$calls"
  PATH="$fakebin:$PATH" FM_LINT_CACHE_ROOT="$cache" "$LINT" "$a" "$b" >/dev/null 2>&1 || true
  n=$(wc -l < "$calls")
  [ "$n" -eq 2 ] || fail "an unwritable cache must lint every file (full lint), linted $n"
  # Second run with the same unwritable cache must ALSO lint both (no stale skip)
  PATH="$fakebin:$PATH" FM_LINT_CACHE_ROOT="$cache" "$LINT" "$a" "$b" >/dev/null 2>&1 || true
  [ "$(wc -l < "$calls")" -eq 4 ] || fail "an unwritable cache must never serve a skip; expected a second full lint"
  pass "an unwritable cache degrades to a full lint, never a skip"
}

test_findings_are_never_cached() {
  # A file with findings must re-lint (and re-report) every run until fixed: a
  # failing verdict is never recorded as a pass.
  local tmp fakebin calls cache bad rc1 rc2 n
  tmp=$(fm_test_tmproot fm-lint-cache-bad)
  fakebin=$(fm_fakebin "$tmp")
  calls="$tmp/calls"
  cache="$tmp/cache"
  fm_lint_spy_shellcheck "$fakebin" "$calls"
  bad="$tmp/bad.sh"
  printf '#!/usr/bin/env bash\n# SC_FAIL_TOKEN\necho bad\n' > "$bad"

  : > "$calls"
  rc1=0
  PATH="$fakebin:$PATH" FM_LINT_CACHE_ROOT="$cache" "$LINT" "$bad" >/dev/null 2>&1 || rc1=$?
  [ "$rc1" -ne 0 ] || fail "a file with a finding must make fm-lint fail"
  rc2=0
  PATH="$fakebin:$PATH" FM_LINT_CACHE_ROOT="$cache" "$LINT" "$bad" >/dev/null 2>&1 || rc2=$?
  [ "$rc2" -ne 0 ] || fail "a previously-failing file must still fail on re-run (finding was cached as a pass)"
  n=$(wc -l < "$calls")
  [ "$n" -eq 2 ] || fail "a failing file must re-lint every run, linted $n times"
  pass "findings are never cached; a failing file re-lints and re-fails"
}

test_verdict_parity_serial_vs_parallel() {
  # The pass/fail verdict of the parallel cached run must equal a serial
  # per-file lint of the same set, on both a clean set and a set with a defect.
  local tmp fakebin calls cache a b bad rc_clean rc_defect
  tmp=$(fm_test_tmproot fm-lint-parity)
  fakebin=$(fm_fakebin "$tmp")
  calls="$tmp/calls"
  cache="$tmp/cache"
  fm_lint_spy_shellcheck "$fakebin" "$calls"
  a="$tmp/a.sh"; b="$tmp/b.sh"; bad="$tmp/bad.sh"
  printf '#!/usr/bin/env bash\necho a\n' > "$a"
  printf '#!/usr/bin/env bash\necho b\n' > "$b"

  # clean set -> pass
  rc_clean=0
  PATH="$fakebin:$PATH" FM_LINT_CACHE_ROOT="$cache/1" "$LINT" "$a" "$b" >/dev/null 2>&1 || rc_clean=$?
  [ "$rc_clean" -eq 0 ] || fail "clean set must pass (exit $rc_clean)"

  # set with a defect -> fail, regardless of file order (parallel is unordered)
  printf '#!/usr/bin/env bash\n# SC_FAIL_TOKEN\necho bad\n' > "$bad"
  rc_defect=0
  PATH="$fakebin:$PATH" FM_LINT_CACHE_ROOT="$cache/2" "$LINT" "$a" "$bad" "$b" >/dev/null 2>&1 || rc_defect=$?
  [ "$rc_defect" -ne 0 ] || fail "a set containing a defect must fail (parallel verdict must match serial)"
  pass "parallel cached verdict matches serial: clean passes, any defect fails"
}

# --- host gentleness: nice, the -P 4 cap, and heavy-run admission -----------
#
# These prove the sweep can never freeze the host: every ShellCheck runs at low
# priority, no more than 4 run at once, and a full-tree sweep is admitted through
# the fleet's heavy-run queue while a single-file call stays fast and un-gated,
# with no nested double-admission that could deadlock.

test_shellcheck_runs_under_nice() {
  # The per-file worker must invoke shellcheck behind `nice -n 15`. Assert the
  # wiring at the source (the definition and its use), and confirm behaviorally
  # that a lint still succeeds when nice is present.
  assert_grep 'LINT_NICE=(nice -n 15)' "$LINT" "fm-lint.sh must define a nice -n 15 prefix"
  # shellcheck disable=SC2016  # literal source-text pattern, not a shell expansion
  assert_grep '"${LINT_NICE[@]}" shellcheck' "$LINT" "the per-file worker must run shellcheck behind the nice prefix"

  # Behavioral: a spy `nice` records that it was asked for -n 15 wrapping the
  # linter, and forwards to a spy checker. Both on PATH via fakebin.
  local tmp fakebin calls niced a
  tmp=$(fm_test_tmproot fm-lint-nice)
  fakebin=$(fm_fakebin "$tmp")
  calls="$tmp/calls"
  niced="$tmp/niced"
  fm_lint_spy_shellcheck "$fakebin" "$calls"
  cat > "$fakebin/nice" <<SH
#!/usr/bin/env bash
# Expect: nice -n 15 shellcheck ...; record the priority, then exec the rest.
if [ "\$1" = "-n" ]; then
  printf '%s\n' "\$2" >> "$niced"
  shift 2
fi
exec "\$@"
SH
  chmod +x "$fakebin/nice"
  a="$tmp/a.sh"
  printf '#!/usr/bin/env bash\necho hi\n' > "$a"
  PATH="$fakebin:$PATH" FM_LINT_CACHE_ROOT="$tmp/c" FM_LINT_NO_HEAVY_GATE=1 "$LINT" "$a" >/dev/null 2>&1 || true
  [ -s "$niced" ] || fail "shellcheck was not run behind nice"
  grep -Fqx 15 "$niced" || fail "shellcheck must run at nice -n 15, got: $(cat "$niced")"
  pass "every shellcheck runs behind nice -n 15"
}

test_jobs_capped_at_four() {
  # The clamp must hold on a many-core host: no more than 4 concurrent workers.
  # Assert the cap constant and clamp exist, then observe the real cap by having
  # a spy shellcheck record peak concurrency across a set larger than 4.
  assert_grep 'LINT_MAX_JOBS=4' "$LINT" "fm-lint.sh must cap concurrency at 4"
  # shellcheck disable=SC2016  # literal source-text pattern
  assert_grep 'jobs=$LINT_MAX_JOBS' "$LINT" "fm-lint.sh must clamp computed jobs to the cap"

  local tmp fakebin peakdir a i
  tmp=$(fm_test_tmproot fm-lint-cap)
  fakebin=$(fm_fakebin "$tmp")
  peakdir="$tmp/peak"
  mkdir -p "$peakdir"
  # A spy shellcheck that marks itself in-flight, records the live count, then
  # sleeps briefly so overlaps actually happen, then clears. The max directory
  # size seen is the peak concurrency.
  cat > "$fakebin/shellcheck" <<SH
#!/usr/bin/env bash
[ "\$1" = "--version" ] && { printf 'version: $REQUIRED\n'; exit 0; }
me="$peakdir/\$\$"
: > "\$me"
ls "$peakdir" | wc -l >> "$tmp/counts"
sleep 0.3
rm -f "\$me"
exit 0
SH
  chmod +x "$fakebin/shellcheck"
  # 10 distinct files, well above the cap of 4.
  : > "$tmp/counts"
  local -a files=()
  for i in $(seq 1 10); do
    printf '#!/usr/bin/env bash\necho %s\n' "$i" > "$tmp/f$i.sh"
    files+=("$tmp/f$i.sh")
  done
  PATH="$fakebin:$PATH" FM_LINT_CACHE_ROOT="$tmp/c" FM_LINT_NO_HEAVY_GATE=1 "$LINT" "${files[@]}" >/dev/null 2>&1 || true
  local peak
  peak=$(sort -n "$tmp/counts" | tail -n 1)
  [ -n "$peak" ] || fail "no concurrency was recorded"
  [ "$peak" -le 4 ] || fail "concurrency exceeded the cap of 4 (peak $peak)"
  pass "concurrent shellcheck processes never exceed 4 (peak $peak)"
}

test_full_tree_routes_through_heavy_run() {
  # A full-tree sweep (no file args) must be admitted through the heavy-run
  # wrapper; a single-file call must not. A spy wrapper records each invocation.
  local tmp fakebin spy calls a
  tmp=$(fm_test_tmproot fm-lint-heavy)
  fakebin=$(fm_fakebin "$tmp")
  spy="$tmp/heavy-spy.sh"
  calls="$tmp/heavy-calls"
  fm_lint_spy_shellcheck "$fakebin" "$tmp/sc-calls"
  # The spy heavy-run records that it was called, marks the slot active (as the
  # real one does via FM_HEAVY_RUN_ACTIVE), then runs the wrapped command.
  cat > "$spy" <<SH
#!/usr/bin/env bash
printf 'called\n' >> "$calls"
# skip past flags to the -- command
while [ "\$#" -gt 0 ]; do [ "\$1" = "--" ] && { shift; break; }; shift; done
export FM_HEAVY_RUN_ACTIVE=1
exec "\$@"
SH
  chmod +x "$spy"
  a="$tmp/a.sh"
  printf '#!/usr/bin/env bash\necho hi\n' > "$a"

  # single-file: wrapper must NOT be called
  : > "$calls"
  PATH="$fakebin:$PATH" FM_LINT_CACHE_ROOT="$tmp/c1" FM_LINT_HEAVY_RUN="$spy" \
    FM_LINT_NO_HEAVY_GATE='' FM_HEAVY_RUN_ACTIVE='' "$LINT" "$a" >/dev/null 2>&1 || true
  [ ! -s "$calls" ] || fail "a single-file lint must NOT go through heavy-run admission"

  # full-tree (no args): wrapper MUST be called exactly once. Clear the gate
  # seams the surrounding suite may set so this exercises real admission.
  : > "$calls"
  ( cd "$ROOT" && PATH="$fakebin:$PATH" FM_LINT_CACHE_ROOT="$tmp/c2" FM_LINT_HEAVY_RUN="$spy" \
      FM_LINT_NO_HEAVY_GATE='' FM_HEAVY_RUN_ACTIVE='' "$LINT" >/dev/null 2>&1 ) || true
  [ "$(wc -l < "$calls")" -eq 1 ] || fail "a full-tree sweep must go through heavy-run admission exactly once (got $(wc -l < "$calls"))"
  pass "full-tree sweep routes through heavy-run; single-file call does not"
}

test_no_nested_heavy_run_admission() {
  # When already inside a heavy-run slot (FM_HEAVY_RUN_ACTIVE set), a full-tree
  # sweep must NOT re-admit - that would deadlock against the held lease. The
  # spy wrapper must never be called in that case.
  local tmp fakebin spy calls
  tmp=$(fm_test_tmproot fm-lint-nested)
  fakebin=$(fm_fakebin "$tmp")
  spy="$tmp/heavy-spy.sh"
  calls="$tmp/heavy-calls"
  fm_lint_spy_shellcheck "$fakebin" "$tmp/sc-calls"
  cat > "$spy" <<SH
#!/usr/bin/env bash
printf 'called\n' >> "$calls"
while [ "\$#" -gt 0 ]; do [ "\$1" = "--" ] && { shift; break; }; shift; done
exec "\$@"
SH
  chmod +x "$spy"

  : > "$calls"
  ( cd "$ROOT" && PATH="$fakebin:$PATH" FM_HEAVY_RUN_ACTIVE=1 \
      FM_LINT_CACHE_ROOT="$tmp/c" FM_LINT_HEAVY_RUN="$spy" "$LINT" >/dev/null 2>&1 ) || true
  [ ! -s "$calls" ] || fail "a full-tree sweep already inside a heavy-run slot must NOT re-admit (nested double-admission)"
  pass "no nested heavy-run admission when already inside a slot"
}

test_heavy_run_exports_active_marker() {
  # The self-deadlock guard depends on fm-heavy-run exporting FM_HEAVY_RUN_ACTIVE
  # to its child; assert the wrapper does so.
  local heavy="$ROOT/bin/fm-heavy-run.sh"
  assert_grep 'export FM_HEAVY_RUN_ACTIVE=1' "$heavy" "fm-heavy-run.sh must mark its child as inside a slot"
  pass "fm-heavy-run exports the in-slot marker its children self-gate on"
}

test_owner_exists_and_executable
test_owner_defines_canonical_set
test_ci_invokes_the_owner
test_nomistakes_invokes_the_owner
test_exec_bit_guard_owned_and_wired
test_pins_an_explicit_version
test_ci_installs_and_logs_the_pinned_version
test_installer_retries_transient_download_failure
test_rejects_wrong_shellcheck_version
test_catches_a_real_lint_defect
test_ignores_ambient_shellcheck_opts
test_clean_fixture_passes
test_cache_hit_skips_relint
test_content_change_forces_relint
test_sourced_lib_change_invalidates_dependent
test_version_change_invalidates_cache
test_version_axis_in_key
test_cache_miss_degrades_to_full_lint
test_findings_are_never_cached
test_verdict_parity_serial_vs_parallel
test_shellcheck_runs_under_nice
test_jobs_capped_at_four
test_full_tree_routes_through_heavy_run
test_no_nested_heavy_run_admission
test_heavy_run_exports_active_marker
