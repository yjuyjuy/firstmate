#!/usr/bin/env bash
# fm-afk-driver.sh - the away-mode autonomous queue-advancing driver.
#
# WHY THIS EXISTS. The away-mode sub-supervisor (bin/fm-supervise-daemon.sh)
# NOTIFIES: it classifies each wake and escalates a digest so firstmate's own
# agent turn drives the fleet. That contract has a hole with no owner. When
# firstmate is not taking turns - the paneless reader died, or the captain is away
# for hours between turns - nothing mechanical advances: a finished lane is never
# cleaned up, a lane stalled just before its push is never nudged, and queued work
# whose blocker cleared is never dispatched. Evidence 2026-07-30: the fleet coasted
# roughly 9.5 hours overnight while the daemon escalated correctly into an outbox
# nobody was reading (state/.afk-outbox held 9 unread records and the reader's
# liveness beacon was 34522s stale).
#
# So this driver does the MECHANICAL, non-judgment part of what firstmate would do
# on each wake, on a cadence, while away mode is active. It never takes a decision
# that belongs to the captain, and it never widens away mode's approval authority.
#
# WHAT ONE TICK DOES, in order:
#   1. Clean up finished lanes. For every ship or scout task whose reconciled
#      current state (bin/fm-crew-state.sh) is done, and whose branch is verified
#      present on origin (git ls-remote), run bin/fm-teardown.sh. Teardown owns the
#      complete landed-work test and refuses uncommitted or genuinely unpushed and
#      unlanded work, so a refusal is reported as a fact and never worked around.
#      --force is never passed.
#      A branch on origin is NOT proof of finished delivery: a lane whose
#      no-mistakes run is still active and has not opened its PR yet is held and
#      reported once, never torn down mid-pipeline. The doclint two-run pass
#      (bin/fm-doclint-batch.sh) pushes its branch inside its second delivery run
#      and only opens the PR steps later, so a pushed branch can still be
#      mid-delivery (observed 2026-09-02: two doclint lanes were reaped between
#      push and PR, stranding the branches on origin with no delivery).
#   2. Nudge a lane that finished but never pushed. A done lane whose branch is
#      ABSENT from origin is steered ONCE with bin/fm-send.sh to finish its own
#      delivery flow. The driver never pushes project code itself: the lane's own
#      agent owns its push. The steer is recorded so later ticks do not re-send it.
#   3. Dispatch queued work that needs no judgment. While live active workers are
#      below the worker cap and the host has headroom, dispatch the next
#      `tasks-axi ready` item that ALREADY has both a complete brief (data/<id>/brief.md
#      with no {TASK} placeholder left) and a recorded dispatch recipe
#      (data/<id>/dispatch, see DISPATCH RECIPE below). Anything else is reported as
#      a fact for firstmate and never auto-dispatched.
#   4. Report what moved. Every action, refusal, and skipped-because reason is
#      written to a durable spool the moment it happens and drained into ONE
#      away-mode outbox record, so the captain's catch-up shows what the driver did
#      while they were away. The spool, not an in-memory list, is the source of that
#      record: a tick the daemon's watchdog stops after acting leaves its facts
#      there and the next tick reports them.
#   5. Surface a dead escalation reader. bin/fm-afk-reader-check.sh's condition is
#      re-checked each tick and printed, which reaches the daemon log rather than
#      the outbox: when that condition holds, the outbox is precisely the channel
#      nobody is reading. The driver never arms a reader itself - that script's
#      header owns why arming must stay firstmate's own action - so session start
#      remains the path that heals the channel.
#
# HARD BOUNDARIES. The driver has exactly firstmate's own away-mode authority and
# not one step more:
#   - It never merges anything, on any forge or locally.
#   - It never forces, discards, stashes, resets, or resolves a conflict, and it
#     never passes --force to teardown.
#   - It never writes to a project: its only project commands are the read-only
#     git probes it needs (rev-parse, ls-remote), and bin/fm-teardown.sh's own
#     guarded cleanup.
#   - It never dispatches work without a complete brief and a recorded recipe.
#   - It never exceeds the worker cap (hard maximum 4, whatever is configured) or
#     dispatches while the host reads degraded or critical.
#   - Money, destructive, irreversible, and security-sensitive decisions are not
#     its business at all: those keep escalating and waiting for the captain.
#   - It refuses to run unless away mode is active (state/.afk present).
#   - It is idempotent. A tick over unchanged state takes no action and appends no
#     record, and a per-tick lock means two ticks never overlap.
#
# DISPATCH RECIPE - this header owns the format. data/<id>/dispatch is a plain
# key=value file, one pair per line, written by firstmate when it queues work it
# wants the away-mode driver to be able to start without a human turn:
#   project=<path>          REQUIRED. The clone to work in, absolute or relative
#                           to FM_HOME (normally projects/<name>).
#   harness=<name>          optional explicit harness/profile adapter.
#   model=<name>            optional model axis.
#   effort=<level>          optional effort axis.
#   kind=scout              optional; anything else means an ordinary ship spawn.
# A recipe missing project=, or naming a project directory that does not exist, is
# not dispatchable: the item is reported for firstmate instead. Absent file means
# the same. The recipe exists so the driver never has to INVENT a dispatch
# decision - firstmate records the decision in advance, and the driver only fires
# it once the dependency and host gates clear.
#
# ACTIVE WORKER. Every recorded ship or scout task counts against the cap unless
# its reconciled state is done. failed and unknown count too, deliberately: a task
# whose state cannot be reconciled may still hold a live endpoint and a memory
# slot, and the safe direction for a cap is to OVERCOUNT. Dispatching one item late
# costs a delay; undercounting starts a fifth worker on a machine sized for four.
#
# Usage: fm-afk-driver.sh tick [--dry-run]
#        fm-afk-driver.sh --help
#   tick        run one bounded pass (the away daemon's housekeeping calls this)
#   --dry-run   print the actions the tick WOULD take and mutate nothing: no
#               teardown, no steer, no dispatch, no marker, no outbox record
#
# Exit status:
#   0  the tick ran (whether or not it acted), or --dry-run/--help
#   1  an internal failure the caller should log
#   3  refused: away mode is not active, or the driver is switched off
#   4  another tick holds the per-tick lock; nothing was done
#
# Environment:
#   FM_HOME                     the firstmate home whose fleet this tick advances
#   FM_AFK_DRIVER_MAX_WORKERS   worker cap (default 4; values above 4 clamp to 4)
#   FM_AFK_DRIVER_DISABLE=1     switch the driver off for this home (exit 3)
#   FM_AFK_DRIVER_TICK_SECS     cadence, read by the DAEMON's housekeeping gate
#                               rather than by this script (default 600)
#   FM_STATE_OVERRIDE           alternate state dir (testing)
#   FM_ROOT_OVERRIDE            alternate script root (testing)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="$FM_HOME/data"

