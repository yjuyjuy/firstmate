#!/bin/bash
# fm-switch-account.sh - switch the Claude sub-account for live jcode worker sessions.
#
# STATUS: MANUAL FALLBACK. The ROUTINE account switch now goes through the
# account-switch orchestrator (ADR 0031, Phase 1): bin/fm-spawn.sh consults
# quota-axi `decide` at spawn so a jcode/Claude worker lands on a non-exhausted
# account, and the watcher (bin/fm-watch.sh) calls quota-axi `decide`+`switch` on
# a live limit-error (tripwire) wake to auto-rotate the fleet WITHOUT captain
# intervention. Both paths run through bin/fm-account-orchestrator.sh, firstmate's
# thin caller of the orchestrator. This script is KEPT as the documented manual
# fallback for when the orchestrator is unavailable, the installed quota-axi lacks
# the merged verbs, or the captain wants to force a specific account by hand; it
# is not deleted (deletion is a later confidence step and a captain call). See
# docs/account-orchestrator.md for the full routine path and the tripwire catalog.
#
# jcode's `/account claude switch <label>` is a PER-SESSION slash command, not a
# server-global setting. To move the whole fleet you must send it into every live
# worker's jcode session individually. This script does exactly that.
#
# Usage:
#   bin/fm-switch-account.sh <label> [pane_id ...]
#   bin/fm-switch-account.sh --help | --status
#
#   <label>     required, e.g. claude-1 or claude-2. Validated against the known
#               account labels in jcode's auth.json BEFORE anything is broadcast.
#   --help      print usage and exit 0 without broadcasting.
#   --status    print the currently active account and the known labels without
#               broadcasting a switch.
#   pane_id...  optional explicit herdr targets in the full
#               "<session>:<workspace>:<pane>" form (e.g. "default:w1J:p3"), the
#               same value meta records in window=; if omitted, all live worker
#               targets recorded in state/<id>.meta are targeted, each on the
#               backend that meta records (defaulting to tmux per the P1
#               compatibility contract in fm_backend_of_meta). No-args discovery
#               also walks EVERY registered secondmate home's own state/*.meta
#               (data/secondmates.md -> home= paths), because a secondmate's
#               crews are recorded only in that secondmate home, never in the
#               main home: without this walk a live secondmate crew keeps the old
#               account silently through a fleet switch (task
#               scout-switch-misses-secondmate-crews, live incident 2026-08-25).
#               Each secondmate home is validated read-only through the same
#               validate_secondmate_home guard the liveness sweep uses; the walk
#               only READS meta files and never mutates a secondmate home.
#
# For each target it first checks the pane's composer state and refuses to
# garble a half-typed prompt: if the composer already holds pending unsubmitted
# text it sends one Escape to clear it, settles, and re-checks. A composer that
# stays pending after the Escape is SKIPPED (never overwrite genuine human
# typing), as is a composer that reads `unknown` (dead shell / non-agent pane -
# never blind-inject). Only a confirmed-empty composer receives the switch
# command. It then types the slash command and submits it through the backend's
# verified send path, waits briefly, and prints each target's tail so the caller
# can confirm the switch landed.
#
# BACKEND AWARENESS: discovery reads each meta's recorded backend so this works
# on tmux-backed tasks (the common default) as well as herdr. Explicit pane-id
# args on the CLI have no meta to read a backend from and keep the historical
# herdr assumption (this script's original only caller).
#
# SAFETY: this only rotates a reversible account label. It never edits auth.json,
# never restarts the server, and never touches project code.
#
# NOTE ON no-args DISCOVERY: not every state/*.meta file records a target
# (for example a service sidecar meta such as state/.lavish-lan.meta records
# only port=/bind=/target=). Under `set -euo pipefail` a helper that resolves no
# target must not be fatal: the `|| true` guard on the extraction below is
# load-bearing - a meta with no resolvable target must be skipped, not fatal.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
here="$(cd "$script_dir/.." && pwd)"
cd "$here"

# shellcheck source=bin/fm-backend.sh
. "$script_dir/fm-backend.sh"

