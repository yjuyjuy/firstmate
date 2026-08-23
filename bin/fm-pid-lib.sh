# shellcheck shell=bash
# Shared process-identity helpers.
# Usage: . bin/fm-pid-lib.sh
#
# One owner for "is this pid alive?" and "is this pid still the same process?".
# Sourcing is SIDE-EFFECT FREE on purpose: it defines functions only and creates
# no directories, so a read-only reporting command (bin/fm-session-start.sh
# before its lock decision) can ask these questions without writing anything.
# bin/fm-wake-lib.sh sources it for the queue and lock helpers built on top.

fm_pid_alive() {
  local pid=$1 proc_root stat_line state
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  # kill -0 succeeds on a defunct (zombie) process because its pid still exists
  # in the table, so read the process state and treat Z/defunct as dead: this
  # container's init never reaps zombies, and a bare kill -0 would otherwise let
  # a day-dead holder pin the session lock or the heavy-run queue forever.
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ "$(uname)" = Linux ] && [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 0
    # After the final comm delimiter ')', the next field is the state char.
    read -r state _ <<< "${stat_line##*)}"
    [ "$state" = Z ] && return 1
    return 0
  fi
  # Non-Linux fallback: ps state field, Z (also shown as 'Z+') marks a zombie.
  state=$(ps -o state= -p "$pid" 2>/dev/null | tr -d ' ')
  case "$state" in
    Z*) return 1 ;;
  esac
  return 0
}

fm_pid_identity() {
  local pid=$1 out proc_root stat_line starttime cmdline_hex
  local -a stat_fields
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  # Prefer /proc on Linux: stat field 22 (starttime, clock ticks since boot) is
  # immune to the wall-clock steps that re-render the ps lstart fallback's date
  # (observed as WSL2 btime drift) and would evict a live watcher; combining the
  # full NUL-separated cmdline keeps PID reuse a mismatch even on a tick collision.
  if [ "$(uname)" = Linux ] && [ -r "$proc_root/$pid/stat" ] && [ -r "$proc_root/$pid/cmdline" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    # After the final comm delimiter, array index 19 is proc stat field 22.
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in
      ''|*[!0-9]*) return 1 ;;
    esac
    cmdline_hex=$(od -An -v -tx1 "$proc_root/$pid/cmdline" 2>/dev/null | tr -d '[:space:]') || return 1
    [ -n "$cmdline_hex" ] || return 1
    printf 'linux-starttime=%s cmdline-hex=%s\n' "$starttime" "$cmdline_hex"
    return 0
  fi
  # Pin LC_ALL=C so lstart's date format is locale-invariant: the identity is
  # written under one locale but re-read under the machine's ambient locale, which
  # would otherwise mismatch on a non-C locale (e.g. ko_KR) and reject a live watcher.
  out=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
}
