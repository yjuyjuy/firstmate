#!/usr/bin/env bash
# Behavior tests for bin/fm-project-mode.sh: it resolves a project's delivery
# mode, yolo flag, autoland flag, and no-ci posture from data/projects.md, accepts
# the four known modes, composes the orthogonal +yolo, +autoland, and +no-ci flags
# in any order, and falls back to "no-mistakes off off off" (with a warning) for an
# unknown mode or an absent project so a typo never silently drops the gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-mode)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data"
cat > "$HOME_DIR/data/projects.md" <<'EOF'
- plain-proj - legacy default, no bracket (added 2026-07-01)
- nm-proj [no-mistakes] - explicit no-mistakes (added 2026-07-01)
- pr-proj [direct-PR] - direct-PR fixture (added 2026-07-01)
- push-proj [direct-push] - direct-push fixture (added 2026-07-24)
- push-yolo-proj [direct-push +yolo] - direct-push with yolo (added 2026-07-24)
- push-autoland-proj [direct-push +autoland] - direct-push self-land fixture (added 2026-07-26)
- push-yolo-autoland-proj [direct-push +yolo +autoland] - both flags fixture (added 2026-07-26)
- autoland-order-proj [direct-push +autoland +yolo] - flags in reverse order (added 2026-07-26)
- local-autoland-proj [local-only +autoland] - local-only self-land fixture (added 2026-07-26)
- noci-proj [no-mistakes +no-ci] - fork-no-CI fixture (added 2026-09-01)
- noci-order-proj [no-mistakes +no-ci +yolo] - no-ci with yolo, order test (added 2026-09-01)
- local-proj [local-only] - local-only fixture (added 2026-07-01)
- bogus-proj [made-up] - unknown mode fixture (added 2026-07-01)
EOF

mode_of() { FM_HOME="$HOME_DIR" "$ROOT/bin/fm-project-mode.sh" "$1" 2>/dev/null; }

# Exact-match assertion (lib.sh only ships assert_contains); the four-word output
# contract needs an exact check so a stray extra word cannot slip through.
assert_equals() { # <expected> <actual> <msg>
  [ "$1" = "$2" ] || fail "$3 (expected [$1], got [$2])"
}

# Every resolved line now carries four words: "<mode> <yolo> <autoland> <noci>".
test_known_modes_resolve() {
  assert_equals "no-mistakes off off off" "$(mode_of plain-proj)" "plain line must default to no-mistakes off off off"
  assert_equals "no-mistakes off off off" "$(mode_of nm-proj)" "explicit no-mistakes must resolve"
  assert_equals "direct-PR off off off" "$(mode_of pr-proj)" "direct-PR must resolve"
  assert_equals "direct-push off off off" "$(mode_of push-proj)" "direct-push must be an accepted mode"
  assert_equals "local-only off off off" "$(mode_of local-proj)" "local-only must resolve"
  pass "fm-project-mode.sh: all four delivery modes resolve with default-off autoland and no-ci words"
}

test_direct_push_carries_yolo() {
  assert_equals "direct-push on off off" "$(mode_of push-yolo-proj)" \
    "direct-push +yolo must resolve mode and yolo independently, autoland+noci off"
  pass "fm-project-mode.sh: direct-push composes with the orthogonal yolo flag"
}

# +autoland is orthogonal to mode and +yolo and is order-independent inside the brackets.
test_autoland_flag_resolves() {
  assert_equals "direct-push off on off" "$(mode_of push-autoland-proj)" \
    "direct-push +autoland must set autoland on and leave yolo+noci off"
  assert_equals "direct-push on on off" "$(mode_of push-yolo-autoland-proj)" \
    "+yolo +autoland must set both flags on"
  assert_equals "direct-push on on off" "$(mode_of autoland-order-proj)" \
    "flag order inside the brackets must not matter"
  assert_equals "local-only off on off" "$(mode_of local-autoland-proj)" \
    "local-only +autoland must compose too"
  pass "fm-project-mode.sh: +autoland composes orthogonally and order-independently"
}

# +no-ci is orthogonal to mode, +yolo, and +autoland and is order-independent inside
# the brackets. It marks a fork/no-merge-authority repo whose forge reports no CI, so
# the no-mistakes DoD parks on a clean+mergeable PR instead of chasing an unreachable green.
test_noci_flag_resolves() {
  assert_equals "no-mistakes off off on" "$(mode_of noci-proj)" \
    "no-mistakes +no-ci must set noci on and leave yolo+autoland off"
  assert_equals "no-mistakes on off on" "$(mode_of noci-order-proj)" \
    "+no-ci must compose with +yolo order-independently"
  pass "fm-project-mode.sh: +no-ci composes orthogonally and order-independently"
}

