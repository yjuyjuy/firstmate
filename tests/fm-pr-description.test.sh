#!/usr/bin/env bash
# Behavior tests for bin/fm-pr-description.sh.
#
# Covers the captain enrichment contract: summary + acceptance criteria from
# the brief Task text, Mattermost and ticket sections, prior-work commit URLs
# resolved through the project remote, related reports, the {TASK}-placeholder
# refusal, and the omit-when-nothing-discoverable rule (enrichment sections
# are never emitted empty, and bare numbers are never emitted as links).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-description)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data"

# cwd for invocations that must not resolve a project from the test runner's
# own directory (which is a git repo with a remote).
NONREPO_DIR="$TMP_ROOT/nonrepo"
mkdir -p "$NONREPO_DIR"

test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-pr-description.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-pr-description.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-pr-description.sh emitted unexpected output: $out"
  pass "fm-pr-description.sh: bash -n succeeds"
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-pr-description.sh" --help)
  assert_contains "$help" "Refuses to run when the brief's Task text still contains the {TASK}" \
    "fm-pr-description.sh --help omitted its header terminator"
  pass "fm-pr-description.sh: --help renders the complete header"
}

test_usage_validation() {
  local out rc
  out=$("$ROOT/bin/fm-pr-description.sh" 2>&1); rc=$?
  expect_code 2 "$rc" "no args must exit 2"
  assert_contains "$out" "missing task id" "no args must name the missing task id"
  out=$("$ROOT/bin/fm-pr-description.sh" '../escape' --stdout 2>&1); rc=$?
  expect_code 2 "$rc" "path-traversal task id must be refused"
  assert_contains "$out" "invalid task id" "path-traversal task id must be refused loudly"
  out=$("$ROOT/bin/fm-pr-description.sh" unknown-task-xyz --stdout 2>&1); rc=$?
  expect_code 1 "$rc" "missing brief must exit 1"
  assert_contains "$out" "task brief is unavailable" "missing brief must report unavailability"
  pass "fm-pr-description.sh: usage validation is fail-closed"
}

test_task_placeholder_refusal() {
  local home id out rc
  home="$HOME_DIR/placeholder-home"
  mkdir -p "$home/data/ph-task"
  id=ph-task
  cat > "$home/data/$id/brief.md" <<'EOF'
You are a crewmate.

# Task
{TASK}

# Rules
1. Never push.
EOF
  local out rc
  OUT_FILE="$TMP_ROOT/ph-task.stdout"
  out=$(cd "$NONREPO_DIR" && FM_HOME="$home" "$ROOT/bin/fm-pr-description.sh" "$id" --stdout 2>&1); rc=$?
  expect_code 1 "$rc" "unfilled {TASK} placeholder must refuse generation"
  assert_contains "$out" "{TASK}" "refusal must name the placeholder"
  printf '%s\n' "$out" > "$OUT_FILE"
  assert_no_grep "## Summary" "$OUT_FILE" "no skeleton may be emitted for an unfilled brief"
  pass "fm-pr-description.sh: refuses to skeleton an unfilled brief"
}

# Fixture: a brief carrying every enrichment signal plus a git project remote
# so ticket short-refs and prior-work URLs can resolve to full URLs.
# Args: <home> <id> <project-dir> <remote-owner/repo>
write_full_fixture() {
  local home=$1 id=$2 project=$3 remote=$4
  mkdir -p "$home/data/$id" "$home/state"
  cat > "$home/data/$id/brief.md" <<EOF
You are a crewmate.

# Task
Add a widget flipper.
Acceptance criteria:
- [ ] Flipper flips in both directions
- [ ] No state leaks between widgets
See also #42 for the original report.
Ticket JIRA-42 blocks the flip animation.

# Rules
1. Never push.
EOF
  cat > "$home/state/$id.meta" <<EOF
window=fake
worktree=$home/worktrees/x
project=$project
harness=fixture
kind=ship
mode=direct-PR
EOF
  mkdir -p "$project"
  git -C "$project" init -q -b main
  git -C "$project" remote add origin "git@github.com:$remote.git"
  git -C "$project" config user.email test@example.com
  git -C "$project" config user.name Tester
  echo one > "$project/flipper.c"
  git -C "$project" add .
  git -C "$project" -c commit.gpgsign=false commit -qm "flipper: initial widget"
  echo two >> "$project/flipper.c"
  git -C "$project" add .
  git -C "$project" -c commit.gpgsign=false commit -qm "flipper: flip both ways"
  main_sha=$(git -C "$project" rev-parse HEAD)
  git -C "$project" checkout -q -b "fm/$id"
  echo three >> "$project/flipper.c"
  git -C "$project" add .
  git -C "$project" -c commit.gpgsign=false commit -qm "flipper: task change"
  git -C "$project" update-ref refs/remotes/origin/main "$main_sha"
  git -C "$project" update-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}

