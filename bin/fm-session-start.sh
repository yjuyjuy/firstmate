#!/usr/bin/env bash
# fm-session-start.sh - one command for the whole session start.
#
# Collapses AGENTS.md sections 3 (bootstrap) and 5 (recovery) into ONE script
# producing ONE ordered digest, so a session starts in one or two turns
# instead of the six-plus separate reads the old docs required: run
# fm-bootstrap.sh, then separately read data/projects.md, data/secondmates.md,
# data/captain.md, data/captain-shared.md, data/learnings.md, then run
# fm-lock.sh, fm-wake-drain.sh, then read data/backlog.md, every state/*.meta,
# and every state/*.status.
# Every one of those reads is UNCONDITIONAL at every session start, so they
# belong in a script, not in N agent turns.
#
# COMPOSITION, NOT DUPLICATION: this script calls fm-lock.sh, fm-bootstrap.sh,
# and fm-wake-drain.sh as real subprocesses and prints their real output. It
# never re-implements their logic; all sequencing/formatting logic added here
# stays local to this file. Those three scripts remain fully working
# standalone with unchanged default behavior - other flows (fm-bootstrap.sh
# install <tools> after consent, /updatefirstmate, the afk daemon, existing
# tests) still call them directly. The one seam this script needed -
# bootstrap running its detect-only diagnostics without its six mutating
# sweeps - is an opt-in FM_BOOTSTRAP_DETECT_ONLY=1 flag on fm-bootstrap.sh
# itself (default unset/0 = unchanged behavior), not a fork.
#
# ORDERING, and why LOCK now runs before BOOTSTRAP (the old AGENTS.md order
# was bootstrap-then-lock):
#
#   1. lock          - acquire the per-home session lock FIRST, before any
#                       mutating step runs.
#   2. bootstrap      - detect-only diagnostics always run. The five
#                       MUTATING sweeps (legacy PR-check migration, secondmate
#                       fast-forward, secondmate liveness, X-mode artifact writes, fleet sync) run only
#                       when this session actually holds the lock.
#   3. wake-drain     - mutates the durable wake queue, so it also only runs
#                       when locked.
#   3b. hourly passes - arm the hourly session review and hourly cleanup sweep
#                       for the life of the session (bin/fm-hourly-lib.sh).
#                       Writes durable schedule state only - the existing
#                       watcher runs them on its slow poll, so no second
#                       supervision cycle exists - and is mutating, so it too
#                       runs only when locked.
#   4. context digest - data/projects.md, data/secondmates.md, data/captain.md,
#                       data/captain-shared.md, data/learnings.md: read-only,
#                       always safe, always runs.
#   5. fleet digest   - a compact data/backlog.md identity/metadata listing,
#                       a prominent cross-session stall banner (any worker a
#                       prior session left paused/blocked, read via
#                       bin/fm-crew-state.sh, surfaced above the per-task status
#                       tails so a shared-account or rate-limit stall is loud at
#                       attach instead of buried; paused is age-gated by
#                       FM_SESSION_START_STALL_THRESHOLD, blocked always shows),
#                       every state/*.meta, a bounded state/*.status tail,
#                       one host CPU/memory/swap reading with the concurrent-crew
#                       ceiling it supports (bin/fm-resource-check.sh, so the
#                       session opens knowing whether the machine can take more
#                       work), a one-line count of released-but-unmerged branches
#                       when the merge queue is non-empty (silent when empty),
#                       state/.afk, and a cheap per-task endpoint-liveness
#                       read: read-only, always runs.
#   6. closing reminder - prints the context-specific watcher next step; this
#                       script points back to the emitted harness supervision
#                       block and deliberately never arms the watcher itself.
#
# On a Pi primary, the supervision-block step also checks whether Pi's two
# tracked primary extensions are loaded and prints a PI_WATCH_EXTENSION
# reminder line when one is missing.
#
# Why lock first: the old documented order (bootstrap, THEN lock) let a
# SECOND concurrent session run bootstrap's mutating sweeps - fast-forwarding
# secondmate homes, writing X-mode artifacts, fetching/fast-forwarding every
# project clone - before ever discovering another session already holds the
# lock. Two sessions racing those sweeps is exactly the hazard the lock
# exists to prevent, so locking first closes the hole outright: only the
# session that actually wins the lock ever touches shared mutable state.
#
# The tradeoff this ordering accepts: a refused (read-only) session must not
# go dark. So on refusal, bootstrap still runs (in FM_BOOTSTRAP_DETECT_ONLY=1
# mode) for its read-only detect lines - missing tools, gh auth, the
# worktree-tangle check, the harness override, crew-dispatch validation,
# tasks-axi and quota-axi tool checks, and tasks-axi availability - none of
# which mutate shared state and all of which are safe to compute from a second
# session.
# Only the six mutating sweeps and the wake-queue drain are skipped.
# The context and fleet-state digests
# below are always read-only, so they run unconditionally in both modes.
#
# BACKLOG DIGEST: FM_SESSION_START_BACKLOG_LIMIT bounds the startup backlog
# listing, default 80 items.
# When compatible tasks-axi is selected and available, the shared tasks-axi
# backend probe remains the compatibility owner and this script asks
# `tasks-axi list` for the compact identity fields plus blocked_by, hold_kind,
# and hold_reason, never body.
# When manual mode is selected, or tasks-axi is unavailable or incompatible,
# this script prints only backlog section headings and item title lines, so
# title-line hold and blocked-by metadata remain visible while indented bodies
# stay out of the startup digest.
# Full bodies are targeted follow-up only: `tasks-axi show <id> --full` when
# compatible tasks-axi is available, or `data/backlog.md` when the file body is
# truly needed.
#
# Usage: fm-session-start.sh
#   Prints the full ordered digest to stdout and always exits 0: this is a
#   reporting command, not a gate. A lock refusal is reported as a loud
#   banner inline, never a silent failure or a non-zero exit that would make
#   an agent skip the rest of the digest.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PRIMARY_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-afk-daemon-lib.sh
. "$SCRIPT_DIR/fm-afk-daemon-lib.sh"
# shellcheck source=bin/fm-hourly-lib.sh
. "$SCRIPT_DIR/fm-hourly-lib.sh"
# shellcheck source=bin/fm-token-sessions-lib.sh
. "$SCRIPT_DIR/fm-token-sessions-lib.sh"

