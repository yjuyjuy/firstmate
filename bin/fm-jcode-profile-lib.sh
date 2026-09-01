#!/usr/bin/env bash
# jcode model/effort pin seam + pin-and-verify, the RELIABLE replacement for the
# TUI slash-command popup race that silently lost /model|/effort (incidents
# 2026-08-10 "verdict pending + brief raced ahead", 2026-08-23 "MODEL DRIFT
# INCIDENT": three tooling lanes ran the wrong model at max effort for hours, and
# 2026-08-11 data/learnings.md "jcode crew spawn: effort ... comes up ... High on
# 3 spawns, Low on 1"). Sourced by bin/fm-spawn.sh (spawn-time pin) and
# bin/fm-jcode-repin.sh (the drift-response re-pin). NEVER executed directly.
#
# Sourcing is SIDE-EFFECT FREE: it defines functions only, creates nothing, and
# runs no jcode command, so a read-only caller can source it safely. It depends
# on fm_session_store_profile from bin/fm-token-sessions-lib.sh; a caller sources
# that first.
#
# WHY the debug socket, not TUI slash commands: jcode exposes a debug-socket verb
#   jcode debug -S <session-id> 'set_model:{"model":<m>,"effort":<e>}'
# that applies model AND effort ATOMICALLY server-side. Two properties make it
# reliable where a typed /model|/effort is not:
#   1. It takes the agent lock with `agent.lock().await` (jcode-app-core
#      server/debug_command_exec.rs set_model branch -> agent.set_model_and_effort),
#      so a call issued WHILE A TURN IS RUNNING WAITS for the turn to finish and
#      then applies - it is never deferred-and-forgotten the way a typed
#      /model|/effort is (provider_control.rs handle_set_model spawns a deferred
#      mutation on a failed try_lock; submitting the brief starts a turn, so a
#      typed slash sent after it queues behind the lock and, if the caller moves
#      on, never lands). This is exactly the "retry-when-idle" the busy re-send
#      path needs, for free.
#   2. It persists to the session store immediately (set_reasoning_effort ->
#      session.save; set_model -> persist_session_best_effort) and returns the
#      APPLIED {model, provider, effort} as JSON with a nonzero exit on any
#      failure (unknown model, unsupported effort - the effort case rolls the
#      model back so the session is never left half-applied). There is no
#      slash-autocomplete popup to lose an Enter into and no pane echo to
#      misread: the store is ground truth and the call reports what it wrote.
#
# The store (~/.jcode/sessions/<sid>.json, fields `model` and `reasoning_effort`)
# stays the single verification oracle: after applying, the caller reads the store
# back through fm_session_store_profile and gates on THAT, so a future jcode
# change to the debug verb's return shape cannot mask a real drift.

# Resolve the jcode binary. FM_JCODE_BIN overrides it (tests inject a fake, and a
# non-standard install can point at its own path); otherwise the first `jcode` on
# PATH. Prints the resolved command word; returns 1 when none is found so the
# caller fails loud rather than pinning against a missing binary.
fm_jcode_bin() {
  if [ -n "${FM_JCODE_BIN:-}" ]; then
    printf '%s' "$FM_JCODE_BIN"
    return 0
  fi
  command -v jcode >/dev/null 2>&1 || return 1
  printf 'jcode'
  return 0
}