# FM_ROOT/FM_HOME/DATA resolution mirrors bin/fm-bootstrap.sh so no-args
# discovery can walk registered secondmate homes' state/*.meta. Overridable for
# tests. validate_secondmate_home (fm-ff-lib.sh) reads FM_HOME and FM_ROOT.
FM_ROOT="${FM_ROOT_OVERRIDE:-$here}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
export FM_ROOT FM_HOME
# shellcheck source=bin/fm-ff-lib.sh
. "$script_dir/fm-ff-lib.sh"

# Pacing between the send-text and Enter, and before reading confirmations.
# Overridable so tests can run without the real multi-second waits.
send_settle="${FM_SWITCH_SEND_SETTLE:-1}"
confirm_wait="${FM_SWITCH_CONFIRM_WAIT:-5}"
# Settle between the Escape that clears a pending composer and the re-check.
clear_settle="${FM_SWITCH_CLEAR_SETTLE:-0.5}"

usage() {
  cat >&2 <<EOF
usage: $0 <label> [pane_id ...]
       $0 --help | --status

  <label>     account label to switch every live worker to (e.g. claude-1).
              Must be one of the known account labels; validated before any
              pane is touched.
  --help      show this help and exit without broadcasting.
  --status    show the active account and known labels without broadcasting.
EOF
}

# Resolve jcode's auth.json. Overridable for tests via FM_SWITCH_AUTH_JSON.
auth_json="${FM_SWITCH_AUTH_JSON:-${JCODE_HOME:-$HOME/.jcode}/auth.json}"

# Print the known account labels (one per line), best effort. Empty when the
# auth file is missing or unreadable - callers must treat empty as "unknown set".
known_labels() {
  [ -f "$auth_json" ] || return 0
  grep -o '"label"[[:space:]]*:[[:space:]]*"[^"]*"' "$auth_json" 2>/dev/null \
    | sed 's/.*"\([^"]*\)"$/\1/'
}

# Print the currently active account label, best effort.
active_label() {
  [ -f "$auth_json" ] || return 0
  grep -o '"active_anthropic_account"[[:space:]]*:[[:space:]]*"[^"]*"' "$auth_json" 2>/dev/null \
    | head -1 | sed 's/.*"\([^"]*\)"$/\1/'
}

label="${1:-}"

# Subcommands and guard: handle --help/--status and reject any leading-dash first
# arg that is not a recognized flag BEFORE broadcasting anything. Typing an
# unrecognized flag (--help, --status, a typo) used to be sent verbatim into
# every live worker pane; this guard stops that.
case "$label" in
  --help | -h | help)
    usage
    exit 0
    ;;
  --status | status)
    active="$(active_label)"
    echo "active account: ${active:-unknown}"
    mapfile -t _st_labels < <(known_labels)
    if [ "${#_st_labels[@]}" -gt 0 ]; then
      echo "known labels:"
      printf '  %s\n' "${_st_labels[@]}"
    else
      echo "known labels: (none found in $auth_json)"
    fi
    exit 0
    ;;
  -*)
    echo "error: unrecognized option '$label'" >&2
    usage
    exit 2
    ;;
esac

if [ -z "$label" ]; then
  usage
  exit 2
fi

# Validate the label against the known account set before broadcasting. An
# unknown label is a typo, not a switch target: reject it here so it is never
# broadcast into every live worker pane. When the known set cannot be read
# (auth.json missing), skip validation rather than block a legitimate switch.
mapfile -t _known < <(known_labels)
if [ "${#_known[@]}" -gt 0 ]; then
  _match=0
  for _l in "${_known[@]}"; do
    [ "$_l" = "$label" ] && { _match=1; break; }
  done
  if [ "$_match" -eq 0 ]; then
    echo "error: unknown account label '$label' (known: ${_known[*]})" >&2
    usage
    exit 2
  fi
fi
shift || true

panes=("$@")
# target -> backend map. Explicit CLI panes default to herdr (see header).
declare -A target_backends=()
# target -> "home-label" for reporting which home each pane belongs to.
declare -A target_homes=()

