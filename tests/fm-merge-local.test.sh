#!/usr/bin/env bash
# Characterization tests for bin/fm-merge-local.sh - the local-only landing gate.
#
# fm-merge-local.sh is the ONE sanctioned exception to hard rule #1 (never run
# state-changing git in projects/): it lands a local-only ship task by merging its
# fm/<id> branch into the project's default branch as a clean --no-ff merge. Its
# whole safety value is that it REFUSES a diverged base (default is not an ancestor
# of the branch) rather than resolving a conflict blind, and only ever records a
# --no-ff merge commit so each landed change stays one revertable unit.
#
# These pin CURRENT behavior against real throwaway git repos (fixtures, never a
# real project). No network is touched; the only mutation is inside a temp repo the
# test owns. Covered:
#   - REFUSE when fm/<id> has diverged from the default branch (default not an
#     ancestor), and NO merge commit is written.
#   - clean --no-ff land when default IS an ancestor: a merge commit appears, both
#     parents are recorded, and the reported before/after shas match.
#   - refuse a non-local-only mode (direct-push and a PR mode name), with a distinct
#     message per mode.
#   - refuse a missing branch, a missing meta, a dirty default worktree, and a
#     project checked out on a non-default branch.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

# Build a project repo on its default branch `main` with a task branch fm/<id>.
# The task branch adds a commit on top of main. Echoes nothing; sets globals via
# the caller's chosen dir. <diverge> non-empty adds an EXTRA commit to main after
# the branch is cut, so main is no longer an ancestor of fm/<id> (diverged base).
build_project() {  # <proj-dir> <id> [diverge]
  local proj=$1 id=$2 diverge=${3:-}
  mkdir -p "$proj"
  git -C "$proj" init -q -b main
  printf 'base\n' > "$proj/file.txt"
  git -C "$proj" add -- file.txt
  git -C "$proj" -c user.email=t@t -c user.name=t commit -q -m baseline
  # Cut the task branch and add its own commit.
  git -C "$proj" checkout -q -b "fm/$id"
  printf 'branch work\n' >> "$proj/file.txt"
  git -C "$proj" add -- file.txt
  git -C "$proj" -c user.email=t@t -c user.name=t commit -q -m "work on fm/$id"
  git -C "$proj" checkout -q main
  if [ -n "$diverge" ]; then
    printf 'main-only\n' > "$proj/main-only.txt"
    git -C "$proj" add -- main-only.txt
    git -C "$proj" -c user.email=t@t -c user.name=t commit -q -m "diverge main"
  fi
}

# Write a local-only task meta. <mode> defaults to local-only.
write_meta() {  # <state> <id> <proj> [mode]
  local state=$1 id=$2 proj=$3 mode=${4:-local-only}
  mkdir -p "$state"
  cat > "$state/$id.meta" <<EOF
window=test:fm-$id
worktree=$proj
project=$proj
harness=echo
kind=ship
mode=$mode
EOF
}

# Run fm-merge-local.sh for <id> against a home at <home>. Echoes stdout+stderr;
# exit status goes to $RC_FILE (read after the $(...) capture).
RC_FILE="$TMP_ROOT/merge-local-rc"
run_merge_local() {  # <home> <id>
  local home=$1 id=$2
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    "$MERGE_LOCAL" "$id" 2>&1
  printf '%s' "$?" > "$RC_FILE"
}
merge_local_rc() { cat "$RC_FILE"; }

test_clean_no_ff_land() {
  local home="$TMP_ROOT/clean-home" proj="$TMP_ROOT/clean-proj" out
  build_project "$proj" c1
  write_meta "$home/state" c1 "$proj"
  local before
  before=$(git -C "$proj" rev-parse --short main)
  out=$(run_merge_local "$home" c1)
  expect_code 0 "$(merge_local_rc)" "clean land must exit 0"
  assert_contains "$out" "merged fm/c1 into local main" "clean land must report the merge"
  # A merge commit exists on main with two parents (--no-ff never fast-forwards).
  local parents
  parents=$(git -C "$proj" rev-list --parents -n1 main | wc -w)
  [ "$parents" -eq 3 ] || fail "expected a 2-parent merge commit on main, got $parents fields"
  # The reported before/after are the real main shas.
  local after
  after=$(git -C "$proj" rev-parse --short main)
  assert_contains "$out" "($before -> $after)" "reported before/after shas must match main"
  [ "$before" != "$after" ] || fail "main did not advance after the merge"
  pass "clean local-only land records a --no-ff merge commit and advances main"
}

