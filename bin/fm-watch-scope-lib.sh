# shellcheck shell=bash
# Shared home-scoped watcher/arm process enumeration.
# Usage: . bin/fm-watch-scope-lib.sh
#
# One owner for "which watcher/arm processes belong to THIS home?", so the
# tangle-collapse path (bin/fm-watch-arm.sh --converge) and the wake-path
# ownership guard (fm_wake_path_owned in bin/fm-supervision-lib.sh) share ONE
# audited scoping implementation rather than two subtly-different ones - a real
# hazard given the AGENTS.md hard rule against a cross-home kill.
#
# Home scoping comes from the ABSOLUTE path of the script in the process cmdline.
# A watcher for this home runs `bash <abs>/bin/fm-watch.sh` and an arm-loop runs
# `bash <abs>/bin/fm-watch-arm.sh`, where <abs> is this home's own tracked code
# root. A sibling firstmate home or a secondmate runs the SAME script name from a
# DIFFERENT absolute path, so an EXACT absolute-path argv match is inherently
# home-scoped and can never select another home's process. This is the exact
# opposite of the forbidden `pkill -f bin/fm-watch.sh` / `pkill -f fm-watch-arm`,
# which match the bare relative fragment across every home and every secondmate.
#
# Matching is EXACT-argument, never substring: a pid is selected only when one of
# its NUL-separated cmdline arguments equals the target absolute path verbatim.
# That keeps `<abs>/bin/fm-watch.sh` from ever matching an arm at
# `<abs>/bin/fm-watch-arm.sh` (different final component) and keeps a decoy path
# that merely contains the target as a substring from matching.
#
# Linux reads /proc/<pid>/cmdline (the same NUL-separated identity source
# bin/fm-pid-lib.sh already uses); a non-Linux host falls back to `ps`. Both honor
# FM_PROC_ROOT_OVERRIDE for hermetic tests, mirroring fm-pid-lib.sh.

# fm_home_scope_pids_for <absolute-script-path> [exclude-pid...]
# Print, one per line, the pids whose cmdline contains <absolute-script-path> as
# an exact argument, excluding any pid listed after the path and excluding this
# shell's own pid. Internal helper; callers use the two wrappers below.
fm_home_scope_pids_for() {
  local target=$1
  shift
  local self=${BASHPID:-$$}
  local exclude_list=" $self "
  local proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  local pid excl cmdline_file arg matched

  [ -n "$target" ] || return 0
  for excl in "$@"; do
    case "$excl" in
      ''|*[!0-9]*) continue ;;
    esac
    exclude_list="$exclude_list$excl "
  done

  if [ "$(uname)" = Linux ] && [ -d "$proc_root" ]; then
    for cmdline_file in "$proc_root"/*/cmdline; do
      [ -r "$cmdline_file" ] || continue
      pid=${cmdline_file%/cmdline}
      pid=${pid##*/}
      case "$pid" in
        ''|*[!0-9]*) continue ;;
      esac
      case "$exclude_list" in
        *" $pid "*) continue ;;
      esac
      matched=0
      # Read NUL-separated arguments and compare each one exactly.
      while IFS= read -r -d '' arg; do
        if [ "$arg" = "$target" ]; then
          matched=1
          break
        fi
      done < "$cmdline_file"
      [ "$matched" -eq 1 ] && printf '%s\n' "$pid"
    done
    return 0
  fi

  # Non-Linux fallback: ps command line, matched exactly on a whitespace-bounded
  # occurrence of the absolute path so a substring path never matches.
  while IFS= read -r pid arg; do
    case "$pid" in
      ''|*[!0-9]*) continue ;;
    esac
    case "$exclude_list" in
      *" $pid "*) continue ;;
    esac
    case " $arg " in
      *" $target "*) printf '%s\n' "$pid" ;;
    esac
  done < <(ps -A -o pid=,command= 2>/dev/null)
  return 0
}

# fm_home_watcher_pids <script-dir> [exclude-pid...]
# Print this home's live watcher pids (processes running <script-dir>/fm-watch.sh
# by absolute path). <script-dir> is the tracked bin/ directory whose absolute
# path scopes the match to this home.
fm_home_watcher_pids() {
  local script_dir=$1
  shift
  fm_home_scope_pids_for "$script_dir/fm-watch.sh" "$@"
}

# fm_home_arm_pids <script-dir> [exclude-pid...]
# Print this home's live arm-loop pids (processes running
# <script-dir>/fm-watch-arm.sh by absolute path). Callers that run from inside an
# arm process (e.g. --converge) must pass their own pid as an exclude so a
# convergence never targets itself.
fm_home_arm_pids() {
  local script_dir=$1
  shift
  fm_home_scope_pids_for "$script_dir/fm-watch-arm.sh" "$@"
}
