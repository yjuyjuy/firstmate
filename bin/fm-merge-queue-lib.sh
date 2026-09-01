#!/usr/bin/env bash
# Durable merge-queue format owner. Sourced by bin/fm-teardown.sh (record) and
# bin/fm-merge-queue.sh (list/remove/sweep). NEVER executed directly.
#
# The merge queue is the safety guard for release-on-pushed teardown: when a
# finished worker's branch is fully pushed to origin but not yet merged, teardown
# releases its disposable worktree (freeing the memory-bound slot) and records the
# branch here so it can never be silently forgotten. Firstmate surfaces the batched
# set as one list of compare links, and entries clear once the branch's content is
# confirmed in its base branch.
#
# Storage: data/merge-queue.tsv, one entry per line, tab-separated:
#   <id>\t<project-path>\t<branch>\t<head>\t<base>\t<compare-url>
# where <project-path> is the local clone firstmate runs git against, <head> is the
# branch tip commit at release time, <base> is the intended merge target branch, and
# <compare-url> is the captain-facing compare link. Comment lines start with '#'.
#
# One entry per task id; recording an id again replaces its line. All writes are
# atomic (tmp + mv). Field values may not contain a tab or newline.

FM_MERGE_QUEUE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-mutex-lib.sh
. "$FM_MERGE_QUEUE_LIB_DIR/fm-mutex-lib.sh"
# fm-pr-lib.sh supplies the origin-slug resolver the auto-merge eligibility gate
# below reads. It is a leaf lib whose only top-level side effects are resetting
# its own FM_PR_* globals to empty, so a caller that already sourced it (teardown
# does, before this lib) must not get those globals clobbered mid-flow. Source it
# only when its resolver is absent, the same discipline the mutex source uses for
# "no side effects on a caller".
if ! declare -F fm_pr_github_origin_slug >/dev/null 2>&1; then
  # shellcheck source=bin/fm-pr-lib.sh
  . "$FM_MERGE_QUEUE_LIB_DIR/fm-pr-lib.sh"
fi

# Serialize the read-modify-write in record/remove so two concurrent teardowns
# cannot lose an entry. The mutex primitives come from bin/fm-mutex-lib.sh, a leaf
# lib with NO top-level side effects, so sourcing it never repoints a caller's
# FM_ROOT, FM_HOME, or STATE. A lock that cannot be taken within the bounded wait
# fails the record or remove: atomic writes do not prevent a lost update, and a
# refused record is safer than a silently dropped entry.
fm_merge_queue_lock_path() {
  printf '%s\n' "$1/.merge-queue.lock"
}

fm_merge_queue_lock() {
  local data_dir=$1 lock attempt=0
  lock=$(fm_merge_queue_lock_path "$data_dir")
  while [ "$attempt" -lt 100 ]; do
    if fm_lock_try_acquire "$lock"; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done
  return 1
}

fm_merge_queue_unlock() {
  local data_dir=$1
  fm_lock_release "$(fm_merge_queue_lock_path "$data_dir")" 2>/dev/null || true
}

# Print every entry line whose first tab-separated field is NOT <id>. Literal
# field comparison, never a regex, so an id containing '.' cannot match another.
fm_merge_queue_drop_id() {
  local file=$1 id=$2
  awk -F'\t' -v id="$id" '$1 != id' "$file"
}

# Absolute path to the merge-queue file for a data dir.
fm_merge_queue_file() {
  local data_dir=$1
  printf '%s\n' "$data_dir/merge-queue.tsv"
}

# True when a value is a safe single-line field (no tab, no newline, non-empty).
fm_merge_queue_field_safe() {
  local v=$1
  [ -n "$v" ] || return 1
  case "$v" in
    *"	"*) return 1 ;;
  esac
  [ "$(printf '%s' "$v" | wc -l | tr -d ' ')" = 0 ] || return 1
  return 0
}