test_full_skeleton_sections() {
  local home id out
  home="$TMP_ROOT/full-home"
  write_full_fixture "$home" full-task "$TMP_ROOT/full-project" acme/widgets
  local id out
  OUT_FILE="$TMP_ROOT/full-task.stdout"
  id=full-task
  out=$(cd "$NONREPO_DIR" && FM_HOME="$home" "$ROOT/bin/fm-pr-description.sh" "$id" --stdout) || fail "full fixture must generate"
  printf '%s\n' "$out" > "$OUT_FILE"
  assert_grep "## Summary" "$OUT_FILE" "skeleton must carry a Summary heading"
  assert_grep "Add a widget flipper" "$OUT_FILE" "Summary must carry the brief Task text"
  assert_grep "## Acceptance criteria" "$OUT_FILE" "skeleton must carry the Acceptance criteria heading"
  assert_grep 'Flipper flips in both directions' "$OUT_FILE" "checkbox criteria must ride into the skeleton"
  assert_grep "## Approach" "$OUT_FILE" "skeleton must carry the Approach fill-in section"
  assert_grep "## Tradeoffs" "$OUT_FILE" "skeleton must carry the Tradeoffs fill-in section"
  assert_grep "## Test evidence" "$OUT_FILE" "skeleton must carry the Test evidence fill-in section"
  assert_grep "test-first and end-to-end coverage declaration" "$OUT_FILE" "Test evidence must demand the coverage declaration"
  assert_grep "## Related tickets" "$OUT_FILE" "issue/ticket section must appear when tickets are discoverable"
  assert_grep "https://github.com/acme/widgets/issues/42" "$OUT_FILE" "short #NNN ticket ref must resolve to a full URL"
  assert_grep '[#42](https://github.com/acme/widgets/issues/42)' "$OUT_FILE" "bare #42 in the summary must become a full-URL link"
  assert_grep "JIRA-42 (resolve to the tracker URL before opening)" "$OUT_FILE" "tracker-style ticket id must be kept verbatim"
  assert_grep "## Prior work" "$OUT_FILE" "prior-work section must appear when changed paths and a remote exist"
  assert_grep "https://github.com/acme/widgets/commit/" "$OUT_FILE" "prior-work entries must be full commit URLs"
  assert_grep "flipper: flip both ways" "$OUT_FILE" "prior-work must surface the relevant earlier commit subject"
  assert_no_grep ' See also #42' "$OUT_FILE" "bare short-ref prose must not survive into the description"
  pass "fm-pr-description.sh: full fixture renders summary, criteria, tickets, and prior work"
}

test_mattermost_and_report_sections() {
  local home id out
  home="$TMP_ROOT/mm-home"
  id=mm-task
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
You are a crewmate.

# Task
Fix flipper crash, see https://mm.example.com/acme/pl/abcdef123 for the thread.

# Rules
1. Never push.
EOF
  local id out
  OUT_FILE="$TMP_ROOT/mm-task.stdout"
  out=$(cd "$NONREPO_DIR" && FM_HOME="$home" "$ROOT/bin/fm-pr-description.sh" "$id" --stdout) || fail "mm fixture must generate"
  printf '%s\n' "$out" > "$OUT_FILE"
  assert_grep "## Related discussion" "$OUT_FILE" "Mattermost permalink must open a Related discussion section"
  assert_grep "https://mm.example.com/acme/pl/abcdef123" "$OUT_FILE" "Mattermost permalink must be preserved"
  assert_no_grep "Related tickets" "$OUT_FILE" "no tickets -> Related tickets must be omitted"
  assert_no_grep "Prior work" "$OUT_FILE" "no project -> Prior work must be omitted"
  pass "fm-pr-description.sh: Mattermost permalink section renders, empty sections omitted"
}

test_report_md_included() {
  local home id out
  home="$TMP_ROOT/report-home"
  id=report-task
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
You are a crewmate.

# Task
Implement the findings from data/report-task/report.md.

# Rules
1. Never push.
EOF
  echo "# Findings" > "$home/data/$id/report.md"
  local id out
  OUT_FILE="$TMP_ROOT/report-task.stdout"
  out=$(cd "$NONREPO_DIR" && FM_HOME="$home" "$ROOT/bin/fm-pr-description.sh" "$id" --stdout) || fail "report fixture must generate"
  printf '%s\n' "$out" > "$OUT_FILE"
  assert_grep "## Related reports" "$OUT_FILE" "own report.md must open a Related reports section"
  assert_grep "data/report-task/report.md" "$OUT_FILE" "own report path must be listed"
  pass "fm-pr-description.sh: task report path rides into Related reports"
}

