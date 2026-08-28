#!/usr/bin/env bash
# Write bulky task evidence (test output, diffs, logs) to a digest-once file so
# the status line can carry a one-line verdict plus a path instead of the full
# dump the supervisor would otherwise re-read on every wake.
# Usage: fm-evidence.sh <task-id> <name> [<source-path>]
#   Evidence is read from <source-path> when given, otherwise from stdin.
#   Writes data/<task-id>/evidence/<name>.txt under the active firstmate home
#   and prints the resulting path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: fm-evidence.sh <task-id> <name> [<source-path>]" >&2
  exit 2
fi

ID=$1
NAME=$2
SRC=${3-}

if ! fm_task_id_path_safe "$ID"; then
  echo "error: invalid task id" >&2
  exit 2
fi
# The name becomes a leaf filename, so it must be path-safe for the same reason
# the task id is: no traversal, no leading dot, no separators.
if ! fm_task_id_path_safe "$NAME"; then
  echo "error: invalid evidence name" >&2
  exit 2
fi

[ -d "$DATA" ] && [ ! -L "$DATA" ] || { echo "error: firstmate home data directory is unavailable" >&2; exit 1; }

DEST_DIR="$DATA/$ID/evidence"
mkdir -p "$DEST_DIR" || { echo "error: cannot create evidence directory" >&2; exit 1; }
DEST="$DEST_DIR/$NAME.txt"

if [ -n "$SRC" ]; then
  [ -f "$SRC" ] || { echo "error: source path is not a readable file: $SRC" >&2; exit 1; }
  cat -- "$SRC" > "$DEST" || { echo "error: cannot write evidence file" >&2; exit 1; }
else
  cat > "$DEST" || { echo "error: cannot write evidence file" >&2; exit 1; }
fi

printf '%s\n' "$DEST"
