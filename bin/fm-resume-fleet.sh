#!/usr/bin/env bash
# fm-resume-fleet.sh - resume every live lane in this home with a PACED, VERIFIED
# stagger, so a bulk re-warm never bursts a provider's per-minute rate limit.
#
# WHY this exists (incident 2026-08-25): after an account rotation the fleet's
# prompt caches are cold, so each lane's first turn re-sends its full ~120-180K
# context. Firing a resume steer into every lane at once made five cold-cache
# turns start in the same instant and tripped the claude-1 account's per-minute
# rate limit - 147 HTTP 429s in about two minutes. The fix is mechanical: start
# the lanes' turns ONE AT A TIME, verify each turn actually started before moving
# on, and hold a jittered 60-90s gap between starts so at most one big cold-cache
# request lands per minute. Pacing the STARTS is what keeps the per-minute budget
# from being spent in a single burst.
#
# Usage:
#   fm-resume-fleet.sh [--priority <id>] [--message <text>] [--dry-run]
#   fm-resume-fleet.sh --help
#
#   --priority <id>   resume this lane FIRST, before the rest (e.g. the lane the
#                     captain is actively watching). May also be written
#                     --priority=<id>. A lane whose meta records priority= (any
#                     non-empty, non-0/off/no/false value) is also promoted ahead
#                     of ordinary lanes; an explicit --priority id wins over that.
#   --message <text>  override the resume steer text sent to each lane. The token
#                     {id} in the text is replaced with the lane's task id. May
#                     also be written --message=<text>. Default: a concise
#                     "continue your task" re-warm nudge (see RESUME_MESSAGE).
#   --dry-run         print the resolved order and the per-lane plan (who would be
#                     sent, who would be skipped and why) WITHOUT sending anything
#                     or sleeping. Nothing is written to any lane.
#   --help            print this help and exit 0.
#
# LANE SET: the supervised ship/scout lanes recorded in this home's state/<id>.meta
# (the same per-task metadata every other fm-* script reads via fm_backend_of_meta
# / fm_backend_target_of_meta). Deliberately SKIPPED, never an error:
#   - a meta with no resolvable backend target (a service sidecar such as
#     state/.lavish-lan.meta records only port=/bind=/target=);
#   - kind=secondmate (a secondmate's idle endpoint is healthy by contract and it
#     acts only on routed work - poking it with a "continue" steer is wrong);
#   - supervise=off (a --unsupervised pane the operator asked firstmate to leave
#     alone; its owner re-warms it).
# The re-warm targets exactly the lanes that a fleet account switch just moved and
# that firstmate supervises, which is the set at risk of the simultaneous cold
# burst this script exists to pace.
#
# PER-LANE GUARD (mirrors bin/fm-switch-account.sh, reusing the SAME backend
# primitives - never re-implementing composer probing):
#   1. Dead/unreadable endpoint (fm_backend_target_exists false) -> SKIP: a dead
#      pane is stuck-crewmate recovery's job, not a re-warm target.
#   2. Already mid-turn (lane_is_busy) -> SKIP: never double-poke a lane whose
#      turn is already running. This is what makes the script IDEMPOTENT and safe
#      to re-run - a second run right after the first finds most lanes busy and
#      returns fast, poking none of them twice.
#   3. Composer holds genuine pending human text after one Escape, or reads
#      unknown (dead/non-agent pane) -> SKIP (never garble real typing, never
#      blind-inject a dead shell), exactly as fm-switch-account does.
#   4. Otherwise SEND the resume steer through fm_backend_send_text_submit and
#      VERIFY a new turn actually started (below) before advancing.
#
# VERIFY-BEFORE-ADVANCE: after sending, poll up to FM_RESUME_VERIFY_TIMEOUT
# seconds for positive evidence the turn started - either a busy/working indicator
# (fm_backend_busy_state, else the shared busy-footer regex over a bounded capture)
# OR a fresh append to the lane's status file. Confirmation short-circuits the
# wait. If neither appears within the bound the lane is ESCALATED, never silently
# dropped: a clearly-attributed blocked: line is appended to its status file (so
# supervision sees a durable, actionable record) and it is listed under FAILED in
# this script's summary. The remaining lanes still run, so one wedged lane never
# blocks the whole fleet re-warm.
#
# PACING: a jittered gap of FM_RESUME_MIN_GAP..FM_RESUME_MAX_GAP seconds (default
# 60..90, randomized per gap, not a fixed sleep) is held BEFORE every send after
# the first, so N actual sends produce N-1 gaps - always between real requests,
# never after a skip and never a wasted trailing wait.
#
# EXIT: 0 when every lane either confirmed a fresh turn or was safely skipped
# (including "nothing to resume"); 2 on a usage error; 3 when at least one lane
# failed to confirm a turn (some lanes need attention - the account switch itself,
# when chained from fm-switch-account.sh --resume, still succeeded regardless).
#
# TEST SEAMS (all optional; the defaults are the live path):
#   FM_HOME                    home whose state/ is resumed (default: repo root).
#   FM_STATE_OVERRIDE          state dir override (default: $FM_HOME/state).
#   FM_RESUME_MIN_GAP / _MAX_GAP  pacing window bounds in seconds (default 60/90;
#                              set both to 0 to disable the wait in a test).
#   FM_RESUME_SLEEP_CMD        the pacing sleep command (default: sleep; a test
#                              stubs it to capture the chosen gap without waiting).
#   FM_RESUME_VERIFY_TIMEOUT   bounded verify wait in seconds (default 20).
#   FM_RESUME_VERIFY_POLL      verify poll interval in seconds (default 2).
#   FM_RESUME_VERIFY_SLEEP_CMD verify poll sleep command (default: sleep).
#   FM_RESUME_SEND_SETTLE      per-send settle passed to the backend (default 1).
#   FM_RESUME_CLEAR_SETTLE     settle between an Escape and the composer re-check
#                              (default 0.5).
#   FM_RESUME_MESSAGE          default resume steer text (also set with --message).
#   FM_BUSY_REGEX              busy-footer regex (owned by bin/fm-tmux-lib.sh's
#                              FM_TMUX_BUSY_REGEX_DEFAULT; overridable fleet-wide).
#
# SAFETY: this only re-warms live lanes with a reversible steer. It never edits
# auth.json, never restarts a server, never touches project code, and never force
# anything. A lane it cannot safely poke is skipped, not overwritten.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
here="$(cd "$script_dir/.." && pwd)"
cd "$here"