fm_merge_queue_id_safe() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Print the raw non-comment, non-blank entry lines (or nothing when absent).
fm_merge_queue_entries() {
  local data_dir=$1 file
  file=$(fm_merge_queue_file "$data_dir")
  [ -f "$file" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$file" || true
}

# Record (or replace) an entry. Args: data_dir id project branch head base url.
# Returns non-zero without writing on any unsafe field.
fm_merge_queue_record() {
  local data_dir=$1 id=$2 project=$3 branch=$4 head=$5 base=$6 url=$7 file tmp
  fm_merge_queue_id_safe "$id" || { echo "merge-queue: unsafe task id '$id'" >&2; return 1; }
  local f
  for f in "$project" "$branch" "$head" "$base" "$url"; do
    fm_merge_queue_field_safe "$f" || { echo "merge-queue: unsafe field for $id" >&2; return 1; }
  done
  mkdir -p "$data_dir" || return 1
  file=$(fm_merge_queue_file "$data_dir")
  fm_merge_queue_lock "$data_dir" || {
    echo "merge-queue: could not take the queue lock; not recording $id" >&2
    return 1
  }
  tmp="$file.tmp.$$"
  {
    if [ -f "$file" ]; then
      fm_merge_queue_drop_id "$file" "$id" || true
    else
      printf '%s\n' \
        '# firstmate merge queue: pushed-but-unmerged branches whose worktree was released.' \
        '# Format: <id>\t<project-path>\t<branch>\t<head>\t<base>\t<compare-url>' \
        '# Owned by bin/fm-merge-queue-lib.sh; surface with bin/fm-merge-queue.sh list.'
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$project" "$branch" "$head" "$base" "$url"
  } > "$tmp" || {
    rm -f "$tmp"
    fm_merge_queue_unlock "$data_dir"
    return 1
  }
  local rc=0
  mv "$tmp" "$file" || rc=$?
  [ "$rc" -eq 0 ] || rm -f "$tmp"
  fm_merge_queue_unlock "$data_dir"
  return "$rc"
}

# Remove the entry for a task id. Succeeds silently when absent.
fm_merge_queue_remove() {
  local data_dir=$1 id=$2 file tmp
  fm_merge_queue_id_safe "$id" || return 1
  file=$(fm_merge_queue_file "$data_dir")
  [ -f "$file" ] || return 0
  fm_merge_queue_lock "$data_dir" || {
    echo "merge-queue: could not take the queue lock; not removing $id" >&2
    return 1
  }
  tmp="$file.tmp.$$"
  local had matched wrote rc=0
  had=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
  matched=$(awk -F'\t' -v id="$id" '$1 == id' "$file" 2>/dev/null | wc -l | tr -d ' ')
  fm_merge_queue_drop_id "$file" "$id" > "$tmp" || {
    rm -f "$tmp"
    fm_merge_queue_unlock "$data_dir"
    echo "merge-queue: failed to rewrite the queue; kept it intact" >&2
    return 1
  }
  # Never accept a short write: a truncated rewrite would erase every other queued
  # branch, the one outcome this guard exists to prevent. The replacement must have
  # exactly the lines the source had minus the ones belonging to this id.
  wrote=$(wc -l < "$tmp" 2>/dev/null | tr -d ' ')
  case "$had$matched$wrote" in
    ''|*[!0-9]*)
      rm -f "$tmp"
      fm_merge_queue_unlock "$data_dir"
      echo "merge-queue: could not verify the rewritten queue; kept it intact" >&2
      return 1
      ;;
  esac
  if [ "$wrote" -ne $((had - matched)) ]; then
    rm -f "$tmp"
    fm_merge_queue_unlock "$data_dir"
    echo "merge-queue: refusing a short rewrite of the queue for $id" >&2
    return 1
  fi
  mv "$tmp" "$file" || rc=$?
  [ "$rc" -eq 0 ] || rm -f "$tmp"
  fm_merge_queue_unlock "$data_dir"
  return "$rc"
}

# True only when origin PROVABLY no longer carries <branch>. Used when the recorded
# head object is no longer in the clone (the local branch is gone after teardown, and
# a pruning fetch plus gc can drop the last remote-tracking copy of a merged branch):
# a branch the forge deleted after merging must clear rather than stick forever. Any
# inconclusive answer - a network or auth failure, an ls-remote error - returns
# non-zero so nothing clears on an unverifiable claim.
fm_merge_queue_branch_gone_from_origin() {
  local project=$1 branch=$2 rc=0
  [ -n "$branch" ] || return 1
  git -C "$project" ls-remote --exit-code --heads origin "refs/heads/$branch" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}

# Distinct status for "cleared because origin no longer carries the branch, merge
# NOT verified" so callers never report it as a confirmed merge.
FM_MERGE_QUEUE_BRANCH_GONE=3