test_refuse_diverged_base() {
  local home="$TMP_ROOT/div-home" proj="$TMP_ROOT/div-proj" out
  build_project "$proj" d1 diverge
  write_meta "$home/state" d1 "$proj"
  local before
  before=$(git -C "$proj" rev-parse main)
  out=$(run_merge_local "$home" d1)
  expect_code 1 "$(merge_local_rc)" "a diverged base must be refused"
  assert_contains "$out" "REFUSED" "diverged base must print REFUSED"
  assert_contains "$out" "has diverged from main" "refusal must name the divergence"
  assert_contains "$out" "rebase" "refusal must tell the operator to rebase"
  # No merge commit was written: main is unchanged and still single-parent.
  [ "$(git -C "$proj" rev-parse main)" = "$before" ] || fail "main advanced despite a refused diverged merge"
  local parents
  parents=$(git -C "$proj" rev-list --parents -n1 main | wc -w)
  [ "$parents" -eq 2 ] || fail "a merge commit was written despite the refusal"
  pass "a diverged base is refused with no merge commit written"
}

test_refuse_non_local_only_mode() {
  local home="$TMP_ROOT/mode-home" proj="$TMP_ROOT/mode-proj" out
  build_project "$proj" m1
  # direct-push gets its own distinct message.
  write_meta "$home/state" m1 "$proj" direct-push
  out=$(run_merge_local "$home" m1)
  expect_code 1 "$(merge_local_rc)" "direct-push must be refused"
  assert_contains "$out" "mode=direct-push" "direct-push refusal must name the mode"
  assert_contains "$out" "already pushed to origin" "direct-push refusal must explain it lands on the forge"
  # A PR mode gets the generic PR-merge message.
  write_meta "$home/state" m1 "$proj" no-mistakes
  out=$(run_merge_local "$home" m1)
  expect_code 1 "$(merge_local_rc)" "no-mistakes must be refused"
  assert_contains "$out" "fm-pr-merge.sh" "a PR-mode refusal must point at fm-pr-merge.sh"
  pass "a non-local-only mode is refused with a mode-specific message"
}

test_refuse_missing_branch() {
  local home="$TMP_ROOT/nobr-home" proj="$TMP_ROOT/nobr-proj" out
  build_project "$proj" x1
  # Meta names id nb1, whose fm/nb1 branch does not exist in the project.
  write_meta "$home/state" nb1 "$proj"
  out=$(run_merge_local "$home" nb1)
  expect_code 1 "$(merge_local_rc)" "a missing branch must be refused"
  assert_contains "$out" "branch fm/nb1 does not exist" "missing branch must be named"
  pass "a missing fm/<id> branch is refused"
}

test_refuse_missing_meta() {
  local home="$TMP_ROOT/nometa-home" out
  mkdir -p "$home/state"
  out=$(run_merge_local "$home" ghost)
  expect_code 1 "$(merge_local_rc)" "a missing meta must be refused"
  assert_contains "$out" "no meta for task ghost" "missing meta must be named"
  pass "a missing task meta is refused"
}

test_refuse_dirty_default_worktree() {
  local home="$TMP_ROOT/dirty-home" proj="$TMP_ROOT/dirty-proj" out
  build_project "$proj" dr1
  write_meta "$home/state" dr1 "$proj"
  # Dirty the default worktree so the merge must refuse to write into it.
  printf 'uncommitted\n' >> "$proj/file.txt"
  out=$(run_merge_local "$home" dr1)
  expect_code 1 "$(merge_local_rc)" "a dirty default worktree must be refused"
  assert_contains "$out" "dirty working tree" "refusal must name the dirty tree"
  pass "a dirty default worktree is refused"
}

test_refuse_wrong_current_branch() {
  local home="$TMP_ROOT/wrongbr-home" proj="$TMP_ROOT/wrongbr-proj" out
  build_project "$proj" wb1
  write_meta "$home/state" wb1 "$proj"
  # Leave the project checked out on the task branch, not the default.
  git -C "$proj" checkout -q "fm/wb1"
  out=$(run_merge_local "$home" wb1)
  expect_code 1 "$(merge_local_rc)" "a non-default current branch must be refused"
  assert_contains "$out" "expected default branch 'main'" "refusal must name the expected default"
  pass "a project not on its default branch is refused"
}

test_clean_no_ff_land
test_refuse_diverged_base
test_refuse_non_local_only_mode
test_refuse_missing_branch
test_refuse_missing_meta
test_refuse_dirty_default_worktree
test_refuse_wrong_current_branch

echo "# all fm-merge-local tests passed"
