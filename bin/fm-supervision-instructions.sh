#!/usr/bin/env bash
# Render the primary-harness supervision operating block for session start and
# the short repair line used by guards and turn-end hooks.
#
# Away POSTURE and supervision OWNERSHIP are two different things and take two
# different arguments. --afk means a live away-mode daemon owns the watcher for
# this home; --away-posture means state/.afk is set. A home whose captain session
# runs outside any injectable supervisor pane runs the away posture with no
# daemon, so it reports "--away-posture 1 --afk 0" and keeps this session's own
# watcher as the real supervision mechanism.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$REPO_ROOT}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DOC_DIR="$REPO_ROOT/docs/supervision-protocols"

HARNESS=
READ_ONLY=0
AFK=0
AWAY_POSTURE=0
X_MODE=0
REPAIR_LINE=0
QUEUE_PENDING=0
PRESENT_DAEMON=

usage() {
  cat <<'EOF'
Usage: fm-supervision-instructions.sh [--harness <name>] [--read-only 0|1] [--afk 0|1]
                                     [--away-posture 0|1] [--x-mode 0|1] [--repair-line]
                                     [--queue-pending 0|1] [--present-daemon 0|1]

Print the current primary harness's supervision operating instructions.
With --repair-line, print one concise repair instruction for guard and hook messages.

--afk reports supervision OWNERSHIP: 1 only when a live away-mode daemon owns this
home's watcher. --away-posture reports the away POSTURE (state/.afk) on its own.
Away posture with no daemon means this session still owns supervision, so the
emitted protocol below applies in full.

--present-daemon defaults to probing this home's present-mode daemon
(bin/fm-present-daemon.sh status).
EOF
}

bool_value() {
  case "$1" in
    1|true|TRUE|yes|YES) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --harness)
      [ "$#" -gt 1 ] || { echo "error: --harness requires a value" >&2; exit 2; }
      HARNESS=$2
      shift 2
      ;;
    --read-only)
      [ "$#" -gt 1 ] || { echo "error: --read-only requires 0 or 1" >&2; exit 2; }
      READ_ONLY=$(bool_value "$2")
      shift 2
      ;;
    --afk)
      [ "$#" -gt 1 ] || { echo "error: --afk requires 0 or 1" >&2; exit 2; }
      AFK=$(bool_value "$2")
      shift 2
      ;;
    --away-posture)
      [ "$#" -gt 1 ] || { echo "error: --away-posture requires 0 or 1" >&2; exit 2; }
      AWAY_POSTURE=$(bool_value "$2")
      shift 2
      ;;
    --x-mode)
      [ "$#" -gt 1 ] || { echo "error: --x-mode requires 0 or 1" >&2; exit 2; }
      X_MODE=$(bool_value "$2")
      shift 2
      ;;
    --present-daemon)
      [ "$#" -gt 1 ] || { echo "error: --present-daemon requires 0 or 1" >&2; exit 2; }
      PRESENT_DAEMON=$(bool_value "$2")
      shift 2
      ;;
    --queue-pending)
      [ "$#" -gt 1 ] || { echo "error: --queue-pending requires 0 or 1" >&2; exit 2; }
      QUEUE_PENDING=$(bool_value "$2")
      shift 2
      ;;
    --repair-line)
      REPAIR_LINE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$HARNESS" ]; then
  HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)
fi

case "$HARNESS" in
  claude|codex|opencode|pi|grok|jcode) SNIPPET="$DOC_DIR/$HARNESS.md" ;;
  *) HARNESS=unknown; SNIPPET="$DOC_DIR/unknown.md" ;;
esac
[ -f "$SNIPPET" ] || SNIPPET="$DOC_DIR/unknown.md"

checkpoint_seconds=${FM_CODEX_WATCH_CHECKPOINT:-180}
pi_ext="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
pi_turnend_ext="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
x_mode_env="$CONFIG/x-mode.env"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

x_mode_env_sh=$(shell_quote "$x_mode_env")

if [ "$X_MODE" -eq 0 ] && [ -f "$x_mode_env" ]; then
  X_MODE=1
fi