# shellcheck source=bin/fm-tmux-lib.sh
. "$script_dir/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$script_dir/fm-backend.sh"

# Home / state resolution: an explicit FM_HOME wins; otherwise the repo root is
# the home (a real firstmate home IS its checkout root, with state/ beside it).
FM_HOME="${FM_HOME:-$here}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# Pacing window (seconds). Randomized per gap within [min,max] so the per-minute
# budget is never spent in one burst.
min_gap="${FM_RESUME_MIN_GAP:-60}"
max_gap="${FM_RESUME_MAX_GAP:-90}"
sleep_cmd="${FM_RESUME_SLEEP_CMD:-sleep}"
# Verify-before-advance bounds.
verify_timeout="${FM_RESUME_VERIFY_TIMEOUT:-20}"
verify_poll="${FM_RESUME_VERIFY_POLL:-2}"
verify_sleep_cmd="${FM_RESUME_VERIFY_SLEEP_CMD:-sleep}"
# Per-send pacing passed through to the backend submit path.
send_settle="${FM_RESUME_SEND_SETTLE:-1}"
clear_settle="${FM_RESUME_CLEAR_SETTLE:-0.5}"

# Default resume steer. {id} expands to the lane's task id at send time. One line:
# fm_backend_send_text_submit types a single line. Kept concise on purpose.
RESUME_MESSAGE="${FM_RESUME_MESSAGE:-Fleet resume (paced re-warm after account rotation): continue your task from where you left off. If you need your instructions again, re-read data/{id}/brief.md, then append a status line so supervision can see you working.}"

