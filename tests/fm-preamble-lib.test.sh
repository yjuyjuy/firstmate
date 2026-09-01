#!/usr/bin/env bash
# Tests for bin/fm-preamble-lib.sh - the single owner of the operational-home
# resolution preamble (FM_ROOT/FM_HOME/STATE/DATA/CONFIG) and the canonical
# die/fail for bin/ entrypoints.
#
# WHY THESE TESTS
# The lib is a behavior-preserving extraction of a preamble that ~74 entrypoints
# copy-pasted inline, plus their per-script die/fail. The whole value of the
# extraction is that a migrated script resolves the home EXACTLY as its inline
# copy did and its die/fail exit with the SAME code. So this suite pins:
#   - the resolution chain under fixture layouts and every override, matching the
#     inline chain byte-for-byte in outcome
#   - die/fail print "<FM_PROG>: <message>" and exit with the fixed documented
#     code (canonical default 1, an explicit code argument, and the per-script
#     FM_DIE_CODE legacy default)
#   - a lint-style guard that every MIGRATED pilot entrypoint no longer declares
#     its own die/fail and no longer carries its own FM_ROOT/FM_HOME/STATE/DATA
#     resolution lines (the duplication this lib exists to end)
#
# shellcheck disable=SC2016 # The single-quoted probe bodies and grep patterns
# below are LITERAL on purpose: $FM_ROOT/$STATE/etc. must expand inside the child
# `bash -c` at run time (or stay a literal needle in a grep), never here.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck disable=SC2153 # ROOT is exported by tests/lib.sh, sourced above.
LIB="$ROOT/bin/fm-preamble-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-preamble-lib-tests)

# The pilot set migrated to the lib in phase 1. Kept here as the single list the
# lint-style guard iterates; a phase-2 migration extends it.
MIGRATED_PILOT="fm-grill-reserve.sh fm-lavish-lan.sh fm-token-report.sh fm-ticket-cost-rollup.sh fm-release-lsp.sh fm-afk-inbox.sh"

# run_probe <fm-prog> <die-code-or-empty> <script-body> [env-assignments...]
# Sources the lib exactly as a migrated entrypoint does (FM_PROG/FM_DIE_CODE set
# BEFORE the source), then runs <script-body> which may echo the resolved vars or
# call die/fail. Echoes the child's stdout+stderr. The caller captures the exit
# code itself with `out=$(run_probe ...); PROBE_CODE=$?`, because command
# substitution runs run_probe in a subshell where a PROBE_CODE it set would be
# lost - the child's exit is what the substitution's own $? carries.
run_probe() {
  local prog=$1 die_code=$2 body=$3; shift 3
  env "$@" bash -c '
    FM_PROG="'"$prog"'"
    '"${die_code:+FM_DIE_CODE=$die_code}"'
    . "'"$LIB"'"
    '"$body"'
  ' 2>&1
}

# --- resolution chain -------------------------------------------------------

test_resolution_defaults_to_repo_root() {
  # No overrides: FM_ROOT is the lib's parent (the repo root), and STATE/DATA/
  # CONFIG hang off FM_HOME=FM_ROOT. This is the exact outcome the inline
  # `$SCRIPT_DIR/..` preamble produced for a script invoked from bin/.
  local out
  out=$(run_probe fm-probe '' 'printf "%s\n%s\n%s\n%s\n%s\n" "$FM_ROOT" "$FM_HOME" "$STATE" "$DATA" "$CONFIG"'); PROBE_CODE=$?
  expect_code 0 "$PROBE_CODE" "default resolution should not exit nonzero"
  local root home state data config
  { read -r root; read -r home; read -r state; read -r data; read -r config; } <<EOF
$out
EOF
  [ "$root" = "$ROOT" ] || fail "FM_ROOT should default to the repo root, got '$root' (want '$ROOT')"
  [ "$home" = "$ROOT" ] || fail "FM_HOME should default to FM_ROOT, got '$home'"
  [ "$state" = "$ROOT/state" ] || fail "STATE should be FM_HOME/state, got '$state'"
  [ "$data" = "$ROOT/data" ] || fail "DATA should be FM_HOME/data, got '$data'"
  [ "$config" = "$ROOT/config" ] || fail "CONFIG should be FM_HOME/config, got '$config'"
  pass "preamble: default chain resolves FM_ROOT=repo root and STATE/DATA/CONFIG off FM_HOME"
}

