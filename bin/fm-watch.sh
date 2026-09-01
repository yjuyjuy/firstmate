#!/usr/bin/env bash
# Firstmate watcher.
# Classifies supervision wakes in bash. In normal mode it absorbs benign wakes
# and keeps blocking; it queues and exits only for actionable wakes, apart from
# the env-gated proof-of-life "tick:" close described below, which queues nothing.
# The no-verb signal and stale path is absorb-only-when-provably-working: a wake
# is absorbed only when the crew shows POSITIVE evidence it is still working (an
# actively-running no-mistakes step, or a backend busy signal), and surfaced
# otherwise, so a crew that finishes (or stops and waits) without a current
# working signal is never silently swallowed. A declared external-wait pause is
# the separate idle absorb case and re-surfaces only on its long bounded cadence,
# although its initial no-verb status signal still surfaces in normal mode.
# While away mode is on AND a live daemon for this home is actually running it,
# the daemon owns triage and this watcher queues and exits on every wake; away
# mode with no daemon is the away posture only and leaves triage here.
# Exit contract: absorbing a benign wake NEVER exits the loop. Only two things
# end a cycle - an actionable wake (a queued reason line, exit 0) or a real
# internal error (a loud message, nonzero exit). A best-effort side effect that
# fails while a wake is being ABSORBED (nothing is being surfaced) or after an
# actionable wake is already durably queued must be logged and the loop continued
# or the reason still surfaced; it must never be conflated with the internal-error
# exit. See handle_push_transition for the event fast-path's version of this rule.
# Printed reason lines:
#   signal: <file>...      status/turn-end signals, surfaced when a listed status
#                          has a captain-relevant verb OR a no-verb signal's crew
#                          is not provably working, unless a live away-mode daemon owns triage
#   stale: <window>        a provably-working stale is ALWAYS absorbed (with a wedge
#                          timer) regardless of what the status log says - an active
#                          run-step or busy pane outranks even a captain-relevant log
#                          line, since the crew's own log gets no new entry once
#                          firstmate hands it to a no-mistakes validation. A declared
#                          external-wait pause is absorbed instead with its own long
#                          re-surface cadence, never as a wedge. Only when neither
#                          absorb class applies does the log's last line decide:
#                          terminal (captain-relevant) or non-terminal (no verb),
#                          both surfaced at once. For an ordinary crew whose stale
#                          is NOT captain-relevant (a stopped non-terminal crew, or
#                          a provably-working stale past the wedge threshold), the
#                          watcher first sends ONE re-prompt via fm-send pointing
#                          back at the task brief and asking for a status append,
#                          records it in state/.stale-nudged-<key> so it never
#                          repeats for the same stall episode, and escalates the
#                          stale wake only when the worker stays silent past the
#                          next grace window (secondmates and supervise=off panes
#                          are never nudged). A surfaced wedge carries an
#                          "escalation N" count in the reason; at
#                          FM_WEDGE_DEMAND_INSPECT_COUNT consecutive escalations
#                          on the SAME pane, the reason
#                          also carries a "demand-deep-inspection" marker so the
#                          wake payload itself, not just repetition, forces a
#                          closer look instead of another routine supervision
#                          resume. Unless a live away-mode daemon owns triage.
#   check: <script>: <out> authenticated check output, always actionable
#   check: rejected unauthenticated state checks: <paths>
#                          unsafe state checks were refused without execution
#   check: host-resources <reading>
#                          the host-resource sweep found CPU/memory/swap pressure
#                          WORSE than the level firstmate was last told about.
#                          Report-only: nothing is paused, shed or killed here.
#   check: session-review <headline>
#                          the hourly session review found something that has
#                          NOT moved (a silent worker, an unanswered decision,
#                          queued work with nothing running, a batch of unmerged
#                          branches). Silent when there is nothing new to say.
#   check: session-cleanup <headline>
#                          the hourly cleanup sweep found accumulated material it
#                          deliberately did NOT remove because it could hold
#                          unlanded work. Report-only; nothing is discarded here.
#                          Both are armed by bin/fm-session-start.sh and run on
#                          this watcher's slow poll (bin/fm-hourly-lib.sh).
#   check: context-stow-nudge <detail>
#                          firstmate's OWN context crossed the stow threshold
#                          (config/context-stow-threshold) during NORMAL
#                          supervision: /stow now and /compact when the session
#                          cannot auto-compact. Nudge only - nothing is stowed or
#                          compacted here. Fires once per crossing and stays out
#                          while a live away-mode daemon owns the nudge.
#   check: dead-turn <task>
#                          turn-liveness tripwire (Visibility Gap-5): a lane
#                          whose in-flight turn died after a reactive 429
#                          account rotation already got exactly ONE automatic
#                          resume steer and is STILL content-frozen (or shows
#                          a jcode terminal-dead marker) with no status append
#                          since the 429, so its dead turn is escalated
#                          instead of sitting silent and looking healthy
#                          (mechanism and evidence:
#                          docs/design-visibility-improvements.md).
#   check: retry-loop <task>
#                          retry-loop tripwire: a supervised worker appended
#                          the SAME status body FM_RETRY_LOOP_MIN+ times in a
#                          row (default 3), an objective sign it is stuck
#                          retrying without progress. It already got exactly
#                          ONE automatic steer (`stop retrying, append
#                          blocked: with the exact blocker and wait`) recorded
#                          in state/.retry-loop-<key>, and is escalated ONCE
#                          here only when the SAME loop continued past that
#                          steer. Secondmate and supervise=off panes are never
#                          steered. See retry_loop_check.
#   tick: <note>           env-gated proof-of-life close (FM_WATCH_ABSORB_TICK=1,
#                          default off) for a benign-ABSORBED wake while work is
#                          under way. Not an actionable wake: nothing is queued,
#                          and the arm layer classifies it as a benign completion
#                          rather than the empty-cycle failure. See absorb_tick
#                          and docs/watcher-continuity.md
#   heartbeat              fleet-scan backstop found an unsurfaced captain-relevant
#                          status, unless a live away-mode daemon owns triage.
#                          Becomes "heartbeat: host resources degraded|critical"
#                          when a recent sweep found the host under pressure; a
#                          disabled monitor or a stale cached reading annotates
#                          nothing. The annotation keeps the "heartbeat:" prefix
#                          every wake consumer matches on, so an annotated
#                          heartbeat is still recognised as an actionable wake
# For normal supervision, resume the session-start primary-harness protocol
# after each printed reason. Direct duplicate invocations of this script still
# no-op through the watcher singleton lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
mkdir -p "$STATE"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# Same in-flight count the guards use, so the watcher and they cannot disagree
# about what "work under way" means (see absorb_tick).
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# Shared wake classifier (captain-relevant verbs + signal/stale/heartbeat
# predicates), the SAME library the away-mode daemon uses, so the triage policy
# has one definition.
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# One owner for "is an away-mode daemon actually running for THIS home?", the
# question that decides whether this watcher keeps its own triage or hands every
# wake to the daemon.
# shellcheck source=bin/fm-afk-daemon-lib.sh
. "$SCRIPT_DIR/fm-afk-daemon-lib.sh"
# The DEFAULT EVENT SOURCE: this watcher's poll loop over the pull primitives
# (capture, recorded windows, backend busy-state, and the BUSY_REGEX fallback)
# synthesizes the signal/stale/check/heartbeat wake vocabulary for backends with
# no native event push. tmux always reports unknown busy-state, preserving the
# original regex path. A push-capable backend (herdr) additionally replaces this
# watcher's blind terminal sleep with a bounded wait on its native event stream
# (event_wait_or_sleep below), so a crew entering `blocked` wakes its supervisor
# sub-second; the poll loop stays live every cycle as the permanent fail-closed
# backstop. See bin/fm-backend.sh and docs/herdr-backend.md.
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# Shared normalized-transition accessors and the single-owner status->action
# policy table, so the event-wait splice reads transition records the same way
# the herdr subscriber writes them (bin/fm-transition-lib.sh).
# shellcheck source=bin/fm-transition-lib.sh
. "$SCRIPT_DIR/fm-transition-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# Parent-owned secondmate missed-report guards: durable pending-reply
# expectations created by fm-send on marked secondmate requests. The tick is
# cheap when no records exist and never scrapes secondmate conversation.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# Secondmate context-window read + threshold, for the slow-poll context monitor
# (secondmate_context_sweep). Fails closed: an unreadable/unsupported harness
# yields no tokens and never wakes. See docs/secondmate-context-handoff.md.
# shellcheck source=bin/fm-secondmate-context-lib.sh
. "$SCRIPT_DIR/fm-secondmate-context-lib.sh"

# Arming, cadence, and script mapping for the two session-lifetime hourly
# passes (hourly_pass_sweep below). Unarmed homes never run them.
# shellcheck source=bin/fm-hourly-lib.sh
. "$SCRIPT_DIR/fm-hourly-lib.sh"
# shellcheck source=bin/fm-token-sessions-lib.sh
. "$SCRIPT_DIR/fm-token-sessions-lib.sh"

# Shared per-task telemetry writer (state/<id>.telemetry, key=value). The
# hot-path 429 anomaly scan (quota_anomaly_scan below, Visibility Gap-2) uses
# fm_telemetry_set to bump count_429/last_429_ts without clobbering keys sibling
# producers own. No side effects on source.
# shellcheck source=bin/fm-telemetry-lib.sh
. "$SCRIPT_DIR/fm-telemetry-lib.sh"
# The ONE fleet-wide owner of composer-content classification
# (bin/fm-composer-lib.sh), which also owns the jcode terminal-dead marker
# catalog (supervision-miss-rootcause F2). The dead-turn check below consumes
# fm_composer_tail_has_jcode_dead_marker so the marker vocabulary cannot drift
# between the watcher, the adapters, and any future busy-state correction.
# shellcheck source=bin/fm-composer-lib.sh
. "$SCRIPT_DIR/fm-composer-lib.sh"

# Immediate herdr pane-exit detection: on a confirmed dead herdr pane for a
# tracked task, capture the last ~20 pane lines to state/<id>.crash-tail and
# enqueue one `check: pane-crashed <id>` wake so recovery starts with evidence.
# Herdr-only, meta-gated, idempotent - see fm_pane_crash_capture. Assumes
# fm-backend.sh and fm-wake-lib.sh are already sourced above.
# shellcheck source=bin/fm-pane-crash-lib.sh
. "$SCRIPT_DIR/fm-pane-crash-lib.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
WATCHER_STALE_GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-900}}
# The singleton-lock acquisition, EXIT trap, and the blocking supervision loop
# all live below the source guard at the very bottom of this file (see "Main
# entry"). Sourcing this file for unit tests therefore loads the functions -
# including the event-wait splice below - and returns before acquiring the lock
# or starting the loop. Running it as a script executes the runtime exactly as
# before, byte-for-byte.

# Portable stat. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`.
# Do NOT use the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form: on Linux
# `stat -f` is *filesystem* stat and writes a partial filesystem dump ("File: ...",
# "Blocks: ...") to stdout before failing, so the fallback's correct output gets
# appended to that garbage. Arithmetic under `set -u` then aborts on the stray
# token (e.g. the word "File" read as an unset variable), which silently kills the
# watcher mid-cycle. Detect the platform once and pick the right form.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }        # epoch seconds of mtime
  stat_sig()   { stat -f '%z:%Fm' "$1" 2>/dev/null; }   # size:mtime signature
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
  stat_sig()   { stat -c '%s:%Y' "$1" 2>/dev/null; }
fi

# Watcher cadence config file. docs/configuration.md owns the knob and
# bin/fm-cadence-lib.sh owns the resolver (shared with the startup drift alarm
# bin/fm-drift-check.sh, so the value the watcher CONSUMES and the value the
# alarm AUDITS are resolved by one function and cannot drift apart). The file is
# optional, local, and gitignored, and follows the same present/absent/malformed
# contract as config/heavy-run-slots: present means override, absent means the
# built-in default below, a malformed value falls back LOUDLY to the default
# (never silently).
#
# This reader lives in the watcher, NOT at the arm command, on purpose: the
# arm-command seatbelt (bin/fm-arm-pretool-check.sh) refuses an env-prefixed
# invocation like `FM_SIGNAL_GRACE=240 bin/fm-watch-arm.sh` as a compound
# wrapper, so the env knobs were unreachable in normal operation. The watcher
# reading a file sidesteps that: firstmate edits config/watcher-cadence and
# arms with no env prefix, so bin/fm-watch-arm.sh stays a clean single command.
#
# PRECEDENCE is config-authoritative: a VALID value in config/watcher-cadence
# wins over the environment, and the env var supplies a value only when the file
# is silent on that key (operator override and test seam). This is the fix for
# the settings.local.json drift class - a stale FM_POLL a prior debugging
# session left in the environment no longer outranks the captain's owning file.
# Warnings are collected in FM_CADENCE_WARNINGS and emitted in the runtime
# section (near the host-resource fallback log), because the log helper is
# defined later.
# shellcheck source=bin/fm-cadence-lib.sh
. "$SCRIPT_DIR/fm-cadence-lib.sh"
CADENCE_FILE="$CONFIG/watcher-cadence"
FM_CADENCE_WARNINGS=""
fm_cadence_scan_unknown_keys "$CADENCE_FILE"
fm_cadence_resolve "$CADENCE_FILE" FM_POLL poll 300; POLL=$FM_CADENCE_RESULT  # seconds between cycles (captain default: 5 min).
                                      # INVARIANT: POLL < grace (WATCHER_STALE_GRACE,
                                      # set above from FM_WATCHER_STALE_GRACE, then
                                      # FM_GUARD_GRACE) so a full cycle's wait never
                                      # outlives the liveness beacon - see beacon_sleep
                                      # and the start-up invariant check in the runtime
                                      # section, which warns when it is violated.
                                      # This default of 300 sits below the tracked
                                      # grace default of 900, which is the captain's
                                      # operating pair. If either value is changed,
                                      # keep POLL below the grace.
fm_cadence_resolve "$CADENCE_FILE" FM_HEARTBEAT heartbeat 600; HEARTBEAT=$FM_CADENCE_RESULT  # base seconds between heartbeat scans
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-600}  # seconds between *.check.sh sweeps (captain default: 10 min)
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
# Host-resource sweep cadence, on its OWN interval rather than POLL or
# CHECK_INTERVAL: host pressure moves on a scale of minutes, and X mode drives
# CHECK_INTERVAL down to 30s. bin/fm-resource-check.sh owns the knob, its default
# and its disabled (0) form; this reads the resolved value once at start, the
# same way every other cadence here is fixed for the process lifetime.
# An unrunnable or unparseable resolver falls back to that default rather than
# silently switching the monitor off for this watcher's whole lifetime; the
# fallback is logged once at startup so the condition is visible.
# Mirror of bin/fm-resource-check.sh's RESOURCE_INTERVAL_DEFAULT, which is the
# single source of truth for this number; keep the two in step.
# The flag is kept separate from the offending value, because the case this
# fallback exists for - a resolver that cannot run at all - yields an EMPTY
# value, and an emptiness test would suppress exactly that log line.
RESOURCE_INTERVAL_DEFAULT=900
RESOURCE_INTERVAL_FELL_BACK=0
RESOURCE_INTERVAL_RAW=$("$SCRIPT_DIR/fm-resource-check.sh" --interval 2>/dev/null || printf '')
RESOURCE_INTERVAL=$RESOURCE_INTERVAL_RAW
case "$RESOURCE_INTERVAL" in
  ''|*[!0-9]*)
    RESOURCE_INTERVAL_FELL_BACK=1
    [ -n "$RESOURCE_INTERVAL_RAW" ] || RESOURCE_INTERVAL_RAW='<empty>'
    RESOURCE_INTERVAL=$RESOURCE_INTERVAL_DEFAULT
    ;;
esac
fm_cadence_resolve "$CADENCE_FILE" FM_SIGNAL_GRACE signal_grace 240; SIGNAL_GRACE=$FM_CADENCE_RESULT  # seconds to linger after a
                                      # signal so trailing signals coalesce into one wake.
                                      # Raised from 30 to 240 on 2026-07-24 evidence: one lane
                                      # produced four wakes in minutes (status append, turn-end,
                                      # another status append, then a stale reading while its
                                      # suite ran), and each wake forces firstmate through a
                                      # drain + re-arm before any other fleet command, costing
                                      # the captain a full round trip per wake for no decision.
                                      # 240s spans that burst so ordinary worker chatter batches
                                      # into ONE wake, honoring the standing priority that
                                      # firstmate's responsiveness to the captain outranks
                                      # instant reaction to worker notifications. This does NOT
                                      # delay a real terminal event: the linger below is skipped
                                      # when the first scan already carries a captain-relevant
                                      # verb (done:/failed:/needs-decision:/blocked:), so a
                                      # genuine terminal wake still surfaces promptly - only
                                      # no-verb chatter pays the coalescing wait.