STATUS_TAIL=${FM_SESSION_START_STATUS_TAIL:-5}
case "$STATUS_TAIL" in ''|*[!0-9]*) STATUS_TAIL=5 ;; esac
BACKLOG_LIMIT=${FM_SESSION_START_BACKLOG_LIMIT:-80}
case "$BACKLOG_LIMIT" in ''|*[!0-9]*|0) BACKLOG_LIMIT=80 ;; esac

# Cross-session stall surfacing. A task a PRIOR session left paused (a bounded
# external wait) or blocked (needs firstmate action) must be LOUD at attach, not
# buried in the per-task status tails a firstmate has to go read. STALL_THRESHOLD
# (seconds) gates only the paused case: any blocked worker surfaces regardless of
# age because it needs action, while a paused worker surfaces only once its last
# status event is older than the threshold, so a fresh pause from THIS session's
# own recent dispatch does not nag. Default 1800 (30 min).
STALL_THRESHOLD=${FM_SESSION_START_STALL_THRESHOLD:-1800}
case "$STALL_THRESHOLD" in ''|*[!0-9]*) STALL_THRESHOLD=1800 ;; esac

# Gap 3: a paired current-state+event line marks a status EVENT (OLD) when it is
# older than this (seconds) AND the current state has a fresher authoritative
# source (run-step/pane), so a stale wake event is never read as current truth.
# Default 600s (the supervision slow-poll cadence).
EVENT_OLD_THRESHOLD=${FM_SESSION_START_EVENT_OLD_THRESHOLD:-600}
case "$EVENT_OLD_THRESHOLD" in ''|*[!0-9]*) EVENT_OLD_THRESHOLD=600 ;; esac

# Recent-tail window for the two large consolidated context files (captain.md,
# learnings.md): the last N lines emitted alongside the curated top so newest
# dated rulings appended below the consolidation seam are never dropped.
CONTEXT_TAIL=${FM_SESSION_START_CONTEXT_TAIL:-40}
case "$CONTEXT_TAIL" in ''|*[!0-9]*|0) CONTEXT_TAIL=40 ;; esac
# Per-file escape hatches: force a full cat of either big file when set to 1.
CAPTAIN_FULL=${FM_SESSION_START_CAPTAIN_FULL:-0}
case "$CAPTAIN_FULL" in 1) CAPTAIN_FULL=1 ;; *) CAPTAIN_FULL=0 ;; esac
LEARNINGS_FULL=${FM_SESSION_START_LEARNINGS_FULL:-0}
case "$LEARNINGS_FULL" in 1) LEARNINGS_FULL=1 ;; *) LEARNINGS_FULL=0 ;; esac

RULE='================================================================================'
SUBRULE='--------------------------------------------------------------------------------'
# The field separator fm-crew-state.sh emits between "state: · source: · detail".
# Kept identical so print_cross_session_stalls can split that line reliably.
CREW_STATE_SEP=' · '

section() { printf '\n%s\n%s\n%s\n' "$RULE" "$1" "$RULE"; }
subsection() { printf '\n%s\n%s\n' "$1" "$SUBRULE"; }

# print_file_or_absent <path> <label>: full contents under a labeled
# subsection, or an explicit ABSENT marker. Absence is semantically
# meaningful for every one of these files (captain.md absent = firstmate
# repo built-in defaults, projects.md absent = rebuild from clones, etc. -
# AGENTS.md section 3) and must never be confused with an empty-but-present
# file, so the two cases print differently.
print_file_or_absent() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      cat "$path"
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