# Add every windowed live worker meta under one state dir to the pane set. The
# home_label is a human tag for the confirmation block. Read-only.
collect_state_metas() {  # <state-dir> <home-label>
  local state_dir=$1 home_label=$2 metafile backend target
  [ -d "$state_dir" ] || return 0
  while IFS= read -r metafile; do
    [ -f "$metafile" ] || continue
    backend="$(fm_backend_of_meta "$metafile" 2>/dev/null || true)"
    # A meta without a resolvable target is not a target; `|| true` keeps that
    # expected miss from tripping set -e/pipefail.
    target="$(fm_backend_target_of_meta "$metafile" 2>/dev/null || true)"
    # Pass the recorded target verbatim. A herdr target is the full
    # "<session>:<workspace>:<pane>" form (e.g. "default:w1J:p3"), and the herdr
    # adapter's fm_backend_herdr_parse_target splits on the FIRST colon only:
    # the leading field is the herdr session it passes as --session, the
    # remainder is the whole pane id. Stripping the "default:" prefix left
    # "w1J:p3", which herdr then reads as session=w1J pane=p3 and rejects as
    # pane_not_found, so EVERY live jcode composer probe returned `unknown` and
    # fm-switch-account skipped the whole fleet (task
    # fix-jcode-composer-probe-unknown-blocks-account-switch, verified live
    # 2026-08-12). Every other fm_backend_* caller passes this same meta window=
    # value unchanged, so this script must too.
    [ -n "$target" ] || continue
    # First writer wins: never let a secondmate home overwrite a main-home
    # target's recorded backend on a (pathological) duplicate window id.
    if [ -z "${target_backends[$target]:-}" ]; then
      panes+=("$target")
      target_backends["$target"]="${backend:-tmux}"
      target_homes["$target"]="$home_label"
    fi
  done < <(find "$state_dir" -maxdepth 1 -name '*.meta' 2>/dev/null)
}

if [ "${#panes[@]}" -eq 0 ]; then
  # Derive live worker targets from this home's task meta files, each on its
  # recorded backend.
  collect_state_metas "$FM_HOME/state" main

  # THEN walk every registered secondmate home's OWN state/*.meta. A secondmate's
  # crews are recorded only in that secondmate home (its meta files live under its
  # own FM_HOME/state), never in the main home, so without this walk a live
  # secondmate crew keeps the OLD account silently through a fleet switch (task
  # scout-switch-misses-secondmate-crews, live incident 2026-08-25: crew
  # fix-429-dead-turn missed two claude-2 broadcasts and stayed 429-throttled an
  # hour later). Each home is validated read-only through the same
  # validate_secondmate_home guard the liveness sweep uses; we only READ its meta
  # files. Skip the active home defensively (it is already swept above and the
  # validator rejects it anyway).
  while IFS=$'\t' read -r sm_id sm_home; do
    [ -n "$sm_home" ] || continue
    if validate_secondmate_home "$sm_id" "$sm_home" 2>/dev/null; then
      collect_state_metas "$VALIDATED_HOME/state" "secondmate:$sm_id"
    else
      echo "  note: skipping secondmate '$sm_id' home ($VALIDATION_ERROR)" >&2
    fi
  done < <(secondmate_registry_entries "$DATA/secondmates.md")
else
  for p in "${panes[@]}"; do
    target_backends["$p"]=herdr
    target_homes["$p"]=explicit
  done
fi

if [ "${#panes[@]}" -eq 0 ]; then
  echo "no target panes found (pass pane ids explicitly)" >&2
  exit 1
fi

echo "switching to account '$label' in ${#panes[@]} pane(s): ${panes[*]}"

# A pane is CONFIRMED switched when its captured tail shows jcode's own switch
# acknowledgement carrying the target label. jcode prints
# "Switched to Anthropic account <label>" on a successful `/account claude
# switch`, and the account status line renders the active label as
# "active account: <label>"; both satisfy this. Requiring the acknowledgement
# phrase AND the label on the same line means the pane's own echo of the
# "/account claude switch <label>" command we typed (which contains the label
# but not the phrase) never counts as a false confirmation.
confirmed_switched() {  # <capture-text> <label>
  local cap=$1 lbl=$2
  printf '%s\n' "$cap" | grep -Eq "(Switched to Anthropic account|active account:).*${lbl}"
}