# Longest blind-sleep slice. A single `sleep POLL` refreshes the beacon only at
# the loop top, so once POLL approaches the grace a healthy sleeping watcher
# reads as dead for the back of every cycle (the wedge). beacon_sleep splits the
# wait into slices no longer than min(POLL, grace/2) and re-touches the beacon
# each slice, so a healthy watcher stays fresh within the grace for the whole
# cycle and a machine-suspend can strand the beacon for at most one slice past
# resume. Floor at 1s so a tiny grace still makes progress.
_beacon_half=$(( WATCHER_STALE_GRACE / 2 ))
[ "$_beacon_half" -lt 1 ] && _beacon_half=1
if [ "$POLL" -lt "$_beacon_half" ]; then BEACON_SLICE=$POLL; else BEACON_SLICE=$_beacon_half; fi
[ "$BEACON_SLICE" -lt 1 ] && BEACON_SLICE=1
# Busy signatures per harness, OR-ed. Extend via env when new adapters are verified.
# claude/codex: "esc to interrupt"; opencode: "esc interrupt"; pi: "Working...";
# grok: "Ctrl+c:cancel" (the mid-turn cancel hint in grok's keybind bar, shown iff a
# turn is running; absent when idle - verified grok 0.2.73, ASCII to avoid the
# locale fragility of matching grok's braille spinner glyph directly).
# jcode: its numbered composer prompt row, anchored at column 0, flips from "3>"
# (idle) to "4…" (mid-turn) and back - verified jcode server 0.64.2. jcode's
# spinner line is NOT usable: its text changes across the phases of one turn
# ("⠴ sending context… 1s · https", then "⠹ 4s · 714.3 tps · https", then a
# per-tool line such as "●·· bash ··● · $ sleep 12 · https · 6s · ⌥+B bg"), and
# the trailing ⏳ on the composer row is present when idle too, so neither is a
# busy signal. The composer row is the one signal present in every busy phase.
BUSY_REGEX=${FM_BUSY_REGEX:-'esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel|^[0-9]+…'}
# Always-on wake triage: most wakes during a long crew validation are benign (a
# working: note or turn-end while a pipeline runs, a no-change heartbeat). Rather
# than wake firstmate's LLM for each, this watcher classifies every wake in bash
# and ABSORBS the benign majority - it advances the suppression marker, logs to a
# debug log, and keeps blocking WITHOUT enqueuing or exiting. The no-verb signal
# / stale path is absorb-only-when-provably-working: such a wake is absorbed ONLY
# while the crew shows positive evidence it is still working (an actively-running
# no-mistakes step, or a busy pane, via crew_is_provably_working over
# fm-crew-state.sh); a crew that stopped its turn with no running pipeline and no
# busy pane is SURFACED, so a finish reported only through interactive pane menus
# (no done: status) is never swallowed. An ACTIONABLE wake (a captain-relevant
# signal, a no-verb signal whose crew is not provably working, any check, a stale
# pane whose crew is not provably working, a provably-working stale past the
# threshold, or anything unknown) is written to the durable queue and exits, which
# is what wakes the LLM through the background-task completion. The same classifier
# (fm-classify-lib.sh) backs the away-mode daemon; while a live daemon for this home
# owns triage, this watcher reverts to one-shot (enqueue + exit on every wake) and
# never double-triages - and never runs the costly provably-working read.
STALE_ESCALATE_SECS=${FM_STALE_ESCALATE_SECS:-240}  # idle secs before a provably-working stale escalates as a possible wedge
# A crew that declared a pause is idling on a known external wait, so its stale
# pane is absorbed rather than wedge-escalated.
# A captain-held or paused crew whose agent has confidently exited uses the same
# bounded cadence, while a live or ambiguously read agent still surfaces once.
# These cases re-surface once for a recheck every PAUSE_RESURFACE_SECS - far
# longer than the wedge threshold, but finite so a forgotten hold cannot rot invisibly.
PAUSE_RESURFACE_SECS=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
TRIAGE_LOG="$STATE/.watch-triage.log"
TRIAGE_LOG_MAX_BYTES=${FM_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}
# Consecutive event-path failures (fm_backend_wait_transition returning 2 -
# connect/subscribe failure) before the push fast-path is disabled for the rest
# of this watcher process and the loop reverts to pure polling (report section
# 5c trigger 3: proven-unreliable-at-runtime). A watcher restart re-probes
# capability, so a transient herdr hiccup self-heals on the next cycle chain.
EVENT_CAP_FAIL_MAX=${FM_EVENT_CAP_FAIL_MAX:-3}
# Per-process memo for the push-capability probe (fm_backend_events_capable runs
# a ~220KB `herdr api schema` read, too heavy to repeat every poll). Keyed by
# "<backend>:<session>"; re-probed only when that key changes.
_event_cap_key=""
_event_cap_ok=0
_event_cap_fails=0
# Bumped once per poll iteration; per-cycle memos key off it.
POLL_CYCLE=0

# afk_daemon_owns_triage: 0 while away mode is on AND a live daemon for this home
# is actually running it. Then the daemon wraps this watcher and owns triage, so
# the watcher must behave one-shot (enqueue + exit on every wake) and let the
# daemon classify - never absorb here, or the daemon's digest/injection layer
# would never see the wake. Away mode with NO daemon is the away posture only:
# deferring to a triager that never runs would surface every benign wake and
# leave the fleet effectively unsupervised, so the watcher keeps its own normal
# triage. Memoized for the whole poll cycle so one wake never reads the daemon
# lock several times (bin/fm-afk-daemon-lib.sh owns the liveness question).
_afk_owner_cycle=""
_afk_owner_verdict=1
afk_daemon_owns_triage() {
  if [ "$_afk_owner_cycle" != "$POLL_CYCLE" ]; then
    _afk_owner_cycle=$POLL_CYCLE
    _afk_owner_verdict=1
    fm_afk_daemon_owns_supervision "$STATE" "$SCRIPT_DIR" && _afk_owner_verdict=0
  fi
  return "$_afk_owner_verdict"
}

# Append one line to the triage debug log explaining an absorbed (benign) wake,
# size-capped so a long benign stretch cannot grow it without bound. Best-effort:
# a logging hiccup never affects supervision.
triage_log() {
  local sz
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$TRIAGE_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$TRIAGE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$TRIAGE_LOG_MAX_BYTES" ]; then
    tail -n 2000 "$TRIAGE_LOG" > "$TRIAGE_LOG.tmp" 2>/dev/null && mv -f "$TRIAGE_LOG.tmp" "$TRIAGE_LOG" 2>/dev/null
    rm -f "$TRIAGE_LOG.tmp" 2>/dev/null || true
  fi
}

hash_pane() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# window_is_busy: 0 (busy) iff the task's harness is actively working. Prefers
# a backend's native semantic busy state (fm_backend_busy_state - herdr's
# agent.get; herdr-addendum "busy state" row, "the first backend where
# fm_session_busy_state gets real semantics"); falls back to the existing
# pane-tail regex ONLY when the backend reports unknown (tmux always does, so
# its path is unchanged byte-for-byte). <tail40> is the same bounded capture
# already read for hashing, so this adds no extra backend calls on the
# regex-fallback path.
window_is_busy() {  # <window> <tail40>
  local w=$1 tail40=$2 bs
  bs=$(fm_backend_busy_state "$(window_backend "$w")" "$w" 2>/dev/null)
  case "$bs" in
    busy) return 0 ;;
    idle) return 1 ;;
    *)
      printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 | grep -qiE "$BUSY_REGEX"
      ;;
  esac
}

window_kind() {
  local w=$1 meta kind
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    echo "$kind"
    return 0
  fi
  echo unknown
}

# window_backend: the backend recorded in the meta whose window= matches <w>,
# defaulting to tmux (absent backend= means tmux; the P1 compatibility
# contract) when no matching meta carries the field, or none matches at all.
window_backend() {
  local w=$1 meta backend
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    backend=$(grep '^backend=' "$meta" | cut -d= -f2- || true)
    [ -n "$backend" ] || backend=tmux
    echo "$backend"
    return 0
  fi
  echo tmux
}

window_label() {
  local w=$1 task
  task=$(window_to_task "$w" "$STATE")
  [ -n "$task" ] && printf 'fm-%s' "$task"
}

recorded_windows() {
  local meta w seen=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    # An --unsupervised pane (supervise=off) is deliberately hands-off: firstmate
    # created it but must never observe, steer, or poke it (the grilling-handoff
    # griller pane, a live interview any injection would corrupt). Dropping it
    # HERE excludes it from every supervision path this list feeds - the
    # stale/wedge loop, the turn-end/event fast wake, and the context sweep - so
    # the exclusion is enforced in one place rather than per-consumer.
    [ "$(grep '^supervise=' "$meta" | cut -d= -f2- || true)" = off ] && continue
    w=$(fm_backend_target_of_meta "$meta")
    [ -n "$w" ] || continue
    case "$seen" in
      *"|$w|"*) continue ;;
    esac
    seen="$seen|$w|"
    printf '%s\n' "$w"
  done
}

# secondmate_context_sweep: the slow-poll context monitor. For each live
# secondmate window, read its context-window occupancy (claude and jcode have a
# verified read; every other harness reads unknown and is skipped - fail closed,
# no false handoff) and act
# once when it first crosses the configured threshold, so a proactive handoff
# replaces the context-full agent BEFORE it must /compact.
#
# Two behaviors on a first crossing, chosen by the opt-in
# config/secondmate-auto-handoff flag (fm_sm_auto_handoff_enabled; absent =
# today's escalate-only default, fail-closed):
#   - AUTO disabled (default): wake firstmate once with a `check:
#     secondmate-context <id>` line; the primary runs the handoff by hand. Sets
#     the marker, then wake() exits the cycle exactly as before.
#   - AUTO enabled: hand off automatically without a primary wake to START it.
#     Only an IDLE secondmate is handed off (invariant: never fire mid-turn); a
#     busy one is deferred to a later cycle WITHOUT setting the marker, so the
#     crossing re-evaluates next poll and once-only semantics hold (the marker is
#     set only when a handoff actually launches). The handoff itself
#     (bin/fm-secondmate-handoff.sh, driven by bin/fm-secondmate-auto-handoff.sh)
#     is launched DETACHED and never waited on, so its multi-minute steer+wait+
#     respawn cannot stall this slow-poll loop; the wrapper enqueues the required
#     after-the-fact primary FYI/escalation itself. The sweep sets the marker
#     BEFORE launching so an in-flight handoff is not re-launched next poll, then
#     keeps scanning (no wake, no cycle exit) - the FYI arrives via the queue.
#
# A per-window surfaced marker makes the crossing idempotent: an action fires
# once and re-arms only after the count drops back under the threshold (a fresh
# post-handoff agent). Runs only on the CHECK_INTERVAL cadence, never on every
# fast poll. Like the *.check.sh loop it lives in, wake() exits the cycle; a
# second crossed secondmate surfaces on a later cycle.
secondmate_context_sweep() {
  local threshold auto w meta home harness tokens key marker id reason
  local backend target tail40
  threshold=$(fm_sm_context_threshold "$CONFIG")
  auto=0; fm_sm_auto_handoff_enabled "$CONFIG" || auto=1
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    [ "$(window_kind "$w")" = secondmate ] || continue
    meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
    [ -n "$meta" ] || continue
    home=$(fm_meta_get "$meta" home); [ -n "$home" ] || home=$(fm_meta_get "$meta" worktree)
    [ -n "$home" ] || continue
    harness=$(fm_meta_get "$meta" harness); [ -n "$harness" ] || harness=$(fm_backend_of_meta "$meta")
    tokens=$(fm_sm_context_tokens "$home" "$harness" 2>/dev/null || true)
    key=$(fm_sm_context_marker_key "$w")
    marker="$STATE/.sm-context-surfaced-$key"
    if [ -n "$tokens" ] && [ "$tokens" -ge "$threshold" ]; then
      [ -e "$marker" ] && continue
      id=$(window_to_task "$w" "$STATE")
      if [ "$auto" = 0 ]; then
        # Never hand off a mid-turn agent: defer to a later cycle without marking
        # the crossing, so once-only semantics are preserved (the marker is set
        # only when a handoff actually launches). The handoff script re-checks
        # idle too, but deferring here avoids a launch that would just refuse.
        backend=$(fm_backend_of_meta "$meta")
        target=$(fm_backend_target_of_meta "$meta" || true)
        tail40=$(fm_backend_capture "$backend" "$target" 40 "fm-$id" 2>/dev/null || true)
        if window_is_busy "$w" "$tail40"; then
          continue
        fi
        : > "$marker"
        FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
          "$SCRIPT_DIR/fm-secondmate-auto-handoff.sh" "$id" >/dev/null 2>&1 &
        disown 2>/dev/null || true
        continue
      fi
      : > "$marker"
      reason="check: secondmate-context $id (context ${tokens} tokens >= threshold ${threshold})"
      fm_wake_append check "secondmate-context-$id" "$reason" || exit 1
      touch "$STATE/.last-check"
      wake "$reason"
    else
      rm -f "$marker"
    fi
  done <<EOF
$(recorded_windows)
EOF
}

# firstmate's OWN context stow-nudge sweep - the always-on twin of the away-mode
# daemon's context_stow_check (bin/fm-supervise-daemon.sh). Context fills during
# NORMAL supervision too, not just away mode, and the away-mode daemon owns the
# nudge only while it is running; without this the nudge never fires in the
# ordinary case. This is the interim enforcement while the structural turn-end
# backstop (enforce-stow-at-turnend-guard) stays blocked on an unbuilt jcode
# turn-end hook. It only NUDGES - it never runs /stow or /compact itself, because
# a stow needs firstmate's judgment about where each durable fact belongs and an
# auto-fired bare compact would summarize away un-stowed knowledge.
#
# When firstmate's own live context first crosses the stow threshold, wake once
# with a firstmate-facing "check: context-stow-nudge" carrying the shared
# self-executing directive: /stow now, then /compact, then re-arm supervision,
# before auto-compaction can discard un-stowed knowledge. The crossing/marker/
# hysteresis state machine and the directive text are both owned by
# fm-secondmate-context-lib.sh (fm_context_stow_should_nudge,
# fm_context_stow_directive) and shared byte-for-byte with the away-mode daemon's
# context_stow_check, through the SAME durable marker (state/.context-stow-nudged),
# so the two supervision paths never double-nudge or drift across a mode switch:
# the wake fires once per crossing and re-arms only after the count drops back
# below (threshold - hysteresis), which a fresh or compacted session does. Fails
# CLOSED: an unreadable, non-numeric, or unsupported-harness count leaves the
# marker untouched and wakes nobody, exactly like secondmate_context_sweep. Runs
# only on the CHECK_INTERVAL cadence, and never while a live away-mode daemon owns
# triage (the daemon's own check owns the nudge then, through its injection path).
# The harness is FM_SUPERVISOR_HARNESS when set (testing) else this process's own
# detected harness; the transcript cwd is FM_CONTEXT_STOW_CWD when set (testing)
# else FM_HOME - identical resolution to the daemon so both read the same count.
_own_stow_harness_memo=""
own_stow_harness() {
  if [ -z "$_own_stow_harness_memo" ]; then
    _own_stow_harness_memo=${FM_SUPERVISOR_HARNESS:-$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)}
    [ -n "$_own_stow_harness_memo" ] || _own_stow_harness_memo=unknown
  fi
  printf '%s' "$_own_stow_harness_memo"
}
context_stow_sweep() {
  local harness cwd threshold hysteresis tokens marker reason
  afk_daemon_owns_triage && return 0
  harness=$(own_stow_harness)
  cwd=${FM_CONTEXT_STOW_CWD:-${FM_HOME:-}}
  [ -n "$harness" ] && [ "$harness" != unknown ] || return 0
  [ -n "$cwd" ] || return 0
  tokens=$(fm_sm_context_tokens "$cwd" "$harness" 2>/dev/null || true)
  # Fail closed: never nudge on an unreadable or non-numeric count.
  case "$tokens" in ''|*[!0-9]*) return 0 ;; esac
  threshold=$(fm_context_stow_threshold "$CONFIG")
  hysteresis=${FM_CONTEXT_STOW_HYSTERESIS:-$FM_CONTEXT_STOW_HYSTERESIS_DEFAULT}
  case "$hysteresis" in ''|*[!0-9]*) hysteresis=$FM_CONTEXT_STOW_HYSTERESIS_DEFAULT ;; esac
  marker="$STATE/.context-stow-nudged"
  # Shared crossing/marker/hysteresis owner (fm-secondmate-context-lib.sh), the
  # SAME state machine the away-mode daemon's context_stow_check drives, so the
  # two paths can never fork. It returns 0 only on the first crossing per arming.
  if fm_context_stow_should_nudge "$tokens" "$threshold" "$hysteresis" "$marker"; then
    reason="check: context-stow-nudge $(fm_context_stow_directive "$tokens" "$threshold")"
    fm_wake_append check context-stow-nudge "$reason" || exit 1
    touch "$STATE/.last-check"
    wake "$reason"
  fi
  return 0
}

