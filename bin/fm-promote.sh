#!/usr/bin/env bash
# Promote a scout task to a ship task, gated on the scout crew's live context.
#
# WHY the gate: a scout that did heavy investigation can be near auto-compact.
# Promoting in place then makes it implement on a nearly-full context, which
# compacts mid-ship and loses fidelity. Above a threshold a FRESH agent that
# inherits the scout's report is cleaner than continuing the heavy session.
#
# Behavior, decided by the scout's current context-window occupancy (read with
# fm_sm_context_tokens <cwd> <harness> from fm-secondmate-context-lib.sh, the
# single owner of the harness context read - the scout's cwd is its worktree=
# and harness is its harness= in state/<task-id>.meta):
#   - context <= threshold: promote IN PLACE as before - the crewmate keeps its
#     window, worktree, and loaded context; only the contract changes. Flips
#     kind= to ship in state/<task-id>.meta so fm-teardown.sh applies the full
#     ship-task teardown protection again, then firstmate sends the crewmate its
#     ship instructions via fm-send.sh (emitted as the next step).
#   - context > threshold: do NOT promote in place and do NOT flip kind (the task
#     stays kind=scout). Instead EMIT the fresh-handoff next step: firstmate
#     spawns a FRESH agent that inherits the scout report + ship instructions, so
#     implementation starts on a clean context budget, and tears down the old
#     scout worktree per normal scout teardown once its report exists.
#   - context UNREADABLE (unsupported harness, missing transcript, no jq, etc.):
#     FAIL CLOSED to today's behavior - promote in place - but PRINT a clear
#     notice that context could not be read, so the operator can override.
#
# Threshold: config/promote-context-threshold (a single integer, first non-empty
# non-comment line), default 100000, following the fm_sm_context_threshold
# pattern. Absent, non-integer, or non-positive falls back to the default so a
# typo never silently disables the gate.
#
# Usage: fm-promote.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-secondmate-context-lib.sh
. "$SCRIPT_DIR/fm-secondmate-context-lib.sh"

"$FM_ROOT/bin/fm-guard.sh" || true

# The promote context gate's token threshold, or the default. Reads
# config/promote-context-threshold (first non-empty non-comment line). Absent,
# non-integer, or non-positive falls back to the default, so a typo never
# silently disables the gate. Mirrors fm_sm_context_threshold.
FM_PROMOTE_CONTEXT_THRESHOLD_DEFAULT=100000
fm_promote_context_threshold() {  # <config-dir>
  local config=$1 file line
  file="$config/promote-context-threshold"
  [ -f "$file" ] || { printf '%s' "$FM_PROMOTE_CONTEXT_THRESHOLD_DEFAULT"; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    if [[ "$line" =~ ^[1-9][0-9]*$ ]]; then
      printf '%s' "$line"
    else
      printf '%s' "$FM_PROMOTE_CONTEXT_THRESHOLD_DEFAULT"
    fi
    return 0
  done < "$file"
  printf '%s' "$FM_PROMOTE_CONTEXT_THRESHOLD_DEFAULT"
}

ID=$1
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

CWD=$(fm_meta_get "$META" worktree)
HARNESS=$(fm_meta_get "$META" harness)
[ -n "$HARNESS" ] || HARNESS=$(fm_backend_of_meta "$META")
PROJECT=$(fm_meta_get "$META" project)

THRESHOLD=$(fm_promote_context_threshold "$CONFIG")
TOKENS=$(fm_sm_context_tokens "$CWD" "$HARNESS" || true)

HOME_Q=$(printf '%q' "$FM_HOME")

promote_in_place() {
  local tmp="$META.tmp"
  grep -v '^kind=' "$META" > "$tmp"
  echo "kind=ship" >> "$tmp"
  mv "$tmp" "$META"
  echo "promoted $ID to ship in place (teardown protection restored)"
  echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
}

if [ -z "$TOKENS" ]; then
  # FAIL CLOSED: context unreadable -> keep today's in-place behavior, but say so
  # loudly so the operator can override with a fresh handoff if they choose.
  echo "notice: could not read scout $ID context (harness=$HARNESS cwd=$CWD); context gate cannot decide, defaulting to in-place promote - override with a fresh handoff if this scout is context-heavy"
  promote_in_place
  exit 0
fi

if [ "$TOKENS" -le "$THRESHOLD" ]; then
  echo "context gate: scout $ID at $TOKENS tokens <= threshold $THRESHOLD - promoting in place"
  promote_in_place
  exit 0
fi

# Over threshold: refuse the in-place promote, leave kind=scout untouched, and
# emit the fresh-handoff next step for firstmate to execute.
echo "context gate: scout $ID at $TOKENS tokens > threshold $THRESHOLD - refusing in-place promote (kind stays scout)"
echo "reason: an already-heavy session would compact mid-ship and lose fidelity; hand off to a FRESH agent that inherits the scout report instead"
echo "next: spawn a fresh ship agent that carries the scout report at data/$ID/report.md PLUS the ship instructions (implement the report's recommended fix; create branch fm/<new-id>; report done per the project delivery mode):"
echo "      FM_HOME=$HOME_Q bin/fm-spawn.sh <new-id> $PROJECT --harness $HARNESS   # then seed its brief with the report + ship instructions via fm-brief.sh/fm-send.sh"
echo "then: tear down the old scout $ID worktree per normal scout teardown once its report at data/$ID/report.md exists (bin/fm-teardown.sh $ID)"
exit 0
