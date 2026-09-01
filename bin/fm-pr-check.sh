#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
# Usage: fm-pr-check.sh <task-id> <pr-url>
#
# Orphan mode (fm-pr-check.sh --orphan <pr-url>) exists so an orphan merge - a
# PR whose task metadata state/<id>.meta is already gone - shares the same
# invocation shape as the task path. Arming a watcher merge poll genuinely
# requires a task: the poll's data sidecar, registration, and check are all
# keyed by task id and validated against the task's own meta, and there is no
# meta for an orphan PR. So orphan mode records no pr=/pr_head= evidence and
# arms no poll; it cleanly no-ops with a message and exits 0. The merge itself
# (bin/fm-pr-merge.sh --orphan) is the must-have path and records its own
# durable evidence to data/orphan-merges.log.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "${1:-}" = "--orphan" ]; then
  if [ "$#" -ne 2 ]; then
    echo "error: invalid PR check request" >&2
    exit 2
  fi
  if ! fm_pr_url_parse "$2"; then
    echo "error: invalid PR check request" >&2
    exit 2
  fi
  echo "orphan: no task metadata to record and no poll to arm; skipping" >&2
  exit 0
fi

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  echo "hint: task $ID has no metadata (torn down while its PR was still open, or its branch drained to the merge queue); records-gone lands through orphan mode: fm-pr-merge.sh --orphan <owner/repo> <pr-url>" >&2
  exit 1
fi

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

# Refuse to arm a Bitbucket watch when the poll could never confirm a merge:
# the byte-static poll reads the Bitbucket REST API with curl and jq and
# authenticates with the NO_MISTAKES_BITBUCKET_* credentials, and it is silent
# on every error, so a missing tool or credential is indistinguishable from a PR
# that is never merged. Arming is the one point where that gap can be reported,
# so an absent tool or credential stops the watch here instead of watching
# nothing. fm-bitbucket-lib.sh owns the specific diagnostic.
if [ "$PROVIDER" = bitbucket ]; then
  # shellcheck source=bin/fm-bitbucket-lib.sh
  . "$SCRIPT_DIR/fm-bitbucket-lib.sh"
  fm_bitbucket_ready || exit 1
fi

# Fork-target guard: a GitHub PR must target the task clone's OWN repository, not
# a fork parent. `gh`/`glab` default a PR base to the fork parent on a fork
# clone, so without this a worker (even with a correct brief) could arm a merge
# poll for, and firstmate could then merge, a PR against a repo we do not own.
# The check runs before any state mutation and fails closed on a resolved
# mismatch. It is silent and permissive when origin does not resolve to a
# github.com owner/repository (local-only clone, self-hosted forge), so those
# clones are unchanged. GitLab targets are addressed by full path, not
# owner/repository, and this GitHub-owner check does not apply to them.
if [ "$PROVIDER" = github ]; then
  GUARD_WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  GUARD_PROJ=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
  fm_pr_refuse_unowned_github_target "$FM_PR_OWNER" "$FM_PR_REPO" "$GUARD_WT" "$GUARD_PROJ" || exit 1
fi

# Same own-repository guard for Bitbucket: the target workspace/repository must
# be the task clone's own origin, so a poll is never armed for, and a merge never
# fires against, a Bitbucket repository we do not own. It is silent and permissive
# when origin does not resolve to a bitbucket.org workspace/repository, so a
# local-only or different-forge clone is unchanged.
if [ "$PROVIDER" = bitbucket ]; then
  GUARD_WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  GUARD_PROJ=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
  fm_pr_refuse_unowned_bitbucket_target "$FM_PR_WORKSPACE" "$FM_PR_REPO" "$GUARD_WT" "$GUARD_PROJ" || exit 1
fi

# Neutralize any pre-fix poll before recording or arming this task. The
# migration never executes legacy artifacts and holds watcher exclusion while
# it quarantines or rebuilds them.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || exit 1
"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head is recorded only when the forge's CLI can supply it. gh exposes the
# head commit as a selectable field; plain glab exposes it only inside its JSON
# output, which would need a JSON processor firstmate does not require, so a
# GitLab task records no pr_head. Both consumers already treat it as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi

META_TMP=
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
printf 'armed: state/%s.check.sh\n' "$ID"

# A PR was just recorded for this task, which changes what the desk's ready-to-
# merge section shows, so rebuild the live desk in place if one exists. Best-
# effort and silent (no-op without a live desk, never re-serves, never wakes);
# it self-detaches so it cannot delay arming the poll. See bin/fm-desk-event.sh.
FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-desk-event.sh" pr >/dev/null 2>&1 || true
