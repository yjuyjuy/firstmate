#!/usr/bin/env bash
# fm-decision-desk-ledger.sh - lightweight value tracking for the decision-desk
# secondmate.
#
# The decision-desk secondmate answers routed technical rulings, but nothing
# records how often it is used or whether its rulings hold up. This script is a
# cheap tracking affordance, not a workflow: firstmate calls it at the two points
# it already touches a decision-desk request, and reads the tally on demand.
#
# WHERE the routing-time append lives: firstmate's secondmate-routing step (the
# "Intake and authority" routing in AGENTS.md section 7). When firstmate routes a
# request to the decision-desk secondmate, it runs `route` here. When the ruling
# returns, firstmate runs `resolve`. Neither call may block routing; both are
# fire-and-forget and never fail the caller's real work.
#
# Storage: data/decision-desk-ledger.md, one Markdown table row per request. It
# is firstmate-private durable state (gitignored data/), like the other data/
# ledgers, and is human-readable and hand-annotatable. Append-only in spirit:
# `route` appends a row; `resolve` and `overturn` edit that row's status/overturned
# cells in place. Nothing is ever pruned.
#
# Row columns (Markdown table):
#   | when (UTC ISO) | subject | question | status | overturned |
# where <subject> is the task id or short subject, <question> is a one-line
# summary, <status> is one of routed/ruled/insufficient-source/escalated, and
# <overturned> is empty or yes (a manual annotation is fine too).
#
# Usage:
#   fm-decision-desk-ledger.sh route <subject> <question>
#   fm-decision-desk-ledger.sh resolve <subject> <status>   # ruled|insufficient-source|escalated
#   fm-decision-desk-ledger.sh overturn <subject>            # mark last matching row overturned=yes
#   fm-decision-desk-ledger.sh tally                         # N routed, M ruled, K overturned
#   fm-decision-desk-ledger.sh path                          # print the ledger file path
#
# `resolve` and `overturn` update the LAST row matching <subject>, so a re-used
# subject updates its most recent request. A resolve with no matching row is
# reported and is a no-op, never an error that would disrupt supervision.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LEDGER="$DATA/decision-desk-ledger.md"

VALID_STATUSES="routed ruled insufficient-source escalated"

usage() {
  sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# True when a value is a safe single table cell (no pipe, no newline). Keeps the
# Markdown table parseable; a stray pipe would split a cell. one_line already
# collapses newlines, so this guards the pipe that would split a cell.
cell_safe() {
  local nl
  nl=$(printf '\nx'); nl=${nl%x}
  case "$1" in
    *"|"*) return 1 ;;
    *"$nl"*) return 1 ;;
  esac
  return 0
}

# Escape nothing but trim to a single line: collapse any embedded newline to a
# space so a multi-line question never breaks the row.
one_line() {
  printf '%s' "$1" | tr '\n' ' '
}

ensure_ledger() {
  mkdir -p "$DATA" || return 1
  if [ ! -f "$LEDGER" ]; then
    {
      printf '%s\n' '# Decision-desk value ledger'
      printf '%s\n' ''
      printf '%s\n' 'Firstmate-private durable state. One row per request routed to the decision-desk secondmate.'
      printf '%s\n' 'Owned by bin/fm-decision-desk-ledger.sh; appended at the secondmate-routing step. Never pruned.'
      printf '%s\n' 'The overturned cell may be hand-annotated (yes) when a ruling is later reversed.'
      printf '%s\n' ''
      printf '%s\n' '| when (UTC) | subject | question | status | overturned |'
      printf '%s\n' '| --- | --- | --- | --- | --- |'
    } >> "$LEDGER" || return 1
  fi
  return 0
}

cmd_route() {
  local subject=${1:-} question=${2:-} when
  [ -n "$subject" ] || { echo "route: missing <subject>" >&2; return 2; }
  [ -n "$question" ] || { echo "route: missing <question>" >&2; return 2; }
  question=$(one_line "$question")
  cell_safe "$subject" || { echo "route: unsafe subject (contains '|')" >&2; return 2; }
  cell_safe "$question" || { echo "route: unsafe question (contains '|')" >&2; return 2; }
  ensure_ledger || { echo "route: cannot create ledger" >&2; return 1; }
  when=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '| %s | %s | %s | routed | |\n' "$when" "$subject" "$question" >> "$LEDGER" \
    || { echo "route: append failed" >&2; return 1; }
  return 0
}