# The slow-poll HOST monitor, split into a probe CYCLE and a surface DECISION so
# the crew-liveness probe never runs on this loop. The probe (kernel-wide CPU,
# memory and swap plus a per-crew backend liveness read) is bounded by seconds,
# not milliseconds, so running it inline delayed every wake behind it. It now
# runs in its own short-lived process (bin/fm-resource-probe.sh) that this loop
# launches on the resource cadence and never waits on; the loop only READS the
# reading that process published. Both halves are monitor-and-report only:
# nothing here pauses, sheds or kills anything, because shedding load is the
# captain's decision.
#
# resource_probe_launch: on the RESOURCE_INTERVAL cadence (time-based via
# .last-resource so it survives watcher restarts), fire the probe in the
# background and return at once. It is NOT a second supervision cycle: the probe
# handles no wakes, enqueues nothing, and takes its own lock rather than the
# watcher singleton (see bin/fm-resource-probe.sh). Skip a launch while a probe
# is still running; the probe's own lock is the authoritative guard against a
# genuine overlap. That lock is HOST-GLOBAL (bin/fm-resource-probe.sh, resolved
# here via --lock-path), so this skip - and the probe's own deferral - now bound
# concurrent probes to one across every worktree and home on the host, not just
# within this worktree. This is the fix for the per-worktree-only guard that let
# N treehouse worktrees each launch a heavy sweep at once and OOM the host
# (data/20260823T031739Z-home-oom-fm-resource-probe-runaway).
RESOURCE_PROBE_LOCK=$("$SCRIPT_DIR/fm-resource-probe.sh" --lock-path 2>/dev/null | head -n 1)
resource_probe_running() {
  local pid
  [ -n "$RESOURCE_PROBE_LOCK" ] || return 1
  pid=$(cat "$RESOURCE_PROBE_LOCK/pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_pid_alive "$pid"
}
resource_probe_launch() {
  [ "$RESOURCE_INTERVAL" -gt 0 ] || return 0
  [ "$(age_of "$STATE/.last-resource")" -ge "$RESOURCE_INTERVAL" ] || return 0
  resource_probe_running && return 0
  # Stamp at launch so the cadence does not re-fire every poll while the probe
  # runs; the probe re-touches it on completion so the interval is measured from
  # when a reading was actually published.
  touch "$STATE/.last-resource"
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-resource-probe.sh" >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# resource_surface_check: the cheap main-loop half. Reads the timestamped reading
# the probe published (state/.resource-reading = "<epoch>\t<status>\t<reading>")
# and wakes firstmate when host pressure first gets WORSE than the level it was
# last told about, so a thrashing host is reported once instead of nagged every
# poll. FRESHNESS: the age comes from the record's own <epoch>, not a file mtime;
# a reading at least two sweep intervals old is stale and never surfaced, the same
# bound the heartbeat annotation and the .resource-live count use, so a probe that
# stopped publishing degrades to silence rather than to a confidently wrong wake.
# .resource-surfaced remembers the worst level already reported; recovery to
# healthy re-arms it SILENTLY (no wake). A missing, malformed, stale, or
# unknown/disabled reading surfaces nothing - the same
# never-wake-on-an-unreadable-probe rule as secondmate_context_sweep.
resource_surface_check() {
  local rec epoch rest status reading age last rank last_rank reason
  rec=$(cat "$STATE/.resource-reading" 2>/dev/null || true)
  [ -n "$rec" ] || return 0
  epoch=${rec%%$'\t'*}
  rest=${rec#*$'\t'}
  status=${rest%%$'\t'*}
  reading=${rest#*$'\t'}
  case "$epoch" in ''|*[!0-9]*) return 0 ;; esac
  age=$(( $(date +%s) - epoch ))
  [ "$age" -lt $(( RESOURCE_INTERVAL * 2 )) ] || return 0
  case "$status" in healthy|degraded|critical) : ;; *) return 0 ;; esac
  last=$(cat "$STATE/.resource-surfaced" 2>/dev/null || printf 'healthy')
  case "$status" in healthy) rank=0 ;; degraded) rank=1 ;; *) rank=2 ;; esac
  case "$last" in healthy) last_rank=0 ;; degraded) last_rank=1 ;; critical) last_rank=2 ;; *) last_rank=0 ;; esac
  if [ "$rank" -eq 0 ]; then
    [ "$last_rank" -eq 0 ] || triage_log "host resources recovered to healthy (re-armed, no wake)"
    printf '%s\n' healthy > "$STATE/.resource-surfaced"
    return 0
  fi
  if [ "$rank" -le "$last_rank" ]; then
    triage_log "absorbed host resources $status (already reported at $last)"
    return 0
  fi
  printf '%s\n' "$status" > "$STATE/.resource-surfaced"
  reason="check: host-resources $reading"
  fm_wake_append check host-resources "$reason" || exit 1
  wake "$reason"
}

# hourly_pass_sweep: run the session-lifetime hourly passes that
# bin/fm-session-start.sh armed - the session review and the cleanup sweep.
# They live here, on the one watcher, precisely so no second supervision cycle
# is needed: this loop is already the home's single scheduler, so an hourly duty
# becomes one more cadence-gated sweep rather than a competing timer.
#
# Each pass runs at most once per its own interval, time-based via its stamp
# mtime so the cadence survives watcher restarts, and the stamp is touched
# BEFORE the run so a slow or failing pass cannot re-fire every poll. Only
# repository-owned, non-symlinked bin/ scripts are executed, the same trust rule
# the X-mode poll shim uses. A pass that prints nothing is the normal case and
# wakes nobody; output means it has something the fleet has not been told about,
# so it is flattened onto one wake record. wake() ends the cycle, so a second
# due pass runs on a later poll.
hourly_pass_sweep() {
  local pass interval stamp script script_name out reason
  fm_hourly_is_armed "$STATE" || return 0
  for pass in $FM_HOURLY_PASSES; do
    interval=$(fm_hourly_interval "$pass") || continue
    [ "$interval" -gt 0 ] || continue
    stamp=$(fm_hourly_stamp "$STATE" "$pass")
    [ "$(age_of "$stamp")" -ge "$interval" ] || continue
    touch "$stamp"
    script_name=$(fm_hourly_pass_script "$pass") || continue
    [ -n "$script_name" ] || continue
    script="$SCRIPT_DIR/$script_name"
    [ -f "$script" ] && [ ! -L "$script" ] || continue
    FM_HOME="$FM_HOME" run_check_capture "$script" || exit 1
    out=$FM_CHECK_RESULT
    [ -n "$out" ] || continue
    reason="check: session-$pass $(printf '%s\n' "$out" \
      | awk 'NF {printf "%s%s", sep, $0; sep="; "}')"
    fm_wake_append check "session-$pass" "$reason" || exit 1
    wake "$reason"
  done
}

# Exit reporting a wake. Consecutive heartbeats with no other wake in between
# mean an idle fleet, so the heartbeat interval backs off exponentially
# (base * 2^streak, capped at HEARTBEAT_MAX); any real wake resets the cadence.
wake() {
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  echo "$1"
  exit 0
}

# Proof-of-life "tick" for a benign-ABSORBED wake. Default OFF: with
# FM_WATCH_ABSORB_TICK unset or any value other than 1 this is a no-op that RETURNS,
# so the caller keeps blocking exactly as before and behavior is byte-identical. When
# set to 1, a benign-absorbed wake instead ENDS the cycle with a distinguishable
# "tick: <note>" reason line and exit 0, so the arming session can tell a
# live-but-quiet watcher from a dead one at minimal token cost (the standing rule on a
# tick-enabled home is a single literal "tick" reply). A tick enqueues NO durable wake
# record, so bin/fm-wake-drain.sh, the continuity guard, and the turn-end guard see no
# actionable work; bin/fm-watch-arm.sh classifies the "tick:" line as a benign
# completion, distinct from an actionable wake (signal/stale/check/heartbeat) and from
# a failure (nonzero exit). Call ONLY from one-shot absorb points that have already
# advanced their suppression state (a benign signal whose .seen-* signature is
# written, an absorbed heartbeat whose schedule and backoff are advanced), never from
# a per-poll re-evaluation of an unchanged pane, so it fires at most once per
# absorbed-wake event and never storms on a static fleet. A tick also fires ONLY while
# work is under way: a signal presupposes a task, and the absorbed-heartbeat caller
# gates on the shared in-flight count. That is exactly the state in which the turn-end
# guard already forces a re-arm, so ending the cycle can never leave a home without
# supervision and no guard needs to know about this knob. With nothing under way the
# watcher keeps absorbing silently and self-sustains as it always has.
# This function itself never
# writes .heartbeat-streak and never enqueues anything, because a tick is not an
# actionable wake; the absorbed-heartbeat caller deliberately bumps the streak just
# before calling here, since that bump is what drives the heartbeat backoff.
FM_WATCH_ABSORB_TICK=${FM_WATCH_ABSORB_TICK:-0}
absorb_tick() {  # <note>
  [ "$FM_WATCH_ABSORB_TICK" = 1 ] || return 0
  echo "tick: $1"
  exit 0
}

# Consecutive wedge-escalation count for a window past FM_WEDGE_DEMAND_INSPECT_COUNT
# (default 3): a pane that keeps re-wedging on the SAME stale hash - each
# escalation gets absorbed again as "still validating" one poll later, since the
# hash never changes - can otherwise repeat forever with no signal that this is
# no longer a one-off. At the threshold, wedge_timer_check appends a
# "demand-deep-inspection" marker to the wake payload so the wake reason itself
# (not just repetition the supervisor has to notice on its own) forces a closer
# look instead of another routine supervision resume. Reset wherever a window's
# pane/hash state resets to genuinely active (see the two rm-on-reset call sites
# below).
FM_WEDGE_DEMAND_INSPECT_COUNT=${FM_WEDGE_DEMAND_INSPECT_COUNT:-3}

