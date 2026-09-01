#!/usr/bin/env bash
# fm-lavish-lan.sh - expose a running lavish-axi review server to the home LAN so
# the captain can open Lavish artifacts from a phone that VPNs into the network.
#
# WHY: lavish-axi's own server binds 127.0.0.1 only and has no host/bind flag, so
# nothing off the loopback interface can reach it. This starts a raw-TCP relay
# that listens on a LAN-reachable address and forwards every byte to lavish's
# loopback port, in both directions, without parsing the stream. Because it is a
# raw passthrough and NOT an HTTP proxy, the WebSocket upgrade and live frames
# lavish depends on pass through untouched, and the URL path is preserved: the
# phone opens http://<lan-ip>:<port>/session/<id> and reaches lavish's own
# http://127.0.0.1:<target>/session/<id>. The byte forwarding lives in the tracked
# companion bin/fm-lavish-lan-relay.js; this script owns only the lifecycle.
#
# REACHABILITY TRADEOFF: the relay binds 0.0.0.0 by default, so WHILE IT IS UP any
# host on the home network (and anything on the captain's VPN) can reach the
# lavish server, not just the captain's phone. That is the deliberate, accepted
# posture - the VPN already gates who is on the network, and nothing here touches
# the public internet, needs a third-party account, or replaces the VPN. `start`
# prints this notice every time. To narrow exposure to a single interface, pass
# `--bind <address>` (or FM_LAVISH_LAN_BIND); 0.0.0.0 stays the default because a
# single-interface bind can silently miss the VPN interface the phone arrives on,
# which is the exact reachability this exists to provide.
#
# Idempotent by pidfile: a second `start` refuses rather than launching a rival
# relay on the same port. `stop` signals only this home's recorded relay and waits
# for it to exit. Both operate on this FM_HOME's own state, never another home's.
#
# Usage:
#   fm-lavish-lan.sh start [--session <id>] [--port <n>] [--target <n>] [--bind <addr>]
#       Start the relay (idempotent) and print the reachability notice plus the LAN
#       URL to hand the captain. With --session, the URL includes /session/<id>;
#       without it, the base LAN URL is printed for the captain to append their own
#       session path. Exit 0 on start or already-running, non-zero on failure.
#   fm-lavish-lan.sh url [--session <id>]
#       Print the LAN URL for the running relay without touching it. Exit 1 if the
#       relay is not running.
#   fm-lavish-lan.sh status
#       Print running/not-running with pid, bind, and port. Exit 0 if running.
#   fm-lavish-lan.sh stop
#       Stop this home's relay and wait for it to exit. Exit 0 whether or not one
#       was running (stopping an absent relay is not an error).
#   fm-lavish-lan.sh -h | --help
#       Print this header.
#
# Defaults (env overrides in parentheses):
#   listen port   4388  (FM_LAVISH_LAN_PORT)     - matches the 2026-07-23 stopgap
#   target port   4387  (FM_LAVISH_LAN_TARGET)   - lavish-axi's loopback port
#   bind address  0.0.0.0 (FM_LAVISH_LAN_BIND)
# A --flag always wins over the matching environment variable.
#
# Exit status:
#   0   success (started, already running, stopped, status running, url printed)
#   1   status/url: relay not running; or a runtime failure
#   2   usage error
#   3   start: the listen port is already in use by something that is NOT this
#       relay (a stale non-relay listener, or another tool)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# FM_ROOT/FM_HOME/STATE and die (exit 2 default) come from the shared preamble.
FM_PROG=fm-lavish-lan FM_DIE_CODE=2
# shellcheck source=bin/fm-preamble-lib.sh
. "$SCRIPT_DIR/fm-preamble-lib.sh"

# shellcheck source=bin/fm-pid-lib.sh
. "$SCRIPT_DIR/fm-pid-lib.sh"

RELAY="$SCRIPT_DIR/fm-lavish-lan-relay.js"
PIDFILE="$STATE/.lavish-lan.pid"
METAFILE="$STATE/.lavish-lan.meta"
LOG="$STATE/.lavish-lan.log"

DEFAULT_PORT=4388
DEFAULT_TARGET=4387
DEFAULT_BIND=0.0.0.0

PORT="${FM_LAVISH_LAN_PORT:-$DEFAULT_PORT}"
TARGET="${FM_LAVISH_LAN_TARGET:-$DEFAULT_TARGET}"
BIND="${FM_LAVISH_LAN_BIND:-$DEFAULT_BIND}"
SESSION=""

usage() {
  # Print the header comment block (lines beginning with '# ') as help.
  sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed -e '/^set -u/d' -e 's/^# \{0,1\}//'
}

require_port() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*) die "$1 must be a positive integer (got '$2')" ;;
  esac
  [ "$2" -ge 1 ] && [ "$2" -le 65535 ] || die "$1 must be 1-65535 (got '$2')"
}

