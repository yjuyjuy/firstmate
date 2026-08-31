#!/usr/bin/env bash
# Generate a structured PR-description skeleton for a task from its brief,
# so a worker never starts the description from a blank page.
#
# Reads data/<task-id>/brief.md under the active firstmate home and produces a
# Markdown skeleton owned by the captain's enrichment contract:
#   Summary             - the brief's Task section, verbatim
#   Acceptance criteria - checkbox lines / explicit criteria blocks from the Task text
#   Approach / Tradeoffs / Test evidence
#                        - named sections with fill-in instructions, never stubs:
#                          the worker must complete each one substantively
#                        - Test evidence asks for commands + results, test paths,
#                          the test-first / end-to-end coverage declaration, and
#                          CI or build links
#   Related discussion  - Mattermost permalinks found in the brief, the task's
#                         data/<id>/ files, or state/<id>.meta
#   Related tickets     - issue URLs and short #NNN references (resolved to full
#                         URLs through the task's project remote) plus bare
#                         tracker-style ticket ids, kept verbatim
#   Prior work          - recent commits touching the task's changed paths, as
#                         full commit URLs resolved through the project remote
#                         (capped at five entries)
#   Related reports     - the task's own data/<id>/report.md when it exists and
#                         any Markdown docs the brief references that exist on
#                         disk under the home or the repo
# Every enrichment section is omitted when nothing discoverable is found, never
# emitted empty. All links are full clickable URLs: bare numbers are never
# emitted (standing captain rule); a reference that cannot be resolved to a URL
# is carried verbatim with a resolve-before-opening hint instead of dropped.
#
# The task's repo is resolved from the caller's current directory when it is a
# git checkout (the worker's own worktree, whose HEAD is the task branch),
# falling back to the project recorded in state/<task-id>.meta. All git reads
# are read-only: history lookups and changed-path diffs never write to the
# project. A remote-less repo simply omits the URL-bearing sections.
#
# Refuses to run when the brief's Task text still contains the {TASK}
# placeholder: a skeleton generated from an unfilled brief would carry no real
# summary, which is exactly the stub the helper exists to prevent.
#
# Usage: fm-pr-description.sh <task-id>
#        fm-pr-description.sh <task-id> --stdout   print instead of writing
# By default the skeleton is written to data/<task-id>/pr-description.md and
# its path is printed, so a worker can edit it and pass it to the PR opener
# (e.g. gh-axi pr create --body-file data/<task-id>/pr-description.md).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [ "$#" -lt 1 ]; then
  echo "error: missing task id" >&2
  usage >&2
  exit 2
fi
ID=$1
TO_STDOUT=0
if [ "${2:-}" = "--stdout" ]; then
  TO_STDOUT=1
elif [ "$#" -gt 1 ]; then
  echo "error: unknown argument: $2" >&2
  usage >&2
  exit 2
fi