# Repeat-poll wedge-timer bookkeeping for an already-classified stale hash
# absorbed as provably-working - repairs a missing/corrupt timer (self-heals a
# watcher restart between recording the hash and recording the timer), or
# escalates once STALE_ESCALATE_SECS have elapsed. Never re-reads the crew
# state (the costly check already ran once, at classification time). Shared by
# both places a hash can be absorbed this way: the plain non-terminal path,
# and the stale_is_terminal-overridden path (a captain-relevant status-log
# line that an active run/busy pane outranked).
# When <nudgeable> is 1 (the plain non-terminal paths), the FIRST expiry of a
# stall episode sends nudge_stale_worker's one re-prompt instead of escalating;
# the timer restarts so the worker has one full grace window to reply, and the
# second expiry escalates because the recorded nudge already exists.
wedge_timer_check() {  # <window> <since-file> <triage-label> <escalation-count-file> [nudgeable]
  local win=$1 since_file=$2 label=$3 escalation_file=$4 nudgeable=${5:-0} since age n reason
  since=$(cat "$since_file" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*)
      date +%s > "$since_file"
      triage_log "absorbed $label timer reset: $win"
      ;;
    *)
      age=$(( $(date +%s) - since ))
      if [ "$age" -ge "$STALE_ESCALATE_SECS" ]; then
        if [ "$nudgeable" = 1 ] && nudge_stale_worker "$win"; then
          date +%s > "$since_file"
          triage_log "stale nudge sent (wedge): $win"
          return 0
        fi
        n=$(( $(cat "$escalation_file" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$escalation_file"
        reason="stale: $win (idle ${age}s, possible wedge, escalation $n)"
        if [ "$n" -ge "$FM_WEDGE_DEMAND_INSPECT_COUNT" ]; then
          reason="stale: $win (idle ${age}s, possible wedge, escalation $n, demand-deep-inspection: same pane has wedge-escalated $n times in a row - do not re-absorb on the run-step/pane state alone)"
        fi
        fm_wake_append stale "$win" "$reason" || exit 1
        rm -f "$since_file"
        wake "$reason"
      fi
      ;;
  esac
}

# Absorb a stale pane under a declared external-wait pause (paused:) or a
# dead-agent captain-held transfer, and re-surface it once every
# PAUSE_RESURFACE_SECS for a recheck so it cannot rot invisibly. Called on any
# stale poll once pause_state_class permits the bounded cadence, so it must be
# cheap: it NEVER re-reads crew state. The re-surface age is anchored on the
# status file mtime, not a per-hash marker, so a churny idle pane (a ticking
# clock, a token counter) cannot keep resetting the cadence the way a hash-tied
# timer would. A .paused-resurfaced-<key> throttle marker records the last
# re-surface epoch so, once past the window, it fires once per window rather than
# every poll. Advances the stale suppressor to <hash> and flags the key paused.
handle_paused_stale() {  # <window> <task> <hash>
  local win=$1 task=$2 h=$3 key statusf mtime age rf rf_age reason
  key=$(printf '%s' "$win" | tr ':/.' '___')
  printf '%s' "$h" > "$STATE/.stale-$key"
  : > "$STATE/.paused-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key" "$STATE/.stale-verdict-$key"
  statusf="$STATE/$task.status"
  mtime=$(stat_mtime "$statusf")
  case "$mtime" in ''|*[!0-9]*) mtime=$(date +%s) ;; esac
  age=$(( $(date +%s) - mtime ))
  rf="$STATE/.paused-resurfaced-$key"
  rf_age=$(age_of "$rf")   # 999999 when no prior re-surface
  if [ "$age" -ge "$PAUSE_RESURFACE_SECS" ] && [ "$rf_age" -ge "$PAUSE_RESURFACE_SECS" ]; then
    reason="stale: $win (paused ${age}s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)"
    fm_wake_append stale "$win" "$reason" || exit 1
    date +%s > "$rf"
    wake "$reason"
  fi
  triage_log "absorbed stale (paused, awaiting external, age ${age}s): $win"
}

clear_pause_state() {  # <window>
  local win=$1 key
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
}

clear_pause_tracking() {  # <window>
  local win=$1 key
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  clear_pause_state "$win"
  rm -f "$STATE/.stale-$key" "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key" "$STATE/.stale-verdict-$key" "$STATE/.stale-nudged-$key"
}

# --- account-switch orchestrator tripwire rotation ---------------------------
#
# On a live limit-error (tripwire) wake for a jcode/Claude worker, rotate the
# fleet's live jcode sessions onto the next non-exhausted Claude account by
# calling the account-switch orchestrator (quota-axi decide+switch, via
# bin/fm-account-orchestrator.sh). firstmate is a CALLER only: the orchestrator's
# `switch` verb re-runs decide, actuates the jcode live-session surface itself,
# and records the durable tripwire so the exhausted account stays out. This
# happens WITHOUT captain intervention, in addition to (never instead of) the
# ordinary captain-relevant surfacing of the blocking status.
#
# A per-window idempotence marker (.orch-rotated-<key>) makes the rotation fire
# once per recovery window, so a burst of limit errors on the same worker does
# not thrash the fleet with repeated switches. It is cleared after
# FM_ORCH_ROTATE_COOLDOWN seconds (default one hour, matching the pause
# re-surface cadence) so a later exhaustion rotates again. FAIL-SOFT throughout:
# an unavailable/old/erroring orchestrator logs and returns without blocking
# supervision - the manual bin/fm-switch-account.sh broadcast remains the fallback.
FM_ORCH_ROTATE_COOLDOWN=${FM_ORCH_ROTATE_COOLDOWN:-3600}

# 0 when this status line reports a live Claude account-exhaustion (tripwire)
# limit error. Reuses the shared status classifier's auth-exhaustion test (the
# worker's own self-report vocabulary) OR the orchestrator's raw-provider-error
# recognizer, so either phrasing trips a rotation. Cheap pure read of the line.
status_is_tripwire() {  # <status-line>
  local line=$1
  [ -n "$line" ] || return 1
  status_is_auth_exhaustion_pause "$line" && return 0
  "$SCRIPT_DIR/fm-account-orchestrator.sh" recognize-tripwire "$line" 2>/dev/null
}

# Rotate accounts for a tripped jcode/Claude worker. Idempotent per task within
# the cooldown window. Never fatal: every failure fails soft. On a successful
# rotation, stamp the post-rotation Claude account onto the task's
# state/<id>.telemetry (gap-1: account=/account_source=switch) from switch's own
# SwitchResponse, so the pane's telemetry follows a live account switch.
orchestrator_rotate_on_tripwire() {  # <task>
  local task=$1 meta harness key marker age out chosen
  meta="$STATE/$task.meta"
  [ -f "$meta" ] || return 0
  harness=$(fm_meta_get "$meta" harness); [ -n "$harness" ] || harness=$(fm_backend_of_meta "$meta")
  # Phase 1 scope: only a jcode worker rotates through this path.
  [ "$harness" = jcode ] || return 0
  # Only when the orchestrator actually exposes the merged verbs; otherwise the
  # manual fallback owns the switch and this stays inert.
  "$SCRIPT_DIR/fm-account-orchestrator.sh" supports >/dev/null 2>&1 || return 0

  key=$(printf '%s' "$task" | tr ':/.' '___')
  marker="$STATE/.orch-rotated-$key"
  if [ -e "$marker" ]; then
    age=$(age_of "$marker")
    [ "$age" -lt "$FM_ORCH_ROTATE_COOLDOWN" ] && return 0
    rm -f "$marker"
  fi
  : > "$marker"
  if out=$("$SCRIPT_DIR/fm-account-orchestrator.sh" rotate 2>/dev/null); then
    triage_log "orchestrator rotated accounts on tripwire for $task"
    # switch's SwitchResponse names the account the fleet rotated onto
    # (outcomes[0].chosenAccount); stamp it so the pane's telemetry stays
    # current. A keep/absent/parse failure stamps nothing - FAIL-SOFT.
    if command -v jq >/dev/null 2>&1 && [ -n "$out" ]; then
      chosen=$(printf '%s' "$out" | jq -r '.outcomes[0].chosenAccount // ""' 2>/dev/null || true)
      if [ -n "$chosen" ]; then
        fm_telemetry_stamp_account "$STATE/$task.telemetry" "$chosen" switch || true
      fi
    fi
  else
    triage_log "orchestrator rotation failed on tripwire for $task; manual fallback available"
  fi
  return 0
}

# Visibility Gap-2: how many rolling 429/limit-error occurrences on one pane
# cross from a self-healing transient into a real anomaly worth a proactive wake.
# A small threshold: a single overloaded-429 self-heals (telemetry only), a rate
# is real exhaustion. Overridable for tests; the captain rarely tunes it.
FM_QUOTA_ANOMALY_RATE=${FM_QUOTA_ANOMALY_RATE:-3}

# Resolve the SHARED tripwire regex from its single owner, once, so the hot-path
# 429 scan reuses the exact catalog bin/fm-account-orchestrator.sh owns
# (FM_ORCH_TRIPWIRE_RE_DEFAULT) instead of forking a second copy that would drift.
# We read the owner's own assignment line rather than restating the pattern here.
# Fail-soft: if the owner cannot be read, FM_WATCH_TRIPWIRE_RE stays empty and the
# scan below is inert (never a wrong wake). Runs at load so it is cached for the
# process lifetime, the same way every other watcher constant is fixed once.
if [ -z "${FM_WATCH_TRIPWIRE_RE:-}" ]; then
  _fm_orch_tw_line=$(grep -m1 '^FM_ORCH_TRIPWIRE_RE_DEFAULT=' \
    "$SCRIPT_DIR/fm-account-orchestrator.sh" 2>/dev/null || true)
  if [ -n "$_fm_orch_tw_line" ]; then
    # shellcheck disable=SC2034  # FM_ORCH_TRIPWIRE_RE_DEFAULT is read on the next line.
    eval "$_fm_orch_tw_line" && FM_WATCH_TRIPWIRE_RE=$FM_ORCH_TRIPWIRE_RE_DEFAULT
  fi
  unset _fm_orch_tw_line
fi

# quota_anomaly_scan: Visibility Gap-2 - detect a per-pane 429/rate-limit anomaly
# from the 40-line pane tail the stale loop ALREADY captured, on FIRST occurrence,
# before the worker surfaces its own blocked/paused status. ZERO extra backend
# calls (it scans text already in hand) and no per-pane subprocess: one grep over
# tail plus a shell int compare on the supervision hot path.
#
# On a tripwire match not already counted for this pane tail, bump count_429 and
# set last_429_ts in state/<task>.telemetry (deduped by the tail hash the stale
# loop already computes, so a 429 that sits in an idle tail counts once per burst,
# not once per poll - the same idempotence shape as .orch-rotated-<key>). Severity
# split: a single first 429 is telemetry-only, NO wake (a lone overloaded-429
# self-heals); only a RATE past FM_QUOTA_ANOMALY_RATE emits a proactive
# `check: quota-anomaly <task> <account> <count>` wake, idempotent per rotation
# cooldown window so a storm wakes firstmate once, not every poll. Fail-soft: an
# unresolved regex, an absent task, or a telemetry-write failure surfaces nothing.
quota_anomaly_scan() {  # <window> <task> <tail40> <hash>
  local w=$1 task=$2 tail=$3 h=$4 key seenf tel count marker age account reason
  [ -n "$task" ] || return 0
  [ -n "${FM_WATCH_TRIPWIRE_RE:-}" ] || return 0
  printf '%s' "$tail" | grep -qiE "$FM_WATCH_TRIPWIRE_RE" || return 0
  key=$(printf '%s' "$w" | tr ':/.' '___')
  seenf="$STATE/.quota-429-seen-$key"
  # One burst = one count: the same 429 line persists in an idle tail across
  # polls, so count only when this tail hash is new (mirrors the stale loop's own
  # per-hash dedup). A later, changed tail carrying a fresh 429 counts again.
  [ "$(cat "$seenf" 2>/dev/null || true)" = "$h" ] && return 0
  printf '%s' "$h" > "$seenf"
  tel="$STATE/$task.telemetry"
  count=$(fm_meta_get "$tel" count_429)
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  count=$((count + 1))
  fm_telemetry_set "$tel" count_429 "$count" || return 0
  fm_telemetry_set "$tel" last_429_ts "$(date +%s)" || return 0
  # Telemetry-only until the rate crosses the threshold.
  [ "$count" -ge "$FM_QUOTA_ANOMALY_RATE" ] || return 0
  # One wake per cooldown window, reusing the rotation cooldown so a storm does
  # not nag every poll (the same window rotation itself is idempotent over).
  marker="$STATE/.quota-anomaly-$key"
  if [ -e "$marker" ]; then
    age=$(age_of "$marker")
    [ "$age" -lt "$FM_ORCH_ROTATE_COOLDOWN" ] && return 0
    rm -f "$marker"
  fi
  : > "$marker"
  account=$(fm_meta_get "$tel" account); [ -n "$account" ] || account=unknown
  reason="check: quota-anomaly $task $account $count"
  fm_wake_append check "quota-anomaly-$key" "$reason" || exit 1
  wake "$reason"
}

# Visibility Gap-4: detect a delivered-but-never-processed steer (a silent
# composer-stuck) from the same values the stale loop ALREADY has in hand
# (tail40, hash, prev) - zero extra backend captures, and the busy probe is
# gated so it only runs while a steer is actually fresh (design:
# data/design-visibility-improvements/report.md "Gap 4"). fm-send stamps
# last_steer_ts= in state/<id>.telemetry on every CONFIRMED text delivery.
#
# A steer is STUCK when, within FM_STEER_STUCK_WINDOW of its delivery, the pane
# hash has NOT advanced since the steer and the pane is not busy: the text left
# the composer but the harness never started the turn. Detection compares the
# current hash against a BASELINE hash captured at first observation of the
# fresh steer (the recorded prev hash - the pane's pre-steer state - in
# practice), never the rolling .hash-<key> value. The baseline is what prevents
# a false alarm on a steer the pane DID install: it went busy, produced output,
# and idled again - that hash differs from the baseline - while a genuinely
# stuck pane stays on the unchanged baseline. The baseline is persisted in a
# small .steer-baseline-<key> watcher state file (the .stale-<key> family) so a
# re-arm inside the freshness window cannot rebaseline onto a post-steer pane
# state.
#
# On stuck: set composer_stuck=1 in telemetry and emit a steer-aware variant of
# the EXISTING stale wake (fm_wake_append stale ... + wake), once per steer via
# a .steer-stuck-<key> marker holding the last_steer_ts warned for. On a busy
# pane or a hash advance: clear composer_stuck=0. On the window expiring: drop
# the flag and both tracking files, so a long-idle healthy pane never trips it.
# A declared pause / captain-hold stays on its existing absorb path and is never
# alarmed. FAIL-SOFT: an absent/unreadable telemetry or a write failure
# surfaces nothing and never blocks the loop.
FM_STEER_STUCK_WINDOW=${FM_STEER_STUCK_WINDOW:-600}

steer_stuck_check() {  # <window> <task> <tail40> <hash> <prev-hash>
  local w=$1 task=$2 tail=$3 h=$4 prev=$5
  local tel ts now age key base_file marker baseline_ts baseline_hash reason
  [ -n "$task" ] || return 0
  tel="$STATE/$task.telemetry"
  ts=$(fm_meta_get "$tel" last_steer_ts)
  case "$ts" in
    ''|*[!0-9]*) return 0 ;;  # no recorded steer: an idle pane with no steer stays quiet
  esac
  now=$(date +%s)
  age=$(( now - ts ))
  key=$(printf '%s' "$w" | tr ':/.' '___')
  base_file="$STATE/.steer-baseline-$key"
  marker="$STATE/.steer-stuck-$key"
  if [ "$age" -gt "$FM_STEER_STUCK_WINDOW" ]; then
    # Steer aged out of the fresh window: no longer an active concern. Drop the
    # flag and the tracking files so a long-idle healthy pane never trips it.
    rm -f "$base_file" "$marker"
    if [ "$(fm_meta_get "$tel" composer_stuck)" = 1 ]; then
      fm_telemetry_set "$tel" composer_stuck 0 || true
    fi
    return 0
  fi
  # A declared pause / captain-hold is a legitimate wait the existing pause
  # absorb path owns; never raise the stuck alarm for it.
  if status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")"; then
    return 0
  fi
  # Arm (or re-arm on a new steer's ts) the baseline: the pane hash this steer
  # was delivered against. In practice the recorded prev hash - the pane's
  # state before this steer - falls back to the current hash on a fresh
  # window's first poll.
  baseline_ts=
  baseline_hash=
  if [ -f "$base_file" ]; then
    IFS=' ' read -r baseline_ts baseline_hash < "$base_file" || true
  fi
  if [ "$baseline_ts" != "$ts" ]; then
    baseline_ts=$ts
    baseline_hash=$prev
    [ -n "$baseline_hash" ] || baseline_hash=$h
    printf '%s %s\n' "$baseline_ts" "$baseline_hash" > "$base_file" || return 0
  fi
  [ -n "$baseline_hash" ] || return 0
  # Stuck iff the pane hash has NOT advanced since the baseline AND the pane is
  # not busy. The busy probe runs only on the not-advanced path, so it costs
  # nothing on a pane that processed the steer (or has no fresh steer at all).
  if [ "$h" = "$baseline_hash" ] && ! window_is_busy "$w" "$tail"; then
    fm_telemetry_set "$tel" composer_stuck 1 || true
    if [ "$(cat "$marker" 2>/dev/null || true)" != "$ts" ]; then
      printf '%s' "$ts" > "$marker" 2>/dev/null || true
      reason="stale: $w (steer delivered ${age}s ago, pane never processed it - possible stuck composer)"
      fm_wake_append stale "$w" "$reason" || exit 1
      wake "$reason"
    fi
  elif [ "$(fm_meta_get "$tel" composer_stuck)" = 1 ]; then
    fm_telemetry_set "$tel" composer_stuck 0 || true
  fi
  return 0
}

# The ANIMATED FOOTER-ROW catalog for pane_content_hash below. Every verified
# harness renders its busy indicator in the BOTTOM rows of the pane - the
# spinner row, the elapsed-timer row, and the right-aligned composer /
# indicator row (the same footer area the BUSY_REGEX scan scopes to: the last
# 6 non-blank lines). jcode's frozen footer draws exactly these shapes
# (`⠋ thinking… 15m 2s · https` and `6… ⏳`, supervision-miss-rootcause
# evidence). Overridable; the comma-free alternation is one grep -E catalog.
FM_WATCH_FOOTER_ROW_RE=${FM_WATCH_FOOTER_ROW_RE:-'⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏|[0-9]+m [0-9]+s|⏳|^[0-9]+…|·●·'}

# pane_content_hash (F1 seam, supervision-miss-rootcause): hash the tail40
# MINUS the animated footer rows. A dead jcode lane after a 429 rotation keeps
# redrawing its footer (spinner chars, a growing elapsed timer, the busy
# "NNN…" composer) while its CONTENT rows stay byte-identical, so the raw tail
# hash never stabilizes and every downstream stale/hash classifier never sees
# the freeze (`.count-<key>` stayed 0 on the incident lanes for 10 hours).
# Stripping only TRAILING rows that match the footer catalog leaves content
# rows untouched; content change then moves the hash exactly when it should.
# A pane smaller than its footer hashes to a stable empty content, which is
# the correct shape for the dead-turn check: an idle pane with no content is
# exactly the dead-turn condition when a fresh 429 and no status append
# accompany it. Zero backend calls: consumes the tail40 the loop already
# captured.
pane_content_hash() {  # <tail40>
  printf '%s' "$1" | grep -v '^[[:space:]]*$' | awk -v re="$FM_WATCH_FOOTER_ROW_RE" '
    { rows[NR] = $0 }
    END {
      n = NR
      while (n > 0 && rows[n] ~ re) n--
      for (i = 1; i <= n; i++) print rows[i]
    }' | hash_pane
}

# Visibility Gap-5: the dead-turn liveness tripwire. A lane that reactively
# rotated accounts on a 429 (rate limit) can have its in-flight turn die during
# or after the rotation, with the harness never starting a new turn. The pane
# stays present and may keep REDRAWING (a live-looking hash) while its content
# rows are frozen, so the stale loop never fires, and telemetry already
# carries the 429 cue (last_429_ts, written by quota_anomaly_scan above -
# Gap-2). The dead-turn signal is CONTENT-STALL (pane_content_hash unchanged
# across polls) or a conclusive jcode terminal-dead marker, both with NO status
# append after the 429. HARD-WON FACT (supervision-miss-rootcause F4): busy is
# a LYING liveness signal on a dead jcode pane - herdr reports
# agent_status=working forever, the frozen "NNN…" composer matches BUSY_REGEX,
# and the footer animates - so this check NEVER consults window_is_busy for
# probe, escalate, or recovery. Full state machine, axis review, and
# verification: docs/design-visibility-improvements.md "Gap 5".
#
# Two-poll state machine (never a probe loop), driven by the same per-window
# values this loop already holds (tail40 only; zero extra backend capture):
#   1. Each in-window poll observes the pane's content hash (footer stripped).
#      A poll whose content hash MATCHES the previous poll's hash is a
#      content-stall; the first poll of an observation baseline never probes.
#   2. First qualifying poll - recent last_429_ts + CONTENT-STALL (or a jcode
#      dead marker: "Auto-retry limit reached" / "Already processing a
#      message", owned by bin/fm-composer-lib.sh) + NO status append since
#      last_429_ts + not paused/captain-held + episode not already spent -
#      sends exactly ONE bounded automatic resume steer via fm-send (the seam
#      FM_DEAD_TURN_SEND_BIN, default this repo's fm-send.sh, mirrors
#      FM_STALE_NUDGE_BIN; tests stub it), records resume_probe_ts= in
#      telemetry, and persists the episode in state/.dead-turn-probe-<key>
#      (holding the last_429_ts probed for, so one 429 burst = one probe).
#   3. Next poll - STILL content-stalled (or dead marker) AND STILL no status
#      append since the 429 - escalates ONCE as `check: dead-turn <task>` via
#      state/.dead-turn-escalated-<key> (same wake pattern as
#      quota_anomaly_scan). A later fresh last_429_ts is a NEW episode and may
#      probe once again.
#   4. Recovery - a status append after the 429, or ADVANCING content (the
#      content hash differs from the previous poll - the lane produced a new
#      row, which is liveness even when the app still draws a busy footer) -
#      clears the episode's ACTIVE markers and records it as spent in
#      state/.dead-turn-resolved-<key>, so a later idle poll inside the same
#      window stays SILENT. A recovered episode re-arms only on a genuinely
#      new last_429_ts. Busy-ness NEVER resolves an episode: the incident
#      lanes read busy forever while dead (herdr native state + BUSY_REGEX).
#   5. Window expiry drops the tracking files - no wake, no probe. Same marker
#      lifecycle as steer_stuck_check, whose pause/expiry ordering is mirrored
#      exactly.
# A send that cannot be confirmed records the episode's single probe anyway and
# escalates immediately: a failing sender must never swallow a stalled worker
# (the same rule the stale nudge follows), and a failure does not retry into a
# probe loop. Gap-4 coordination: the probe steer stamps last_steer_ts in
# telemetry, so the probe's own steer ts is pre-recorded in Gap-4's
# .steer-stuck-<key> warned-marker, keeping the dead-turn wake the single
# escalation for that steer (fail-soft: an unreadable stamp skips the
# suppression and Gap-4 may also wake - a duplicate, never a missed lane).
# FAIL-SOFT throughout: absent/unreadable telemetry, a missing meta, or a
# marker/telemetry write failure surfaces nothing and never blocks the loop.
# Never probes a secondmate (its own home supervises its lanes, and a marked
# main-home steer would open a parent pending-reply expectation) or an
# --unsupervised pane (supervise=off; recorded_windows already drops those,
# this guard keeps the contract single-place).
#
# The recency window: ONE episode is probed only while last_429_ts is fresh
# enough that the dead turn is plausibly the 429's aftermath. Default 900s:
# > 2x the default poll cadence (POLL 300s) so a probe and its follow-up
# escalation both land inside it, ~1.5x the slow-check cadence (CHECK_INTERVAL
# 600s), and the same order as FM_STEER_STUCK_WINDOW (600s), the sibling
# fresh-concern window. An old 429 (hours) on a long-idle healthy pane is
# outside it and never trips. Overridable for tests and tuning.
FM_DEAD_TURN_WINDOW=${FM_DEAD_TURN_WINDOW:-900}
# The resume-steer seam. Default is this repo's fm-send.sh, used exactly as any
# steer (target = task id; never force, never restarts the harness, never
# touches another lane); tests stub it.
FM_DEAD_TURN_SEND_BIN=${FM_DEAD_TURN_SEND_BIN:-"$SCRIPT_DIR/fm-send.sh"}

