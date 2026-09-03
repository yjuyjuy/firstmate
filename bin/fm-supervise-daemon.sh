#!/usr/bin/env bash
# fm-supervise-daemon.sh — presence-gated sub-supervisor (closes #27's P2).
#
# Wraps bin/fm-watch.sh: runs it as a child, classifies each wake reason, and
# either SELF-HANDLES the routine majority in bash (no firstmate turn) or
# ESCALATES a batched, distilled digest to the supervisor pane on
# captain-relevant events plus bounded declared-pause rechecks. This is the
# token-efficient replacement for the prior always-inject daemon: routine
# signal/stale/heartbeat wakes cost zero firstmate context; only done/
# needs-decision/blocked/failed/persistent-wedge/check-output events and a
# declared-pause recheck reach the LLM, and even then as one pre-read digest per
# batch window.
#
# PRESENCE-GATING (the /afk contract). The daemon is the away-mode engine: it
# injects ONLY when the durable away-mode flag state/.afk is present. Invoking
# the /afk skill sets that flag and starts this daemon; any real (unmarked)
# user message clears it and firstmate resumes full responsiveness.
# When afk is off, normal fm-watch.sh always-on triage is the active mechanism.
# Any buffered daemon escalations that remain while afk is off survive in
# state/.subsuper-escalations and are flushed on the next "while you were out"
# catch-up or when afk is re-entered.
#
# DELIVERY MODES. Escalations reach firstmate one of two ways, chosen once at
# startup by afk_delivery_mode_select and logged with its reason. PANE mode types
# the digest into firstmate's own pane (the original path, unchanged whenever a
# real supervisor pane is identified). PANELESS mode - selected when nothing
# positively identified that pane, e.g. a primary firstmate running outside every
# supported terminal backend - appends the same marked, single-line digest to a
# durable outbox that firstmate's armed reader pulls (bin/fm-afk-outbox-lib.sh
# owns the record and acknowledgement contract; bin/fm-afk-inbox.sh is the
# reader). A supported-but-broken pane still refuses loudly at startup.
#
# IN-BAND OPERATIONAL INPUT. bin/fm-operational-input.sh constructs every
# current daemon injection as the typed away-supervisor kind after the stable
# FM_OPERATIONAL_PREFIX, on both delivery modes. A human cannot type its leading
# U+2063 from a normal
# keyboard at the start of a message, and Herdr transports it as text.
# Firstmate's contract: a message that starts with the current prefix, or a
# legacy bare-marker daemon escalation, is internal (stay afk); an ordinary
# unmarked captain message is answered in place and away mode continues; only an
# explicit exit instruction (see message_is_afk_exit) ends away mode, flushes
# catch-up, and resumes per-wake
# responsiveness. The prefix and busy-guard solve the same problem - the
# daemon and the human share one input channel - so they live together under
# /afk.
#
# Reliability model (see the /afk skill):
#   - Nothing is lost in away mode: while state/.afk exists, the watcher reverts
#     to daemon-owned one-shot behavior and enqueues every wake to
#     state/.wake-queue BEFORE advancing its suppression markers, so a
#     crash/restart/missed injection is recovered on the next fm-wake-drain.sh.
#     The daemon does not touch the queue; it only reads the watcher's stdout
#     reason.
#   - Fail-safe-to-escalate: any wake the classifier cannot confidently mark
#     routine is escalated.
#   - Bounded wedge latency: a stale pane without a declared external wait is
#     escalated only after it has been idle for STALE_ESCALATE_SECS
#     (configurable), rechecked once. A wedged crewmate is therefore detected
#     within STALE_ESCALATE_SECS + a tick, never lost. A declared pause instead
#     gets its own longer PAUSE_RESURFACE_SECS recheck, never a wedge escalation.
#     Crewmates are autonomous, so a delayed stale response does not stall a
#     healthy crewmate's own progress.
#     Buffered escalation delivery also has a max-defer alarm: if a digest stays
#     undelivered past FM_MAX_DEFER_SECS, the daemon retries a normal flush and
#     writes state/.subsuper-inject-wedged and attempts a configurable active
#     alert if submit still cannot be confirmed. Paneless delivery gets the same
#     alarm off the age of the oldest unacknowledged outbox record, because there
#     the append itself always succeeds and could otherwise never look wedged -
#     gated on the reader's liveness beacon so an armed reader waiting through a
#     long firstmate turn is never mistaken for one that was never armed.
#   - Cheap heartbeat catch-all: every HEARTBEAT_SCAN_SECS the daemon greps all
#     state/*.status for a captain-relevant line the per-wake classifier might
#     have missed (e.g. a status verb outside CAPTAIN_RE) and escalates it.
#
# The robustness shell from the prior always-inject version is preserved:
# single-instance lock (portable helper, no flock dependency), crash-loop
# backoff, pane-gone guard, and a signal-trapped shutdown that flushes buffered
# escalations before exit.
#
# Usage: fm-supervise-daemon.sh
#          Long-lived background loop. Normally started by the /afk skill, which
#          sets state/.afk first. Env knobs:
#          FM_SUPERVISOR_TARGET     supervisor pane target (override; otherwise
#                                   auto-discovered per backend - $TMUX_PANE
#                                   under tmux, "<session>:<pane-id>" from
#                                   $HERDR_PANE_ID under herdr - then
#                                   firstmate:0 fallback). Accepts either a
#                                   tmux target or a herdr "<session>:<pane-id>"
#                                   target; which one it's read as is decided by
#                                   FM_SUPERVISOR_BACKEND (below), independently.
#          FM_SUPERVISOR_BACKEND    supervisor pane BACKEND (tmux|herdr;
#                                   override; otherwise auto-discovered the same
#                                   way bin/fm-backend.sh's fm_backend_detect
#                                   resolves the runtime firstmate itself is
#                                   executing inside - $TMUX_PANE selects tmux,
#                                   $HERDR_ENV=1 selects herdr - falling back to
#                                   tmux). zellij, orca, and cmux are not yet
#                                   supported as supervisor backends; the daemon
#                                   refuses loudly at startup rather than trying
#                                   tmux primitives against a non-tmux pane.
#          FM_AFK_DELIVERY          delivery mode: auto (default), pane, or
#                                   paneless. auto picks pane whenever the
#                                   supervisor target came from a real signal
#                                   (override, $TMUX_PANE, herdr env) and
#                                   paneless when only the legacy firstmate:0
#                                   fallback remained. An unrecognized value
#                                   warns and behaves as auto.
#          FM_INJECT_SKIP           |-prefixes force-self-handle bypassing
#                                   classification (default "heartbeat"); empty
#                                   disables. Use sparingly: it overrides the
#                                   captain-relevant escalation for matching
#                                   kinds.
#          FM_STALE_ESCALATE_SECS   idle seconds before a stale pane escalates
#                                   as a possible wedge (default 240)
#          FM_PAUSE_RESURFACE_SECS  idle seconds before a declared external wait
#                                   re-surfaces as a recheck (default 3600)
#          FM_ESCALATE_BATCH_SECS   buffer window for batched escalation
#                                   digests; 0 = flush immediately (default 90)
#          FM_HEARTBEAT_SCAN_SECS   cadence for the catch-all status scan
#                                   (default 300)
#          FM_HOUSEKEEPING_TICK     seconds between housekeeping passes while
#                                   the watcher is mid-cycle (default 15)
#          FM_CONTEXT_STOW_CHECK_SECS cadence for reading firstmate's OWN context
#                                   and nudging it to /stow when it crosses the
#                                   stow threshold (default 120; 0 disables). The
#                                   threshold itself is config/context-stow-threshold
#                                   (default 200000; docs/configuration.md). The
#                                   read is claude/jcode-capable and fails closed:
#                                   an unreadable/unsupported harness never nudges.
#          FM_CONTEXT_STOW_HYSTERESIS tokens the count must drop BELOW the
#                                   threshold by before the once-per-crossing stow
#                                   nudge re-arms (default 20000). Prevents a count
#                                   hovering at the line from re-nudging every tick.
#          FM_SUPERVISOR_HARNESS    firstmate's own harness for the context-stow
#                                   read (override; otherwise bin/fm-harness.sh).
#          FM_CONTEXT_STOW_CWD      transcript launch dir for the context read
#                                   (override; otherwise FM_HOME). Testing seam.
#          FM_BUSY_REGEX            OR-ed busy signatures (mirrors fm-watch.sh)
#          FM_COMPOSER_IDLE_RE      empty-composer regex applied after dim-ghost
#                                   and structural border stripping (default:
#                                   bare prompt glyphs plus busy footers)
#          FM_MAX_DEFER_SECS        max seconds a buffered escalation may sit
#                                   undelivered before one normal flush attempt;
#                                   if that cannot confirm a submit, a wedge
#                                   alarm fires (default 300; 0 disables)
#          FM_AFK_INBOX_BEACON_STALE_SECS seconds without a stamp on
#                                   state/.afk-inbox.beat before the paneless
#                                   undelivered alarm treats firstmate's inbox
#                                   reader as gone. docs/configuration.md
#                                   ("Away-mode paneless delivery") owns the
#                                   default, the reporting bound, and why they are
#                                   derived from FM_MAX_DEFER_SECS.
#          FM_WEDGE_ALARM_CHANNEL   override config/wedge-alarm with a single
#                                   active-alert directive for that wedge alarm
#                                   (off|auto|osascript|notify-send|herdr|command:<cmd>). An
#                                   absent file/var means auto: on macOS an
#                                   osascript banner, on Linux a notify-send
#                                   banner when present, so the alarm is
#                                   never silent on a desktop. See wedge_alarm_notify below
#                                   and docs/configuration.md.
#          FM_WEDGE_ALARM_EXEC      notifier seam: when set, every notifier
#                                   channel routes through this command as
#                                   `<cmd> <channel> <summary>` instead of
#                                   invoking its real notifier; "discard" fires
#                                   nothing. Unset in production. When SOURCED the
#                                   daemon defaults this to "discard" so no test
#                                   can post a real notification (wedge_alarm_emit
#                                   and the library-mode guard at the foot).
#          FM_WEDGE_ALARM_TIMEOUT_SECS seconds allowed for each notifier before
#                                   its watchdog terminates it and continues to the
#                                   next channel (default 10; invalid/zero uses the
#                                   default).
#          FM_INJECT_CONFIRM_RETRIES Enter-retry attempts on a swallowed Enter
#                                   (default 3); the digest is typed once, only
#                                   Enter is retried. Composer-empty detection is
#                                   structural and style-aware (bin/fm-tmux-lib.sh):
#                                   it drops dim/faint ghost text and strips the
#                                   harness's box borders before deciding, so a
#                                   ghost-only or bordered-but-empty composer is
#                                   not misread as pending input.
#          FM_INJECT_CONFIRM_SLEEP  seconds between daemon submit checks
#                                   (default 0.5)
#          FM_LOG_MAX_BYTES / FM_LOG_KEEP_LINES / FM_CRASH_*  log + crash guards
#          FM_STATE_OVERRIDE        alternate state dir (testing)
#          Logs each wake to state/.supervise-daemon.log (size-capped). Single
#          instance via portable lock on state/.supervise-daemon.lock. Trapped
#          SIGTERM/SIGINT shut down within ~1s, flush escalations, release the
#          lock. A crashing fm-watch.sh is logged and restarted, never killing
#          the daemon; a tight crash-restart spin is detected and backed off.
set -u

FM_DAEMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_DAEMON_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# Shared tmux pane primitives for supervisor injection (busy/composer detection
# + verify-retry submit). Sourced at top level so BOTH the executed daemon and
# the unit tests (which source this file for its pure functions) get the
# corrected composer detection. Stale task rechecks use fm-backend.sh below.
# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_DAEMON_DIR/fm-tmux-lib.sh"

# shellcheck source=bin/fm-backend.sh
. "$FM_DAEMON_DIR/fm-backend.sh"

# Canonical construction and parsing for every Firstmate operational input.
# shellcheck source=bin/fm-operational-input.sh
. "$FM_DAEMON_DIR/fm-operational-input.sh"

# Shared wake classifier (last_status_line, status_is_captain_relevant,
# window_to_task, scan_captain_relevant_statuses). The SAME library backs the
# always-on watcher's triage, so the captain-relevant verb set and the
# classification predicates have exactly one definition.
# shellcheck source=bin/fm-classify-lib.sh
. "$FM_DAEMON_DIR/fm-classify-lib.sh"

# Supervisor-pane discovery (FM_SUPERVISOR_TARGET_DEFAULT,
# FM_SUPERVISOR_BACKEND_DEFAULT, discover_supervisor_target,
# discover_supervisor_backend). Shared with the script-owned away launcher
# (bin/fm-afk-launch.sh) so the captain-pane resolution has exactly one owner.
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$FM_DAEMON_DIR/fm-supervisor-target-lib.sh"

# Away-mode daemon lock and bring-up-marker helpers, shared with the away entry
# paths and every supervision-ownership consumer.
# shellcheck source=bin/fm-afk-daemon-lib.sh
. "$FM_DAEMON_DIR/fm-afk-daemon-lib.sh"

# Paneless (pull) delivery: the durable outbox record and acknowledgement
# contract used when no supervisor pane can be identified. Owned by
# bin/fm-afk-outbox-lib.sh and shared with its reader (bin/fm-afk-inbox.sh), the
# away launcher, and the return catch-up gate.
# shellcheck source=bin/fm-afk-outbox-lib.sh
. "$FM_DAEMON_DIR/fm-afk-outbox-lib.sh"

# firstmate's own live context read (fm_sm_context_tokens, claude/jcode-capable)
# and the stow-nudge threshold (fm_context_stow_threshold). The SAME read the
# secondmate context monitor uses, pointed at firstmate's own home so the daemon
# can nudge firstmate to /stow before a context reset loses knowledge. Fails
# closed: an unreadable or unsupported harness yields no tokens and never nudges.
# shellcheck source=bin/fm-secondmate-context-lib.sh
. "$FM_DAEMON_DIR/fm-secondmate-context-lib.sh"