# Task ids are path components; refuse anything that could escape data/.
case "$ID" in
  ''|.|..|*/*|*\\*|*[!A-Za-z0-9._-]*)
    echo "error: invalid task id: $ID" >&2
    exit 2
    ;;
esac

BRIEF="$DATA/$ID/brief.md"
if [ ! -f "$BRIEF" ] || [ -L "$BRIEF" ]; then
  echo "error: task brief is unavailable: $BRIEF" >&2
  exit 1
fi

# --- Summary and acceptance criteria from the Task text ----------------------
# The Task section runs from the "# Task" heading to the next "# " heading.
TASK_BODY=$(
  awk '
    /^#+[[:space:]]+Task[[:space:]]*$/ { in_task=1; next }
    in_task && /^#+[[:space:]]/ { exit }
    in_task { print }
  ' "$BRIEF"
)
if printf '%s' "$TASK_BODY" | grep -q '{TASK}'; then
  echo "error: brief still contains the unfilled {TASK} placeholder; nothing to summarize" >&2
  exit 1
fi
# Collapse blank-line runs, trim leading/trailing blank lines and stray whitespace.
SUMMARY=$(printf '%s' "$TASK_BODY" \
  | awk 'NF { if (prev) print ""; print; prev=1 } !NF { prev=0 }' \
  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
[ -n "$SUMMARY" ] || SUMMARY="(the brief carried an empty Task section; summarize the task here)"

# Short #NNN references in the emitted text (summary and criteria) must become
# full-URL links, because no bare number may ride into a PR description. A task
# with a resolved project remote expands them against that repo; without a
# remote the label points at an explicit resolve-before-opening placeholder so
# the worker cannot mistake it for a finished link.
expand_short_refs() {
  local text=$1
  if [ -n "$REMOTE_BASE" ]; then
    printf '%s' "$text" | sed -E "s|#([0-9]+)|[#\1]($REMOTE_BASE/issues/\1)|g"
  else
    printf '%s' "$text" | sed -E 's|#([0-9]+)|[#](resolve-before-opening)|g'
  fi
}

# Acceptance criteria: checkbox lines anywhere in the Task text plus any block
# explicitly headed "Acceptance criteria" / "AC:" / "Criteria:".
CRITERIA=$(
  awk '
    /^#+[[:space:]]+Task[[:space:]]*$/ { in_task=1; next }
    in_task && /^#+[[:space:]]/ { exit }
    in_task && (/^[[:space:]]*[-*][[:space:]]*\[[ xX]\]/ || /^[[:space:]]*(AC|Acceptance criter|Criteria|Requirements)/) { print; got=1; next }
    in_task && got && /^[[:space:]]*[-*][[:space:]]*[^[({]/ { print; next }
    { got=0 }
  ' "$BRIEF"
)

# --- Enrichment scan sources -------------------------------------------------
# Mattermost permalinks can live in the brief, other files of the task's data
# dir, or the task metadata (e.g. a captain note carrying the thread).
MATTERMOST=$(cat "$BRIEF")
for f in "$DATA/$ID"/*; do
  # The generator's own output must not feed the scan: a previous run would
  # otherwise re-extract the refs it emitted (e.g. prior-work commit subjects)
  # and the skeleton would grow stale links on every regeneration.
  [ -f "$f" ] && [ "$f" != "$BRIEF" ] && [ "$(basename "$f")" != "pr-description.md" ] && MATTERMOST="$MATTERMOST
$(cat "$f")"
done
if [ -f "$STATE/$ID.meta" ]; then
  MATTERMOST="$MATTERMOST
$(cat "$STATE/$ID.meta")"
fi

# --- Related reports ---------------------------------------------------------
# The task's own scout report when one exists, plus any Markdown doc the brief
# references that exists under the home or the repo.
REPORTS_LINES=""
if [ -f "$DATA/$ID/report.md" ]; then
  REPORTS_LINES="$DATA/$ID/report.md"
fi
while IFS= read -r tok; do
  [ -z "$tok" ] && continue
  cand=""
  [ -f "$FM_HOME/$tok" ] && cand="$FM_HOME/$tok"
  [ -z "$cand" ] && [ -f "$FM_ROOT/$tok" ] && cand="$FM_ROOT/$tok"
  if [ -n "$cand" ]; then
    case "$REPORTS_LINES" in
      *"$cand"*) ;;
      *) REPORTS_LINES="$REPORTS_LINES
$cand" ;;
    esac
  fi
done < <(grep -oE '[A-Za-z0-9_./-]+\.md' "$BRIEF" | sort -u | while IFS= read -r tok; do
  case "$tok" in
    data/*) printf '%s\n' "$tok" ;;
    *report.md|*report-*.md|*diagnos*.md|*finding*.md|*scout*.md|*audit*.md|*analysis*.md) printf '%s\n' "$tok" ;;
  esac
done)

# --- Project repo resolution -------------------------------------------------
# A pooled or secondmate worker runs inside its own checkout of the task's
# repo, and that checkout's HEAD is the task branch. The caller's current
# directory is therefore the preferred repo for every git read; the task's
# recorded project clone (state/<id>.meta project=) is the fallback for runs
# outside any checkout. Both are the same repository in the pooled layout, so
# history, refs, and remotes agree either way.
PROJECT=""
if [ -f "$STATE/$ID.meta" ]; then
  PROJECT=$(sed -n 's/^project=//p' "$STATE/$ID.meta" | head -1)
  if [ -n "$PROJECT" ] && { [ ! -d "$PROJECT" ] || ! git -C "$PROJECT" rev-parse --git-dir >/dev/null 2>&1; }; then
    PROJECT=""
  fi
fi
PWD_TOP=""
if git -C "$PWD" rev-parse --show-toplevel >/dev/null 2>&1; then
  PWD_TOP=$(git -C "$PWD" rev-parse --show-toplevel)
fi
REPO=""
if [ -n "$PWD_TOP" ] && [ -n "$PROJECT" ]; then
  # The caller's checkout wins only when it is the SAME repository as the
  # task's project (the pooled-worktree layout); a different repo (e.g. the
  # firstmate home itself) must not shadow the task repo.
  if [ "$(git -C "$PWD_TOP" rev-parse --absolute-git-dir 2>/dev/null)" = "$(git -C "$PROJECT" rev-parse --absolute-git-dir 2>/dev/null)" ]; then
    REPO=$PWD_TOP
  else
    REPO=$PROJECT
  fi
elif [ -n "$PWD_TOP" ]; then
  REPO=$PWD_TOP
elif [ -n "$PROJECT" ]; then
  REPO=$PROJECT
fi

# --- Remote base for full URLs -----------------------------------------------
REMOTE_BASE=""
if [ -n "$REPO" ]; then
  REMOTE_URL=$(git -C "$REPO" remote get-url origin 2>/dev/null || true)
  case "$REMOTE_URL" in
    https://*)
      REMOTE_BASE=$(printf '%s' "$REMOTE_URL" | sed -E 's#^(https://[^/]+/[^/]+/[^/.]+)(\.git)?/?$#\1#')
      ;;
    git@*:*)
      REMOTE_BASE=$(printf '%s' "$REMOTE_URL" | sed -E 's#^git@([^:]+):([^/]+)/([^/.]+)(\.git)?$#https://\1/\2/\3#')
      ;;
    ssh://*)
      REMOTE_BASE=$(printf '%s' "$REMOTE_URL" | sed -E 's#^ssh://([^/]+)/([^/]+)/([^/.]+)(\.git)?$#https://\1/\2/\3#')
      ;;
  esac
fi

# --- Prior work: recent commits touching the task's changed paths -------------
PRIOR_WORK=""
if [ -n "$REPO" ] && [ -n "$REMOTE_BASE" ]; then
  DEFAULT=""
  for cand in $(git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##') main master dev; do
    if git -C "$REPO" rev-parse --verify --quiet "origin/$cand" >/dev/null 2>&1; then
      DEFAULT=$cand
      break
    fi
  done
  # The task branch head: the fm/<id> lane when it exists (spawned tasks all
  # work on fm/<id>), else the repo's current branch, else HEAD. The repo's
  # bare HEAD can sit on the default branch when this runs outside the task
  # worktree, which would make the branch diff empty.
  HEAD_REF=HEAD
  if git -C "$REPO" rev-parse --verify --quiet "fm/$ID" >/dev/null 2>&1; then
    HEAD_REF="fm/$ID"
  else
    CUR_BRANCH=$(git -C "$REPO" branch --show-current 2>/dev/null || true)
    [ -n "$CUR_BRANCH" ] && HEAD_REF=$CUR_BRANCH
  fi
  CHANGED_PATHS=""
  if [ -n "$DEFAULT" ]; then
    BASE=$(git -C "$REPO" merge-base "origin/$DEFAULT" "$HEAD_REF" 2>/dev/null || true)
    [ -n "$BASE" ] && CHANGED_PATHS=$(git -C "$REPO" diff --name-only "$BASE".."$HEAD_REF" 2>/dev/null || true)
  fi
  CHANGED_PATHS="$CHANGED_PATHS
$(git -C "$REPO" diff --name-only "$HEAD_REF" 2>/dev/null || true)
$(git -C "$REPO" diff --cached --name-only 2>/dev/null || true)"
  CHANGED_PATHS=$(printf '%s' "$CHANGED_PATHS" | awk 'NF && !seen[$0]++')
  if [ -n "$CHANGED_PATHS" ]; then
    PRIOR_LOG=""
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      prior=$(git -C "$REPO" log --no-merges --format='%H%x09%s' -5 -- "$p" 2>/dev/null || true)
      [ -n "$prior" ] && PRIOR_LOG="$PRIOR_LOG
$prior"
    done <<EOF
$CHANGED_PATHS
EOF
    PRIOR_WORK=$(printf '%s' "$PRIOR_LOG" | awk 'NF && !seen[$1]++ {print}' | head -5 \
      | while IFS=$'\t' read -r sha subj; do
          [ -z "$sha" ] && continue
          short=$(printf '%s' "$sha" | cut -c1-7)
          subj=$(printf '%s' "$subj" | tr -d '[]`' | cut -c1-72)
          printf -- '- [%s %s](%s/commit/%s)\n' "$short" "$subj" "$REMOTE_BASE" "$sha"
        done)
  fi
fi

# --- Related tickets: issue URLs, #NNN refs, tracker-style ids ----------------
ISSUE_URLS=$(printf '%s' "$MATTERMOST" | grep -oE 'https://[^[:space:]")]+/issues/[0-9]+' | tr -d '.,;' | sort -u || true)
HASH_REFS=$(printf '%s' "$MATTERMOST" | grep -oE '(^|[^A-Za-z0-9_])#[0-9]+' | grep -oE '#[0-9]+' | sort -u || true)
TICKET_IDS=$(printf '%s' "$MATTERMOST" | grep -oE '(^|[^A-Za-z0-9_])[A-Z][A-Z0-9]{1,9}-[0-9]{1,6}' | grep -oE '[A-Z][A-Z0-9]{1,9}-[0-9]{1,6}' | sort -u || true)

TICKETS_LINES=""
while IFS= read -r u; do
  [ -z "$u" ] && continue
  case "$TICKETS_LINES" in
    *"$u"*) ;;
    *) TICKETS_LINES="$TICKETS_LINES
- $u" ;;
  esac
done <<EOF
$ISSUE_URLS
EOF
if [ -n "$REMOTE_BASE" ]; then
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    url="$REMOTE_BASE/issues/${n#\#}"
    case "$TICKETS_LINES" in
      *"$url"*) ;;
      *) TICKETS_LINES="$TICKETS_LINES
- $url" ;;
    esac
  done <<EOF
$HASH_REFS
EOF
fi
while IFS= read -r t; do
  [ -z "$t" ] && continue
  case "$TICKETS_LINES" in
    *"$t"*) ;;
    *) TICKETS_LINES="$TICKETS_LINES
- $t (resolve to the tracker URL before opening)" ;;
  esac
done <<EOF
$TICKET_IDS
EOF

# --- Mattermost permalink section --------------------------------------------
MM_LINES=""
if printf '%s' "$MATTERMOST" | grep -qE 'https?://[^[:space:]]+/(pl|channels)/[^[:space:]]+'; then
  MM_LINES=$(printf '%s' "$MATTERMOST" \
    | grep -oE 'https?://[^[:space:]")]+/(pl|channels)/[^[:space:]")]+' \
    | tr -d '.,;' | sort -u \
    | while IFS= read -r u; do printf -- '- %s\n' "$u"; done)
fi

# --- Assembly ----------------------------------------------------------------
OUT_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-pr-desc.XXXXXX")
trap 'rm -f "$OUT_TMP"' EXIT
{
  cat <<'EOF'
> PR description skeleton generated from the task brief.
> Fill EVERY section substantively before opening the PR: the description is long-run documentation, and a stub description is a defect.
> Full clickable URLs only, never bare numbers. Remove this note before opening the PR.

## Summary
EOF
  printf '%s\n' "$(expand_short_refs "$SUMMARY")"
  printf '\n## Acceptance criteria\n'
  if [ -n "$CRITERIA" ]; then
    printf '%s\n' "$(expand_short_refs "$CRITERIA")"
  else
    cat <<'EOF'
> Fill in: the concrete, checkable outcomes this change must satisfy.
EOF
  fi
  cat <<'EOF'

## Approach
> Fill in: what changed and why, the implementation shape, and the files or subsystems touched.

## Tradeoffs
> Fill in: alternatives considered, decisions taken, risks, and anything a reviewer should weigh.

## Test evidence
> Fill in: verification commands and their results, the tests added or run (with paths), the test-first and end-to-end coverage declaration, and CI or build links.

## Verification checklist
- [ ] Every section above is filled in substantively from the actual change
- [ ] All links are full clickable URLs
- [ ] The description was re-read once before opening the PR
EOF
  if [ -n "$MM_LINES" ]; then
    printf '\n## Related discussion\n%s\n' "$MM_LINES"
  fi
  if [ -n "$TICKETS_LINES" ]; then
    printf '\n## Related tickets\n%s\n' "$TICKETS_LINES"
  fi
  if [ -n "$PRIOR_WORK" ]; then
    printf '\n## Prior work\n%s\n' "$PRIOR_WORK"
  fi
  if [ -n "$REPORTS_LINES" ]; then
    printf '\n## Related reports\n'
    printf '%s\n' "$REPORTS_LINES" | while IFS= read -r r; do
      [ -z "$r" ] && continue
      printf -- '- %s\n' "\`$r\`"
    done
  fi
} > "$OUT_TMP"

if [ "$TO_STDOUT" = 1 ]; then
  cat "$OUT_TMP"
else
  DEST="$DATA/$ID/pr-description.md"
  mkdir -p "$(dirname "$DEST")"
  cp "$OUT_TMP" "$DEST"
  echo "wrote: $DEST"
fi