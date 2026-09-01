#!/usr/bin/env bash
# fm-release-lsp.sh - reclaim the memory a PARKED or DEAD lane's language server
# holds, WITHOUT touching the agent process or the worktree.
#
# WHY THIS EXISTS. On a memory-bound host a typescript-language-server (and its
# kin: tsserver, rust-analyzer, gopls, pyright, ...) commonly costs ~1 GB, often
# roughly double the agent process that spawned it. When a lane is deliberately
# PARKED (idling on a long declared external wait) or its agent is DEAD (endpoint
# gone), that language server is pure dead weight: nothing is editing code, so
# nothing needs the server, yet it keeps its footprint until the kernel pages it
# out or it exits. Two such servers were reclaimed BY HAND on 2026-07-24 and
# moved swap from 78% to 69%. This makes that reclaim repeatable and safe instead
# of a manual hunt through the process table.
#
# THE HARD SAFETY CONSTRAINT - the whole point of this script. It NEVER touches a
# LIVE lane's language server. A language server is released ONLY when its lane is
# one of:
#   (a) PARKED  - fm-crew-state.sh reports the lane's authoritative current state
#                 is `paused` (a declared external-wait `paused:` line, the
#                 fm-classify-lib.sh FM_CLASSIFY_PAUSED_VERB); or
#   (b) DEAD    - fm-backend.sh's fm_backend_endpoint_live returns a CONFIDENT
#                 `dead` for the lane's recorded endpoint.
# A lane that is actively working, briefly waiting (heavy-run queue, CI, a short
# bounded wait -> it reports with working: lines, so fm-crew-state.sh reads it as
# working, never paused), blocked on a captain decision, parked at a no-mistakes
# gate (fm-crew-state.sh `parked`, distinct from `paused`), finished, failed, or
# whose state cannot be resolved, keeps its server UNTOUCHED. Getting this wrong
# kills a working developer's tooling mid-task, so the default under ANY
# uncertainty is to NOT kill - the same conservative default fm-resource-check.sh
# and the secondmate-liveness sweep use.
#
# Lane state is read the DURABLE way, not a flaky live probe of the pane: the
# status-event classifier (bin/fm-classify-lib.sh) reconciled through
# bin/fm-crew-state.sh, the same file-only, last-event-wins read
# bin/fm-resource-check.sh's exclude-blocked/parked-crews logic uses. Endpoint
# liveness is fm_backend_endpoint_live, the same CONFIDENT verdict the live-lane
# count trusts (only a confident `dead` ever qualifies a lane; alive and unknown
# never do).
#
# OWNERSHIP IS NOT RE-DERIVED HERE. Which language server belongs to which lane is
# answered by bin/fm-memory-report.sh, the one command that attributes process
# ownership from durable records the same way every time (worktree path against
# state/*.meta, never a guess from a path's shape or from ancestry). This script
# consumes its --json and acts ONLY on processes it reports as owner_kind=task,
# kind=lsp for an eligible lane. If fm-memory-report REFUSES (a broken reading) or
# raises its attribution warning (the wrong-home signature), this script aborts
# and kills nothing - acting on ownership the report itself distrusts is exactly
# the incident that report exists to prevent.
#
# A RELEASED SERVER RESPAWNS ON DEMAND. Language servers are spawned by the
# editor/agent tooling when a file is next opened, so releasing one does not break
# a lane that later resumes; it transparently gets a fresh server. This is
# existing, verified tooling behavior (data/learnings host-resources: "Killing
# editor LSP helpers is safe (respawn on demand next edit)"), not something this
# script arranges.
#
# IDEMPOTENT AND SAFE TO RE-RUN. A lane with no language server, or one already
# released, is a no-op: a pid that is already gone is skipped, never an error.
#
# Usage:
#   fm-release-lsp.sh              release eligible lanes' language servers, report
#   fm-release-lsp.sh --dry-run    report what WOULD be released; kill nothing
#   fm-release-lsp.sh --json       machine-readable report of what was released
#   fm-release-lsp.sh --help
#
# Exit status:
#   0  ran; a reading was taken and any eligible servers released (including the
#      no-op case where nothing qualified)
#   1  a required input could not be collected at all
#   3  REFUSED - ownership could not be stood behind (fm-memory-report refused or
#      warned); nothing was released
#   64 usage error. Deliberately NOT 2, matching fm-resource-check.sh's reasoning
#      that a caller might read 2 as a resource state.
#
# Test seams (a test injects these so no assertion depends on the real machine or
# on real processes being killed):
#   FM_RELEASE_LSP_MEMJSON     read the memory-report JSON from this file instead
#                              of invoking bin/fm-memory-report.sh
#   FM_RELEASE_LSP_MEMREPORT   run this instead of the sibling bin/fm-memory-report.sh
#                              (invoked as "<bin> --json"), so a test exercises the
#                              refuse/fail propagation of a real exit code
#   FM_RELEASE_LSP_STATE_BIN   crew-state reader to run per id (default: the
#                              sibling bin/fm-crew-state.sh); called as
#                              "<bin> <id>", must print a "state: ..." line
#   FM_RELEASE_LSP_ENDPOINT_BIN  endpoint-liveness reader; called as
#                              "<bin> <id> <backend> <target>", must print
#                              alive|dead|unknown (default: fm_backend_endpoint_live)
#   FM_RELEASE_LSP_KILL_LOG    when set, "killed" pids are appended here instead of
#                              being signalled, so a test verifies the exact pid
#                              set with no real process
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# FM_ROOT/FM_HOME/STATE and die (canonical exit 1 default) come from the shared preamble.
FM_PROG=fm-release-lsp
# shellcheck source=bin/fm-preamble-lib.sh
. "$SCRIPT_DIR/fm-preamble-lib.sh"