# The present-mode daemon is opt-in and inert by default, so an unset flag probes
# for a genuinely live one rather than assuming either way. A live daemon changes
# only the ordinary-wake continuation: it already owns re-arming. It never changes
# the repair path, because a guard alarm firing at all means the daemon is not
# keeping a watcher alive and this session must arm one itself.
if [ -z "$PRESENT_DAEMON" ]; then
  PRESENT_DAEMON=0
  if FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-present-daemon.sh" status >/dev/null 2>&1; then
    PRESENT_DAEMON=1
  fi
fi

render_snippet() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line//__FM_PI_EXT__/$pi_ext}
    line=${line//__FM_PI_TURNEND_EXT__/$pi_turnend_ext}
    line=${line//__FM_X_MODE_ENV_SH__/$x_mode_env_sh}
    line=${line//__FM_X_MODE_ENV__/$x_mode_env}
    printf '%s\n' "$line"
  done < "$SNIPPET"
}

repair_line() {
  if [ "$READ_ONLY" -eq 1 ]; then
    printf '%s\n' 'Watcher repair belongs to the session holding the fleet lock; do not drain, arm, or repair from this read-only session.'
    return 0
  fi
  if [ "$AFK" -eq 1 ]; then
    printf '%s\n' 'Away mode owns watcher supervision; load /afk and ensure the daemon is running instead of starting normal supervision directly.'
    return 0
  fi

  prefix=
  if [ "$QUEUE_PENDING" -eq 1 ]; then
    prefix='After draining queued wakes, '
  fi
  if [ "$X_MODE" -eq 1 ]; then
    prefix="${prefix}source ${x_mode_env_sh} first, then "
  fi

  case "$HARNESS" in
    claude)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision with bin/fm-watch-arm.sh as its own Claude Code background task, never shell &.'
      ;;
    codex)
      printf '%s%s%s%s\n' "$prefix" 'repair missing watcher supervision with a foreground checkpoint: bin/fm-watch-checkpoint.sh --seconds ' "$checkpoint_seconds" '.'
      ;;
    jcode)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision as two paired actions: launch bin/fm-watch-arm.sh as its own Bash run_in_background task, then immediately set wake:true on that task id with the bg tool (subscribe). Never leave the task at the default wake:false, and never use shell &.'
      ;;
    pi)
      printf '%s%s%s%s%s%s\n' "$prefix" 'repair a missing or failed watcher cycle with the Pi tool fm_watch_arm_pi, or restart Pi with -e ' "$pi_turnend_ext" ' -e ' "$pi_ext" ' if the extensions are not loaded.'
      ;;
    opencode)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision by letting the OpenCode TUI plugin arm after idle; use bin/fm-watch-arm.sh only as a manual recovery probe if the plugin reports failure.'
      ;;
    grok)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision with bin/fm-watch-arm.sh as its own Grok tracked background task, never shell &.'
      ;;
    *)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision according to the session-start block for this harness; do not use shell &.'
      ;;
  esac
}

ordinary_wake_line() {
  if [ "$PRESENT_DAEMON" -eq 1 ]; then
    printf '%s\n' '- Ordinary wake: the present-mode supervision daemon already owns re-arming; drain queued wakes and do not arm another cycle.'
    return 0
  fi
  case "$HARNESS" in
    claude)
      printf '%s\n' '- Ordinary wake: re-arm exactly one bin/fm-watch-arm.sh Claude Code background task as directed below.'
      ;;
    codex)
      printf '%s\n' '- Ordinary wake: take the next foreground bin/fm-watch-checkpoint.sh checkpoint as directed below.'
      ;;
    jcode)
      printf '%s\n' '- Ordinary wake: re-arm one fresh cycle as directed below - launch bin/fm-watch-arm.sh as a Bash run_in_background task, then set wake:true on it with the bg tool.'
      ;;
    pi)
      printf '%s\n' '- Ordinary wake: the Pi extension already owns watcher continuity; do not arm another cycle.'
      ;;
    opencode)
      printf '%s\n' '- Ordinary wake: the OpenCode TUI plugin already owns watcher continuity; do not arm manually.'
      ;;
    grok)
      printf '%s\n' '- Ordinary wake: re-arm exactly one bin/fm-watch-arm.sh Grok tracked background task as directed below.'
      ;;
    *)
      printf '%s\n' '- Ordinary wake: follow the continuation in the harness protocol below; do not use shell &.'
      ;;
  esac
}