# True when <branch>'s work (tip <head>) is confirmed merged into <base> on origin.
# Repo-agnostic and safe for Bitbucket repos with no PR automation: it checks
# content-in-base against the real base branch, never a PR-state lookup. Fetches the
# base fresh, then accepts either head reachable from origin/<base> (ordinary merge)
# or the branch introducing nothing origin/<base> lacks (squash/rebase merge). Any
# inconclusive result (no origin, fetch failure, conflict) returns non-zero so the
# entry is KEPT rather than cleared on an unverifiable claim. Returns 0 for a
# confirmed merge, $FM_MERGE_QUEUE_BRANCH_GONE when only the branch-gone fallback
# applies, and 1 otherwise.
fm_merge_queue_branch_merged() {
  local project=$1 branch=$2 head=$3 base=$4 ref base_tree merged_tree
  [ -n "$project" ] && [ -d "$project" ] || return 1
  [ -n "$base" ] || return 1
  git -C "$project" remote get-url origin >/dev/null 2>&1 || return 1
  if ! git -C "$project" cat-file -e "$head^{commit}" 2>/dev/null; then
    fm_merge_queue_branch_gone_from_origin "$project" "$branch" || return 1
    return "$FM_MERGE_QUEUE_BRANCH_GONE"
  fi
  git -C "$project" fetch --quiet origin "+refs/heads/$base:refs/remotes/origin/$base" >/dev/null 2>&1 || return 1
  ref="refs/remotes/origin/$base"
  git -C "$project" merge-base --is-ancestor "$head" "$ref" 2>/dev/null && return 0
  base_tree=$(git -C "$project" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$base_tree" ] || return 1
  merged_tree=$(git -C "$project" merge-tree --write-tree "$ref" "$head" 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$base_tree" ]
}

# A forge-confirmed merge check, used ONLY when the content-in-base check above
# is inconclusive (a squash/rebase merge whose base later touched a file the
# branch also touched makes merge-tree report a conflict, so the content check
# keeps the entry forever). This is an ADDITION to fm_merge_queue_branch_merged,
# never a replacement: it asks the forge directly whether <head> landed in a
# merged pull request, and it is reached only after the content check declined.
#
# GitHub: gh-axi api repos/<slug>/commits/<head>/pulls filtered to MERGED PRs
# whose base is <base>. A non-empty result is a confirmed merge. Any error, an
# unresolvable slug, or a missing gh-axi is inconclusive (return 1), so nothing
# clears on an unverifiable claim. Bitbucket has no head-commit-to-PR lookup as
# cheap as GitHub's, and the Bitbucket branch poll (bin/fm-merge-queue-poll.sh)
# already drives the merged/declined wake for those entries, so this helper is
# GitHub-only by design and returns 1 (inconclusive) for a non-GitHub origin.
#
# Returns 0 for a forge-confirmed merge, 1 for "not confirmed" (including every
# inconclusive or unavailable case), so a caller treats only 0 as a clear.
fm_merge_queue_forge_confirms_merged() {
  local project=$1 head=$2 base=$3 slug count
  [ -n "$project" ] && [ -d "$project" ] || return 1
  [ -n "$head" ] && [ -n "$base" ] || return 1
  command -v gh-axi >/dev/null 2>&1 || return 1
  slug=$(fm_pr_github_origin_slug "$project") || return 1
  # The commits/<sha>/pulls endpoint lists every PR that contains this commit.
  # Keep only a PR that is MERGED into the queued base; a non-empty count is a
  # confirmed merge. gh-axi's --jq does the filtering, so no local jq is needed.
  count=$(gh-axi api "repos/$slug/commits/$head/pulls" \
    --header 'Accept: application/vnd.github+json' \
    --jq "[.[] | select(.merged_at != null) | select(.base.ref == \"$base\")] | length" \
    2>/dev/null) || return 1
  case "$count" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$count" -gt 0 ]
}

# Reconcile queue entries against live state/<id>.meta before a sweep. An id can
# sit in the queue with a STALE head while a live meta records a NEWER pr_head
# (the branch got more commits and a fresh PR head after the entry was recorded,
# e.g. a promoted scout that re-pushed). The stale head is not an ancestor of
# base and its content no longer matches, so the entry would never sweep. This
# refreshes the queued head to the meta's pr_head so the merged check runs
# against the commit that actually landed. It only ever rewrites the head field;
# it never removes an entry (removal stays with the merged-confirmation sweep)
# and never touches an id with no live meta or whose meta pr_head already matches.
# Args: data_dir state_dir. Prints one line per refreshed id.
fm_merge_queue_reconcile_drift() {
  local data_dir=$1 state_dir=$2 entries meta new_head
  [ -n "$state_dir" ] && [ -d "$state_dir" ] || return 0
  entries=$(fm_merge_queue_entries "$data_dir") || return 0
  [ -n "$entries" ] || return 0
  while IFS='	' read -r id project branch head base url; do
    [ -n "$id" ] || continue
    meta="$state_dir/$id.meta"
    [ -f "$meta" ] || continue
    new_head=$(grep '^pr_head=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$new_head" ] || continue
    [ "$new_head" != "$head" ] || continue
    fm_pr_head_valid "$new_head" || continue
    if fm_merge_queue_record "$data_dir" "$id" "$project" "$branch" "$new_head" "$base" "$url"; then
      printf 'refreshed: %s head %s -> %s (from live meta)\n' "$id" "$head" "$new_head"
    else
      printf 'kept: %s (drift refresh could not update the queue)\n' "$id" >&2
    fi
  done <<EOF
$entries
EOF
}

# Build a captain-facing compare URL from an origin remote URL, base, and branch.
# Handles github.com and bitbucket.org (SSH or HTTPS); falls back to a plain
# descriptive string when the host is unknown, so the value is always non-empty.
fm_merge_queue_compare_url() {
  local remote=$1 base=$2 branch=$3 hostpath host path owner repo
  hostpath=$remote
  case "$hostpath" in
    git@*:*) host=${hostpath#git@}; host=${host%%:*}; path=${hostpath#*:} ;;
    ssh://git@*) hostpath=${hostpath#ssh://git@}; host=${hostpath%%/*}; host=${host%%:*}; path=${hostpath#*/} ;;
    https://*) hostpath=${hostpath#https://}; hostpath=${hostpath#*@}; host=${hostpath%%/*}; path=${hostpath#*/} ;;
    http://*) hostpath=${hostpath#http://}; hostpath=${hostpath#*@}; host=${hostpath%%/*}; path=${hostpath#*/} ;;
    *) host=; path= ;;
  esac
  path=${path%.git}
  owner=${path%%/*}
  repo=${path#*/}
  if [ -n "$host" ] && [ -n "$owner" ] && [ -n "$repo" ] && [ "$owner" != "$path" ]; then
    case "$host" in
      github.com)
        printf '%s\n' "https://github.com/$owner/$repo/compare/$base...$branch"; return 0 ;;
      bitbucket.org)
        printf '%s\n' "https://bitbucket.org/$owner/$repo/branch/$branch?dest=$base"; return 0 ;;
    esac
  fi
  printf '%s\n' "branch $branch (base $base) in ${path:-$remote}"
}