# --- tunables ---------------------------------------------------------------
# Supervisor backends this daemon knows how to inject into today. zellij, orca,
# and cmux are real backends elsewhere in firstmate (bin/fm-backend.sh) but this
# daemon has no verified composer/busy primitives wired up for them yet - see
# docs/herdr-backend.md and AGENTS.md section 4's
# harness-verification discipline. Selecting one refuses loudly at startup
# instead of silently running tmux primitives against a pane that is not a tmux
# pane.
FM_SUPERVISOR_SUPPORTED_BACKENDS="tmux herdr"
INJECT_SKIP_DEFAULT="heartbeat"
STALE_ESCALATE_SECS_DEFAULT=240
ESCALATE_BATCH_SECS_DEFAULT=90
HEARTBEAT_SCAN_SECS_DEFAULT=300
HOUSEKEEPING_TICK_DEFAULT=15
# Max time a buffered escalation may sit undelivered before the daemon retries
# the normal flush path and, if that cannot confirm a submit, raises a loud wedge
# alarm. The escape hatch makes a guard false-positive visible instead of silent.
# The value itself lives with the beacon it is compared against
# (bin/fm-afk-outbox-lib.sh's FM_AFK_MAX_DEFER_SECS_DEFAULT), because the
# session-start reader-liveness check needs the same number.
MAX_DEFER_SECS_DEFAULT=$FM_AFK_MAX_DEFER_SECS_DEFAULT
WEDGE_ALARM_TIMEOUT_SECS_DEFAULT=10
# How often housekeeping runs one bounded away-mode driver tick
# (bin/fm-afk-driver.sh), and how long a single tick may take before it is
# stopped. The cadence is minutes rather than seconds because the driver's work -
# cleaning up finished lanes, nudging an unpushed one, starting queued work - is
# fleet-scale and costs real commands; FM_AFK_DRIVER_TICK_SECS=0 switches the
# hook off for a home without touching the rest of away mode.
AFK_DRIVER_TICK_SECS_DEFAULT=600
AFK_DRIVER_TIMEOUT_SECS_DEFAULT=300
# firstmate own-context stow-nudge cadence and hysteresis. The daemon reads
# firstmate's OWN live context on this cadence (minutes, not seconds - the read
# streams a transcript and the nudge is a slow-moving condition) and, when the
# count first crosses fm_context_stow_threshold, injects ONE operational nudge to
# /stow. A durable marker rate-limits it to once per crossing; the marker clears
# only after the count drops back below (threshold - hysteresis), so a count
# hovering at the line cannot re-nudge every tick. FM_CONTEXT_STOW_CHECK_SECS=0
# switches the check off for a home without touching the rest of the daemon.
CONTEXT_STOW_CHECK_SECS_DEFAULT=120
# The hysteresis band is owned by bin/fm-secondmate-context-lib.sh
# (FM_CONTEXT_STOW_HYSTERESIS_DEFAULT), shared with the always-on watcher sweep,
# so the daemon and the watcher cannot disagree about the re-arm point. Aliased
# here only to keep the existing local name this file already reads.
CONTEXT_STOW_HYSTERESIS_DEFAULT=$FM_CONTEXT_STOW_HYSTERESIS_DEFAULT
WEDGE_ALARM_LAST_EPOCH=0
WEDGE_ALARM_NOTIFIER_PID=
# Paneless undelivered-alarm probe state. A probe that cannot read the outbox
# burns the whole bounded lock acquire, so housekeeping logs the transition into
# and out of that state rather than every one-second tick, and backs the next
# probe off by one max-defer window instead of stalling on every pass.
OUTBOX_UNREADABLE=0
OUTBOX_PROBE_NOT_BEFORE=0
# How stale bin/fm-afk-inbox.sh's liveness beacon must be before the paneless
# undelivered alarm treats the reader as gone is derived in
# bin/fm-afk-outbox-lib.sh (fm_afk_inbox_beacon_stale_secs), with the beacon it
# measures and the session-start reader-liveness check that needs the same answer.
# The captain-relevant verb set and the status classifiers (last_status_line,
# status_is_captain_relevant, window_to_task, scan_captain_relevant_statuses) now
# live in bin/fm-classify-lib.sh, shared with the always-on watcher.
# Composer-empty detection and the tmux busy-footer fallback live in
# bin/fm-tmux-lib.sh (FM_TMUX_BUSY_REGEX_DEFAULT / fm_tmux_composer_state);
# FM_BUSY_REGEX still overrides the fallback busy set here, as before.
INJECT_FAIL_SLEEP_DEFAULT=30
INJECT_CONFIRM_RETRIES_DEFAULT=3
INJECT_CONFIRM_SLEEP_DEFAULT=0.5
CRASH_THRESHOLD_DEFAULT=10
CRASH_WINDOW_DEFAULT=60
CRASH_BACKOFF_DEFAULT=60
CRASH_NORMAL_SLEEP_DEFAULT=5
LOG_MAX_BYTES_DEFAULT=1048576
LOG_KEEP_LINES_DEFAULT=2000

# --- presence-gating --------------------------------------------------------
# bin/fm-operational-input.sh owns the U+2063 FIRSTMATE_OP bytes and typed
# away-supervisor construction. The away-exit predicate intentionally retains
# its landed leading-U+2063 compatibility behavior.
AFK_FLAG_NAME=".afk"

# Resolve the effective state dir. FM_STATE_OVERRIDE wins (testing); otherwise
# $FM_HOME/state. Kept as a function so the pure
# classifiers can take an explicit state arg without depending on globals.
_state_root() { printf '%s' "${FM_STATE_OVERRIDE:-$FM_HOME/state}"; }

# --- portable stat (same trap as fm-watch.sh: no `stat -f || stat -c`) -------
if [ "$(uname)" = Darwin ]; then
  _stat_file_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  _stat_file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi
_now() { date +%s; }
_file_age() {  # seconds since mtime; very large if missing
  local f=$1 m
  m=$(_stat_file_mtime "$f") || { echo 999999; return; }
  echo $(( $(_now) - m ))
}

_hash_text() {
  if command -v md5 >/dev/null 2>&1; then printf '%s' "$1" | md5 -q
  else printf '%s' "$1" | md5sum | cut -d ' ' -f1; fi
}

# --- presence-gating helpers (PURE-ish: side-effect-free reads of state) -----
# afk_active: 0 if the durable away-mode flag exists, 1 otherwise.
afk_active() {  # <state>
  [ -e "$1/$AFK_FLAG_NAME" ]
}

# afk_enter / afk_exit: write/clear the away-mode flag. Called by the /afk
# skill (enter) and by firstmate on an explicit captain return (exit). Durable: a plain file,
# so recovery (§5) re-enters afk if it is present after a restart.
afk_enter() {  # <state>
  mkdir -p "$1"
  date '+%s' > "$1/$AFK_FLAG_NAME"
}

afk_exit() {  # <state>
  rm -f "$1/$AFK_FLAG_NAME"
}

# should_exit_afk: encodes firstmate's afk-exit contract as a testable function.
#   afk inactive                       -> 1 (nothing to exit)
#   message has marker                 -> 1 (internal escalation; stay afk)
#   explicit exit instruction          -> 0 (the captain ordered the exit)
#   anything else, including an ordinary captain message or reply -> 1 (stay afk)
#
# Bias toward STAYING away. Standing captain order, 2026-07-25: the captain
# answers questions from a phone throughout the day while genuinely still away,
# so an ordinary reply must never tear away supervision down. A missed exit
# costs one more explicit word from the captain, while a false exit costs a
# daemon restart, a full return catch-up gate, and blocker reclassification.
# Away mode therefore ends only on an explicit exit instruction; see
# message_is_afk_exit below for that grammar.
should_exit_afk() {  # <state> <message-text>
  local state=$1 msg=$2
  afk_active "$state" || return 1
  message_is_injection "$msg" && return 1
  message_is_afk_exit "$msg"
}

# fm_afk_normalize_message: lowercase the text, drop apostrophes, collapse
# whitespace, trim, and strip trailing sentence punctuation, so the exit
# grammar below compares against one stable form.
fm_afk_normalize_message() {  # <message-text>
  local s=$1
  s=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')
  s=${s//\'/}
  s=${s//’/}
  s=$(printf '%s' "$s" | tr -s '[:space:]' ' ')
  s=${s# }
  s=${s% }
  while [ -n "$s" ]; do
    case "$s" in
      *[.!?,\;:]) s=${s%?} ;;
      *) break ;;
    esac
  done
  printf '%s' "$s"
}

# message_is_afk_exit: 0 when the message text is an explicit instruction to
# leave away mode, 1 otherwise. This function is the single owner of that
# grammar; the /afk skill and AGENTS.md point here rather than restating it.
#
# Accepted forms:
#   - a slash command: /back or /unafk, with or without trailing text.
#   - /afk with an exit subcommand: exit, off, stop, end, or done. Bare /afk and
#     /afk with any other argument (for example "/afk back in an hour") still
#     refresh away mode rather than ending it.
#   - a whole-message plain-language instruction, such as "im back",
#     "exit afk", "afk off", "stop afk", "end away mode", or "away mode off".
#
# Plain-language forms must match the WHOLE message, so an ordinary request that
# merely contains one of those words (for example "back up the database")
# keeps away mode alive.
message_is_afk_exit() {  # <message-text>
  local msg=$1 norm
  [ -n "$msg" ] || return 1
  norm=$(fm_afk_normalize_message "$msg")
  case "$norm" in
    /back|/back\ *|/unafk|/unafk\ *) return 0 ;;
    /afk\ exit*|/afk\ off*|/afk\ stop*|/afk\ end*|/afk\ done*) return 0 ;;
  esac
  case "$norm" in
    back|"back now"|"im back"|"im back now"|"i am back"|"i am back now") return 0 ;;
    "exit afk"|"afk exit"|"afk off"|"stop afk"|"end afk"|"afk done"|"done afk") return 0 ;;
    "exit away mode"|"away mode off"|"end away mode"|"stop away mode") return 0 ;;
  esac
  return 1
}

# message_is_injection: 0 if the given message text starts with the sentinel
# marker (a daemon escalation), 1 otherwise (a real user message). Firstmate's
# afk-exit contract uses this: marker present -> internal escalation, stay afk.
# An unmarked message is a real captain message, which by itself does NOT exit
# away mode; only message_is_afk_exit's explicit grammar does.
message_is_injection() {  # <message-text>
  local msg=$1
  [ -n "$msg" ] || return 1
  case "$msg" in
    "$FM_INJECT_MARK"*) return 0 ;;
  esac
  return 1
}

# strip_injection_marker: remove a current typed away envelope, the landed
# untyped FIRSTMATE_OP prefix, or the legacy bare sentinel. Current grammar is
# delegated to its owner rather than reimplemented here.
strip_injection_marker() {  # <message-text>
  local msg=$1 body
  if fm_operational_input_body "$msg" body; then
    printf '%s' "$body"
    return
  fi
  case "$msg" in
    "$FM_OPERATIONAL_PREFIX"*) msg=${msg#"$FM_OPERATIONAL_PREFIX"} ;;
    "$FM_INJECT_MARK"*) msg=${msg#"$FM_INJECT_MARK"} ;;
  esac
  printf '%s' "$msg"
}

# Collapse all newlines to a literal " - " separator so the injected digest is
# a single line. Submission via send-keys + Enter is then unambiguous regardless
# of how the target TUI handles embedded newlines in its composer.
_collapse_newlines() {  # <text>
  local s=$1
  s=${s//$'\n'/ - }
  printf '%s' "$s"
}

# discover_supervisor_target / discover_supervisor_backend are owned by
# bin/fm-supervisor-target-lib.sh (sourced above). fm_super_main below calls
# them exactly as before; the away launcher reuses the identical resolution to
# pass the captain pane in as FM_SUPERVISOR_TARGET.

# --- delivery-mode selection (PURE: reads env, no side effects) --------------
# Two delivery modes, chosen once at startup and logged with the reason:
#   pane     - type the digest into firstmate's own pane (the original path,
#              unchanged whenever a real supervisor pane is identified).
#   paneless - append the digest to the durable outbox and let firstmate's armed
#              reader (bin/fm-afk-inbox.sh) pull it. No pane is touched at all.
#
# Why paneless exists: supervisor-target discovery ends in a legacy "firstmate:0"
# fallback that is a GUESS, not evidence. A primary firstmate running outside
# every supported terminal backend (a desktop-app session) reaches that guess,
# types into whatever unrelated pane answers to it, never gets a confirmed
# submit, and buffers forever - the 2026-07-22 incident bin/fm-afk-outbox-lib.sh
# describes. Choosing the pull channel when NOTHING positively identified
# firstmate's pane is the honest reading of that state.
#
# This is only for supported-backend-ABSENT. A supported-but-BROKEN supervisor
# pane - an explicit FM_SUPERVISOR_TARGET that does not resolve, or an
# unsupported FM_SUPERVISOR_BACKEND - still refuses loudly at startup, because
# there the captain named a pane and the daemon must not quietly stop using it.
#
# Returns 2 (with the auto-selected mode still printed) when FM_AFK_DELIVERY
# holds an unrecognized value, so the caller can warn about the typo without
# taking away mode down over it.
afk_delivery_mode_select() {  # <target-source>
  local target_source=$1 override="${FM_AFK_DELIVERY:-auto}" auto=pane rc=0
  case "$target_source" in
    FALLBACK*) auto=paneless ;;
  esac
  case "$override" in
    pane|paneless) printf '%s' "$override"; return 0 ;;
    ''|auto|default) ;;
    *) rc=2 ;;
  esac
  printf '%s' "$auto"
  return "$rc"
}

# --- classification helpers (PURE: no side effects, testable) ---------------
# last_status_line, status_is_captain_relevant, window_to_task, and
# scan_captain_relevant_statuses come from bin/fm-classify-lib.sh (sourced above),
# the single classifier shared with bin/fm-watch.sh. The decision-string wrappers
# and dedup state below layer the daemon's escalation-digest concerns on top.
#
# Decision protocol: every classifier prints exactly one line on stdout of the
# form "<action>|<distilled>" where action is "self" or "escalate". The distilled
# field for "self" is informational (logged); for "escalate" it is the pre-read
# summary firstmate would otherwise have to re-read.