MEMREPORT="${FM_RELEASE_LSP_MEMREPORT:-$SCRIPT_DIR/fm-memory-report.sh}"
CREW_STATE_BIN="${FM_RELEASE_LSP_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"

# fm-backend.sh supplies fm_backend_of_meta, fm_backend_target_of_meta and
# fm_backend_endpoint_live. Sourcing it defines functions only. When it cannot be
# sourced (an unusual environment) every endpoint verdict degrades to unknown,
# which - being neither a confident dead nor a paused verdict - keeps the lane
# ineligible, the conservative default.
BACKEND_OK=1
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh" 2>/dev/null || BACKEND_OK=0

usage() {
  awk 'NR==1 { next } /^[^#]/ { exit } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

refuse() {  # <reason> <detail>...
  local reason=$1
  shift
  {
    printf 'fm-release-lsp: REFUSING to release - ownership cannot be stood behind.\n'
    printf '  problem: %s\n' "$reason"
    local line
    for line in "$@"; do printf '  %s\n' "$line"; done
    printf '  Nothing was released. Acting on ownership the memory report itself\n'
    printf '  distrusts is the exact hazard that report exists to prevent.\n'
  } >&2
  exit 3
}

# --- argument parsing -------------------------------------------------------

mode=text
dry_run=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --dry-run) dry_run=1 ;;
    --json) mode=json ;;
    *) die "unknown option '$1' (see --help)" 64 ;;
  esac
  shift
done

# --- ownership from fm-memory-report ----------------------------------------

# The memory-report JSON, either injected (test seam) or read from the real
# script. Prints the JSON on stdout and returns:
#   0  ok, JSON on stdout
#   3  the memory report REFUSED its own reading (exit 3) - ownership unavailable
#   1  any other collection failure
# The caller (not this function) turns 3 into a refusal and 1 into a die, because
# this runs inside a command substitution where an exit would only leave the
# subshell.
collect_memjson() {
  if [ -n "${FM_RELEASE_LSP_MEMJSON:-}" ]; then
    [ -r "$FM_RELEASE_LSP_MEMJSON" ] || return 1
    cat "$FM_RELEASE_LSP_MEMJSON"
    return 0
  fi
  [ -x "$MEMREPORT" ] || return 1
  local out rc
  out=$(FM_HOME="$FM_HOME" "$MEMREPORT" --json 2>/dev/null)
  rc=$?
  [ "$rc" -eq 3 ] && return 3
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$out"
}

MEMJSON=$(collect_memjson)
COLLECT_RC=$?
case "$COLLECT_RC" in
  0) : ;;
  3) refuse "the memory report refused its own reading (exit 3)" \
       "re-run bin/fm-memory-report.sh to see why the reading is not trustworthy" ;;
  *) die "could not collect ownership from bin/fm-memory-report.sh" ;;
esac
[ -n "$MEMJSON" ] || die "the memory report produced no output"

# The wrong-home signature: fm-memory-report resolved ownership against records
# that do not describe the running processes. Its own reclaim list is not to be
# acted on, and neither is ours.
if printf '%s\n' "$MEMJSON" | grep -q '"attribution_warning": "'; then
  refuse "the memory report raised its attribution warning (likely the wrong home)" \
    "re-run bin/fm-memory-report.sh and read the ATTRIBUTION LOOKS WRONG banner"
