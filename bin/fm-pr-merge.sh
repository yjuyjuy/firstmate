#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# GitHub PR URLs are parsed by bin/fm-pr-lib.sh and the derived owner/repository
# and PR number are passed to gh-axi as separate arguments. Bitbucket Cloud PR
# URLs are also accepted: they merge by workspace/repository through the REST 2.0
# API in bin/fm-bitbucket-lib.sh (which requires curl, jq, and the
# NO_MISTAKES_BITBUCKET_* credentials). A GitLab merge request URL is still
# refused here until its merge path lands.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. For a Bitbucket
# PR those same flags translate to a Bitbucket merge strategy (squash,
# merge_commit, fast_forward) and any other extra argument is refused; for a
# GitHub PR they are forwarded to gh-axi, and extra args must not include --repo
# or -R because the repository comes only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra merge args>]
#
# Orphan mode merges a PR whose task metadata state/<id>.meta is already gone
# (the worker was torn down), for example a branch drained from the durable
# merge queue by the merge-desk secondmate. It runs the same guarded machinery -
# the URL is parsed and validated by bin/fm-pr-lib.sh, the merge method still
# defaults to --squash, --repo/-R overrides are still refused, and any conflict
# or red required check still makes the provider refuse loudly - but it takes no
# task id, requires no meta, and records merge evidence to the append-only log
# data/orphan-merges.log instead of a task's pr= line. Before any orphan merge
# the PR is verified green and mergeable through its provider (GitHub: the PR
# must be open, not a draft, conflict-free, and every status check must be
# SUCCESS, NEUTRAL, or SKIPPED; Bitbucket: the PR must be open, and the merge
# endpoint itself still refuses a conflicting PR or one blocked by merge
# checks), and an unverifiable PR is refused loudly rather than merged blind.
# The records-gone green check is final: the --admin bypass gh accepts for the
# task-based path is refused here, because no watcher or task chain stands
# behind this merge to catch a red PR another way.
# The explicit repository argument must equal the project path the URL already
# carries (owner/repository on GitHub, workspace/repository on Bitbucket, the
# full namespace on GitLab); it exists so the caller states the repository it
# believes it is merging and the merge refuses on any mismatch. A local clone
# PATH (for example projects/firstmate) is also accepted for GitHub and
# Bitbucket: it is mapped to its origin's own owner/repository before the match,
# so the operator does not have to hand-translate a clone path into the URL
# owner/repository. A clone whose origin resolves to a different repository is
# still refused.
#
# Orphan mode accepts every provider the task-based path merges: a GitHub PR
# merges through gh-axi, and a Bitbucket Cloud PR merges through the REST 2.0 API
# in bin/fm-bitbucket-lib.sh (curl, jq, and the NO_MISTAKES_BITBUCKET_*
# credentials). A GitLab merge request URL is accepted and parsed but refused
# with a provider-specific "GitLab orphan merge not yet supported" message and
# exit code 3, mirroring the task path where GitLab merge is not yet implemented;
# no orphan evidence is recorded because no merge happened.
# Usage: fm-pr-merge.sh --orphan <project-path> <pr-url> [-- <extra merge args>]
#
# Records-gone auto-detect: the same task-id invocation merges a PR whose task
# was already cleaned up. When state/<id>.meta is gone but the id has a durable
# data/merge-queue.tsv entry (the record teardown writes for every
# pushed-but-unmerged ship branch), the merge proceeds through the identical
# guarded machinery as --orphan - green/mergeable verification, the provider
# merge, and durable evidence in data/orphan-merges.log (with the task id so the
# merge traces back to its queue record) - plus the fork-target ownership guard
# run against the queue record's clone, the guard fm-pr-check.sh runs from
# meta's worktree/project. An id with no queue record fails closed with "task
# metadata is unavailable" and a pointer to --orphan: a typo or unknown id never
# merges, and a merge that can no longer prove which clone it belongs to must be
# stated explicitly. The queue entry itself is left for bin/fm-merge-queue.sh
# sweep, whose content-in-base check clears it once the merge lands.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

