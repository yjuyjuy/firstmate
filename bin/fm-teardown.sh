#!/usr/bin/env bash
# Tear down a finished task: return the treehouse worktree, release the Orca
# worktree, or retire a secondmate home; kill the recorded runtime endpoint,
# clear volatile state, refresh/prune the project's clone for remote-backed ship
# tasks, then close or print a backlog-refresh reminder for ship and scout teardowns
# (a secondmate teardown prints none, since secondmates are not backlog items).
# When the task's branch is VERIFIABLY merged into the default branch (its PR is
# merged, or - for direct-push autoland - the branch's fresh origin tip is an ancestor
# of the fresh origin default branch), teardown auto-closes the backlog ticket with
# `tasks-axi done`, closing the drift where autoland lands work but the ticket never
# flips to done. Only a proven merge auto-closes: pushed-but-unmerged (merge queue),
# detached-HEAD/scratch-branch containment, and local-only landing all keep the plain
# print-reminder. `config/backlog-backend=manual` never auto-closes. A backlog-close
# failure only warns; it never blocks the worktree release.
# REFUSES if the worktree holds work that is NEITHER durable on a remote NOR landed,
# because cleanup hard-resets/removes the worktree and kills its processes. The
# worktree is disposable - so teardown releases it - when its branch is fully PUSHED
# to origin (every commit reachable from the branch's own origin ref, verified by a
# fresh fetch), INDEPENDENT of whether it merged: a pushed branch is durable on the
# remote and the local copy holds nothing unique. A released-but-unmerged ship branch
# is recorded in the durable merge queue (bin/fm-merge-queue.sh, docs/merge-queue.md)
# so it can never be silently forgotten; that queue is the safety guard that makes
# release-on-pushed acceptable. A branch with commits absent from its remote ref, a
# dirty worktree, and the no-remote/offline case all still refuse (fail safe), and
# --force remains the only discard path for genuinely unlanded work.
# Work is also LANDED when it is
# reachable from any remote-tracking branch (a fork counts as a remote, so
# upstream-contribution PRs pushed to a fork satisfy this in any mode), OR - for a
# normal ship task whose commits are not so reachable - when its PR is merged and
# GitHub reports a PR head that contains the current local work, or its content is
# already present in the up-to-date default branch. This recognizes the common
# squash-merge-then-delete-branch flow, where the branch's own commits live nowhere
# on a remote yet the change is fully in main.
# The PR itself is resolved from the task's recorded pr= when present, or - when
# no pr= was ever recorded (e.g. a yolo-authorized merge on a repo with no PR CI,
# where the usual "checks green" fm-pr-check.sh trigger never fires) - by looking
# up a merged PR whose head branch matches the worktree's branch, fetching its head
# via refs/pull/<n>/head when the branch itself was deleted. So a missing pr= never
# by itself causes a false refusal of landed work.
# A gh lookup error falls back to the content check; if that is also inconclusive,
# teardown refuses rather than risk discarding unlanded work.
# Uncommitted changes are never landed.
# Work is LANDED as well when HEAD's exact commit is CONTAINED in a default branch
# that outlives this worktree - proved by git merge-base --is-ancestor, never by
# content equivalence (head_contained_in_default_branch). Two forms count: the
# freshly fetched refs/remotes/origin/<default>, and the project clone's own
# refs/heads/<default> when this worktree is a LINKED worktree of that clone, so the
# ref and its commits live in an object store teardown does not remove. This is what
# releases a lane that finished on a detached HEAD or a scratch branch name after
# landing on origin, and one whose approved landing target is local - the firstmate
# repo under the captain's merge-locally rule. It narrows a false refusal rather than
# widening "landed": a standalone clone's own default branch never counts, because it
# dies with the worktree, and a commit absent from both forms still refuses.
# direct-push projects additionally require positive proof that the task branch
# exists on origin (git ls-remote origin refs/heads/<branch>), because that mode
# has no PR or merge confirmation and the no-mistakes pipeline's internal
# validation remote never counts as landed. An ls-remote failure refuses too.
# That branch-name probe is skipped only when the containment test above already
# proved the exact commit is in a surviving default branch, where a branch-name
# lookup can prove nothing more.
# local-only projects additionally accept work merged into the local default
# branch (firstmate performs that merge after configured approval) as a fallback
# for the common case where there is no remote at all.
# Scout tasks (kind=scout in meta) carve out of that check: their worktree is
# declared scratch and the report at data/<task-id>/report.md is the work
# product. Teardown proceeds only once the report exists and the shared
# unresolved-decision completion gate verifies its captain-held inventory.
# A report missing its mandatory TL;DR header block (see bin/fm-brief.sh --scout)
# only warns; the block is a supervisor-relay aid, not a landed-work check.
# Before destructive cleanup, teardown validates task check artifacts and any
# matching quarantine entries as ordinary single-link files on the state
# device. It refuses and preserves task state when that proof fails; otherwise
# it removes the task's check, trust record, PR sidecar, publication record, and
# quarantine entries with the rest of the volatile state.
# Orca tasks use the same safety checks, then close the recorded terminal and
# remove the recorded worktree through `orca worktree rm`; teardown never guesses
# an Orca target from ambient CLI state.
# A Herdr presentation journal never authorizes cleanup. Teardown still closes
# only the exact task pane from ordinary endpoint metadata and never calls
# `workspace close`. It retires the non-authoritative journal only when a
# read-only token correlation agrees with that endpoint and pane closure is
# confirmed. Otherwise the journal stays quarantined for manual inspection.
# Projected closes share the presentation-order lock, refuse to close the
# captain's active tab, and restore the exact response-derived pre-close tab
# if Herdr's last-pane cleanup focuses an unrelated neighboring workspace.
# Secondmates (kind=secondmate in meta) are retired explicitly. Normal
# teardown refuses while their home has in-flight crewmate meta files; --force
# is the approved discard path that prevalidates child removal targets, discards
# child work, kills child runtime endpoints, and removes the retired home. Removing a
# leased home releases its durable treehouse lease so the pool slot is freed,
# never left leased forever. If the treehouse return fails, teardown leaves the
# leased home and state in place instead of hiding a still-held lease.
# Usage: fm-teardown.sh <task-id> [--force]
#   --force skips ordinary-task dirty and landed-work checks, skips scout report
#   checks, and discards secondmate child work for kind=secondmate. Only use it
#   when the captain has explicitly said to discard the work.
#
# Transient / stale worktree git lock recovery (teardown-lock-race): a crew process
# killed mid-git-operation can leave a .git/worktrees/<wt>/index.lock (or, for a
# non-linked worktree, .git/index.lock) that makes `treehouse return --force` fail
# with Unable to create '...index.lock': File exists. That lock is usually transient
# (the dying process finishes or exits within seconds) and must never be force-deleted
# while a live git process might still own it - the fix is patience, not rm.
#
# On that failure signature only, teardown_treehouse_return:
#   1. Retries up to FM_TREEHOUSE_RETURN_LOCK_RETRIES times (default 3), waiting
#      FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS (default 1s; falls back to the older
#      FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS name when the new one is unset) between
#      attempts. Retries key off the error text, not whether the lock file still
#      exists after the failed attempt - a lock that self-clears mid-check still
#      deserves a retry of the return.
#   2. Other treehouse return failures still abort immediately and loudly (no retry).
#   3. If every retry still hits the lock signature and the lock remains, it is removed
#      and the return tried once more ONLY when the lock is provably stale per
#      bin/fm-lock-lib.sh's fm_lock_is_provably_stale, passing the worktree dir as the
#      companion directory and FM_STALE_WORKTREE_LOCK_AGE_SECS (default 30s) as the age
#      threshold. That shared proof owns the exact lsof-holder, mtime-age, and fail-safe
#      rules.
#   4. If retries exhaust and the lock is not provably stale, teardown fails as loudly
#      as a normal return failure and notes that the lock persisted across the retry
#      window. A missing `lsof`, or a lock that fails any stale check, is treated as
#      NOT provably stale (fail safe): the lock is left untouched.
# The same proof is used when non-force safety inspection cannot run because the lock
# is present; teardown clears only a provably stale lock, then re-runs the safety
# checks before any destructive return. Teardown output notes every wait, retry, and
# removal so the operator can see what happened.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SECONDMATE_REG="$DATA/secondmates.md"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-merge-queue-lib.sh
. "$SCRIPT_DIR/fm-merge-queue-lib.sh"
# shellcheck source=bin/fm-completions-lib.sh
. "$SCRIPT_DIR/fm-completions-lib.sh"
if [ "$#" -lt 1 ] || ! fm_task_id_path_safe "$1"; then
  echo "error: invalid teardown request" >&2
  exit 2
fi
ID=$1
FORCE=${2:-}
# Fail closed before any fleet mutation: a no-mistakes gate agent must never tear
# down a worktree (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent
FM_LOCK_LOG_PREFIX=teardown
"$FM_ROOT/bin/fm-guard.sh" || true

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
T=$(grep '^window=' "$META" | cut -d= -f2-)
PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
BACKEND=$(fm_backend_of_meta "$META")
if [ "$BACKEND" = orca ]; then
  T_ORCA=$(grep '^terminal=' "$META" | tail -1 | cut -d= -f2- || true)
  [ -n "$T_ORCA" ] && T=$T_ORCA
fi
HOME_PATH=$(grep '^home=' "$META" | cut -d= -f2- || true)
PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
# tasktmp is recorded by fm-spawn for tasks that set up a per-task temp root
# (/tmp/fm-<id>/); absent for tasks spawned before that change, so tolerate empty.
TASK_TMP=$(grep '^tasktmp=' "$META" | cut -d= -f2- || true)
ORCA_WORKTREE_ID=$(fm_meta_get "$META" orca_worktree_id)
ORCA_PATH_MATCH_VERIFIED=0

KIND=$(grep '^kind=' "$META" | cut -d= -f2- || true)
[ -n "$KIND" ] || KIND=ship
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ -n "$MODE" ] || MODE=no-mistakes