classify_signal() {  # <reason-after-colon> <state>
  local reason=$1 state=$2 f last distilled="" rel="" all_seen=1 task seen
  for f in $reason; do
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    distilled="${distilled}$(basename "$f"): ${last} | "
    status_is_captain_relevant "$last" || continue
    rel=1
    # Dedupe against the catch-all scan: if this status was already escalated
    # (seen marker matches), skip escalating again. The seen marker is the
    # single source of truth shared between the per-wake signal path and the
    # heartbeat scan. all_seen stays 1 only if EVERY relevant file was seen.
    task=$(basename "$f"); task="${task%.status}"
    seen="$state/.subsuper-seen-status-$(_stale_key "$task")"
    [ "$(cat "$seen" 2>/dev/null || true)" = "$last" ] || all_seen=0
  done
  # strip a trailing " | " separator so the distilled line is clean
  distilled="${distilled% | }"
  if [ -z "$rel" ]; then
    printf 'self|routine signal: %s' "$distilled"
  elif [ "$all_seen" = "1" ]; then
    # Every relevant status was already escalated by the catch-all scan;
    # self-handle to avoid a duplicate entry in the digest.
    printf 'self|signal already escalated (catch-all scan): %s' "$distilled"
  else
    printf 'escalate|%s' "$distilled"
  fi
}

# classify_stale decides the WAKE itself (one-shot per distinct hash). On a
# first sight of a non-terminal stale it returns "self" and the caller records a
# timestamp marker; persistence is escalated by housekeeping's recheck, not here.
classify_stale() {  # <window> <state>
  local win=$1 state=$2 task last seen
  task=$(window_to_task "$win" "$state")
  last=$(last_status_line "$state/$task.status")
  if [ -n "$last" ] && status_is_paused "$last"; then
    # A DECLARED external-wait pause (fm-classify-lib.sh): an idle pane is EXPECTED,
    # so this is not a wedge. The caller records a pause marker (long re-surface
    # cadence in housekeeping) rather than a wedge stale marker. Cheap: reuses the
    # status line already read, no fm-crew-state.sh call, mirroring the daemon's
    # existing status-log classification.
    printf 'pause|paused (awaiting external), rechecked on a long cadence: %s' "$last"
    return
  fi
  if [ -n "$last" ] && status_is_captain_relevant "$last"; then
    # Independent of free-text captain-relevant matching: a nonterminal progress
    # verb (working:) must never take the terminal stale path. Seen-status dedupe
    # must not permanently suppress or clear possible-wedge aging merely because
    # prose once looked captain-relevant. Real terminal verbs and legacy free-text
    # captain lines without those verbs keep the terminal escalate/dedupe path.
    if ! status_is_terminal_verb "$last"; then
      case "$(status_line_verb "$last")" in
        working|resolved|captain-held)
          printf 'self|transient stale (%s): %s' "$win" "$last"
          return
          ;;
      esac
    fi
    # Dedupe against the signal path: if this status was already escalated
    # (seen marker matches), self-handle to avoid a duplicate in the digest.
    seen="$state/.subsuper-seen-status-$(_stale_key "$task")"
    if [ "$(cat "$seen" 2>/dev/null || true)" = "$last" ]; then
      printf 'self|stale + terminal (already escalated by signal): %s' "$last"
      return
    fi
    printf 'escalate|stale + terminal status: %s' "$last"
    return
  fi
  # Non-terminal (or no status): defer to the persistence recheck. The caller
  # records/refreshes the stale marker so housekeeping can age it.
  printf 'self|transient stale (%s): %s' "$win" "${last:-no status}"
}

classify_check() {  # <full reason>  — check scripts print only when firstmate should wake
  printf 'escalate|%s' "$1"
}

classify_heartbeat() {
  # The wake itself is routine; the catch-all scan runs separately in
  # housekeeping on the HEARTBEAT_SCAN_SECS cadence.
  printf 'self|heartbeat (catch-all scan runs in housekeeping)'
}

# Anything unrecognized is escalated (fail-safe).
classify_unknown() {  # <reason>
  printf 'escalate|unknown wake: %s' "$1"
}

# --- stale marker + escalation buffer (stateful, but via explicit state dir) -
# Marker:   state/.subsuper-stale-<key>   contains the epoch first seen idle.
# Buffer:   state/.subsuper-escalations    one distilled line per escalation.
# Seen:     state/.subsuper-seen-status-<task>  last status line the scan
#           escalated, so the catch-all does not re-fire the same terminal.

_stale_key() { printf '%s' "$1" | tr ':/.' '___'; }

stale_marker_record() {  # <window> <state>  — create if absent
  local win=$1 state=$2 key marker
  key=$(_stale_key "$(window_to_task "$win" "$state")")
  marker="$state/.subsuper-stale-$key"
  [ -e "$marker" ] || _now > "$marker"
}

stale_marker_remove() {  # <window> <state>
  local win=$1 state=$2 key
  key=$(_stale_key "$(window_to_task "$win" "$state")")
  rm -f "$state/.subsuper-stale-$key"
}

# Pause marker: state/.subsuper-paused-<key> holds the epoch a declared pause was
# first observed idle. Housekeeping ages it against PAUSE_RESURFACE_SECS (much
# longer than a wedge) and re-surfaces the pause once per window. Recording is
# create-if-absent so the timestamp is stable across a churny idle pane (many
# distinct stale hashes map to one marker), keeping the cadence hash-immune.
pause_marker_record() {  # <window> <state> - create if absent
  local win=$1 state=$2 key marker
  key=$(_stale_key "$(window_to_task "$win" "$state")")
  marker="$state/.subsuper-paused-$key"
  [ -e "$marker" ] || _now > "$marker"
}

pause_marker_remove() {  # <window> <state>
  local win=$1 state=$2 key
  key=$(_stale_key "$(window_to_task "$win" "$state")")
  rm -f "$state/.subsuper-paused-$key"
}

clear_pause_tracking() {  # <window> <state>
  local win=$1 state=$2 task key watcher_key
  task=$(window_to_task "$win" "$state")
  key=$(_stale_key "$task")
  watcher_key=$(_stale_key "$win")
  rm -f "$state/.subsuper-paused-$key" "$state/.subsuper-stale-$key" \
    "$state/.paused-$watcher_key" "$state/.paused-rechecked-$watcher_key" "$state/.paused-resurfaced-$watcher_key" \
    "$state/.stale-$watcher_key" "$state/.stale-since-$watcher_key" "$state/.wedge-escalations-$watcher_key"
}

reconcile_pause_tracking() {  # <window> <state> <last-status-line>
  local win=$1 state=$2 last=$3 task key marker watcher_key
  task=$(window_to_task "$win" "$state")
  key=$(_stale_key "$task")
  marker="$state/.subsuper-paused-$key"
  watcher_key=$(_stale_key "$win")
  if status_is_paused "$last"; then
    stale_marker_remove "$win" "$state"
    pause_marker_record "$win" "$state"
  elif [ -e "$marker" ] || [ -e "$state/.paused-$watcher_key" ]; then
    clear_pause_tracking "$win" "$state"
  fi
}

migrate_watcher_pause_markers() {  # <state>
  local state=$1 meta win task key last watcher_key
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    win=$(fm_backend_target_of_meta "$meta")
    [ -n "$win" ] || continue
    task=$(basename "$meta"); task=${task%.meta}
    key=$(_stale_key "$task")
    watcher_key=$(_stale_key "$win")
    last=$(last_status_line "$state/$task.status")
    if status_is_paused "$last" || [ -e "$state/.subsuper-paused-$key" ] || [ -e "$state/.paused-$watcher_key" ]; then
      reconcile_pause_tracking "$win" "$state" "$last"
    fi
  done
}

sync_pause_markers_from_signal() {  # <state> <signal files>
  local state=$1 paths=$2 f last task win
  local -a files
  read -r -a files <<<"$paths"
  for f in "${files[@]}"; do
    case "$f" in *.status) ;; *) continue ;; esac
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    task=$(basename "$f"); task=${task%.status}
    win=$(window_for_task "$task" "$state" 2>/dev/null || true)
    [ -n "$win" ] || continue
    reconcile_pause_tracking "$win" "$state" "$last"
  done
}

# Record the seen-status marker for a captain-relevant status line so the
# heartbeat catch-all scan does not re-fire it. The single source of truth for
# the .subsuper-seen-status-<task> dedup state: called from both the per-wake
# escalate path and the catch-all scan.
mark_status_seen() {  # <state> <task> <last-line>
  local state=$1 task=$2 line=$3
  printf '%s' "$line" > "$state/.subsuper-seen-status-$(_stale_key "$task")"
}

# Mark every captain-relevant status line a per-wake classification escalated as
# seen, so the catch-all scan does not re-escalate the same line within
# HEARTBEAT_SCAN_SECS. Mirrors classify_signal/classify_stale's relevance test.
mark_escalated_seen() {  # <kind> <arg> <state>
  local kind=$1 arg=$2 state=$3 f last task
  case "$kind" in
    signal)
      for f in $arg; do
        [ -e "$f" ] || continue
        last=$(last_status_line "$f")
        [ -n "$last" ] || continue
        status_is_captain_relevant "$last" || continue
        task=$(basename "$f"); task="${task%.status}"
        mark_status_seen "$state" "$task" "$last"
      done ;;
    stale)
      task=$(window_to_task "$arg" "$state")
      last=$(last_status_line "$state/$task.status")
      [ -n "$last" ] && status_is_captain_relevant "$last" \
        && mark_status_seen "$state" "$task" "$last" ;;
  esac
}

# Busy + composer-empty detection are the shared primitives in fm-tmux-lib.sh
# (one source of truth with fm-send.sh). These thin wrappers keep the daemon's
# call sites and the unit tests stable.
#
# pane_input_pending returns 0 (pending) when the cursor line holds real
# unsubmitted text - a human's half-typed line (the return race) or a previous
# injection whose Enter was swallowed. The detector drops dim/faint ghost text and
# strips the harness's composer box borders, so a ghost-only or idle bordered
# claude composer ("│ > … │") is correctly read as empty, not pending (incidents
# afk-invx-i5 and composer-robust).
# pane_is_busy / pane_input_pending: BACKEND-AWARE now (previously tmux-only
# direct calls). <backend> defaults to tmux when omitted, so every existing
# caller/test that passes only <target> is unaffected. Dispatch goes through
# bin/fm-backend.sh's generic per-backend primitives (fm_backend_busy_state,
# fm_backend_capture, fm_backend_composer_state) rather than hand-rolling a
# case statement here, mirroring the same fallback pattern
# stale_window_is_busy already uses for per-task panes: try the backend's
# native busy-state first, and fall back to the shared regex-over-capture
# reader whenever it does not report "busy" (tmux has no native busy-state
# primitive, so it always takes this fallback path - byte-identical to the
# pre-existing fm_pane_is_busy, since fm_backend_capture's tmux arm runs the
# exact same `tmux capture-pane -p -t <target> -S -40`).
pane_is_busy() {  # <target> [backend]
  local target=$1 backend=${2:-tmux} bs tail40
  bs=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null)
  case "$bs" in
    busy) return 0 ;;
  esac
  tail40=$(fm_backend_capture "$backend" "$target" 40 2>/dev/null) || return 1
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"
}

# pane_input_pending: the standalone "is there real unsubmitted text" predicate,
# dispatching through fm_backend_composer_state (byte-identical to a direct
# fm_tmux_composer_state call for the default/omitted-backend case). inject_msg
# no longer routes its composer-guard through this boolean: a safe injection
# target must be affirmatively 'empty', and a boolean pending/not-pending check
# cannot distinguish an empty agent composer from a bare dead-shell prompt or an
# unreadable pane (both 'unknown'), so inject_msg reads the full tri-state
# verdict directly. This predicate is retained as the shared pending check and
# as the vehicle for the composer-classifier dispatch regression tests.
pane_input_pending() {  # <target> [backend]
  local target=$1 backend=${2:-tmux}
  [ "$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)" = pending ]
}

task_window_backend() {  # <window> <state>
  local win=$1 state=$2 task meta
  task=$(window_to_task "$win" "$state")
  meta="$state/$task.meta"
  fm_backend_of_meta "$meta"
}

stale_window_is_busy() {  # <window> <state>
  local win=$1 state=$2 backend label tail40 bs
  backend=$(task_window_backend "$win" "$state")
  label="fm-$(window_to_task "$win" "$state")"
  tail40=$(fm_backend_capture "$backend" "$win" 40 "$label" 2>/dev/null) || return 2
  bs=$(fm_backend_busy_state "$backend" "$win" 2>/dev/null)
  case "$bs" in
    busy) return 0 ;;
  esac
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"
}

escalate_add() {  # <state> <distilled-item>
  local state=$1 item=$2 buf
  buf="$state/.subsuper-escalations"
  [ -s "$buf" ] || _now > "${buf}.since"
  printf '%s\n' "$item" >> "$buf"
}

