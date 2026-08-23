#!/usr/bin/env bash
# fm-hourly-lib.sh - arming, cadence, and script mapping for the two
# session-lifetime hourly passes: the session review and the cleanup sweep.
#
# WHY THIS IS ARMED, NOT REMEMBERED: a recurring duty that depends on an agent
# remembering it is a duty that stops happening. The same failure already
# forced the merge queue to become durable state (bin/fm-merge-queue-lib.sh),
# the host-resource monitor to become a watcher sweep, and session start to
# become one script instead of six remembered reads. Arming at session start
# makes both passes structural: they run for the life of the session whether or
# not any turn thinks to run them, and a restarted session re-arms them from
# durable state rather than from conversation memory.
#
# WHY IT RIDES THE EXISTING WATCHER: the supervision cycle is a singleton
# (bin/fm-watch.sh holds .watch.lock), and a second timer would be a second
# supervision cycle by another name. So arming writes durable schedule state
# only; the ONE live watcher decides when a pass is due, runs it the same way
# it runs its other slow-poll sweeps, and enqueues an ordinary `check:` wake.
# Nothing here starts, forks, or backgrounds a process.
#
# WHY EACH PASS IS QUIET BY DEFAULT: an hourly report that says "nothing
# changed" trains the captain to ignore it, which removes the value of the one
# report that does matter. So a pass prints to stdout ONLY when it has a
# finding the fleet has not already been told about; the watcher wakes only on
# non-empty output, exactly like resource_sweep's "report pressure once"
# contract.
#
# Cadence knobs (seconds, 0 disables that pass; see docs/configuration.md):
#   FM_HOURLY_REVIEW_INTERVAL    default 3600
#   FM_HOURLY_CLEANUP_INTERVAL   default 3600

FM_HOURLY_INTERVAL_DEFAULT=3600

# The passes, in run order. Each name maps to a stamp file, a wake key
# ("session-<pass>"), and the script below.
FM_HOURLY_PASSES="review cleanup"

fm_hourly_armed_marker() {  # <state>
  printf '%s/.hourly-armed' "$1"
}

fm_hourly_stamp() {  # <state> <pass>
  printf '%s/.last-hourly-%s' "$1" "$2"
}

# The bin/ script that performs one pass. Kept here so the watcher stays
# generic and the pass set has exactly one owner.
fm_hourly_pass_script() {  # <pass>
  case "$1" in
    review) printf 'fm-session-review.sh' ;;
    cleanup) printf 'fm-cleanup-sweep.sh' ;;
    *) return 1 ;;
  esac
}

# Seconds between runs of one pass. A missing, malformed, or negative value
# falls back to the default rather than disabling the pass silently; an
# explicit 0 disables it.
fm_hourly_interval() {  # <pass>
  local pass=$1 raw
  case "$pass" in
    review) raw=${FM_HOURLY_REVIEW_INTERVAL:-$FM_HOURLY_INTERVAL_DEFAULT} ;;
    cleanup) raw=${FM_HOURLY_CLEANUP_INTERVAL:-$FM_HOURLY_INTERVAL_DEFAULT} ;;
    *) return 1 ;;
  esac
  case "$raw" in
    ''|*[!0-9]*) raw=$FM_HOURLY_INTERVAL_DEFAULT ;;
  esac
  printf '%s' "$raw"
}

fm_hourly_is_armed() {  # <state>
  [ -f "$(fm_hourly_armed_marker "$1")" ]
}

# Arm both passes for this session. Idempotent, and deliberately does NOT touch
# a cadence stamp that already exists: a home whose session restarts more often
# than the interval (a context reset, a watcher restart, a self-update) would
# otherwise never accumulate an elapsed hour and neither pass would ever run.
# Elapsed time therefore survives a restart, and a stamp is created only when it
# is absent, which makes a first arm mean "from here, hourly".
fm_hourly_arm() {  # <state>
  local state=$1 pass stamp
  [ -d "$state" ] || return 1
  touch "$(fm_hourly_armed_marker "$state")" || return 1
  for pass in $FM_HOURLY_PASSES; do
    stamp=$(fm_hourly_stamp "$state" "$pass")
    [ -e "$stamp" ] && continue
    touch "$stamp" || return 1
  done
}

# A persistent secondmate is idle by contract (AGENTS.md section 8), so both
# passes must exclude its metadata from any "work under way" or "has gone quiet"
# judgment: counting it would make in-flight never reach zero, and timing it
# would report a healthy idle endpoint as a stall.
fm_hourly_meta_is_secondmate() {  # <meta>
  grep -q '^kind=secondmate$' "$1" 2>/dev/null
}

# --- shared pass helpers ------------------------------------------------------
# Both passes report only what the fleet has not already been told about, so
# they share one suppression contract: a stable SIGNATURE of the current
# finding set (identities only, never ages or counts that drift every hour) is
# compared against the last surfaced signature. Unchanged findings stay silent;
# a new or changed finding surfaces once; an empty finding set re-arms silently,
# the same shape as bin/fm-watch.sh's resource_sweep.