# fm_jcode_apply_profile: apply <model>/<effort> to session <sid> via the
# debug-socket set_model verb (atomic, lock-waiting, store-persisting - see the
# header). Args: <sid> <model|-> <effort|->.
#
# The debug verb REQUIRES a model, so an effort-only pin (model is `-`) resolves
# the session's CURRENT model from the store first and re-applies it unchanged
# alongside the requested effort - the store read is also the fail-closed guard
# that there is a readable session to pin at all. A model-only pin (effort is `-`)
# sends the model with no effort key, leaving the session's effort untouched.
#
# Returns 0 when the verb reports success, 1 on any failure (no jcode binary,
# python3 missing for the effort-only model lookup, an unreadable store when one
# is needed, or the verb's own nonzero exit). Prints nothing on stdout; the
# store read-back in fm_jcode_pin_and_verify is the source of confirmed values.
# The verb's error text is left on the caller's stderr, so a loud failure carries
# jcode's own diagnostic.
fm_jcode_apply_profile() {  # <sid> <model|-> <effort|->
  local sid=$1 model=$2 effort=$3 jcode payload cur_model profile kv
  [ -n "$sid" ] || return 1
  jcode=$(fm_jcode_bin) || return 1
  if [ "$model" = - ] || [ -z "$model" ]; then
    # Effort-only: the verb needs a model, so re-apply the current one unchanged.
    # fm_session_store_profile is the readable-session guard too: no store, no pin.
    profile=$(fm_session_store_profile "$sid" 2>/dev/null) || return 1
    cur_model=''
    while IFS= read -r kv; do
      case "$kv" in model=*) cur_model=${kv#model=} ;; esac
    done <<EOF
$profile
EOF
    [ -n "$cur_model" ] || return 1
    model=$cur_model
  fi
  if [ "$effort" = - ] || [ -z "$effort" ]; then
    payload=$(printf '{"model":"%s"}' "$model")
  else
    payload=$(printf '{"model":"%s","effort":"%s"}' "$model" "$effort")
  fi
  "$jcode" debug -S "$sid" "set_model:$payload" >/dev/null 2>&1
}

# fm_jcode_pin_and_verify: apply the requested profile to <sid> and CONFIRM it
# against the session store, with bounded retries. Args:
#   <sid> <want_model|-> <want_effort|-> [tries] [settle]
# Because the debug verb waits out any in-flight turn and persists synchronously,
# one apply normally verifies on the first store read; the bounded retry is the
# fail-closed backstop for a store write that lags the return or a transient
# unreadable store. `-` on an axis means "not requested" and that axis is not
# compared (an effort-only or model-only pin verifies only its own axis).
#
# On success prints the CONFIRMED store values, one per requested axis, as
#   model=<value>
#   effort=<value>
# (a `-` axis is omitted) and returns 0. On exhaustion prints nothing and returns
# 1, leaving the last store read for the caller to fold into a loud failure. tries
# defaults to 3, settle to 0 (the store persists before the verb returns, so a
# real spawn passes a small settle only to absorb filesystem lag under load).
fm_jcode_pin_and_verify() {  # <sid> <want_model|-> <want_effort|-> [tries] [settle]
  local sid=$1 want_model=$2 want_effort=$3 tries=${4:-3} settle=${5:-0}
  local attempt=0 profile kv actual_model actual_effort ok
  [ -n "$sid" ] || return 1
  while [ "$attempt" -lt "$tries" ]; do
    attempt=$((attempt + 1))
    # Apply on every attempt: a retry means the last read did not confirm, so
    # re-issuing the atomic apply (which waits idle) is the correct recovery.
    fm_jcode_apply_profile "$sid" "$want_model" "$want_effort" || true
    [ "$settle" != 0 ] && sleep "$settle"
    profile=$(fm_session_store_profile "$sid" 2>/dev/null) || profile=''
    if [ -z "$profile" ]; then
      [ "$attempt" -lt "$tries" ] && continue
      return 1
    fi
    actual_model='' actual_effort=''
    while IFS= read -r kv; do
      case "$kv" in
        model=*) actual_model=${kv#model=} ;;
        effort=*) actual_effort=${kv#effort=} ;;
      esac
    done <<EOF
$profile
EOF
    ok=0
    { [ "$want_model" = - ] || [ -z "$want_model" ] || [ "$actual_model" = "$want_model" ] || ok=1; }
    { [ "$want_effort" = - ] || [ -z "$want_effort" ] || [ "$actual_effort" = "$want_effort" ] || ok=1; }
    if [ "$ok" -eq 0 ]; then
      if [ "$want_model" != - ] && [ -n "$want_model" ]; then printf 'model=%s\n' "$actual_model"; fi
      if [ "$want_effort" != - ] && [ -n "$want_effort" ]; then printf 'effort=%s\n' "$actual_effort"; fi
      return 0
    fi
    [ "$attempt" -lt "$tries" ] && continue
  done
  return 1
}