# A live relay is a pidfile whose pid is alive, NOT a zombie, AND whose /proc
# command line is our relay. A recycled pid that now belongs to an unrelated
# process must read as dead, never as a running relay. A zombie (state Z) must
# read as dead too: when this host's pid 1 does not reap orphans, a stopped relay
# lingers as <defunct> and kill -0 still succeeds on it, so an exit-state check is
# what actually proves the relay is gone after stop.
relay_alive_pid() {
  local pid cmd
  [ -f "$PIDFILE" ] || return 1
  pid=$(head -n1 "$PIDFILE" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  # Route liveness (including the zombie STAT Z check) through the shared pid lib
  # so a defunct relay reads as dead exactly as every other holder check does.
  fm_pid_alive "$pid" || return 1
  # Confirm identity where /proc is available; where it is not, a live recorded
  # pid plus our own pidfile is the best signal and is accepted.
  if [ -r "/proc/$pid/cmdline" ]; then
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
    case "$cmd" in
      *fm-lavish-lan-relay.js*) ;;
      *) return 1 ;;
    esac
  fi
  printf '%s\n' "$pid"
}

# Discover a LAN-reachable IPv4 address to show in the URL. The src of the default
# route is a last resort; the Tailscale address is preferred because the captain's
# phone arrives over the VPN. This is display only - the relay's actual reach
# is set by --bind, not by this discovery.
discover_lan_ip() {
  local ip
  # Prefer the Tailscale address: the captain's phone arrives over the VPN, and
  # in containers the default-route src is a bridge address no phone can reach.
  ip=$(tailscale ip -4 2>/dev/null | head -n1)
  if [ -z "$ip" ]; then
    ip=$(ip -4 addr show tailscale0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -n1)
  fi
  if [ -z "$ip" ]; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1)
  fi
  if [ -z "$ip" ]; then
    ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9.]+$' | head -n1)
  fi
  [ -n "$ip" ] || ip="127.0.0.1"
  printf '%s\n' "$ip"
}

print_url() {  # <lan-ip>
  local ip=$1 base
  base="http://$ip:$PORT"
  if [ -n "$SESSION" ]; then
    echo "$base/session/$SESSION"
  else
    echo "$base"
    echo "fm-lavish-lan: append the lavish session path, e.g. $base/session/<id>"
  fi
}

load_meta() {  # populate PORT/BIND from the running relay's recorded meta
  [ -f "$METAFILE" ] || return 0
  local key val
  while IFS='=' read -r key val; do
    case "$key" in
      port) PORT=$val ;;
      bind) BIND=$val ;;
      target) TARGET=$val ;;
    esac
  done < "$METAFILE"
}

parse_common_flags() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session) SESSION=${2:?--session needs a value}; shift 2 ;;
      --session=*) SESSION=${1#--session=}; shift ;;
      --port) PORT=${2:?--port needs a value}; shift 2 ;;
      --port=*) PORT=${1#--port=}; shift ;;
      --target) TARGET=${2:?--target needs a value}; shift 2 ;;
      --target=*) TARGET=${1#--target=}; shift ;;
      --bind) BIND=${2:?--bind needs a value}; shift 2 ;;
      --bind=*) BIND=${1#--bind=}; shift ;;
      *) die "unknown option '$1' (see --help)" ;;
    esac
  done
}

cmd_start() {
  parse_common_flags "$@"
  require_port "port" "$PORT"
  require_port "target" "$TARGET"
  [ -f "$RELAY" ] || die "missing relay companion $RELAY" 1
  command -v node >/dev/null 2>&1 || die "node not found on PATH" 1

  local pid
  if pid=$(relay_alive_pid); then
    load_meta
    echo "fm-lavish-lan: already running pid=$pid bind=$BIND port=$PORT -> 127.0.0.1:$TARGET"
    print_reachability_notice
    print_url "$(discover_lan_ip)"
    return 0
  fi

  # A stale pidfile from a crashed relay must not block a fresh start.
  rm -f "$PIDFILE" 2>/dev/null || true
  mkdir -p "$STATE" 2>/dev/null || true

  local child=""
  if ! launch_relay; then
    die "cannot detach relay (need setsid or perl)" 1
  fi

  # The relay writes the pidfile only once it is actually listening, so the
  # pidfile's appearance is the readiness signal. If the child dies first
  # (EADDRINUSE or a bind error), report that instead of a false start.
  local i=0
  while [ "$i" -lt 50 ]; do
    if [ -f "$PIDFILE" ] && relay_alive_pid >/dev/null; then
      printf 'port=%s\nbind=%s\ntarget=%s\n' "$PORT" "$BIND" "$TARGET" > "$METAFILE" 2>/dev/null || true
      echo "fm-lavish-lan: started pid=$(head -n1 "$PIDFILE") bind=$BIND port=$PORT -> 127.0.0.1:$TARGET"
      print_reachability_notice
      print_url "$(discover_lan_ip)"
      return 0
    fi
    if [ -n "$child" ] && ! kill -0 "$child" 2>/dev/null; then
      # Child exited before listening. Its exit code distinguishes port-in-use.
      wait "$child" 2>/dev/null
      local rc=$?
      if [ "$rc" -eq 3 ]; then
        die "port $PORT is already in use by something that is not this relay" 3
      fi
      die "relay failed to start (exit $rc); see $LOG" 1
    fi
    sleep 0.1
    i=$((i + 1))
  done
  # Timed out waiting; do not leave a rival running. The detached relay may be a
  # grandchild whose pid we never captured, so fall back to the pidfile.
  if [ -n "$child" ]; then
    kill "$child" 2>/dev/null || true
  elif [ -f "$PIDFILE" ]; then
    local stray
    stray=$(head -n1 "$PIDFILE" 2>/dev/null || true)
    case "$stray" in ''|*[!0-9]*) ;; *) kill "$stray" 2>/dev/null || true ;; esac
  fi
  die "relay did not become ready within 5s; see $LOG" 1
}