dead_turn_check() {  # <window> <task> <tail40>
  local w=$1 task=$2 tail=$3
  local meta tel ts now age key probe_marker escalated_marker resolved_marker content_file
  local status_m cur prev stalled out probe_ts probe_age reason last_steer dead_desc
  [ -n "$task" ] || return 0
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  [ -n "$meta" ] || return 0
  [ "$(grep '^kind=' "$meta" | cut -d= -f2- || true)" = secondmate ] && return 0
  [ "$(grep '^supervise=' "$meta" | cut -d= -f2- || true)" = off ] && return 0
  tel="$STATE/$task.telemetry"
  ts=$(fm_meta_get "$tel" last_429_ts)
  case "$ts" in
    ''|*[!0-9]*) return 0 ;;  # no recorded 429: an idle pane with no 429 stays quiet
  esac
  now=$(date +%s)
  age=$(( now - ts ))
  key=$(printf '%s' "$w" | tr ':/.' '___')
  probe_marker="$STATE/.dead-turn-probe-$key"
  escalated_marker="$STATE/.dead-turn-escalated-$key"
  resolved_marker="$STATE/.dead-turn-resolved-$key"
  content_file="$STATE/.dead-turn-content-$key"
  if [ "$age" -gt "$FM_DEAD_TURN_WINDOW" ]; then
    # The 429 aged out of the episode window: not an active concern. Drop the
    # tracking files so a long-idle healthy pane with an OLD 429 never trips,
    # and a later fresh last_429_ts starts a new episode.
    rm -f "$probe_marker" "$escalated_marker" "$resolved_marker" "$content_file"
    return 0
  fi
  # A declared pause / captain-hold is a legitimate wait; never probed, never
  # alarmed. Markers are left in place so a bounded pause does not consume the
  # episode's single probe.
  if status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")"; then
    return 0
  fi
  # Content-stall observation (F1): hash THIS poll's captured tail40 without
  # the animated footer rows and compare against the previous poll's hash,
  # persisted in the .dead-turn-content-<key> observation file. A dead jcode
  # lane after a rotation redraws its footer (spinner, growing timer, busy
  # composer) while the CONTENT rows stay byte-identical, so the content hash
  # stalls even though the raw tail hash keeps churning and every busy
  # predicate keeps lying `busy`. Busy-ness is deliberately NOT a liveness
  # signal here (supervision-miss-rootcause F4); it is never consulted.
  cur=$(pane_content_hash "$tail")
  prev=$(cat "$content_file" 2>/dev/null || true)
  printf '%s' "$cur" > "$content_file" 2>/dev/null || true
  stalled=0
  [ -n "$prev" ] && [ "$prev" = "$cur" ] && stalled=1
  # Recovery: a status append after the 429, or ADVANCING content (the
  # non-footer rows changed since the last poll), means the lane is alive
  # again. Clear the episode's ACTIVE markers and record the episode as SPENT
  # so a later idle poll inside this window stays silent (the lane is healthy,
  # not a new dead turn); only a genuinely new last_429_ts re-arms. A busy
  # pane NEVER resolves an episode: the incident lanes read busy forever
  # while dead.
  status_m=$(stat_mtime "$STATE/$task.status")
  if { [ -n "$status_m" ] && [ "$status_m" -gt "$ts" ]; } \
    || { [ -n "$prev" ] && [ "$prev" != "$cur" ]; }; then
    rm -f "$probe_marker" "$escalated_marker"
    printf '%s' "$ts" > "$resolved_marker" 2>/dev/null || true
    return 0
  fi
  # A spent episode stays silent until a NEW 429 (a fresh last_429_ts).
  [ "$(cat "$resolved_marker" 2>/dev/null || true)" = "$ts" ] && return 0
  # Dead-turn predicate: content-stalled across two polls, OR a conclusive
  # jcode terminal-dead marker in the tail (auto-retry-limit-reached, or the
  # swallowed-steer rejection row; catalog owned by bin/fm-composer-lib.sh).
  # Everything else - native busy state, BUSY_REGEX hits, raw-hash churn - is
  # ignored for the probe/escalate decision.
  if [ "$stalled" = 1 ] || fm_composer_tail_has_jcode_dead_marker "$tail"; then
    if [ "$(cat "$probe_marker" 2>/dev/null || true)" = "$ts" ]; then
      # Probe already recorded for THIS episode: the only next actions are
      # recovery (handled above) or the single escalation wake. Never a second
      # probe - the escalation poll is where a still-dead lane surfaces.
      [ "$(cat "$escalated_marker" 2>/dev/null || true)" = "$ts" ] && return 0
      printf '%s' "$ts" > "$escalated_marker" 2>/dev/null || return 0
      probe_ts=$(fm_meta_get "$tel" resume_probe_ts)
      case "$probe_ts" in
        ''|*[!0-9]*) probe_age= ;;
        *) probe_age=$(( now - probe_ts )) ;;
      esac
      if fm_composer_tail_has_jcode_dead_marker "$tail"; then
        dead_desc="jcode dead marker since the 429"
      elif [ "$stalled" = 1 ]; then
        dead_desc="content frozen since the 429"
      else
        dead_desc="dead turn since the 429"
      fi
      if [ -n "$probe_age" ]; then
        reason="check: dead-turn $task (429 ${age}s ago, resume steer sent ${probe_age}s ago, ${dead_desc}, no status append since 429)"
      else
        reason="check: dead-turn $task (429 ${age}s ago, resume steer not processed, ${dead_desc}, no status append since 429)"
      fi
      fm_wake_append check "dead-turn-$key" "$reason" || exit 1
      wake "$reason"
    fi
    # First qualifying poll of the episode: exactly ONE bounded resume steer.
    # The text is short, single-line, and steer-safe (plain text, no slash
    # command, no skill invocation) so every verified harness treats it as an
    # ordinary turn nudge.
    if ! out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
        "$FM_DEAD_TURN_SEND_BIN" "$task" \
        "Auto-nudge: your turn ended after a rate-limit (429) account rotation. Resume your turn; append a working: status line once you are back." 2>&1); then
      # A send that cannot be confirmed records the episode's single probe and
      # escalates NOW rather than retrying into a probe loop or swallowing the
      # stalled lane.
      printf '%s' "$ts" > "$probe_marker" 2>/dev/null || true
      printf '%s' "$ts" > "$escalated_marker" 2>/dev/null || true
      triage_log "dead-turn resume steer send failed for $w: $(printf '%s' "$out" | tail -n 1)"
      reason="check: dead-turn $task (429 ${age}s ago, resume steer delivery FAILED, content frozen since the 429, no status append since 429)"
      fm_wake_append check "dead-turn-$key" "$reason" || exit 1
      wake "$reason"
    fi
    printf '%s' "$ts" > "$probe_marker" 2>/dev/null || true
    fm_telemetry_set "$tel" resume_probe_ts "$(date +%s)" || true
    # Gap-4 coordination: our probe steer stamps last_steer_ts (fm-send does
    # on confirmed delivery), and steer_stuck_check would otherwise escalate
    # the SAME steer as a stuck composer on the next poll, without the 429
    # context. Pre-record the probe's steer ts in Gap-4's .steer-stuck-<key>
    # warned-marker so the dead-turn wake is the single escalation for that
    # steer.
    last_steer=$(fm_meta_get "$tel" last_steer_ts)
    case "$last_steer" in
      ''|*[!0-9]*) ;;
      *) printf '%s' "$last_steer" > "$STATE/.steer-stuck-$key" 2>/dev/null || true ;;
    esac
  fi
  return 0
}

# retry_loop_check: the worker retry-loop tripwire. A worker stuck in a retry
# loop keeps writing the SAME status body over and over (an identical failing
# command, an identical error line, an identical "working: retrying X" note),
# burning tokens without making progress and never appending a `blocked:` line
# that would surface it. The stale loop does NOT catch this: the pane keeps
# CHANGING (each retry redraws output) and the status file keeps being APPENDED
# (so its size:mtime signature advances and the signal path treats each append
# as fresh chatter), so nothing wedges and nothing surfaces.
#
# DETECTION - "identical status append 3+ times" - is defined precisely as: the
# task status file's last FM_RETRY_LOOP_MIN (default 3) non-blank lines are all
# BYTE-IDENTICAL to each other (exact string match on the whole status line,
# verb and note together). A worker appending the same failing-command line, or
# the same error, or the same retry note, three times in a row satisfies this;
# any variation in the body (a different command, a changed error, an advancing
# note, a real progress line between retries) breaks the run and never trips.
# The exact-match-on-the-status-body rule is what makes "identical" objective:
# a worker whose retries carry the same command signature writes that command
# into its status line, so the status body IS the command signature we compare.
#
# STATE MACHINE (mirrors dead_turn_check's marker lifecycle, one auto-steer per
# distinct loop episode, then one escalation if it continues):
#   1. Not looping (fewer than FM_RETRY_LOOP_MIN trailing identical lines): clear
#      this key's tracking so a later genuine loop starts a fresh episode.
#   2. First poll that sees a qualifying run whose identical body differs from
#      the last episode's recorded body: send exactly ONE auto-steer via fm-send
#      (`stop retrying, append blocked: with the exact blocker and wait`) and
#      record the body's hash in state/.retry-loop-<key> so the SAME loop never
#      re-steers. No wake - the steer is the first, quiet intervention.
#   3. A later poll still showing the SAME looping body (the worker ignored the
#      steer and kept retrying past the grace window) escalates ONCE as
#      `check: retry-loop <task>` via state/.retry-loop-escalated-<key>, then
#      stays silent for that episode. A worker that changes its body (including
#      finally writing the asked-for `blocked:` line) is a NEW body: the run
#      breaks, the episode clears, and a different loop later may steer once
#      again.
# NEVER steers a secondmate (its own home supervises its lanes, and a marked
# main-home steer would open a parent pending-reply expectation) or an
# --unsupervised pane (supervise=off), the same exclusions nudge_stale_worker
# and dead_turn_check enforce. A send that cannot be confirmed records the
# episode's single steer anyway and escalates immediately, so a failing sender
# never swallows a looping worker. FAIL-SOFT throughout: a missing meta,
# missing status file, or a marker write failure surfaces nothing and never
# blocks the loop. FM_RETRY_LOOP_SEND_BIN is the send seam (default this repo's
# fm-send.sh); tests stub it.
FM_RETRY_LOOP_MIN=${FM_RETRY_LOOP_MIN:-3}
FM_RETRY_LOOP_SEND_BIN=${FM_RETRY_LOOP_SEND_BIN:-"$SCRIPT_DIR/fm-send.sh"}

# retry_loop_trailing_body: prints the status body repeated by the last
# FM_RETRY_LOOP_MIN non-blank lines of <status-file> when they are ALL identical,
# and prints nothing otherwise. Pure read; the objective "identical" predicate.
retry_loop_trailing_body() {  # <status-file>
  local f=$1 lines first n
  [ -e "$f" ] || return 0
  lines=$(grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -n "$FM_RETRY_LOOP_MIN")
  n=$(printf '%s\n' "$lines" | grep -c .)
  [ "$n" -ge "$FM_RETRY_LOOP_MIN" ] || return 0
  first=$(printf '%s\n' "$lines" | head -n 1)
  [ -n "$first" ] || return 0
  # Every one of the trailing lines must equal the first: uniq -c collapsing to a
  # single group proves all identical.
  [ "$(printf '%s\n' "$lines" | sort -u | grep -c .)" = 1 ] || return 0
  printf '%s' "$first"
}

retry_loop_check() {  # <window> <task>
  local w=$1 task=$2 meta body key steer_marker esc_marker sig prev out reason
  [ -n "$task" ] || return 0
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  [ -n "$meta" ] || return 0
  [ "$(grep '^kind=' "$meta" | cut -d= -f2- || true)" = secondmate ] && return 0
  [ "$(grep '^supervise=' "$meta" | cut -d= -f2- || true)" = off ] && return 0
  key=$(printf '%s' "$w" | tr ':/.' '___')
  steer_marker="$STATE/.retry-loop-$key"
  esc_marker="$STATE/.retry-loop-escalated-$key"
  body=$(retry_loop_trailing_body "$STATE/$task.status")
  if [ -z "$body" ]; then
    # Not looping: the run broke (a changed body, a real progress line). Clear
    # the episode so a genuinely new loop later starts fresh and may steer once.
    rm -f "$steer_marker" "$esc_marker"
    return 0
  fi
  sig=$(printf '%s' "$body" | hash_pane)
  prev=$(cat "$steer_marker" 2>/dev/null || true)
  if [ "$prev" = "$sig" ]; then
    # Same loop already steered. Escalate ONCE if it is still going past the
    # grace window, then stay silent for this episode.
    [ "$(cat "$esc_marker" 2>/dev/null || true)" = "$sig" ] && return 0
    printf '%s' "$sig" > "$esc_marker" 2>/dev/null || return 0
    reason="check: retry-loop $task (same status appended ${FM_RETRY_LOOP_MIN}+ times, still looping after the stop-retrying steer)"
    fm_wake_append check "retry-loop-$key" "$reason" || exit 1
    wake "$reason"
  fi
  # First qualifying poll of a NEW loop body: exactly ONE auto-steer. The text is
  # short, single-line, and steer-safe (plain text, no slash command) so every
  # verified harness treats it as an ordinary turn nudge.
  if ! out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$FM_RETRY_LOOP_SEND_BIN" "$task" \
      "stop retrying, append blocked: with the exact blocker and wait" 2>&1); then
    # A send that cannot be confirmed records the episode's single steer and
    # escalates NOW rather than retrying into a steer loop or swallowing the
    # looping worker.
    printf '%s' "$sig" > "$steer_marker" 2>/dev/null || true
    printf '%s' "$sig" > "$esc_marker" 2>/dev/null || true
    triage_log "retry-loop steer send failed for $w: $(printf '%s' "$out" | tail -n 1)"
    reason="check: retry-loop $task (same status appended ${FM_RETRY_LOOP_MIN}+ times, stop-retrying steer delivery FAILED)"
    fm_wake_append check "retry-loop-$key" "$reason" || exit 1
    wake "$reason"
  fi
  printf '%s' "$sig" > "$steer_marker" 2>/dev/null || true
  rm -f "$esc_marker"
  triage_log "retry-loop steer sent for $w (body hash $sig)"
  return 0
}

# Visibility Gap-1: the fleet-wide account/quota PRODUCER - this watcher's
# slow-poll `check: fleet-quota` pass. Runs exactly ONE quota-axi --json per
# CHECK_INTERVAL (never per pane), folds the claude provider's relevant general
# windows (five_hour/seven_day) into one lowest-runway reading, and fans
# quota_pct= / quota_window= / quota_reset_ts= onto every live task's
# state/<id>.telemetry. The per-pane account label was already stamped at spawn
# and on switch; quota is per-ACCOUNT, so one fleet-wide reading fans everywhere.
#
# PASSIVE (dashboard + session-start digest surfacing only, design "Surfacing"):
# this sweep NEVER wakes and prints nothing - account level is slow-moving
# context, not an alarm - so it emits no check: line and enqueues no wake.
# FAIL-SOFT: an absent/unreadable quota-axi, a missing jq, an unparseable
# payload, or no relevant general window writes NO quota keys this cycle (absent
# = unknown, never a zero) and never blocks the watcher loop. Mirrors the shared
# quota-axi resolution used by fm-account-orchestrator.sh
# (FM_DISPATCH_QUOTA_AXI, default quota-axi) so the whole fleet addresses one
# binary. Skips supervise=off panes exactly like recorded_windows, so an
# unsupervised griller pane is never written.
fleet_quota_sweep() {
  local cmd qjson row win pct reset_raw reset_ts meta
  command -v jq >/dev/null 2>&1 || return 0
  cmd=$(printf '%s' "${FM_DISPATCH_QUOTA_AXI:-quota-axi}")
  command -v "$cmd" >/dev/null 2>&1 || return 0
  qjson=$("$cmd" --json 2>/dev/null) || return 0
  [ -n "$qjson" ] || return 0
  # The claude general windows only (the same five_hour/seven_day set
  # fm-dispatch-select.sh's general_window_matches owns), sorted by remaining so
  # the minimum drives the pane's quota_pct and names quota_window.
  row=$(printf '%s' "$qjson" | jq -r '
    [ .providers[]? | select(.provider == "claude") | .windows // [] | .[]?
        | select(((.percentRemaining | type)) == "number")
        | select(.percentRemaining >= 0 and .percentRemaining <= 100)
        | select(.id == "five_hour" or .id == "seven_day") ]
    | sort_by(.percentRemaining)
    | .[0]
    | [ .id // "", (.percentRemaining | tostring), (.resetsAt // "") ]
    | @tsv
  ' 2>/dev/null) || return 0
  [ -n "$row" ] || return 0
  IFS=$'\t' read -r win pct reset_raw <<EOF || true
$row
EOF
  [ -n "$pct" ] || return 0
  # quota_reset_ts is the window's reset as an epoch when quota-axi gives it; an
  # ISO resetsAt converts on either platform, a numeric value passes through, and
  # an absent/unparseable one stays absent (never a fabricated value).
  reset_ts=
  case "$reset_raw" in
    '') ;;
    *[!0-9]*)
      reset_ts=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$reset_raw" +%s 2>/dev/null \
        || date -u -d "$reset_raw" +%s 2>/dev/null || true)
      ;;
    *) reset_ts=$reset_raw ;;
  esac
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    [ "$(grep '^supervise=' "$meta" | cut -d= -f2- || true)" = off ] && continue
    fm_telemetry_set "$STATE/$(basename "$meta" .meta).telemetry" quota_pct "$pct" || true
    fm_telemetry_set "$STATE/$(basename "$meta" .meta).telemetry" quota_window "$win" || true
    if [ -n "$reset_ts" ]; then
      fm_telemetry_set "$STATE/$(basename "$meta" .meta).telemetry" quota_reset_ts "$reset_ts" || true
    fi
  done
  return 0
}