# Translate the caller's extra merge arguments into a single Bitbucket merge
# strategy, printed on stdout. Extra gh-axi flags do not apply to a Bitbucket
# merge, so only an explicit merge method (mapped to a Bitbucket strategy) is
# accepted and any other extra argument is refused loudly rather than silently
# ignored. The default is squash, matching the GitHub default. Used by both the
# task-based path and the orphan path so the mapping lives in one place.
bitbucket_strategy_from_args() {
  local strategy=squash
  bb_translate_method() {
    case "$1" in
      --squash|--method=squash) strategy=squash ;;
      --merge|--method=merge) strategy=merge_commit ;;
      --rebase|--method=rebase|--method=fast_forward) strategy=fast_forward ;;
      *) return 1 ;;
    esac
  }
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --method ]; then
      shift
      bb_translate_method "--method=${1:-}" || {
        echo "error: unsupported Bitbucket merge method: ${1:-}" >&2
        return 1
      }
    elif ! bb_translate_method "$1"; then
      echo "error: unsupported Bitbucket merge argument: $1" >&2
      return 1
    fi
    shift
  done
  printf '%s\n' "$strategy"
}

# Verify a GitHub PR is genuinely green and mergeable before a records-gone
# merge. Refuses loudly - never silently - when the PR is not open, is a draft,
# is conflicting or otherwise not mergeable, is blocked by required checks or
# reviews, or has any status check that is not SUCCESS, NEUTRAL, or SKIPPED
# (a check still running or queued counts as not green). A gh lookup failure is
# equally a refusal, because an unverifiable PR must never merge. gh's bundled
# jq does the field extraction, so no JSON processor is required. The fields
# mirror the ones gh pr merge itself consults, so this check can never be weaker
# than the merge-time guard; mergeStateStatus CLEAN, BEHIND, HAS_HOOKS, UNSTABLE,
# and APPROVED are the states in which a merge is allowed, everything else -
# BLOCKED, DIRTY, DRAFT, REVIEW_REQUESTED, UNKNOWN - is refused here.
recordless_verify_github_green() {
  local verdict summary
  verdict=$(gh pr view "$URL" --json state,isDraft,mergeable,mergeStateStatus,statusCheckRollup \
    -q 'if (.state == "OPEN") and (.isDraft == false) and (.mergeable == "MERGEABLE") and ((.mergeStateStatus == "CLEAN") or (.mergeStateStatus == "BEHIND") or (.mergeStateStatus == "HAS_HOOKS") or (.mergeStateStatus == "UNSTABLE") or (.mergeStateStatus == "APPROVED")) and ([.statusCheckRollup[]? | select((.conclusion // "PENDING") != "SUCCESS" and (.conclusion // "PENDING") != "NEUTRAL" and (.conclusion // "PENDING") != "SKIPPED")] | length == 0) then "GREEN" else "NOT_GREEN" end' 2>/dev/null) || {
    echo "error: could not verify PR green state: $URL" >&2
    return 1
  }
  if [ "$verdict" != GREEN ]; then
    summary=$(gh pr view "$URL" --json state,isDraft,mergeable,mergeStateStatus \
      -q '.state + " " + (.isDraft | tostring) + " " + .mergeable + " " + .mergeStateStatus' \
      2>/dev/null || echo unreadable)
    echo "error: refusing to merge PR that is not green and mergeable: $URL ($summary)" >&2
    return 1
  fi
}

# Verify a Bitbucket PR is mergeable before a records-gone merge: it must be
# OPEN. Bitbucket's REST PR object exposes no richer mergeability signal than
# the state, so the deeper guards stay where they already are: the merge
# endpoint itself refuses a conflicting PR or one blocked by merge checks, and
# that refusal is propagated loudly. A state read failure (transport, parse,
# missing credential) refuses too, never merging on an unverifiable read.
recordless_verify_bitbucket_green() {
  # shellcheck source=bin/fm-bitbucket-lib.sh
  . "$SCRIPT_DIR/fm-bitbucket-lib.sh"
  if ! fm_bitbucket_ready || ! fm_bitbucket_pr_state "$PR_WORKSPACE" "$PR_REPO" "$PR_NUMBER"; then
    echo "error: could not verify Bitbucket pull request state: $URL" >&2
    return 1
  fi
  [ "$FM_BITBUCKET_PR_STATE" = OPEN ] || {
    echo "error: refusing to merge Bitbucket pull request that is not open: $URL (state=$FM_BITBUCKET_PR_STATE)" >&2
    return 1
  }
}

