#!/usr/bin/env bash
# Firstmate batched document+lint recovery pass: status, brief, and marker helpers.
#
# WHY THIS EXISTS: small / doc-irrelevant lanes run
# `no-mistakes axi run --skip document,lint` (data/learnings.md anchor
# no-mistakes-cost-model), so document/lint drift accumulates silently on a
# repo's dev. This pass is the cheap recovery half: run document+lint ONCE over
# the accumulated merged changes when a batch is big enough. It reuses the
# merge-queue's shape (durable record + hourly surfacing + on-demand worker, no
# standing worker), never a standing worker or a new cadence loop. See
# data/batch-doclint-pass/report.md for the design of record and
# bin/fm-doclint-batch-lib.sh for the format, arithmetic, and marker-ref owner.
#
# Usage:
#   fm-doclint-batch.sh status [<repo>]   read the marker ref + data/completions.tsv
#                                         and print, per repo,
#                                         "<repo>: <N> lanes since <sha> (<days>d),
#                                          threshold met=yes/no". Cheap, read-only.
#                                         No repo = every registered repo with a
#                                         clone. Called by the hourly review pass.
#   fm-doclint-batch.sh ready             print only the repos whose threshold is
#                                         met, one status line each (nothing when
#                                         none). Used by fm-session-review.sh.
#   fm-doclint-batch.sh brief <repo>      emit a scoped ship brief for the on-demand
#                                         pass lane: cut fm/doclint-<repo>-<date>
#                                         off origin/dev, run no-mistakes document+lint
#                                         only (the inverse of the per-lane skip) with
#                                         the delivery steps skipped, then deliver any
#                                         fixes the pass produced through the
#                                         no-mistakes-repo PR path as a second
#                                         push-legal run (review + pipeline-owned
#                                         push + PR) that ends at a PR for captain
#                                         merge, then advance the marker ref.
#                                         Prints to stdout.
#   fm-doclint-batch.sh marker-read <repo>          print the marker sha (or nothing)
#   fm-doclint-batch.sh marker-advance <repo> <sha> fast-forward-only advance; never
#                                                   forces, never deletes (rule C1)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
# shellcheck source=bin/fm-doclint-batch-lib.sh
. "$SCRIPT_DIR/fm-doclint-batch-lib.sh"
# shellcheck source=bin/fm-brief-scaffold-lib.sh
. "$SCRIPT_DIR/fm-brief-scaffold-lib.sh"