test_default_write_sets_pr_description_file() {
  local home id dest out
  home="$TMP_ROOT/write-home"
  id=write-task
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
You are a crewmate.

# Task
Do the thing.

# Rules
1. Never push.
EOF
  out=$(cd "$NONREPO_DIR" && FM_HOME="$home" "$ROOT/bin/fm-pr-description.sh" "$id") || fail "default write mode must succeed"
  dest="$home/data/$id/pr-description.md"
  assert_present "$dest" "default mode must write data/<id>/pr-description.md"
  assert_contains "$out" "$dest" "default mode must print the destination path"
  assert_grep "## Summary" "$dest" "written file must contain the skeleton"
  pass "fm-pr-description.sh: default mode writes and names the pr-description file"
}

# The generated skeleton must be completion-forcing: fill-in sections and a
# verification checklist, never a ready-to-open stub.
test_skeleton_forces_substantive_completion() {
  local home id out
  home="$TMP_ROOT/floor-home"
  id=floor-task
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
You are a crewmate.

# Task
Do the thing.

# Rules
1. Never push.
EOF
  local id out
  OUT_FILE="$TMP_ROOT/floor-task.stdout"
  out=$(cd "$NONREPO_DIR" && FM_HOME="$home" "$ROOT/bin/fm-pr-description.sh" "$id" --stdout) || fail "floor fixture must generate"
  printf '%s\n' "$out" > "$OUT_FILE"
  assert_grep "Fill in: what changed and why" "$OUT_FILE" "Approach must demand substantive content"
  assert_grep "Fill in: alternatives considered" "$OUT_FILE" "Tradeoffs must demand substantive content"
  assert_grep "Fill in: verification commands and their results" "$OUT_FILE" "Test evidence must demand substantive content"
  assert_grep "## Verification checklist" "$OUT_FILE" "skeleton must carry a verification checklist"
  assert_grep "Every section above is filled in substantively" "$OUT_FILE" "checklist must bind completion of every section"
  assert_grep "The description was re-read once before opening the PR" "$OUT_FILE" "checklist must require a re-read"
  assert_grep "never bare numbers" "$OUT_FILE" "header must state the full-URL rule"
  pass "fm-pr-description.sh: skeleton demands substantive completion"
}

test_full_fixture_write() {
  local home id dest
  home="$TMP_ROOT/full-write-home"
  id=full-write
  write_full_fixture "$home" "$id" "$TMP_ROOT/full-write-project" acme/widgets
  (cd "$NONREPO_DIR" && FM_HOME="$home" "$ROOT/bin/fm-pr-description.sh" "$id" >/dev/null) || fail "full fixture write must succeed"
  dest="$home/data/$id/pr-description.md"
  assert_present "$dest" "full fixture must write its pr-description.md"
  assert_grep "## Related tickets" "$dest" "written full fixture must carry tickets"
  pass "fm-pr-description.sh: full fixture writes a complete pr-description file"
}

test_remote_less_repo_omits_url_sections() {
  local home id out
  home="$TMP_ROOT/noremote-home"
  id=noremote-task
  mkdir -p "$home/data/$id" "$home/state" "$TMP_ROOT/noremote-project"
  cat > "$home/data/$id/brief.md" <<'EOF'
You are a crewmate.

# Task
Fix issue #7 locally.

# Rules
1. Never push.
EOF
  git -C "$TMP_ROOT/noremote-project" init -q -b main
  echo a > "$TMP_ROOT/noremote-project/a.txt"
  git -C "$TMP_ROOT/noremote-project" add .
  git -C "$TMP_ROOT/noremote-project" -c user.email=t@e.com -c user.name=T -c commit.gpgsign=false commit -qm base
  cat > "$home/state/$id.meta" <<EOF
project=$TMP_ROOT/noremote-project
kind=ship
EOF
  local id out
  OUT_FILE="$TMP_ROOT/noremote-task.stdout"
  out=$(cd "$NONREPO_DIR" && FM_HOME="$home" "$ROOT/bin/fm-pr-description.sh" "$id" --stdout) || fail "remote-less fixture must generate"
  printf '%s\n' "$out" > "$OUT_FILE"
  assert_grep "resolve-before-opening" "$OUT_FILE" "no remote -> #NNN must carry a resolve-before-opening placeholder"
  assert_no_grep 'issue #7' "$OUT_FILE" "bare-number prose must not survive without a link"
  assert_no_grep "Related tickets" "$OUT_FILE" "no remote -> Related tickets must be omitted"
  assert_no_grep "Prior work" "$OUT_FILE" "no remote -> Prior work must be omitted"
  pass "fm-pr-description.sh: remote-less repo omits URL sections"
}