# Flush the escalation buffer as ONE batched, single-line digest to the
# supervisor pane. Returns 0 on successful inject (or empty buffer), non-zero on
# inject failure (buffer preserved for retry / catch-up).
escalate_flush() {  # <state>
  local state=$1 buf item n msg
  buf="$state/.subsuper-escalations"
  [ -s "$buf" ] || return 0
  # `tr -d ' '`: BSD wc pads its count, and this number is rendered straight into
  # the digest the captain reads, so an unpadded count is the only correct one.
  n=$(wc -l < "$buf" 2>/dev/null | tr -d ' ')
  # `tr` succeeds even when `wc` did not, so the fallback has to be checked on the
  # value rather than on the pipeline's status: an empty count would render as
  # "( event(s))" in the line the captain reads.
  [ -n "$n" ] || n=0
  # Join buffered items with the literal " | " separator into one digest line.
  msg=$(awk 'NR>1{printf " | "} {printf "%s",$0} END{print ""}' "$buf" 2>/dev/null)
  # Single-line wrapper: no embedded newlines (inject_msg also collapses as a
  # safety net, but keeping the source single-line makes the intent explicit).
  msg=$(printf 'Supervisor escalate (%s event(s)): %s (pre-read; re-arm not needed — watcher daemon-managed)' "$n" "$msg")
  if inject_msg "$msg" "$state"; then
    : > "$buf"; rm -f "${buf}.since"
    # Retiring the undelivered marker means DELIVERY recovered. On the pane path a
    # confirmed submit really is delivery, so it clears here exactly as before. In
    # paneless mode a successful inject only APPENDED the record, so clearing here
    # would let ordinary escalation traffic reset the marker's mtime-based
    # re-alarm rate limit (the only limit that survives a daemon restart) and
    # destroy the catch-up evidence bin/fm-afk-return.sh reads, while the records
    # the marker describes are still unacknowledged. There the clear belongs to
    # housekeeping (1c), which owns actual reader acknowledgement.
    paneless_delivery || rm -f "$state/.subsuper-inject-wedged"
    return 0
  fi
  return 1
}

# Paneless delivery is in force for this run: escalations are appended to the
# durable outbox for firstmate's armed reader instead of typed into a pane.
paneless_delivery() {
  [ "${FM_AFK_DELIVERY_MODE:-pane}" = paneless ]
}

# Seconds without a reader beacon stamp before the paneless undelivered alarm
# treats firstmate's inbox reader as gone: FM_AFK_INBOX_BEACON_STALE_DEFER_MULTIPLE times
# the effective max-defer window (see docs/configuration.md for that default and
# its reporting bound). A non-numeric or zero override falls back to the derived
# default rather than disabling the staleness check, because a staleness window of
# zero would make every armed reader look dead and restore the false alarm this
# gate removes.
inbox_beacon_stale_secs() {
  fm_afk_inbox_beacon_stale_secs
}

# The supervisor pane target for THIS run, or the empty string when no pane is
# reachable. The single owner of that derivation, so no caller can resurrect a
# pane the daemon deliberately refused to identify.
#
# `${FM_SUPERVISOR_TARGET:-$FM_SUPERVISOR_TARGET_DEFAULT}` is wrong here:
# fm_super_main sets FM_SUPERVISOR_TARGET to the EMPTY STRING in paneless mode
# precisely so every pane primitive stays unreachable, and `:-` treats an empty
# value as unset - which silently hands back the legacy "firstmate:0" guess, the
# exact unrelated pane the 2026-07-22 incident typed into.
supervisor_pane_target() {
  paneless_delivery && return 0
  printf '%s' "${FM_SUPERVISOR_TARGET:-$FM_SUPERVISOR_TARGET_DEFAULT}"
}

# --- backend-independent active wedge alert ---------------------------------
# The tmux status-line flash in inject_wedge_alarm below is a cosmetic,
# client-side OSD with no cross-backend equivalent, so a wedged non-tmux primary
# (the 2026-07-10 overnight incident: a claude-on-herdr primary) got NO active
# signal - only the passive state/.subsuper-inject-wedged marker, which nothing
# surfaces until the next fleet action (that night, 20 escalations sat buffered
# for 8.5h). These helpers add a configurable active alert that does not depend
# on any pane or its backend status-line: an OS-level macOS notification, a
# herdr notification, or a captain-supplied command (push to a phone, etc.).
# Every channel is best-effort - a missing or failing channel logs and is
# skipped, never crashing the daemon loop - and the durable marker plus the tmux
# flash stay exactly as before.
#
# Config: config/wedge-alarm (local, gitignored), one channel directive per
# non-empty, non-comment line. FM_WEDGE_ALARM_CHANNEL overrides the file with a
# single directive. Directives:
#   off              disable the active alert entirely, regardless of position
#                    (marker + flash remain)
#   auto | default   platform default: macOS -> osascript; Linux -> notify-send
#                    when present; otherwise none
#   osascript        macOS Notification Center banner (backend-independent)
#   notify-send      Linux libnotify desktop banner (backend-independent)
#   herdr            herdr UI notification (herdr notification show)
#   command:<cmd>    run <cmd> via `sh -c`, summary on $1 and on stdin
# An absent config means auto, i.e. default-ON on a desktop macOS or Linux host:
# the alarm's whole purpose is to never be silent, so the reachable OS channel
# fires unless the captain explicitly disables it.

# Print the configured channel directives, one per line. FM_WEDGE_ALARM_CHANNEL
# wins (a single directive); else each non-empty, non-comment line of
# config/wedge-alarm; else "auto".
wedge_alarm_configured_channels() {
  local cfg line found=
  if [ -n "${FM_WEDGE_ALARM_CHANNEL:-}" ]; then
    printf '%s\n' "$FM_WEDGE_ALARM_CHANNEL"
    return 0
  fi
  cfg="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/wedge-alarm"
  if [ -f "$cfg" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [ -n "$line" ] || continue
      case "$line" in '#'*) continue ;; esac
      printf '%s\n' "$line"
      found=1
    done < "$cfg"
  fi
  [ -n "$found" ] || printf 'auto\n'
}

# Resolve the platform's default OS-level channel for `auto`. macOS reaches the
# captain via an osascript Notification Center banner; Linux reaches a desktop
# captain via a libnotify notify-send banner when that binary is present. A
# platform with no built-in channel, or a Linux host with no notify-send (a
# headless server), prints nothing and wedge_alarm_notify logs that the marker
# is the only signal, so the captain wires a command: directive (ntfy, Slack,
# SMS) instead. Both desktop defaults are gated on the binary actually existing,
# so a paneless away home never counts a channel it cannot fire.
wedge_alarm_platform_default() {
  case "$(uname)" in
    Darwin) command -v osascript >/dev/null 2>&1 && printf 'osascript' ;;
    Linux) command -v notify-send >/dev/null 2>&1 && printf 'notify-send' ;;
    *) : ;;
  esac
}

wedge_alarm_run_bounded() {
  local channel=$1 timeout monitor_was_on=0 pid start elapsed rc
  shift
  timeout=${FM_WEDGE_ALARM_TIMEOUT_SECS:-$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT}
  case "$timeout" in
    ''|*[!0-9]*) timeout=$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT ;;
    *) [ "$timeout" -gt 0 ] 2>/dev/null || timeout=$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT ;;
  esac
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  case $- in
    *m*) ;;
    *) log "wedge alarm: ${channel} notifier skipped because its watchdog could not start"; return 125 ;;
  esac
  "$@" &
  pid=$!
  WEDGE_ALARM_NOTIFIER_PID=$pid
  start=$SECONDS
  while kill -0 "-$pid" 2>/dev/null; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      wedge_alarm_stop_active_notifier
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      log "wedge alarm: ${channel} notifier timed out after ${elapsed}s (limit ${timeout}s)"
      return 124
    fi
    sleep 0.1
  done
  if wait "$pid"; then rc=0; else rc=$?; fi
  WEDGE_ALARM_NOTIFIER_PID=
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  return "$rc"
}

wedge_alarm_stop_active_notifier() {
  local pid=${WEDGE_ALARM_NOTIFIER_PID:-}
  [ -n "$pid" ] || return 0
  WEDGE_ALARM_NOTIFIER_PID=
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  sleep 0.2
  kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# The single execution seam for every configured notifier channel.
# FM_WEDGE_ALARM_EXEC, when set, REPLACES the real notifier: the resolved channel
# name and summary are handed to that command instead of ever invoking osascript
# or herdr or a captain-supplied command. This is the one injection point the test harness forces to a recorder
# so no test can post a real desktop notification - the library-mode guard at the
# foot of this file defaults it to "discard" whenever the daemon is SOURCED
# rather than executed, which is the only way a test reaches these functions. The
# special value "discard" fires nothing; unset means production (the executed
# daemon), so the real channels fire.
wedge_alarm_os_notifier_override() {  # <channel> <summary>
  local channel=$1 summary=$2 rc exec_override=${FM_WEDGE_ALARM_EXEC:-}
  case "$exec_override" in
    '') return 2 ;;
    discard) return 0 ;;
    *)
      wedge_alarm_run_bounded "$channel" "$exec_override" "$channel" "$summary" >/dev/null 2>&1
      rc=$?
      [ "$rc" -eq 0 ] && return 0
      log "wedge alarm: notifier override exited $rc for channel '$channel'"
      return 1 ;;
  esac
}

# Post a macOS Notification Center banner. `display notification` is OS-level,
# independent of any terminal pane or multiplexer status-line. The summary is
# passed as an argv item (never interpolated into the AppleScript source) so its
# text can never break the script. Best-effort: logs and returns 1 on failure.
wedge_alarm_via_osascript() {  # <summary>
  local summary=$1 rc
  wedge_alarm_os_notifier_override osascript "$summary"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  command -v osascript >/dev/null 2>&1 || {
    log "wedge alarm: osascript not found; cannot post a macOS notification"; return 1; }
  wedge_alarm_run_bounded osascript osascript -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title "firstmate: away-mode escalations WEDGED" sound name "Basso"' \
    -e 'end run' "$summary" >/dev/null 2>&1 && return 0
  log "wedge alarm: osascript notification failed"
  return 1
}

# Post a herdr UI notification - herdr's own surface, separate from the pane and
# its status-line. Best-effort: logs and returns 1 on failure.
wedge_alarm_via_herdr() {  # <summary>
  local summary=$1 rc
  wedge_alarm_os_notifier_override herdr "$summary"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  command -v herdr >/dev/null 2>&1 || {
    log "wedge alarm: herdr not found; cannot post a herdr notification"; return 1; }
  wedge_alarm_run_bounded herdr herdr notification show "firstmate: away-mode escalations WEDGED" \
    --body "$summary" --sound request >/dev/null 2>&1 && return 0
  log "wedge alarm: herdr notification failed"
  return 1
}

# Post a Linux desktop notification via libnotify's notify-send. Like osascript
# on macOS, this is an OS-level banner independent of any terminal pane or
# multiplexer status-line, so it reaches a desktop captain even when every pane
# is unreadable. The summary is passed as an argv item (never interpolated into
# a shell string) so its text can never break the call. Best-effort: logs and
# returns 1 on failure. A headless server without notify-send never reaches
# here, because wedge_alarm_platform_default only resolves to notify-send when
# the binary exists.
wedge_alarm_via_notify_send() {  # <summary>
  local summary=$1 rc
  wedge_alarm_os_notifier_override notify-send "$summary"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  command -v notify-send >/dev/null 2>&1 || {
    log "wedge alarm: notify-send not found; cannot post a Linux notification"; return 1; }
  wedge_alarm_run_bounded notify-send notify-send --urgency=critical \
    "firstmate: away-mode escalations WEDGED" "$summary" >/dev/null 2>&1 && return 0
  log "wedge alarm: notify-send notification failed"
  return 1
}

# Run a captain-supplied command with the summary on $1 and on stdin, so an
# alert can reach a phone/pager (ntfy, Slack, SMS) even when the captain is away
# from the machine entirely. Best-effort: logs and returns 1 on failure.
wedge_alarm_via_command() {  # <cmd> <summary>
  local cmd=$1 summary=$2 rc
  if [ "${WEDGE_ALARM_EMIT_ACTIVE:-}" != 1 ]; then
    wedge_alarm_emit command "$summary" "$cmd"
    return $?
  fi
  [ -n "$cmd" ] || { log "wedge alarm: empty command: channel; nothing to run"; return 1; }
  wedge_alarm_run_bounded command sh -c "$cmd" fm-wedge-alarm "$summary" \
    <<< "$summary" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  log "wedge alarm: command channel exited $rc (command redacted)"
  return 1
}

wedge_alarm_emit() {  # <channel> <summary>
  local channel=$1 summary=$2 cmd=${3:-} rc exec_override=${FM_WEDGE_ALARM_EXEC:-} WEDGE_ALARM_EMIT_ACTIVE=1
  case "$exec_override" in
    '') ;;
    discard) return 0 ;;
    *)
      wedge_alarm_run_bounded "$channel" "$exec_override" "$channel" "$summary" >/dev/null 2>&1
      rc=$?
      [ "$rc" -eq 0 ] && return 0
      log "wedge alarm: notifier override exited $rc for channel '$channel'"
      return 1 ;;
  esac
  case "$channel" in
    osascript) wedge_alarm_via_osascript "$summary" ;;
    notify-send) wedge_alarm_via_notify_send "$summary" ;;
    herdr) wedge_alarm_via_herdr "$summary" ;;
    command) wedge_alarm_via_command "$cmd" "$summary" ;;
  esac
}

# Fire every configured active-alert channel, best-effort. Always returns 0: a
# channel failure can never abort inject_wedge_alarm or the daemon loop. Any
# `off` directive disables the alert, regardless of position; an unresolvable
# `auto` (no OS channel on this platform) logs that the durable marker is the
# only signal. Every notifier routes through the test-forced recorder seam.
wedge_alarm_notify() {  # <summary> <marker>
  local summary=$1 marker=$2 ch
  local -a channels=()
  while IFS= read -r ch; do
    [ -n "$ch" ] || continue
    channels+=("$ch")
  done < <(wedge_alarm_configured_channels)
  for ch in "${channels[@]}"; do
    [ "$ch" = off ] && return 0
  done
  for ch in "${channels[@]}"; do
    case "$ch" in auto|default) ch=$(wedge_alarm_platform_default) ;; esac
    case "$ch" in
      '') log "wedge alarm: no OS-level alert channel on $(uname); durable marker $marker is the only signal - set config/wedge-alarm (e.g. a command: directive)" ;;
      osascript|notify-send|herdr) wedge_alarm_emit "$ch" "$summary" || true ;;
      command:*) wedge_alarm_emit command "$summary" "${ch#command:}" || true ;;
      *) log "wedge alarm: unrecognized active-alert channel directive (redacted); marker still written" ;;
    esac
  done
  return 0
}