test_fm_home_override_wins() {
  # An explicit FM_HOME is honored exactly and STATE/DATA/CONFIG follow it, even
  # when FM_ROOT resolves elsewhere - the isolated-home case every fleet member
  # relies on.
  local home="$TMP_ROOT/home-a" out
  mkdir -p "$home"
  out=$(run_probe fm-probe '' 'printf "%s\n%s\n%s\n" "$STATE" "$DATA" "$CONFIG"' FM_HOME="$home"); PROBE_CODE=$?
  expect_code 0 "$PROBE_CODE" "FM_HOME override should not exit nonzero"
  assert_contains "$out" "$home/state" "STATE should follow an explicit FM_HOME"
  assert_contains "$out" "$home/data" "DATA should follow an explicit FM_HOME"
  assert_contains "$out" "$home/config" "CONFIG should follow an explicit FM_HOME"
  pass "preamble: explicit FM_HOME wins and STATE/DATA/CONFIG follow it"
}

test_root_override_sets_root_and_home() {
  # FM_ROOT_OVERRIDE feeds FM_ROOT, and (absent FM_HOME) FM_HOME too - the exact
  # precedence of the inline `${FM_ROOT_OVERRIDE:-...}` / `${FM_HOME:-${FM_ROOT_OVERRIDE:-...}}`.
  local ovr="$TMP_ROOT/root-ovr" out
  mkdir -p "$ovr"
  out=$(run_probe fm-probe '' 'printf "%s\n%s\n%s\n" "$FM_ROOT" "$FM_HOME" "$STATE"' FM_ROOT_OVERRIDE="$ovr"); PROBE_CODE=$?
  local root home state
  { read -r root; read -r home; read -r state; } <<EOF
$out
EOF
  [ "$root" = "$ovr" ] || fail "FM_ROOT_OVERRIDE should set FM_ROOT, got '$root'"
  [ "$home" = "$ovr" ] || fail "FM_ROOT_OVERRIDE should set FM_HOME when FM_HOME unset, got '$home'"
  [ "$state" = "$ovr/state" ] || fail "STATE should follow the overridden home, got '$state'"
  pass "preamble: FM_ROOT_OVERRIDE sets FM_ROOT and, absent FM_HOME, FM_HOME too"
}

test_state_data_config_overrides_win() {
  # The three leaf overrides are honored independently of FM_HOME, matching the
  # inline `${FM_STATE_OVERRIDE:-...}` (etc.) each script carried.
  local home="$TMP_ROOT/home-b" s="$TMP_ROOT/s" d="$TMP_ROOT/d" c="$TMP_ROOT/c" out
  out=$(run_probe fm-probe '' 'printf "%s\n%s\n%s\n" "$STATE" "$DATA" "$CONFIG"' \
    FM_HOME="$home" FM_STATE_OVERRIDE="$s" FM_DATA_OVERRIDE="$d" FM_CONFIG_OVERRIDE="$c"); PROBE_CODE=$?
  expect_code 0 "$PROBE_CODE" "leaf overrides should not exit nonzero"
  local state data config
  { read -r state; read -r data; read -r config; } <<EOF
$out
EOF
  [ "$state" = "$s" ] || fail "FM_STATE_OVERRIDE should win, got '$state'"
  [ "$data" = "$d" ] || fail "FM_DATA_OVERRIDE should win, got '$data'"
  [ "$config" = "$c" ] || fail "FM_CONFIG_OVERRIDE should win, got '$config'"
  pass "preamble: FM_STATE/DATA/CONFIG overrides win independently of FM_HOME"
}

# --- die / fail exit codes --------------------------------------------------

test_die_default_code_is_one() {
  # Canonical fixed default: a die with no explicit code and no FM_DIE_CODE exits 1.
  local out
  out=$(run_probe fm-probe '' 'die "boom"'); PROBE_CODE=$?
  expect_code 1 "$PROBE_CODE" "die with no code should exit the canonical default 1"
  assert_contains "$out" "fm-probe: boom" "die should print '<FM_PROG>: <message>' to stderr"
  pass "preamble: die default exit code is the fixed canonical 1"
}