# print_file_compact_top <path> <label> <marker_regex> <force_full>:
# a shape-2 emit for the two large consolidated context files (captain.md and
# learnings.md). Both carry a "# Detailed ... (inlined from former topic
# files ...)" seam: above it is the curated recent top, below it is a bulk
# topical archive that also accrues the newest dated one-off rulings at its
# very end. Full cat of these two files is ~92% of the digest's token cost.
#
# This prints the curated top (everything ABOVE the seam line) PLUS a head+tail
# window (the last FM_SESSION_START_CONTEXT_TAIL lines, so newest dated rulings
# appended after the seam are never dropped), an elision notice for the omitted
# middle, and a pointer to read the full file on demand.
#
# Safety: ABSENT vs (present, empty) semantics are identical to
# print_file_or_absent. If the seam marker is not found (an un-consolidated or
# future-reshaped file), it falls back to a FULL cat so content is never
# truncated blindly. force_full=1 (per-file escape-hatch env) also forces full.
print_file_compact_top() {
  local path=$1 label=$2 marker=$3 force_full=${4:-0}
  local total marker_line top_end tail_start omitted
  local tail_lines=$CONTEXT_TAIL
  if [ ! -f "$path" ]; then
    subsection "$label"
    printf 'ABSENT\n'
    return
  fi
  if [ ! -s "$path" ]; then
    subsection "$label"
    printf '(present, empty)\n'
    return
  fi

  # Force-full escape hatch, or marker absent: emit the whole file verbatim
  # under the plain label so behavior is byte-identical to print_file_or_absent.
  marker_line=$(grep -n -m1 -E "$marker" "$path" | cut -d: -f1)
  if [ "$force_full" = "1" ] || [ -z "$marker_line" ]; then
    subsection "$label"
    cat "$path"
    return
  fi

  total=$(wc -l < "$path")
  total=${total//[!0-9]/}
  top_end=$((marker_line - 1))
  tail_start=$((total - tail_lines + 1))
  [ "$tail_start" -lt 1 ] && tail_start=1

  # If the tail window would overlap the curated top (small file), just cat it
  # all - there is no meaningful middle to elide.
  if [ "$tail_start" -le "$((top_end + 1))" ]; then
    subsection "$label"
    cat "$path"
    return
  fi

  omitted=$((tail_start - 1 - top_end))
  subsection "$label (curated recent top + newest rulings; full archive on demand)"
  sed -n "1,${top_end}p" "$path"
  printf '\n[detail omitted: %d line(s) of topical archive below the consolidation seam. Read %s in full, or grep it, only when a specific older item is needed. Newest dated rulings follow below.]\n\n' \
    "$omitted" "$path"
  sed -n "${tail_start},\$p" "$path"
}

print_backlog_pointer() {
  printf 'Full task bodies remain available on demand: tasks-axi show <id> --full when compatible tasks-axi is available, or data/backlog.md.\n'
}

print_backlog_manual_compact() {
  local path=$1 reason=$2
  printf 'compact backlog listing (%s; max %s item(s); indented task bodies omitted)\n' "$reason" "$BACKLOG_LIMIT"
  awk -v max="$BACKLOG_LIMIT" '
    function state_for_heading(line, heading) {
      heading = line
      sub(/^##[[:space:]]+/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      if (heading == "In flight") return "in_flight"
      if (heading == "Queued") return "queued"
      if (heading == "Done") return "done"
      return ""
    }
    /^##[[:space:]]+/ {
      state = state_for_heading($0)
      if (state != "") print $0
      next
    }
    state != "" && /^[-*][[:space:]]+/ {
      total++
      if (shown < max) {
        print $0
        shown++
      }
      next
    }
    END {
      if (total == 0) {
        print "(no backlog item title lines found)"
      } else {
        printf "(shown %d of %d backlog item title line(s))\n", shown, total
        if (total > shown) {
          printf "(truncated %d item(s); increase FM_SESSION_START_BACKLOG_LIMIT for a larger startup listing)\n", total - shown
        }
      }
    }
  ' "$path"
}

print_backlog_tasks_axi_compact() {
  local path=$1 out rc
  printf 'compact backlog listing (tasks-axi; max %s item(s); task bodies omitted)\n' "$BACKLOG_LIMIT"
  out=$(tasks-axi list --file "$path" --limit "$BACKLOG_LIMIT" --fields blocked_by,hold_kind,hold_reason 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$out"
  else
    printf 'tasks-axi compact listing failed; falling back to title-line rendering.\n'
    printf '%s\n' "$out"
    print_backlog_manual_compact "$path" "fallback"
  fi
}

print_backlog_compact() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      if fm_tasks_axi_backend_available "$CONFIG"; then
        print_backlog_tasks_axi_compact "$path"
      elif fm_backlog_backend_manual "$CONFIG"; then
        print_backlog_manual_compact "$path" "manual backend"
      else
        print_backlog_manual_compact "$path" "tasks-axi unavailable or incompatible"
      fi
      print_backlog_pointer
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

print_status_tail() {
  local status=$1
  printf 'status tail (last %s line(s), wake-EVENT history, not current state; full log: %s):\n' "$STATUS_TAIL" "$status"
  tail -n "$STATUS_TAIL" "$status"
}

# Portable file mtime in epoch seconds; empty on failure.
file_mtime_epoch() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# Human "2h10m"/"47m" age for an event; empty when age is unknown.
human_event_age() {  # <seconds>
  local s=${1:-}
  case "$s" in ''|*[!0-9]*) printf ''; return 0 ;; esac
  if [ "$s" -lt 3600 ]; then
    printf '%dm' $(( s / 60 ))
  else
    printf '%dh%dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
  fi
}

# Gap 3: pair the reconciled CURRENT state with the last wake EVENT and a
# freshness age, so a stale status event is never read as current truth. Prints
# one "current: <state> · source: <src>[ · SUPERSEDED] · event(<age>)[ (OLD)]:
# <line>" line above the raw status tail. The current state comes from
# fm-crew-state.sh (the same reconciliation the fleet uses); SUPERSEDED and OLD
# are surfaced from values that already exist, no new collection.
print_current_and_event() {  # <id> <status-file>
  local id=$1 status=$2 state_line state source detail superseded now event_epoch age age_label line marker
  state_line=$("$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null) || state_line=""
  # Parse "state: <s> · source: <src> · <detail>" (same shape as the stall scan).
  state=unknown
  source=none
  detail=""
  case "$state_line" in
    state:\ *"$CREW_STATE_SEP"source:\ *)
      state=${state_line#state: }
      state=${state%%"$CREW_STATE_SEP"*}
      source=${state_line#*"$CREW_STATE_SEP"source: }
      case "$source" in
        *"$CREW_STATE_SEP"*) detail=${source#*"$CREW_STATE_SEP"}; source=${source%%"$CREW_STATE_SEP"*} ;;
      esac
      ;;
  esac
  # SUPERSEDED: fm-crew-state.sh already computed this reconciliation, surfaced in detail.
  superseded=""
  case "$detail" in *superseded*) superseded="${CREW_STATE_SEP}SUPERSEDED" ;; esac
  line="current: $state${CREW_STATE_SEP}source: $source$superseded"
  if [ -f "$status" ]; then
    now=$(date +%s)
    event_epoch=$(file_mtime_epoch "$status")
    age=""
    age_label=""
    case "$event_epoch" in
      ''|*[!0-9]*) : ;;
      *)
        age=$(( now - event_epoch ))
        [ "$age" -lt 0 ] && age=0
        age_label=$(human_event_age "$age")
        ;;
    esac
    # OLD only when the event is older than the threshold AND current state has a
    # fresher authoritative source (run-step/pane).
    marker=""
    case "$source" in
      run-step|pane)
        case "$age" in
          ''|*[!0-9]*) : ;;
          *) [ "$age" -gt "$EVENT_OLD_THRESHOLD" ] && marker=" (OLD)" ;;
        esac
        ;;
    esac
    local raw
    raw=$(grep -v '^[[:space:]]*$' "$status" 2>/dev/null | tail -1)
    if [ -n "$raw" ]; then
      if [ -n "$age_label" ]; then
        line="$line${CREW_STATE_SEP}event($age_label)$marker: $raw"
      else
        line="$line${CREW_STATE_SEP}event$marker: $raw"
      fi
    fi
  fi
  printf '%s\n' "$line"
}