fi

# Every task-owned language server, as "pid<TAB>owner-id<TAB>footprint_kb". This is
# the ONLY set of processes this script will ever consider killing: owner_kind is
# exactly task and kind is exactly lsp. An agent process (kind=agent) can never
# match, so the agent is structurally excluded from the candidate set.
lsp_rows() {
  printf '%s\n' "$MEMJSON" | awk '
    /"kind":"lsp"/ && /"owner_kind":"task"/ {
      pid=""; owner=""; fp="0"
      if (match($0, /"pid":[0-9]+/)) pid = substr($0, RSTART + 6, RLENGTH - 6)
      if (match($0, /"footprint_kb":[0-9]+/)) fp = substr($0, RSTART + 15, RLENGTH - 15)
      if (match($0, /"owner":"[^"]*"/)) owner = substr($0, RSTART + 9, RLENGTH - 10)
      if (pid != "" && owner != "") printf "%s\t%s\t%s\n", pid, owner, fp
    }
  '
}

LSP_ROWS=$(lsp_rows)

# --- per-lane eligibility ---------------------------------------------------

# Endpoint liveness for one lane: alive|dead|unknown. Only a CONFIDENT dead ever
# qualifies a lane as DEAD-eligible; alive and unknown never do.
endpoint_verdict() {  # <id> <backend> <target>
  if [ -n "${FM_RELEASE_LSP_ENDPOINT_BIN:-}" ]; then
    "$FM_RELEASE_LSP_ENDPOINT_BIN" "$1" "$2" "$3" 2>/dev/null || printf 'unknown'
    return 0
  fi
  [ "$BACKEND_OK" = 1 ] || { printf 'unknown'; return 0; }
  [ -n "$3" ] || { printf 'unknown'; return 0; }
  fm_backend_endpoint_live "$2" "$3" 2>/dev/null || printf 'unknown'
}

# Authoritative current state token for one lane, from fm-crew-state.sh's one
# canonical line ("state: <s> · source: <src> · <detail>").
crew_state_token() {  # <id>
  local line
  line=$("$CREW_STATE_BIN" "$1" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'unknown'; return 0 ;; esac
  line=${line#state: }
  printf '%s' "${line%% *}"
}

# Classify a lane: prints "dead", "parked", or "" (ineligible). DEAD is decided
# FIRST and on the endpoint alone, because a dead agent's declared-state history
# is moot - the server it left behind is dead weight whatever the last status
# line said. Only when the endpoint is not confidently dead does the declared
# state decide, and only a `paused` state (a declared external wait) qualifies.
# Everything else - working, briefly-waiting, blocked, gate-parked, done, failed,
# or an unresolvable/unknown state - is ineligible, the conservative default.
lane_eligibility() {  # <meta-file> <id>
  local meta=$1 id=$2 backend target verdict state
  backend=tmux
  target=""
  if [ "$BACKEND_OK" = 1 ]; then
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
  else
    target=$(sed -n 's/^window=//p' "$meta" 2>/dev/null | tail -1)
  fi
  verdict=$(endpoint_verdict "$id" "$backend" "$target")
  if [ "$verdict" = dead ]; then
    printf 'dead'
    return 0
  fi
  state=$(crew_state_token "$id")
  if [ "$state" = paused ]; then
    printf 'parked'
    return 0
  fi
  printf ''
}

# --- termination ------------------------------------------------------------

# release_pid <pid>: terminate one language-server pid, TERM then KILL after a
# short grace. A pid that is already gone is a silent no-op (idempotent re-run).
# Under the FM_RELEASE_LSP_KILL_LOG test seam the pid is recorded instead of
# signalled, so a test verifies the exact set with no real process. Prints
# `released` when it acted, `absent` when the pid was already gone.
release_pid() {  # <pid>
  local pid=$1 grace=0
  if [ -n "${FM_RELEASE_LSP_KILL_LOG:-}" ]; then
    printf '%s\n' "$pid" >> "$FM_RELEASE_LSP_KILL_LOG"
    printf 'released'
    return 0
  fi
  kill -0 "$pid" 2>/dev/null || { printf 'absent'; return 0; }
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$grace" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    grace=$((grace + 1))
  done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  printf 'released'
}

# --- main -------------------------------------------------------------------

[ -d "$STATE" ] || die "no state directory to read lanes from: $STATE"

# Build the eligible-lane set once: id<TAB>reason. Only ordinary crews are ever
# considered; a persistent secondmate is idle-by-default (healthy, not a shed
# candidate), so its meta is skipped entirely.
ELIGIBLE=""
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  id=$(basename "$meta" .meta)
  kind=tmux
  kind=$(sed -n 's/^kind=//p' "$meta" 2>/dev/null | tail -1)
  [ "$kind" = secondmate ] && continue
  reason=$(lane_eligibility "$meta" "$id")
  [ -n "$reason" ] || continue
  ELIGIBLE="${ELIGIBLE}${id}"$'\t'"${reason}"$'\n'
done

# Walk the task-owned language servers and release those whose lane is eligible.
released_count=0
released_kb=0
REPORT_ROWS=""
if [ -n "$LSP_ROWS" ]; then
  while IFS=$'\t' read -r pid owner fp; do
    [ -n "$pid" ] || continue
    reason=""
    while IFS=$'\t' read -r eid ereason; do
      [ -n "$eid" ] || continue
      if [ "$eid" = "$owner" ]; then reason=$ereason; break; fi
    done <<EOF
$ELIGIBLE
EOF
    [ -n "$reason" ] || continue
    case "$fp" in ''|*[!0-9]*) fp=0 ;; esac
    outcome=released
    if [ "$dry_run" = 1 ]; then
      outcome=would-release
    else
      outcome=$(release_pid "$pid")
    fi
    if [ "$outcome" = released ] || [ "$outcome" = would-release ]; then
      released_count=$((released_count + 1))
      released_kb=$((released_kb + fp))
    fi
    REPORT_ROWS="${REPORT_ROWS}${owner}"$'\t'"${reason}"$'\t'"${pid}"$'\t'"${fp}"$'\t'"${outcome}"$'\n'
  done <<EOF
$LSP_ROWS
EOF
fi

fmt_kb() {
  awk -v kb="$1" 'BEGIN {
    if (kb >= 1024 * 1024) printf "%.2f GB", kb / 1024 / 1024
    else if (kb >= 1024) printf "%.0f MB", kb / 1024
    else printf "%.0f KB", kb
  }'
}

if [ "$mode" = json ]; then
  printf '{\n'
  printf '  "kind": "release-lsp",\n'
  printf '  "dry_run": %s,\n' "$([ "$dry_run" = 1 ] && printf true || printf false)"
  printf '  "released_count": %s,\n' "$released_count"
  printf '  "released_kb": %s,\n' "$released_kb"
  printf '  "released": [\n'
  first=1
  if [ -n "$REPORT_ROWS" ]; then
    while IFS=$'\t' read -r owner reason pid fp outcome; do
      [ -n "$pid" ] || continue
      [ "$first" = 1 ] || printf ',\n'
      first=0
      printf '    {"lane":"%s","reason":"%s","pid":%s,"footprint_kb":%s,"outcome":"%s"}' \
        "$owner" "$reason" "$pid" "$fp" "$outcome"
    done <<EOF
$REPORT_ROWS
EOF
  fi
  printf '\n  ]\n'
  printf '}\n'
  exit 0
fi

if [ "$dry_run" = 1 ]; then
  printf 'Release language servers of PARKED or DEAD lanes (DRY RUN - nothing killed)\n'
else
  printf 'Release language servers of PARKED or DEAD lanes\n'
fi
if [ -z "$REPORT_ROWS" ]; then
  printf '  nothing to release: no eligible lane has a language server\n'
  printf '  (a live, briefly-waiting, blocked, gate-parked, finished or uncertain\n'
  printf '   lane keeps its server; only paused or dead lanes qualify)\n'
  exit 0
fi
printf '  %-24s %-8s %-8s %10s  %s\n' LANE STATE PID FOOTPRINT OUTCOME
while IFS=$'\t' read -r owner reason pid fp outcome; do
  [ -n "$pid" ] || continue
  printf '  %-24s %-8s %-8s %10s  %s\n' \
    "$(printf '%.24s' "$owner")" "$reason" "$pid" "$(fmt_kb "$fp")" "$outcome"
done <<EOF
$REPORT_ROWS
EOF
printf '  %s language server(s), about %s reclaimed\n' "$released_count" "$(fmt_kb "$released_kb")"
printf '  Agent processes and worktrees are left intact; a resumed lane respawns\n'
printf '  its own language server on next use.\n'
exit 0