# Raise a loud, rate-limited alarm when escalations cannot be delivered after
# max-defer (the supervisor pane is genuinely busy/wedged, or the submit's Enter
# is swallowed). The daemon must NEVER silently wedge: this logs
# an ERROR, drops a durable marker firstmate/recovery can surface, flashes
# the tmux supervisor client's status line when applicable, and attempts a
# configurable backend-independent active alert (wedge_alarm_notify). Nothing
# is lost - the buffer and the
# wake-queue both survive - but the stall stops being invisible.
#
# <mode> selects which stall is being reported, and therefore which subsystem the
# operator is pointed at while reading this during an incident:
#   pane             (default) the supervisor pane would not accept a submit.
#   paneless         the digests reached the durable outbox but firstmate's armed
#                    reader never picked them up.
#   paneless-append  the pull path could not even store the digest, so it is still
#                    buffered. Naming the pane here would send diagnosis to a
#                    subsystem this run does not have.
inject_wedge_alarm() {  # <state> <age-seconds> [mode]
  local state=$1 age=$2 mode=${3:-pane} marker target backend max_defer now notify=1
  local cause detail headline report report_rc=0
  marker="$state/.subsuper-inject-wedged"
  case "$mode" in
    paneless)
      cause="firstmate's away-mode inbox reader has not picked them up (never armed or never re-armed)"
      detail="Records waiting in the away-mode inbox:"
      ;;
    paneless-append)
      cause="the digest could not be stored in the away-mode inbox (state directory unwritable, or the inbox lock is held)"
      detail="The away-mode inbox could not accept an escalation. Buffered items:"
      ;;
    *)
      cause="inject could not confirm a submit (supervisor pane busy or wedged)"
      detail="The supervisor pane could not accept an escalation. Buffered items:"
      ;;
  esac
  max_defer="${FM_MAX_DEFER_SECS:-$MAX_DEFER_SECS_DEFAULT}"
  # Re-alarm at most once per max-defer window so a long wedge does not spam.
  if [ "$(_file_age "$marker")" -lt "$max_defer" ]; then
    return 0
  fi
  headline=$(printf 'fm away-mode inject WEDGED: %ss undelivered as of %s' \
    "$age" "$(date '+%Y-%m-%dT%H:%M:%S%z')")
  # The paneless listing has THREE outcomes, and the marker must keep them
  # distinguishable: it is read during an incident by the captain and by
  # bin/fm-afk-return.sh's catch-up gate, and a heading followed by nothing is the
  # failed-read-looks-empty presentation this delivery path removes everywhere
  # else. Read it once, here, and branch on the status rather than discarding it.
  if [ "$mode" = paneless ]; then
    report=$(fm_afk_outbox_pending_report "$state" 2>/dev/null) || report_rc=$?
    if [ "$report_rc" -eq 0 ] && [ -z "$report" ]; then
      # A positively successful read that found nothing pending means the reader
      # acknowledged every record between housekeeping's oldest-pending probe and
      # this write, so the escalation WAS delivered. That is this alarm's own
      # success condition - the same way the pane path retires the marker on a
      # confirmed submit - so it neither wakes the away captain nor writes the
      # marker: $marker means WEDGED to every one of its consumers, and
      # bin/fm-afk-return.sh files its first line as wedge catch-up evidence that
      # the away-mode skill then surfaces on the while-you-were-out report. The
      # outcome is recorded in the daemon log instead, and housekeeping retires
      # any pre-existing marker on its own terms. Suppression is allowed ONLY
      # here; an inbox that could not be READ still alarms, because a failed read
      # is never an empty one.
      log "away-mode escalation ${age}s undelivered; firstmate's away-mode inbox reader picked every record up while this alarm was being written. No alert raised and no wedge marker written."
      return 0
    fi
  fi
  now=$(_now)
  if [ "$WEDGE_ALARM_LAST_EPOCH" -gt 0 ] && [ $((now - WEDGE_ALARM_LAST_EPOCH)) -lt "$max_defer" ]; then
    notify=0
  else
    WEDGE_ALARM_LAST_EPOCH=$now
    log "ERROR: away-mode escalation undelivered ${age}s; ${cause}. Buffer + wake-queue preserved; alarm marker written."
  fi
  {
    printf '%s\n' "$headline"
    printf '%s\n' "$detail"
    if [ "$mode" = paneless ]; then
      if [ "$report_rc" -ne 0 ]; then
        printf '(the away-mode inbox could not be read while writing this alarm; its records are still pending)\n'
      else
        printf '%s\n' "$report"
      fi
    else
      cat "$state/.subsuper-escalations" 2>/dev/null
    fi
  } 2>/dev/null > "$marker" || true
  target=$(supervisor_pane_target)
  backend="${FM_SUPERVISOR_BACKEND:-$FM_SUPERVISOR_BACKEND_DEFAULT}"
  # Best-effort status-line flash. tmux's display-message is a client-side OSD
  # with no herdr equivalent; the log line + durable marker above are already
  # the primary, backend-independent signal, so a non-tmux backend just skips
  # this cosmetic extra rather than attempting an unsupported call.
  # Paneless mode leaves the target deliberately empty so no pane primitive is
  # reachable, so there is nothing to flash there either.
  if [ "$backend" = tmux ] && [ -n "$target" ]; then
    tmux display-message -t "$target" "fm: away-mode escalations WEDGED ${age}s — see $marker" 2>/dev/null || true
  fi
  # Backend-independent active alert. Unlike the tmux flash above (skipped on
  # every non-tmux backend), this can reach the captain even when every pane and
  # its backend status-line is unreadable - the gap the 2026-07-10 overnight
  # incident fell through. Configurable and best-effort; the marker above stays
  # the durable record whether or not any channel fires.
  if [ "$notify" -eq 1 ]; then
    wedge_alarm_notify "away-mode escalations WEDGED ${age}s undelivered - see $marker" "$marker"
  fi
}

# --- autonomous queue advancement ------------------------------------------
# One bounded away-mode driver tick (bin/fm-afk-driver.sh), which owns every
# decision it makes and every safety boundary it observes. This wrapper owns only
# the two things the DAEMON must guarantee: the tick can never take the daemon
# down, and it can never run longer than its own window.
#
# The daemon's contract is to escalate so firstmate's agent drives; the driver's
# is to advance the mechanical part of the queue when no firstmate turn is
# happening at all. Keeping the call here rather than in the watcher is deliberate:
# away mode is the only posture where nothing else is driving, and the driver
# refuses to run unless state/.afk is present anyway.
afk_driver_tick() {  # <state>
  local state=$1 driver out rc=0 pid waited timeout line
  driver="$FM_DAEMON_DIR/fm-afk-driver.sh"
  [ -x "$driver" ] || return 0
  timeout=${FM_AFK_DRIVER_TIMEOUT_SECS:-$AFK_DRIVER_TIMEOUT_SECS_DEFAULT}
  case "$timeout" in
    ''|*[!0-9]*|0) timeout=$AFK_DRIVER_TIMEOUT_SECS_DEFAULT ;;
  esac
  out=$(mktemp "${TMPDIR:-/tmp}/fm-afk-driver.XXXXXX") || return 0
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$state" "$driver" tick >"$out" 2>&1 &
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$timeout" ]; then
      kill "$pid" 2>/dev/null || true
      log "away-mode driver tick exceeded ${timeout}s and was stopped; the fleet is unchanged and the next tick retries"
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null || rc=$?
  if [ -s "$out" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      log "driver: $line"
    done < "$out"
  fi
  # A driver failure is a logged fact, never a daemon crash: supervision must keep
  # escalating even when queue advancement cannot run.
  case "$rc" in
    0|3|4) ;;
    *) log "away-mode driver tick failed (exit $rc); supervision continues unaffected" ;;
  esac
  rm -f "$out"
  return 0
}

# --- firstmate own-context stow nudge ---------------------------------------
# Read firstmate's OWN live context occupancy and, when it first crosses the stow
# threshold, buffer ONE operational directive telling firstmate to /stow now, then
# /compact, then re-arm supervision, before auto-compaction can discard un-stowed
# knowledge. Stow+compact is firstmate's own responsibility but depends on the
# agent remembering mid-flurry, and a long-lived session cannot auto-compact, so
# knowledge can be lost to a context reset with no enforcement. This is the
# structural, daemon-side half of that enforcement; the turn-end-hook half is
# separate (enforce-stow-at-turnend-guard).
#
# The crossing/marker/hysteresis state machine and the directive text are both
# owned by fm-secondmate-context-lib.sh (fm_context_stow_should_nudge,
# fm_context_stow_directive), shared byte-for-byte with the always-on watcher's
# context_stow_sweep, so the two supervision paths can never fork.
# The read is claude/jcode-capable (fm_sm_context_tokens) and fails CLOSED: any
# unreadable or unsupported harness, or a non-numeric count, yields no nudge -
# the check never nudges on a bad read. The nudge reuses the same operational
# escalation path (escalate_add -> escalate_flush -> inject_msg's
# fm_operational_input_encode away-supervisor) as every other daemon escalation,
# so firstmate recognizes it as an operational nudge rather than captain input.

# firstmate_own_context_tokens: firstmate's OWN context occupancy in tokens, or
# empty when unreadable. Harness comes from FM_SUPERVISOR_HARNESS (resolved once
# at startup in fm_super_main); the transcript cwd is firstmate's launch home,
# FM_CONTEXT_STOW_CWD when set (testing) else FM_HOME. Fails closed to empty on a
# missing harness/cwd or an unsupported harness, exactly like the secondmate
# monitor.
firstmate_own_context_tokens() {
  local harness=${FM_SUPERVISOR_HARNESS:-} cwd
  cwd=${FM_CONTEXT_STOW_CWD:-${FM_HOME:-}}
  [ -n "$harness" ] || return 0
  [ -n "$cwd" ] || return 0
  fm_sm_context_tokens "$cwd" "$harness"
}

# context_stow_check: buffer a single stow nudge when firstmate's own context
# first crosses the stow threshold. Rate-limited to ONCE per crossing by a
# durable marker (state/.context-stow-nudged); the marker clears only after the
# count drops back below (threshold - hysteresis), so a count hovering at the
# line cannot re-nudge every tick. Fails closed: a non-numeric/empty read leaves
# the marker untouched and buffers nothing. Deliberately NOT gated on afk_active:
# the gate is the daemon running (context fills in normal mode too), and delivery
# itself stays afk-gated in inject_msg.
context_stow_check() {  # <state>
  local state=$1 config threshold hysteresis tokens marker
  config="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
  tokens=$(firstmate_own_context_tokens 2>/dev/null || true)
  # Fail closed: never nudge on an unreadable or non-numeric count.
  case "$tokens" in ''|*[!0-9]*) return 0 ;; esac
  threshold=$(fm_context_stow_threshold "$config")
  hysteresis=${FM_CONTEXT_STOW_HYSTERESIS:-$CONTEXT_STOW_HYSTERESIS_DEFAULT}
  case "$hysteresis" in ''|*[!0-9]*) hysteresis=$CONTEXT_STOW_HYSTERESIS_DEFAULT ;; esac
  marker="$state/.context-stow-nudged"
  # Shared crossing/marker/hysteresis owner (fm-secondmate-context-lib.sh), the
  # SAME state machine the always-on watcher's context_stow_sweep drives, so the
  # two paths can never fork. It returns 0 only on the first crossing per arming.
  if fm_context_stow_should_nudge "$tokens" "$threshold" "$hysteresis" "$marker"; then
    escalate_add "$state" "$(fm_context_stow_directive "$tokens" "$threshold")"
    log "context-stow nudge buffered: ${tokens} tokens >= threshold ${threshold}"
  fi
  return 0
}

_oldest_line_age() {  # <buf> -> seconds since the oldest buffered item first arrived (sidecar epoch)
  local f=$1 since
  [ -s "$f" ] || { echo 999999; return; }
  since="${f}.since"
  if [ -r "$since" ]; then
    echo $(( $(_now) - $(cat "$since" 2>/dev/null || echo 0) ))
  else
    echo 999999
  fi
}