# Gap 1: per-account quota rollup for the fleet-state digest. Reads each live
# task's state/<id>.telemetry (the same key=value shape as .meta, via
# fm_meta_get) and prints ONE line per account, lowest runway first (min
# quota_pct across the account's panes, with the driving window and its closest
# reset clock). Absent quota data = "unavailable", never a zero. Passive digest
# material, never a wake.
print_account_quotas() {  # <state-dir>
  local state=$1 tel id acct pct win reset reset_clock out
  out=$({
    for tel in "$state"/*.telemetry; do
      [ -f "$tel" ] || continue
      id=$(basename "$tel" .telemetry)
      [ -f "$state/$id.meta" ] || continue
      acct=$(fm_meta_get "$tel" account)
      pct=$(fm_meta_get "$tel" quota_pct)
      [ -n "$acct" ] && [ -n "$pct" ] || continue
      win=$(fm_meta_get "$tel" quota_window)
      reset=$(fm_meta_get "$tel" quota_reset_ts)
      case "$pct" in ''|*[!0-9.]*) continue ;; esac
      reset_clock=""
      case "$reset" in
        ''|*[!0-9]*) : ;;
        *)
          reset_clock=$(date -d "@$reset" +%H:%M 2>/dev/null \
            || date -r "$reset" +%H:%M 2>/dev/null || printf '')
          ;;
      esac
      printf '%s\t%s\t%s\t%s\n' "$acct" "$pct" "$win" "$reset_clock"
    done
  } | awk -F '\t' '
    {
      acct = $1; pct = $2 + 0; win = $3; rclock = $4
      if (!(acct in minpct) || pct < minpct[acct]) {
        minpct[acct] = pct; winid[acct] = win; resetclock[acct] = rclock
      }
    }
    function reset_suffix(a) {
      return (resetclock[a] != "" ? " resets " resetclock[a] : "")
    }
    END {
      n = 0
      for (a in minpct) { order[n++] = a }
      for (i = 0; i < n; i++)
        for (j = i + 1; j < n; j++)
          if (minpct[order[j]] < minpct[order[i]]) { t = order[i]; order[i] = order[j]; order[j] = t }
      if (n == 0) { print "unavailable"; exit }
      s = ""
      for (i = 0; i < n; i++) {
        a = order[i]
        part = sprintf("%s %d%% (%s%s)", a, minpct[a],
          (winid[a] != "" ? winid[a] : "window"), reset_suffix(a))
        s = (s == "" ? part : s " · " part)
      }
      print "accounts: " s
    }')
  printf '%s\n' "$out"
}

# Cross-session stall surfacing. Scan every task's CURRENT state via
# bin/fm-crew-state.sh (the same current-state reconciliation the rest of the
# fleet uses - NOT a tail of the status EVENT log) and surface, prominently and
# separately from the per-task status tails, any worker a prior session left
# stalled:
#   - blocked: needs firstmate action -> always surfaced, any age.
#   - paused:  a bounded external wait (rate-limit reset, upstream release,
#              scheduled window) -> surfaced only once its last status event is
#              older than STALL_THRESHOLD, so a pause THIS session just created
#              does not nag.
# A shared-account usage-window stall left by an 11:39 session was invisible to
# the 17:14 session precisely because it lived only in status tails; this makes
# it loud at attach. Complements classify-auth-limit-as-blocked-not-paused (which
# reclassifies auth stalls to blocked) and any shared-account rollup - it only
# makes the cross-session stall visible, it does not reclassify anything.
print_cross_session_stalls() {
  local now stall_lines meta id state_line state detail status age m
  now=$(date +%s)
  stall_lines=""
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    state_line=$("$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null) || continue
    # Parse "state: <s> · source: <src> · <detail>".
    state=${state_line#state: }
    state=${state%%"$CREW_STATE_SEP"*}
    detail=""
    case "$state_line" in
      *"$CREW_STATE_SEP"source:*"$CREW_STATE_SEP"*) detail=${state_line#*"$CREW_STATE_SEP"source:*"$CREW_STATE_SEP"} ;;
    esac
    case "$state" in
      blocked)
        stall_lines="$stall_lines$(printf 'BLOCKED  %-40s needs firstmate action: %s\n' "$id" "${detail:-no detail}")
"
        ;;
      paused)
        status="$STATE/$id.status"
        age=""
        if [ -f "$status" ]; then
          m=$(file_mtime_epoch "$status")
          case "$m" in ''|*[!0-9]*) m="" ;; esac
          [ -n "$m" ] && age=$((now - m))
        fi
        # Surface a pause only once it is older than the threshold.
        if [ -n "$age" ] && [ "$age" -ge "$STALL_THRESHOLD" ]; then
          stall_lines="$stall_lines$(printf 'PAUSED   %-40s external wait, idle %dm: %s\n' "$id" "$((age / 60))" "${detail:-no detail}")
"
        elif [ -z "$age" ]; then
          # No readable status mtime: cannot bound the age, so surface it rather
          # than silently hide a possibly-old pause.
          stall_lines="$stall_lines$(printf 'PAUSED   %-40s external wait, idle unknown: %s\n' "$id" "${detail:-no detail}")
"
        fi
        ;;
    esac
  done
  if [ -n "$stall_lines" ]; then
    subsection "STALLED WORKERS FROM A PRIOR SESSION (act on these first)"
    printf 'These workers are idle waiting - surfaced here so a cross-session stall is not buried in status tails below. BLOCKED needs your action; PAUSED is a bounded external wait rechecked on a long cadence.\n'
    printf '%s' "$stall_lines"
  fi
}

hash_file() {
  local file=$1
  [ -f "$file" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print "sha256:" $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print "sha256:" $1}'
  else
    cksum "$file" | awk '{print "cksum:" $1 ":" $2}'
  fi
}

pi_extension_loaded() {
  local marker=$1 expected_version=$2 lock=$3 marker_version marker_pid lock_pid
  [ -f "$marker" ] && [ -f "$lock" ] && [ -n "$expected_version" ] || return 1
  marker_version=$(sed -n '1p' "$marker")
  marker_pid=$(sed -n '2p' "$marker")
  lock_pid=$(sed -n '1p' "$lock")
  [ -n "$marker_pid" ] || return 1
  [ "$marker_version" = "$expected_version" ] && [ "$marker_pid" = "$lock_pid" ]
}

section "SESSION START - $FM_HOME"

# --- 1. lock -----------------------------------------------------------
subsection "LOCK"
LOCK_OUT=$("$SCRIPT_DIR/fm-lock.sh" 2>&1)
LOCK_RC=$?
printf '%s\n' "$LOCK_OUT"
READ_ONLY=0
if [ "$LOCK_RC" -ne 0 ]; then
  READ_ONLY=1
  BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '%s\n' "$BAR"
    printf '●  READ-ONLY SESSION - ANOTHER LIVE FIRSTMATE SESSION HOLDS THE FLEET LOCK\n'
    printf '●  %s\n' "$LOCK_OUT"
    printf '●  Skipping every mutating step: PR-check migration, secondmate sync,\n'
    printf '●  X-mode artifacts, fleet sync, and wake-queue drain. Detect-only bootstrap\n'
    printf '●  diagnostics and the rest of this read-only-safe digest still ran below.\n'
    printf '●  Operate read-only until this resolves - do not spawn, steer, merge, or\n'
    printf '●  otherwise mutate fleet state from this session.\n'
    printf '%s\n' "$BAR"
  }
fi

# --- 2. bootstrap --------------------------------------------------------
subsection "BOOTSTRAP"
if [ "$READ_ONLY" -eq 1 ]; then
  BOOT_OUT=$(FM_BOOTSTRAP_DETECT_ONLY=1 "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
else
  BOOT_OUT=$("$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
fi
if [ -n "$BOOT_OUT" ]; then
  printf '%s\n' "$BOOT_OUT"
else
  printf '(silent - all good)\n'
fi

# --- 3. wake-drain -------------------------------------------------------
# Drained records are this turn's first work queue (AGENTS.md section 8); the
# drain also runs fm-guard.sh internally on the locked path, so the
# tangle/watcher-liveness alarms land right here too, ahead of the bulk digest
# below. The read-only path never touches the queue (another session
# may be actively draining it) but still runs fm-guard.sh directly with
# non-mutating advisory text, so the same alarms surface without repair
# commands.
subsection "WAKE QUEUE"
if [ "$READ_ONLY" -eq 1 ]; then
  QLEN=0
  [ -s "$STATE/.wake-queue" ] && QLEN=$(grep -c . "$STATE/.wake-queue" 2>/dev/null || printf '0')
  printf 'skipped (read-only session) - %s record(s) remain queued for the session holding the lock.\n' "$QLEN"
  GUARD_OUT=$(FM_GUARD_READ_ONLY=1 "$SCRIPT_DIR/fm-guard.sh" 2>&1)
  [ -n "$GUARD_OUT" ] && printf '%s\n' "$GUARD_OUT"
else
  DRAIN_OUT=$("$SCRIPT_DIR/fm-wake-drain.sh" 2>&1)
  if [ -n "$DRAIN_OUT" ]; then
    printf '%s\n' "$DRAIN_OUT"
  else
    printf '(no queued wakes)\n'
  fi
fi

# --- 3b. hourly passes ---------------------------------------------------
# Arm the two session-lifetime hourly passes (the session review and the
# cleanup sweep). Arming is durable schedule state only: the ONE live watcher
# runs them on its existing slow poll, so this creates no second supervision
# cycle and starts no process. Mutating, so it is skipped on the read-only
# path like every other mutating step. bin/fm-hourly-lib.sh owns the mechanism.
subsection "HOURLY PASSES"
if [ "$READ_ONLY" -eq 1 ]; then
  printf 'skipped (read-only session) - the session holding the lock owns them.\n'
elif fm_hourly_arm "$STATE"; then
  printf 'armed: an hourly review and an hourly cleanup run for the life of this session, and surface only when they have something worth acting on.\n'
else
  printf 'HOURLY_PASSES: could not arm (state directory not writable) - the hourly review and cleanup will not run this session.\n'
fi

# --- 3c. session-stats backfill -----------------------------------------
# Detect an unclean turnover: a predecessor session that reloaded without a
# clean /endsession close left no ended= record in data/session-stats.log. The
# missing-record backfill (bin/fm-end-session.sh session-open, the owner of that
# ledger and its format) appends exactly one reconstructed stub for it, then
# stamps the session-open marker with this session's identity. Mutating and
# lock-guarded like every other sweep, so it is skipped on the read-only path.
subsection "SESSION STATS"
if [ "$READ_ONLY" -eq 1 ]; then
  printf 'skipped (read-only session) - the session holding the lock owns the ledger.\n'
else
  STATS_OUT=$("$SCRIPT_DIR/fm-end-session.sh" session-open 2>&1)
  if [ -n "$STATS_OUT" ]; then
    printf '%s\n' "$STATS_OUT"
  else
    printf '(predecessor closed cleanly - nothing to backfill)\n'
  fi
fi

# --- 3d. own-session token sentinel -------------------------------------
# Capture firstmate's OWN harness session id into the durable token-session
# ledger under the sentinel id __firstmate__, so this home's cross-ticket
# supervision tokens attribute to the home, not lost and not force-fit to any one
# ticket. FM_ROOT is firstmate's own working_dir (the primary checkout), and the
# session started at or before now, so pass no floor (empty spawn_ts) and let the
# newest session in that working_dir win. Mutating, so it is skipped on the
# read-only path. FAIL-CLOSED and best-effort: an unresolvable id (a harness
# whose store we cannot read, or no matching session) skips silently and never
# blocks the session. The ledger dedupes by (id, session_id), so re-running the
# same session start is a no-op while a genuinely new session appends a new row.
subsection "TOKEN SESSION"
if [ "$READ_ONLY" -eq 1 ]; then
  printf 'skipped (read-only session) - the session holding the lock owns the ledger.\n'
elif [ "$PRIMARY_HARNESS" = jcode ]; then
  FM_SESSION_ID=$(fm_resolve_crew_session_id "$FM_ROOT" "" 2>/dev/null || true)
  if [ -n "$FM_SESSION_ID" ] \
    && fm_token_sessions_record "$DATA" __firstmate__ "$FM_SESSION_ID" "$FM_ROOT" \
         "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PRIMARY_HARNESS" 2>/dev/null; then
    printf 'recorded firstmate own-session token attribution (sentinel __firstmate__).\n'
  else
    printf '(own session id unresolved - skipped, token attribution best-effort).\n'
  fi
else
  printf '(harness %s session store not readable - skipped).\n' "$PRIMARY_HARNESS"
fi

# --- 4. supervision operating instructions ----------------------------------
# Watcher ownership moves to the away-mode daemon only while one is actually live
# for this home; away mode with no daemon is the away posture only and keeps the
# ordinary supervision instructions (bin/fm-afk-daemon-lib.sh).
AFK_PRESENT=0
fm_afk_daemon_owns_supervision "$STATE" "$SCRIPT_DIR" && AFK_PRESENT=1
AWAY_POSTURE=0
[ -e "$STATE/.afk" ] && AWAY_POSTURE=1
X_MODE_PRESENT=0
[ -f "$CONFIG/x-mode.env" ] && X_MODE_PRESENT=1

if [ "$PRIMARY_HARNESS" = pi ]; then
  PI_EXT="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
  PI_TURNEND_EXT="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  PI_WATCH_MARKER="$STATE/.pi-watch-extension-loaded"
  PI_TURNEND_MARKER="$STATE/.pi-turnend-extension-loaded"
  PI_LOCK="$STATE/.lock"
  PI_WATCH_VERSION=$(hash_file "$PI_EXT" || printf '')
  PI_TURNEND_VERSION=$(hash_file "$PI_TURNEND_EXT" || printf '')
  if ! pi_extension_loaded "$PI_WATCH_MARKER" "$PI_WATCH_VERSION" "$PI_LOCK" \
    || ! pi_extension_loaded "$PI_TURNEND_MARKER" "$PI_TURNEND_VERSION" "$PI_LOCK"; then
    printf 'PI_WATCH_EXTENSION: not loaded - approve Pi project trust once per clone, then restart plain pi so %s and %s auto-load for turn-end guard and background wake coverage; use -e %s -e %s only if project hooks are not trusted\n' "$PI_TURNEND_EXT" "$PI_EXT" "$PI_TURNEND_EXT" "$PI_EXT"
  fi
fi
"$SCRIPT_DIR/fm-supervision-instructions.sh" \
  --harness "$PRIMARY_HARNESS" \
  --read-only "$READ_ONLY" \
  --afk "$AFK_PRESENT" \
  --away-posture "$AWAY_POSTURE" \
  --x-mode "$X_MODE_PRESENT"

# --- 4. context digest -----------------------------------------------------
section "CONTEXT"
print_file_or_absent "$DATA/projects.md" "data/projects.md"
print_file_or_absent "$DATA/secondmates.md" "data/secondmates.md"
print_file_compact_top "$DATA/captain.md" "data/captain.md" \
  '^# Detailed standing rules \(inlined from former topic files' "$CAPTAIN_FULL"
print_file_or_absent "$DATA/captain-shared.md" "data/captain-shared.md (shared, main-authoritative, read-only in secondmate homes)"
print_file_compact_top "$DATA/learnings.md" "data/learnings.md" \
  '^# Detailed learnings \(inlined from former topic files' "$LEARNINGS_FULL"

# --- 5. fleet-state digest ---------------------------------------------
section "FLEET STATE"
print_backlog_compact "$DATA/backlog.md" "data/backlog.md"

# Cross-session stall banner FIRST in the fleet digest, above the per-task
# status tails, so a paused/blocked worker a prior session left behind is loud
# at attach instead of buried where a firstmate has to go read it.
print_cross_session_stalls

subsection "Work under way (state/*.meta)"
META_FOUND=0
# Backlog-drift reconcile (see the drift section after orphan status): record,
# once per meta, whether this id has a LIVE worker, reusing the endpoint read
# computed here so the drift check never opens a second endpoint sweep. An id is
# "live" when its meta exists and its endpoint is alive or unknown; only an
# explicitly DEAD endpoint marks the worker gone.
declare -A WORKER_ALIVE=()
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  META_FOUND=1
  id=$(basename "$meta" .meta)
  printf '\n--- %s ---\n' "$id"
  cat "$meta"

  window=$(fm_meta_get "$meta" window)
  target=$(fm_backend_target_of_meta "$meta")
  if [ -n "$window" ]; then
    backend=$(fm_backend_of_meta "$meta")
    if fm_backend_target_exists "$backend" "${target:-$window}" "fm-$id"; then
      printf 'endpoint: alive (backend=%s window=%s)\n' "$backend" "$window"
      WORKER_ALIVE["$id"]=yes
    else
      printf 'endpoint: dead (backend=%s window=%s)\n' "$backend" "$window"
      WORKER_ALIVE["$id"]=no
    fi
  else
    printf 'endpoint: unknown (no window recorded)\n'
    WORKER_ALIVE["$id"]=yes
  fi

  status="$STATE/$id.status"
  # Gap 3: pair the reconciled current state with the last event and its freshness
  # BEFORE the raw tail, so the event is never read alone as current truth.
  print_current_and_event "$id" "$status"
  if [ -f "$status" ]; then
    print_status_tail "$status"
  else
    printf 'status tail: (no status file yet: %s)\n' "$status"
  fi
done
[ "$META_FOUND" -eq 1 ] || printf '(none)\n'

subsection "Orphan status logs (state/*.status without matching .meta)"
ORPHAN_STATUS_FOUND=0
for status in "$STATE"/*.status; do
  [ -f "$status" ] || continue
  id=$(basename "$status" .status)
  [ -f "$STATE/$id.meta" ] && continue
  ORPHAN_STATUS_FOUND=1
  printf '\n--- %s ---\n' "$id"
  print_status_tail "$status"
done
[ "$ORPHAN_STATUS_FOUND" -eq 1 ] || printf '(none)\n'

# Backlog drift = the deliberate INVERSE of orphan status. Orphan status is a
# state/<id>.status with no matching meta; drift is a backlog id parsed as "In
# flight" with NO live state/<id>.meta OR a DEAD recorded endpoint. Detection
# only: never mutate the backlog, never kill or spawn anything - just one
# advisory line per drifting id, reusing the endpoint liveness the meta loop
# above already computed (WORKER_ALIVE) so no second endpoint sweep runs.
subsection "Backlog drift (In flight with no live worker)"
BACKLOG_DRIFT_FOUND=0
if [ -f "$DATA/backlog.md" ] && [ -s "$DATA/backlog.md" ]; then
  # Parse only "In flight" section item title lines to their leading id, mirroring
  # the heading classifier the compact listing uses (In flight / Queued / Done).
  while IFS= read -r drift_id; do
    [ -n "$drift_id" ] || continue
    # Live when a meta exists AND its endpoint was not read DEAD this run. A dead
    # endpoint or an absent meta both mean no live worker -> drift.
    if [ ! -f "$STATE/$drift_id.meta" ] || [ "${WORKER_ALIVE[$drift_id]:-no}" = no ]; then
      printf 'BACKLOG_DRIFT: %s in-flight but no live worker\n' "$drift_id"
      BACKLOG_DRIFT_FOUND=1
    fi
  done < <(awk '
    /^##[[:space:]]+/ {
      heading = $0
      sub(/^##[[:space:]]+/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      in_flight = (heading == "In flight")
      next
    }
    in_flight && /^[-*][[:space:]]+/ {
      line = $0
      sub(/^[-*][[:space:]]+(\[[^]]*\][[:space:]]+)?/, "", line)
      id = line
      sub(/[[:space:]].*$/, "", id)
      if (id != "") print id
    }
  ' "$DATA/backlog.md")
fi
[ "$BACKLOG_DRIFT_FOUND" -eq 1 ] || printf '(none)\n'

# Released-but-unmerged branches. Structural, not discretionary: the release-on-pushed
# safety guard cannot depend on remembering to run the merge-queue CLI. One bounded
# line, and nothing at all when the queue is empty.
MERGE_QUEUE_COUNT=$("$SCRIPT_DIR/fm-merge-queue.sh" count 2>/dev/null || echo 0)
case "$MERGE_QUEUE_COUNT" in
  ''|*[!0-9]*) MERGE_QUEUE_COUNT=0 ;;
esac
if [ "$MERGE_QUEUE_COUNT" -gt 0 ]; then
  subsection "Finished work still waiting to merge"
  printf '%s finished branch(es) are pushed but not merged yet; run bin/fm-merge-queue.sh list for the batched compare links.\n' \
    "$MERGE_QUEUE_COUNT"
  # Drift flag: an id that is BOTH in the merge queue AND has a live state/<id>.meta
  # is a released ship branch whose task is somehow still tracked as live, so the
  # queued head can be stale against a newer pr_head the meta records. Name each so
  # the sweep's drift reconcile (bin/fm-merge-queue.sh sweep) is run against it.
  MERGE_QUEUE_DRIFT=$("$SCRIPT_DIR/fm-merge-queue.sh" list --raw 2>/dev/null \
    | while IFS='	' read -r mq_id _; do
        [ -n "$mq_id" ] || continue
        [ -f "$STATE/$mq_id.meta" ] && printf '%s\n' "$mq_id"
      done)
  if [ -n "$MERGE_QUEUE_DRIFT" ]; then
    printf 'These queued branches also still have a live task record, so the queued head may be stale; run bin/fm-merge-queue.sh sweep to reconcile: %s\n' \
      "$(printf '%s' "$MERGE_QUEUE_DRIFT" | tr '\n' ' ' | sed 's/ $//')"
  fi
fi

subsection "Host resources"
# No --sweep here: the digest is fast and bounded, so it reads the watcher's
# cached crew-liveness verdict rather than probing any backend.
RESOURCE_OUT=$("$SCRIPT_DIR/fm-resource-check.sh" 2>/dev/null) || true
if [ -n "$RESOURCE_OUT" ]; then
  printf '%s\n' "$RESOURCE_OUT"
else
  printf 'unavailable\n'
fi

subsection "Account quotas"
# Gap 1: per-account lowest-runway rollup from the task telemetry files, next to
# the host reading where the rest of the machine-level fleet context lives.
print_account_quotas "$STATE"

subsection "AFK"
if [ "$AWAY_POSTURE" -eq 1 ]; then
  if [ "$AFK_PRESENT" -eq 1 ]; then
    printf 'present - away-mode supervision is active; the daemon owns the watcher.\n'
  else
    printf 'present - away posture only; no away-mode daemon is running here, so this home keeps arming and repairing its own watcher.\n'
  fi
else
  printf 'absent\n'
fi

# --- 6. closing reminder -----------------------------------------------
section "NEXT STEP"
if [ "$READ_ONLY" -eq 1 ]; then
  cat <<'EOF'
This session did not acquire the fleet lock. Stay read-only: do not arm,
drain, spawn, steer, merge, or repair fleet state from here. The session
holding the lock owns mutable follow-up.

EOF
elif [ "$AFK_PRESENT" -eq 1 ]; then
  cat <<'EOF'
Away mode is active. Follow the supervision operating instructions block above:
load /afk and ensure the daemon is running, because the daemon owns watcher
supervision.

EOF
elif [ "$AWAY_POSTURE" -eq 1 ]; then
  cat <<EOF
Away posture is active: batch routine updates, keep the standing routine merge
authority, and load /afk for away-mode handling. No away-mode daemon is running
here, so this session's own watcher-arm loop is the supervision mechanism: arm
and repair it normally.
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
EOF
  if [ -f "$CONFIG/x-mode.env" ]; then
    printf "X mode is active, so the emitted block's cadence instruction applies.\n"
  fi
  printf 'This script never starts supervision itself.\n\n'
elif [ -f "$CONFIG/x-mode.env" ]; then
  cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
X mode is active, so the emitted block's cadence instruction applies.
This script never starts supervision itself.

EOF
else
cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
This script never starts supervision itself.

EOF
fi
cat <<'EOF'
The digest above is complete for this session start. Do NOT re-read
data/projects.md, data/secondmates.md, data/captain.md,
data/captain-shared.md, data/learnings.md,
or state/*.meta now - they were just printed.
data/captain.md and data/learnings.md were emitted TRIMMED (curated recent top
plus the newest dated rulings via a tail window, with the middle archive
elided); reading one of those two files in full is EXPECTED when a specific
older item below the elision is actually needed, and is not a violation.
Do NOT bulk-read data/backlog.md now either: the compact identity/metadata
listing was just printed with a pointer for targeted full-body follow-up.
Do NOT bulk-read state/*.status now either: their bounded tails were just
printed with full log paths for targeted follow-up when older wake-event
history is actually needed. Re-reading everything defeats the entire point
of this command. Otherwise re-read a file only if this digest flagged it
ABSENT (then rebuild or create it per AGENTS.md), its contents looked
unparseable/corrupt, or an individual full status log is needed for older
wake-event history.
EOF

exit 0
