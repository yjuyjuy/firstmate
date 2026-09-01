#!/usr/bin/env bash
# Reserve an ADR number and create the session directory for a grilling handoff.
#
# The grilling-handoff skill's prepare step calls this to claim an ADR number
# for a griller session. Two concurrent firstmate sessions must never claim the
# same number, so the claim is recorded in a durable, firstmate-private ledger
# under a mutual-exclusion lock rather than left to agent memory. Firstmate
# scans the product repo's ADR directory for the highest existing number and
# passes it as --adr-scan-max; this script picks max(that, highest already
# reserved in the ledger) + 1 under the lock, so a number a concurrent session
# already reserved but has not yet committed as a file is still avoided.
#
# This script never writes into a product repo: it only touches the ledger and
# the session directory under $FM_HOME/data/grilling. The griller creates the
# actual ADR file in the product repo and re-checks the number at commit time.
#
# Idempotent per slug: re-running with an already-reserved slug re-prints that
# reservation instead of allocating a second number, so a retried prepare is
# safe.
#
# Usage:
#   fm-grill-reserve.sh --slug <slug> --date <YYYY-MM-DD> \
#       --project <name> --adr-scan-max <N>
#
# On success prints three lines to stdout:
#   adr=<NNNN>
#   session_dir=<absolute path>
#   slug=<slug>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# FM_ROOT/FM_HOME/DATA and die (exit 2 default) come from the shared preamble.
FM_PROG=error FM_DIE_CODE=2
# shellcheck source=bin/fm-preamble-lib.sh
. "$SCRIPT_DIR/fm-preamble-lib.sh"
GRILL_DIR="$DATA/grilling"
LEDGER="$GRILL_DIR/adr-reservations.md"
LOCK="$GRILL_DIR/.reserve.lock"

SLUG=""; DATE=""; PROJECT=""; SCAN_MAX=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --slug) SLUG=${2:-}; shift 2 || die "usage" ;;
    --date) DATE=${2:-}; shift 2 || die "usage" ;;
    --project) PROJECT=${2:-}; shift 2 || die "usage" ;;
    --adr-scan-max) SCAN_MAX=${2:-}; shift 2 || die "usage" ;;
    *) die "unknown argument: $1" ;;
  esac
done

# A slug becomes a branch name (grill/<slug>), a worktree name, and a directory
# name, so keep it to lowercase, digits, and dashes.
case "$SLUG" in
  ""|*[!a-z0-9-]*) die "invalid --slug (need lowercase letters, digits, dashes): '$SLUG'" ;;
esac
case "$DATE" in
  [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]) : ;;
  *) die "invalid --date (need YYYY-MM-DD): '$DATE'" ;;
esac
[ -n "$PROJECT" ] || die "missing --project"
case "$PROJECT" in *'|'*) die "invalid --project (no '|'): '$PROJECT'" ;; esac
case "$SCAN_MAX" in
  ""|*[!0-9]*) die "invalid --adr-scan-max (need a non-negative integer): '$SCAN_MAX'" ;;
esac

mkdir -p "$GRILL_DIR" || die "cannot create $GRILL_DIR"

# Portable mutex: mkdir is atomic, so exactly one caller wins the create. Retry
# briefly, then fail closed rather than proceed without the lock and risk a
# duplicate number.
acquired=""
for _ in $(seq 1 50); do
  if mkdir "$LOCK" 2>/dev/null; then
    acquired=1
    break
  fi
  sleep 0.1
done
[ -n "$acquired" ] || die "could not acquire reservation lock at $LOCK"
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# Ledger row shape: | date | slug | project | adr | status |
# Read the 4-digit adr field (column 5 under a leading empty field) only from
# well-formed data rows, so the header/separator lines are ignored.
ledger_field() { # <row-line> <field-index>
  printf '%s\n' "$1" | awk -F'|' -v n="$2" '{ gsub(/^[ \t]+|[ \t]+$/, "", $n); print $n }'
}

existing_row=""
max_adr=0
if [ -f "$LEDGER" ]; then
  while IFS= read -r line; do
    case "$line" in "|"*) : ;; *) continue ;; esac
    adr=$(ledger_field "$line" 5)
    case "$adr" in [0-9][0-9][0-9][0-9]) : ;; *) continue ;; esac
    rslug=$(ledger_field "$line" 3)
    if [ "$rslug" = "$SLUG" ]; then
      existing_row=$line
    fi
    if [ "$((10#$adr))" -gt "$max_adr" ]; then
      max_adr=$((10#$adr))
    fi
  done < "$LEDGER"
fi

SESSION_DIR="$GRILL_DIR/$DATE-$SLUG"

if [ -n "$existing_row" ]; then
  # Idempotent replay: return the number this slug already holds.
  adr=$(ledger_field "$existing_row" 5)
  mkdir -p "$SESSION_DIR" || die "cannot create $SESSION_DIR"
  printf 'adr=%s\n' "$adr"
  printf 'session_dir=%s\n' "$SESSION_DIR"
  printf 'slug=%s\n' "$SLUG"
  exit 0
fi

next=$max_adr
if [ "$SCAN_MAX" -gt "$next" ]; then
  next=$SCAN_MAX
fi
next=$((next + 1))
adr=$(printf '%04d' "$next")

if [ ! -f "$LEDGER" ]; then
  cat > "$LEDGER" <<'EOF'
# ADR reservations

Firstmate-private ledger of ADR numbers claimed by grilling-handoff sessions.
One row per session. Owned by `bin/fm-grill-reserve.sh`; do not hand-edit while a session is open.

| date | slug | project | adr | status |
| ---- | ---- | ------- | ---- | ------ |
EOF
fi

printf '| %s | %s | %s | %s | reserved |\n' "$DATE" "$SLUG" "$PROJECT" "$adr" >> "$LEDGER" \
  || die "cannot append reservation to $LEDGER"

mkdir -p "$SESSION_DIR" || die "cannot create $SESSION_DIR"

printf 'adr=%s\n' "$adr"
printf 'session_dir=%s\n' "$SESSION_DIR"
printf 'slug=%s\n' "$SLUG"
