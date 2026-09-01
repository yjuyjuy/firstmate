#!/usr/bin/env bash
# Behavior tests for bin/fm-prepush-guard-lib.sh - the worktree-scoped pre-push
# guard that refuses an out-of-band worker push to the repository default branch.
#
# The hole this closes (HIGH severity, observed live 2026-08-20): a worker whose
# no-mistakes push step refused could run `no-mistakes axi sync --recover` to take
# custody back and then `git push origin HEAD:<default>` with nothing stopping it.
# These tests exercise the enforcement half: install the guard on a real linked
# worktree and assert the four cases from the brief - refuse a default-branch
# push, allow an fm/<id> push, allow a no-mistakes gate-mirror push, and allow a
# firstmate-authorized push carrying FM_ALLOW_DEFAULT_PUSH=1 - plus that the
# primary checkout is left untouched and the origin/HEAD-unset fallback still
# refuses the common default names.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-prepush-guard-lib.sh"

# Source the library once at top level. It is side-effect-free on source. Do NOT
# re-source it inside a ( ) subshell: bash fires this suite's registered EXIT
# cleanup trap when such a subshell exits, which would delete the temp dir a test
# is still using. Call the library functions directly instead.
# shellcheck source=bin/fm-prepush-guard-lib.sh
. "$LIB"