usage() {
  cat >&2 <<EOF
usage: $0 [--priority <id>] [--message <text>] [--dry-run]
       $0 --help

  --priority <id>   resume this lane first, before the rest.
  --message <text>  override the resume steer ({id} -> the lane's task id).
  --dry-run         print the plan without sending or sleeping.
  --help            show this help and exit.
EOF
}

PRIORITY_ID=""
DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help | help)
      usage
      exit 0
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --priority)
      PRIORITY_ID="${2:-}"
      [ -n "$PRIORITY_ID" ] || { echo "error: --priority needs a lane id" >&2; usage; exit 2; }
      shift 2
      ;;
    --priority=*)
      PRIORITY_ID="${1#--priority=}"
      [ -n "$PRIORITY_ID" ] || { echo "error: --priority needs a lane id" >&2; usage; exit 2; }
      shift
      ;;
    --message)
      RESUME_MESSAGE="${2:-}"
      [ -n "$RESUME_MESSAGE" ] || { echo "error: --message needs text" >&2; usage; exit 2; }
      shift 2
      ;;
    --message=*)
      RESUME_MESSAGE="${1#--message=}"
      shift
      ;;
    -*)
      echo "error: unrecognized option '$1'" >&2
      usage
      exit 2
      ;;
    *)
      echo "error: unexpected argument '$1'" >&2
      usage
      exit 2
      ;;
  esac
done

if [ ! -d "$STATE" ]; then
  echo "error: state dir '$STATE' is missing; fm-resume-fleet cannot resolve lanes for FM_HOME '$FM_HOME'" >&2
  exit 2
fi

# file_bytes: byte length of <file>, 0 when it does not exist. Used to detect a
# fresh status-file append during verify without depending on stat's platform
# flags (wc -c is portable and reads the whole file, which the status log is
# small enough for).
file_bytes() {  # <file>
  local f=$1 n
  [ -f "$f" ] || { printf '0'; return 0; }
  n=$(wc -c < "$f" 2>/dev/null || printf '0')
  n=${n//[!0-9]/}
  printf '%s' "${n:-0}"
}

# lane_is_busy: 0 when <target> is mid-turn on <backend>. Prefers the backend's
# native busy state (herdr's agent.get); for a backend that reports unknown
# (tmux today) it falls back to the shared busy-footer regex over a bounded
# capture, mirroring fm-crew-state.sh's crew_pane_is_busy so the two cannot drift
# on what "busy" means. A capture that cannot be read is treated as not-busy
# (the caller then guards the composer before any send anyway).
lane_is_busy() {  # <backend> <target> <expected-label>
  local backend=$1 target=$2 expected=${3:-} bs tail
  bs=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null || printf 'unknown')
  case "$bs" in
    busy) return 0 ;;
    *)
      tail=$(fm_backend_capture "$backend" "$target" 40 "$expected" 2>/dev/null) || return 1
      printf '%s' "$tail" | grep -v '^[[:space:]]*$' | tail -6 \
        | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"
      ;;
  esac
}

# verify_turn_started: poll up to verify_timeout seconds for positive evidence a
# fresh turn started on <target> - a busy indicator OR a status-file append past
# <baseline_bytes>. Returns 0 as soon as either is seen (short-circuit), 1 on a
# clean timeout. verify_timeout=0 checks exactly once then times out, so a test
# can force the fail path without waiting.
verify_turn_started() {  # <backend> <target> <expected-label> <status-file> <baseline-bytes>
  local backend=$1 target=$2 expected=$3 status_file=$4 baseline=$5 now deadline cur
  now=$(date +%s)
  deadline=$(( now + verify_timeout ))
  while :; do
    if lane_is_busy "$backend" "$target" "$expected"; then
      return 0
    fi
    cur=$(file_bytes "$status_file")
    if [ "$cur" -gt "$baseline" ]; then
      return 0
    fi
    now=$(date +%s)
    [ "$now" -ge "$deadline" ] && return 1
    "$verify_sleep_cmd" "$verify_poll" || true
  done
}