# One shared records-gone merge body for --orphan and the task-id auto-detect
# fallback. Verifies the PR green/mergeable by provider, performs the merge
# through the same guarded provider paths as the task-based merge (gh-axi for
# GitHub, the REST API for Bitbucket, provider-refused for GitLab), and appends
# durable merge evidence to data/orphan-merges.log only after the merge
# confirms. The green check is the only gate this path has - there is no watcher
# and no task chain behind it - so --admin is refused here even though the
# task-based path forwards it: an operator bypassing the green check through a
# records-gone merge would be exactly the weakening this mode must never allow.
# $1 is the evidence kind (orphan-merge for --orphan, recordless-merge for
# auto-detect), $2 the task id for auto-detect (empty for --orphan), and the
# remaining arguments are the extra merge arguments.
recordless_merge() {
  local kind=$1 id=${2-} arg
  shift 2
  for arg in "$@"; do
    case "$arg" in
      --admin|--admin=*)
        echo "error: records-gone merges must not bypass the green check with --admin" >&2
        return 1
        ;;
    esac
  done
  case "$PROVIDER" in
    github) recordless_verify_github_green || return 1 ;;
    bitbucket) recordless_verify_bitbucket_green || return 1 ;;
    gitlab)
      echo "error: GitLab orphan merge not yet supported" >&2
      return 3
      ;;
    *)
      echo "error: invalid PR merge request" >&2
      return 2
      ;;
  esac
  case "$PROVIDER" in
    github)
      merge_args=()
      if ! caller_has_merge_method "$@"; then
        merge_args=(--squash)
      fi
      gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
      ;;
    bitbucket)
      BB_STRATEGY=$(bitbucket_strategy_from_args "$@") || return 1
      fm_bitbucket_merge_pr "$PR_WORKSPACE" "$PR_REPO" "$PR_NUMBER" "$BB_STRATEGY" || return 1
      ;;
  esac
  # Record merge evidence only after the provider merge confirms. The append-only
  # log is the durable evidence sink for both records-gone shapes; the
  # recordless-merge line additionally carries the task id so an auto-detected
  # merge traces back to its queue record.
  mkdir -p "$DATA" || { echo "error: could not record orphan-merge evidence" >&2; return 1; }
  if [ "$kind" = recordless-merge ]; then
    printf '%s\trecordless-merge\t%s\t%s\t%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$id" "$PR_PATH" "$URL" \
      >> "$DATA/orphan-merges.log" \
      || { echo "error: could not record orphan-merge evidence" >&2; return 1; }
  else
    printf '%s\torphan-merge\t%s\t%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PR_PATH" "$URL" \
      >> "$DATA/orphan-merges.log" \
      || { echo "error: could not record orphan-merge evidence" >&2; return 1; }
  fi
}

# Task-id auto-detect for a task whose state/<id>.meta is already gone. The
# durable data/merge-queue.tsv entry is the positive evidence that <id> is a
# real released ship task rather than a typo, and its clone path stands in for
# meta's worktree/project in the fork-target ownership guard. An id with no
# queue record fails closed with the same "task metadata is unavailable" error
# plus a pointer to --orphan, so a records-gone merge that cannot prove which
# clone it belongs to is never invoked without stating the repository.
recordless_merge_auto() {
  local id=$1 queue_project
  shift
  queue_project=
  if [ -f "$DATA/merge-queue.tsv" ]; then
    queue_project=$(awk -F '\t' -v id="$id" '$1 == id { print $2; exit }' "$DATA/merge-queue.tsv" 2>/dev/null || true)
  fi
  if [ -z "$queue_project" ]; then
    echo "error: task metadata is unavailable" >&2
    echo "hint: task $id has no durable merge-queue record; for a records-gone merge state the repository explicitly: fm-pr-merge.sh --orphan <owner/repo> <pr-url>" >&2
    return 1
  fi
  # The queue record's clone is the same fork-target guard source fm-pr-check.sh
  # reads from meta, so an auto-detected merge can never target a repo we do not
  # own. The guard is silent and permissive only when the clone has no
  # resolvable origin, exactly like the meta path.
  if [ "$PROVIDER" = github ]; then
    fm_pr_refuse_unowned_github_target "$PR_OWNER" "$PR_REPO" "$queue_project" || return 1
  elif [ "$PROVIDER" = bitbucket ]; then
    fm_pr_refuse_unowned_bitbucket_target "$PR_WORKSPACE" "$PR_REPO" "$queue_project" || return 1
  fi
  recordless_merge recordless-merge "$id" "$@"
}