# Set by capture_ticket_merge_evidence while the worktree still exists, and read by
# backlog_refresh_reminder at the very end (after the worktree is gone) to decide
# whether to auto-close the backlog ticket. Empty means "no verified merge", so the
# reminder-only path runs. Initialized here so set -u is satisfied even when the
# capture step is skipped (scout, secondmate, local-only, or a missing worktree).
TICKET_MERGE_EVIDENCE=

# Completion-ledger landing SHA, captured now while the worktree still exists (the
# destructive cleanup below removes it). The append-only ledger records this at the
# authoritative completion point; fm-completions-lib.sh owns the field mechanics.
# Priority: the forge's recorded pr_head= (merge/head commit) when present, else the
# worktree's own HEAD for direct-push and local-only lanes whose pushed/merged head
# IS that commit. When genuinely unknown, stay empty rather than guessing.
PR_HEAD_META=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
LANDING_SHA=$PR_HEAD_META
if [ -z "$LANDING_SHA" ] && [ "$KIND" != scout ] && [ "$KIND" != secondmate ] \
   && { [ "$MODE" = direct-push ] || [ "$MODE" = local-only ]; } \
   && [ -n "$WT" ] && [ -d "$WT" ]; then
  LANDING_SHA=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null || true)
fi
# Repo name for the ledger: the project clone's basename, or 'firstmate' when the
# clone could not be resolved (e.g. a firstmate-repo task with no registry entry).
COMPLETION_REPO=firstmate
[ -z "$PROJ" ] || COMPLETION_REPO=$(basename "$PROJ")

# Separately-leased extra worktrees (e.g. a full-stack lane's paired backend
# checkout), one per meta line as "extra_worktree=<clone-abs>\t<worktree-abs>",
# recorded at lease time by bin/fm-lease-extra-worktree.sh. fm_meta_get returns
# only the LAST value of a key, so read every line directly. Each is returned to
# its own pool alongside the primary worktree, with the same safety guards.
extra_worktree_lines() {
  grep '^extra_worktree=' "$META" 2>/dev/null | cut -d= -f2- || true
}

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

meta_value() {
  local meta=$1 key=$2
  fm_meta_get "$meta" "$key"
}

require_orca_worktree_id() {
  local meta=$1 id
  id=$(meta_value "$meta" orca_worktree_id)
  if [ -z "$id" ]; then
    echo "error: missing orca_worktree_id in $meta; cannot remove Orca worktree" >&2
    return 1
  fi
  printf '%s\n' "$id"
}

require_orca_terminal() {
  local meta=$1 terminal
  terminal=$(meta_value "$meta" terminal)
  if [ -z "$terminal" ]; then
    echo "error: missing terminal in $meta; cannot close Orca terminal" >&2
    return 1
  fi
  printf '%s\n' "$terminal"
}

if [ "$BACKEND" = orca ] && [ "$KIND" != secondmate ]; then
  ORCA_WORKTREE_ID=$(require_orca_worktree_id "$META") || exit 1
  T_ORCA=$(meta_value "$META" terminal)
  [ -z "$T_ORCA" ] || T=$T_ORCA
fi

remove_grok_turnend_auth() {
  local state_dir=$1 id=$2 token hooks_dir
  token=$(cat "$state_dir/$id.grok-turnend-token" 2>/dev/null || true)
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  hooks_dir="${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d"
  rm -f "$hooks_dir/$token"
}

