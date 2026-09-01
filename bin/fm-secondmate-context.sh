#!/usr/bin/env bash
# Report a secondmate agent's current context-window usage.
# Usage: fm-secondmate-context.sh <id>
#
# Resolves the secondmate from this home's state/<id>.meta, reads its context
# tokens from its harness transcript (claude and jcode have a verified read;
# every other harness reports unknown - see docs/secondmate-context-handoff.md),
# and prints:
#
#   id=<id>
#   harness=<harness>
#   home=<home>
#   context_tokens=<n|unknown>
#   threshold=<t>
#   over_threshold=<yes|no|unknown>
#
# Exit status: 0 on a successful report (including a clean unknown read),
# 2 on an invalid request or a task that is not a secondmate. This reporter is
# read-only and never steers, exits, or respawns anything - the handoff itself
# is bin/fm-secondmate-handoff.sh. The threshold defaults to 200000 tokens and
# is set with config/secondmate-context-threshold (docs/configuration.md).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-secondmate-context-lib.sh
. "$SCRIPT_DIR/fm-secondmate-context-lib.sh"

case "${1:-}" in
  -h|--help)
    cat <<'EOF'
Usage: fm-secondmate-context.sh <id>

Read-only report of a secondmate's context-window usage, resolved from this
home's state/<id>.meta. Prints id=, harness=, home=, threshold=, context_tokens=
(claude and jcode have a verified read; every other harness prints unknown), and over_threshold=yes|no|unknown.
Threshold defaults to 200000 and is set with config/secondmate-context-threshold.
Exit 0 on a report (including a clean unknown read), 2 on a bad request or a
non-secondmate. See docs/secondmate-context-handoff.md.
EOF
    exit 0
    ;;
esac
if [ "$#" -ne 1 ] || [ -z "${1:-}" ]; then
  echo "error: usage: fm-secondmate-context.sh <id>" >&2
  exit 2
fi
ID=$1
META="$STATE/$ID.meta"
if [ ! -f "$META" ]; then
  echo "error: no metadata for '$ID' in $STATE" >&2
  exit 2
fi
if [ "$(fm_meta_get "$META" kind)" != secondmate ]; then
  echo "error: '$ID' is not a secondmate" >&2
  exit 2
fi

HARNESS=$(fm_meta_get "$META" harness)
[ -n "$HARNESS" ] || HARNESS=$(fm_backend_of_meta "$META")
HOME_DIR=$(fm_meta_get "$META" home)
[ -n "$HOME_DIR" ] || HOME_DIR=$(fm_meta_get "$META" worktree)

THRESHOLD=$(fm_sm_context_threshold "$CONFIG")
TOKENS=$(fm_sm_context_tokens "$HOME_DIR" "$HARNESS" || true)

printf 'id=%s\n' "$ID"
printf 'harness=%s\n' "$HARNESS"
printf 'home=%s\n' "$HOME_DIR"
printf 'threshold=%s\n' "$THRESHOLD"
if [ -z "$TOKENS" ]; then
  printf 'context_tokens=unknown\n'
  printf 'over_threshold=unknown\n'
elif [ "$TOKENS" -ge "$THRESHOLD" ]; then
  printf 'context_tokens=%s\n' "$TOKENS"
  printf 'over_threshold=yes\n'
else
  printf 'context_tokens=%s\n' "$TOKENS"
  printf 'over_threshold=no\n'
fi