# Orphan mode: merge a PR with no task meta, recording evidence to the durable
# orphan-merge log rather than a task's pr= line. Gated strictly behind the
# explicit --orphan flag; the task-based path below is unchanged.
if [ "${1:-}" = "--orphan" ]; then
  if [ "$#" -lt 3 ]; then
    echo "error: invalid PR merge request" >&2
    exit 2
  fi
  REPO_ARG=$2
  RAW_URL=$3
  # Accept every provider bin/fm-pr-lib.sh parses; the merge dispatch below routes
  # each to its own implementation. An unparseable URL is still refused generically.
  if ! fm_pr_url_parse "$RAW_URL"; then
    echo "error: invalid PR merge request" >&2
    exit 2
  fi
  # The explicit repository argument must equal the URL's own project path
  # (owner/repository, workspace/repository, or the full GitLab namespace). A
  # local clone PATH (e.g. projects/firstmate) is also accepted: it is mapped to
  # its origin's own owner/repository so the operator need not hand-translate a
  # clone path into the URL-owner slug. The safety check is unchanged - the
  # mapped project path must still equal the URL's - so a clone whose origin
  # resolves to a different repository is still refused.
  if [ "$REPO_ARG" != "$FM_PR_PATH" ]; then
    MAPPED_PATH=
    case "$FM_PR_PROVIDER" in
      github) MAPPED_PATH=$(fm_pr_github_origin_slug "$REPO_ARG" 2>/dev/null || true) ;;
      bitbucket) MAPPED_PATH=$(fm_pr_bitbucket_origin_slug "$REPO_ARG" 2>/dev/null || true) ;;
    esac
    if [ -z "$MAPPED_PATH" ] || [ "${MAPPED_PATH,,}" != "${FM_PR_PATH,,}" ]; then
      echo "error: repository argument does not match the PR URL" >&2
      exit 1
    fi
  fi
  URL=$FM_PR_URL
  PROVIDER=$FM_PR_PROVIDER
  PR_PATH=$FM_PR_PATH
  PR_OWNER=$FM_PR_OWNER
  PR_REPO=$FM_PR_REPO
  PR_WORKSPACE=$FM_PR_WORKSPACE
  PR_NUMBER=$FM_PR_NUMBER
  shift 3
  [ "${1:-}" = "--" ] && shift
  reject_repo_overrides "$@" || exit 1
  recordless_merge orphan-merge "" "$@" || exit $?
  exit 0
fi

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitHub, Bitbucket, and GitLab PR/MR URLs. This path
# merges GitHub (by owner/repository through gh-axi) and Bitbucket Cloud (by
# workspace/repository through the REST API). A GitLab merge request is still
# refused here until its merge path lands, so the watcher can follow it but this
# command will not merge it.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || { [ "$FM_PR_PROVIDER" != github ] && [ "$FM_PR_PROVIDER" != bitbucket ]; }; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
PR_PATH=$FM_PR_PATH
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_WORKSPACE=$FM_PR_WORKSPACE
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  # Records-gone auto-detect: the task was already cleaned up but its durable
  # merge-queue record survives. The failure to find either is the fail-closed
  # refusal below; a records-gone merge never happens on an unproven id.
  recordless_merge_auto "$ID" "$@" || exit $?
  exit 0
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

if [ "$PROVIDER" = bitbucket ]; then
  # Bitbucket merges through the REST API, not gh-axi, reusing the shared merge
  # implementation and strategy mapping. The default is a squash merge, matching
  # the GitHub default below.
  # shellcheck source=bin/fm-bitbucket-lib.sh
  . "$SCRIPT_DIR/fm-bitbucket-lib.sh"
  BB_STRATEGY=$(bitbucket_strategy_from_args "$@") || exit 1
  fm_bitbucket_merge_pr "$PR_WORKSPACE" "$PR_REPO" "$PR_NUMBER" "$BB_STRATEGY"
  exit $?
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
