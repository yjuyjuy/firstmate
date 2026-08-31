#!/usr/bin/env bash
# tests/fm-watch-scope.test.sh - home-scoped watcher/arm pid enumeration.
#
# The single safety property that matters here: absolute-path scoping must select
# THIS home's watcher/arm processes and NEVER a decoy sibling-home process that
# runs the same script name from a different absolute path. A regression here
# would reintroduce the cross-home kill the AGENTS.md hard rule forbids.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCOPE_LIB="$ROOT/bin/fm-watch-scope-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-scope-tests)

# Install a runnable stand-in for a named script at <home>/bin/<name> that just
# sleeps, so a launched process carries the exact absolute path in its cmdline.
install_fake_script() {  # <home> <name>
  local home=$1 name=$2
  mkdir -p "$home/bin"
  cat > "$home/bin/$name" <<'SH'
#!/usr/bin/env bash
sleep 60
SH
  chmod +x "$home/bin/$name"
  printf '%s\n' "$home/bin/$name"
}

# Launch `bash <abs-script>` and echo its pid, waiting until it is live. The
# child's stdio is detached to /dev/null so it never holds the command
# substitution pipe open (which would both hang the caller and, on subshell exit,
# reap the child before the enumeration runs).
launch_script() {  # <abs-script>
  local script=$1 pid i
  bash "$script" </dev/null >/dev/null 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 50 ] && ! kill -0 "$pid" 2>/dev/null; do
    sleep 0.02
    i=$((i + 1))
  done
  printf '%s\n' "$pid"
}

scope_pids() {  # <fn> <script-dir> [exclude...]
  local fn=$1
  shift
  local script_dir=$1
  shift
  bash -c '. "$1"; shift; fn=$1; shift; "$fn" "$@"' _ "$SCOPE_LIB" "$fn" "$script_dir" "$@" | sort -n
}

test_watcher_pids_selects_this_home() {
  local home script pid found
  home="$TMP_ROOT/watcher-this-home"
  script=$(install_fake_script "$home" fm-watch.sh)
  pid=$(launch_script "$script")
  found=$(scope_pids fm_home_watcher_pids "$home/bin")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  case " $(printf '%s' "$found" | tr '\n' ' ') " in
    *" $pid "*) ;;
    *) fail "fm_home_watcher_pids did not find this home's watcher pid $pid (found: $found)" ;;
  esac
  pass "fm_home_watcher_pids selects this home's watcher process by absolute path"
}

# THE cross-home-safety regression: a decoy watcher launched from a DIFFERENT
# absolute path (a sibling home) must NEVER be selected.
test_scope_never_matches_decoy_sibling_home() {
  local home decoy this_script decoy_script this_pid decoy_pid found
  home="$TMP_ROOT/scope-this"
  decoy="$TMP_ROOT/scope-sibling"
  this_script=$(install_fake_script "$home" fm-watch.sh)
  decoy_script=$(install_fake_script "$decoy" fm-watch.sh)
  this_pid=$(launch_script "$this_script")
  decoy_pid=$(launch_script "$decoy_script")
  found=$(scope_pids fm_home_watcher_pids "$home/bin")
  kill "$this_pid" "$decoy_pid" 2>/dev/null || true
  wait "$this_pid" 2>/dev/null || true
  wait "$decoy_pid" 2>/dev/null || true
  case " $(printf '%s' "$found" | tr '\n' ' ') " in
    *" $decoy_pid "*) fail "absolute-path scoping WRONGLY matched a decoy sibling-home watcher pid $decoy_pid (found: $found)" ;;
  esac
  case " $(printf '%s' "$found" | tr '\n' ' ') " in
    *" $this_pid "*) ;;
    *) fail "absolute-path scoping missed this home's own watcher pid $this_pid (found: $found)" ;;
  esac
  pass "absolute-path scoping never matches a decoy sibling-home watcher, only this home's own"
}

# The arm helper must not confuse an arm-loop with a watcher: fm-watch.sh and
# fm-watch-arm.sh share a prefix, so an exact-argument match (not substring) is
# required. A watcher must not appear in the arm list and vice versa.
test_arm_and_watcher_are_disjoint() {
  local home watch_script arm_script wpid apid watcher_found arm_found
  home="$TMP_ROOT/arm-watcher-disjoint"
  watch_script=$(install_fake_script "$home" fm-watch.sh)
  arm_script=$(install_fake_script "$home" fm-watch-arm.sh)
  wpid=$(launch_script "$watch_script")
  apid=$(launch_script "$arm_script")
  watcher_found=$(scope_pids fm_home_watcher_pids "$home/bin")
  arm_found=$(scope_pids fm_home_arm_pids "$home/bin")
  kill "$wpid" "$apid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  wait "$apid" 2>/dev/null || true
  case " $(printf '%s' "$watcher_found" | tr '\n' ' ') " in
    *" $wpid "*) ;;
    *) fail "watcher scoping missed the watcher pid $wpid (found: $watcher_found)" ;;
  esac
  case " $(printf '%s' "$watcher_found" | tr '\n' ' ') " in
    *" $apid "*) fail "watcher scoping wrongly matched the arm-loop pid $apid (fm-watch-arm.sh is not fm-watch.sh)" ;;
  esac
  case " $(printf '%s' "$arm_found" | tr '\n' ' ') " in
    *" $apid "*) ;;
    *) fail "arm scoping missed the arm-loop pid $apid (found: $arm_found)" ;;
  esac
  case " $(printf '%s' "$arm_found" | tr '\n' ' ') " in
    *" $wpid "*) fail "arm scoping wrongly matched the watcher pid $wpid" ;;
  esac
  pass "watcher and arm enumeration stay disjoint (exact-argument match, not substring)"
}

test_exclude_pid_is_honored() {
  local home arm_script apid found
  home="$TMP_ROOT/arm-exclude"
  arm_script=$(install_fake_script "$home" fm-watch-arm.sh)
  apid=$(launch_script "$arm_script")
  found=$(scope_pids fm_home_arm_pids "$home/bin" "$apid")
  kill "$apid" 2>/dev/null || true
  wait "$apid" 2>/dev/null || true
  case " $(printf '%s' "$found" | tr '\n' ' ') " in
    *" $apid "*) fail "an explicitly excluded arm pid $apid was still returned (found: $found)" ;;
  esac
  pass "an explicitly excluded pid is never returned (a converge never targets itself)"
}

test_watcher_pids_selects_this_home
test_scope_never_matches_decoy_sibling_home
test_arm_and_watcher_are_disjoint
test_exclude_pid_is_honored
