#!/usr/bin/env bash
# fm-cleanup-sweep.sh - the hourly cleanup pass.
#
# WHAT ACTUALLY ACCUMULATES IN A LONG-RUNNING HOME (established by reading the
# producers, not guessed):
#   - watcher temp files from a killed poll: state/.fm-check-output.* and
#     state/.fm-custom-check.* (bin/fm-watch.sh removes these on its own happy
#     path, so any survivor is crash residue)
#   - watcher suppression markers for tasks that no longer exist: .seen-*,
#     .hash-*, .count-*, .stale-*, .paused-*, .hb-surfaced-*,
#     .wedge-escalations-*, .sm-context-surfaced-*, and the wake-brief reader's
#     own .wake-brief-seen-* last-seen markers
#   - isolated copies still registered in a project clone after their task is
#     gone
#
# THE SAFETY LINE, AND WHY IT IS DRAWN HERE: the first two are pure bookkeeping
# - no work of any kind lives in them - so this pass reclaims them SILENTLY and
# logs what it did. An orphan isolated copy can hold unlanded work, so this pass
# never removes it and never runs a teardown to find out: it REPORTS it as a
# candidate with the exact command, and bin/fm-teardown.sh stays the single
# owner of the landed-work test. That keeps a background sweep structurally
# incapable of discarding work: refusing costs a line of prose, and being wrong
# costs a crewmate's unlanded branch.
#
# Nothing here writes to a project, and nothing here touches the network. The
# project-clone inspection is a read-only `git worktree list`; even a
# `git worktree prune` (which would be safe in isolation) is deliberately not
# run, because it is a write into a clone firstmate must only read. The merge
# queue is deliberately NOT swept here either: its merged test fetches into a
# clone, which an unattended poll must never do, so sweeping it stays
# firstmate's own action through bin/fm-merge-queue.sh.
#
# Usage: fm-cleanup-sweep.sh
#   Prints one short headline line when something needs a decision, and nothing
#   at all when it only reclaimed bookkeeping or found nothing. The full report
#   is written to state/.hourly-cleanup.latest, reclaim actions to
#   state/.hourly-cleanup.log. Always exits 0: a reporting command, not a gate.
#
# Thresholds (seconds; see docs/configuration.md):
#   FM_CLEANUP_TEMP_SECS      default 3600    age before temp residue is reclaimed
#   FM_CLEANUP_MARKER_SECS    default 86400   age before dead markers are reclaimed
#   FM_CLEANUP_ORPHAN_SECS    default 86400   how old the orphan copy's own
#                                             directory mtime must be before it
#                                             is reported (a coarse "left alone
#                                             for a while" test, not a measure of
#                                             when work in it last happened)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

# shellcheck source=bin/fm-hourly-lib.sh
. "$SCRIPT_DIR/fm-hourly-lib.sh"

TEMP_SECS=${FM_CLEANUP_TEMP_SECS:-3600}
case "$TEMP_SECS" in ''|*[!0-9]*) TEMP_SECS=3600 ;; esac
MARKER_SECS=${FM_CLEANUP_MARKER_SECS:-86400}
case "$MARKER_SECS" in ''|*[!0-9]*) MARKER_SECS=86400 ;; esac
ORPHAN_SECS=${FM_CLEANUP_ORPHAN_SECS:-86400}
case "$ORPHAN_SECS" in ''|*[!0-9]*) ORPHAN_SECS=86400 ;; esac

[ -d "$STATE" ] || exit 0

LOG_PATH="$STATE/.hourly-cleanup.log"
LOG_MAX_BYTES=${FM_CLEANUP_LOG_MAX_BYTES:-262144}
case "$LOG_MAX_BYTES" in ''|*[!0-9]*|0) LOG_MAX_BYTES=262144 ;; esac
RECLAIMED=0
fm_hourly_reset_findings

