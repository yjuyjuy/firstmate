#!/usr/bin/env bash
# Send one line of literal text to a crewmate endpoint, then Enter.
# Usage: fm-send.sh <target> <text...>
#   <target> may be an exact task id, a legacy fm-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit well-formed backend
#   target. fm-send refuses unresolved guesses rather than falling back to a
#   tmux window search, because a "successful" send to the wrong endpoint is
#   worse than a loud failure.
# Special keys instead of text: fm-send.sh <target> --key Enter
# Key support is backend-specific: tmux/herdr support Escape, Enter, and C-c;
# Orca currently supports Enter and C-c only, and rejects Escape.
#
# Text submission is verified: the line is typed ONCE, then Enter is sent and
# retried (Enter only, never retyped) until the target backend confirms a
# submit or reports an inconclusive send. If a swallowed Enter is positively
# confirmed, fm-send exits NON-ZERO so the caller knows the steer did not land
# instead of silently leaving an unsubmitted instruction.
# Submission dispatches through the target's recorded backend; the tmux adapter
# shares its composer/submit core with the away-mode daemon via bin/fm-tmux-lib.sh.
# Tune with FM_SEND_RETRIES (default 3) / FM_SEND_SLEEP (0.4).
# Slash commands, and codex `$...` skill invocations resolved through harness
# meta, get a longer pre-Enter settle so completion popups do not swallow Enter.
#
# From-firstmate marker: when the resolved target is a task selector whose meta
# records kind=secondmate, the text uses the live-charter-compatible
# from-firstmate carrier owned by bin/fm-operational-input.sh so the secondmate
# routes its reply via its status file or a status-pointed doc instead of
# stranding it in chat the main firstmate never reads. A crewmate/scout target,
# an explicit backend-target escape-hatch target, and the --key path are never
# marked - their behavior is unchanged. A leading-slash CONTROL directive
# ("/model ...", "/effort ...", "/no-mistakes") is also delivered unmarked, even
# to a secondmate target, so the slash reaches column 0 and the harness runs it;
# see the slash-command carve-out at the classification site below for the why.
#
# Parent-owned pending-reply expectation: every newly marked secondmate request
# also receives a privacy-safe correlation id and a durable parent record under
# state/pending-replies/ before delivery (bin/fm-pending-reply-lib.sh). Delivery
# success and reply success are separate facts: a successful submit never
# resolves the expectation. Set FM_PENDING_REPLY_EXISTING_CORR=<id> when
# re-sending a recovery request for an already-open expectation so a second
# record is not created. Direct unmarked captain input never creates one.
#
# One-way secondmate messages: a nudge or control message that expects no
# correlated reply (a re-read-your-AGENTS nudge, a config-reread pointer) must
# not open a pending-reply expectation, or the parent keeps re-escalating a
# message that was actually delivered. Set FM_SEND_NO_REPLY_EXPECTED=1 to keep
# the from-firstmate reply-routing marker (so the secondmate still routes any
# volunteered reply through its status channel) while creating no correlation id
# and no durable pending record. Ordinary reply-expected secondmate requests
# leave the variable unset and keep the correlation and expectation unchanged.
#
# After a successful text submit fm-send pauses FM_SEND_SETTLE seconds (default 1,
# 0 disables) before returning: submit confirmation only proves the text was
# accepted, but the harness needs a beat to spin up the turn before its busy
# footer appears, so an immediate peek would otherwise see the stale idle pane.
# The pause is fm-send-only; the shared submit core (used by the away-mode daemon,
# which only needs "submitted") does not pay it, and the --key path is unaffected.
# Home resolution: an explicit FM_HOME always wins. When FM_HOME is unset or
# empty, fm-send defaults it to the current working directory IF that directory
# is a valid firstmate home (data/, state/, config/ and AGENTS.md present);
# anywhere else it refuses loudly, so a steer can never silently resolve
# against another home.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never steer
# a crewmate (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

fm_send_is_valid_home() {  # <dir>
  [ -d "$1/data" ] && [ -d "$1/state" ] && [ -d "$1/config" ] && [ -f "$1/AGENTS.md" ]
}

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  if fm_send_is_valid_home "$PWD"; then
    FM_HOME=$PWD
  else
    echo "error: FM_HOME is not set and the current directory is not a firstmate home; fm-send refuses to resolve targets without an explicit firstmate home" >&2
    exit 1
  fi
