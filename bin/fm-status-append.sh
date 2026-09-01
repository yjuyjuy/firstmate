#!/usr/bin/env bash
# fm-status-append.sh - the single capped write point for crew status appends.
#
# Every crew status line lands in state/<id>.status, and every append wakes
# firstmate: the watcher, the away daemon, the wake-brief digest, and every
# status tail the supervisor reads. A 500+ char needs-decision line therefore
# bloats every one of those reads. This helper caps the line that actually hits
# the status file so a reader never sees an untruncated giant line, while the
# complete original text is preserved in an overflow file the truncated line
# points at.
#
# Behavior:
#   - A line at or under the cap (default 300, FM_STATUS_APPEND_CAP overrides) is
#     appended UNCHANGED.
#   - A line over the cap: the FULL original text is written FIRST to
#     <overflow-dir>/<ts>.txt, THEN a truncated line is appended, suffixed with
#     ` ... [full: <path>]` pointing at that overflow file. The full body always
#     reaches disk before the truncated line hits the status file, so a crash
#     between the two writes still leaves the evidence recoverable.
#   - The state prefix (working:/blocked:/needs-decision:/etc.) stays at the
#     front of the truncated line, so bin/fm-classify-lib.sh's verb-keyed triage
#     is unaffected.
#
# Usage:
#   fm-status-append.sh [--overflow-dir DIR] [--cap N] <status-file> <line...>
#
# The overflow dir defaults to <home>/data/<id>/status-overflow, derived from the
# status file path (<home>/state/<id>.status). Callers that use a non-default
# layout pass --overflow-dir explicitly (fm-brief.sh bakes it from the resolved
# $DATA/$ID).
set -eu

usage() {
  cat <<'EOF' >&2
Usage: fm-status-append.sh [--overflow-dir DIR] [--cap N] <status-file> <line...>
EOF
  exit 2
}

OVERFLOW_DIR=""
CAP="${FM_STATUS_APPEND_CAP:-300}"
while [ $# -gt 0 ]; do
  case "$1" in
    --overflow-dir) [ $# -ge 2 ] || usage; OVERFLOW_DIR=$2; shift 2 ;;
    --cap) [ $# -ge 2 ] || usage; CAP=$2; shift 2 ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
done

[ $# -ge 2 ] || usage
STATUS_FILE=$1
shift
LINE=$*

case "$CAP" in
  ''|*[!0-9]*) echo "error: --cap must be a non-negative integer (got '$CAP')" >&2; exit 1 ;;
esac

mkdir -p "$(dirname "$STATUS_FILE")" 2>/dev/null || true
if [ ! -d "$(dirname "$STATUS_FILE")" ]; then
  echo "error: cannot create parent directory for status file '$STATUS_FILE'" >&2
  exit 1
fi

# Under the cap: append unchanged. printf, not echo, so a leading dash or a
# backslash in the body is written literally.
if [ "${#LINE}" -le "$CAP" ]; then
  printf '%s\n' "$LINE" >> "$STATUS_FILE"
  exit 0
fi

# Over the cap. Resolve the overflow dir from the status file path when not given
# explicitly: <home>/state/<id>.status -> <home>/data/<id>/status-overflow.
if [ -z "$OVERFLOW_DIR" ]; then
  base=$(basename "$STATUS_FILE")
  id=${base%.status}
  state_dir=$(cd "$(dirname "$STATUS_FILE")" && pwd)
  home=$(dirname "$state_dir")
  OVERFLOW_DIR="$home/data/$id/status-overflow"
fi

mkdir -p "$OVERFLOW_DIR" || {
  echo "error: cannot create overflow dir '$OVERFLOW_DIR'" >&2
  exit 1
}

# Timestamped overflow file, made unique so two appends in the same nanosecond do
# not clobber each other.
ts=$(date -u +%Y%m%dT%H%M%S.%N 2>/dev/null || date -u +%Y%m%dT%H%M%S)
overflow_file="$OVERFLOW_DIR/$ts.txt"
while [ -e "$overflow_file" ]; do
  ts="$ts-$RANDOM"
  overflow_file="$OVERFLOW_DIR/$ts.txt"
done

# Write the FULL body FIRST, so the evidence is durable before the truncated line
# is visible to any reader.
printf '%s\n' "$LINE" > "$overflow_file"

# Build the truncated line: <head> ... [full: <path>]. Keep the head large enough
# that the state-verb prefix always survives even when the pointer path is long.
suffix=" ... [full: $overflow_file]"
head_len=$((CAP - ${#suffix}))
min_head=40
if [ "$head_len" -lt "$min_head" ]; then
  head_len=$min_head
fi
head=${LINE:0:$head_len}
printf '%s%s\n' "$head" "$suffix" >> "$STATUS_FILE"