# pick_gap: a fresh random integer in [min_gap, max_gap]. Guards a mis-ordered or
# non-numeric window by clamping to a single deterministic value rather than
# erroring, so a bad override can never wedge the pacing.
pick_gap() {
  local lo=$min_gap hi=$max_gap span
  case "$lo" in ''|*[!0-9]*) lo=60 ;; esac
  case "$hi" in ''|*[!0-9]*) hi=90 ;; esac
  [ "$hi" -ge "$lo" ] || hi=$lo
  span=$(( hi - lo + 1 ))
  printf '%s' "$(( lo + (RANDOM % span) ))"
}

# --- discover + order the lanes ---------------------------------------------

# Parallel arrays index-aligned by discovery: id / backend / target / priority.
ids=()
backends=()
targets=()
prios=()

while IFS= read -r metafile; do
  [ -f "$metafile" ] || continue
  id=$(basename "$metafile" .meta)
  # Skip a secondmate (idle by contract) and an --unsupervised pane (opt-out).
  [ "$(fm_meta_get "$metafile" kind)" = secondmate ] && continue
  [ "$(fm_meta_get "$metafile" supervise)" = off ] && continue
  backend=$(fm_backend_of_meta "$metafile" 2>/dev/null || true)
  # A meta with no resolvable target (a service sidecar) is not a lane. `|| true`
  # keeps that expected miss from tripping set -e/pipefail.
  target=$(fm_backend_target_of_meta "$metafile" 2>/dev/null || true)
  [ -n "$target" ] || continue
  prio=$(fm_meta_get "$metafile" priority 2>/dev/null || true)
  ids+=("$id")
  backends+=("${backend:-tmux}")
  targets+=("$target")
  prios+=("$prio")
done < <(find "$STATE" -maxdepth 1 -name '*.meta' 2>/dev/null | sort)

lane_count=${#ids[@]}
if [ "$lane_count" -eq 0 ]; then
  echo "resume fleet: no resumable lanes found in $STATE (nothing to do)"
  exit 0
fi

# meta_priority_truthy: 0 when a recorded priority= value marks a lane as
# priority. Empty and the common "off" spellings are NOT priority.
meta_priority_truthy() {  # <value>
  case "$1" in
    ''|0|off|no|false|none) return 1 ;;
    *) return 0 ;;
  esac
}

# Build the resume order: an explicit --priority id first (when it is a real
# discovered lane), then any meta-priority lanes, then the rest. Discovery was
# id-sorted, so each bucket stays in stable id order.
order=()
seen_marker=" "
add_once() {  # <index>
  local i=$1
  case "$seen_marker" in
    *" $i "*) return 0 ;;
  esac
  order+=("$i")
  seen_marker="$seen_marker$i "
}

if [ -n "$PRIORITY_ID" ]; then
  matched=0
  for i in "${!ids[@]}"; do
    [ "${ids[$i]}" = "$PRIORITY_ID" ] || continue
    add_once "$i"
    matched=1
  done
  [ "$matched" = 1 ] || echo "resume fleet: note: --priority '$PRIORITY_ID' is not a resumable lane here; ignoring" >&2
fi
for i in "${!ids[@]}"; do
  meta_priority_truthy "${prios[$i]}" && add_once "$i"
done
for i in "${!ids[@]}"; do
  add_once "$i"
done

# --- dry-run: print the plan and stop ---------------------------------------

if [ "$DRY_RUN" = 1 ]; then
  echo "resume fleet (dry-run): $lane_count lane(s), order:"
  for i in "${order[@]}"; do
    printf '  %s  backend=%s  target=%s%s\n' \
      "${ids[$i]}" "${backends[$i]}" "${targets[$i]}" \
      "$(meta_priority_truthy "${prios[$i]}" && printf ' [priority]' || true)"
  done
  exit 0
fi

# --- resume, one lane at a time ---------------------------------------------

confirmed=()
skipped=()
failed=()
first_send=1