test_fail_default_code_is_one() {
  local out
  out=$(run_probe fm-probe '' 'fail "nope"'); PROBE_CODE=$?
  expect_code 1 "$PROBE_CODE" "fail with no code should exit the canonical default 1"
  assert_contains "$out" "fm-probe: nope" "fail should print '<FM_PROG>: <message>' to stderr"
  pass "preamble: fail default exit code is the fixed canonical 1"
}

test_die_explicit_code_wins() {
  # An explicit second argument is the exit code, overriding any default.
  local out
  out=$(run_probe fm-probe 1 'die "arg" 64'); PROBE_CODE=$?
  expect_code 64 "$PROBE_CODE" "an explicit die code argument should win over FM_DIE_CODE"
  assert_contains "$out" "fm-probe: arg" "die should still print the prefixed message"
  pass "preamble: die explicit code argument wins over the default"
}

test_fm_die_code_legacy_default() {
  # A script whose legacy die defaulted to a non-1 code sets FM_DIE_CODE to
  # preserve it; a codeless die then exits that legacy code, not 1.
  local out
  out=$(run_probe fm-probe 2 'die "legacy"'); PROBE_CODE=$?
  expect_code 2 "$PROBE_CODE" "FM_DIE_CODE should set the codeless-die default"
  assert_contains "$out" "fm-probe: legacy" "die should print the prefixed message under FM_DIE_CODE"
  pass "preamble: FM_DIE_CODE sets the codeless-die default (legacy-code preservation)"
}

test_fm_prog_defaults_to_basename() {
  # With FM_PROG unset the prefix is the invoked basename without .sh; a real
  # migrated script always sets FM_PROG explicitly, but the fallback keeps a
  # bare source from printing an empty prefix.
  local script="$TMP_ROOT/fm-fallback.sh" out rc
  cat > "$script" <<EOF
#!/usr/bin/env bash
. "$LIB"
die "x"
EOF
  chmod +x "$script"
  out=$(bash "$script" 2>&1); rc=$?
  expect_code 1 "$rc" "fallback die should exit 1"
  assert_contains "$out" "fm-fallback: x" "FM_PROG should default to the basename without .sh"
  pass "preamble: FM_PROG defaults to the invoked basename without .sh"
}

# --- migration lint guard ---------------------------------------------------

test_migrated_scripts_source_the_lib() {
  # Every pilot script must actually source the lib; otherwise it is not migrated
  # and the guards below are vacuous.
  local f
  for f in $MIGRATED_PILOT; do
    grep -Eq '\. +"\$SCRIPT_DIR/fm-preamble-lib\.sh"' "$ROOT/bin/$f" \
      || fail "migrated pilot $f should source bin/fm-preamble-lib.sh"
  done
  pass "preamble: every migrated pilot script sources the lib"
}

test_migrated_scripts_drop_local_die_fail() {
  # A migrated script must not re-declare its own die/fail: the lib owns them.
  local f
  for f in $MIGRATED_PILOT; do
    grep -Eq '^[[:space:]]*(die|fail)\(\)' "$ROOT/bin/$f" \
      && fail "migrated pilot $f still declares its own die()/fail(); the lib owns it"
  done
  pass "preamble: no migrated pilot script re-declares its own die()/fail()"
}

test_migrated_scripts_drop_inline_resolution() {
  # A migrated script must not carry its own FM_ROOT/FM_HOME/STATE/DATA/CONFIG
  # resolution lines: the lib owns the chain. SCRIPT_DIR stays inline by design
  # (it must run before the lib can be sourced), so it is NOT checked here.
  local f var
  for f in $MIGRATED_PILOT; do
    for var in FM_ROOT FM_HOME STATE DATA CONFIG; do
      grep -Eq "^${var}=\"?\\\$\\{FM_" "$ROOT/bin/$f" \
        && fail "migrated pilot $f still resolves $var inline; the lib owns the chain"
    done
  done
  pass "preamble: no migrated pilot script resolves FM_ROOT/FM_HOME/STATE/DATA/CONFIG inline"
}

test_resolution_defaults_to_repo_root
test_fm_home_override_wins
test_root_override_sets_root_and_home
test_state_data_config_overrides_win
test_die_default_code_is_one
test_fail_default_code_is_one
test_die_explicit_code_wins
test_fm_die_code_legacy_default
test_fm_prog_defaults_to_basename
test_migrated_scripts_source_the_lib
test_migrated_scripts_drop_local_die_fail
test_migrated_scripts_drop_inline_resolution

pass "fm-preamble-lib.sh: all checks passed"