# shellcheck source=bin/fm-afk-outbox-lib.sh
. "$SCRIPT_DIR/fm-afk-outbox-lib.sh"

WORKER_CAP_HARD=4
# Durable spool of this tick's facts, drained into one outbox record. It exists so
# a tick stopped by the daemon's watchdog still reports what it already did.
FACT_SPOOL_NAME=".afk-driver-facts"
DRY_RUN=0
ACTIONS=()

usage() {
  awk '/^# Usage:/ { show = 1 } show && /^#/ { sub(/^# ?/, ""); print; next } show { exit }' \
    "${BASH_SOURCE[0]}"
}

# Every fact is written to the durable spool the MOMENT its action completed, not
# only collected in memory for the end-of-tick report. A tick can be stopped by the
# daemon's own timeout watchdog mid-pass, and an action that already happened - a
# lane cleaned up, an agent nudged, work started - must still reach the captain's
# catch-up. The spool is drained into one outbox record at the end of this tick, or
# by the next tick when this one did not get that far.
note() {  # <text> - one captain-facing fact about this tick
  ACTIONS+=("$1")
  [ "$DRY_RUN" -eq 1 ] || printf '%s\n' "$1" >> "$STATE/$FACT_SPOOL_NAME" 2>/dev/null || true
  printf 'driver: %s\n' "$1"
}

