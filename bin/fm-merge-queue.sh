#!/usr/bin/env bash
# Firstmate merge-queue CLI: surface, sweep, and prune the durable list of
# pushed-but-unmerged branches whose disposable worktree was already released by
# teardown (see bin/fm-merge-queue-lib.sh for the format and rationale).
#
# The queue is the safety guard behind release-on-pushed teardown: a released
# branch that still needs merging must be impossible to forget. Firstmate surfaces
# the batched set as one list of compare links rather than a trickle of asks, and -
# when a batch has accumulated for a repo AND merge authority exists - may spawn a
# merge worker on demand for that repo (no standing merge worker; idle workers cost
# memory, the binding limit on this host). See docs/merge-queue.md.
#
# Usage:
#   fm-merge-queue.sh list [--raw]     surface entries; grouped by repo with compare
#                                      links, or --raw for the tab-separated records
#   fm-merge-queue.sh sweep            reconcile queue-vs-live-meta drift, then
#                                      drop every entry whose branch is now merged
#                                      into its base (content-in-base check, then a
#                                      forge-confirmed check for the inconclusive case)
#   fm-merge-queue.sh remove <id>      drop one entry by task id
#   fm-merge-queue.sh count            print the number of queued branches
#   fm-merge-queue.sh dispatch [--execute] [--min-batch N] [--harness H] [--model M] [--effort E]
#                                      group the queue by clone, classify each for
#                                      auto-merge, and (with --execute) spawn ONE
#                                      merge worker per ELIGIBLE tooling repo to
#                                      verify-green and land its queued branches.
#
# Dispatch is the on-demand batch merger behind the queue. It NEVER auto-merges a
# product repo: hyfin, hyfin-server, dashposserver3, and every other Bitbucket
# dashnow repo are always skipped (captain hard rule 2026-08-23 - the captain
# reviews and merges product PRs himself). Only tooling forks we own on GitHub
# (github.com/yjuyjuy/*) are eligible, decided by the clone's live origin, an
# allowlist that fails closed on anything else. See fm-merge-queue-lib.sh's
# fm_merge_queue_repo_auto_mergeable and docs/merge-queue.md.
#
# Without --execute, dispatch is a dry PLAN: it prints, per clone, whether it is
# eligible, below the batch threshold, or skipped (with the reason), and spawns
# NOTHING. --execute spawns a worker only for each eligible clone at or above
# --min-batch (default 1). A dispatched worker lands only that repo's queued
# branches, one at a time, through the guarded fm-pr-merge.sh path (squash by
# default, red or conflicted PRs refused), never force-merging and never touching
# any other repo. Firstmate's sweep clears the entries once the merges land.
# --harness/--model/--effort are forwarded to fm-spawn.sh; when a crew-dispatch
# profile file is active, --harness is required so profile consultation is never
# silently skipped, exactly as fm-spawn.sh requires.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-merge-queue-lib.sh
. "$SCRIPT_DIR/fm-merge-queue-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