# The GitHub owner whose forks firstmate owns and may auto-merge. It is the
# origin owner of every tooling fork in this fleet (firstmate, no-mistakes,
# jcode, tasks-axi, herdr, quota-axi, claude-swap, mongosh-axi), each cloned as
# git@github.com:yjuyjuy/<repo>.git.
FM_MERGE_QUEUE_OWNED_GITHUB_OWNER=${FM_MERGE_QUEUE_OWNED_GITHUB_OWNER:-yjuyjuy}

# Decide whether the queued branches for one clone may be auto-merged by a
# firstmate-dispatched merge worker.
#
# This is the hard product-repo safety gate the captain set on 2026-08-23: our
# PRODUCT repos (hyfin, hyfin-server, dashposserver3, and every other Bitbucket
# dashnow repo) are NEVER auto-merged - the captain reviews and merges those PRs
# himself. Only the tooling forks we own on GitHub are eligible.
#
# The gate is an ALLOWLIST on the clone's LIVE git origin, deliberately never a
# denylist of product-repo names. A denylist fails OPEN: the day a new product
# repo is cloned, its name is not on the list yet, so it would slip through and be
# auto-merged - exactly the mistake this gate exists to prevent. An origin
# allowlist fails CLOSED: a repo is eligible only when it PROVABLY resolves to a
# github.com/<owned-owner> origin, so anything else - a Bitbucket dashnow product
# repo, a GitHub repo under any other owner, a clone with no resolvable origin -
# is skipped by construction. The check reads the clone's real origin URL
# (fm_pr_github_origin_slug, a config read, never the network), so it tracks
# where the code actually lands rather than a name that can drift.
#
# Prints the reason for the decision on stdout and returns:
#   0  eligible: origin is github.com/<owned-owner>/<repo>
#   1  skipped:  any other origin, or origin unresolved (fail closed)
fm_merge_queue_repo_auto_mergeable() {
  local project=$1 slug owner
  if [ -z "$project" ] || [ ! -d "$project" ]; then
    printf 'skip: clone path %s is missing, cannot verify it is an owned tooling repo\n' "${project:-(empty)}"
    return 1
  fi
  # fm_pr_github_origin_slug prints owner/repo and returns 0 ONLY for a
  # github.com origin in a recognized form; a Bitbucket origin, any other host,
  # or no origin returns non-zero. That non-zero is exactly "not provably an
  # owned GitHub tooling repo", so it is the skip path.
  if ! slug=$(fm_pr_github_origin_slug "$project"); then
    printf 'skip: %s origin is not a github.com/%s tooling repo (product or not-owned repo, captain merges those)\n' \
      "$project" "$FM_MERGE_QUEUE_OWNED_GITHUB_OWNER"
    return 1
  fi
  owner=${slug%%/*}
  # Owner comparison is case-insensitive: GitHub owners are case-insensitive, and
  # fm_pr_refuse_unowned_github_target folds case the same way.
  if [ "${owner,,}" = "${FM_MERGE_QUEUE_OWNED_GITHUB_OWNER,,}" ]; then
    printf 'eligible: %s is our owned tooling fork\n' "$slug"
    return 0
  fi
  printf 'skip: %s is on GitHub but not under %s, a repo we do not own\n' \
    "$slug" "$FM_MERGE_QUEUE_OWNED_GITHUB_OWNER"
  return 1
}

# Group the live queue by clone and classify each clone for auto-merge dispatch.
# This is the pure planning core the dispatch CLI renders and acts on; it spawns
# nothing and mutates nothing, so it is safe to run any time and easy to test.
#
# Args: data_dir [min_batch]. min_batch (default 1) is the smallest branch count
# that makes a clone worth a dedicated merge worker; an eligible clone below it is
# reported as below-threshold rather than dispatched, so a single stray branch
# does not spawn a whole worker unless the caller lowers the bar.
#
# Prints one tab-separated row per clone, in first-seen queue order:
#   <decision>\t<project-path>\t<count>\t<reason>
# decision is one of:
#   eligible         auto-mergeable AND count >= min_batch  -> dispatch a worker
#   below-threshold  auto-mergeable AND count <  min_batch  -> report, do not spawn
#   skip             NOT auto-mergeable (product/not-owned/unresolved) -> never spawn
# The reason is the human string fm_merge_queue_repo_auto_mergeable produced, so
# the skip rationale (the hard product-repo exclusion) travels with every row.
fm_merge_queue_dispatch_plan() {
  local data_dir=$1 min_batch=${2:-1} entries grouped path count reason rc
  entries=$(fm_merge_queue_entries "$data_dir") || return 0
  [ -n "$entries" ] || return 0
  # One pass: count entries per clone and remember first-seen order. Project
  # paths can carry neither a tab nor a newline (fm_merge_queue_field_safe
  # enforces that at record time), so a tab-delimited read of field 2 is safe.
  grouped=$(printf '%s\n' "$entries" | awk -F'\t' '
    $2 != "" {
      c[$2]++
      if (!($2 in seen)) { seen[$2] = 1; order[++n] = $2 }
    }
    END { for (i = 1; i <= n; i++) printf "%s\t%s\n", order[i], c[order[i]] }
  ')
  [ -n "$grouped" ] || return 0
  while IFS='	' read -r path count; do
    [ -n "$path" ] || continue
    if reason=$(fm_merge_queue_repo_auto_mergeable "$path"); then
      rc=0
    else
      rc=1
    fi
    if [ "$rc" -eq 0 ]; then
      if [ "$count" -ge "$min_batch" ]; then
        printf 'eligible\t%s\t%s\t%s\n' "$path" "$count" "$reason"
      else
        printf 'below-threshold\t%s\t%s\t%s\n' "$path" "$count" "$reason"
      fi
    else
      printf 'skip\t%s\t%s\t%s\n' "$path" "$count" "$reason"
    fi
  done <<EOF
$grouped
EOF
}