meta_value() {  # <meta-file> <key>
  awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1" 2>/dev/null
}

marker_key() {  # <task-id> - filesystem-safe marker suffix
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# Report one condition once. <kind> is a STABLE condition name and <task-key> the
# task it concerns, so a marker records the condition rather than the exact wording:
# every one of these reports embeds a tool's own last output line as evidence, and
# keying on that text would re-report the same unchanged condition on every tick as
# soon as a path, a count, or a timestamp inside it moved. Returns 0 when the
# condition is new for this task and the caller should report it, 1 when it was
# already reported and this tick must stay silent about it.
report_once() {  # <kind> <task-key> <text>
  local kind=$1 key=$2 text=$3 marker="$STATE/.afk-driver-noted-$2-$1"
  if [ -e "$marker" ]; then
    return 1
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    printf '%s\n' "$text" > "$marker" 2>/dev/null || true
  fi
  return 0
}

# Forget every condition recorded for a task, so a lane that genuinely moved on
# reports its next condition instead of staying silent behind a stale marker.
forget_notes() {  # <task-key>
  [ "$DRY_RUN" -eq 1 ] && return 0
  rm -f "$STATE/.afk-driver-noted-$1"-* 2>/dev/null || true
}

worker_cap() {
  local cap=${FM_AFK_DRIVER_MAX_WORKERS:-$WORKER_CAP_HARD}
  case "$cap" in
    ''|*[!0-9]*) cap=$WORKER_CAP_HARD ;;
  esac
  [ "$cap" -le "$WORKER_CAP_HARD" ] || cap=$WORKER_CAP_HARD
  printf '%s' "$cap"
}

# The reconciled current state word for a task, via the deterministic reader.
# Never a tail of the status log: that is an event history, not current state.
crew_state() {  # <task-id>
  local out
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-crew-state.sh" "$1" 2>/dev/null) || return 1
  printf '%s' "$out" | awk '{ for (i = 1; i < NF; i++) if ($i == "state:") { print $(i + 1); exit } }'
}

# --- step 1 and 2: finished lanes -------------------------------------------

# The driver must never treat a pushed branch as proof of finished delivery.
# fm-crew-state.sh resolves run-step attribution through `no-mistakes runs`
# (that script owns the attribution rules and this probe only reuses its row
# format), but its answer degrades to the status log when attribution misses, so
# the driver asks the pipeline itself before it tears a done lane down. The
# bounded call below mirrors fm-crew-state.sh's nm_run pattern in miniature; it
# cannot be sourced because that script executes top to bottom.
NM_RUNS_LIMIT=200
NM_CALL_TIMEOUT=10