for i in "${order[@]}"; do
  id="${ids[$i]}"
  backend="${backends[$i]}"
  target="${targets[$i]}"
  expected="fm-$id"
  status_file="$STATE/$id.status"

  # 1. Dead/unreadable endpoint: recovery's job, not a re-warm target.
  if ! fm_backend_target_exists "$backend" "$target" "$expected" 2>/dev/null; then
    echo "  $id: SKIPPED - endpoint not live ($backend $target)"
    skipped+=("$id (dead endpoint)")
    continue
  fi

  # 2. Already mid-turn: never double-poke (idempotent re-run safety).
  if lane_is_busy "$backend" "$target" "$expected"; then
    echo "  $id: SKIPPED - already mid-turn (not double-poking)"
    skipped+=("$id (already busy)")
    continue
  fi

  # 3. Composer guard: never garble pending human text, never inject a dead pane.
  state=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null || echo unknown)
  if [ "$state" = pending ]; then
    fm_backend_send_key "$backend" "$target" Escape 2>/dev/null || true
    sleep "$clear_settle" || true
    state=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null || echo unknown)
    if [ "$state" = pending ]; then
      echo "  $id: SKIPPED - composer still has pending text after Escape (not overwriting)"
      skipped+=("$id (pending human input)")
      continue
    fi
  fi
  if [ "$state" = unknown ]; then
    echo "  $id: SKIPPED - composer state unknown (dead/non-agent pane)"
    skipped+=("$id (unknown composer)")
    continue
  fi

  # Pace BEFORE every send after the first: N sends -> N-1 jittered gaps, always
  # between real requests, never after a skip and never a trailing wait.
  if [ "$first_send" = 0 ]; then
    gap=$(pick_gap)
    echo "  pacing ${gap}s before next lane (jittered ${min_gap}-${max_gap}s)"
    "$sleep_cmd" "$gap" || true
  fi
  first_send=0

  message="${RESUME_MESSAGE//\{id\}/$id}"
  baseline=$(file_bytes "$status_file")

  verdict=$(fm_backend_send_text_submit "$backend" "$target" "$message" \
    3 "$send_settle" "$send_settle" "$expected" 2>/dev/null) || verdict=send-failed
  case "$verdict" in
    pending | send-failed | unknown)
      echo "  $id: send did not land (verdict=${verdict:-unknown})"
      # A send that never landed did not spend budget; treat it as a failed lane
      # (needs attention) but keep the pacing gate honest by NOT counting it as a
      # started turn. Re-arm first_send so the next lane is not wrongly paced
      # against a request that never fired.
      first_send=1
      msg="blocked: [fm-resume-fleet] resume steer did not submit (verdict=${verdict:-unknown}); lane may be wedged"
      printf '%s\n' "$msg" >> "$status_file" 2>/dev/null || true
      failed+=("$id (send $verdict)")
      continue
      ;;
  esac
  echo "  $id: resume steer sent, verifying turn start..."

  if verify_turn_started "$backend" "$target" "$expected" "$status_file" "$baseline"; then
    echo "  $id: confirmed - new turn started"
    confirmed+=("$id")
  else
    echo "  $id: FAILED - no new turn confirmed within ${verify_timeout}s"
    msg="blocked: [fm-resume-fleet] no new turn confirmed within ${verify_timeout}s after paced resume steer (lane may be wedged)"
    printf '%s\n' "$msg" >> "$status_file" 2>/dev/null || true
    failed+=("$id (no turn in ${verify_timeout}s)")
  fi
done

# --- summary ----------------------------------------------------------------

echo "resume fleet: ${#confirmed[@]} confirmed, ${#skipped[@]} skipped, ${#failed[@]} failed (of $lane_count lane(s))"
[ "${#confirmed[@]}" -gt 0 ] && echo "  confirmed: ${confirmed[*]}"
[ "${#skipped[@]}" -gt 0 ] && echo "  skipped:   ${skipped[*]}"
if [ "${#failed[@]}" -gt 0 ]; then
  echo "  FAILED:    ${failed[*]}"
  exit 3
fi
exit 0