usage() {
  sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

completions_file() {
  printf '%s/completions.tsv\n' "$DATA"
}

project_dir() {  # <repo>
  printf '%s/%s\n' "$PROJECTS" "$1"
}

# The repos that have a local clone AND are registered as a product/ship repo in
# data/projects.md. The pass targets the repo's authoritative dev, so a repo with
# no clone here has nothing to scan. Prints one name per line.
registered_repos() {
  local reg="$DATA/projects.md" name
  [ -d "$PROJECTS" ] || return 0
  for name in "$PROJECTS"/*; do
    [ -d "$name" ] || continue
    name=$(basename "$name")
    if [ -f "$reg" ]; then
      grep -qE "^-[[:space:]]+$name([[:space:]]|\[)" "$reg" || continue
    fi
    printf '%s\n' "$name"
  done
}

status_one() {  # <repo>
  local repo=$1 proj
  proj=$(project_dir "$repo")
  if [ ! -d "$proj" ]; then
    echo "$repo: no local clone under $PROJECTS" >&2
    return 1
  fi
  fm_doclint_status "$proj" "$(completions_file)" "$repo"
}

cmd=${1:-status}
[ "$#" -gt 0 ] && shift || true

case "$cmd" in
  status)
    if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
      status_one "$1"
    else
      registered_repos | while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        status_one "$repo" || true
      done
    fi
    ;;
  ready)
    # One line per threshold-met repo; nothing when none. The hourly review pass
    # turns a non-empty result into a single actionable surfacing line.
    registered_repos | while IFS= read -r repo; do
      [ -n "$repo" ] || continue
      line=$(status_one "$repo" 2>/dev/null) || continue
      case "$line" in
        *"threshold met=yes"*) printf '%s\n' "$line" ;;
      esac
    done
    ;;
  brief)
    repo=${1:-}
    [ -n "$repo" ] || { echo "error: brief needs a repo" >&2; exit 2; }
    fm_doclint_repo_safe "$repo" || { echo "error: unsafe repo '$repo'" >&2; exit 2; }
    date_tag=$(date -u +%Y%m%d)
    branch="fm/doclint-$repo-$date_tag"
    proj=$(project_dir "$repo")
    marker=""
    [ -d "$proj" ] && marker=$(fm_doclint_marker_read "$proj" "$repo" 2>/dev/null || true)
    intent="batched document+lint recovery pass over merged changes since ${marker:-repo start} on $repo"
    cat <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
Run the batched document+lint recovery pass on $repo. Small / doc-irrelevant lanes landed on $repo's dev with the document and lint steps skipped per-lane, so doc/lint drift has accumulated. Run document+lint ONCE over the accumulated merged code. Deliver any fixes the pass produces as a PR for captain merge. Never hand-push, never merge.

Steps:
1. Verify worktree isolation (Setup below). Then cut your branch:
   \`git fetch origin && git checkout -b $branch origin/dev\`
2. Run the PASS - document and lint only, no delivery steps:
   \`no-mistakes axi run --skip rebase,review,test,push,pr,ci --intent "$intent"\`
   This is the exact inverse of the per-lane skip: document and lint inspect the merged code and fix in place; review and test already ran on each landed branch, so re-running them is pure waste. push/pr/ci are skipped here on purpose: a no-mistakes repo refuses to push a run that skipped review (no durably recorded review-approved head), so this pass commits fixes locally and pushes nothing. Do NOT hand-push this pass's output - that would bypass the no-mistakes review-approved push boundary. Drive the run to completion by id (no-mistakes axi respond as directed by the gate help). NEVER pass --yes.
3. If document or lint raise an ask-user finding, append \`needs-decision:\` and stop - firstmate decides.
4. Find out whether the pass produced fixes:
   \`git fetch origin && git rev-list --count origin/dev..HEAD\`
   A count of 0 means the pass was clean.
5. CLEAN PASS (count 0): no fixes, so no PR is needed. This is a valid, successful outcome. Advance the marker (step 7) and report \`done: doclint pass clean, no fixes\`.
6. PASS WITH FIXES (count > 0): deliver the fixes through the no-mistakes PR path in one separate run on the SAME branch. This second run runs review for real - the no-mistakes repo's push gate requires a durably recorded review-approved head, which is what makes a pipeline-owned push legal - then pushes the branch and opens the PR:
   \`no-mistakes axi run --skip document,lint,test --intent "deliver the batched document+lint fixes on $repo as a PR for captain merge"\`
   document and lint already ran in step 2 and test already ran per-lane. Drive the run by id through the gate flow to its CI-ready/completed outcome. NEVER pass --yes. Never merge the PR, never delete the branch, never hand-push anything - the push must stay pipeline-owned from this review-approved run.
   - If the pipeline opened the PR, report \`done: doclint pass PR <url>\` (full URL).
   - If the pipeline's PR step skipped for lack of forge credentials, report \`done: doclint pass branch $branch pushed <head> - firstmate opens PR\`; firstmate verifies the pushed branch and opens the PR itself.
7. AFTER the pass is complete (clean or delivered), advance the provenance marker to the dev sha the pass covered:
   \`git fetch origin\`
   \`covered=\$(git rev-parse origin/dev)\`
   \`$FM_ROOT/bin/fm-doclint-batch.sh marker-advance $repo "\$covered"\`
   The advance is fast-forward-only and never forces; if it refuses, report the refusal, do not force it.

Report the outcome: \`done: doclint pass PR <url>\`, \`done: doclint pass branch $branch pushed <head> - firstmate opens PR\`, or \`done: doclint pass clean, no fixes\`.

NOTE: this touches PROJECT code via the normal delivery path, not firstmate shared material - do not edit firstmate's own bin/ or docs here.

# Setup
You are in a disposable git worktree of $repo, at a detached HEAD on a clean default branch.

$FM_BRIEF_ISOLATION_BLOCK

The branch this pass cuts is the dated \`$branch\` off \`origin/dev\` (step 1), not \`fm/<id>\`.

# Rules
1. Never push to the default branch. Never merge a PR. The pass commits fixes locally; only the second push-legal no-mistakes run (step 6) may push, and it pushes your \`$branch\` branch for captain merge.
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub and chrome-devtools-axi for browser operations.
4. Report status by appending one line to the status file firstmate gave you. States: working, needs-decision, blocked, paused, done, failed. A mid-task \`working:\` line is nonterminal; continue until a defined \`done:\` outcome above. An auth session-limit, usage-window/quota exhaustion, or revoked/expired token is captain-fixable, so report it \`blocked:\`, never \`paused:\`.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop.
6. Never stop, restart, or update the shared \`no-mistakes\` daemon. On ANY daemon error, append \`blocked: {the daemon error}\` and stop.

$FM_BRIEF_CAPTAIN_RULES
EOF
    ;;
  marker-read)
    repo=${1:-}
    [ -n "$repo" ] || { echo "error: marker-read needs a repo" >&2; exit 2; }
    proj=$(project_dir "$repo")
    fm_doclint_marker_read "$proj" "$repo"
    ;;
  marker-advance)
    repo=${1:-}
    sha=${2:-}
    [ -n "$repo" ] && [ -n "$sha" ] || { echo "error: marker-advance needs <repo> <sha>" >&2; exit 2; }
    proj=$(project_dir "$repo")
    fm_doclint_marker_advance "$proj" "$repo" "$sha"
    echo "advanced: refs/fm/doclint-base/$repo -> $sha"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "error: unknown command '$cmd'" >&2
    usage >&2
    exit 2
    ;;
esac