# 0 = HOLD cleanup, 1 = safe to proceed. A lane is held when the pipeline state
# for its branch shows a run that is active and has not opened a PR yet, or when
# the pipeline state cannot be read at all: unverifiable delivery never
# destroys a live pipeline (fail closed, the same bias as the worker-cap
# overcount). Terminal runs and runs whose PR is already open are delivered or
# over, so they proceed exactly as before. A host without the no-mistakes CLI
# has no pipeline that could be mid-run and proceeds too.
lane_pipeline_holds_cleanup() {  # <worktree> <branch>
  local wt=$1 branch=$2 head out rc=0 row st rest br sha full tcmd
  command -v no-mistakes >/dev/null 2>&1 || return 1
  head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  tcmd=timeout
  command -v timeout >/dev/null 2>&1 || tcmd=gtimeout
  command -v "$tcmd" >/dev/null 2>&1 || return 0
  out=$(cd "$wt" && "$tcmd" "$NM_CALL_TIMEOUT" no-mistakes runs --limit "$NM_RUNS_LIMIT" 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return 0
  while IFS= read -r row; do
    row=$(printf '%s' "$row" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$row" ] || continue
    st=${row%% *}
    rest=${row#* }
    rest=$(printf '%s' "$rest" | sed 's/^[[:space:]]*//')
    br=${rest%% *}
    [ "$br" = "$branch" ] || continue
    rest=${rest#* }
    rest=$(printf '%s' "$rest" | sed 's/^[[:space:]]*//')
    sha=${rest%% *}
    # Same code-identity rule fm-crew-state.sh applies: only a row whose head
    # matches this worktree (equal, or the worktree head is an ancestor of the
    # run tip) counts for this lane, so a rewritten or reused branch never
    # attributes a foreign or dead run to it.
    full=$(git -C "$wt" rev-parse --verify "${sha}^{commit}" 2>/dev/null) || continue
    [ "$full" = "$head" ] \
      || git merge-base --is-ancestor "$head" "$full" >/dev/null 2>&1 || continue
    case "$st" in
      completed|failed|cancelled) return 1 ;;
      # Still active: delivered only once the run's row carries its PR url.
      *) printf '%s' "$row" | grep -qE 'https?://' && return 1 || return 0 ;;
    esac
  done <<< "$out"
  return 1
}

# Advance ONE done lane: clean it up when its branch is durable on origin AND
# its delivery pipeline, if any, is finished or already opened its PR; hold it
# while a no-mistakes run is still active; steer it once when it finished
# without pushing.
advance_done_lane() {  # <task-id> <worktree>
  local id=$1 wt=$2 key branch out rc
  key=$(marker_key "$id")
  if [ ! -d "$wt" ]; then
    # No worktree left to inspect: an already-cleaned lane, nothing to advance.
    return 0
  fi
  branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [ -z "$branch" ] || [ "$branch" = HEAD ]; then
    # A detached HEAD cannot be probed by branch name, and deciding what its
    # commit belongs to is a judgment call. Report it once and leave it alone.
    report_once detached-head "$key" \
      "$id finished on a detached HEAD; firstmate must decide where that commit belongs" \
      && note "$id finished on a detached HEAD; left alone for firstmate"
    return 0
  fi
  rc=0
  git -C "$wt" ls-remote --exit-code origin "refs/heads/$branch" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0)
      if lane_pipeline_holds_cleanup "$wt" "$branch"; then
        report_once pipeline-active "$key" \
          "$id has an active or unverifiable no-mistakes run; cleanup held until its delivery finishes" \
          && note "held cleanup for $id: its no-mistakes delivery is still active or unverifiable, so the branch on origin is not treated as delivered"
        return 0
      fi
      if [ "$DRY_RUN" -eq 1 ]; then
        note "would clean up $id (branch $branch is on origin)"
        return 0
      fi
      if out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
        "$SCRIPT_DIR/fm-teardown.sh" "$id" 2>&1); then
        forget_notes "$key"
        rm -f "$STATE/.afk-driver-steered-$key"
        note "cleaned up $id (branch $branch durable on origin)"
      else
        report_once cleanup-refused "$key" \
          "cleanup refused for $id: $(printf '%s' "$out" | tail -n 1)" \
          && note "cleanup refused for $id, work left untouched: $(printf '%s' "$out" | tail -n 1)"
      fi
      ;;
    2)
      # The branch is genuinely absent from origin: the lane finished its work but
      # never completed its own delivery flow. Steering its agent is the only safe
      # move - the driver must not push project code.
      if [ -e "$STATE/.afk-driver-steered-$key" ]; then
        return 0
      fi
      if [ "$DRY_RUN" -eq 1 ]; then
        note "would steer $id to finish pushing $branch"
        return 0
      fi
      if out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
        "$SCRIPT_DIR/fm-send.sh" "$id" \
        "finish your delivery flow: branch $branch is not on origin yet - push it and report the result" 2>&1); then
        date +%s > "$STATE/.afk-driver-steered-$key"
        note "steered $id to finish pushing $branch"
      else
        report_once steer-failed "$key" \
          "could not steer $id: $(printf '%s' "$out" | tail -n 1)" \
          && note "could not reach $id to ask it to push $branch: $(printf '%s' "$out" | tail -n 1)"
      fi
      ;;
    *)
      # An ls-remote that failed for any other reason (no remote, offline, auth)
      # proves nothing about durability, so the lane is left exactly as it is.
      report_once origin-unreachable "$key" \
        "origin unreachable for $id ($branch); durability unknown" \
        && note "could not check whether $id's work reached origin; left untouched"
      ;;
  esac
}

