#!/usr/bin/env bash
# Library: read a secondmate agent's live context-window occupancy from its
# harness session transcript, and resolve the handoff threshold. Sourced by
# bin/fm-secondmate-context.sh (the reporter), bin/fm-secondmate-handoff.sh
# (the orchestrator), and bin/fm-watch.sh (the threshold monitor). Never prints
# a guess: an unreadable or unsupported harness yields empty output so every
# caller fails closed (no false handoff). See docs/secondmate-context-handoff.md
# for the evidence behind the claude read and the not-applicable verdict for the
# other harnesses.

# Default handoff threshold in context tokens. ~200000 is the point a 200k-window
# model reaches auto-compact; a larger-window model should raise the knob.
FM_SM_CONTEXT_THRESHOLD_DEFAULT=200000

# fm_sm_context_threshold: the configured token threshold, or the default.
# Reads config/secondmate-context-threshold (a single integer, first non-empty
# non-comment line). Absent, non-integer, or non-positive falls back to the
# default rather than failing, so a typo never disables the safety net silently.
# This is the PRIMARY's monitoring knob and is not inherited into secondmate
# homes (secondmates do not spawn secondmates, so nothing downstream reads it).
fm_sm_context_threshold() {  # <config-dir>
  local config=$1 file line
  file="$config/secondmate-context-threshold"
  [ -f "$file" ] || { printf '%s' "$FM_SM_CONTEXT_THRESHOLD_DEFAULT"; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    if [[ "$line" =~ ^[1-9][0-9]*$ ]]; then
      printf '%s' "$line"
    else
      printf '%s' "$FM_SM_CONTEXT_THRESHOLD_DEFAULT"
    fi
    return 0
  done < "$file"
  printf '%s' "$FM_SM_CONTEXT_THRESHOLD_DEFAULT"
}

# fm_sm_auto_handoff_enabled: 0 (enabled) iff this home opts in to AUTOMATIC
# context handoff, else 1 (disabled, today's escalate-only behavior). Opt-in and
# fail-closed by default: absent config/secondmate-auto-handoff = disabled, so a
# threshold crossing still only WAKES the primary to run the handoff by hand,
# exactly as before, until the captain explicitly enables it. Enabled when the
# local, gitignored config/secondmate-auto-handoff presence flag exists AND its
# first non-empty non-comment line is not "off" (so a stray "off" force-disables
# a mistakenly created flag). This is the PRIMARY's monitoring knob and is not
# inherited into secondmate homes (secondmates do not spawn secondmates). See
# docs/configuration.md and docs/secondmate-context-handoff.md.
fm_sm_auto_handoff_enabled() {  # <config-dir>
  local config=$1 file line
  file="$config/secondmate-auto-handoff"
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    [ "$line" = off ] && return 1
    return 0
  done < "$file"
  # Present but empty/comment-only: treat presence as consent (enabled).
  return 0
}

# fm_sm_context_marker_key: the per-window surfaced-marker key both the watcher's
# secondmate_context_sweep and the auto-handoff wrapper derive from a window, so
# neither forks the transform. A window string with ':' '/' '.' mapped to '_'.
fm_sm_context_marker_key() {  # <window>
  printf '%s' "$1" | tr ':/.' '___'
}

# fm_sm_claude_projects_dir: the base directory holding claude's per-session
# transcript project folders. Honors $CLAUDE_CONFIG_DIR, else ~/.claude.
fm_sm_claude_projects_dir() {
  printf '%s/projects' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

# fm_sm_munge_path: claude's project-folder name for a launch directory - every
# "/" and "." replaced by "-". Verified in docs/secondmate-context-handoff.md.
fm_sm_munge_path() {  # <absolute-path>
  printf '%s' "$1" | tr '/.' '--'
}

# fm_sm_claude_transcript: the newest-mtime *.jsonl transcript for the claude
# session launched in <cwd>, or empty when none exists. Newest = active session.
fm_sm_claude_transcript() {  # <cwd>
  local cwd=$1 dir f newest=''
  dir="$(fm_sm_claude_projects_dir)/$(fm_sm_munge_path "$cwd")"
  [ -d "$dir" ] || return 0
  # Newest-mtime *.jsonl via -nt (portable, no ls/stat): the active session.
  for f in "$dir"/*.jsonl; do
    [ -f "$f" ] || continue
    if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then
      newest=$f
    fi
  done
  [ -n "$newest" ] && printf '%s' "$newest"
}

# fm_sm_claude_context_tokens: the most recent main-thread turn's context-window
# occupancy (input + cache_creation + cache_read input tokens) from <cwd>'s
# claude transcript. Empty when the transcript, jq, or a usable usage line is
# missing - the caller then treats context as unknown and fails closed.
fm_sm_claude_context_tokens() {  # <cwd>
  local cwd=$1 f line tokens
  command -v jq >/dev/null 2>&1 || return 0
  f=$(fm_sm_claude_transcript "$cwd") || return 0
  [ -n "$f" ] || return 0
  # Last completed MAIN-thread assistant turn: a line carrying message.usage and
  # not a sub-agent sidechain (a Task turn is a separate context). grep streams
  # the file, so a multi-MB transcript stays cheap on the slow-poll cadence.
  line=$(grep '"usage"' "$f" 2>/dev/null | grep -v '"isSidechain":true' | tail -1 || true)
  [ -n "$line" ] || return 0
  tokens=$(printf '%s' "$line" | jq '
      (.message.usage.input_tokens // 0)
    + (.message.usage.cache_creation_input_tokens // 0)
    + (.message.usage.cache_read_input_tokens // 0)' 2>/dev/null || true)
  [[ "$tokens" =~ ^[0-9]+$ ]] || return 0
  [ "$tokens" -gt 0 ] || return 0
  printf '%s' "$tokens"
}

# fm_sm_context_tokens: dispatch the context read by harness. claude and jcode
# have a verified read (docs/secondmate-context-handoff.md); every other harness
# yields empty so the monitor fails closed. <cwd> is the agent's launch
# directory, which for a secondmate is its home= (state/<id>.meta) and for
# firstmate's own read is its operational home (FM_HOME).
#
# jcode (github.com/1jehuang/jcode) is a Claude-Agent-SDK runtime, but it does
# NOT write to claude's projects dir - it persists its own journal at
# <jcode-home>/sessions/session_<id>.journal.jsonl with a per-turn
# append_messages[].token_usage object (verified 2026-08-01; see
# docs/secondmate-context-handoff.md), so it dispatches to its own reader.
fm_sm_context_tokens() {  # <cwd> <harness>
  local cwd=$1 harness=$2
  [ -n "$cwd" ] || return 0
  case "$harness" in
    claude) fm_sm_claude_context_tokens "$cwd" ;;
    jcode)  fm_sm_jcode_context_tokens "$cwd" ;;
    *) return 0 ;;
  esac
}

# --- jcode reader ----------------------------------------------------------
# jcode persists token usage in its own journal, NOT claude's projects dir. The
# read: find the journal whose FIRST line .meta.working_dir equals <home> (exact
# string equality - jcode stores the raw absolute path, no munging), preferring
# the active-pid-confirmed live journal over a stale same-home leftover; the
# context count is the LAST POSITIVE per-record append_messages[].token_usage
# sum (input_tokens + cache_creation_input_tokens + cache_read_input_tokens),
# which skips a trailing degenerate zero-usage turn that would otherwise mask
# real occupancy. Every failure path (no jq, no sessions dir, no working_dir
# match, no usage line, no positive-sum record, or any jcode format shift that
# renames the field or moves the dir) returns empty so the caller treats context
# as unknown and fails closed - it never returns a wrong number. Verified
# 2026-08-01; see docs/secondmate-context-handoff.md.

# fm_sm_jcode_home: jcode's config root - $JCODE_HOME, else ~/.jcode.
fm_sm_jcode_home() {
  printf '%s' "${JCODE_HOME:-$HOME/.jcode}"
}

# fm_sm_jcode_journal: the journal file for the live jcode session launched in
# <home>, or empty when none matches. Selection: among
# <jcode-home>/sessions/session_*.journal.jsonl whose FIRST line
# .meta.working_dir equals <home>, prefer the one whose session_<id> basename is
# present in <jcode-home>/active_pids/ (the running session), falling back to the
# newest-mtime working_dir match when no active-pid match exists (a resumed or
# edge session). Only the first line of each file is parsed for working_dir, so
# the scan stays cheap even with ~130 session files.
fm_sm_jcode_journal() {  # <home>
  local home=$1 jhome sessions pids f base first wd
  local newest='' newest_active=''
  command -v jq >/dev/null 2>&1 || return 0
  [ -n "$home" ] || return 0
  jhome=$(fm_sm_jcode_home)
  sessions="$jhome/sessions"
  pids="$jhome/active_pids"
  [ -d "$sessions" ] || return 0
  for f in "$sessions"/session_*.journal.jsonl; do
    [ -f "$f" ] || continue
    first=$(head -1 "$f" 2>/dev/null || true)
    # Cheap pre-filter: skip a file whose first line has no working_dir at all.
    case "$first" in *'"working_dir"'*) ;; *) continue ;; esac
    wd=$(printf '%s' "$first" | jq -r '.meta.working_dir // empty' 2>/dev/null || true)
    [ "$wd" = "$home" ] || continue
    if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then
      newest=$f
    fi
    # session_<id>.journal.jsonl -> session_<id> is the active_pids basename.
    base=$(basename "$f")
    base=${base%.journal.jsonl}
    if [ -e "$pids/$base" ]; then
      if [ -z "$newest_active" ] || [ "$f" -nt "$newest_active" ]; then
        newest_active=$f
      fi
    fi
  done
  if [ -n "$newest_active" ]; then
    printf '%s' "$newest_active"
  elif [ -n "$newest" ]; then
    printf '%s' "$newest"
  fi
}

# fm_sm_jcode_context_tokens: the last turn's context-window occupancy
# (input + cache_creation + cache_read input tokens) from <home>'s live jcode
# journal. Empty when the journal, jq, or a usable token_usage line is missing,
# or when no record yields a positive sum - the caller then treats context as
# unknown and fails closed.
fm_sm_jcode_context_tokens() {  # <home>
  local f sums s tokens=''
  local home=$1
  command -v jq >/dev/null 2>&1 || return 0
  f=$(fm_sm_jcode_journal "$home") || return 0
  [ -n "$f" ] || return 0
  # Every record carrying a token_usage, in file order; grep streams the file so
  # a multi-MB journal stays cheap on the slow-poll cadence. For each record take
  # its LAST append_messages[].token_usage (the turn's cumulative context) and
  # sum the three input components, guarding each field with // 0 so a renamed
  # field yields 0 (fails closed) rather than misreporting.
  sums=$(grep '"token_usage"' "$f" 2>/dev/null | jq '
      ([.append_messages[]?.token_usage // empty] | last) as $u
    | (($u.input_tokens // 0)
     + ($u.cache_creation_input_tokens // 0)
     + ($u.cache_read_input_tokens // 0))' 2>/dev/null || true)
  [ -n "$sums" ] || return 0
  # Take the last POSITIVE per-record sum, not the last record's sum. A real
  # journal can END on a degenerate token_usage ({"input_tokens":0,
  # "output_tokens":0}, no cache fields - an interrupted, placeholder, or system
  # turn) after many high-usage turns; a naive tail-1 read would sum that to 0,
  # fail the >0 guard, and return unknown, masking real occupancy so no handoff
  # fires (observed live in session_unicorn_... at ~84661 real tokens). Walking
  # to the last positive sum reports the true last real occupancy instead, and
  # still returns empty when NO record is positive (a genuinely empty or
  # format-shifted journal), preserving the fail-closed contract.
  while IFS= read -r s; do
    [[ "$s" =~ ^[0-9]+$ ]] || continue
    [ "$s" -gt 0 ] || continue
    tokens=$s
  done <<EOF
$sums
EOF
  [ -n "$tokens" ] || return 0
  printf '%s' "$tokens"
}

# --- firstmate's OWN context stow-nudge threshold ---------------------------
# The point firstmate's OWN context is considered full enough that the away-mode
# daemon should nudge it to /stow (and /compact when the session cannot
# auto-compact). This is a SEPARATE knob from the secondmate handoff threshold
# above: that one decides when to hand a secondmate off to a fresh agent, this
# one decides when to tell firstmate to persist its own knowledge before a
# context reset can lose it. The daemon owns the crossing logic and the nudge
# (bin/fm-supervise-daemon.sh); this library owns only the threshold read and
# the harness dispatch it shares with the secondmate monitor.
FM_CONTEXT_STOW_THRESHOLD_DEFAULT=200000

# Hysteresis band (in tokens) below the stow threshold at which a fired nudge
# re-arms. The single owner of this number: both the away-mode daemon check
# (bin/fm-supervise-daemon.sh's context_stow_check) and the always-on watcher
# sweep (bin/fm-watch.sh's context_stow_sweep) read it, so a nudge that fired
# once re-arms only after the count drops back below (threshold - hysteresis) -
# a fresh or compacted session - and a count hovering at the line cannot re-fire
# every poll. 20000 is a full compaction's worth of headroom below the 200000
# default threshold.
# shellcheck disable=SC2034 # Read by callers (fm-watch.sh, fm-supervise-daemon.sh), not this lib.
FM_CONTEXT_STOW_HYSTERESIS_DEFAULT=20000

# fm_context_stow_threshold: the configured own-context stow threshold, or the
# default. Reads config/context-stow-threshold (a single integer, first
# non-empty non-comment line). Absent, non-integer, or non-positive falls back
# to the default rather than failing, so a typo never disables the nudge
# silently - identical robustness to fm_sm_context_threshold above.
fm_context_stow_threshold() {  # <config-dir>
  local config=$1 file line
  file="$config/context-stow-threshold"
  [ -f "$file" ] || { printf '%s' "$FM_CONTEXT_STOW_THRESHOLD_DEFAULT"; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    if [[ "$line" =~ ^[1-9][0-9]*$ ]]; then
      printf '%s' "$line"
    else
      printf '%s' "$FM_CONTEXT_STOW_THRESHOLD_DEFAULT"
    fi
    return 0
  done < "$file"
  printf '%s' "$FM_CONTEXT_STOW_THRESHOLD_DEFAULT"
}

# fm_context_stow_directive: the single canonical own-context stow directive both
# supervision paths deliver, so the away-mode daemon nudge and the normal-mode
# watcher wake read identically and can never drift apart. It is a self-executing
# instruction, not an FYI: firstmate should /stow now (persist each durable fact
# to its right home), then /compact, then re-arm supervision, and it must do this
# BEFORE auto-compaction discards un-stowed knowledge - the threshold is tuned
# (config/context-stow-threshold) to leave that window. Keeps the "/stow now" and
# "stow threshold <n>" substrings the callers and tests key on.
fm_context_stow_directive() {  # <tokens> <threshold>
  local tokens=$1 threshold=$2
  printf 'firstmate context %s tokens >= stow threshold %s: /stow now to persist knowledge, then /compact, then re-arm supervision - do this BEFORE auto-compaction can discard un-stowed knowledge' \
    "$tokens" "$threshold"
}

# fm_context_stow_should_nudge: the single owner of the crossing/marker/hysteresis
# state machine both paths share, so neither the daemon nor the watcher forks its
# own copy. Given the live token count, the configured threshold, the hysteresis
# band, and the durable marker path, it decides whether THIS poll should nudge and
# manages the marker atomically:
#   - at/above threshold with no marker: record the marker, return 0 (nudge now)
#   - at/above threshold with a marker already set: return 1 (already nudged this
#     crossing, stay silent)
#   - below (threshold - hysteresis): clear the marker so the next crossing nudges
#     again (a fresh or compacted session), return 1
#   - inside the hysteresis band: leave the marker as-is, return 1
# The caller is responsible for failing closed on an unreadable/non-numeric count
# BEFORE calling this (it assumes numeric inputs); it never reads context itself.
fm_context_stow_should_nudge() {  # <tokens> <threshold> <hysteresis> <marker>
  local tokens=$1 threshold=$2 hysteresis=$3 marker=$4 rearm
  if [ "$tokens" -ge "$threshold" ]; then
    [ -e "$marker" ] && return 1
    date +%s > "$marker"
    return 0
  fi
  rearm=$(( threshold - hysteresis ))
  [ "$rearm" -ge 0 ] || rearm=0
  [ "$tokens" -lt "$rearm" ] && rm -f "$marker"
  return 1
}
