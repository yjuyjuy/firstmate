#!/usr/bin/env bash
# fm-steer-templates.sh - single owner of the standardized crewmate-steer
# phrasings that keep a worker's prompt cache warm.
#
# WHY: every fm-send steer phrased fresh changes the leading bytes of the
# worker's next prompt, busting its prompt cache and paying full input-token
# cost on every steer. A supervisor who phrases each steer from a FIXED prefix
# with only a variable tail keeps that prefix byte-stable across steers, so the
# cached prefix is reused and only the tail is re-encoded. This script is the
# canonical source of those fixed prefixes; it emits phrasing for a supervisor
# to send, it never sends anything and it never touches fm-send.
#
# Usage:
#   fm-steer-templates.sh <template> [tail...]
#   fm-steer-templates.sh --list
#
# Templates (each a fixed prefix plus one variable tail slot):
#   nudge              gentle "keep going / what is your status" prod
#   decision-delivery  hand a worker a resolved ask-user/needs-decision answer
#   blocker-query      ask a stalled worker exactly what it is blocked on
#   gate-response      tell a worker to answer the active pipeline gate
#   wrapup             tell a worker to finish and report done
#
# The emitted line is what the supervisor pastes as the fm-send text. The tail
# words are appended verbatim after the fixed prefix (a single space joins them
# when a tail is given). With no tail the bare prefix is emitted, which is
# itself a valid, fully cache-warm steer.
set -eu

usage() {
  cat <<'EOF'
usage: fm-steer-templates.sh <template> [tail...]
       fm-steer-templates.sh --list

templates: nudge decision-delivery blocker-query gate-response wrapup
EOF
}

# Fixed prefixes. Keep these byte-stable: changing a prefix busts the cache for
# every steer that uses it, which is the exact cost this file exists to avoid.
prefix_for() {
  case "$1" in
    nudge)             printf '%s' 'Status check:' ;;
    decision-delivery) printf '%s' 'Decision:' ;;
    blocker-query)     printf '%s' 'Blocked on what exactly?' ;;
    gate-response)     printf '%s' 'Answer the active gate:' ;;
    wrapup)            printf '%s' 'Wrap up and report done:' ;;
    *) return 1 ;;
  esac
}

main() {
  if [ "$#" -eq 0 ]; then
    usage >&2
    exit 2
  fi

  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --list)
      printf '%s\n' nudge decision-delivery blocker-query gate-response wrapup
      exit 0
      ;;
  esac

  local template=$1
  shift

  local prefix
  if ! prefix=$(prefix_for "$template"); then
    printf 'error: unknown template %s\n' "$template" >&2
    usage >&2
    exit 2
  fi

  if [ "$#" -eq 0 ]; then
    printf '%s\n' "$prefix"
  else
    printf '%s %s\n' "$prefix" "$*"
  fi
}

main "$@"