# The repo resolution contract: a caller inside a worktree of the task's own
# repo (the real spawned-worker layout) resolves git reads against that
# checkout; a caller inside an unrelated git repo must not shadow the task's
# recorded project clone.
test_repo_resolution_prefers_task_worktree_rejects_foreign_repo() {
  local home id out
  home="$TMP_ROOT/resolution-home"
  id=resolution-task
  write_full_fixture "$home" "$id" "$TMP_ROOT/resolution-project" acme/widgets
  mkdir -p "$TMP_ROOT/foreign-repo"
  git -C "$TMP_ROOT/foreign-repo" init -q -b main
  git -C "$TMP_ROOT/foreign-repo" remote add origin "git@github.com:elsewhere/other.git"
  echo x > "$TMP_ROOT/foreign-repo/x.txt"
  git -C "$TMP_ROOT/foreign-repo" add .
  git -C "$TMP_ROOT/foreign-repo" -c user.email=t@e.com -c user.name=T -c commit.gpgsign=false commit -qm base
  # The fixture project sits on fm/<id> after write_full_fixture, so return it
  # to main first: a branch can only be checked out once, exactly as in the
  # real pooled layout where the primary checkout stays on the default branch.
  git -C "$TMP_ROOT/resolution-project" checkout -q main
  git -C "$TMP_ROOT/resolution-project" worktree add -q "$TMP_ROOT/resolution-wt" "fm/$id"

  OUT_FILE="$TMP_ROOT/resolution-worktree.stdout"
  out=$(cd "$TMP_ROOT/resolution-wt" && FM_HOME="$home" "$ROOT/bin/fm-pr-description.sh" "$id" --stdout) || fail "worktree-cwd run must generate"
  printf '%s\n' "$out" > "$OUT_FILE"
  assert_grep "https://github.com/acme/widgets/issues/42" "$OUT_FILE" "worktree cwd must resolve tickets against the task repo"
  assert_grep "## Prior work" "$OUT_FILE" "worktree cwd must feed prior-work discovery"

  OUT_FILE="$TMP_ROOT/resolution-foreign.stdout"
  out=$(cd "$TMP_ROOT/foreign-repo" && FM_HOME="$home" "$ROOT/bin/fm-pr-description.sh" "$id" --stdout) || fail "foreign-cwd run must generate"
  printf '%s\n' "$out" > "$OUT_FILE"
  assert_grep "https://github.com/acme/widgets/issues/42" "$OUT_FILE" "foreign cwd must not shadow the task's recorded project"
  assert_no_grep "elsewhere/other" "$OUT_FILE" "foreign cwd remote must never leak into the skeleton"
  pass "fm-pr-description.sh: repo resolution prefers the task worktree and rejects foreign repos"
}

# The generator's own previous output must not feed the enrichment scan: a
# stale pr-description.md from an earlier run (full of prior-work subjects and
# ticket links) would otherwise re-seed itself on every regeneration.
test_own_output_excluded_from_enrichment_scan() {
  local home id out
  home="$TMP_ROOT/self-feed-home"
  id=self-feed-task
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
You are a crewmate.

# Task
Do the thing.

# Rules
1. Never push.
EOF
  printf '## Prior work\n- [abc1234 old run subject (#999)](https://github.com/acme/widgets/commit/xyz)\n## Related discussion\n- https://mm.example.com/acme/pl/oldrun\n' > "$home/data/$id/pr-description.md"
  OUT_FILE="$TMP_ROOT/self-feed-task.stdout"
  out=$(cd "$NONREPO_DIR" && FM_HOME="$home" "$ROOT/bin/fm-pr-description.sh" "$id" --stdout) || fail "self-feed fixture must generate"
  printf '%s\n' "$out" > "$OUT_FILE"
  assert_no_grep '#999' "$OUT_FILE" "previous output refs must not re-seed the skeleton"
  assert_no_grep 'Related discussion' "$OUT_FILE" "previous output links must not re-seed the skeleton"
  assert_no_grep 'acme/widgets' "$OUT_FILE" "previous output repo must not re-seed the skeleton"
  pass "fm-pr-description.sh: own previous output is excluded from the enrichment scan"
}

# --- run -----------------------------------------------------------------
test_script_parses
test_help_includes_entire_header
test_usage_validation
test_task_placeholder_refusal
test_full_skeleton_sections
test_mattermost_and_report_sections
test_report_md_included
test_default_write_sets_pr_description_file
test_skeleton_forces_substantive_completion
test_full_fixture_write
test_remote_less_repo_omits_url_sections
test_repo_resolution_prefers_task_worktree_rejects_foreign_repo
test_own_output_excluded_from_enrichment_scan