# --- step 3: dispatch --------------------------------------------------------

# Ready task ids, oldest-first, from the backlog backend. Silent when the backend
# is absent or errors: an unreadable queue is never a dispatch signal.
ready_ids() {
  command -v tasks-axi >/dev/null 2>&1 || return 0
  (cd "$FM_HOME" 2>/dev/null && tasks-axi ready 2>/dev/null) |
    awk '/^ready\[/ { in_ready = 1; next }
         /^[a-z_]+\[/ { in_ready = 0 }
         in_ready && /^  [^ ]/ { sub(/^  /, ""); sub(/,.*$/, ""); print }'
}

brief_is_complete() {  # <task-id>
  local brief="$DATA/$1/brief.md"
  [ -s "$brief" ] || return 1
  grep -Fq '{TASK}' "$brief" && return 1
  return 0
}

# Resolve a recipe into the concrete fm-spawn arguments, echoed one per line.
# Returns 1 when the recipe is absent or incomplete, so the item is reported for
# firstmate rather than dispatched on a guess.
recipe_args() {  # <task-id>
  local id=$1 recipe="$DATA/$1/dispatch" project harness model effort kind
  [ -s "$recipe" ] || return 1
  project=$(meta_value "$recipe" project)
  [ -n "$project" ] || return 1
  case "$project" in
    /*) ;;
    *) project="$FM_HOME/$project" ;;
  esac
  [ -d "$project" ] || return 1
  harness=$(meta_value "$recipe" harness)
  model=$(meta_value "$recipe" model)
  effort=$(meta_value "$recipe" effort)
  kind=$(meta_value "$recipe" kind)
  printf '%s\n' "$id" "$project"
  [ -z "$harness" ] || printf '%s\n' --harness "$harness"
  [ -z "$model" ] || printf '%s\n' --model "$model"
  [ -z "$effort" ] || printf '%s\n' --effort "$effort"
  [ "$kind" = scout ] && printf '%s\n' --scout
  return 0
}

# The host's own reading decides whether another worker may start. A degraded or
# critical host holds dispatch; an unknown or disabled reading is no signal at all
# and never blocks, exactly as every other consumer of that probe treats it.
host_has_headroom() {
  local rc=0
  [ -x "$SCRIPT_DIR/fm-resource-check.sh" ] || return 0
  "$SCRIPT_DIR/fm-resource-check.sh" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    1|2) return 1 ;;
    *) return 0 ;;
  esac
}

dispatch_ready_work() {  # <active-worker-count>
  local active=$1 cap id key out line held=0
  local -a args=()
  cap=$(worker_cap)
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ -e "$STATE/$id.meta" ] && continue
    if [ "$active" -ge "$cap" ]; then
      held=$((held + 1))
      continue
    fi
    key=$(marker_key "$id")
    if ! brief_is_complete "$id"; then
      report_once brief-incomplete "$key" "$id is ready but has no complete brief" \
        && note "$id is ready to start but still needs instructions written; left for firstmate"
      continue
    fi
    args=()
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      args+=("$line")
    done < <(recipe_args "$id")
    if [ "${#args[@]}" -lt 2 ]; then
      report_once recipe-missing "$key" "$id is ready but has no dispatch recipe" \
        && note "$id is ready to start but firstmate has not recorded how to start it; left for firstmate"
      continue
    fi
    if ! host_has_headroom; then
      report_once host-pressure fleet "host under pressure; dispatch held" \
        && note "the machine is under pressure, so queued work is waiting rather than starting"
      return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      note "would start $id"
      active=$((active + 1))
      continue
    fi
    if out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-spawn.sh" "${args[@]}" 2>&1); then
      forget_notes "$key"
      note "started $id"
      active=$((active + 1))
    else
      report_once spawn-failed "$key" "could not start $id: $(printf '%s' "$out" | tail -n 1)" \
        && note "could not start $id: $(printf '%s' "$out" | tail -n 1)"
    fi
  done < <(ready_ids)
  if [ "$held" -gt 0 ]; then
    report_once worker-cap fleet "cap reached with $held item(s) waiting" \
      && note "$held queued item(s) are waiting because the fleet is already at its worker limit"
  else
    forget_notes fleet
  fi
}

# --- reader liveness ---------------------------------------------------------

# Surface a dead escalation reader on the daemon's own log, where a human reading
# an incident will find it, rather than as an outbox fact: the outbox is exactly
# the channel nobody is reading when this condition holds, so reporting it there
# would be a message to the failure itself. Arming a reader is deliberately NOT
# done here - bin/fm-afk-reader-check.sh's header owns why that must stay
# firstmate's own action - and session start acts on the same check.
report_reader_liveness() {
  local out
  [ -x "$SCRIPT_DIR/fm-afk-reader-check.sh" ] || return 0
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-afk-reader-check.sh" 2>/dev/null || true)
  [ -n "$out" ] || return 0
  printf '%s\n' "$out"
  return 0
}

# --- one tick ----------------------------------------------------------------

# Drain the durable fact spool into ONE outbox record. The spool, not the in-memory
# list, is the source: a previous tick that the watchdog stopped after acting leaves
# its facts there, and they must still reach the captain rather than be lost with
# the process that performed them. The spool is cleared only after the record is
# safely appended.
report_actions() {
  local spool="$STATE/$FACT_SPOOL_NAME" digest
  [ "$DRY_RUN" -eq 1 ] && return 0
  [ -s "$spool" ] || return 0
  digest="away-mode driver: $(tr '\n' ';' < "$spool" | sed 's/;$//; s/;/; /g')"
  fm_afk_outbox_append "$STATE" driver "$digest" || return 1
  rm -f "$spool"
  return 0
}

run_tick() {
  local meta lane id kind wt st active=0 rc=0
  local -a done_lanes=()
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta"); id=${id%.meta}
    kind=$(meta_value "$meta" kind)
    case "$kind" in
      secondmate) continue ;;
    esac
    st=$(crew_state "$id") || st=
    if [ "$st" = "done" ]; then
      done_lanes+=("$id"$'\t'"$(meta_value "$meta" worktree)")
      continue
    fi
    # Everything else counts against the cap, including failed and unknown. A
    # recorded task whose state cannot be reconciled may still be holding a live
    # endpoint and a memory slot, and the safe direction for a cap is to
    # OVERCOUNT: a tick that dispatches one item late costs a delay, while one
    # that undercounts starts a fifth worker on a machine sized for four.
    active=$((active + 1))
  done

  for lane in "${done_lanes[@]:-}"; do
    [ -n "$lane" ] || continue
    id=${lane%%$'\t'*}
    wt=${lane#*$'\t'}
    advance_done_lane "$id" "$wt"
  done

  dispatch_ready_work "$active"
  report_reader_liveness
  report_actions || rc=1
  return "$rc"
}

main() {
  local lock rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      tick) ;;
      --dry-run) DRY_RUN=1 ;;
      -h|--help) usage; return 0 ;;
      *) printf 'fm-afk-driver: unknown argument %s\n' "$1" >&2; usage >&2; return 1 ;;
    esac
    shift
  done

  if [ "${FM_AFK_DRIVER_DISABLE:-0}" = 1 ]; then
    printf 'fm-afk-driver: disabled for this home (FM_AFK_DRIVER_DISABLE=1)\n' >&2
    return 3
  fi
  if [ ! -e "$STATE/.afk" ]; then
    printf 'fm-afk-driver: refusing to run - away mode is not active for this home\n' >&2
    return 3
  fi

  # Per-tick lock: a slow tick must never overlap the next one, and the driver's
  # idempotence guarantee is about repeated SEQUENTIAL ticks, not concurrent ones.
  fm_afk_outbox_lock_lib "$STATE" || return 1
  lock="$STATE/.afk-driver.lock"
  if ! fm_lock_try_acquire "$lock"; then
    printf 'fm-afk-driver: another tick is running (lock %s)\n' "$lock" >&2
    return 4
  fi
  run_tick || rc=1
  fm_lock_release "$lock"
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