# --- housekeeping (runs every tick while the watcher is mid-cycle) ----------
# Cheap jobs, each guarded so an empty/quiet fleet costs near zero:
#  1) batch flush: if the escalation buffer's oldest content is older than
#     ESCALATE_BATCH_SECS (or batching is disabled), inject one digest.
#  1b) max-defer escape: if the buffer is STILL undelivered past MAX_DEFER_SECS,
#     attempt one normal delivery; if it cannot confirm, raise the wedge alarm.
#     Never silently defer forever.
#  1c) paneless undelivered escape: in pull delivery the append always succeeds,
#     so (1b) can never fire. Alarm instead when the oldest unacknowledged outbox
#     record is older than MAX_DEFER_SECS *and* the reader's liveness beacon is
#     absent or stale, through the same wedge alarm and marker, and clear that
#     alarm once the reader has acknowledged everything. Both conditions are
#     required: age alone cannot tell a reader that was never armed from a
#     firstmate that is armed and mid-turn.
#  2) stale recheck: for each pending stale marker past STALE_ESCALATE_SECS,
#     re-peek the pane; still idle -> escalate (wedge); resumed -> clear marker.
#  2b) pause re-surface: for each declared-pause marker past PAUSE_RESURFACE_SECS,
#     re-peek; busy/gone -> clear; still idle + still paused -> escalate a recheck
#     digest and reset the window (repeating bounded re-surface, never a wedge).
#  3) heartbeat scan: every HEARTBEAT_SCAN_SECS, grep state/*.status for a
#     captain-relevant line the per-wake classifier missed and escalate it.
#  4) driver tick: every FM_AFK_DRIVER_TICK_SECS while away mode is active, run one
#     bounded bin/fm-afk-driver.sh pass so the queue still advances when no
#     firstmate turn is happening. Never able to crash the daemon.
#  5) context-stow nudge: every FM_CONTEXT_STOW_CHECK_SECS, read firstmate's OWN
#     context and buffer one /stow nudge on the first crossing of the stow
#     threshold (context_stow_check). Gated on the daemon running, NOT on away
#     mode, because context fills in normal mode too; fails closed on a bad read.
housekeeping() {  # <state>
  local state=$1 now due f key task win marker age last max_defer oldest pause_secs
  local oldest_epoch outbox_rc driver_secs context_secs
  now=$(_now)
  migrate_watcher_pause_markers "$state"

  # (1) batch flush
  if [ "${FM_ESCALATE_BATCH_SECS:-$ESCALATE_BATCH_SECS_DEFAULT}" -le 0 ]; then
    escalate_flush "$state" || true
  else
    due=$(_oldest_line_age "$state/.subsuper-escalations")
    if [ "$due" -ge "${FM_ESCALATE_BATCH_SECS:-$ESCALATE_BATCH_SECS_DEFAULT}" ]; then
      escalate_flush "$state" || true
    fi
  fi

  # (1b) max-defer escape. If anything is still buffered past MAX_DEFER_SECS,
  # retry the normal delivery path. If that still cannot confirm, raise a loud
  # wedge alarm while preserving the buffer.
  max_defer=${FM_MAX_DEFER_SECS:-$MAX_DEFER_SECS_DEFAULT}
  if afk_active "$state" && [ "$max_defer" -gt 0 ] && [ -s "$state/.subsuper-escalations" ]; then
    oldest=$(_oldest_line_age "$state/.subsuper-escalations")
    # Throttle the alarm to once per max-defer window (the wedge marker doubles
    # as the throttle). A successful flush clears the buffer; a failed one alarms
    # and waits.
    if [ "$oldest" -ge "$max_defer" ] \
       && [ "$(_file_age "$state/.subsuper-inject-wedged")" -ge "$max_defer" ]; then
      if escalate_flush "$state"; then
        log "inject recovered: max-defer flush succeeded after ${oldest}s undelivered"
        # Same ownership split as escalate_flush: only the pane path's confirmed
        # submit is delivery, so only it retires the marker here.
        paneless_delivery || rm -f "$state/.subsuper-inject-wedged"
      elif paneless_delivery; then
        # A paneless run reaching here failed to STORE the digest; there is no
        # supervisor pane to be busy or wedged, so the alarm must not name one.
        inject_wedge_alarm "$state" "$oldest" paneless-append
      else
        inject_wedge_alarm "$state" "$oldest"
      fi
    fi
  fi

  # (1c) PANELESS undelivered escape. Appending to the outbox always succeeds, so
  # in paneless mode the escalation buffer always clears and (1b) above - which
  # keys off that buffer - can never fire. Without this age check, records
  # accumulate unread whenever firstmate's reader was never armed or re-armed (a
  # harness restart, a turn that ignored the reader's re-arm line, or paneless
  # selected while firstmate actually had a reachable pane), which silently
  # recreates the very undelivered-escalation incident this delivery mode exists
  # to fix. Same alarm, same durable marker, same rate limiting as the pane path,
  # and presence-gated on away mode exactly like every other away-mode behavior.
  if afk_active "$state" && [ "$max_defer" -gt 0 ] && paneless_delivery \
     && [ "$now" -ge "$OUTBOX_PROBE_NOT_BEFORE" ]; then
    outbox_rc=0
    oldest_epoch=$(fm_afk_outbox_oldest_pending_epoch "$state") || outbox_rc=$?
    if [ "$outbox_rc" -ne 0 ]; then
      # An outbox that could not be read is not an empty one, so neither alarm nor
      # clear: leave whatever alarm state exists and retry later. Each failed
      # attempt burns the full bounded lock acquire, so back the probe off to one
      # per max-defer window and log only the transition INTO the failed-read
      # state - otherwise this line, and that stall, repeat on every
      # HOUSEKEEPING_TICK_DEFAULT tick during precisely the incident the line
      # exists to document.
      if [ "$OUTBOX_UNREADABLE" -eq 0 ]; then
        OUTBOX_UNREADABLE=1
        if [ "$outbox_rc" -eq "$FM_AFK_OUTBOX_LOCK_TIMEOUT" ]; then
          log "away-mode inbox lock could not be acquired; undelivered-escalation alarm state left unchanged until the outbox can be read again"
        else
          log "away-mode inbox unreadable; undelivered-escalation alarm state left unchanged until it can be read again"
        fi
      fi
      OUTBOX_PROBE_NOT_BEFORE=$(( now + max_defer ))
    else
      if [ "$OUTBOX_UNREADABLE" -eq 1 ]; then
        OUTBOX_UNREADABLE=0
        log "away-mode inbox readable again; undelivered-escalation alarm resumed"
      fi
      if [ -n "$oldest_epoch" ]; then
        oldest=$(( now - oldest_epoch ))
        # The alarm must answer "is anyone going to read this?", not "how old is
        # the oldest record?". Age alone cannot separate a reader that was never
        # armed from a firstmate that is armed and simply mid-turn, and agent
        # turns longer than the max-defer window are routine, so age alone would
        # alarm the captain on the healthy path. An armed reader stamps
        # state/.afk-inbox.beat every poll iteration, so only a beacon that is
        # ABSENT or stale means nothing has claimed the outbox. Raising the
        # threshold instead was rejected on purpose: that trades a false alarm for
        # a silent gap, which is the failure this delivery mode exists to remove.
        if [ "$oldest" -ge "$max_defer" ] \
           && [ "$(_file_age "$(fm_afk_inbox_beacon_file "$state")")" -ge "$(inbox_beacon_stale_secs)" ] \
           && [ "$(_file_age "$state/.subsuper-inject-wedged")" -ge "$max_defer" ]; then
          inject_wedge_alarm "$state" "$oldest" paneless
        fi
      elif [ ! -s "$state/.subsuper-escalations" ]; then
        # Everything appended has been acknowledged and nothing is buffered behind
        # a failed append, so a prior alarm is stale: clear it rather than let a
        # delivered-then-quiet outbox keep alarming.
        rm -f "$state/.subsuper-inject-wedged"
      fi
    fi
  fi

  # (2) stale persistence recheck
  for marker in "$state"/.subsuper-stale-*; do
    [ -e "$marker" ] || continue
    key="${marker##*.subsuper-stale-}"
    # Reconstruct the backend target from metadata, with the live tmux list as the
    # legacy fallback for old markers that predate meta lookup.
    win=$(window_for_task "$key" "$state" 2>/dev/null || true)
    if [ -z "$win" ]; then
      # Window gone (task torn down): drop the marker, nothing to escalate.
      rm -f "$marker"; continue
    fi
    task=$(window_to_task "$win" "$state")
    last=$(last_status_line "$state/$task.status")
    if [ -n "$last" ] && status_is_paused "$last"; then
      reconcile_pause_tracking "$win" "$state" "$last"
      continue
    fi
    age=$(( now - $(cat "$marker" 2>/dev/null || echo "$now") ))
    [ "$age" -ge "${FM_STALE_ESCALATE_SECS:-$STALE_ESCALATE_SECS_DEFAULT}" ] || continue
    stale_window_is_busy "$win" "$state"
    case "$?" in
      0) rm -f "$marker" ;;
      2) rm -f "$marker" ;;
      *) escalate_add "$state" "stale persisted ${age}s (possible wedge): $win"
         stale_marker_remove "$win" "$state" ;;
    esac
  done

  # (2b) pause re-surface recheck. A DECLARED external-wait pause idles by design,
  # so it is rechecked on a much longer cadence than a wedge (PAUSE_RESURFACE_SECS)
  # and never escalated as one - but it MUST re-surface, so a forgotten pause cannot
  # rot invisibly. Past the window: busy (resumed) or gone -> drop; still idle and
  # still declaring the pause -> escalate a recheck digest and reset the marker so
  # the window repeats.
  pause_secs=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
  for marker in "$state"/.subsuper-paused-*; do
    [ -e "$marker" ] || continue
    key="${marker##*.subsuper-paused-}"
    win=$(window_for_task "$key" "$state" 2>/dev/null || true)
    if [ -z "$win" ]; then
      rm -f "$marker"; continue
    fi
    task=$(window_to_task "$win" "$state")
    last=$(last_status_line "$state/$task.status")
    if [ -z "$last" ] || ! status_is_paused "$last"; then
      reconcile_pause_tracking "$win" "$state" "$last"
      continue
    fi
    age=$(( now - $(cat "$marker" 2>/dev/null || echo "$now") ))
    [ "$age" -ge "$pause_secs" ] || continue
    stale_window_is_busy "$win" "$state"
    case "$?" in
      0) rm -f "$marker" ;;
      2) rm -f "$marker" ;;
      *)
        last=$(last_status_line "$state/$task.status")
        if [ -n "$last" ] && status_is_paused "$last"; then
          escalate_add "$state" "paused ${age}s (awaiting external, recheck whether the wait still holds): $win"
          _now > "$marker"
        else
          rm -f "$marker"
        fi
        ;;
    esac
  done

  # (3) heartbeat scan (catch-all for a captain-relevant status the per-wake
  #     classifier may have missed). Cheap: status files only, no tmux. The
  #     captain-relevant filtering is the shared classifier's
  #     scan_captain_relevant_statuses; the daemon layers its digest dedup on top.
  if [ "$(_file_age "$state/.subsuper-last-scan")" -ge "${FM_HEARTBEAT_SCAN_SECS:-$HEARTBEAT_SCAN_SECS_DEFAULT}" ]; then
    _now > "$state/.subsuper-last-scan"
    local seen
    while IFS="$(printf '\t')" read -r f task last; do
      [ -n "$f" ] || continue
      seen="$state/.subsuper-seen-status-$(_stale_key "$task")"
      [ "$(cat "$seen" 2>/dev/null || true)" = "$last" ] && continue
      escalate_add "$state" "$(basename "$f"): $last (catch-all scan)"
      mark_status_seen "$state" "$task" "$last"
    done < <(scan_captain_relevant_statuses "$state")
  fi

  # (4) autonomous queue advancement. Escalating tells firstmate what to drive;
  # while the captain is away there may be no firstmate turn for hours, so one
  # bounded driver tick advances the mechanical part of the queue itself. Gated on
  # away mode and on its own cadence, and wrapped so it can never take the daemon
  # down (afk_driver_tick above).
  if afk_active "$state"; then
    driver_secs=${FM_AFK_DRIVER_TICK_SECS:-$AFK_DRIVER_TICK_SECS_DEFAULT}
    case "$driver_secs" in
      ''|*[!0-9]*) driver_secs=$AFK_DRIVER_TICK_SECS_DEFAULT ;;
    esac
    if [ "$driver_secs" -gt 0 ] \
       && [ "$(_file_age "$state/.subsuper-last-driver")" -ge "$driver_secs" ]; then
      _now > "$state/.subsuper-last-driver"
      afk_driver_tick "$state"
    fi
  fi

  # (5) firstmate own-context stow nudge. On its own cadence, read firstmate's OWN
  # context and buffer one /stow nudge on the first crossing of the stow
  # threshold. NOT gated on away mode - a filling context loses knowledge in
  # normal mode too, and the daemon runs in both - and fails closed on a bad read
  # (context_stow_check above). FM_CONTEXT_STOW_CHECK_SECS=0 disables it.
  context_secs=${FM_CONTEXT_STOW_CHECK_SECS:-$CONTEXT_STOW_CHECK_SECS_DEFAULT}
  case "$context_secs" in
    ''|*[!0-9]*) context_secs=$CONTEXT_STOW_CHECK_SECS_DEFAULT ;;
  esac
  if [ "$context_secs" -gt 0 ] \
     && [ "$(_file_age "$state/.subsuper-last-context-stow")" -ge "$context_secs" ]; then
    _now > "$state/.subsuper-last-context-stow"
    context_stow_check "$state"
  fi
}

# Find a recorded or live window target whose task id matches the marker key.
window_for_task() {  # <task-key> [state]
  local key=$1 state=${2:-$(_state_root)} meta task w t
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    task=$(basename "$meta"); task=${task%.meta}
    [ "$(_stale_key "$task")" = "$key" ] || continue
    w=$(fm_backend_target_of_meta "$meta")
    [ -n "$w" ] && { printf '%s' "$w"; return 0; }
  done
  for w in $(tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null | grep ':fm-' || true); do
    t=$(window_to_task "$w" "$state")
    [ "$(_stale_key "$t")" = "$key" ] && { printf '%s' "$w"; return 0; }
  done
  return 1
}