fi

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
if [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME '$FM_HOME' is not a directory; fm-send cannot resolve this home's state" >&2
  exit 1
fi
if [ ! -d "$STATE" ]; then
  echo "error: state dir '$STATE' is missing; fm-send cannot resolve targets for FM_HOME '$FM_HOME'" >&2
  exit 1
fi

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-telemetry-lib.sh
. "$SCRIPT_DIR/fm-telemetry-lib.sh"

FM_GUARD_CONTINUE_LINE='This is a supervision warning only; the requested message WILL still be sent.' "$SCRIPT_DIR/fm-guard.sh" || true

fm_send_id_from_meta() {  # <meta-file>
  local base
  base=${1##*/}
  printf '%s' "${base%.meta}"
}

fm_send_meta_for_key_value() {  # <state-dir> <key> <value>
  local state=$1 key=$2 value=$3 meta got
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    got=$(fm_meta_get "$meta" "$key")
    [ "$got" = "$value" ] || continue
    printf '%s' "$meta"
    return 0
  done
  return 1
}

fm_send_count_colons() {  # <string>
  local s=$1 no_colons
  no_colons=${s//:/}
  printf '%s' $(( ${#s} - ${#no_colons} ))
}

fm_send_resolve_target() {  # <raw-target>
  local raw=$1 meta pane_meta target backend assumed colons id session hint

  RESOLVED_TARGET=""
  TARGET_BACKEND=""
  TARGET_HARNESS=""
  EXPECTED_LABEL=""
  TARGET_META=""
  TARGET_SELECTOR=""
  RESOLUTION_TRIED=""

  meta=$(fm_backend_meta_for_selector "$raw" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    RESOLUTION_TRIED="meta=$meta; backend=from-meta"
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then
      echo "error: no backend target recorded in $meta (tried $RESOLUTION_TRIED)" >&2
      return 1
    fi
    backend=$(fm_backend_of_meta "$meta")
    RESOLVED_TARGET=$target
    TARGET_BACKEND=$backend
    TARGET_META=$meta
    TARGET_HARNESS=$(fm_meta_get "$meta" harness)
    EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$raw" "$STATE")
    TARGET_SELECTOR=1
    return 0
  fi

  case "$raw" in
    fm-*)
      RESOLUTION_TRIED="meta=$STATE/$raw.meta; legacy-meta=$STATE/${raw#fm-}.meta; backend=none"
      echo "error: no metadata for $raw in $STATE (tried $RESOLUTION_TRIED); pass a well-formed explicit backend target only when targeting outside this firstmate home" >&2
      return 1
      ;;
  esac

  pane_meta=$(fm_send_meta_for_key_value "$STATE" herdr_pane_id "$raw" 2>/dev/null || true)
  if [ -n "$pane_meta" ]; then
    session=$(fm_meta_get "$pane_meta" herdr_session)
    hint="${session:-<herdr-session>}:$raw"
    id=$(fm_send_id_from_meta "$pane_meta")
    echo "error: target '$raw' matches herdr_pane_id in $pane_meta but is missing its herdr session prefix; expected <herdr-session>:<pane-id> such as '$hint' or use 'fm-$id' (tried meta=$STATE/$raw.meta; backend=herdr)" >&2
    return 1
  fi

  meta=$(fm_backend_meta_for_window "$raw" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then
      echo "error: no backend target recorded in $meta (tried explicit target '$raw' via recorded window/terminal; backend=from-meta)" >&2
      return 1
    fi
    RESOLVED_TARGET=$target
    TARGET_BACKEND=$(fm_backend_of_meta "$meta")
    TARGET_META=$meta
    TARGET_HARNESS=$(fm_meta_get "$meta" harness)
    RESOLUTION_TRIED="explicit target '$raw' matched $meta; backend=$TARGET_BACKEND"
    return 0
  fi

  case "$raw" in
    *:*)
      colons=$(fm_send_count_colons "$raw")
      if [ "$colons" -ge 2 ]; then
        assumed=herdr
      else
        assumed=tmux
      fi
      if ! fm_backend_target_exists "$assumed" "$raw"; then
        echo "error: explicit target '$raw' is not a live $assumed endpoint (tried meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=$assumed). Use fm-<id> for a recorded task/lane, or pass a target whose backend endpoint can be verified." >&2
        return 1
      fi
      RESOLVED_TARGET=$raw
      TARGET_BACKEND=$assumed
      RESOLUTION_TRIED="meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=$assumed; endpoint=verified"
      return 0
      ;;
  esac

  echo "error: target '$raw' is not resolvable (tried meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=none). Use fm-$raw for a recorded task/lane, or pass a well-formed explicit backend target such as session:window." >&2
  return 1
}

RAW_TARGET=$1
fm_send_resolve_target "$RAW_TARGET" || exit 1
T=$RESOLVED_TARGET
shift

fm_backend_validate "$TARGET_BACKEND" || exit 1

# Classify a from-firstmate -> secondmate request. Only a task selector resolved
# through this home's meta whose authoritative kind is secondmate is marked: the
# secondmate then routes its reply via the status path (see fm-marker-lib.sh).
# An explicit backend target (the escape hatch for endpoints outside this home)
# and any crewmate/scout target are left unmarked, and so is the --key path.
#
# Slash-command carve-out: a leading-slash message ("/model ...", "/effort ...",
# "/no-mistakes") is a harness CONTROL directive, not an agent request. It must
# reach the composer with the slash at column 0 or the target harness treats it
# as plain text, and the from-firstmate carrier ("[fm-from-firstmate]<sep>corr=")
# prepended ahead of the body would break that. The reply-routing contract does
# not apply either: a control directive spins up no agent turn and produces no
# correlated status reply, so a pending-reply expectation on it could never be
# resolved and would falsely trip recovery/escalation. So a slash-command send is
# delivered UNMARKED even to a secondmate target, with no pending-reply record.
# This is a deliberate, documented resolution of a genuine conflict, not a silent
# drop: ordinary (non-slash) secondmate messages keep the carrier and pending
# expectation unchanged.
MARK_FROM_FIRSTMATE=0
PENDING_REPLY_CORR=
PENDING_REPLY_CREATED=0
TARGET_TASK_ID=
MESSAGE_IS_SLASH_COMMAND=0
MARK_NO_REPLY_EXPECTED=0
case "${FM_SEND_NO_REPLY_EXPECTED:-}" in
  1|true|yes) MARK_NO_REPLY_EXPECTED=1 ;;
esac
case "$*" in
  /*) MESSAGE_IS_SLASH_COMMAND=1 ;;
esac
if [ "$MESSAGE_IS_SLASH_COMMAND" = 0 ] \
  && [ -n "$TARGET_SELECTOR" ] && [ -n "$TARGET_META" ] \
  && [ "$(fm_meta_get "$TARGET_META" kind)" = secondmate ]; then
  MARK_FROM_FIRSTMATE=1
  TARGET_TASK_ID=$(fm_send_id_from_meta "$TARGET_META")
fi

# Resolve the target's harness from its meta (recorded by fm-spawn), used only to
# scope the codex `$<skill>` popup-settle below. A task selector carries
# meta; an explicit backend-target escape hatch has none, so its harness is
# unknown and treated as non-codex (the safe default that keeps the fast path).
# The target's BACKEND comes from selector meta, from matching an explicit target
# back to recorded meta, or from strict explicit-target shape validation.
# Do not add a separate passive liveness preflight here. Active send paths own
# backend readiness: herdr, for example, must route through its session-aware
# target_ready path before sending, while zellij verifies pane labels in its
# send implementation. A failed backend send is still surfaced below as a hard
# error with the attempted resolution attached.

if [ "${1:-}" = "--key" ]; then
  if ! fm_backend_send_key "$TARGET_BACKEND" "$T" "$2" "$EXPECTED_LABEL"; then
    echo "error: key '$2' not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
    exit 1
  fi
else
  MESSAGE=$*
  if [ "$MARK_FROM_FIRSTMATE" = 1 ] && [ "$MARK_NO_REPLY_EXPECTED" = 1 ]; then
    # One-way secondmate message (nudge / control pointer): keep the
    # from-firstmate reply-routing marker so a volunteered reply still lands on
    # the status channel, but open no correlation id and no pending record - the
    # message expects no correlated report, so an expectation could never resolve
    # and would falsely trip recovery/escalation (see header).
    fm_message_mark_from_firstmate "$MESSAGE" MESSAGE
  elif [ "$MARK_FROM_FIRSTMATE" = 1 ]; then
    # Reuse an existing correlation id for recovery resends; otherwise create a
    # durable parent expectation before delivery. Transport success never
    # resolves that expectation (see fm-pending-reply-lib.sh).
    existing_corr=${FM_PENDING_REPLY_EXISTING_CORR:-$(fm_pending_reply_extract_corr "$MESSAGE")}
    if [ -n "$existing_corr" ] \
      && fm_pending_reply_corr_reusable "$STATE" "$existing_corr" "$TARGET_TASK_ID"; then
      PENDING_REPLY_CORR=$existing_corr
    else
      if [ -z "$TARGET_TASK_ID" ]; then
        echo "error: cannot create pending-reply expectation without a resolvable secondmate task id" >&2
        exit 1
      fi
      PENDING_REPLY_CORR=$(fm_pending_reply_create "$FM_HOME" "$STATE" "$TARGET_TASK_ID" "$MESSAGE") \
        || { echo "error: failed to create parent pending-reply expectation for $TARGET_TASK_ID" >&2; exit 1; }
      PENDING_REPLY_CREATED=1
    fi
    fm_pending_reply_embed_corr "$MESSAGE" "$PENDING_REPLY_CORR" MESSAGE
    if [ "$PENDING_REPLY_CREATED" = 1 ] \
      && ! fm_pending_reply_prepare_delivery "$STATE" "$PENDING_REPLY_CORR"; then
      fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
      echo "error: failed to durably prepare pending-reply delivery for $TARGET_TASK_ID" >&2
      exit 1
    fi
  fi
  # Slash commands open a completion popup in some TUIs (verified on codex);
  # submitting too fast selects nothing, so give the popup time to settle before
  # the (retried) Enter. Codex opens the same kind of popup for a `$<skill>`
  # invocation, so a `$...` message to a codex target gets the same settle. That
  # `$` case is scoped to codex on purpose: unlike `/`, a leading `$` commonly
  # starts ordinary text ("$5/month", "$HOME"), so a universal `$` rule would
  # needlessly slow plain text to claude/opencode/pi. The target backend's
  # verified submit retry still backs the settle up either way.
  case "$*" in
    /*) settle=1.2 ;;
    \$*)
      if [ "$TARGET_HARNESS" = codex ]; then settle=1.2; else settle=0.3; fi
      ;;
    *) settle=0.3 ;;
  esac
  retries=${FM_SEND_RETRIES:-3}
  sleep_s=${FM_SEND_SLEEP:-0.4}
  # Type once, submit, verify. Lenient by default: only a positively-confirmed
  # swallow (text still in the composer) is an error; an unreadable pane is
  # assumed sent. The one exception lives in the backend, not here: the herdr
  # adapter folds an unconfirmable read into `pending` (fail-closed, task
  # herdr-send-submit-gap), so a herdr steer whose confirmation cannot be
  # determined exits non-zero instead of claiming success - the jcode
  # false-positive that left a live steer unsubmitted in the composer while
  # fm-send reported it delivered. The caller-facing verdict vocabulary stays
  # backend-identical, so this branch remains backend-agnostic.
  if ! verdict=$(fm_backend_send_text_submit "$TARGET_BACKEND" "$T" "$MESSAGE" "$retries" "$sleep_s" "$settle" "$EXPECTED_LABEL"); then
    if [ "$PENDING_REPLY_CREATED" = 1 ] && [ -n "$PENDING_REPLY_CORR" ]; then
      fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
    fi
    echo "error: text not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
    exit 1
  fi
  case "$verdict" in
    pending)
      if [ "$PENDING_REPLY_CREATED" = 1 ] && [ -n "$PENDING_REPLY_CORR" ]; then
        fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
      fi
      echo "error: text not submitted to $T (Enter swallowed; text left in composer; tried $RESOLUTION_TRIED)" >&2
      exit 1
      ;;
    send-failed)
      if [ "$PENDING_REPLY_CREATED" = 1 ] && [ -n "$PENDING_REPLY_CORR" ]; then
        fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
      fi
      echo "error: text not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
      exit 1
      ;;
  esac
  # Delivery confirmed. Mark the pending expectation delivered without resolving
  # it: only a correlated parent report acknowledges the request.
  if [ -n "$PENDING_REPLY_CORR" ]; then
    if fm_pending_reply_confirm_delivery "$STATE" "$PENDING_REPLY_CORR"; then
      :
    else
      delivery_commit_status=$?
      if [ "$delivery_commit_status" = 2 ]; then
        echo "error: text was delivered to $T, but its pending-reply delivery commit failed; a durable recovery marker was stored and the watcher will reconcile it. Do not resend." >&2
      else
        echo "error: text was delivered to $T, but its pending-reply delivery commit and recovery marker both failed. Do not resend; inspect $STATE manually." >&2
      fi
      exit 1
    fi
  fi
  # Visibility Gap-4: record this steer on the target task's telemetry so the
  # watcher's stale loop can detect a pane that never processes it (a silent
  # composer-stuck; see data/design-visibility-improvements/report.md "Gap 4").
  # Only a CONFIRMED text submit stamps - every failure path above has already
  # exited, so a failed or unconfirmed send never writes. An explicit endpoint
  # with no recorded meta has no per-task telemetry to write, which is the same
  # silent-when-absent contract the watcher reader uses (fail-soft).
  if [ -n "$TARGET_META" ]; then
    fm_telemetry_set "$STATE/$(fm_send_id_from_meta "$TARGET_META").telemetry" last_steer_ts "$(date +%s)" || true
  fi
  # Submit landed (verdict was not pending/send-failed). Confirmation only proves
  # the text was accepted; the harness still needs a beat to spin up the
  # turn before its busy footer shows. Pause so an immediate peek catches the
  # crewmate actually working instead of the stale idle pane. FM_SEND_SETTLE=0
  # disables it. Scoped to this path only, never the shared submit core.
  [ "${FM_SEND_SETTLE:-1}" = 0 ] || sleep "${FM_SEND_SETTLE:-1}"
fi