# An unknown mode and an absent project both fall back to the safe default and
# warn to stderr, so a typo never silently drops the validation gate.
test_unknown_mode_falls_back_to_safe_default() {
  local out err
  out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-project-mode.sh" bogus-proj 2>/dev/null)
  assert_contains "$out" "no-mistakes off" "unknown mode must fall back to no-mistakes off"
  err=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-project-mode.sh" bogus-proj 2>&1 >/dev/null)
  assert_contains "$err" "unknown mode" "unknown mode must warn to stderr"

  out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-project-mode.sh" not-registered 2>/dev/null)
  assert_equals "no-mistakes off off off" "$out" "absent project must fall back to no-mistakes off off off"
  pass "fm-project-mode.sh: unknown mode and absent project fall back safely"
}

# --strict is the form a caller whose output is a delivery CONTRACT must use.
# The default fallback is a stderr warning a scripted caller never sees, so a
# strict caller gets a refusal (exit 3, nothing on stdout) instead of a mode the
# registry never authorized.
test_strict_refuses_an_unresolvable_project() {
  local out err rc
  out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-project-mode.sh" --strict not-registered 2>/dev/null); rc=$?
  expect_code 3 "$rc" "--strict must refuse an absent project"
  [ -z "$out" ] || fail "--strict must print no mode on stdout when it refuses (got [$out])"
  err=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-project-mode.sh" --strict not-registered 2>&1 >/dev/null)
  assert_contains "$err" "cannot resolve a delivery mode" "--strict refusal must say what failed"
  assert_contains "$err" "registered projects:" "--strict refusal must list the registered names"

  out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-project-mode.sh" --strict bogus-proj 2>/dev/null); rc=$?
  expect_code 3 "$rc" "--strict must refuse an unknown mode instead of silently defaulting"
  [ -z "$out" ] || fail "--strict must print no mode for an unknown registry mode (got [$out])"
  pass "fm-project-mode.sh: --strict refuses instead of falling back to the default"
}

# The path-versus-name mistake is the whole reason --strict exists: this script
# and fm-brief.sh take a registry NAME while fm-spawn.sh takes a PATH, so
# "projects/<name>" resolved to a silent no-mistakes default. When the basename
# IS registered the refusal must say so and name the correct argument.
test_strict_names_the_path_versus_name_mistake() {
  local err rc
  err=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-project-mode.sh" --strict projects/pr-proj 2>&1 >/dev/null); rc=$?
  expect_code 3 "$rc" "--strict must refuse a path-shaped argument"
  assert_contains "$err" "looks like a PATH" "the refusal must name the path-versus-name cause"
  assert_contains "$err" '"pr-proj" IS registered' "the refusal must say the basename is registered"
  assert_contains "$err" "fm-spawn.sh takes the project PATH" "the refusal must name which script takes a path"

  # A path whose basename is NOT registered still gets the path hint, but must
  # not claim a registry entry that does not exist.
  err=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-project-mode.sh" --strict projects/ghost-proj 2>&1 >/dev/null)
  assert_contains "$err" "looks like a PATH" "an unregistered path must still get the path hint"
  case "$err" in *"IS registered"*) fail "an unregistered basename must not be claimed as registered" ;; esac
  pass "fm-project-mode.sh: --strict names the path-versus-name mistake actionably"
}

# The default (non-strict) form is used by callers that legitimately want a
# fallback (bin/fm-fleet-sync.sh, bin/fm-spawn.sh, bin/fm-home-seed.sh), so it
# must keep behaving exactly as before.
test_default_form_is_unchanged() {
  local out rc
  out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-project-mode.sh" not-registered 2>/dev/null); rc=$?
  expect_code 0 "$rc" "the default form must still exit 0 for an absent project"
  assert_equals "no-mistakes off off off" "$out" "the default form must still fall back"
  assert_equals "direct-PR off off off" "$(mode_of pr-proj)" "the default form must still resolve a registered project"
  pass "fm-project-mode.sh: the default fallback form is unchanged for its existing callers"
}

test_known_modes_resolve
test_direct_push_carries_yolo
test_autoland_flag_resolves
test_noci_flag_resolves
test_unknown_mode_falls_back_to_safe_default
test_strict_refuses_an_unresolvable_project
test_strict_names_the_path_versus_name_mistake
test_default_form_is_unchanged
