#!/usr/bin/env bash
# fm-jcode-repin.sh - re-pin a live jcode lane's model/effort to the profile its
# task meta records, then confirm it against the session store. This is the
# drift-response counterpart to the spawn-time pin in bin/fm-spawn.sh: when the
# watcher fires a `check: model-drift <id>` wake (the live session store
# disagrees with the meta), firstmate runs this to re-apply the intended profile.
#
# WHY this exists (the busy re-send fix): a typed /model|/effort sent to a lane
# whose turn is in flight is DEFERRED behind the agent lock and, if fired once
# and forgotten, never applies - the exact failure the ticket cites. This script
# re-pins through jcode's debug socket instead
# (`jcode debug -S <sid> set_model:{"model":..,"effort":..}`), which runs
# server-side under `agent.lock().await`: a call issued while a turn is running
# WAITS for the turn and then applies, so the re-pin lands on the next idle
# moment rather than being dropped. It is then VERIFIED against the session store
# (the only truth), with bounded retries, exactly as the spawn-time pin is. See
# bin/fm-jcode-profile-lib.sh for the shared apply+verify seam and the full race
# analysis.
#
# Usage: fm-jcode-repin.sh <task-id>
#   Reads state/<id>.meta for harness=jcode, the recorded model=/effort=, and the
#   session_id (or resolves it from worktree=). Re-pins and verifies. On success
#   prints a one-line confirmation and returns 0. On failure prints an actionable
#   diagnostic and returns nonzero, so a caller escalates rather than assuming the
#   re-pin worked.
#
# Fail-closed: a non-jcode task, a default profile (nothing to pin), an
# unresolvable session, or an unreadable store all stop with a clear message and
# a nonzero exit rather than silently pretending to re-pin.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') echo "error: a task id is required (usage: fm-jcode-repin.sh <task-id>)" >&2; exit 2 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# fm_meta_get lives in bin/fm-backend.sh (sourcing it is side-effect free).
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-token-sessions-lib.sh
. "$SCRIPT_DIR/fm-token-sessions-lib.sh"
# shellcheck source=bin/fm-jcode-profile-lib.sh
. "$SCRIPT_DIR/fm-jcode-profile-lib.sh"

# Bounded verification, same knobs as the spawn-time pin.
FM_SPAWN_JCODE_VERIFY_TRIES=${FM_SPAWN_JCODE_VERIFY_TRIES:-3}
FM_SPAWN_JCODE_VERIFY_SETTLE=${FM_SPAWN_JCODE_VERIFY_SETTLE:-3}

ID=$1
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task '$ID' at $META" >&2; exit 1; }

HARNESS=$(fm_meta_get "$META" harness 2>/dev/null || true)
[ "$HARNESS" = jcode ] || { echo "error: task '$ID' is harness=$HARNESS, not jcode; nothing to re-pin" >&2; exit 1; }

MODEL=$(fm_meta_get "$META" model 2>/dev/null || true)
EFFORT=$(fm_meta_get "$META" effort 2>/dev/null || true)
[ "$MODEL" = default ] && MODEL=
[ "$EFFORT" = default ] && EFFORT=
WANT_MODEL=${MODEL:--}
WANT_EFFORT=${EFFORT:--}
if [ "$WANT_MODEL" = - ] && [ "$WANT_EFFORT" = - ]; then
  echo "error: task '$ID' records a default profile; there is nothing to pin" >&2
  exit 1
fi

SID=$(fm_meta_get "$META" session_id 2>/dev/null || true)
if [ -z "$SID" ]; then
  WORKTREE=$(fm_meta_get "$META" worktree 2>/dev/null || true)
  [ -n "$WORKTREE" ] || { echo "error: task '$ID' has no session_id and no worktree to resolve one; cannot re-pin" >&2; exit 1; }
  SID=$(fm_resolve_crew_session_id "$WORKTREE" "" 2>/dev/null || true)
fi
[ -n "$SID" ] || { echo "error: could not resolve a jcode session id for task '$ID'; cannot re-pin" >&2; exit 1; }

if CONFIRMED=$(fm_jcode_pin_and_verify "$SID" "$WANT_MODEL" "$WANT_EFFORT" \
    "$FM_SPAWN_JCODE_VERIFY_TRIES" "$FM_SPAWN_JCODE_VERIFY_SETTLE"); then
  CONF_MODEL='' CONF_EFFORT=''
  while IFS= read -r kv; do
    case "$kv" in
      model=*) CONF_MODEL=${kv#model=} ;;
      effort=*) CONF_EFFORT=${kv#effort=} ;;
    esac
  done <<EOF
$CONFIRMED
EOF
  echo "re-pinned $ID: store confirms model=${CONF_MODEL:--} effort=${CONF_EFFORT:--} (wanted ${WANT_MODEL}/${WANT_EFFORT})"
  exit 0
fi

# The re-pin did not verify. Read the store once for the diagnostic.
PROFILE=$(fm_session_store_profile "$SID" 2>/dev/null || true)
ACT_MODEL='' ACT_EFFORT=''
while IFS= read -r kv; do
  case "$kv" in
    model=*) ACT_MODEL=${kv#model=} ;;
    effort=*) ACT_EFFORT=${kv#effort=} ;;
  esac
done <<EOF
$PROFILE
EOF
echo "error: re-pin of $ID did not verify after ${FM_SPAWN_JCODE_VERIFY_TRIES} attempts (wanted ${WANT_MODEL}/${WANT_EFFORT}, store shows ${ACT_MODEL:--}/${ACT_EFFORT:--}); escalate to the captain" >&2
exit 1
