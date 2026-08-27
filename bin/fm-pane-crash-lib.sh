#!/usr/bin/env bash
# fm-pane-crash-lib.sh - immediate pane-exit detection for herdr task panes.
#
# When a worker's herdr pane dies, the ordinary supervision path only learns of
# it indirectly (a stale-pane wedge timer, or the next liveness sweep), long
# after the evidence in the pane has scrolled away. This library captures that
# evidence the moment the watcher observes a dead pane: it writes the last ~20
# pane lines to state/<id>.crash-tail and enqueues one durable `check` wake with
# payload `pane-crashed <id>`, so recovery starts with the crash tail in hand
# rather than a blank reconstruction.
#
# Ownership and reuse (no duplicated contracts):
#   - The wake-queue record format is owned by fm_wake_append
#     (bin/fm-wake-lib.sh). This library NEVER hand-writes the queue; it calls
#     that one enqueue owner.
#   - The dead-pane verdict and the pane tail read are owned by the herdr
#     adapter (bin/backends/herdr.sh), reached through the backend dispatch in
#     bin/fm-backend.sh (fm_backend_agent_alive, fm_backend_capture).
#   - state/<id>.meta is the task-tracked lifecycle marker; an absent meta means
#     the pane is untracked or already torn down, which is not an incident.
#
# No side effects on source. Sourced by bin/fm-watch.sh, which has already
# sourced bin/fm-backend.sh and bin/fm-wake-lib.sh, so this library assumes both
# fm_backend_* and fm_wake_append are already defined and does not re-source
# them (the same in-caller-context pattern the other watcher helper libraries
# use). Torn down with the task by bin/fm-teardown.sh, which removes
# state/<id>.crash-tail alongside the other per-task state files.

# fm_pane_crash_capture <backend> <window> <task-id> <state-dir>
# On a CONFIRMED dead herdr pane for a task that still has state/<id>.meta,
# write the last ~20 pane lines to state/<id>.crash-tail and enqueue exactly one
# `check` wake with payload `pane-crashed <id>`. Silent, idempotent no-op in
# every other case:
#   - backend is not herdr (the only backend this task targets today);
#   - no state/<id>.meta (untracked or already-torn-down pane);
#   - the pane is not confidently dead (a transient capture error, or a live
#     but momentarily unreadable pane, must never fabricate a crash);
#   - state/<id>.crash-tail already exists (a second detection of the same death
#     must not double-enqueue or clobber the tail already captured).
# Prints the literal string `captured` on stdout ONLY when this call freshly
# recorded a crash-tail AND enqueued the wake, so the caller can end its
# supervision cycle exactly once per death. Prints nothing on every no-op.
# Returns 0 on a fresh capture-and-enqueue and on every silent no-op; a non-zero
# return means the enqueue itself failed, in which case the crash-tail is rolled
# back (removed) so the next supervision cycle retries the detection.
FM_PANE_CRASH_TAIL_LINES=${FM_PANE_CRASH_TAIL_LINES:-20}
fm_pane_crash_capture() {  # <backend> <window> <task-id> <state-dir>
  local backend=$1 window=$2 id=$3 state=$4 meta crash_tail alive tail tmp

  # Herdr backend only. Every other backend is a silent no-op: no crash-tail, no
  # wake, no error.
  [ "$backend" = herdr ] || return 0

  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 0 ;;
  esac
  [ -n "$state" ] || return 0

  # An untracked or already-torn-down pane is not an incident.
  meta="$state/$id.meta"
  [ -f "$meta" ] || return 0

  # Idempotency: a crash-tail already captured for this death is authoritative;
  # never clobber it and never enqueue a second wake for the same pane.
  crash_tail="$state/$id.crash-tail"
  [ -e "$crash_tail" ] && return 0

  # Only a CONFIDENTLY dead pane records a crash. `unknown` (an unreadable or
  # ambiguous read) is deliberately treated as not-a-crash, so a transient herdr
  # hiccup never fabricates a crash-tail or a wake.
  alive=$(fm_backend_agent_alive "$backend" "$window" 2>/dev/null) || alive=unknown
  [ "$alive" = dead ] || return 0

  # Best-effort tail capture: a reaped pane may return nothing, so an empty read
  # is still recorded (the wake itself is the primary signal; the tail is the
  # evidence when the pane is still readable at detection time).
  tail=$(fm_backend_capture "$backend" "$window" "$FM_PANE_CRASH_TAIL_LINES" "fm-$id" 2>/dev/null) || tail=

  mkdir -p "$state" || return 0
  tmp="$crash_tail.tmp.$$"
  # A crash-tail that appeared concurrently between the check above and now wins;
  # do not clobber it and do not enqueue a duplicate wake. The hard-link publish
  # gives create-if-absent semantics, so two concurrent detections cannot both
  # claim the capture.
  if printf '%s\n' "$tail" > "$tmp" 2>/dev/null; then
    if ! ln "$tmp" "$crash_tail" 2>/dev/null; then
      rm -f "$tmp"
      return 0
    fi
    rm -f "$tmp"
  else
    rm -f "$tmp"
    return 0
  fi

  # Enqueue exactly one durable wake through the queue's one owner. On enqueue
  # failure remove the just-published crash-tail so the idempotency guard does
  # not block the next stale-loop cycle from retrying this detection; otherwise
  # a confirmed crash would capture evidence but never trigger recovery.
  if ! fm_wake_append check "pane-crashed-$id" "pane-crashed $id"; then
    rm -f "$crash_tail"
    return 1
  fi
  printf 'captured'
}