validate_pr_poll_cleanup() {
  local state_dir=$1 id=$2 quarantine state_device artifact has_artifact=0
  fm_task_id_path_safe "$id" || return 0
  quarantine="$state_dir/.pr-check-quarantine"
  if [ "$id" = _noncanonical ] \
    && { [ -e "$quarantine/_noncanonical.diagnostic.pending-noncanonical" ] \
      || [ -L "$quarantine/_noncanonical.diagnostic.pending-noncanonical" ] \
      || [ -e "$quarantine/_noncanonical.diagnostic.noncanonical" ] \
      || [ -L "$quarantine/_noncanonical.diagnostic.noncanonical" ]; }; then
    echo "REFUSED: legacy PR-check quarantine migration is incomplete; preserving task state." >&2
    return 1
  fi
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    has_artifact=1
  done
  if [ -e "$quarantine" ] || [ -L "$quarantine" ]; then
    has_artifact=1
  fi
  [ "$has_artifact" -eq 1 ] || return 0
  [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || return 1
  state_device=$(fm_pr_file_device "$state_dir") || return 1
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if [ ! -f "$artifact" ] || [ -L "$artifact" ] \
      || [ "$(fm_pr_file_device "$artifact")" != "$state_device" ] \
      || [ "$(fm_pr_file_link_count "$artifact")" != 1 ]; then
      echo "REFUSED: unsafe task PR-check artifact; preserving task state." >&2
      return 1
    fi
  done
  [ -e "$quarantine" ] || [ -L "$quarantine" ] || return 0
  if [ ! -d "$state_dir" ] || [ -L "$state_dir" ] \
    || [ ! -d "$quarantine" ] || [ -L "$quarantine" ]; then
    echo "REFUSED: unsafe PR-check quarantine path $quarantine; preserving task state." >&2
    return 1
  fi
  if [ "$(fm_pr_file_device "$quarantine")" != "$state_device" ] \
    || [ "$(fm_pr_file_mode "$quarantine")" != 700 ]; then
    echo "REFUSED: PR-check quarantine is not on the task state device; preserving task state." >&2
    return 1
  fi
  for artifact in "$quarantine/$id."*; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if ! fm_pr_private_file_valid "$artifact" 600 "$state_device"; then
      echo "REFUSED: unsafe task quarantine entry; preserving task state." >&2
      return 1
    fi
  done
}

remove_pr_poll_artifacts() {
  local state_dir=$1 id=$2 quarantine artifact
  validate_pr_poll_cleanup "$state_dir" "$id" || return 1
  rm -f "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.check-trust" || return 1
  if fm_task_id_path_safe "$id"; then
    quarantine="$state_dir/.pr-check-quarantine"
    if [ -d "$quarantine" ] && [ ! -L "$quarantine" ]; then
      for artifact in "$quarantine/$id."*; do
        [ -e "$artifact" ] || [ -L "$artifact" ] || continue
        rm -f -- "$artifact" || return 1
      done
      rmdir "$quarantine" 2>/dev/null || true
    fi
  fi
}

# Resolve the PR number for a worktree branch via gh-axi. Echoes the number on a
# single match and returns 0; returns non-zero on no match or any lookup failure,
# so the caller treats it as "no PR found" (fail-safe).
pr_number_from_branch() {
  local branch=$1 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$( cd "$WT" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

ensure_commit_object() {
  local target=$1 commit=$2 n
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  n=$(pr_number_from_target "$target") || return 1
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$WT" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null
}

patch_id_for_commit() {
  local commit=$1
  git -C "$WT" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

unpushed_patches_are_in_pr_head() {
  local pr_head=$1 current base pr_patch_ids commit patch_id unpushed
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  base=$(git -C "$WT" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(
    git -C "$WT" log --format=%H "$base..$pr_head" -- 2>/dev/null \
      | while IFS= read -r commit; do
          patch_id_for_commit "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  unpushed=$(git -C "$WT" log --format=%H HEAD --not --remotes -- 2>/dev/null) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(patch_id_for_commit "$commit") || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

# Is the worktree's PR merged for local work contained in that PR? Resolves the
# PR from the recorded pr= URL first, then from the branch name, and asks GitHub
# for both the PR state and head. Returns non-zero when the PR is not merged, the
# current work is not contained in the PR head, no PR is found, or any gh error
# occurs - the caller then falls back to the content check.
pr_is_merged() {
  local branch=$1 target view state head current
  if [ -n "$PR_URL" ]; then
    target=$PR_URL
  else
    target=$(pr_number_from_branch "$branch") || return 1
  fi
  [ -n "$target" ] || return 1
  view=$(cd "$WT" && gh pr view "$target" --json state,headRefOid -q '.state + "\t" + .headRefOid' 2>/dev/null) || return 1
  state=${view%%$'\t'*}
  head=${view#*$'\t'}
  [ "$state" != "$view" ] || return 1
  case "$state" in
    MERGED|merged) ;;
    *) return 1 ;;
  esac
  [ -n "$head" ] || return 1
  ensure_commit_object "$target" "$head" || return 1
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  git -C "$WT" merge-base --is-ancestor "$current" "$head" 2>/dev/null && return 0
  unpushed_patches_are_in_pr_head "$head"
}

# Is the branch's content already present in the up-to-date default branch? Fetches
# first, then 3-way merges the default branch with HEAD: when HEAD introduces nothing
# the default branch does not already contain (e.g. its change landed via squash) the
# merged tree equals the default branch's tree. This isolates branch-only changes, so
# unrelated commits the default branch gained past the merge-base do not count as
# "added". Returns non-zero when inconclusive (no default ref, or a merge conflict),
# so the caller refuses rather than guesses.
content_in_default() {
  local name ref default_tree merged_tree
  name=$(default_branch) || return 1
  if git -C "$WT" remote get-url origin >/dev/null 2>&1; then
    git -C "$WT" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    ref="refs/remotes/origin/$name"
  elif git -C "$WT" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$WT" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$WT" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ]
}

# Absolute, symlink-resolved path of one of a repository's git directories
# ("--git-dir" or "--git-common-dir"), or non-zero when it cannot be resolved.
# git reports these relative to the queried directory in some layouts.
git_dir_abs() {
  local dir=$1 what=$2 path base
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  path=$(git -C "$dir" rev-parse "$what" 2>/dev/null) || return 1
  [ -n "$path" ] || return 1
  case "$path" in
    /*) ;;
    *)
      base=$(canonical_existing_dir "$dir") || return 1
      path="$base/$path"
      ;;
  esac
  canonical_existing_dir "$path"
}

# Is this task worktree a LINKED git worktree of the project clone, so that refs and
# commits held by the clone outlive the worktree teardown removes? Non-zero for a
# standalone clone (whose refs die with it) and for the clone's own primary checkout
# (which teardown must never treat as a disposable worktree).
worktree_shares_project_repository() {
  local wt_git wt_common proj_common
  [ -n "$PROJ" ] && [ -d "$PROJ" ] || return 1
  wt_git=$(git_dir_abs "$WT" --git-dir) || return 1
  wt_common=$(git_dir_abs "$WT" --git-common-dir) || return 1
  proj_common=$(git_dir_abs "$PROJ" --git-common-dir) || return 1
  [ "$wt_git" != "$wt_common" ] || return 1
  [ "$wt_common" = "$proj_common" ]
}

# Is HEAD's exact commit already contained in the project's default branch, in a form
# that SURVIVES this teardown? Two accepted forms, both proved by exact commit
# reachability (git merge-base --is-ancestor), never by content equivalence:
#   1. the freshly fetched origin copy, refs/remotes/origin/<default>; and
#   2. the project clone's own refs/heads/<default>, accepted ONLY when this worktree
#      is a linked worktree of that clone, so the ref and the commit it reaches live
#      in an object store teardown does not remove.
# Form 1 answers the lane that landed on origin and left a detached HEAD or a scratch
# branch name behind: the name is absent from origin but the commit is origin's own
# default branch, so nothing is lost. Form 2 answers a repo whose approved landing
# target is local - firstmate's own repo under the captain's merge-locally rule -
# where the work is merged into local main and origin has not seen it yet.
# This is a containment test, not a relaxation of the remote test: form 1 is still
# tried first, form 2 only counts a ref that outlives the worktree, and a commit
# absent from both still returns non-zero so the caller refuses.
head_contained_in_default_branch() {
  local name head
  head=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  name=$(default_branch) || return 1
  if git -C "$WT" remote get-url origin >/dev/null 2>&1 \
    && git -C "$WT" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 \
    && git -C "$WT" merge-base --is-ancestor "$head" "refs/remotes/origin/$name" 2>/dev/null; then
    return 0
  fi
  worktree_shares_project_repository || return 1
  git -C "$WT" rev-parse --quiet --verify "refs/heads/$name^{commit}" >/dev/null 2>&1 || return 1
  git -C "$WT" merge-base --is-ancestor "$head" "refs/heads/$name" 2>/dev/null
}

# Has the worktree's committed work actually LANDED, though its commits are not
# reachable from any remote-tracking branch? True when a merged PR proves the
# current local work is contained in the PR head, OR the content is already in the
# default branch (fallback, which also covers the no-PR and gh-error paths). False
# only for genuinely unlanded work.
work_is_landed() {
  local branch=$1
  pr_is_merged "$branch" && return 0
  content_in_default
}

# Is every commit on the branch reachable from the branch's OWN remote-tracking ref
# on origin, verified by a FRESH fetch (not a possibly-stale local ref)? A pushed
# branch is durable on the remote, so the local worktree holds nothing unique and is
# disposable, INDEPENDENT of whether it merged. Returns non-zero - so the caller
# still refuses - when there is no origin, the branch does not exist on origin, the
# fetch fails (e.g. offline), or HEAD is not contained in the fetched head. This
# never releases on an unverifiable claim.
branch_fully_pushed_to_origin() {
  local branch=$1 head current
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$WT" fetch --quiet origin "+refs/heads/$branch:refs/remotes/origin/$branch" >/dev/null 2>&1 || return 1
  head=$(git -C "$WT" rev-parse --quiet --verify "refs/remotes/origin/$branch^{commit}" 2>/dev/null) || return 1
  [ -n "$head" ] || return 1
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  git -C "$WT" merge-base --is-ancestor "$current" "$head" 2>/dev/null
}

# Is HEAD's exact commit reachable from ANY branch on origin, verified by a FRESH
# pruning fetch of every origin head (never a possibly-stale local ref)? This is the
# broadening of branch_fully_pushed_to_origin from the RECORDED branch name to any
# origin ref: it releases a lane whose exact work is already durable on origin under a
# DIFFERENT ref than the recorded branch - a rebase that renamed and pushed the branch,
# or a commit that landed on origin under some other name. The pruning fetch keeps a
# deleted origin branch from counting through a stale local remote-tracking ref. Only
# refs under refs/remotes/origin/ count, so an internal validation remote (e.g. the
# no-mistakes pipeline remote) never satisfies this. The for-each-ref prefix is
# refs/remotes/origin with no trailing /* on purpose: /* matches only one path
# component and would miss a slashed branch name like fm/task-x1, while the bare
# prefix matches every descendant ref. Returns non-zero - so the caller still refuses
# - when there is no origin, the fetch fails (e.g. offline), or no origin ref contains
# HEAD. This never releases on an unverifiable claim.
head_on_any_origin_ref() {
  local head ref refs
  head=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$WT" fetch --quiet --prune origin "+refs/heads/*:refs/remotes/origin/*" >/dev/null 2>&1 || return 1
  refs=$(git -C "$WT" for-each-ref --format='%(refname)' refs/remotes/origin 2>/dev/null) || return 1
  [ -n "$refs" ] || return 1
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    git -C "$WT" merge-base --is-ancestor "$head" "$ref" 2>/dev/null && return 0
  done <<EOF
$refs
EOF
  return 1
}

# Record a released-but-unmerged ship branch in the durable merge queue. Called once
# from the main flow (never from the idempotent safety check) after safety passes and
# while the worktree still exists. The merge queue is the ONLY durable tracker of a
# released ship branch (teardown also drops the armed merge-poll check.sh), so a silent
# miss orphans a merge-ready PR permanently. This recorder therefore NEVER skips in
# silence on a branch it cannot PROVE already landed: every skip is either a
# reachability-proven landing or a loud stderr report, and it errs toward recording.
#
# Decision order:
#   1. Proven landed -> skip silently. Proof is COMMIT REACHABILITY only, never content
#      equivalence: a merged PR whose head contains the local work (pr_is_merged), or
#      HEAD's exact commit already reachable from a default branch that survives
#      teardown (head_contained_in_default_branch). Content equivalence
#      (content_in_default, a git merge-tree tree compare) is deliberately NOT a skip
#      proof here: its false positives - a branch whose net content already appears in
#      the default branch yet whose own PR is still open and unmerged - are exactly what
#      silently dropped PR #124/#125 from this queue.
#   2. Otherwise, when the branch is verifiably durable on origin
#      (branch_fully_pushed_to_origin, or head_on_any_origin_ref for a rename/relanded
#      push), RECORD it, even if content_in_default would call it landed: a
#      pushed-but-unmerged branch/PR still needs a merge decision.
#   3. Otherwise the branch is not confirmed on origin. If its content is already in the
#      default branch it landed by squash/rebase under no origin branch of its own, so
#      there is no pushed branch to lose - skip. Anything else is genuinely ambiguous or
#      errored (gh failure, fetch failure, inconclusive check): REPORT LOUDLY and still
#      try to record so real work is never silently lost. This ambiguous path is
#      normally reached only under --force, where safety was skipped and a real branch is
#      most easily lost.
#
# Best-effort: a recording failure warns loudly but never blocks teardown.
record_pushed_unmerged_to_merge_queue() {
  local branch head base remote url on_origin=
  branch=${TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY:-}
  [ -n "$branch" ] || branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  [ "$branch" != HEAD ] || return 0

  # Step 1: proven landed by commit reachability -> nothing to track.
  if pr_is_merged "$branch" || head_contained_in_default_branch; then
    return 0
  fi

  # Step 2: verifiably on origin and not proven merged -> must record.
  if branch_fully_pushed_to_origin "$branch" || head_on_any_origin_ref; then
    on_origin=1
  fi

  # Step 3: not confirmed on origin.
  if [ -z "$on_origin" ]; then
    if content_in_default; then
      # Landed by squash/rebase under no origin branch of its own; no pushed branch to
      # lose. This is the only non-reachability skip, and only when the branch is
      # genuinely absent from origin (nothing to track), never on its say-so for a
      # branch that is still on origin.
      return 0
    fi
    echo "teardown: WARNING $branch is not proven merged and not confirmed on origin; recording it in the merge queue so it is not silently lost" >&2
  fi

  head=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || {
    echo "teardown: WARNING could not resolve HEAD to record $branch in the merge queue; track it manually" >&2
    return 0
  }
  base=$(default_branch) || {
    echo "teardown: WARNING could not resolve the default branch to record $branch in the merge queue; track it manually" >&2
    return 0
  }
  remote=$(git -C "$WT" remote get-url origin 2>/dev/null) || {
    echo "teardown: WARNING could not resolve origin to record $branch in the merge queue; track it manually" >&2
    return 0
  }
  url=$(fm_merge_queue_compare_url "$remote" "$base" "$branch") || url="branch $branch (base $base)"
  fm_merge_queue_record "$DATA" "$ID" "$PROJ" "$branch" "$head" "$base" "$url" || {
    echo "teardown: WARNING could not record $branch in the merge queue; track it manually" >&2
    return 0
  }
}

# Capture whether THIS task's ticket is verifiably merged into the default branch,
# while the worktree still exists (the destructive cleanup below removes it). Sets
# TICKET_MERGE_EVIDENCE to a short human evidence string ONLY when a real merge is
# proven, so backlog_refresh_reminder can auto-close the ticket after cleanup. Left
# empty for every non-merge durable-release path (pushed-but-unmerged, detached HEAD
# or scratch branch contained in default, local-only landing target), so those keep
# the existing print-reminder behavior.
#
# This reuses teardown's own already-computed merge tests; it does NOT introduce a
# second independent merge check. Two accepted merge proofs, both provable and both
# meaning the recorded branch itself merged rather than merely landed by some other
# path:
#   1. pr_is_merged: GitHub reports the task's PR merged with a head that contains the
#      local work (the no-mistakes / direct-PR squash-or-merge flow).
#   2. the recorded branch's fresh origin tip is an ancestor of the fresh origin
#      default branch (the direct-push autoland flow, where the worker merged its own
#      fm/<id> branch onto the origin default). branch_fully_pushed_to_origin already
#      fetches and confirms the branch tip; this adds only the is-ancestor test that
#      distinguishes a merged branch from a pushed-but-unmerged one.
# Never sets evidence for a dirty or unlanded worktree: it runs only after the safety
# checks have already released the worktree, and each proof independently requires a
# real remote merge state.
capture_ticket_merge_evidence() {
  local branch name origin_default origin_branch
  TICKET_MERGE_EVIDENCE=
  case "$KIND" in scout|secondmate) return 0 ;; esac
  [ "$MODE" != local-only ] || return 0
  [ -n "$WT" ] && [ -d "$WT" ] || return 0

  branch=${TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY:-}
  [ -n "$branch" ] || branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)

  if [ "$branch" != HEAD ] && pr_is_merged "$branch"; then
    TICKET_MERGE_EVIDENCE="PR merged, head contains the local work"
    return 0
  fi

  # Direct-push autoland: the branch tip on origin is an ancestor of origin's default
  # branch, i.e. the branch really merged (not just pushed-but-unmerged).
  [ "$branch" != HEAD ] || return 0
  branch_fully_pushed_to_origin "$branch" || return 0
  name=$(default_branch) || return 0
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 0
  git -C "$WT" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 0
  origin_branch=$(git -C "$WT" rev-parse --quiet --verify "refs/remotes/origin/$branch^{commit}" 2>/dev/null) || return 0
  origin_default="refs/remotes/origin/$name"
  git -C "$WT" rev-parse --quiet --verify "$origin_default^{commit}" >/dev/null 2>&1 || return 0
  if git -C "$WT" merge-base --is-ancestor "$origin_branch" "$origin_default" 2>/dev/null; then
    TICKET_MERGE_EVIDENCE="$branch is an ancestor of origin/$name"
  fi
}

# Auto-close the backlog ticket for a verified merge, then re-scan. Called only from
# backlog_refresh_reminder's merged branch. Failure-tolerant by contract: a failed
# close never blocks teardown (the worktree is already released by the time this
# runs), so on any tasks-axi error it prints a loud warning and returns non-zero so
# the caller falls back to the ordinary print-reminder line. Never passes --yes and
# never touches the worktree.
auto_close_backlog_ticket() {
  local done_cmd=$1 evidence=$2 out
  # `close_sub` holds the literal subcommand so the token `done` is never parsed as a
  # loop keyword here (shellcheck SC1010).
  local close_sub='done'
  if out=$( (cd "$FM_HOME" && tasks-axi "$close_sub" "$ID" --note "auto-closed at teardown: $evidence") 2>&1); then
    printf '%s\n' "Backlog: auto-closed $ID at teardown ($evidence). Run tasks-axi ready for dependency-cleared candidates, check date gates, and dispatch only work whose blockers are gone and date is due."
    return 0
  fi
  echo "teardown: WARNING could not auto-close $ID in the backlog; close it by hand with: $done_cmd" >&2
  [ -z "$out" ] || echo "teardown: tasks-axi error: $out" >&2
  return 1
}

backlog_refresh_reminder() {
  local pr done_cmd report_path
  [ "$KIND" = secondmate ] && return 0
  if fm_tasks_axi_backend_available "$CONFIG"; then
    case "$KIND" in
      scout)
        report_path="data/$ID/report.md"
        done_cmd="tasks-axi done $ID --report $report_path"
        ;;
      *)
        if [ "$MODE" = local-only ]; then
          done_cmd="tasks-axi done $ID --note \"local main\""
        elif [ "$MODE" = direct-push ]; then
          done_cmd="tasks-axi done $ID --note \"pushed to origin\""
        else
          pr=$PR_URL
          if [ -n "$pr" ]; then
            done_cmd="tasks-axi done $ID --pr $pr"
          else
            done_cmd="tasks-axi done $ID --pr PR_URL"
          fi
        fi
        ;;
    esac
    # When this task's branch is verifiably merged into the default branch (captured
    # above, before the worktree was removed), auto-close the ticket instead of only
    # printing the reminder that firstmate then has to remember to run - the recurring
    # backlog-drift gap where autoland lands work but the ticket never flips to done.
    # A failed close falls through to the ordinary reminder line below and never
    # blocks teardown (the worktree is already released). The manual backlog backend
    # never auto-closes: fm_tasks_axi_backend_available is already false for it, so
    # this whole branch is skipped and the hand-edit reminder prints instead.
    if [ -n "$TICKET_MERGE_EVIDENCE" ] && [ "$KIND" != scout ] \
       && auto_close_backlog_ticket "$done_cmd" "$TICKET_MERGE_EVIDENCE"; then
      return 0
    fi
    printf '%s\n' "Backlog: $ID just finished. Run $done_cmd, then run tasks-axi ready for dependency-cleared candidates, check date gates, and dispatch only work whose blockers are gone and date is due."
  else
    printf '%s\n' "Backlog: $ID just finished. Update data/backlog.md - move $ID to Done, keep Done to the 10 most recent, then re-scan Queued and dispatch only work whose blockers are gone and date is due."
  fi
}

registry_home_for_line() {
  sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p'
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

removal_target_abs_path() {
  local target=$1
  if [ -d "$target" ]; then
    cd "$target" && pwd -P
  else
    cd "$(dirname "$target")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$target")"
  fi
}

worktree_registered_for_project() {
  local project=$1 target=$2 abs_target listed line listed_abs
  [ -n "$project" ] || return 1
  [ -d "$project" ] || return 1
  git -C "$project" rev-parse --git-dir >/dev/null 2>&1 || return 1
  abs_target=$(removal_target_abs_path "$target")
  listed=$(git -C "$project" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        listed_abs=$(removal_target_abs_path "${line#worktree }" 2>/dev/null || true)
        [ "$listed_abs" = "$abs_target" ] && return 0
        ;;
    esac
  done <<EOF
$listed
EOF
  return 1
}

inspectable_git_worktree() {
  local target=$1 top
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  top=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] || return 1
  [ -d "$top" ] || return 1
  git -C "$top" rev-parse --git-dir >/dev/null 2>&1
}

canonical_existing_dir() {
  local target=$1
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  ( cd "$target" && pwd -P )
}

retry_wait_secs_is_valid() {
  [[ "$1" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]
}

STALE_WORKTREE_LOCK_AGE_SECS=${FM_STALE_WORKTREE_LOCK_AGE_SECS:-30}
# Bounded patience window for transient index.lock after killing a crew process.
# New knobs are preferred; FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS remains an alias
# for the per-attempt wait so existing tests and operators keep working.
TREEHOUSE_RETURN_LOCK_RETRIES=${FM_TREEHOUSE_RETURN_LOCK_RETRIES:-3}
TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=${FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS:-${FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS:-1}}
if ! retry_wait_secs_is_valid "$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS"; then
  echo "teardown: invalid treehouse return lock retry wait '$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS'; using 1s" >&2
  TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1
fi
# Compatibility alias used by the safety-check wait path and older call sites.
STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS
TEARDOWN_TREEHOUSE_LOCK_REFUSED=2
TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED=3

# True when treehouse/git stderr shows the transient index.lock "File exists" race.
# Other return failures must not enter the retry path.
treehouse_return_is_index_lock_error() {
  local text=$1
  printf '%s\n' "$text" | grep -Eq "Unable to create ['\"].*index\\.lock['\"]: File exists"
}

# Absolute path to the git index lock for a worktree/repo dir, or empty when it
# cannot be resolved (dir missing or not a git worktree at all).
worktree_git_lock_path() {
  local dir=$1 lock abs_dir
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  lock=$(git -C "$dir" rev-parse --git-path index.lock 2>/dev/null) || return 1
  [ -n "$lock" ] || return 1
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(canonical_existing_dir "$dir") || return 1
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

# The lock-staleness proof (lsof holder check, mtime age, fail-safe defaults)
# is owned by bin/fm-lock-lib.sh's fm_lock_is_provably_stale, sourced above.
# Teardown passes the worktree dir as the companion directory and its own
# STALE_WORKTREE_LOCK_AGE_SECS threshold.

# Resolves the worktree's branch once and caches it in
# TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY, which the caller reads after the call.
worktree_safety_branch() {
  local dir=$1
  if [ -z "${TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY:-}" ]; then
    TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  fi
}

worktree_safety_blocked_by_lock() {
  local reason=$1 lock
  lock=$(worktree_git_lock_path "$WT") || lock=""
  [ -n "$lock" ] && [ -e "$lock" ] || return 1
  echo "teardown: cannot inspect worktree $WT for $reason while git lock $lock is present; checking whether the lock is stale" >&2
  return 0
}

cleanup_stale_lock_for_safety_check() {
  local dir=$1 lock
  lock=$(worktree_git_lock_path "$dir") || lock=""
  [ -n "$lock" ] && [ -e "$lock" ] || return 0

  echo "teardown: worktree safety check blocked by git lock $lock; waiting ${STALE_WORKTREE_LOCK_RETRY_WAIT_SECS}s and retrying (owning process may be exiting)" >&2
  sleep "$STALE_WORKTREE_LOCK_RETRY_WAIT_SECS"

  if [ ! -e "$lock" ]; then
    echo "teardown: worktree safety check lock cleared on its own; retrying safety checks" >&2
    return 0
  fi

  if fm_lock_is_provably_stale "$lock" "$dir" "$STALE_WORKTREE_LOCK_AGE_SECS"; then
    rm -f "$lock"
    echo "teardown: removed provably-stale git lock $lock (age >= ${STALE_WORKTREE_LOCK_AGE_SECS}s, no live holder) and retrying worktree safety checks" >&2
    return 0
  fi

  echo "teardown: worktree safety check blocked by git lock $lock that is not provably stale (may belong to a live process); leaving it in place" >&2
  return "$TEARDOWN_TREEHOUSE_LOCK_REFUSED"
}

# Return a worktree/home via `treehouse return --force`, tolerating a transient or
# stale git index.lock left by a killed crew process. See the script header.
teardown_treehouse_return() {
  local dir=$1 cd_dir=$2 label=$3 post_cleanup_check=${4:-}
  local out lock attempt=0 max_retries lock_desc

  # Capture stdout+stderr so non-lock failures stay visible and lock failures can
  # be matched by signature even when the lock file is already gone mid-check.
  if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
  fi
  [ -n "$out" ] && printf '%s\n' "$out" >&2

  if ! treehouse_return_is_index_lock_error "$out"; then
    return 1
  fi

  lock=$(worktree_git_lock_path "$dir") || lock=""
  if [ -n "$lock" ]; then
    lock_desc=$lock
  else
    lock_desc="index.lock"
  fi

  max_retries=$TREEHOUSE_RETURN_LOCK_RETRIES
  case "$max_retries" in ''|*[!0-9]*) max_retries=3 ;; esac

  while [ "$attempt" -lt "$max_retries" ]; do
    attempt=$(( attempt + 1 ))
    echo "teardown: $label return failed with transient git lock ($lock_desc); waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s and retrying ($attempt/${max_retries})" >&2
    sleep "$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS"

    if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
      [ -n "$out" ] && printf '%s\n' "$out"
      echo "teardown: $label return succeeded on retry; lock cleared on its own" >&2
      return 0
    fi
    [ -n "$out" ] && printf '%s\n' "$out" >&2

    if ! treehouse_return_is_index_lock_error "$out"; then
      echo "teardown: $label return failed with a non-lock error after retry; aborting" >&2
      return 1
    fi
  done

  # Refresh lock path after the patience window; it may have appeared, moved, or
  # cleared while we waited.
  lock=$(worktree_git_lock_path "$dir") || lock=""
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    lock_desc=$lock
    if fm_lock_is_provably_stale "$lock" "$dir" "$STALE_WORKTREE_LOCK_AGE_SECS"; then
      rm -f "$lock"
      echo "teardown: removed provably-stale git lock $lock (age >= ${STALE_WORKTREE_LOCK_AGE_SECS}s, no live holder) and retrying $label return" >&2
      if [ -n "$post_cleanup_check" ]; then
        if ! "$post_cleanup_check"; then
          echo "teardown: $label return aborted after stale-lock cleanup because safety checks failed" >&2
          return 1
        fi
      fi
      if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
        [ -n "$out" ] && printf '%s\n' "$out"
        echo "teardown: $label return succeeded after stale-lock cleanup" >&2
        return 0
      fi
      [ -n "$out" ] && printf '%s\n' "$out" >&2
      echo "teardown: $label return still failing after stale-lock cleanup" >&2
      return 1
    fi

    echo "teardown: $label return failed: git lock $lock_desc persisted across ${max_retries} retries (waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s each) and is not provably stale (may belong to a live process); leaving it in place" >&2
    return "$TEARDOWN_TREEHOUSE_LOCK_REFUSED"
  fi

  echo "teardown: $label return failed: git index.lock signature persisted across ${max_retries} retries (waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s each) even after the lock file disappeared" >&2
  return 1
}

validate_worktree_teardown_safety() {
  local dirty_raw dirty unpushed_raw unpushed DEFAULT unmerged_raw unmerged branch origin_ref
  [ -d "$WT" ] || return 0
  [ "$FORCE" != "--force" ] || return 0
  case "$KIND" in
    secondmate|scout) return 0 ;;
  esac

  if ! dirty_raw=$(git -C "$WT" status --porcelain 2>/dev/null); then
    if worktree_safety_blocked_by_lock "uncommitted changes"; then
      return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
    fi
    echo "REFUSED: cannot inspect worktree $WT for uncommitted changes." >&2
    echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
    return 1
  fi
  dirty=$(printf '%s\n' "$dirty_raw" | grep -vE '^\?\? (\.claude/|\.fm-grok-turnend$)' | head -1 || true)

  if ! unpushed_raw=$(git -C "$WT" log --oneline HEAD --not --remotes -- 2>/dev/null); then
    if worktree_safety_blocked_by_lock "commits not on a remote"; then
      return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
    fi
    echo "REFUSED: cannot inspect worktree $WT for commits not on a remote." >&2
    echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
    return 1
  fi
  unpushed=$(printf '%s\n' "$unpushed_raw" | head -5)

  if [ -n "$unpushed" ] && [ "$MODE" = local-only ]; then
    DEFAULT=$(default_branch) || { echo "REFUSED: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master." >&2; return 1; }
    if ! unmerged_raw=$(git -C "$WT" log --oneline HEAD --not "$DEFAULT" -- 2>/dev/null); then
      if worktree_safety_blocked_by_lock "commits not on $DEFAULT"; then
        return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
      fi
      echo "REFUSED: cannot inspect worktree $WT for commits not on $DEFAULT." >&2
      echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
    unmerged=$(printf '%s\n' "$unmerged_raw" | head -5)
    if [ -n "$dirty" ] || [ -n "$unmerged" ]; then
      echo "REFUSED: local-only worktree $WT has work not yet merged into $DEFAULT and not on any remote." >&2
      [ -n "$dirty" ] && echo "uncommitted changes present" >&2
      [ -n "$unmerged" ] && printf 'commits not yet on %s:\n%s\n' "$DEFAULT" "$unmerged" >&2
      echo "Merge the branch into local $DEFAULT first (bin/fm-merge-local.sh after the captain approves), or push to a fork/remote, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
  elif [ -n "$dirty" ]; then
    echo "REFUSED: worktree $WT has uncommitted changes." >&2
    echo "uncommitted changes present" >&2
    echo "Commit them (or get the captain's explicit OK to discard, then --force)." >&2
    return 1
  elif [ -n "$unpushed" ]; then
    worktree_safety_branch "$WT"
    branch=$TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY
    # Release when the work has LANDED (merged), OR the branch is fully pushed to its
    # own origin ref, OR HEAD's exact commit is reachable from ANY branch on origin
    # (a rebase renamed and pushed it, or it landed on origin under another name), OR
    # HEAD's exact commit is already contained in a default branch that outlives this
    # worktree. A pushed branch is durable on the remote, so the local copy is
    # disposable even before it merges; the merge queue (recorded from the main flow)
    # keeps the released-but-unmerged branch visible. The any-origin-ref test adds the
    # alternate-branch-name case; the containment test adds the locally-landed case,
    # where the approved landing target is the clone's own default branch. Work absent
    # from all of these still refuses.
    if ! work_is_landed "$branch" && ! branch_fully_pushed_to_origin "$branch" \
      && ! head_on_any_origin_ref && ! head_contained_in_default_branch; then
      echo "REFUSED: worktree $WT has work not on any remote and not landed." >&2
      printf 'unpushed commits:\n%s\n' "$unpushed" >&2
      echo "Push the branch, land its PR, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
  fi

  # direct-push has no PR or merge confirmation to catch a skipped push, and the
  # no-mistakes pipeline's internal validation remote never counts as landed, so
  # require positive proof that the branch reached origin.
  # The branch-name probe below is skipped when HEAD's exact commit is already proven
  # durable on origin by a means the recorded branch name cannot improve on: it is
  # reachable from ANY branch on origin (rebase renamed and pushed it, or it landed
  # under another name), or it is contained in a default branch that survives teardown
  # (a lane that finished on a detached HEAD or a scratch branch, or landed by merging
  # rather than by pushing this branch name). In every such case looking the recorded
  # branch name up on origin can prove nothing further.
  if [ "$MODE" = direct-push ] && ! head_on_any_origin_ref \
    && ! head_contained_in_default_branch; then
    local origin_sha head_sha
    worktree_safety_branch "$WT"
    branch=$TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY
    if ! origin_ref=$(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true SSH_ASKPASS=true GIT_SSH_COMMAND='ssh -oBatchMode=yes' \
      git -C "$WT" ls-remote origin "refs/heads/$branch" 2>/dev/null); then
      if worktree_safety_blocked_by_lock "the direct-push branch $branch on origin"; then
        return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
      fi
      echo "REFUSED: cannot confirm direct-push worktree $WT pushed branch $branch to origin." >&2
      echo "origin could not be queried; the validation remote never counts as landed" >&2
      echo "Restore access to origin and retry, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
    if [ -z "$origin_ref" ]; then
      echo "REFUSED: direct-push worktree $WT has validated work that was never pushed to origin." >&2
      echo "branch $branch is absent from origin; the validation remote never counts as landed" >&2
      echo "Run git push origin HEAD:$branch first, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
    origin_sha=${origin_ref%%[[:space:]]*}
    if ! head_sha=$(git -C "$WT" rev-parse HEAD 2>/dev/null); then
      if worktree_safety_blocked_by_lock "the direct-push worktree head"; then
        return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
      fi
      echo "REFUSED: cannot resolve the head commit of direct-push worktree $WT." >&2
      echo "origin holds $origin_sha for $branch but the local head is unreadable" >&2
      echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
    if [ "$origin_sha" != "$head_sha" ] \
      && ! git -C "$WT" merge-base --is-ancestor "$head_sha" "$origin_sha" 2>/dev/null; then
      echo "REFUSED: direct-push worktree $WT has commits after what origin holds for $branch." >&2
      echo "origin is at $origin_sha but the worktree head is $head_sha; the validation remote never counts as landed" >&2
      echo "Run git push origin HEAD:$branch first, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
  fi
}

# Run the full worktree teardown-safety check against ONE extra (separately-leased)
# worktree, reusing validate_worktree_teardown_safety unchanged. That function reads
# the WT and PROJ globals and caches the resolved branch in
# TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY, so this saves and restores those globals and
# clears the branch cache around the call. The extra worktree gets exactly the same
# dirty / unpushed-and-unlanded refusal as the primary; a --force teardown skips it
# the same way. Returns non-zero (loudly) when the extra worktree is unsafe.
validate_extra_worktree_safety() {
  local clone=$1 wt=$2 saved_wt saved_proj saved_branch rc
  [ "$FORCE" != "--force" ] || return 0
  [ -d "$wt" ] || return 0
  saved_wt=$WT
  saved_proj=$PROJ
  saved_branch=${TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY:-}
  WT=$wt
  PROJ=$clone
  TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY=
  if validate_worktree_teardown_safety; then
    rc=0
  else
    rc=$?
    if [ "$rc" -eq "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED" ]; then
      # Mirror the primary flow: clear only a provably-stale lock, then re-check.
      if cleanup_stale_lock_for_safety_check "$WT"; then
        if validate_worktree_teardown_safety; then rc=0; else rc=1; fi
      else
        rc=1
      fi
    fi
  fi
  WT=$saved_wt
  PROJ=$saved_proj
  TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY=$saved_branch
  return "$rc"
}

# Validate every recorded extra worktree before any destructive return, so an
# unsafe second worktree refuses teardown exactly like the primary. Returns
# non-zero on the first unsafe extra worktree.
validate_all_extra_worktrees_safety() {
  local clone wt
  [ "$FORCE" != "--force" ] || return 0
  while IFS=$'\t' read -r clone wt; do
    [ -n "$wt" ] || continue
    validate_extra_worktree_safety "$clone" "$wt" || return 1
  done <<EOF
$(extra_worktree_lines)
EOF
}

# Return every recorded extra worktree to its pool through the same guarded
# treehouse-return path as the primary, from its own clone directory. Removes the
# per-task hook files first so a reused pool slot cannot fire signals for a dead
# task, then drops the local task branch best-effort. A return failure aborts
# teardown loudly (the lease would otherwise stay silently held); a lock-refused
# return propagates its distinct code so the caller can treat it like the primary.
return_extra_worktrees() {
  local clone wt branch rc
  while IFS=$'\t' read -r clone wt; do
    [ -n "$wt" ] || continue
    [ -d "$wt" ] || continue
    if [ ! -d "$clone" ] || ! command -v treehouse >/dev/null 2>&1; then
      echo "error: cannot return extra worktree $wt; clone $clone missing or treehouse unavailable; lease may still be held" >&2
      return 1
    fi
    branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
    if [ "$branch" != HEAD ]; then
      if git -C "$wt" checkout --detach -q 2>/dev/null; then
        git -C "$wt" branch -D "$branch" >/dev/null 2>&1 || true
      fi
    fi
    rm -f "$wt/.claude/settings.local.json" "$wt/.opencode/plugins/fm-turn-end.js" "$wt/.fm-grok-turnend"
    if teardown_treehouse_return "$wt" "$clone" "extra worktree"; then
      :
    else
      rc=$?
      echo "error: treehouse return failed for extra worktree $wt; lease may still be held" >&2
      return "$rc"
    fi
  done <<EOF
$(extra_worktree_lines)
EOF
}

require_orca_worktree_path_match() {
  local worktree_id=$1 inspected=$2 resolved inspected_abs resolved_abs
  resolved=$(fm_backend_worktree_path orca "$worktree_id") || {
    echo "REFUSED: cannot resolve Orca worktree id $worktree_id to a path; preserving metadata." >&2
    return 1
  }
  inspected_abs=$(canonical_existing_dir "$inspected") || {
    echo "REFUSED: cannot canonicalize inspected worktree ${inspected:-<missing>}; preserving metadata." >&2
    return 1
  }
  resolved_abs=$(canonical_existing_dir "$resolved") || {
    echo "REFUSED: Orca worktree id $worktree_id resolved to uninspectable path ${resolved:-<missing>}; preserving metadata." >&2
    return 1
  }
  if [ "$resolved_abs" != "$inspected_abs" ]; then
    echo "REFUSED: Orca worktree id $worktree_id resolves to $resolved_abs, not inspected worktree $inspected_abs." >&2
    echo "Cannot verify dirty or unlanded work for the worktree Orca would remove; preserving metadata." >&2
    return 1
  fi
}

require_orca_worktree_path_match_if_present() {
  local worktree_id=$1 inspected=$2
  [ -n "$inspected" ] && [ -e "$inspected" ] || return 0
  require_orca_worktree_path_match "$worktree_id" "$inspected"
}

firstmate_home_has_treehouse_slot() {
  local home=$1
  worktree_registered_for_project "$FM_ROOT" "$home"
}

validate_removal_target() {
  local target=$1 label=$2 abs_target abs_home abs_root
  [ -n "$target" ] || return 0
  [ -e "$target" ] || return 0
  abs_target=$(removal_target_abs_path "$target")
  if abs_home=$(cd "$FM_HOME" 2>/dev/null && pwd -P); then
    :
  else
    abs_home=
  fi
  abs_root=$(cd "$FM_ROOT" && pwd -P)
  case "$abs_target" in
    ''|/) echo "REFUSED: unsafe $label removal target $target" >&2; return 1 ;;
  esac
  if [ -n "$abs_home" ] && [ "$abs_target" = "$abs_home" ]; then
    echo "REFUSED: unsafe $label removal target $target is the active firstmate home" >&2
    return 1
  fi
  if [ "$abs_target" = "$abs_root" ]; then
    echo "REFUSED: unsafe $label removal target $target is the firstmate repo" >&2
    return 1
  fi
  if [ -n "$abs_home" ] && path_is_ancestor_of "$abs_target" "$abs_home"; then
    echo "REFUSED: unsafe $label removal target $target is an ancestor of the active firstmate home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_target" "$abs_root"; then
    echo "REFUSED: unsafe $label removal target $target is an ancestor of the firstmate repo" >&2
    return 1
  fi
  if [ -n "$abs_home" ] && path_is_ancestor_of "$abs_home" "$abs_target"; then
    echo "REFUSED: unsafe $label removal target $target is inside the active firstmate home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_target"; then
    echo "REFUSED: unsafe $label removal target $target is inside the firstmate repo" >&2
    return 1
  fi
  printf '%s\n' "$abs_target"
}

registered_descendant_home_for_removal() {
  local reg=$1 target=$2 line id registered_home registered_abs
  [ -f "$reg" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "- "*)
        id=${line#- }
        id=${id%% *}
        registered_home=$(printf '%s\n' "$line" | registry_home_for_line)
        [ -n "$registered_home" ] || continue
        registered_abs=$(removal_target_abs_path "$registered_home" 2>/dev/null || true)
        [ -n "$registered_abs" ] || continue
        [ "$registered_abs" = "$target" ] && continue
        if path_is_ancestor_of "$target" "$registered_abs"; then
          printf '%s\t%s\n' "$id" "$registered_abs"
          return 0
        fi
        ;;
    esac
  done < "$reg"
  return 1
}

validate_firstmate_operational_dirs_for_removal() {
  local home=$1 label=$2 name dir abs_home abs_dir
  abs_home=$(removal_target_abs_path "$home")
  for name in data state config projects; do
    dir="$home/$name"
    [ -e "$dir" ] || [ -L "$dir" ] || continue
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "REFUSED: unsafe $label $name directory $dir resolves outside the secondmate home" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "REFUSED: unsafe $label $name path $dir is not a directory" >&2
      return 1
    else
      abs_dir=
    fi
    if [ -z "$abs_dir" ] || ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "REFUSED: unsafe $label $name directory $dir resolves outside the secondmate home" >&2
      return 1
    fi
  done
}

validate_child_worktree_for_removal() {
  local target=$1 project=$2 abs_target abs_home abs_root
  [ -n "$target" ] || return 0
  [ -e "$target" ] || return 0
  abs_target=$(validate_removal_target "$target" "child worktree") || return 1
  if abs_home=$(cd "$FM_HOME" 2>/dev/null && pwd -P); then
    if path_is_ancestor_of "$abs_home" "$abs_target"; then
      echo "REFUSED: unsafe child worktree removal target $target is inside the active firstmate home" >&2
      return 1
    fi
  fi
  abs_root=$(cd "$FM_ROOT" && pwd -P)
  if path_is_ancestor_of "$abs_root" "$abs_target"; then
    echo "REFUSED: unsafe child worktree removal target $target is inside the firstmate repo" >&2
    return 1
  fi
  if ! worktree_registered_for_project "$project" "$target"; then
    echo "REFUSED: unsafe child worktree removal target $target is not a git worktree for ${project:-the recorded project}" >&2
    return 1
  fi
  printf '%s\n' "$abs_target"
}

safe_rm_rf() {
  local target=$1 label=$2
  validate_removal_target "$target" "$label" >/dev/null || return 1
  rm -rf -- "$target"
}

safe_rm_rf_child_worktree() {
  local target=$1 project=$2
  validate_child_worktree_for_removal "$target" "$project" >/dev/null || return 1
  rm -rf -- "$target"
}

validate_firstmate_home_for_removal() {
  local home=$1 label=$2 expected_id=${3:-} abs_home_path marker_id conflict child_id child_home
  [ -n "$home" ] || return 0
  [ -e "$home" ] || return 0
  abs_home_path=$(validate_removal_target "$home" "$label") || return 1
  if [ ! -f "$abs_home_path/$SUB_HOME_MARKER" ]; then
    echo "REFUSED: unsafe $label removal target $home is not a seeded secondmate home" >&2
    return 1
  fi
  if [ -n "$expected_id" ]; then
    marker_id=$(cat "$abs_home_path/$SUB_HOME_MARKER" 2>/dev/null || true)
    if [ "$marker_id" != "$expected_id" ]; then
      echo "REFUSED: unsafe $label removal target $home is marked for secondmate ${marker_id:-unknown}, expected $expected_id" >&2
      return 1
    fi
  fi
  validate_firstmate_operational_dirs_for_removal "$abs_home_path" "$label" || return 1
  conflict=$(registered_descendant_home_for_removal "$SECONDMATE_REG" "$abs_home_path" || true)
  if [ -z "$conflict" ]; then
    conflict=$(registered_descendant_home_for_removal "$abs_home_path/data/secondmates.md" "$abs_home_path" || true)
  fi
  if [ -n "$conflict" ]; then
    IFS=$'\t' read -r child_id child_home <<EOF
$conflict
EOF
    echo "REFUSED: unsafe $label removal target $home contains registered secondmate home $child_home for $child_id" >&2
    return 1
  fi
  printf '%s\n' "$abs_home_path"
}

remove_firstmate_home() {
  local home=$1 label=$2 expected_id=${3:-} abs_home_path
  [ -n "$home" ] || return 0
  [ -e "$home" ] || return 0
  abs_home_path=$(validate_firstmate_home_for_removal "$home" "$label" "$expected_id") || return 1
  [ -n "$abs_home_path" ] || return 0
  if firstmate_home_has_treehouse_slot "$abs_home_path"; then
    command -v treehouse >/dev/null 2>&1 || {
      echo "error: treehouse command not found; cannot return $label $abs_home_path" >&2
      return 1
    }
    teardown_treehouse_return "$abs_home_path" "$FM_ROOT" "$label" || {
      echo "error: treehouse return failed for $label $abs_home_path; lease may still be held" >&2
      return 1
    }
    return 0
  fi
  safe_rm_rf "$abs_home_path" "$label"
}

validate_firstmate_home_children_removal() {
  local home=$1 sub_state child_meta child_id child_wt child_proj child_kind child_home child_backend child_orca_worktree_id
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    validate_pr_poll_cleanup "$sub_state" "$child_id" || return 1
    child_wt=$(meta_value "$child_meta" worktree)
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    child_backend=$(fm_backend_of_meta "$child_meta")
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      validate_firstmate_home_for_removal "$child_home" "child firstmate home" "$child_id" >/dev/null || return 1
      validate_firstmate_home_children_removal "$child_home" || return 1
    elif [ "$child_backend" = orca ]; then
      child_orca_worktree_id=$(require_orca_worktree_id "$child_meta") || return 1
      if [ -n "$child_wt" ] && [ -e "$child_wt" ]; then
        child_proj=$(meta_value "$child_meta" project)
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
        require_orca_worktree_path_match "$child_orca_worktree_id" "$child_wt" || return 1
      fi
    elif [ -n "$child_wt" ] && [ -e "$child_wt" ]; then
      child_proj=$(meta_value "$child_meta" project)
      validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
    fi
  done
}

cleanup_firstmate_home_children() {
  local home=$1 sub_state child_meta child_id child_t child_wt child_proj child_kind child_home child_backend child_orca_worktree_id child_return_rc
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    child_wt=$(meta_value "$child_meta" worktree)
    child_proj=$(meta_value "$child_meta" project)
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    child_backend=$(fm_backend_of_meta "$child_meta")
    if [ "$child_backend" = orca ]; then
      child_t=$(meta_value "$child_meta" terminal)
    else
      child_t=$(fm_backend_target_of_meta "$child_meta")
    fi
    if [ "$child_backend" = orca ] && [ "$child_kind" != secondmate ]; then
      child_orca_worktree_id=$(require_orca_worktree_id "$child_meta") || return 1
      if [ -n "$child_wt" ] && [ -e "$child_wt" ]; then
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
      fi
    fi
    if [ -n "$child_t" ]; then
      if [ "$child_backend" = zellij ]; then
        # Zellij titles are scoped by the owning home tag, so forced secondmate
        # cleanup must verify child tabs as that child home, not the parent.
        ( unset FM_ROOT_OVERRIDE; FM_HOME=$home FM_ROOT=$home fm_backend_kill "$child_backend" "$child_t" "$(meta_value "$child_meta" zellij_tab_id)" "fm-$child_id" ) 2>/dev/null || true
      else
        fm_backend_kill "$child_backend" "$child_t" "$(meta_value "$child_meta" zellij_tab_id)" "fm-$child_id" 2>/dev/null || true
      fi
    fi
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      if [ -n "$child_home" ] && [ -d "$child_home" ]; then
        cleanup_firstmate_home_children "$child_home"
        remove_firstmate_home "$child_home" "child firstmate home" "$child_id"
      fi
    elif [ "$child_backend" = orca ]; then
      if [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
        rm -f "$child_wt/.claude/settings.local.json" "$child_wt/.opencode/plugins/fm-turn-end.js" "$child_wt/.fm-grok-turnend"
      fi
      fm_backend_remove_worktree "$child_backend" "$child_orca_worktree_id" || return 1
    elif [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
      validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
      rm -f "$child_wt/.claude/settings.local.json" "$child_wt/.opencode/plugins/fm-turn-end.js" "$child_wt/.fm-grok-turnend"
      if [ -n "$child_proj" ] && [ -d "$child_proj" ] && command -v treehouse >/dev/null 2>&1; then
        if teardown_treehouse_return "$child_wt" "$child_proj" "child worktree"; then
          :
        else
          child_return_rc=$?
          if [ "$child_return_rc" -eq "$TEARDOWN_TREEHOUSE_LOCK_REFUSED" ]; then
            return "$child_return_rc"
          fi
          safe_rm_rf_child_worktree "$child_wt" "$child_proj"
        fi
      else
        safe_rm_rf_child_worktree "$child_wt" "$child_proj"
      fi
    fi
    remove_grok_turnend_auth "$sub_state" "$child_id"
    remove_pr_poll_artifacts "$sub_state" "$child_id" || return 1
    rm -f "$sub_state/$child_id.status" "$sub_state/$child_id.turn-ended" "$sub_state/$child_id.meta" "$sub_state/$child_id.telemetry" "$sub_state/$child_id.crash-tail" "$sub_state/$child_id.pi-ext.ts" "$sub_state/$child_id.grok-turnend-token"
  done
}

remove_secondmate_registry_entry() {
  local id=$1 tmp
  [ -f "$SECONDMATE_REG" ] || return 0
  tmp="$SECONDMATE_REG.tmp.$$"
  grep -vE "^- $id( |$)" "$SECONDMATE_REG" > "$tmp" || true
  mv "$tmp" "$SECONDMATE_REG"
}

validate_pr_poll_cleanup "$STATE" "$ID" || exit 1

if [ "$KIND" = secondmate ]; then
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  validate_firstmate_home_for_removal "$HOME_PATH" "secondmate home" "$ID" >/dev/null || exit 1
  if [ "$FORCE" = "--force" ]; then
    validate_firstmate_home_children_removal "$HOME_PATH" || exit 1
  fi
fi

if [ "$KIND" = secondmate ] && [ "$FORCE" != "--force" ]; then
  SUB_STATE="$HOME_PATH/state"
  if [ -d "$SUB_STATE" ]; then
    for child_meta in "$SUB_STATE"/*.meta; do
      [ -e "$child_meta" ] || continue
      echo "REFUSED: secondmate $ID still has in-flight work in $SUB_STATE." >&2
      echo "Found $(basename "$child_meta"). Let that home finish or explicitly discard with --force." >&2
      exit 1
    done
  fi
fi

if [ "$KIND" = secondmate ] && [ "$FORCE" = "--force" ]; then
  cleanup_firstmate_home_children "$HOME_PATH"
fi

# Ledger-wide backstop against the retention-loss bug: a teardown is immediately
# followed by a `tasks-axi done` whose auto-prune can bury a captain hold that was
# closed without an answer. The per-scout `verify` above never sees a sibling hold, so
# run the fail-closed `guard` across the whole backlog and archive before proceeding.
if [ "$FORCE" != "--force" ] && fm_tasks_axi_backend_available "$CONFIG"; then
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-decision-hold.sh" guard; then
    echo "REFUSED: an unanswered captain decision hold is closed in the backlog or archive." >&2
    echo "Restore it with bin/fm-decision-hold.sh guard --restore before tearing down and pruning." >&2
    exit 1
  fi
fi

if [ "$KIND" = scout ] && [ "$FORCE" != "--force" ]; then
  REPORT="$DATA/$ID/report.md"
  if [ ! -f "$REPORT" ]; then
    echo "REFUSED: scout task $ID has no report at $REPORT." >&2
    echo "The report is the work product. Have the crewmate write it, or use --force after explicit discard approval." >&2
    exit 1
  fi
  # Warn (never refuse) when the report lacks the mandatory TL;DR header block
  # (see bin/fm-brief.sh --scout). A TL;DR lets the supervisor relay the verdict
  # without reading a 200+ line report whole. Match a `TL;DR` heading in the
  # first 15 lines, case-insensitively, tolerating markdown heading markers.
  if ! head -n 15 "$REPORT" | grep -qiE '^[[:space:]]*#*[[:space:]]*TL;?DR\b'; then
    echo "WARNING: scout task $ID report at $REPORT has no TL;DR header block in its first 15 lines." >&2
    echo "The supervisor relies on that block to relay the verdict without deep-reading. Proceeding anyway." >&2
  fi
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-decision-hold.sh" verify "$ID" >/dev/null; then
    echo "REFUSED: scout task $ID has not passed the unresolved-decision completion gate." >&2
    echo "Inventory its report and any visual review through bin/fm-decision-hold.sh before teardown." >&2
    exit 1
  fi
fi

if [ "$BACKEND" = orca ] && [ "$KIND" != scout ] && [ "$KIND" != secondmate ] && [ "$FORCE" != "--force" ]; then
  if ! inspectable_git_worktree "$WT"; then
    echo "REFUSED: Orca ship task $ID has no inspectable git worktree at ${WT:-<missing>}." >&2
    echo "Cannot verify dirty or unlanded work; restore the worktree path or get explicit OK to discard, then --force." >&2
    exit 1
  fi
  require_orca_worktree_path_match "$ORCA_WORKTREE_ID" "$WT" || exit 1
  ORCA_PATH_MATCH_VERIFIED=1
fi

if [ -d "$WT" ] && [ "$FORCE" != "--force" ]; then
  if validate_worktree_teardown_safety; then
    :
  else
    safety_rc=$?
    if [ "$safety_rc" -eq "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED" ]; then
      cleanup_stale_lock_for_safety_check "$WT" || exit 1
      validate_worktree_teardown_safety || exit 1
    else
      exit 1
    fi
  fi
fi

# A separately-leased extra worktree (e.g. a full-stack lane's paired backend
# checkout) gets the SAME unlanded-work protection as the primary: refuse the whole
# teardown before destroying anything if any extra worktree holds unpushed-and-
# unlanded or uncommitted work. A --force teardown skips this the same way.
if [ "$KIND" != secondmate ] && [ "$FORCE" != "--force" ]; then
  validate_all_extra_worktrees_safety || exit 1
fi

# Before the worktree is destroyed, record a pushed-but-unmerged ship branch in the
# durable merge queue so a released-yet-unmerged branch is never silently forgotten
# (see bin/fm-merge-queue.sh, docs/merge-queue.md). Recording is read-only and runs
# for a forced teardown too, which is exactly when a branch is most easily lost.
if [ "$KIND" != scout ] && [ "$KIND" != secondmate ] \
   && [ "$MODE" != local-only ] && [ -d "$WT" ]; then
  record_pushed_unmerged_to_merge_queue || true
fi

# Also while the worktree still exists, capture whether this task's branch is
# verifiably merged into the default branch, so the end-of-run backlog reminder can
# auto-close the ticket for a real merge (see capture_ticket_merge_evidence and
# backlog_refresh_reminder). Read-only and best-effort: a failure leaves the evidence
# empty, which simply keeps the print-reminder behavior.
if [ -d "$WT" ]; then
  capture_ticket_merge_evidence || true
fi

# Best-effort: drop the local task branch so the shared repo does not accumulate refs.
if [ "$BACKEND" = orca ] && [ "$KIND" != secondmate ]; then
  if [ "$ORCA_PATH_MATCH_VERIFIED" != 1 ]; then
    require_orca_worktree_path_match_if_present "$ORCA_WORKTREE_ID" "$WT" || exit 1
    ORCA_PATH_MATCH_VERIFIED=1
  fi
  if [ -d "$WT" ]; then
    branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
    if [ "$branch" != "HEAD" ]; then
      if git -C "$WT" checkout --detach -q 2>/dev/null; then
        git -C "$WT" branch -D "$branch" >/dev/null 2>&1 || true
      fi
    fi
    rm -f "$WT/.claude/settings.local.json" "$WT/.opencode/plugins/fm-turn-end.js" "$WT/.fm-grok-turnend"
  fi
  [ -z "$T_ORCA" ] || fm_backend_kill "$BACKEND" "$T" "$(meta_value "$META" zellij_tab_id)" "fm-$ID" 2>/dev/null || true
  fm_backend_remove_worktree "$BACKEND" "$ORCA_WORKTREE_ID"
elif [ -d "$WT" ] && [ "$KIND" != secondmate ]; then
  branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  if [ "$branch" != "HEAD" ]; then
    if git -C "$WT" checkout --detach -q 2>/dev/null; then
      git -C "$WT" branch -D "$branch" >/dev/null 2>&1 || true
    fi
  fi
  # Remove our hook file so a reused pool worktree cannot fire signals for a dead task.
  rm -f "$WT/.claude/settings.local.json" "$WT/.opencode/plugins/fm-turn-end.js" "$WT/.fm-grok-turnend"
  # Kills remaining processes in the worktree (including the agent), resets, returns
  # to pool. treehouse resolves the pool from the working directory, so run it from
  # the project. teardown_treehouse_return tolerates transient and stale git locks
  # left by a killed crew process; see the script header for retry and stale-lock proof.
  post_lock_cleanup_check=
  if [ "$FORCE" != "--force" ] && [ "$KIND" != scout ] && [ "$KIND" != secondmate ]; then
    post_lock_cleanup_check=validate_worktree_teardown_safety
  fi
  teardown_treehouse_return "$WT" "$PROJ" "worktree" "$post_lock_cleanup_check" || {
    echo "error: treehouse return failed for worktree $WT; teardown aborted" >&2
    exit 1
  }
fi

# Return every separately-leased extra worktree to its own pool alongside the
# primary, through the same guarded treehouse-return path (never a raw rm, never
# --force). Safety was already validated above, so a return failure here means the
# lease could not be released and teardown aborts loudly rather than leaving it held.
if [ "$KIND" != secondmate ]; then
  return_extra_worktrees || {
    echo "error: could not return one or more extra worktrees; teardown aborted" >&2
    exit 1
  }
fi

HERDR_PRESENTATION_JOURNAL="$STATE/$ID.herdr-presentation"
HERDR_PRESENTATION_RETIRE_CANDIDATE=0
HERDR_PRESENTATION_SESSION=
HERDR_PRESENTATION_PANE=
if [ "$BACKEND" = herdr ] \
   && { [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; }; then
  fm_backend_source herdr || true
  HERDR_PRESENTATION_SESSION=$(meta_value "$META" herdr_session)
  HERDR_PRESENTATION_WORKSPACE=$(meta_value "$META" herdr_workspace_id)
  HERDR_PRESENTATION_PANE=$(meta_value "$META" herdr_pane_id)
  if [ -n "$HERDR_PRESENTATION_SESSION" ] \
     && [ -n "$HERDR_PRESENTATION_WORKSPACE" ] \
     && [ -n "$HERDR_PRESENTATION_PANE" ] \
     && [ "$T" = "$HERDR_PRESENTATION_SESSION:$HERDR_PRESENTATION_PANE" ] \
     && fm_backend_herdr_projection_endpoint_matches_journal \
       "$HERDR_PRESENTATION_SESSION" "$HERDR_PRESENTATION_WORKSPACE" \
       "$HERDR_PRESENTATION_JOURNAL" "$ID"; then
    HERDR_PRESENTATION_RETIRE_CANDIDATE=1
  fi
fi

if [ "$HERDR_PRESENTATION_RETIRE_CANDIDATE" = 1 ]; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  HERDR_PRESENTATION_FOCUS_LOCK=
  HERDR_PRESENTATION_FOCUS_LOCK_HELD=0
  HERDR_PRESENTATION_FOCUS_LOCK_ATTEMPT=0
  if HERDR_PRESENTATION_FOCUS_LOCK=$(fm_backend_herdr_presentation_session_lock_path "$HERDR_PRESENTATION_SESSION"); then
    while [ "$HERDR_PRESENTATION_FOCUS_LOCK_ATTEMPT" -lt 50 ]; do
      if fm_lock_try_acquire "$HERDR_PRESENTATION_FOCUS_LOCK"; then
        HERDR_PRESENTATION_FOCUS_LOCK_HELD=1
        break
      fi
      sleep 0.1
      HERDR_PRESENTATION_FOCUS_LOCK_ATTEMPT=$((HERDR_PRESENTATION_FOCUS_LOCK_ATTEMPT + 1))
    done
  fi
  if [ "$HERDR_PRESENTATION_FOCUS_LOCK_HELD" = 1 ]; then
    fm_backend_herdr_projection_close_pane_focus_preserving \
      "$HERDR_PRESENTATION_SESSION" "$HERDR_PRESENTATION_PANE" 2>/dev/null || true
    HERDR_PRESENTATION_FOCUS_LOCK_HELD=0
    fm_lock_release "$HERDR_PRESENTATION_FOCUS_LOCK" || true
  else
    echo "warning: herdr presentation focus lock unavailable; refusing a concurrent focus-unsafe pane close" >&2
  fi
elif [ "$BACKEND" != orca ]; then
  fm_backend_kill "$BACKEND" "$T" "$(meta_value "$META" zellij_tab_id)" "fm-$ID" 2>/dev/null || true
fi
if [ "$HERDR_PRESENTATION_RETIRE_CANDIDATE" = 1 ]; then
  if [ "$(fm_backend_herdr_pane_agent_state "$HERDR_PRESENTATION_SESSION" "$HERDR_PRESENTATION_PANE")" = dead ]; then
    rm -f "$HERDR_PRESENTATION_JOURNAL"
  else
    echo "warning: exact herdr task-pane close could not be confirmed for $ID; retaining the presentation journal and attempting no workspace cleanup" >&2
  fi
elif [ "$BACKEND" = herdr ] \
     && { [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; }; then
  echo "warning: herdr presentation journal for $ID remains quarantined; no workspace cleanup was attempted" >&2
fi
if [ "$KIND" = secondmate ]; then
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  remove_firstmate_home "$HOME_PATH" "secondmate home" "$ID"
  remove_secondmate_registry_entry "$ID"
fi
remove_grok_turnend_auth "$STATE" "$ID"
fm_backend_clear_transition "$BACKEND" "$STATE" "$T" || true
# Remove the per-task temp root (/tmp/fm-<id>/, incl. its gotmp/) recorded by spawn.
# Read before the state-file rm below; empty (pre-fix tasks without tasktmp=) is a no-op.
[ -n "$TASK_TMP" ] && rm -rf "$TASK_TMP"
remove_pr_poll_artifacts "$STATE" "$ID" || exit 1
rm -f "$STATE/$ID.status" "$STATE/$ID.turn-ended" "$STATE/$ID.meta" "$STATE/$ID.telemetry" "$STATE/$ID.crash-tail" "$STATE/$ID.pi-ext.ts" "$STATE/$ID.grok-turnend-token"
if [ "$KIND" != scout ] && [ "$KIND" != secondmate ] && [ "$MODE" != local-only ]; then
  "$FM_ROOT/bin/fm-fleet-sync.sh" "$PROJ" || true
fi
echo "teardown $ID complete (window $T, worktree $WT)"
# Authoritative completion point: append one durable, never-pruned ledger line for
# this finished task. Captured LANDING_SHA (empty when unknown) and COMPLETION_REPO
# were resolved above while the worktree still existed. The append is idempotent, so
# a retried teardown never double-records. A failure here never fails the teardown.
fm_completions_record "$DATA" "$ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$KIND" "$COMPLETION_REPO" "$LANDING_SHA" \
  || echo "teardown: WARNING could not append $ID to the completion ledger" >&2
backlog_refresh_reminder

# A task just finished and was cleaned up, which changes what the desk shows
# (one fewer worker, possibly a new landed/ready entry), so rebuild the live desk
# in place if one exists. Best-effort and silent (no-op without a live desk,
# never re-serves, never wakes); it self-detaches. See bin/fm-desk-event.sh.
FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-desk-event.sh" teardown >/dev/null 2>&1 || true