# Reconcile a declared pause or captain-held status with authoritative crew state.
# Only a confidently dead ordinary crew may recover paused classification after
# fm-crew-state has fallen back to stopped or unknown.
pause_state_class() {  # <window> <task>
  local win=$1 task=$2 key last recheck_file class agent_alive
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  last=$(last_status_line "$STATE/$task.status")
  recheck_file="$STATE/.paused-rechecked-$key"
  if ! status_is_paused_or_captain_held "$last"; then
    rm -f "$recheck_file"
    crew_absorb_class "$task"
    return
  fi
  if [ -e "$STATE/.paused-$key" ] && [ "$(age_of "$recheck_file")" -lt "$STALE_ESCALATE_SECS" ]; then
    if [ "$(window_kind "$win")" != secondmate ]; then
      agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
      if [ "$agent_alive" != dead ]; then
        rm -f "$recheck_file"
        printf 'none'
        return
      fi
    fi
    printf 'paused'
    return
  fi
  class=$(crew_absorb_class "$task")
  if [ "$class" = working ]; then
    rm -f "$recheck_file"
    printf 'working'
    return
  fi
  if [ "$(window_kind "$win")" != secondmate ]; then
    agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
    if [ "$agent_alive" != dead ]; then
      rm -f "$recheck_file"
      printf 'none'
      return
    fi
  fi
  [ "$class" = none ] && [ "${agent_alive:-unknown}" = dead ] && class=paused
  case "$class" in
    paused) date +%s > "$recheck_file" ;;
    *) rm -f "$recheck_file" ;;
  esac
  printf '%s' "$class"
}

# ---- first-line stale nudge -------------------------------------------------
#
# On a stale wake for an ordinary crew task, the watcher sends ONE re-prompt
# via fm-send pointing the worker back at its brief and asking for a status
# append, records the nudge in state/.stale-nudged-<key> so it never repeats
# for the same stall episode, and only escalates the wake to firstmate if the
# worker stays silent past the next grace window (one more STALE_ESCALATE_SECS,
# which the callers arm by restarting the timer). Never nudges secondmates
# (their idle endpoint is healthy by contract) or unsupervised panes
# (supervise=off - recorded_windows already drops those, the guard here keeps
# the helper's contract single-place). A nudge that cannot be delivered
# escalates immediately exactly as before, so a failing sender never swallows
# a stalled worker. FM_STALE_NUDGE_BIN is the send seam (default: this repo's
# fm-send.sh); tests stub it.
# Prints 0 when the nudge was sent (caller absorbs and restarts the grace
# timer), 1 when it must not or could not be sent (caller escalates as before).
FM_STALE_NUDGE_BIN=${FM_STALE_NUDGE_BIN:-"$SCRIPT_DIR/fm-send.sh"}
nudge_stale_worker() {  # <window>
  local win=$1 key meta task out
  key=$(printf '%s' "$win" | tr ':/.' '___')
  [ -e "$STATE/.stale-nudged-$key" ] && return 1
  [ "$(window_kind "$win")" = secondmate ] && return 1
  meta=$(fm_backend_meta_for_window "$win" "$STATE" 2>/dev/null || true)
  [ -n "$meta" ] || return 1
  [ "$(grep '^supervise=' "$meta" | cut -d= -f2- || true)" = off ] && return 1
  task=$(window_to_task "$win" "$STATE")
  [ -n "$task" ] || return 1
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$FM_STALE_NUDGE_BIN" "$task" \
    "Auto-nudge: you have been silent for a while. Re-read your task brief (data/$task/brief.md) and append a status line (working:/paused:/blocked: ...) so supervision can see you are alive." 2>&1) \
    || { triage_log "stale nudge send failed for $win: $(printf '%s' "$out" | tail -n 1)"; return 1; }
  : > "$STATE/.stale-nudged-$key"
  return 0
}

surface_nonterminal_stale() {  # <window> <hash>
  local win=$1 h=$2 key task last
  key=$(printf '%s' "$win" | tr ':/.' '___')
  task=$(window_to_task "$win" "$STATE")
  last=$(last_status_line "$STATE/$task.status")
  # First-line nudge before the wake reaches firstmate: a stopped ordinary crew
  # gets ONE re-prompt, then the next-grace timer decides. A crew under a
  # declared pause or captain-held is never nudged - that wait is legitimate and
  # this surface is its bounded hold-recheck, so it escalates exactly as before.
  if ! status_is_paused_or_captain_held "$last" && nudge_stale_worker "$win"; then
    printf '%s' "$h" > "$STATE/.stale-$key"
    # Atomic restart: a reader polling on .stale-nudged (written first, inside
    # nudge_stale_worker) must never observe .stale-since mid-truncate as empty.
    date +%s > "$STATE/.stale-since-$key.tmp" && mv -f "$STATE/.stale-since-$key.tmp" "$STATE/.stale-since-$key"
    rm -f "$STATE/.wedge-escalations-$key" "$STATE/.stale-verdict-$key"
    return 0
  fi
  fm_wake_append stale "$win" "stale: $win" || exit 1
  printf '%s' "$h" > "$STATE/.stale-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.stale-verdict-$key"
  if status_is_paused_or_captain_held "$last"; then
    : > "$STATE/.paused-$key"
    date +%s > "$STATE/.paused-rechecked-$key"
    date +%s > "$STATE/.paused-resurfaced-$key"
  else
    rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
  fi
  wake "stale: $win"
}

# Check and heartbeat cadence must survive actionable exits and restarts: the
# watcher may be relaunched before in-memory counters reach their threshold on a
# busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m
  m=$(stat_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# Layer 2 + 3 signal scan: status files and turn-end markers. Each file is
# compared against a persisted size:mtime signature (.seen-*) rather than
# mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one, and same-second writes cannot slip through a
# strict -nt comparison. Pure read: prints one "<seen-file>\t<sig>\t<file>"
# line per changed file. .seen-* is updated only after the wake is either
# surfaced or intentionally absorbed, so a watcher killed mid-cycle never
# swallows a signal.
scan_signals() {
  local f sig sf
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ -e "$f" ] || continue
    sig=$(stat_sig "$f") || continue
    sf="$STATE/.seen-$(basename "$f" | tr '.' '_')"
    if [ "$sig" != "$(cat "$sf" 2>/dev/null)" ]; then
      printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
    fi
  done
  return 0
}

run_check_process() {
  local c=$1
  shift
  if [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    exec timeout "$CHECK_TIMEOUT" bash "$c" "$@"
  elif [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    exec gtimeout "$CHECK_TIMEOUT" bash "$c" "$@"
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    exec perl -e 'my $t = shift; my $owned = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0) unless $owned; exec @ARGV } my $group = $owned ? getpgrp(0) : $pid; my $stop = sub { $SIG{HUP} = $SIG{INT} = $SIG{TERM} = "IGNORE"; kill "TERM", -$group; select undef, undef, undef, 0.2; kill "KILL", -$group; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; local $SIG{HUP} = $stop; local $SIG{INT} = $stop; local $SIG{TERM} = $stop; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" "${FM_CHECK_OWNED_GROUP:-0}" bash "$c" "$@"
  fi
}

run_check() {
  ( run_check_process "$@" ) 2>/dev/null || true
}

FM_ACTIVE_CHECK_PID=
FM_ACTIVE_CHECK_PGID=
FM_CHECK_OUTPUT=
FM_CHECK_RESULT=
FM_CHECK_SIGNAL_PENDING=

fm_check_output_cleanup() {
  [ -z "$FM_CHECK_OUTPUT" ] || rm -f -- "$FM_CHECK_OUTPUT"
  FM_CHECK_OUTPUT=
}

fm_active_check_stop() {
  local pid=${FM_ACTIVE_CHECK_PID:-} pgid=${FM_ACTIVE_CHECK_PGID:-} i
  [ -n "$pid" ] || [ -n "$pgid" ] || return 0
  [ -z "$pgid" ] || kill -TERM -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -z "$pgid" ] || kill -KILL -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
  [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null; then
    return 1
  fi
  FM_ACTIVE_CHECK_PID=
  FM_ACTIVE_CHECK_PGID=
}

run_check_capture() {
  local pgid
  fm_check_output_cleanup
  FM_CHECK_RESULT=
  FM_CHECK_OUTPUT=$(mktemp "$STATE/.fm-check-output.XXXXXX") || return 1
  chmod 0600 "$FM_CHECK_OUTPUT" || { fm_check_output_cleanup; return 1; }
  FM_CHECK_SIGNAL_PENDING=
  trap 'FM_CHECK_SIGNAL_PENDING=1' HUP INT TERM
  set -m
  ( FM_CHECK_OWNED_GROUP=1 run_check_process "$@" ) > "$FM_CHECK_OUTPUT" 2>/dev/null &
  FM_ACTIVE_CHECK_PID=$!
  FM_ACTIVE_CHECK_PGID=$FM_ACTIVE_CHECK_PID
  set +m
  pgid=$(ps -o pgid= -p "$FM_ACTIVE_CHECK_PID" 2>/dev/null | tr -d '[:space:]')
  trap 'exit 1' HUP INT TERM
  if [ -n "$pgid" ] && [ "$pgid" != "$FM_ACTIVE_CHECK_PGID" ]; then
    fm_active_check_stop || true
    fm_check_output_cleanup
    return 1
  fi
  [ -z "$FM_CHECK_SIGNAL_PENDING" ] || exit 1
  wait "$FM_ACTIVE_CHECK_PID" 2>/dev/null || true
  FM_ACTIVE_CHECK_PID=
  fm_active_check_stop || return 1
  FM_CHECK_RESULT=$(cat "$FM_CHECK_OUTPUT" 2>/dev/null || true)
  fm_check_output_cleanup
}

# Surfaced-marker bookkeeping for the heartbeat backstop. The watcher records the
# captain-relevant status line it SURFACED (woke firstmate for) in
# .hb-surfaced-<task>, the watcher's analogue of the daemon's
# .subsuper-seen-status. Unlike .seen-* (a size:mtime signature advanced on BOTH
# surface and absorb), .hb-surfaced is advanced ONLY on surface, so the heartbeat
# fleet-scan can tell apart a captain-relevant status that already woke firstmate
# from one that has not - the latter being a per-wake-path miss it must surface.
_hb_surfaced_path() { printf '%s/.hb-surfaced-%s' "$STATE" "$(printf '%s' "$1" | tr ':/.' '___')"; }

# Record a status file's captain-relevant last line as surfaced (no-op for a
# non-captain-relevant or empty status). Call AFTER the wake is enqueued, so the
# enqueue-before-suppress ordering holds for this marker too.
mark_surfaced() {  # <status-file>
  local f=$1 task last
  task=$(basename "$f"); task="${task%.status}"
  last=$(last_status_line "$f")
  [ -n "$last" ] || return 0
  status_is_captain_relevant "$last" || return 0
  printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
}

# Mark every current captain-relevant status as surfaced. Called after the
# heartbeat backstop enqueues its wake, so the same statuses are not re-surfaced
# by the next heartbeat.
mark_all_captain_relevant_surfaced() {
  local f task last
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
  done < <(scan_captain_relevant_statuses "$STATE")
}

# Cheap heartbeat fleet-scan (the always-on twin of the daemon's catch-all). 0 if
# any captain-relevant status has NOT already been surfaced to firstmate (its
# content differs from the .hb-surfaced-<task> marker). Pure detect, no side
# effects: the caller enqueues first, then marks surfaced. Because every
# captain-relevant signal/stale already marks itself surfaced when it wakes
# firstmate, this normally finds nothing and the heartbeat is absorbed; it
# surfaces only a captain-relevant status the per-wake path absorbed by mistake -
# the fail-safe backstop.
heartbeat_scan_finds_actionable() {
  local f task last surfaced
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    surfaced=$(cat "$(_hb_surfaced_path "$task")" 2>/dev/null || true)
    [ "$surfaced" = "$last" ] && continue
    return 0
  done < <(scan_captain_relevant_statuses "$STATE")
  return 1
}

# jcode_drift_sweep: the heartbeat model/effort drift watch for live jcode
# lanes. A jcode session's model and reasoning effort are applied per-session
# through /model and /effort after launch, and the slash-popup submit race can
# lose a slash command silently (incident 2026-08-23, data/learnings.md "MODEL
# DRIFT INCIDENT": three tooling lanes ran the wrong model at max effort for
# hours) - and a worker can also change its own profile later. The session
# store (~/.jcode/sessions/session_<sid>.json, fields model and
# reasoning_effort) is the ONLY truth; pane echo is not. For every live jcode
# task this compares the profile the meta records (last-write-wins: fm-spawn
# stamps the CONFIRMED values after a verified apply) against the store's
# CURRENT values, and wakes firstmate once per drift signature with a `check:
# model-drift <id> wanted=<m>/<e> actual=<m>/<e>` line. The marker re-arms
# silently when the store comes back to the recorded profile. Fail-closed on
# every uncertainty: an unrequested axis, a supervise=off pane, a task that is
# not jcode, an unresolvable session id, or an unreadable store is skipped -
# never guessed. Cheap by design: one json read per jcode task per heartbeat,
# nothing for any other harness.
jcode_drift_sweep() {
  local meta task model effort sid worktree profile kv actual_model actual_effort
  local wanted actual sig marker key
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    [ "$(fm_meta_get "$meta" supervise 2>/dev/null || true)" = off ] && continue
    [ "$(fm_meta_get "$meta" harness)" = jcode ] || continue
    task=$(basename "$meta"); task=${task%.meta}
    key=$(printf '%s' "$task" | tr ':/.' '___')
    model=$(fm_meta_get "$meta" model)
    effort=$(fm_meta_get "$meta" effort)
    [ "$model" = default ] && model=
    [ "$effort" = default ] && effort=
    { [ -n "$model" ] || [ -n "$effort" ]; } || continue
    sid=$(fm_meta_get "$meta" session_id)
    if [ -z "$sid" ]; then
      worktree=$(fm_meta_get "$meta" worktree)
      [ -n "$worktree" ] || continue
      sid=$(fm_resolve_crew_session_id "$worktree" "" 2>/dev/null || true)
    fi
    [ -n "$sid" ] || continue
    profile=$(fm_session_store_profile "$sid" 2>/dev/null || true)
    [ -n "$profile" ] || continue
    actual_model='' actual_effort=''
    while IFS= read -r kv; do
      case "$kv" in
        model=*) actual_model=${kv#model=} ;;
        effort=*) actual_effort=${kv#effort=} ;;
      esac
    done <<EOF
$profile
EOF
    wanted="${model:--}/${effort:--}"
    actual="${actual_model:--}/${actual_effort:--}"
    if { [ -n "$model" ] && [ "$actual_model" != "$model" ]; } \
      || { [ -n "$effort" ] && [ "$actual_effort" != "$effort" ]; }; then
      sig="$wanted|$actual"
      marker="$STATE/.drift-surfaced-$key"
      [ "$(cat "$marker" 2>/dev/null || true)" = "$sig" ] && continue
      printf '%s' "$sig" > "$marker"
      reason="check: model-drift $task wanted=$wanted actual=$actual"
      fm_wake_append check "model-drift-$task" "$reason" || exit 1
      touch "$STATE/.last-check"
      wake "$reason"
    else
      rm -f "$STATE/.drift-surfaced-$key"
    fi
  done
}

# event_wait_or_sleep: the terminal wait of each supervision cycle. For a home
# with push-capable windows (herdr), it replaces the blind `sleep POLL` with a
# bounded wait on the backend's native transition stream, so a crew going
# `blocked` wakes the supervisor sub-second instead of after the stale-pane
# wedge timer. For every other home - no push-capable window, backend not
# capable, or the event path proven unreliable this process - it sleeps POLL,
# byte-for-byte today's behavior. The poll loop above still runs every cycle, so
# this only ever SHORTENS latency; it can never drop an escalation (the poll
# loop is the permanent fail-closed backstop). This preserves the single live
# supervision cycle: the reader is a short-lived subprocess of THIS watcher, not
# a second watcher, so every guard/beacon/arm/turn-end mechanism is unchanged.
# beacon_sleep: sleep `total` seconds while keeping the liveness beacon fresh and
# staying promptly interruptible. The sleep runs as a backgrounded child we
# `wait` on, so a HUP/INT/TERM delivered to this watcher runs its trap right away
# instead of being deferred behind a foreground `sleep` - the recovery wedge
# where --restart's SIGTERM could not land until the whole poll elapsed. The
# beacon is re-touched every slice (see BEACON_SLICE) so a healthy sleeping
# watcher never reads as dead mid-cycle.
_beacon_sleep_child=
beacon_sleep() {  # <total-seconds>
  local slice remaining=$1
  while [ "$remaining" -gt 0 ]; do
    slice=$BEACON_SLICE
    [ "$remaining" -lt "$slice" ] && slice=$remaining
    sleep "$slice" &
    _beacon_sleep_child=$!
    wait "$_beacon_sleep_child"
    _beacon_sleep_child=
    touch "$STATE/.last-watcher-beat"
    remaining=$((remaining - slice))
  done
}

event_wait_or_sleep() {
  local w b session first_backend="" first_session="" rec rc
  local windows=()
  while IFS= read -r w; do
    b=$(window_backend "$w")
    fm_backend_has_push "$b" || continue
    # Secondmate endpoints are supervised via status writes, not pane/agent
    # state (an idle or blocked secondmate agent pane is healthy by design), so
    # they are excluded from the fast escalation exactly as the stale loop skips
    # them.
    [ "$(window_kind "$w")" = secondmate ] && continue
    session=${w%%:*}
    if [ -z "$first_backend" ]; then first_backend=$b; first_session=$session; fi
    # One socket connection covers one backend+session; a home normally has a
    # single herdr session. A window in a different backend/session stays on the
    # poll path this cycle.
    if [ "$b" != "$first_backend" ] || [ "$session" != "$first_session" ]; then
      continue
    fi
    windows+=("$w")
  done < <(recorded_windows)

  if [ "${#windows[@]}" -eq 0 ]; then
    beacon_sleep "$POLL"
    return
  fi

  # Memoized capability probe (fm_backend_events_capable runs a heavy schema
  # read); re-probed only when the backend/session key changes.
  if [ "$_event_cap_key" != "$first_backend:$first_session" ]; then
    _event_cap_key="$first_backend:$first_session"
    if fm_backend_events_capable "$first_backend" "$first_session"; then
      _event_cap_ok=1
    else
      _event_cap_ok=0
    fi
    _event_cap_fails=0
  fi
  if [ "$_event_cap_ok" != 1 ]; then
    beacon_sleep "$POLL"
    return
  fi

  rec=$(FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 fm_backend_wait_transition "$first_backend" "$first_session" "$POLL" "$STATE" "${windows[@]}")
  rc=$?
  case "$rc" in
    0)
      _event_cap_fails=0
      handle_push_transition "$first_backend" "$first_session" "$rec"
      ;;
    2)
      # Event path unusable this cycle (connect/subscribe failure). Sleep the
      # budget and count toward the runtime-disable threshold; past it, drop to
      # pure polling for the rest of this watcher process.
      _event_cap_fails=$((_event_cap_fails + 1))
      [ "$_event_cap_fails" -ge "$EVENT_CAP_FAIL_MAX" ] && _event_cap_ok=0
      beacon_sleep "$POLL"
      ;;
    *)
      # 1: a clean full-budget wait with no actionable edge - the reader already
      # blocked ~POLL, so just continue; the next cycle re-scans.
      _event_cap_fails=0
      ;;
  esac
}