# The library must always parse.
test_lib_parses() {
  local out rc
  out=$(bash -n "$LIB" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-prepush-guard-lib.sh must parse cleanly (got: $out)"
  pass "fm-prepush-guard-lib.sh: bash -n succeeds"
}

# The emitted hook text must parse, both with and without a chained prior hook.
test_emitted_hook_parses() {
  local tmp
  tmp=$(fm_test_tmproot fm-prepush-hooktext)
  mkdir -p "$tmp"
  fm_prepush_guard_hook_text "" > "$tmp/hook_none.sh"
  bash -n "$tmp/hook_none.sh" || fail "emitted hook (no prior) failed bash -n"
  fm_prepush_guard_hook_text "/a path/with spaces/pre-push" > "$tmp/hook_prior.sh"
  bash -n "$tmp/hook_prior.sh" || fail "emitted hook (with prior) failed bash -n"
  assert_grep "prior_hook='/a path/with spaces/pre-push'" "$tmp/hook_prior.sh" \
    "emitted hook must embed the shell-quoted prior-hook path"
  pass "fm-prepush-guard-lib.sh: emitted hook parses and embeds the prior-hook path"
}

# Build a primary checkout with default branch <default>, an origin bare, a
# no-mistakes gate-mirror bare (under a .no-mistakes/repos/*.git path), and a
# linked worktree on an fm/<id> branch with the guard installed. Echoes the
# worktree path. build_fixture runs in a command-substitution subshell at each
# call site, so it communicates ONLY through the echoed worktree path; a caller
# that needs the primary checkout or a remote derives it from that path.
build_fixture() {  # <default-branch>
  local default=$1 root origin gate primary
  root=$(fm_test_tmproot "fm-prepush-$default")
  mkdir -p "$root"
  origin="$root/origin.git"
  gate="$root/host/.no-mistakes/repos/deadbeef.git"
  primary="$root/main"
  git init -q --bare "$origin"
  mkdir -p "$root/host/.no-mistakes/repos"
  git init -q --bare "$gate"
  git init -q -b "$default" "$primary"
  git -C "$primary" config user.email t@example.invalid
  git -C "$primary" config user.name fmtest
  printf 'a\n' > "$primary/a"
  git -C "$primary" add a
  git -C "$primary" commit -qm init
  git -C "$primary" remote add origin "$origin"
  git -C "$primary" remote add no-mistakes "$gate"
  git -C "$primary" push -q origin "$default"
  git -C "$primary" remote set-head origin "$default" 2>/dev/null || true
  git -C "$primary" worktree add -q "$root/wt" >/dev/null 2>&1
  git -C "$root/wt" checkout -q -b fm/testtask
  fm_install_prepush_guard "$root/wt"
  printf '%s\n' "$root/wt"
}

test_install_pins_worktree_hookspath() {
  local wt
  wt=$(build_fixture main)
  local hp
  hp=$(git -C "$wt" config --worktree --get core.hooksPath 2>/dev/null || true)
  [ -n "$hp" ] || fail "guard did not pin a per-worktree core.hooksPath"
  [ -x "$hp/pre-push" ] || fail "guard did not install an executable pre-push at $hp"
  pass "fm-prepush-guard: install pins a per-worktree core.hooksPath with an executable pre-push"
}

test_refuses_default_branch_push() {
  local wt out rc
  wt=$(build_fixture main)
  # Make an fm branch commit that fast-forwards main, then try to hand-push it.
  git -C "$wt" branch -f localmain origin/main
  git -C "$wt" checkout -q localmain
  printf 'b\n' >> "$wt/a"; git -C "$wt" commit -qam ff
  out=$(git -C "$wt" push origin HEAD:main 2>&1); rc=$?
  expect_code 1 "$rc" "a direct push to the default branch must fail non-zero"
  assert_contains "$out" "REFUSING a direct push to the default branch" \
    "the guard must print its refusal banner"
  assert_contains "$out" "no-mistakes axi sync --recover" \
    "the refusal must name the sync --recover bypass it forbids"
  # The push must not have landed.
  git -C "$wt" fetch -q origin
  [ "$(git -C "$wt" rev-parse origin/main)" != "$(git -C "$wt" rev-parse localmain)" ] \
    || fail "the refused push still updated origin/main"
  pass "fm-prepush-guard: refuses and blocks a direct default-branch push"
}

test_allows_feature_branch_push() {
  local wt rc
  wt=$(build_fixture main)
  printf 'c\n' >> "$wt/a"; git -C "$wt" commit -qam c
  git -C "$wt" push origin HEAD:fm/testtask >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "an fm/<id> branch push must be allowed"
  git -C "$wt" fetch -q origin
  git -C "$wt" rev-parse origin/fm/testtask >/dev/null 2>&1 \
    || fail "the allowed fm/<id> push did not land on origin"
  pass "fm-prepush-guard: allows a normal fm/<id> ship push"
}

test_allows_gate_mirror_push() {
  local wt rc
  wt=$(build_fixture main)
  printf 'd\n' >> "$wt/a"; git -C "$wt" commit -qam d
  # A push to the no-mistakes gate mirror even on the default ref is allowed:
  # the pipeline pushes the work branch there, never an out-of-band land.
  git -C "$wt" push no-mistakes HEAD:main >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a push to the no-mistakes gate mirror must be allowed"
  pass "fm-prepush-guard: allows a push to the no-mistakes gate mirror"
}

test_allows_authorized_default_push() {
  local wt rc
  wt=$(build_fixture main)
  git -C "$wt" branch -f localmain origin/main
  git -C "$wt" checkout -q localmain
  printf 'e\n' >> "$wt/a"; git -C "$wt" commit -qam land
  FM_ALLOW_DEFAULT_PUSH=1 git -C "$wt" push origin HEAD:main >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "an FM_ALLOW_DEFAULT_PUSH=1 land must be allowed"
  git -C "$wt" fetch -q origin
  [ "$(git -C "$wt" rev-parse origin/main)" = "$(git -C "$wt" rev-parse localmain)" ] \
    || fail "the authorized autoland push did not land on origin/main"
  pass "fm-prepush-guard: allows an FM_ALLOW_DEFAULT_PUSH=1 autoland push"
}

test_primary_checkout_unaffected() {
  local wt primary
  wt=$(build_fixture main)
  # The primary checkout is the sibling 'main' dir the worktree was added from.
  # build_fixture runs in a command-substitution subshell, so its PRIMARY global
  # does not survive to here; derive it from the returned worktree path instead.
  primary="$(dirname "$wt")/main"
  [ -d "$primary" ] || fail "could not locate the primary checkout at $primary"
  # The primary checkout must have no hooksPath pinned, so its own pushes are
  # never guarded. The worktreeConfig extension may be enabled repo-wide, but
  # with no primary config.worktree overlay it changes nothing there.
  local php pwt
  php=$(git -C "$primary" config --get core.hooksPath 2>/dev/null || echo none)
  pwt=$(git -C "$primary" config --worktree --get core.hooksPath 2>/dev/null || echo none)
  [ "$php" = none ] || fail "primary checkout unexpectedly has a local core.hooksPath ($php)"
  [ "$pwt" = none ] || fail "primary checkout unexpectedly has a worktree core.hooksPath ($pwt)"
  pass "fm-prepush-guard: leaves the primary checkout's hook configuration untouched"
}

test_fallback_blocks_common_default_names() {
  local wt out rc
  # Build with default 'trunk' so origin/HEAD points at trunk, then remove
  # origin/HEAD to simulate an unset symref. The fallback must still refuse the
  # common names main/master/dev.
  wt=$(build_fixture trunk)
  git -C "$wt" remote set-head origin -d 2>/dev/null || true
  printf 'f\n' >> "$wt/a"; git -C "$wt" commit -qam f
  out=$(git -C "$wt" push origin HEAD:master 2>&1); rc=$?
  expect_code 1 "$rc" "with origin/HEAD unset, a push to 'master' must still fail"
  assert_contains "$out" "REFUSING a direct push to the default branch" \
    "the fallback must refuse the common default name 'master'"
  pass "fm-prepush-guard: origin/HEAD-unset fallback still refuses main/master/dev"
}

test_lib_parses
test_emitted_hook_parses
test_install_pins_worktree_hookspath
test_refuses_default_branch_push
test_allows_feature_branch_push
test_allows_gate_mirror_push
test_allows_authorized_default_push
test_primary_checkout_unaffected
test_fallback_blocks_common_default_names