# Launch the relay detached so a closing terminal (SIGHUP) or a completed harness
# background task cannot reap it. Prefer setsid; fall back to a perl fork+setsid
# where setsid(1) is absent (e.g. macOS), matching bin/fm-present-daemon.sh. On the
# setsid path $! is the relay pid (captured in child); the perl fallback exits its
# parent immediately, so child stays empty and readiness relies on the pidfile.
launch_relay() {
  export FM_LL_BIND="$BIND" FM_LL_PORT="$PORT" \
    FM_LL_TARGET_HOST="127.0.0.1" FM_LL_TARGET_PORT="$TARGET" \
    FM_LL_PIDFILE="$PIDFILE"
  if command -v setsid >/dev/null 2>&1; then
    setsid node "$RELAY" >> "$LOG" 2>&1 < /dev/null &
    child=$!
    return 0
  fi
  command -v perl >/dev/null 2>&1 || return 1
  # shellcheck disable=SC2016 # $pid/@ARGV are perl, not shell, expansions.
  perl -e '
    use POSIX qw(setsid);
    my $pid = fork();
    die "fork failed" unless defined $pid;
    exit 0 if $pid;
    setsid();
    exec @ARGV or die "exec failed";
  ' node "$RELAY" >> "$LOG" 2>&1 < /dev/null
  child=""
  return 0
}

print_reachability_notice() {
  echo "fm-lavish-lan: NOTICE - while up, anything on the home network or VPN can reach this lavish server (bind $BIND). Run 'fm-lavish-lan.sh stop' when done."
}

cmd_url() {
  parse_common_flags "$@"
  relay_alive_pid >/dev/null || die "relay not running" 1
  load_meta
  print_url "$(discover_lan_ip)"
}

cmd_status() {
  local pid
  if pid=$(relay_alive_pid); then
    load_meta
    echo "fm-lavish-lan: running pid=$pid bind=$BIND port=$PORT -> 127.0.0.1:$TARGET"
    return 0
  fi
  echo "fm-lavish-lan: not running"
  return 1
}

# True once the pid is gone OR has become a zombie (exited but not yet reaped by
# an init that does not reap). Either way the relay has stopped serving, so the
# stop wait must not spin the full timeout on a <defunct> process.
pid_stopped() {  # <pid>
  local pid=$1
  # Stopped means the shared reader no longer sees a live process: a gone pid or
  # a defunct STAT Z both read as dead, so the stop wait never spins the full
  # timeout on a lingering <defunct>.
  fm_pid_alive "$pid" && return 1
  return 0
}

cmd_stop() {
  local pid
  if ! pid=$(relay_alive_pid); then
    echo "fm-lavish-lan: not running"
    rm -f "$PIDFILE" "$METAFILE" 2>/dev/null || true
    return 0
  fi
  kill "$pid" 2>/dev/null || true
  local i=0
  while [ "$i" -lt 50 ]; do
    pid_stopped "$pid" && break
    sleep 0.1
    i=$((i + 1))
  done
  if ! pid_stopped "$pid"; then
    kill -9 "$pid" 2>/dev/null || true
    sleep 0.2
  fi
  rm -f "$PIDFILE" "$METAFILE" 2>/dev/null || true
  echo "fm-lavish-lan: stopped pid=$pid"
  return 0
}

# When sourced (e.g. by a colocated test exercising the liveness helpers), define
# functions only and run no subcommand dispatch.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  [ "$#" -ge 1 ] || { usage; exit 2; }
  SUB=$1
  shift
  case "$SUB" in
    start) cmd_start "$@" ;;
    url) cmd_url "$@" ;;
    status) cmd_status "$@" ;;
    stop) cmd_stop "$@" ;;
    -h|--help) usage ;;
    *) die "unknown subcommand '$SUB' (see --help)" ;;
  esac
fi
