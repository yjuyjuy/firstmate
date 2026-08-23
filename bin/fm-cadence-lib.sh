#!/usr/bin/env bash
# fm-cadence-lib.sh - the single owner of watcher-cadence knob resolution.
#
# One place resolves the three watcher cadence knobs (poll, signal_grace,
# heartbeat) from their config owner and their environment fallback, so the
# watcher (bin/fm-watch.sh) that CONSUMES a knob and the drift alarm
# (bin/fm-drift-check.sh) that AUDITS it can never disagree about what the live
# value is. docs/configuration.md "Watcher cadence (config/watcher-cadence)" owns
# the knob's user-facing contract; this file owns the resolver it describes.
#
# PRECEDENCE (config-authoritative, deliberately config-over-environment):
#   1. config/watcher-cadence, key present with a VALID value -> that value wins.
#   2. config/watcher-cadence, key present but MALFORMED         -> the built-in
#      default, reported LOUDLY (never silently); the environment is not consulted
#      for that key, because the captain-owned file said something and the reader
#      must not paper over it with a possibly-stale environment value.
#   3. config file absent, or key absent/empty -> the environment variable when it
#      is set and valid (operator override and test seam); a set-but-malformed
#      environment value falls to the default loudly; unset -> the default.
#
# This is the FIX for the settings.local.json drift class: the captain's owning
# file, when it speaks, outranks a stale FM_POLL that a prior debugging session
# left in the environment. The environment stays reachable only where the owner
# file is silent, which keeps every test seam (FM_POLL=1 with no cadence file)
# and the genuine one-off operator override working.
#
# The resolver writes its result and any warnings into GLOBALS rather than
# stdout, on purpose: a command substitution ($(...)) runs in a subshell, so a
# warning appended there would be lost. The caller reads FM_CADENCE_RESULT (and
# accumulates FM_CADENCE_WARNINGS) right after each call.
#
# The file format is one `key = value` per line; blank lines and #-comments are
# ignored; the last occurrence of a key wins; a value must be a non-negative
# integer number of seconds. Recognized keys: signal_grace, poll, heartbeat.
# An unrecognized key is itself a loud condition (the file said something the
# reader could not honor).

# Guard against double-sourcing so a script that sources both this and something
# that also sources it does not redefine the functions or reset the globals.
[ -n "${_FM_CADENCE_LIB_SOURCED:-}" ] && return 0
_FM_CADENCE_LIB_SOURCED=1

# Accumulated, human-readable warnings from the most recent resolve pass. The
# caller resets this to "" before a batch of fm_cadence_resolve calls and reads
# it once after.
FM_CADENCE_WARNINGS=""
# The resolved integer from the most recent fm_cadence_resolve call.
# shellcheck disable=SC2034  # read by sourcing scripts (fm-watch.sh, fm-drift-check.sh)
FM_CADENCE_RESULT=""

# The recognized cadence keys and their built-in defaults, as one owner. The
# drift alarm iterates this same list so it audits exactly the knobs the watcher
# consumes, with the same defaults, and never a hand-copied second list.
# Format: "<file-key> <env-var> <default-seconds>".
fm_cadence_registry() {
  cat <<'EOF'
poll FM_POLL 300
signal_grace FM_SIGNAL_GRACE 240
heartbeat FM_HEARTBEAT 600
EOF
}

_fm_cadence_is_uint() {  # <value> -> 0 when a non-negative integer
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Read a single key's raw value from a cadence file, or print nothing. The last
# matching, non-comment line wins; surrounding whitespace is stripped.
_fm_cadence_file_value() {  # <file> <key>
  local file=$1 key=$2
  [ -f "$file" ] || return 0
  sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$file" 2>/dev/null \
    | grep -v '^[[:space:]]*#' | tail -n 1 | tr -d '[:space:]'
}

# Resolve one cadence knob into FM_CADENCE_RESULT, appending any warning to
# FM_CADENCE_WARNINGS. See the PRECEDENCE block at the top.
# Usage: fm_cadence_resolve <cadence-file> <env-var-name> <file-key> <default>
fm_cadence_resolve() {  # <cadence-file> <env-var-name> <file-key> <default>
  local file=$1 env_name=$2 key=$3 default=$4 env_val file_val
  # 1 + 2: the owning config file, when it names this key, decides.
  file_val=$(_fm_cadence_file_value "$file" "$key")
  if [ -n "$file_val" ]; then
    if _fm_cadence_is_uint "$file_val"; then
      FM_CADENCE_RESULT=$file_val; return 0
    fi
    FM_CADENCE_WARNINGS="$FM_CADENCE_WARNINGS${FM_CADENCE_WARNINGS:+; }malformed $key '$file_val' in $file, using default ${default}s"
    FM_CADENCE_RESULT=$default; return 0
  fi
  # 3: the owner file is silent on this key, so the environment may speak.
  eval "env_val=\${$env_name:-}"
  if [ -n "$env_val" ]; then
    if _fm_cadence_is_uint "$env_val"; then
      FM_CADENCE_RESULT=$env_val; return 0
    fi
    FM_CADENCE_WARNINGS="$FM_CADENCE_WARNINGS${FM_CADENCE_WARNINGS:+; }malformed \$$env_name '$env_val', using default ${default}s"
    FM_CADENCE_RESULT=$default; return 0
  fi
  # shellcheck disable=SC2034  # FM_CADENCE_RESULT read by sourcing scripts
  FM_CADENCE_RESULT=$default
}

# Scan a cadence file for keys the resolver does not recognize and append one
# loud warning per typo to FM_CADENCE_WARNINGS, so a mistyped knob is surfaced
# instead of silently ignored. No-op when the file is absent.
fm_cadence_scan_unknown_keys() {  # <cadence-file>
  local file=$1 line stripped key known
  [ -f "$file" ] || return 0
  known=" $(fm_cadence_registry | awk '{print $1}' | tr '\n' ' ') "
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$stripped" in ''|'#'*) continue ;; esac
    key=${stripped%%=*}; key=$(printf '%s' "$key" | tr -d '[:space:]')
    case "$known" in
      *" $key "*) ;;
      *) FM_CADENCE_WARNINGS="$FM_CADENCE_WARNINGS${FM_CADENCE_WARNINGS:+; }unknown cadence key '$key' in $file, ignored" ;;
    esac
  done < "$file"
}