# The first-cycle directive is the sibling of ordinary_wake_line for the very
# first supervision cycle of a turn. When a live present-mode daemon owns the
# watcher, arming a second cycle would break single-owner, so the directive tells
# the model NOT to self-arm and to rely on the daemon's pane-wake. Otherwise it
# emits the harness-specific launch instruction, and the harness protocol below
# is that directive's full expansion. Kept here so the first-cycle instruction
# has a single source of truth rather than being restated in each snippet file.
first_cycle_line() {
  if [ "$PRESENT_DAEMON" -eq 1 ]; then
    printf '%s\n' '- First cycle: the present-mode supervision daemon owns the watcher; do NOT launch bin/fm-watch-arm.sh. Drain the wake queue, then end the turn and rely on the daemon pane-wake.'
    return 0
  fi
  case "$HARNESS" in
    claude)
      printf '%s\n' '- First cycle: launch exactly one bin/fm-watch-arm.sh Claude Code background task as directed below, never shell &.'
      ;;
    codex)
      printf '%s\n' '- First cycle: take one foreground bin/fm-watch-checkpoint.sh checkpoint as directed below.'
      ;;
    jcode)
      printf '%s\n' '- First cycle: two paired actions as directed below - launch bin/fm-watch-arm.sh as a Bash run_in_background task, then immediately set wake:true on that task id with the bg tool. Never leave the task at the default wake:false.'
      ;;
    pi)
      printf '%s\n' '- First cycle: the Pi extension arms the watcher; follow the protocol below and do not arm manually.'
      ;;
    opencode)
      printf '%s\n' '- First cycle: the OpenCode TUI plugin arms after idle; follow the protocol below and do not arm manually.'
      ;;
    grok)
      printf '%s\n' '- First cycle: launch exactly one bin/fm-watch-arm.sh Grok tracked background task as directed below, never shell &.'
      ;;
    *)
      printf '%s\n' '- First cycle: follow the first-cycle step in the harness protocol below; do not use shell &.'
      ;;
  esac
}

if [ "$REPAIR_LINE" -eq 1 ]; then
  repair_line
  exit 0
fi

RULE='================================================================================'
printf '%s\n' "$RULE"
printf 'SUPERVISION OPERATING INSTRUCTIONS - primary harness: %s\n' "$HARNESS"
printf '%s\n' "$RULE"
printf 'Current state:\n'
if [ "$READ_ONLY" -eq 1 ]; then
  printf '%s\n' '- Lock: read-only; do not drain, arm, spawn, steer, merge, or repair fleet state here.'
else
  printf '%s\n' '- Lock: held by this session; this session owns normal supervision unless away mode says otherwise.'
fi
if [ "$AFK" -eq 1 ]; then
  printf '%s\n' '- Away mode: active; load /afk and keep normal harness supervision paused while the daemon owns the watcher.'
elif [ "$AWAY_POSTURE" -eq 1 ]; then
  printf '%s\n' '- Away mode: active posture only; load /afk for away handling, but no away-mode supervision daemon is running here.'
  printf '%s\n' '- Supervision ownership: this session owns it, so the "away mode is not active" precondition in the protocol below is met and it applies in full.'
else
  printf '%s\n' '- Away mode: inactive.'
fi
if [ "$PRESENT_DAEMON" -eq 1 ]; then
  printf '%s\n' '- Present-mode supervision daemon: live; it keeps one watcher armed for this session, so do not arm per turn. Still drain the wake queue at the top of every turn, and arm normally if a guard alarm ever fires.'
fi
if [ "$X_MODE" -eq 1 ]; then
  printf '%s%s%s\n' '- X mode: active; source ' "$x_mode_env" ' before launching any watcher process so the 30s cadence is inherited.'
else
  printf '%s\n' '- X mode: inactive; use the default watcher cadence.'
fi
first_cycle_line
ordinary_wake_line
printf '\n'
render_snippet
printf '\n'