fm_hourly_surfaced_marker() {  # <state> <pass>
  printf '%s/.hourly-%s-surfaced' "$1" "$2"
}

# Report accumulator, shared by both passes so the report shape has one owner.
# FM_HOURLY_SIGNATURE carries IDENTITY only - never an age or a count - so a
# finding that is still true an hour later produces the same signature and stays
# silent, while a genuinely new one surfaces.
FM_HOURLY_SIGNATURE=
FM_HOURLY_REPORT=
FM_HOURLY_FINDINGS=0
FM_HOURLY_HEADLINES=

fm_hourly_reset_findings() {
  FM_HOURLY_SIGNATURE=
  FM_HOURLY_REPORT=
  FM_HOURLY_FINDINGS=0
  FM_HOURLY_HEADLINES=
}

fm_hourly_add_finding() {  # <signature-key> <headline> <report-line>
  FM_HOURLY_SIGNATURE="$FM_HOURLY_SIGNATURE$1
"
  FM_HOURLY_FINDINGS=$(( FM_HOURLY_FINDINGS + 1 ))
  [ -n "$FM_HOURLY_HEADLINES" ] && FM_HOURLY_HEADLINES="$FM_HOURLY_HEADLINES; "
  FM_HOURLY_HEADLINES="$FM_HOURLY_HEADLINES$2"
  FM_HOURLY_REPORT="$FM_HOURLY_REPORT- $3
"
}

# Key-safe rendering of a task id or window value for use inside a marker file
# name, matching the mangling the watcher already applies to its own markers.
fm_hourly_marker_key() {  # <value>
  printf '%s' "$1" | tr './:' '___'
}

# First-seen marker for one open decision. The status FILE's mtime cannot age a
# decision: any later unrelated append (progress, paused) would reset it, so a
# decision nobody answered for a day would never cross the threshold. The marker
# records when the decision was first observed open, and is cleared when it
# resolves.
fm_hourly_decision_marker() {  # <state> <id> <key>
  printf '%s/.hourly-decision-%s__%s' \
    "$1" "$(fm_hourly_marker_key "$2")" "$(fm_hourly_marker_key "$3")"
}

fm_hourly_report_path() {  # <state> <pass>
  printf '%s/.hourly-%s.latest' "$1" "$2"
}

# 0 when this signature is new or changed and should surface, 1 when it is
# unchanged. Records the signature as surfaced on a 0 return. An empty
# signature clears the marker and always returns 1 (nothing to say).
fm_hourly_should_surface() {  # <state> <pass> <signature>
  local state=$1 pass=$2 signature=$3 marker last
  marker=$(fm_hourly_surfaced_marker "$state" "$pass")
  # Callers accumulate one signature line per finding, so the value arrives with
  # a trailing newline that `cat` would strip on the read side. Normalize here
  # so a stored signature compares equal to the one that produced it.
  while [ "${signature%$'\n'}" != "$signature" ]; do
    signature=${signature%$'\n'}
  done
  if [ -z "$signature" ]; then
    rm -f "$marker" 2>/dev/null || true
    return 1
  fi
  last=$(cat "$marker" 2>/dev/null || printf '')
  [ "$signature" = "$last" ] && return 1
  # A marker that cannot be written costs a repeated report; a marker whose
  # failure suppressed the report would cost the report itself, so err toward
  # surfacing.
  printf '%s\n' "$signature" > "$marker" 2>/dev/null || true
  return 0
}

# mtime reader, detected once for the running OS. BSD/macOS stat uses -f %m; GNU
# stat uses -c %Y. This must NOT be written as `stat -f %m ... || stat -c %Y ...`
# inside a command substitution: on GNU, `stat -f` is --file-system and prints a
# filesystem block to STDOUT with a nonzero exit, so the `||` form concatenates
# that block with the fallback's real value and corrupts the mtime. Mirrors
# bin/fm-watch.sh's stat_mtime, which detects the flavor for the same reason.
if stat -f %m . >/dev/null 2>&1; then
  _fm_hourly_stat_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  _fm_hourly_stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

# Age of a file in whole seconds, or a very large number when it does not
# exist. Mirrors bin/fm-watch.sh's age_of so a missing stamp reads as overdue.
fm_hourly_age_of() {  # <path>
  local f=$1 mtime now
  [ -e "$f" ] || { printf '999999999'; return 0; }
  mtime=$(_fm_hourly_stat_mtime "$f")
  case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
  now=$(date +%s)
  printf '%s' $(( now - mtime ))
}

# "2h10m" style age, for report prose.
fm_hourly_human_age() {  # <seconds>
  local s=$1
  case "$s" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  if [ "$s" -lt 3600 ]; then
    printf '%dm' $(( s / 60 ))
  else
    printf '%dh%dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
  fi
}