# --- injection --------------------------------------------------------------
# inject_msg: send one escalation digest to the supervisor pane.
# Returns 0 on successful inject (or empty buffer), non-zero if the pane is
# gone, the supervisor is busy, afk is inactive, or the verified submit cannot
# be confirmed after bounded retries. On non-zero the caller preserves
# the buffer so the escalation survives for the next cycle or the catch-up flush.
#
# Submit model:
#   - TYPE ONCE, then submit with Enter. Never retype the digest: a swallowed
#     Enter leaves our text in the composer, and retyping would concatenate two
#     sentinel-prefixed digests into one corrupted turn.
#   - SUBMIT ACK = the backend submit primitive reports `empty` after Enter.
#     For tmux that means a cleared composer; for herdr's normal idle-baseline
#     path it means native agent-state observed a real turn start.
#     Pending means Enter was swallowed; unknown is treated as undelivered by
#     this strict daemon path.
#   - COMPOSER GUARD before typing: if the cursor line already has real content
#     after dim/faint ghost text and borders are ignored (a human's half-typed
#     line, or a previous injection's unsent text), defer entirely - injecting
#     would merge with the human's text.
inject_msg() {  # <message> [state]
  local msg=$1 state target backend retries sleep_s verdict composer encoded
  state="${2:-$(_state_root)}"
  # (1) Presence-gate: inject ONLY when afk is active. When afk is off, the
  # daemon self-handles and stays quiet; firstmate drives the normal always-on
  # watcher triage. Escalations buffer and survive for the next catch-up flush.
  afk_active "$state" || { log "inject deferred: afk inactive"; return 1; }
  # (2) Single-line digest: collapse any embedded newlines so submission via
  # send-keys + Enter is unambiguous regardless of how the TUI composer treats
  # them. Then use the canonical typed envelope so downstream consumers retain
  # the exact away-supervisor kind without interpreting this payload's prose.
  msg=$(_collapse_newlines "$msg")
  fm_operational_input_encode away-supervisor "$msg" encoded || return 1
  msg=$encoded
  # (2b) PANELESS delivery: no pane was ever identified, so there is nothing to
  # type into. Append the identical marked, single-line digest to the durable
  # outbox and let firstmate's armed reader (bin/fm-afk-inbox.sh) pull it. A
  # failed append returns non-zero exactly like a failed inject, so the digest
  # stays buffered for the next tick instead of vanishing.
  if paneless_delivery; then
    if fm_afk_outbox_append "$state" escalation "$msg"; then
      # Both numbers come from inside the append's own critical section. Re-reading
      # the count here would take the outbox lock again, and a bounded acquire lost
      # to a concurrent reader would log "0 record(s) pending pickup" right after a
      # record that was in fact appended.
      log "delivered to the away-mode inbox (paneless): record #${FM_AFK_OUTBOX_APPEND_SEQ}, ${FM_AFK_OUTBOX_APPEND_PENDING:-unknown} record(s) pending pickup"
      return 0
    fi
    log "inject failed: could not append the digest to the away-mode inbox"
    return 1
  fi
  target=$(supervisor_pane_target)
  # BACKEND-AWARE (previously a raw `tmux display-message` pane-exists probe):
  # dispatches through bin/fm-backend.sh so a herdr supervisor pane is checked
  # via the herdr adapter instead of always assuming tmux. Falls back to tmux
  # when unset (sourced/test contexts that never ran fm_super_main's startup
  # discovery), matching this function's pre-existing default assumption.
  backend="${FM_SUPERVISOR_BACKEND:-tmux}"
  fm_backend_target_exists "$backend" "$target" || return 1
  # (3) Busy-guard: never inject into an in-use pane.
  #   a) pane_is_busy: the harness shows a busy footer (agent mid-turn).
  if pane_is_busy "$target" "$backend"; then
    log "inject deferred: supervisor pane busy (agent mid-turn)"
    return 1
  fi
  #   b) Composer-guard: inject ONLY into a confirmed-empty GENUINE agent
  #      composer. The shared classifier (fm_backend_composer_state ->
  #      fm_composer_classify_content, bin/fm-composer-lib.sh) reports 'pending'
  #      for real unsubmitted text (a human's half-typed line, or a swallowed
  #      prior injection) and 'unknown' for a bare dead-shell prompt (the agent
  #      exited to its login shell) or an unreadable pane. Neither is a safe
  #      target - typing the escalation into a shell could execute it - so defer
  #      on anything that is not affirmatively 'empty'. A deferred escalation
  #      stays buffered for the next cycle or the catch-up flush.
  composer=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)
  if [ "$composer" != empty ]; then
    log "inject deferred: supervisor composer not confirmed-empty (state=${composer:-unknown}: pending input, dead-shell prompt, or unreadable pane)"
    return 1
  fi
  # (4) Type the digest ONCE, then submit with Enter (retry Enter only, never
  # retype) via the shared submit primitive. Success = the backend confirms
  # submit. An unconfirmed/unknown pane does NOT count as delivered, so the
  # buffer is preserved (strict) rather than cleared.
  # Dispatches through fm_backend_send_text_submit (bin/fm-backend.sh): for
  # backend=tmux this calls fm_backend_tmux_send_text_submit, a verbatim
  # re-export of fm_tmux_submit_core - byte-identical to calling it directly.
  retries=${FM_INJECT_CONFIRM_RETRIES:-$INJECT_CONFIRM_RETRIES_DEFAULT}
  sleep_s=${FM_INJECT_CONFIRM_SLEEP:-$INJECT_CONFIRM_SLEEP_DEFAULT}
  verdict=$(fm_backend_send_text_submit "$backend" "$target" "$msg" "$retries" "$sleep_s" "$sleep_s")
  if [ "$verdict" = empty ]; then
    return 0  # Backend confirmed the submit.
  fi
  log "inject failed: submit unconfirmed after $retries retries (verdict=$verdict, text may be in composer)"
  return 1
}

# --- INJECT_SKIP prefix match (literal prefixes, no regex) ------------------
should_force_self() {  # <reason>
  local reason=$1 skip="${FM_INJECT_SKIP:-$INJECT_SKIP_DEFAULT}" prefix
  [ -n "$skip" ] || return 1
  local -a prefixes
  IFS='|' read -ra prefixes <<<"$skip"
  for prefix in "${prefixes[@]}"; do
    [ -n "$prefix" ] || continue
    [ "$reason" != "${reason#"$prefix"}" ] && return 0
  done
  return 1
}

# A real watcher WAKE reason starts with one of these prefixes. Anything else on
# the watcher child's stdout (e.g. "watcher: already running" on a singleton-lock
# collision, reachable if the daemon was SIGKILL'd and its orphaned watcher child
# still holds the #29 singleton lock) is a STATUS line, not a wake: handling it
# as an unknown wake would flood the escalation buffer and restart the child with
# no crash backoff. The main loop treats a non-wake line as idle (log + sleep +
# continue), so a singleton collision cannot hot-loop escalations.
is_wake_reason() {  # <reason>
  local reason=$1
  case "$reason" in
    signal:*|stale:*|check:*|heartbeat|heartbeat:*) return 0 ;;
  esac
  return 1
}

# --- dispatch one wake reason to self-handle or escalate --------------------
# Side effects: logging, marker records, escalation buffer appends.
handle_wake() {  # <reason> <state>
  local reason=$1 state=$2 decision action distilled task last
  local kind="" arg=""
  if should_force_self "$reason"; then
    log "wake force-self (FM_INJECT_SKIP): $reason"
    return
  fi
  case "$reason" in
    signal:*) kind=signal; arg="${reason#signal: }"
              decision=$(classify_signal "$arg" "$state") ;;
    stale:*)  kind=stale; arg="${reason#stale: }"
              decision=$(classify_stale "$arg" "$state") ;;
    check:*)  decision=$(classify_check "$reason") ;;
    heartbeat|heartbeat:*) decision=$(classify_heartbeat) ;;
    *)        decision=$(classify_unknown "$reason") ;;
  esac
  action=${decision%%|*}
  distilled=${decision#*|}
  [ "$kind" = signal ] && sync_pause_markers_from_signal "$state" "$arg"
  case "$action" in
    escalate)
      log "escalate: $reason -> $distilled"
      escalate_add "$state" "$distilled"
      # A terminal-stale escalate must not leave a persistence marker behind, or
      # housekeeping re-escalates the same pane as a false wedge later.
      [ "$kind" = "stale" ] && stale_marker_remove "$arg" "$state"
      mark_escalated_seen "$kind" "$arg" "$state"
      [ "${FM_ESCALATE_BATCH_SECS:-$ESCALATE_BATCH_SECS_DEFAULT}" -le 0 ] && { escalate_flush "$state" || true; }
      ;;
    pause)
      # Declared external-wait pause: record a pause marker (long re-surface
      # cadence in housekeeping) and drop any wedge stale marker, so a pane that
      # transitioned working->paused is not still wedge-aged. Only stale produces
      # this action.
      if [ "$kind" = "stale" ]; then
        stale_marker_remove "$arg" "$state"
        pause_marker_record "$arg" "$state"
      fi
      log "self-handle (paused): $reason -> $distilled"
      ;;
    *)
      # Transient (non-terminal) stale: record/refresh the wedge marker so
      # housekeeping can age it, and drop any pause marker (a crew that left its
      # pause reverts to normal wedge aging). The persistence recheck, not this
      # wake, escalates a wedge.
      if [ "$kind" = "stale" ]; then
        task=$(window_to_task "$arg" "$state")
        last=$(last_status_line "$state/$task.status")
        # Clear wedge aging only for terminal (or legacy free-text) captain lines.
        # Nonterminal progress verbs keep possible-wedge markers even if free text
        # once looked captain-relevant or was written into a seen marker.
        _clear_wedge=0
        if [ -n "$last" ] && status_is_captain_relevant "$last"; then
          if status_is_terminal_verb "$last"; then
            _clear_wedge=1
          else
            case "$(status_line_verb "$last")" in
              working|resolved|captain-held) _clear_wedge=0 ;;
              *) _clear_wedge=1 ;;
            esac
          fi
        fi
        if [ "$_clear_wedge" = 1 ]; then
          stale_marker_remove "$arg" "$state"
        else
          pause_marker_remove "$arg" "$state"
          stale_marker_record "$arg" "$state"
        fi
      fi
      log "self-handle: $reason -> $distilled"
      ;;
  esac
}