# Write a purpose-built merge-worker brief for one eligible tooling clone to
# data/<task-id>/brief.md. This is NOT a fm-brief.sh ship scaffold: a merge
# worker opens no PR and writes no code, it lands the repo's already-green queued
# branches through the guarded fm-pr-merge.sh path, one at a time, and never
# forces anything. The brief embeds this repo's queued branches so the worker
# knows exactly which branches (and only those) it may land.
# Args: task_id repo_name project_abs owner_repo_slug fm_home_abs
dispatch_write_merge_brief() {
  local task_id=$1 repo_name=$2 project=$3 slug=$4 fm_home_abs=$5
  local brief_dir="$DATA/$task_id" brief_path status_file branches template
  brief_path="$brief_dir/brief.md"
  status_file="$fm_home_abs/state/$task_id.status"
  mkdir -p "$brief_dir" || return 1
  # This repo's queued branches, in queue order, as a human list the worker acts
  # on. Field 2 is the project path; only rows for THIS clone are included, so a
  # worker can never touch another repo's branches.
  branches=$(fm_merge_queue_entries "$DATA" | awk -F'\t' -v p="$project" \
    '$2 == p { printf "- %s (base %s, queue id %s)\n", $3, $5, $1 }')
  [ -n "$branches" ] || branches="(none found - re-check the queue before acting)"
  template=$(cat <<'BRIEF_EOF'
You are a crewmate: an autonomous MERGE worker managed by firstmate. Work on your own; do not wait for a human.

# Task
Land the green, queued pull requests for the tooling repo __REPO__ (__SLUG__) - one at a time, as guarded squash merges. Merge ONLY the branches listed below and NOTHING else.

You open no PR and write no code. Your deliverable is landed merges plus a report of what merged and what you skipped.

This repo is an owned GitHub tooling fork, which is why it is eligible for auto-merge. Product repos (hyfin, hyfin-server, dashposserver3, any Bitbucket dashnow repo) are NEVER auto-merged - firstmate's dispatch already excluded them, so none can appear below.

## Branches to land (queued for __REPO__)
__BRANCHES__

# Setup
You are in a disposable git worktree of __REPO__. Verify isolation before anything else: run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to your task worktree, not the primary checkout firstmate operates from. If they do not, STOP and append `blocked: launched in primary checkout, not an isolated worktree` to the status file and stop.

Do NOT create a branch and do NOT commit. You merge server-side through the guarded firstmate tooling below; the worktree is only your workspace for running commands.

# Procedure (per branch, one at a time, in the order listed)
For each branch B above:
1. Resolve its open pull request:
   `gh-axi pr list --repo __SLUG__ --head B --state open --json url,number,state,isDraft,mergeable,mergeStateStatus,statusCheckRollup`
   If there is no open PR for B, SKIP it: it may already be merged or was never opened. Record the skip and move on.
2. Confirm it is genuinely green before merging. Merge B ONLY when ALL hold:
   - `state` is `OPEN` and `isDraft` is `false`
   - `mergeable` is `MERGEABLE` (never `CONFLICTING`)
   - every `statusCheckRollup` check is `SUCCESS`, `NEUTRAL`, or `SKIPPED` (no `FAILURE`, `ERROR`, `PENDING`, or `IN_PROGRESS`)
   If any check is still running, this is a known external wait: append `paused: waiting on CI for B` and re-check later, do not skip permanently.
   If B is red or conflicting, SKIP it and record why. Never resolve a conflict yourself and never force.
3. Merge the green PR through the guarded firstmate path (squash by default; it refuses a red or conflicting PR loudly, and refuses any repository override):
   `FM_HOME=__FMHOME__ __FMHOME__/bin/fm-pr-merge.sh --orphan __SLUG__ <pr-url>`
   Treat a non-zero exit as "not merged": record the exact error and move to the next branch. NEVER pass `--admin`, `--force`, or any repository override, and NEVER retry a refused merge by weakening it.
4. After a successful merge, confirm the PR now reads `MERGED` before moving on.

Do the branches independently: a skip or failure on one must not stop you from attempting the rest.

# Rules
1. NEVER force anything: no force-push, no `--admin`, no forced merge, no conflict resolution on someone else's code. A conflict or a red check is a SKIP-and-report, never something you push past. (Standing captain rule C1.)
2. Merge ONLY the branches listed above, ONLY through `FM_HOME=__FMHOME__ __FMHOME__/bin/fm-pr-merge.sh --orphan __SLUG__ <pr-url>`. Do not merge by hand, do not touch any other repo, and do not open a PR.
3. Do not touch the merge queue file yourself; firstmate clears merged entries with its own content-in-base sweep after you finish.
4. Report status by appending one line: `echo "{state}: {one short line}" >> __STATUS__`
   States: working, needs-decision, blocked, paused, done, failed. Report sparingly - only phase changes a supervisor would act on and the terminal states.
   Use `paused:` only for a real external wait you expect to clear on its own (a CI run still in progress). Use `blocked:` when you are stuck and need firstmate to act. A Claude/auth session-limit, usage-window or quota exhaustion, or a revoked token is captain-fixable, so report it `blocked:`, never `paused:`.
5. Write your status lines and your report in caveman ultra style: drop articles and filler, fragments fine, keep every technical fact; keep identifiers, URLs, shas, and error strings VERBATIM. (Standing captain rule C4.)

# Definition of done
When you have attempted every listed branch, append one summary line and stop:
`done: merged {n} PR(s) [{urls or shas}]; skipped {m} [{branch: reason}]`
If nothing could be merged (all skipped/red/absent), that is still a valid `done:` - name each branch and why. If you cannot operate at all, append `failed: {why}` or `blocked: {why}` and stop.
BRIEF_EOF
  )
  template=${template//__TASK_ID__/$task_id}
  template=${template//__REPO__/$repo_name}
  template=${template//__SLUG__/$slug}
  template=${template//__FMHOME__/$fm_home_abs}
  template=${template//__STATUS__/$status_file}
  template=${template//__BRANCHES__/$branches}
  printf '%s\n' "$template" > "$brief_path" || return 1
}

# Spawn one merge worker for an eligible clone: write its brief, then launch it
# through fm-spawn.sh in the project's own clone. Forwards the caller's
# harness/model/effort so dispatch obeys the same profile discipline as any
# spawn. FM_HOME is passed explicitly so the spawned worker's state and the brief
# it references resolve to THIS home.
# Args: task_id repo_name project_abs harness model effort
dispatch_spawn_merge_worker() {
  local task_id=$1 repo_name=$2 project=$3 harness=$4 model=$5 effort=$6
  local fm_home_abs slug spawn_args
  fm_home_abs=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || fm_home_abs=$FM_HOME
  # The clone is already proven eligible by the plan (github.com/<owned-owner>),
  # so the slug resolves; guard anyway so a race that changed origin fails closed.
  slug=$(fm_pr_github_origin_slug "$project") || {
    echo "dispatch: $repo_name origin no longer resolves to an owned GitHub repo; not spawning" >&2
    return 1
  }
  dispatch_write_merge_brief "$task_id" "$repo_name" "$project" "$slug" "$fm_home_abs" || {
    echo "dispatch: could not write the merge brief for $repo_name" >&2
    return 1
  }
  spawn_args=("$task_id" "$project")
  [ -z "$harness" ] || spawn_args+=(--harness "$harness")
  [ -z "$model" ] || spawn_args+=(--model "$model")
  [ -z "$effort" ] || spawn_args+=(--effort "$effort")
  FM_HOME="$fm_home_abs" "$SCRIPT_DIR/fm-spawn.sh" "${spawn_args[@]}"
}

cmd=${1:-list}
[ "$#" -gt 0 ] && shift || true

case "$cmd" in
  list)
    raw=0
    [ "${1:-}" = --raw ] && raw=1
    entries=$(fm_merge_queue_entries "$DATA")
    if [ -z "$entries" ]; then
      [ "$raw" -eq 1 ] || echo "Merge queue: empty."
      exit 0
    fi
    if [ "$raw" -eq 1 ]; then
      printf '%s\n' "$entries"
      exit 0
    fi
    echo "Merge queue: pushed branches waiting to merge."
    printf '%s\n' "$entries" | while IFS='	' read -r id project branch head base url; do
      [ -n "$id" ] || continue
      printf -- '- %s [%s -> %s] %s\n' "$id" "$branch" "$base" "$url"
    done
    ;;
  sweep)
    # Reconcile queue-vs-live-meta drift BEFORE the merged checks: an entry with
    # a stale head but a live meta carrying a newer pr_head is refreshed to that
    # head first, so the merged check below runs against the commit that landed
    # rather than a stale head that could never sweep.
    fm_merge_queue_reconcile_drift "$DATA" "$STATE" || true
    entries=$(fm_merge_queue_entries "$DATA")
    [ -n "$entries" ] || { echo "Merge queue: empty."; exit 0; }
    removed=0
    while IFS='	' read -r id project branch head base url; do
      [ -n "$id" ] || continue
      rc=0
      fm_merge_queue_branch_merged "$project" "$branch" "$head" "$base" || rc=$?
      case "$rc" in
        0) reason="$branch merged into $base" ;;
        "$FM_MERGE_QUEUE_BRANCH_GONE") reason="$branch gone from origin, merge unverified" ;;
        *)
          # Content-in-base was inconclusive (a squash/rebase merge the base
          # later touched conflicts under merge-tree). Ask the forge directly
          # whether the head landed in a merged PR; the content check stays the
          # no-PR-automation fallback, this only ADDS a clear when the forge
          # confirms it. Anything the forge cannot confirm keeps the entry.
          if fm_merge_queue_forge_confirms_merged "$project" "$head" "$base"; then
            reason="$branch merged into $base (forge-confirmed)"
          else
            continue
          fi
          ;;
      esac
      if fm_merge_queue_remove "$DATA" "$id"; then
        echo "cleared: $id ($reason)"
        removed=$((removed + 1))
      else
        echo "kept: $id ($reason, but the queue could not be updated)" >&2
      fi
    done <<EOF
$entries
EOF
    echo "Merge queue: swept, $removed cleared."
    ;;
  remove)
    id=${1:-}
    [ -n "$id" ] || { echo "error: remove needs a task id" >&2; exit 2; }
    fm_merge_queue_remove "$DATA" "$id"
    echo "removed: $id"
    ;;
  count)
    entries=$(fm_merge_queue_entries "$DATA")
    if [ -z "$entries" ]; then
      echo 0
    else
      printf '%s\n' "$entries" | grep -c . || true
    fi
    ;;
  dispatch)
    execute=0
    min_batch=1
    harness_arg=
    model_arg=
    effort_arg=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --execute) execute=1 ;;
        --min-batch)
          shift
          min_batch=${1:-}
          [ -n "$min_batch" ] || { echo "error: --min-batch needs a value" >&2; exit 2; }
          ;;
        --min-batch=*) min_batch=${1#--min-batch=} ;;
        --harness) shift; harness_arg=${1:-}; [ -n "$harness_arg" ] || { echo "error: --harness needs a value" >&2; exit 2; } ;;
        --harness=*) harness_arg=${1#--harness=} ;;
        --model) shift; model_arg=${1:-}; [ -n "$model_arg" ] || { echo "error: --model needs a value" >&2; exit 2; } ;;
        --model=*) model_arg=${1#--model=} ;;
        --effort) shift; effort_arg=${1:-}; [ -n "$effort_arg" ] || { echo "error: --effort needs a value" >&2; exit 2; } ;;
        --effort=*) effort_arg=${1#--effort=} ;;
        *) echo "error: unknown dispatch option '$1'" >&2; usage >&2; exit 2 ;;
      esac
      shift
    done
    case "$min_batch" in
      ''|*[!0-9]*) echo "error: --min-batch must be a non-negative integer (got '$min_batch')" >&2; exit 2 ;;
    esac
    # fm-spawn.sh requires an explicit harness for crewmate spawns when a
    # crew-dispatch profile file is active, so the dispatch rules are never
    # silently skipped. Enforce the same rule here before we build any worker, so
    # --execute fails fast with a clear message rather than deep inside a spawn.
    if [ "$execute" -eq 1 ] && [ -z "$harness_arg" ] && [ -f "$CONFIG/crew-dispatch.json" ]; then
      echo "error: config/crew-dispatch.json is active - pass --harness (resolved from the dispatch rules) so profile consultation is not silently skipped." >&2
      exit 1
    fi
    plan=$(fm_merge_queue_dispatch_plan "$DATA" "$min_batch")
    if [ -z "$plan" ]; then
      echo "Merge queue: empty; nothing to dispatch."
      exit 0
    fi
    # Report the whole plan first (every clone and its verdict), so the skipped
    # product repos are always visible, then act only on the eligible rows.
    echo "Merge-queue dispatch plan (min batch $min_batch):"
    dispatched=0
    failed=0
    eligible_seen=0
    while IFS='	' read -r decision project count reason; do
      [ -n "$decision" ] || continue
      case "$decision" in
        eligible)
          eligible_seen=$((eligible_seen + 1))
          printf -- '- DISPATCH %s (%s branch(es)) - %s\n' "$project" "$count" "$reason"
          ;;
        below-threshold)
          printf -- '- hold     %s (%s branch(es), below batch %s) - %s\n' "$project" "$count" "$min_batch" "$reason"
          ;;
        skip)
          printf -- '- SKIP     %s (%s branch(es)) - %s\n' "$project" "$count" "$reason"
          ;;
        *)
          printf -- '- ?        %s (%s branch(es)) - %s\n' "$project" "$count" "$reason"
          ;;
      esac
    done <<EOF
$plan
EOF
    if [ "$execute" -eq 0 ]; then
      echo "Dry run: no merge worker was spawned. Re-run with --execute to dispatch the eligible repos above."
      exit 0
    fi
    if [ "$eligible_seen" -eq 0 ]; then
      echo "Nothing eligible to dispatch."
      exit 0
    fi
    # --execute: spawn one merge worker per eligible clone. Each spawn is
    # independent; a failed spawn is reported and the rest still launch.
    while IFS='	' read -r decision project count reason; do
      [ "$decision" = eligible ] || continue
      repo_name=$(basename "$project")
      task_id="merge-batch-$repo_name-$(date -u +%Y%m%d-%H%M%S)"
      if ! dispatch_spawn_merge_worker "$task_id" "$repo_name" "$project" "$harness_arg" "$model_arg" "$effort_arg"; then
        echo "dispatch: FAILED to spawn merge worker for $repo_name" >&2
        failed=$((failed + 1))
        continue
      fi
      dispatched=$((dispatched + 1))
    done <<EOF
$plan
EOF
    echo "Merge-queue dispatch: $dispatched worker(s) spawned, $failed failed."
    [ "$failed" -eq 0 ]
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