# Send the switch to one pane after the composer guard. Prints the per-pane
# outcome line. Returns 0 when the command was sent (so the caller verifies it),
# 1 when the pane was skipped or the send failed (no verification needed).
send_switch_to() {  # <backend> <target>
  local backend=$1 p=$2 state verdict
  # Composer guard: never garble a half-typed prompt or blind-inject a dead pane.
  state="$(fm_backend_composer_state "$backend" "$p" 2>/dev/null || echo unknown)"
  if [ "$state" = pending ]; then
    # One Escape to clear pending text, settle, then re-check once.
    fm_backend_send_key "$backend" "$p" Escape 2>/dev/null || true
    sleep "$clear_settle"
    state="$(fm_backend_composer_state "$backend" "$p" 2>/dev/null || echo unknown)"
    if [ "$state" = pending ]; then
      echo "  $p: SKIPPED - composer still has pending text after Escape (not overwriting)"
      return 1
    fi
  fi
  if [ "$state" = unknown ]; then
    echo "  $p: SKIPPED - composer state unknown (dead/non-agent pane)"
    return 1
  fi
  # Send the slash command through the backend's verified submit path.
  verdict="$(fm_backend_send_text_submit "$backend" "$p" "/account claude switch $label" \
    3 "$send_settle" "$send_settle" 2>/dev/null)" || {
    echo "  $p: send FAILED"; return 1; }
  case "$verdict" in
    empty) echo "  $p: sent" ;;
    *) echo "  $p: sent (verdict=${verdict:-unknown})" ;;
  esac
  return 0
}

# First pass: send to every target, remembering which panes to verify.
sent_targets=()
for p in "${panes[@]}"; do
  backend="${target_backends[$p]:-herdr}"
  if send_switch_to "$backend" "$p"; then
    sent_targets+=("$p")
  fi
done

echo "waiting for confirmations..."
sleep "$confirm_wait"

# Verification pass: confirm each SENT pane actually reports the switched
# account, and retry ONCE for a pane that has not confirmed. Report a per-pane
# verdict line (CONFIRMED / UNCONFIRMED) instead of a blind capture tail, so a
# silent enumeration-or-delivery miss is visible instead of assumed switched.
# The full capture tail still prints under each verdict as the evidence.
unconfirmed=()
for p in "${sent_targets[@]}"; do
  backend="${target_backends[$p]:-herdr}"
  cap="$(fm_backend_capture "$backend" "$p" 8 2>/dev/null || true)"
  if confirmed_switched "$cap" "$label"; then
    continue
  fi
  # Retry once: re-send the switch, wait, re-capture.
  echo "  $p: not confirmed on first read - retrying once"
  send_switch_to "$backend" "$p" >/dev/null || true
  sleep "$confirm_wait"
  cap="$(fm_backend_capture "$backend" "$p" 8 2>/dev/null || true)"
  confirmed_switched "$cap" "$label" || unconfirmed+=("$p")
done

echo "=== per-pane verdicts (account '$label') ==="
for p in "${sent_targets[@]}"; do
  backend="${target_backends[$p]:-herdr}"
  home="${target_homes[$p]:-?}"
  cap="$(fm_backend_capture "$backend" "$p" 8 2>/dev/null || true)"
  if confirmed_switched "$cap" "$label"; then
    echo "  [$home] $p: CONFIRMED"
  else
    echo "  [$home] $p: UNCONFIRMED"
  fi
  printf '%s\n' "$cap" | sed 's/^/      /'
done

if [ "${#unconfirmed[@]}" -gt 0 ]; then
  echo "WARNING: ${#unconfirmed[@]} pane(s) NOT confirmed on account '$label': ${unconfirmed[*]}" >&2
  exit 3
fi