# handle_push_transition: act on a fresh actionable (blocked) transition record
# the backend returned. Maps the pane back to its window and task, applies the
# declared-pause exemption (a crew waiting on a known external dependency is not
# a surprise block - absorb it on the poll loop's long pause cadence instead),
# and otherwise enqueues an immediate `stale` wake and wakes the supervisor. The
# `stale` kind is deliberate: the supervisor's handler for it ("peek the pane to
# diagnose") is exactly right for a blocked crew, and the drain/dedupe/guard
# machinery already understands it (queued by key=window, so a later poll-path
# stale for the same pane collapses on drain).
handle_push_transition() {  # <backend> <session> <record>
  local backend=$1 session=$2 record=$3 pane_id to window task reason
  pane_id=$(fm_transition_pane_id "$record")
  to=$(fm_transition_to_status "$record")
  [ -n "$pane_id" ] || { sleep 1; return; }
  window="$session:$pane_id"
  task=$(window_to_task "$window" "$STATE")
  if status_is_paused "$(last_status_line "$STATE/$task.status")"; then
    # BENIGN absorb: the crew declared an external-wait pause, so the poll loop
    # owns it on the long pause cadence and this fast-path takes no action. The
    # dedupe-marker commit is a best-effort optimization (it stops the same
    # blocked edge re-firing next cycle); its failure NEVER loses a wake, because
    # nothing is being surfaced here. So a transient marker-write failure must
    # NOT exit the watcher - doing so would turn a benign absorption into a FAILED
    # exit and drop supervision of the whole fleet. Log it and keep polling; a
    # short throttle prevents a hot loop if the write keeps failing (the missing
    # marker just lets this same edge re-absorb on the next cycle, which is
    # harmless for a paused pane).
    triage_log "absorbed push $to (declared pause, awaiting external): $window"
    if ! fm_backend_commit_transition "$backend" "$STATE" "$session" "$record"; then
      triage_log "push absorb dedupe-commit failed (continuing, not fatal): $window"
      sleep 1
    fi
    return
  fi
  reason="stale: $window (herdr: agent $to - waiting on human, escalated immediately, not via wedge timer)"
  # A REAL internal error: the durable wake could not be enqueued, so the blocked
  # crew would be lost entirely. This is distinct from a benign absorption - exit
  # loudly (an explicit stderr line, not just a bare nonzero) so the failure is
  # visible rather than silent.
  if ! fm_wake_append stale "$window" "$reason"; then
    echo "watcher: FAILED - could not enqueue a durable wake for a blocked crew ($window)" >&2
    exit 1
  fi
  # The wake is now durably queued, so the supervisor WILL be surfaced regardless
  # of what happens next. The dedupe-marker commit is a best-effort optimization
  # ON TOP of that surface; a transient marker-write failure must not drop the
  # surface. The wake drain collapses any duplicate stale-by-window record that a
  # missing marker would let re-enqueue next cycle, so re-firing is harmless.
  fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" \
    || triage_log "push escalate dedupe-commit failed (wake already queued, surfacing anyway): $window"
  mark_surfaced "$STATE/$task.status"
  wake "$reason"
}

# --- Main entry: the runtime below runs only when this file is executed as a
# script. When sourced (unit tests loading the functions above), return here
# before acquiring the singleton lock or entering the blocking loop.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

# Invariant: POLL must stay below the beacon grace, or a cycle's wait could
# outlive the beacon and read as dead. beacon_sleep already slices the wait to
# hold this even when the invariant is violated, so this only warns rather than
# refusing to start - but a violated invariant means the operator-chosen poll
# cadence is fighting the grace and should be reconciled.
if [ "$POLL" -ge "$WATCHER_STALE_GRACE" ]; then
  echo "watcher: FM_POLL=${POLL}s >= grace ${WATCHER_STALE_GRACE}s; the beacon is kept fresh by slicing the wait, but set FM_POLL below the grace to match cadence to liveness." >&2
fi

# Before acquiring the watcher lock or enumerating any runnable check, replace
# or quarantine checks created by older versions. The migration compares bytes
# and reads data only; it never invokes legacy check files through Bash.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || {
  echo "watcher: PR check migration blocked; refusing to execute state checks" >&2
  exit 1
}

if ! fm_lock_try_acquire "$WATCH_LOCK"; then
  BEAT="$STATE/.last-watcher-beat"
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    if [ -e "$BEAT" ]; then
      beat_age=$(fm_path_age "$BEAT")
      if [ "$beat_age" -ge "$WATCHER_STALE_GRACE" ]; then
        echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but heartbeat is stale for ${beat_age}s (>${WATCHER_STALE_GRACE}s); inspect or stop that watcher before re-arming." >&2
        exit 1
      fi
    elif [ "$(fm_path_age "$WATCH_LOCK")" -ge "$WATCHER_STALE_GRACE" ]; then
      echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but no heartbeat exists; inspect or stop that watcher before re-arming." >&2
      exit 1
    fi
    echo "watcher: already running pid $FM_LOCK_HELD_PID"
  else
    echo "watcher: already running"
  fi
  exit 0
fi
watcher_cleanup() {
  fm_active_check_stop || return 1
  fm_check_output_cleanup
  fm_custom_check_snapshot_cleanup
  fm_lock_release "$WATCH_LOCK"
}
trap watcher_cleanup EXIT
# On a stop signal, kill the backgrounded beacon_sleep child (if the loop is in
# its terminal wait) so the trap is not deferred behind a foreground sleep, then
# exit so the EXIT trap releases the lock. This is what lets --restart's SIGTERM
# clear a sleeping watcher promptly instead of waiting out the whole poll.
# shellcheck disable=SC2329 # Invoked indirectly by the signal trap below.
watcher_signal_exit() {
  [ -n "${_beacon_sleep_child:-}" ] && kill "$_beacon_sleep_child" 2>/dev/null
  exit 1
}
trap watcher_signal_exit HUP INT TERM
# This watcher's own pid, as recorded in the lock by fm_lock_claim (which writes
# ${BASHPID:-$$} from this same main shell). Read directly, never via a command
# substitution, so it matches the stored holder pid for the self-eviction check.
WATCHER_PID=${BASHPID:-$$}
printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
fm_pid_identity "$WATCHER_PID" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

[ "$RESOURCE_INTERVAL_FELL_BACK" = 0 ] || triage_log \
  "host-resource cadence unresolved ('$RESOURCE_INTERVAL_RAW'), using default ${RESOURCE_INTERVAL}s"

# Cadence-config problems are reported LOUDLY, never silently: a malformed value
# or an unknown key already fell back to its safe default above, but the operator
# who wrote the file must see why it was not honored. Both to stderr (visible when
# the watcher is armed in the foreground) and the triage log (durable).
if [ -n "$FM_CADENCE_WARNINGS" ]; then
  echo "watcher: cadence config: $FM_CADENCE_WARNINGS" >&2
  triage_log "cadence config: $FM_CADENCE_WARNINGS"
fi

while :; do
  POLL_CYCLE=$(( POLL_CYCLE + 1 ))
  # Self-eviction: if the singleton lock no longer names this process, a second
  # watcher has taken over (e.g. a transient duplicate from a racy arm). Stand
  # down so the rightful singleton continues alone. The EXIT trap's release
  # no-ops because the lock pid is not ours, so the survivor's lock is untouched.
  # This makes any duplicate self-resolve within one poll instead of persisting
  # and doubling every wake.
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$WATCHER_PID" ]; then
    exit 0
  fi

  # Liveness beacon for fm-guard.sh: a fresh mtime here means a watcher is
  # alive. Supervision scripts warn when this goes stale with tasks in flight.
  touch "$STATE/.last-watcher-beat"

  # Parent-owned secondmate pending-reply reconciliation: resolve correlated
  # parent reports, observe backend busy/idle turn completion, send one recovery
  # repost after grace, and escalate once if the recovery turn is also missed.
  # No conversation scraping; unresolved records are never silently expired.
  fm_pending_reply_tick "$STATE" || true

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    rejected_checks=
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      if [ "$(basename "$c")" = x-watch.check.sh ]; then
        if fmx_poll_shim_valid "$c" "$FM_HOME" "$FM_ROOT" \
          && [ -f "$FM_ROOT/bin/fm-x-poll.sh" ] && [ ! -L "$FM_ROOT/bin/fm-x-poll.sh" ]; then
          FM_HOME="$FM_HOME" run_check_capture "$FM_ROOT/bin/fm-x-poll.sh" || exit 1
          out=$FM_CHECK_RESULT
        else
          rejected_checks="$rejected_checks $c"
          continue
        fi
      else
        id=$(basename "$c" .check.sh)
        if fm_pr_poll_artifacts_valid "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh"; then
          provider=$FM_PR_DATA_PROVIDER
          url=$FM_PR_DATA_URL
          host=$FM_PR_DATA_HOST
          path=$FM_PR_DATA_PATH
          number=$FM_PR_DATA_NUMBER
          run_check_capture "$SCRIPT_DIR/fm-pr-poll.sh" --validated \
            "$provider" "$url" "$host" "$path" "$number" || exit 1
          out=$FM_CHECK_RESULT
        elif fm_custom_check_snapshot_prepare "$STATE" "$id"; then
          custom_snapshot=$FM_CUSTOM_CHECK_SNAPSHOT
          run_check_capture "$custom_snapshot" || exit 1
          out=$FM_CHECK_RESULT
          fm_custom_check_snapshot_cleanup
        else
          fm_custom_check_snapshot_cleanup
          rejected_checks="$rejected_checks $c"
          continue
        fi
      fi
      if [ -n "$out" ]; then
        reason="check: $c: $out"
        fm_wake_append check "$c" "$reason" || exit 1
        touch "$STATE/.last-check"
        wake "$reason"
      fi
    done
    if [ -n "$rejected_checks" ]; then
      reason="check: rejected unauthenticated state checks:$rejected_checks"
      fm_wake_append check unauthenticated-state-checks "$reason" || exit 1
      touch "$STATE/.last-check"
      wake "$reason"
    fi
    # Slow-poll context monitor: wake once when a secondmate crosses the handoff
    # threshold. wake() exits the cycle when it fires (marker prevents re-fire).
    secondmate_context_sweep
    # Slow-poll OWN-context stow nudge: wake once when firstmate's own context
    # crosses the stow threshold in NORMAL supervision (the away-mode daemon owns
    # it while it runs). wake() exits the cycle when it fires; the shared marker
    # prevents re-fire. Nudge only - never runs /stow or /compact.
    context_stow_sweep
    # Gap-1 fleet-quota producer: ONE quota-axi --json per CHECK_INTERVAL fanned
    # onto every live task's .telemetry. Passive (never wakes); fail-soft (no
    # quota data = no keys this cycle). Shares this slow-poll gate, so it never
    # runs on the fast poll and never per-pane.
    fleet_quota_sweep
    touch "$STATE/.last-check"
  fi

  # Host-resource monitor. The slow crew-liveness probe runs in its OWN process
  # (resource_probe_launch, backgrounded and never waited on), so this loop never
  # blocks on it; the surface decision (resource_surface_check) only reads the
  # timestamped reading that process published and is cheap. Both are off when the
  # monitor is disabled. Placed before the signal scan like the check block above,
  # so a chatty crewmate cannot starve a worsened-pressure wake.
  if [ "$RESOURCE_INTERVAL" -gt 0 ]; then
    resource_probe_launch
    resource_surface_check
  fi

  # Hourly session passes, each on its own stamp cadence. Placed with the other
  # slow sweeps, before the signal scan, so a chatty crewmate cannot starve them.
  hourly_pass_sweep

  # On the first changed signal, linger one grace period and re-scan before
  # classifying: a crewmate's final status write and the same turn's turn-end
  # hook land seconds apart, and reporting them as separate actionable wakes
  # costs a full firstmate turn each. The re-scan also picks up a newer
  # signature for an already-pending file (last write wins below).
  pending=$(scan_signals)
  if [ -n "$pending" ]; then
    # Terminal-latency guard: the coalescing linger exists only to batch benign
    # chatter (a status write plus its turn-end hook, a working: note). A signal
    # whose FIRST scan already carries a captain-relevant verb
    # (done:/failed:/needs-decision:/blocked:) is a real terminal event, so it
    # must NOT pay the linger - raising SIGNAL_GRACE to batch chatter would
    # otherwise delay it by the whole grace. Compute the first-scan file list and
    # skip the linger when it is actionable by verb; a no-verb burst still lingers.
    first_files=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      case " $first_files " in *" $f "*) ;; *) first_files="$first_files $f" ;; esac
    done <<EOF
$pending
EOF
    # shellcheck disable=SC2086  # $first_files is a space-separated status-path list (ids carry no spaces)
    if signal_reason_is_actionable $first_files; then
      : # terminal verb present: surface now, no coalescing delay
    else
      beacon_sleep "$SIGNAL_GRACE"
      pending=$(printf '%s\n%s' "$pending" "$(scan_signals)")
    fi
    files=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
    done <<EOF