# --- log --------------------------------------------------------------------
# Uses LOG set by fm_super_main; harmless no-op-ish if unset (tests source fns
# directly and pass state explicitly, so they do not call log).
log() { [ -n "${LOG:-}" ] && printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG"; }

trim_log() {
  local sz tmp
  [ -n "${LOG:-}" ] || return 0
  sz=$(wc -c < "$LOG" 2>/dev/null) || return 0
  [ "$sz" -ge "${FM_LOG_MAX_BYTES:-$LOG_MAX_BYTES_DEFAULT}" ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-daemon-log.XXXXXX") || return 0
  tail -n "${FM_LOG_KEEP_LINES:-$LOG_KEEP_LINES_DEFAULT}" "$LOG" >"$tmp" 2>/dev/null && mv -f "$tmp" "$LOG"
}

# ============================================================================
# Everything below runs only when the script is EXECUTED, not sourced. The pure
# classifiers above are sourceable for unit tests (tests/fm-daemon.test.sh).
# ============================================================================

fm_super_main() {
  local STATE
  STATE="$(_state_root)"
  mkdir -p "$STATE"

  # Source the portable lock helpers (works on macOS where flock is absent).
  # Export FM_STATE_OVERRIDE so the lib resolves the same state dir.
  # shellcheck source=bin/fm-wake-lib.sh
  FM_STATE_OVERRIDE="$STATE" . "$FM_DAEMON_DIR/fm-wake-lib.sh"

  local WATCH="$FM_DAEMON_DIR/fm-watch.sh"
  local LOG="$STATE/.supervise-daemon.log"
  local WATCH_ERR="$STATE/.supervise-daemon.watcher.err"
  local LOCK="$STATE/.supervise-daemon.lock"
  local PIDFILE="$STATE/.supervise-daemon.pid"
  local INJECT_FAIL_SLEEP=${FM_INJECT_FAIL_SLEEP:-$INJECT_FAIL_SLEEP_DEFAULT}
  local CRASH_THRESHOLD=${FM_CRASH_THRESHOLD:-$CRASH_THRESHOLD_DEFAULT}
  local CRASH_WINDOW=${FM_CRASH_WINDOW:-$CRASH_WINDOW_DEFAULT}
  local CRASH_BACKOFF=${FM_CRASH_BACKOFF:-$CRASH_BACKOFF_DEFAULT}
  local CRASH_NORMAL_SLEEP=${FM_CRASH_NORMAL_SLEEP:-$CRASH_NORMAL_SLEEP_DEFAULT}

  [ -x "$WATCH" ] || { echo "error: watcher not found or not executable: $WATCH" >&2; exit 1; }

  # --- single instance (portable lock, no flock dependency) ------------------
  if ! fm_lock_try_acquire "$LOCK"; then
    if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
      echo "error: another fm-supervise-daemon is already running (pid $FM_LOCK_HELD_PID, lock $LOCK held)" >&2
    else
      echo "error: another fm-supervise-daemon is already running (lock $LOCK held)" >&2
    fi
    exit 1
  fi
  echo "$$" > "$PIDFILE"
  fm_pid_identity "${BASHPID:-$$}" > "$LOCK/pid-identity" 2>/dev/null || true
  # The lock is now the authority for "a daemon supervises this home", so drop
  # the away-entry bring-up claim (bin/fm-afk-daemon-lib.sh "DAEMON BRING-UP").
  # Dropped here rather than after startup validation, so a daemon that refuses
  # to start below leaves ownership free instead of latched.
  fm_afk_daemon_pending_clear "$STATE" || true

  # --- auto-discover the supervisor BACKEND (tmux vs herdr) first -----------
  # Priority: FM_SUPERVISOR_BACKEND override > $TMUX_PANE (tmux) > $HERDR_ENV=1
  # (herdr) > tmux fallback. Resolved before the target below, since target
  # discovery composes a herdr "<session>:<pane-id>" string using the same
  # $HERDR_PANE_ID/$HERDR_SESSION markers this checks. Exporting the result
  # into FM_SUPERVISOR_BACKEND makes inject_msg/pane_is_busy/pane_input_pending
  # (which read that env var) dispatch through the right backend without an
  # extra global thread-through.
  local discovered_backend backend_source
  backend_source="FM_SUPERVISOR_BACKEND"
  if [ -z "${FM_SUPERVISOR_BACKEND:-}" ]; then
    if [ -n "${TMUX_PANE:-}" ]; then
      backend_source="TMUX_PANE"
    elif [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
      backend_source="HERDR_ENV"
    else
      backend_source="FALLBACK($FM_SUPERVISOR_BACKEND_DEFAULT)"
    fi
  fi
  discovered_backend=$(discover_supervisor_backend) || true
  FM_SUPERVISOR_BACKEND="$discovered_backend"
  local BACKEND="$FM_SUPERVISOR_BACKEND"

  # --- resolve firstmate's OWN harness once, for the context-stow nudge --------
  # The context read (fm_sm_context_tokens) needs firstmate's harness to know
  # which transcript format to parse. The daemon is exec'd from firstmate's pane
  # via its harness's background tool, so it inherits the same env markers
  # bin/fm-harness.sh detect_own reads (CLAUDECODE, JCODE_ACTIVE_PROVIDER, etc.).
  # An explicit FM_SUPERVISOR_HARNESS override wins (testing). Only claude and
  # jcode have a verified read; every other harness reads unknown and the nudge
  # simply never fires (fail closed). Resolved once here rather than per tick so
  # the read stays cheap.
  if [ -z "${FM_SUPERVISOR_HARNESS:-}" ]; then
    FM_SUPERVISOR_HARNESS=$("$FM_DAEMON_DIR/fm-harness.sh" 2>/dev/null || printf 'unknown')
  fi
  export FM_SUPERVISOR_HARNESS

  # --- refuse an unsupported supervisor backend loudly, before ever trying a
  # tmux/herdr-specific call against it (zellij, orca, and cmux have no verified
  # composer/busy primitives wired up for this daemon yet - AGENTS.md section 4
  # harness-verification discipline). This is the clear refusal the task calls
  # for, instead of a confusing "does not resolve to a tmux pane" error.
  if ! fm_backend_list_contains "$FM_SUPERVISOR_SUPPORTED_BACKENDS" "$BACKEND"; then
    echo "error: away-mode daemon does not support supervisor backend '$BACKEND' yet (supported: $FM_SUPERVISOR_SUPPORTED_BACKENDS); set FM_SUPERVISOR_BACKEND=tmux|herdr and FM_SUPERVISOR_TARGET to run firstmate's own pane under a supported backend" >&2
    log "startup failed: unsupported supervisor backend '$BACKEND' (source=$backend_source)"
    fm_lock_release "$LOCK" 2>/dev/null || true
    rm -f "$PIDFILE" 2>/dev/null || true
    exit 1
  fi

  # --- auto-discover the supervisor target (the pane running firstmate) -----
  # Priority: FM_SUPERVISOR_TARGET override > $TMUX_PANE (tmux; inherited from
  # the pane that launched the daemon, normally firstmate's own) >
  # $HERDR_PANE_ID (herdr, composed into "<session>:<pane-id>") > firstmate:0
  # fallback. Exporting the result into FM_SUPERVISOR_TARGET makes inject_msg
  # (which reads that env var) use the discovered pane without an extra global.
  local discovered target_source
  target_source="FM_SUPERVISOR_TARGET"
  if [ -z "${FM_SUPERVISOR_TARGET:-}" ]; then
    if [ -n "${TMUX_PANE:-}" ]; then
      target_source="TMUX_PANE"
    elif [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
      target_source="HERDR_ENV(HERDR_PANE_ID)"
    else
      target_source="FALLBACK(firstmate:0)"
    fi
  fi

  # --- choose the delivery mode before touching any pane --------------------
  # A FALLBACK target source means nothing identified firstmate's own pane, so
  # the legacy firstmate:0 guess is NOT used as an injection target: paneless
  # pull delivery is selected instead (afk_delivery_mode_select above owns the
  # rule and the reasoning). Both the mode and the reason are logged, and the
  # mode is recorded durably so the reader and firstmate can tell a paneless away
  # session from a pane one without re-deriving this discovery.
  local DELIVERY delivery_rc=0
  DELIVERY=$(afk_delivery_mode_select "$target_source") || delivery_rc=$?
  if [ "$delivery_rc" -eq 2 ]; then
    echo "warn: ignoring unrecognized FM_AFK_DELIVERY='${FM_AFK_DELIVERY:-}' (expected auto, pane, or paneless); using '$DELIVERY'" >&2
  fi
  FM_AFK_DELIVERY_MODE="$DELIVERY"

  local TARGET=""
  if [ "$DELIVERY" = paneless ]; then
    # Deliberately leave FM_SUPERVISOR_TARGET empty: with no identified pane,
    # every pane primitive stays unreachable for the rest of this run, so the
    # daemon cannot type an escalation into an unrelated terminal.
    FM_SUPERVISOR_TARGET=""
    echo "info: no supervisor pane identified (target_source=$target_source); away-mode escalations will be delivered through the pull inbox - arm bin/fm-afk-inbox.sh as a tracked background task" >&2
    log "delivery mode: paneless (reason: no supervisor pane identified; target_source=$target_source, backend_source=$backend_source)"
  else
    if discovered=$(discover_supervisor_target); then
      : # resolved cleanly
    else
      echo "warn: could not auto-discover supervisor pane (no FM_SUPERVISOR_TARGET, TMUX_PANE, or HERDR_ENV/HERDR_PANE_ID); falling back to '$discovered' — verify this is firstmate's pane" >&2
    fi
    FM_SUPERVISOR_TARGET="$discovered"
    TARGET="$FM_SUPERVISOR_TARGET"
    log "delivery mode: pane (reason: supervisor pane identified; target_source=$target_source)"

    # --- validate supervisor target at startup (a missing target is a typo) ---
    # Dispatches through bin/fm-backend.sh instead of a raw `tmux display-message`
    # probe, so a herdr supervisor pane is checked via the herdr adapter; for
    # backend=tmux this runs the exact same `tmux display-message -p -t "$TARGET"
    # '#{pane_id}'` call as before. A named-but-absent pane is a supported-but-
    # broken pane, so it still refuses loudly rather than silently switching
    # channels.
    if ! fm_backend_target_exists "$BACKEND" "$TARGET"; then
      echo "error: supervisor target '$TARGET' does not resolve to a $BACKEND pane; set FM_SUPERVISOR_TARGET" >&2
      log "startup failed: target '$TARGET' not found (backend=$BACKEND)"
      fm_lock_release "$LOCK" 2>/dev/null || true
      rm -f "$PIDFILE" 2>/dev/null || true
      exit 1
    fi
  fi

  fm_afk_delivery_mode_record "$STATE" "$DELIVERY" \
    || log "warn: could not record the delivery mode in $(fm_afk_delivery_mode_file "$STATE")"

  local afk_status="off"
  afk_active "$STATE" && afk_status="on"
  log "daemon starting (pid $$); delivery=$DELIVERY; target=${TARGET:-none}; target_source=$target_source; backend=$BACKEND; backend_source=$backend_source; afk=$afk_status; inject_skip='${FM_INJECT_SKIP:-$INJECT_SKIP_DEFAULT}'; stale_escalate=${FM_STALE_ESCALATE_SECS:-$STALE_ESCALATE_SECS_DEFAULT}s; batch=${FM_ESCALATE_BATCH_SECS:-$ESCALATE_BATCH_SECS_DEFAULT}s"
  migrate_watcher_pause_markers "$STATE"

  # Invariant: every housekeeping cadence clock starts at daemon start. These
  # gates compare _file_age against a cadence, and _file_age treats a missing
  # marker as infinitely old, so an absent or already-overdue marker would fire
  # on the very first housekeeping tick and race the per-wake signal path (the
  # primary escalation owner; the catch-all scan is only a backstop). A marker
  # that is still fresh keeps its real elapsed time. Startup-only stamp; the
  # main loop never touches these here. See task fm-afk-inject-catchall-race.
  _stamp_cadence_marker() {
    local marker=$1 cadence=$2 fallback=$3
    case "$cadence" in
      ''|*[!0-9]*) cadence=$fallback ;;
    esac
    if [ ! -e "$marker" ] || [ "$(_file_age "$marker")" -ge "$cadence" ]; then
      _now > "$marker"
    fi
  }
  _stamp_cadence_marker "$STATE/.subsuper-last-scan" \
    "${FM_HEARTBEAT_SCAN_SECS:-$HEARTBEAT_SCAN_SECS_DEFAULT}" "$HEARTBEAT_SCAN_SECS_DEFAULT"
  _stamp_cadence_marker "$STATE/.subsuper-last-housekeep" \
    "${FM_HOUSEKEEPING_TICK:-$HOUSEKEEPING_TICK_DEFAULT}" "$HOUSEKEEPING_TICK_DEFAULT"
  _stamp_cadence_marker "$STATE/.subsuper-last-driver" \
    "${FM_AFK_DRIVER_TICK_SECS:-$AFK_DRIVER_TICK_SECS_DEFAULT}" "$AFK_DRIVER_TICK_SECS_DEFAULT"
  _stamp_cadence_marker "$STATE/.subsuper-last-context-stow" \
    "${FM_CONTEXT_STOW_CHECK_SECS:-$CONTEXT_STOW_CHECK_SECS_DEFAULT}" "$CONTEXT_STOW_CHECK_SECS_DEFAULT"

  # --- shutdown: flush buffered escalations, reap child, release lock -------
  local WATCHER_PID="" CUR_TMP=""
  cleanup() {
    trap - TERM INT
    wedge_alarm_stop_active_notifier
    escalate_flush "$STATE" 2>/dev/null || true
    if [ -n "${WATCHER_PID:-}" ]; then
      kill "$WATCHER_PID" 2>/dev/null || true
      wait "$WATCHER_PID" 2>/dev/null || true
    fi
    if [ -n "${CUR_TMP:-}" ]; then
      rm -f "$CUR_TMP" 2>/dev/null || true
    fi
    fm_lock_release "$LOCK" 2>/dev/null || true
    rm -f "$PIDFILE" 2>/dev/null || true
    log "daemon shutting down"
    exit 0
  }
  trap cleanup TERM INT

  # --- crash-loop guard -----------------------------------------------------
  local crash_times=() backoff_secs=$CRASH_NORMAL_SLEEP
  record_crash() {
    local now t
    now=$(_now)
    local -a keep=()
    for t in "${crash_times[@]:-}"; do
      [ -n "$t" ] && [ $((now - t)) -lt "$CRASH_WINDOW" ] && keep+=("$t")
    done
    keep+=("$now")
    crash_times=("${keep[@]}")
    if [ "${#crash_times[@]}" -gt "$CRASH_THRESHOLD" ]; then
      log "ERROR: watcher crashed ${#crash_times[@]} times within ${CRASH_WINDOW}s; backing off ${CRASH_BACKOFF}s"
      crash_times=()
      backoff_secs=$CRASH_BACKOFF
    else
      backoff_secs=$CRASH_NORMAL_SLEEP
    fi
  }

  start_watcher() {
    CUR_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-watch.XXXXXX") || { log "error: mktemp failed; retrying in 5s"; sleep 5; return 1; }
    "$WATCH" >"$CUR_TMP" 2>>"$WATCH_ERR" &
    WATCHER_PID=$!
  }

  local rc reason
  while true; do
    # --- pane-gone guard (preserved) ---------------------------------------
    # With the #29 watcher's enqueue-before-suppress, a wake is no longer
    # swallowed by running the watcher with no injection target. We still back
    # off while the pane is gone: self-handling needs no pane, but escalation
    # has nowhere to go, and firstmate itself is the consumer of escalations.
    # Catch-up signals persist in state/*.status and flow on the next run, so
    # this delays rather than loses work.
    # Paneless delivery has no pane to lose: the outbox is always reachable, so
    # this guard is skipped entirely rather than backing off against a target
    # that was never used.
    if [ "$DELIVERY" != paneless ] && ! fm_backend_target_exists "$BACKEND" "$TARGET"; then
      log "warn: supervisor target '$TARGET' gone; backing off ${INJECT_FAIL_SLEEP}s, will retry"
      # Flush is pointless with no pane; preserve any buffered escalations.
      sleep "$INJECT_FAIL_SLEEP"
      continue
    fi

    # --- (re)start watcher if it has exited --------------------------------
    if [ -z "${WATCHER_PID:-}" ] || ! kill -0 "${WATCHER_PID:-}" 2>/dev/null; then
      if [ -n "${WATCHER_PID:-}" ]; then
        # child exited: reap + classify its wake reason
        if wait "${WATCHER_PID}"; then rc=0; else rc=$?; fi
        reason=""
        if [ -n "${CUR_TMP:-}" ] && [ -e "${CUR_TMP:-}" ]; then
          reason=$(<"${CUR_TMP}")
        fi
        if [ -n "${CUR_TMP:-}" ]; then
          rm -f "${CUR_TMP}" 2>/dev/null || true
        fi
        CUR_TMP=""
        if [ "$rc" -ne 0 ] || [ -z "$reason" ]; then
          record_crash
          log "watcher exited rc=$rc reason='$reason'; restarting after ${backoff_secs}s"
          WATCHER_PID=""
          sleep "$backoff_secs"
          continue
        fi
        # Non-wake stdout (e.g. a watcher singleton-collision "already running"
        # status line) is NOT a wake: idling here prevents an escalation flood
        # and a backoff-less child restart. record_crash is intentionally
        # skipped (rc=0, this is normal idle, not a crash).
        if ! is_wake_reason "$reason"; then
          log "watcher non-wake stdout, idling: $reason"
          WATCHER_PID=""
          sleep "${HOUSEKEEPING_TICK:-$HOUSEKEEPING_TICK_DEFAULT}"
          continue
        fi
        log "wake: $reason"
        handle_wake "$reason" "$STATE"
        trim_log
      fi
      start_watcher || continue
    fi

    # --- one housekeeping tick (gated to HOUSEKEEPING_TICK), then poll -------
    # The watcher child runs on its own FM_POLL cadence internally; we only need
    # to detect its exit (the kill -0 above) promptly and run housekeeping often
    # enough that batch flushes, stale rechecks, and the catch-all scan fire on
    # cadence. Gating keeps a large fleet cheap between ticks.
    sleep 1
    if [ "$(_file_age "$STATE/.subsuper-last-housekeep")" -ge "${FM_HOUSEKEEPING_TICK:-$HOUSEKEEPING_TICK_DEFAULT}" ]; then
      _now > "$STATE/.subsuper-last-housekeep"
      housekeeping "$STATE"
    fi
  done
}

# Run only when executed, not when sourced (tests source the classifiers).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_super_main "$@"
else
  # Library mode: these functions were SOURCED (only tests do this - production
  # execs the daemon, see bin/fm-afk-start.sh). Make it structurally impossible
  # for a sourced context to fire a real desktop notification from the wedge
  # alarm: default the FM_WEDGE_ALARM_EXEC notifier seam to "discard" unless the
  # embedder already wired one (e.g. a recorder in tests/wake-helpers.sh). It is
  # exported so a real daemon a test later spawns inherits the safe default too.
  # The executed branch above never runs this, so production is untouched.
  : "${FM_WEDGE_ALARM_EXEC:=discard}"
  export FM_WEDGE_ALARM_EXEC
fi