# Update the last row matching <subject>: set column $2 (status) or overturned.
# Args: subject column newvalue.
update_last_row() {
  local subject=$1 column=$2 newvalue=$3 tmp
  [ -f "$LEDGER" ] || { echo "update: no ledger yet" >&2; return 3; }
  tmp=$(mktemp) || return 1
  # Walk rows, remember the byte position of the last matching data row, then
  # rewrite that one row. awk keeps it single-pass and format-local.
  awk -v subj="$subject" -v col="$column" -v val="$newvalue" '
    BEGIN { FS="|"; OFS="|"; last=0 }
    # A data row starts with "| " and is not the header/separator.
    /^\| / && $0 !~ /^\| --- / && $0 !~ /^\| when \(UTC\)/ {
      # Trim surrounding spaces of the subject cell ($3).
      s=$3; gsub(/^ +| +$/, "", s)
      if (s == subj) { last=NR }
    }
    { line[NR]=$0 }
    END {
      if (last == 0) { exit 3 }
      for (i=1; i<=NR; i++) {
        if (i == last) {
          n=split(line[i], c, "|")
          # Cells: c[1]="" c[2]=when c[3]=subject c[4]=question c[5]=status c[6]=overturned c[7]=""
          if (col == "status") { c[5]=" " val " " }
          else if (col == "overturned") { c[6]=" " val " " }
          out=c[1]
          for (j=2; j<=n; j++) out=out "|" c[j]
          print out
        } else {
          print line[i]
        }
      }
    }
  ' "$LEDGER" > "$tmp"
  local rc=$?
  if [ "$rc" -eq 3 ]; then
    rm -f "$tmp"
    echo "update: no row for subject '$subject'" >&2
    return 3
  fi
  [ "$rc" -eq 0 ] || { rm -f "$tmp"; return 1; }
  cat "$tmp" > "$LEDGER" && rm -f "$tmp"
}

cmd_resolve() {
  local subject=${1:-} status=${2:-} ok=
  [ -n "$subject" ] || { echo "resolve: missing <subject>" >&2; return 2; }
  [ -n "$status" ] || { echo "resolve: missing <status>" >&2; return 2; }
  for s in $VALID_STATUSES; do [ "$s" = "$status" ] && ok=1; done
  [ -n "$ok" ] || { echo "resolve: status must be one of: $VALID_STATUSES" >&2; return 2; }
  update_last_row "$subject" status "$status"
}

cmd_overturn() {
  local subject=${1:-}
  [ -n "$subject" ] || { echo "overturn: missing <subject>" >&2; return 2; }
  update_last_row "$subject" overturned yes
}

cmd_tally() {
  local routed=0 ruled=0 insufficient=0 escalated=0 overturned=0
  if [ -f "$LEDGER" ]; then
    while IFS='|' read -r _ _when _subject _question status overturn _rest; do
      status=$(printf '%s' "$status" | tr -d ' ')
      overturn=$(printf '%s' "$overturn" | tr -d ' ')
      case "$status" in
        routed) routed=$((routed + 1)) ;;
        ruled) ruled=$((ruled + 1)) ;;
        insufficient-source) insufficient=$((insufficient + 1)) ;;
        escalated) escalated=$((escalated + 1)) ;;
        *) continue ;;
      esac
      [ "$overturn" = "yes" ] && overturned=$((overturned + 1))
    done < <(grep -E '^\| ' "$LEDGER" | grep -vE '^\| --- |^\| when \(UTC\)')
  fi
  local total=$((routed + ruled + insufficient + escalated))
  printf 'decision-desk ledger: %s requests total\n' "$total"
  printf '  routed (awaiting ruling): %s\n' "$routed"
  printf '  ruled: %s\n' "$ruled"
  printf '  insufficient-source: %s\n' "$insufficient"
  printf '  escalated: %s\n' "$escalated"
  printf '  overturned: %s\n' "$overturned"
}

main() {
  local cmd=${1:-}
  shift || true
  case "$cmd" in
    route) cmd_route "$@" ;;
    resolve) cmd_resolve "$@" ;;
    overturn) cmd_overturn "$@" ;;
    tally) cmd_tally "$@" ;;
    path) printf '%s\n' "$LEDGER" ;;
    -h | --help | help | '') usage ;;
    *) echo "unknown command: $cmd" >&2; usage >&2; return 2 ;;
  esac
}

main "$@"