# Size-capped the same way bin/fm-watch.sh caps its triage log, so a long-lived
# home cannot grow this file without bound. Best-effort: a logging hiccup never
# affects the sweep.
log_reclaim() {
  local sz
  RECLAIMED=$(( RECLAIMED + 1 ))
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$LOG_PATH" 2>/dev/null || return 0
  sz=$(wc -c < "$LOG_PATH" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$LOG_MAX_BYTES" ]; then
    tail -n 2000 "$LOG_PATH" > "$LOG_PATH.tmp" 2>/dev/null && mv -f "$LOG_PATH.tmp" "$LOG_PATH" 2>/dev/null
    rm -f "$LOG_PATH.tmp" 2>/dev/null || true
  fi
}

INFLIGHT=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  fm_hourly_meta_is_secondmate "$meta" && continue
  INFLIGHT=$(( INFLIGHT + 1 ))
done

# --- reclaim 1: watcher temp residue -----------------------------------------
for tmpfile in "$STATE"/.fm-check-output.* "$STATE"/.fm-custom-check.*; do
  [ -f "$tmpfile" ] || continue
  [ "$(fm_hourly_age_of "$tmpfile")" -ge "$TEMP_SECS" ] || continue
  rm -f "$tmpfile" 2>/dev/null && log_reclaim "removed stale watcher temp file $(basename "$tmpfile")"
done

# --- reclaim 2: suppression markers for a fleet that no longer exists ---------
# Only with NO ordinary work under way: with no task, no marker can be
# suppressing a live wake, which makes removal provably safe. With work in
# flight the mapping from a mangled marker key back to a task is not worth
# trusting, so nothing is touched - a few stale markers are harmless, a wrongly
# cleared one is not. A persistent secondmate is idle by contract and would
# otherwise disable this reclaim forever in any home that has one, so it does
# not count as work under way; its own markers are protected by name instead.
if [ "$INFLIGHT" -eq 0 ]; then
  LIVE_KEYS=
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    key=$(fm_hourly_marker_key "$(basename "$meta" .meta)")
    LIVE_KEYS="$LIVE_KEYS|$key"
    win=$(grep '^window=' "$meta" 2>/dev/null | head -1 | cut -d= -f2- || true)
    [ -n "$win" ] || continue
    LIVE_KEYS="$LIVE_KEYS|$(fm_hourly_marker_key "$win")"
  done
  for marker in "$STATE"/.seen-* "$STATE"/.hash-* "$STATE"/.count-* \
    "$STATE"/.stale-* "$STATE"/.paused-* "$STATE"/.hb-surfaced-* \
    "$STATE"/.wedge-escalations-* "$STATE"/.sm-context-surfaced-* \
    "$STATE"/.wake-brief-seen-*; do
    [ -f "$marker" ] || continue
    [ "$(fm_hourly_age_of "$marker")" -ge "$MARKER_SECS" ] || continue
    name=$(basename "$marker")
    # Scan LIVE_KEYS by its "|" delimiter rather than word-splitting it: an id or
    # window value carrying a glob character would otherwise expand against the
    # current directory and stop protecting that task's markers.
    skip=0
    rest=$LIVE_KEYS
    while [ -n "$rest" ]; do
      key=${rest%%|*}
      rest=${rest#"$key"}
      rest=${rest#|}
      [ -n "$key" ] || continue
      case "$name" in *"$key"*) skip=1; break ;; esac
    done
    [ "$skip" -eq 1 ] && continue
    rm -f "$marker" 2>/dev/null && log_reclaim "removed dead suppression marker $name"
  done
fi

# --- report 1: isolated copies still registered after their task is gone ------
LIVE_WORKTREES=
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  wt=$(grep '^worktree=' "$meta" 2>/dev/null | head -1 | cut -d= -f2- || true)
  [ -n "$wt" ] || continue
  LIVE_WORKTREES="$LIVE_WORKTREES|$wt|"
done

if [ -d "$PROJECTS" ]; then
  for clone in "$PROJECTS"/*; do
    [ -d "$clone/.git" ] || [ -f "$clone/.git" ] || continue
    while IFS= read -r line; do
      case "$line" in worktree\ *) ;; *) continue ;; esac
      wt=${line#worktree }
      [ "$wt" = "$clone" ] && continue
      case "$LIVE_WORKTREES" in *"|$wt|"*) continue ;; esac
      [ -d "$wt" ] || continue
      [ "$(fm_hourly_age_of "$wt")" -ge "$ORPHAN_SECS" ] || continue
      fm_hourly_add_finding "worktree:$wt" \
        "an isolated copy in $(basename "$clone") outlived its task" \
        "$wt is still registered in $clone with no task recorded for it; NOT removed - it may hold unlanded work, so clean it up with bin/fm-teardown.sh <id> (which owns the landed-work test) or inspect it first"
    done <<EOF
$(git -C "$clone" worktree list --porcelain 2>/dev/null || true)
EOF
  done
fi

# Per-task temp roots under /tmp are deliberately NOT scanned: /tmp is shared by
# every firstmate home on the host, so a live task of another home would be
# reported here as this home's leftover, and there is no reliable ownership
# signal in those paths.

# --- report --------------------------------------------------------------------
REPORT_PATH=$(fm_hourly_report_path "$STATE" cleanup)
{
  printf 'hourly cleanup sweep - %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf 'home: %s\n' "$FM_HOME"
  printf 'reclaimed silently: %s bookkeeping item(s) (see %s)\n' "$RECLAIMED" "$LOG_PATH"
  if [ "$FM_HOURLY_FINDINGS" -eq 0 ]; then
    printf 'no candidates needing a decision.\n'
  else
    printf '%s candidate(s) left in place for a decision:\n' "$FM_HOURLY_FINDINGS"
    printf '%s' "$FM_HOURLY_REPORT"
  fi
} > "$REPORT_PATH" 2>/dev/null || true

fm_hourly_should_surface "$STATE" cleanup "$FM_HOURLY_SIGNATURE" || exit 0
printf 'cleanup: %s (nothing was removed; full report: %s)\n' "$FM_HOURLY_HEADLINES" "$REPORT_PATH"
exit 0