$pending
EOF
    reason="signal:$files"
    # Triage: a signal is ACTIONABLE when any of these holds (cheapest first):
    #   - a live away-mode daemon owns triage and wants every wake;
    #   - any status file carries a captain-relevant verb;
    #   - or it is a no-verb wake (a bare turn-end, a working: note) whose crew is
    #     NOT provably working - the crew stopped its turn with no actively-running
    #     pipeline and no busy pane, so it may be done (even via an interactive menu
    #     that wrote no done: status), waiting on a decision, or wedged. Absorbing
    #     such a turn-end is exactly the swallowed-finish this change guards against.
    # Actionable -> enqueue, advance .seen-* markers, exit. Benign (a no-verb wake
    # whose crew IS provably working) in always-on mode -> advance the markers so it
    # will not re-fire, log, and keep blocking without enqueuing. The provably-working
    # check is the only costly one (it may run a bounded no-mistakes call), so the ||
    # ordering evaluates it ONLY for a daemon-free, no-captain-verb signal.
    # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
    if afk_daemon_owns_triage || signal_reason_is_actionable $files || ! signal_crew_provably_working $files; then
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        fm_wake_append signal "$(basename "$f")" "$reason" || exit 1
      done <<EOF
$pending
EOF
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
        mark_surfaced "$f"
      done <<EOF
$pending
EOF
      # Live tripwire (Claude account-exhaustion limit error) rotation: for any
      # surfaced status file whose last line is a recognized limit error on a
      # jcode/Claude worker, call the account-switch orchestrator to rotate the
      # fleet onto the next non-exhausted account WITHOUT captain intervention.
      # This runs IN ADDITION to surfacing the blocking status (the captain still
      # sees the block); the rotation is idempotent and fail-soft, so it never
      # blocks the wake.
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        case "$f" in
          *.status) ;;
          *) continue ;;
        esac
        _orch_task=$(basename "$f"); _orch_task="${_orch_task%.status}"
        _orch_last=$(last_status_line "$f")
        if status_is_tripwire "$_orch_last"; then
          orchestrator_rotate_on_tripwire "$_orch_task"
        fi
      done <<EOF
$pending
EOF
      # Keep the captain's live desk current on a real fleet-state change. This
      # actionable-signal branch is where a worker's done/failed/needs-decision/
      # blocked status (and a finish reported only through the pane) surfaces, so
      # it is the one central place a crew's own progress can refresh the desk.
      # Best-effort, silent, detached: a no-op without a live desk, it never
      # re-serves and never wakes, and runs before the wake exit below so it
      # cannot delay surfacing. See bin/fm-desk-event.sh.
      FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-desk-event.sh" "done" >/dev/null 2>&1 || true
      wake "$reason"
    else
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
      done <<EOF
$pending
EOF
      triage_log "absorbed benign $reason"
      # Suppressors are advanced above, so this benign signal will not re-fire; a
      # tick (when enabled) surfaces it once as proof of life instead of exiting.
      absorb_tick "signal absorbed"
    fi
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the crewmate finished, is waiting, or is wedged. Each distinct
  # stale hash is surfaced, absorbed, or timed toward escalation once (.stale-*
  # remembers the hash already classified).
  while IFS= read -r w; do
    kind=$(window_kind "$w")
    task=$(window_to_task "$w" "$STATE")
    key=${w//:/_}
    key=${key//\//_}
    key=${key//./_}
    last=$(last_status_line "$STATE/$task.status")
    if ! status_is_paused_or_captain_held "$last" && [ -e "$STATE/.paused-$key" ]; then
      clear_pause_tracking "$w"
    fi
    if [ "$kind" = secondmate ] && ! status_is_paused "$last"; then
      continue
    fi
    # Immediate herdr pane-exit detection: a dead pane makes the capture below
    # fail and `continue` past every stale/wedge path, so the crash evidence
    # would only surface much later via a liveness sweep. Check FIRST, before the
    # capture short-circuit, so a confirmed dead pane records its crash-tail and
    # wakes firstmate now. Herdr-only, meta-gated, idempotent (see
    # fm_pane_crash_capture): a no-op for every live pane and every other backend,
    # printing `captured` only on the one fresh detection of a death, so this
    # wakes exactly once and never re-fires for the same crash.
    if [ "$(fm_pane_crash_capture "$(window_backend "$w")" "$w" "$task" "$STATE")" = captured ]; then
      wake "check: pane-crashed $task"
    fi
    tail40=$(fm_backend_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" 2>/dev/null) || continue
    h=$(printf '%s' "$tail40" | hash_pane)
    # Visibility Gap-2: scan the tail we JUST captured for a 429/rate-limit
    # tripwire before the worker surfaces its own blocked/paused status. Reuses
    # this tail40 and hash - ZERO extra backend call. Telemetry-only on a first
    # 429; a rate emits a proactive check: quota-anomaly wake (which exits).
    quota_anomaly_scan "$w" "$task" "$tail40" "$h"
    key=$(printf '%s' "$w" | tr ':/.' '___')
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    ssf="$STATE/.stale-since-$key"
    ewf="$STATE/.wedge-escalations-$key"
    pf="$STATE/.paused-$key"   # flag: this key's stale is using the bounded pause cadence
    prev=$(cat "$hf" 2>/dev/null || true)
    # Visibility Gap-4: a delivered-but-never-processed steer (a silent
    # composer-stuck) reuses this loop's already-captured tail40/hash/prev -
    # zero extra backend capture. Gated internally: it probes busy state only
    # while a fresh steer is recorded and the pane hash has not advanced.
    steer_stuck_check "$w" "$task" "$tail40" "$h" "$prev"
    # Visibility Gap-5: the dead-turn liveness tripwire. A lane that rotated
    # accounts on a 429 and then never started a new turn looks healthy (pane
    # present, telemetry carries the 429, busy predicates may even say busy)
    # but is dead. Reuses this loop's already-captured tail40 - zero extra
    # backend capture. Gated internally: fires only within
    # FM_DEAD_TURN_WINDOW of a recorded last_429_ts when pane CONTENT is
    # frozen across polls (or a jcode dead marker sits in the tail) with no
    # status append since the 429; sends exactly ONE automatic resume steer
    # via fm-send, escalates `check: dead-turn <task>` on the next poll that
    # is still dead, and clears silently on a status append or advancing
    # content. Busy-ness is NEVER a liveness signal here (the dead jcode
    # lanes read busy forever; supervision-miss-rootcause F4).
    dead_turn_check "$w" "$task" "$tail40"
    # Retry-loop tripwire: a supervised worker appending the SAME status body
    # FM_RETRY_LOOP_MIN+ times in a row is stuck retrying without progress. Pure
    # status-file read (zero backend capture); sends ONE stop-retrying steer per
    # distinct loop episode, then escalates once if the loop continues. Secondmate
    # and supervise=off panes are excluded inside the function.
    retry_loop_check "$w" "$task"
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      # Busy match: a backend's native semantic state when available (herdr),
      # else the last 6 non-blank lines only (the TUI footer area, where every
      # verified harness renders its busy indicator) so busy-looking strings
      # in displayed content cannot suppress stale detection.
      if [ "$n" -ge 2 ] && ! window_is_busy "$w" "$tail40"; then
        # The pane is idle/stale at hash $h. Triage decides whether this wakes
        # firstmate. Detection itself is unchanged from above.
        if [ "$kind" = secondmate ]; then
          case "$(pause_state_class "$w" "$task")" in
            paused) handle_paused_stale "$w" "$task" "$h" ;;
            *)      clear_pause_tracking "$w" ;;
          esac
        elif afk_daemon_owns_triage; then
          # Daemon owns triage: one-shot per distinct stale hash, as before.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            fm_wake_append stale "$w" "stale: $w" || exit 1
            printf '%s' "$h" > "$sf"
            wake "stale: $w"
          fi
        elif stale_is_terminal "$w" "$STATE"; then
          # The log's last line is captain-relevant - but that alone is not
          # proof the crew is actually done: a crew's own status log gets no
          # new entry once firstmate hands it to a no-mistakes validation
          # (AGENTS.md's sparse status-reporting contract), so the log can
          # keep showing a "done:"/needs-decision/blocked leftover from
          # BEFORE that validation started for the run's entire (possibly
          # many-minutes) duration, while stale_is_terminal - which has no
          # run-step awareness - keeps reporting it as still-current on every
          # poll. Root cause of the 2026-07 herdr false-surface incidents: a
          # validating crew was surfaced as stale every few minutes despite an
          # actively-running pipeline, purely because of this stale leftover
          # line. On a NEW hash, give an active run/busy pane (the same
          # authoritative source fm-crew-state.sh itself already prioritizes
          # over the log) a chance to override before trusting the log.
          vf="$STATE/.stale-verdict-$key"
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            # The pane changed, but a captain-relevant log line does not move once
            # firstmate hands a crew off, so the harness footer's live "Churned
            # for Xm Ys" / "Total:" counters advance the hash on every redraw and
            # would re-surface an already-handled terminal crew each poll. Decide
            # on the RECONCILED crew state, not the pixels: if fm-crew-state's
            # verdict is unchanged from the one already surfaced, this is pure
            # redraw churn - advance the hash and stay silent (keeping any running
            # wedge timer honest). Re-surface only when the verdict itself changes.
            verdict=$(crew_state_verdict "$(window_to_task "$w" "$STATE")")
            if [ -n "$verdict" ] && [ "$verdict" = "$(cat "$vf" 2>/dev/null || true)" ]; then
              printf '%s' "$h" > "$sf"
              [ -e "$ssf" ] && wedge_timer_check "$w" "$ssf" "stale (overridden terminal status)" "$ewf"
              triage_log "absorbed stale (terminal verdict unchanged - ${verdict}): $w"
            elif crew_is_provably_working "$(window_to_task "$w" "$STATE")"; then
              printf '%s' "$h" > "$sf"
              date +%s > "$ssf"
              [ -n "$verdict" ] && printf '%s' "$verdict" > "$vf"
              triage_log "absorbed stale (provably working, overriding a stale captain-relevant status): $w"
            else
              fm_wake_append stale "$w" "stale: $w" || exit 1
              printf '%s' "$h" > "$sf"
              rm -f "$ssf"
              [ -n "$verdict" ] && printf '%s' "$verdict" > "$vf"
              mark_surfaced "$STATE/$(window_to_task "$w" "$STATE").status"
              wake "stale: $w"
            fi
          elif [ -e "$ssf" ]; then
            # This exact hash was already overridden as provably-working (a
            # wedge timer is running for it) - keep treating it that way
            # without re-reading the crew state every poll, and without
            # letting the still-captain-relevant log line re-surface it.
            wedge_timer_check "$w" "$ssf" "stale (overridden terminal status)" "$ewf"
          fi
          # else: already surfaced as genuinely terminal on a prior poll of
          # this same hash - nothing left to do (matches the original,
          # unmodified terminal-status behavior).
        else
          # Non-terminal stale: a crew gone quiet without a captain-relevant status.
          # Decided once per distinct stale hash (the costly state reads run only
          # on first sight, never every poll) via pause_state_class, which returns:
          #   - working: an actively-running pipeline legitimately sits on a static
          #     pane (e.g. waiting on CI), so absorb and start the wedge timer so a
          #     genuinely frozen run still escalates past STALE_ESCALATE_SECS;
          #   - paused: the crew declared an external wait, or a declared pause or
          #     captain hold is paired with a confidently dead agent, so absorb on
          #     the long PAUSE_RESURFACE_SECS cadence instead of wedge-escalating;
          #   - none: no running pipeline, idle pane, no busy signature, no declared
          #     pause - the crew has STOPPED. The first stale sighting sends the
          #     one auto-nudge and absorbs; the wake reaches firstmate only when
          #     the crew stays silent past the next grace window, so a crew that
          #     finished via an interactive menu without a done: status is caught
          #     by that timer too, never left to rot invisibly.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            task=$(window_to_task "$w" "$STATE")
            case "$(pause_state_class "$w" "$task")" in
              working)
                clear_pause_tracking "$w"
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                triage_log "absorbed non-terminal stale (provably working): $w"
                ;;
              paused)
                handle_paused_stale "$w" "$task" "$h"
                ;;
              *)
                surface_nonterminal_stale "$w" "$h"
                ;;
            esac
          else
            task=$(window_to_task "$w" "$STATE")
            if [ -e "$pf" ] || status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")"; then
              case "$(pause_state_class "$w" "$task")" in
                paused)  handle_paused_stale "$w" "$task" "$h" ;;
                working) clear_pause_state "$w"
                         printf '%s' "$h" > "$sf"
                         wedge_timer_check "$w" "$ssf" "non-terminal stale (provably working after a declared pause)" "$ewf" 1
                         triage_log "absorbed non-terminal stale (provably working): $w" ;;
                *)       handle_paused_stale "$w" "$task" "$h" ;;
              esac
            else
              wedge_timer_check "$w" "$ssf" "non-terminal stale" "$ewf" 1
            fi
          fi
        fi
      else
        # Pane busy or not yet stably stale: reset pending escalation bookkeeping
        # (a fresh nudge for a future episode too - this stall is over).
        rm -f "$ssf" "$ewf" "$STATE/.stale-nudged-$key"
        if [ -e "$pf" ] && { [ "$n" -ge 2 ] || ! status_is_paused_or_captain_held "$(last_status_line "$STATE/$(window_to_task "$w" "$STATE").status")"; }; then
          clear_pause_tracking "$w"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
      rm -f "$ssf" "$ewf" "$STATE/.stale-nudged-$key"
      task=$(window_to_task "$w" "$STATE")
      if ! afk_daemon_owns_triage && status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")" && ! window_is_busy "$w" "$tail40"; then
        case "$(pause_state_class "$w" "$task")" in
          paused) handle_paused_stale "$w" "$task" "$h" ;;
          *)      clear_pause_tracking "$w" ;;
        esac
      else
        [ -e "$pf" ] && clear_pause_tracking "$w"
      fi
    fi
  done < <(recorded_windows)

  # Heartbeat: the watcher runs a cheap fleet-scan at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # no-change heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any
  # surfaced non-heartbeat wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    # Model/effort drift watch for live jcode lanes: the session store is the
    # only truth for what a session runs, and a silently-lost /model|/effort or
    # a later in-session switch must surface, never run hours on the wrong
    # profile. One json read per jcode task per heartbeat; wakes once per drift
    # signature via `check: model-drift <id>`; re-arms when the store matches.
    jcode_drift_sweep
    # Triage: in always-on mode a heartbeat is benign unless the cheap fleet-scan
    # turns up a captain-relevant status the per-wake path missed. Absorb the
    # no-change case (advance the schedule and back off exactly as wake() would,
    # without exiting); the away-mode daemon, when present, owns triage and wants
    # every heartbeat.
    # Every heartbeat carries the host's latest known pressure, so a fleet review
    # is never done against a machine whose state firstmate cannot see. The value
    # is the one the background probe cycle already cached, so annotating costs no probe; a
    # healthy or disabled host annotates nothing. An unknown reading, on a host
    # whose probes stopped answering, deliberately leaves the last known level in
    # place: going quiet on a machine that was just critical would hide real
    # pressure, and the age gate below bounds how long that can persist.
    # .resource-status is only ever written, never cleared, so a disabled monitor
    # and a reading older than two sweeps are both ignored rather than annotating
    # the heartbeat with pressure that may have gone away long ago.
    # The annotated form keeps the
    # "heartbeat:" prefix, because fm-watch-arm.sh and fm-supervise-daemon.sh both
    # recognise an actionable heartbeat by that exact prefix; any other shape
    # would silently stop being a wake precisely while the host is under pressure.
    hb_reason=heartbeat
    if [ "$RESOURCE_INTERVAL" -gt 0 ] \
      && [ "$(age_of "$STATE/.resource-status")" -lt $(( RESOURCE_INTERVAL * 2 )) ]; then
      case "$(cat "$STATE/.resource-status" 2>/dev/null || true)" in
        degraded) hb_reason='heartbeat: host resources degraded' ;;
        critical) hb_reason='heartbeat: host resources critical' ;;
      esac
    fi
    if afk_daemon_owns_triage; then
      fm_wake_append heartbeat heartbeat "$hb_reason" || exit 1
      touch "$STATE/.last-heartbeat"
      wake "$hb_reason"
    elif heartbeat_scan_finds_actionable; then
      # Backstop: a captain-relevant status the per-wake path absorbed by mistake.
      # Enqueue first, then mark every captain-relevant status surfaced so the next
      # heartbeat does not re-fire them (enqueue-before-suppress preserved).
      fm_wake_append heartbeat heartbeat "$hb_reason" || exit 1
      touch "$STATE/.last-heartbeat"
      mark_all_captain_relevant_surfaced
      wake "$hb_reason"
    else
      touch "$STATE/.last-heartbeat"
      echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak"
      triage_log "absorbed heartbeat (no captain-relevant change)"
      # Schedule and backoff are advanced above, so the next heartbeat is bounded and
      # further out; a tick (when enabled) makes this quiet-fleet proof of life
      # visible once per heartbeat cadence instead of only in the debug log. Only
      # while work is under way: with nothing in flight nothing forces a re-arm, so
      # an idle home keeps absorbing silently and its watcher self-sustains.
      fm_supervision_status "$STATE"
      if [ "$FM_SUP_IN_FLIGHT" -gt 0 ]; then
        absorb_tick "heartbeat absorbed"
      fi
    fi
  fi

  # Terminal wait: a bounded native-event wait for push-capable homes (herdr),
  # else the blind poll sleep. See event_wait_or_sleep.
  event_wait_or_sleep
done
