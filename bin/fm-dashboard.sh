#!/usr/bin/env bash
# fm-dashboard.sh - the captain's dashboard TUI (ADR-0032, CONTEXT.md glossary).
#
# The captain runs `bin/fm-dashboard.sh` in any shell pane and sees the
# fleet-wide backlog as one merged fzf list: every task from the PRIMARY home
# plus every registered secondmate home, each row a collapsed one-liner tagged
# with its home. This is the tracer bullet (firstmate issue #198) of a 6-ticket
# effort; later tickets add more panels as fzf modes cycled by keybind, so the
# snapshot/render seam here is deliberately panel-shaped for that extension.
#
# Interactive keys:
#   type            fuzzy-filter the list (fzf native)
#   ctrl-s          cycle sort: priority -> age -> repo -> priority
#   ctrl-t          cycle state filter: all -> queued -> in-flight -> all
#   ctrl-r          refresh: re-read every home's backlog, no restart
#   preview pane    the selected row's full body (collapsed by default),
#                   from `tasks-axi show <id> --full`
#   enter / esc     quit, leaving NOTHING running
#
# Read discipline (the single-parser rule, ADR-0032): every read flows ONLY
# through `tasks-axi list --all --file <home-backlog>` and
# `tasks-axi show <id> --full --file <home-backlog>`, run read-only per home.
# This script NEVER parses data/backlog.md or any owned format directly, and
# NEVER writes into any home's state. Secondmate homes are resolved from the
# registry (data/secondmates.md) through fm-ff-lib.sh's registry reader.
#
# No standing process, no polling: the list is a snapshot at launch plus the
# manual ctrl-r refresh. Quitting leaves no background process.
#
# Usage:
#   fm-dashboard.sh                 launch the interactive dashboard
#   fm-dashboard.sh --help          print this header
# Internal reentrancy subcommands (invoked by fzf keybinds, not by hand):
#   fm-dashboard.sh --snapshot <statedir>          re-read all homes into the cache
#   fm-dashboard.sh --snapshot-reload <statedir>   re-read all homes, then print rows
#   fm-dashboard.sh --rows <statedir>              print fzf rows from the cache
#   fm-dashboard.sh --cycle-sort <statedir>        rotate the sort mode
#   fm-dashboard.sh --cycle-filter <statedir>      rotate the state filter
#   fm-dashboard.sh --preview <backlog> <id>       render one row's full body
#
# Environment overrides (mainly for tests):
#   FM_ROOT_OVERRIDE, FM_HOME     resolve the code root and the primary home
#   FM_DATA_OVERRIDE              the primary home's data/ dir (registry lives here)
#   FM_DASHBOARD_TASKS_AXI        the tasks-axi command (default: tasks-axi)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
TASKS_AXI="${FM_DASHBOARD_TASKS_AXI:-tasks-axi}"

# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$SCRIPT_PATH"
}

# --- home enumeration -------------------------------------------------------
#
# dash_home_pairs prints one "tag<TAB>backlog-file" line per home to read: the
# primary home first, then each registered secondmate home. The tag is the
# home's registry id (or "primary"); the backlog file is <home>/data/backlog.md,
# never opened here - only handed to tasks-axi as its --file target.
dash_home_pairs() {
  printf 'primary\t%s\n' "$DATA/backlog.md"
  local reg="$DATA/secondmates.md" id home
  [ -f "$reg" ] || return 0
  while IFS=$'\t' read -r id home; do
    [ -n "$id" ] || continue
    [ -n "$home" ] || continue
    printf '%s\t%s\n' "$id" "$home/data/backlog.md"
  done < <(secondmate_registry_entries "$reg")
}

# --- snapshot ---------------------------------------------------------------
#
# dash_home_rows <tag> <backlog-file>: read ONE home through tasks-axi and emit
# the internal 9-column TSV, one row per task. Columns:
#   1 home  2 backlog-file  3 id  4 state  5 kind  6 repo  7 priority  8 created  9 title
# tasks-axi list emits a CSV dialect (comma-separated; a field is bare, or
# double-quoted with \" and \\ escapes when it holds a comma/quote/backslash).
# The awk parser below decodes exactly that dialect from the schema-tagged rows,
# so no backlog file is ever read directly.
dash_home_rows() {
  local tag=$1 file=$2 out
  out=$("$TASKS_AXI" list --all --fields priority,created --file "$file" 2>/dev/null) || return 0
  printf '%s\n' "$out" | awk -v home="$tag" -v file="$file" '
    # Decode the tasks-axi CSV dialect of one row into the fields[] array.
    function decode(line,   n, i, c, cur, inq, esc) {
      n = 0; cur = ""; inq = 0; esc = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (esc) { cur = cur c; esc = 0; continue }
        if (c == "\\") { esc = 1; continue }
        if (c == "\"") { inq = !inq; continue }
        if (c == "," && !inq) { fields[++n] = cur; cur = ""; continue }
        cur = cur c
      }
      fields[++n] = cur
      return n
    }
    BEGIN { intasks = 0 }
    /^tasks\[[0-9]+\]\{/ { intasks = 1; next }   # schema header opens the rows
    /^help\[/ { intasks = 0; next }
    /^count:/ { next }
    /^tasks:/ { next }                            # the "0 tasks" empty line
    {
      if (!intasks) next
      row = $0
      sub(/^  /, "", row)                         # strip the two-space indent
      if (row ~ /^- /) next                       # a help bullet, not a task row
      if (row == "") next
      n = decode(row)
      if (n < 7) next
      # schema: id,state,kind,repo,priority,title,created
      id = fields[1]; state = fields[2]; kind = fields[3]
      repo = fields[4]; pri = fields[5]; title = fields[6]; created = fields[7]
      gsub(/\t/, " ", title)                      # keep the row single-line/single-field
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
        home, file, id, state, kind, repo, pri, created, title
    }
  '
}

# dash_snapshot <cache-file>: rebuild the merged fleet cache by reading every
# home once. This is the whole read side; the interactive layer only ever
# filters and formats what this produced.
dash_snapshot() {
  local cache=$1 tag file tmp
  tmp="$cache.tmp.$$"
  : > "$tmp"
  while IFS=$'\t' read -r tag file; do
    [ -n "$tag" ] || continue
    dash_home_rows "$tag" "$file" >> "$tmp"
  done < <(dash_home_pairs)
  mv "$tmp" "$cache"
}

# --- render -----------------------------------------------------------------
#
# dash_rows <cache-file> <sort> <filter>: filter the cache by state and sort it,
# then print fzf input lines. Each fzf line is "<display>\t<backlog>\t<id>":
# fzf shows only the display column (--with-nth=1) and the hidden columns feed
# the preview subcommand for the selected row.
dash_rows() {
  local cache=$1 sort=$2 filter=$3
  [ -f "$cache" ] || return 0
  awk -F'\t' -v sortmode="$sort" -v filter="$filter" '
    BEGIN { us = sprintf("%c", 31) }             # unit separator: tie-break glue
    {
      state = $4
      if (filter == "queued" && state != "queued") next
      if (filter == "in_flight" && state != "in_flight") next
      # Build one tab-free sort key so `sort` orders on it and `cut` drops it
      # cleanly; the secondary tie-break is glued on with a unit separator.
      if (sortmode == "priority") {
        pri = ($7 ~ /^[0-9]+$/) ? $7 : 9        # unset priority sorts last
        key = pri us $8
      } else if (sortmode == "age") {
        created = ($8 == "-" || $8 == "") ? "9999-99-99" : $8
        key = created us $1                      # oldest first
      } else {
        repo = ($6 == "-" || $6 == "") ? "~" : tolower($6)
        key = repo us $1                          # unset repo sorts last
      }
      pridisp = ($7 ~ /^[0-9]+$/) ? ("p" $7) : "p-"
      repodisp = ($6 == "-" || $6 == "") ? "-" : $6
      display = sprintf("[%s] %-10s %-3s %-6s %-14s %s", \
        $1, state, pridisp, $5, repodisp, $9)
      printf "%s\t%s\t%s\t%s\n", key, display, $2, $3
    }
  ' "$cache" | LC_ALL=C sort -t$'\t' -k1,1 | cut -f2-
}

# --- interactive-state rotation --------------------------------------------

dash_next_sort() {
  case "$1" in
    priority) printf 'age\n' ;;
    age) printf 'repo\n' ;;
    *) printf 'priority\n' ;;
  esac
}

dash_next_filter() {
  case "$1" in
    all) printf 'queued\n' ;;
    queued) printf 'in_flight\n' ;;
    *) printf 'all\n' ;;
  esac
}

dash_read_state() {  # <statedir> <name> <default>
  local f="$1/$2"
  if [ -f "$f" ]; then
    tr -d '[:space:]' < "$f"
  else
    printf '%s' "$3"
  fi
}

# --- preview ----------------------------------------------------------------
#
# dash_preview <backlog-file> <id>: render the selected row's full body via the
# single-parser read path. Empty args (the fzf empty-list case) print nothing.
dash_preview() {
  local file=$1 id=$2
  [ -n "$id" ] || return 0
  [ -n "$file" ] || return 0
  "$TASKS_AXI" show "$id" --full --file "$file" 2>/dev/null || true
}

# --- interactive entry ------------------------------------------------------

dash_run() {
  command -v fzf >/dev/null 2>&1 || {
    echo "fm-dashboard: fzf is required but not installed" >&2
    return 2
  }
  local statedir cache
  statedir=$(mktemp -d "${TMPDIR:-/tmp}/fm-dashboard.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf '$statedir'" EXIT
  cache="$statedir/cache"
  printf 'priority' > "$statedir/sort"
  printf 'all' > "$statedir/filter"
  dash_snapshot "$cache"

  local header
  header=$(printf 'Fleet backlog  |  ctrl-s sort  ctrl-t state  ctrl-r refresh  enter/esc quit')
  fzf --ansi \
    --delimiter=$'\t' --with-nth=1 \
    --header="$header" \
    --preview "$SCRIPT_PATH --preview {2} {3}" \
    --preview-window 'right,55%,wrap' \
    --bind "ctrl-s:execute-silent($SCRIPT_PATH --cycle-sort $statedir)+reload($SCRIPT_PATH --rows $statedir)" \
    --bind "ctrl-t:execute-silent($SCRIPT_PATH --cycle-filter $statedir)+reload($SCRIPT_PATH --rows $statedir)" \
    --bind "ctrl-r:reload($SCRIPT_PATH --snapshot-reload $statedir)" \
    < <("$SCRIPT_PATH" --rows "$statedir") || true
}

# --- Main entry: run only when executed, not when sourced by tests. ---------
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

case "${1:-}" in
  --help | -h)
    usage
    ;;
  --snapshot)
    [ $# -ge 2 ] || { echo "fm-dashboard: --snapshot needs a statedir" >&2; exit 2; }
    dash_snapshot "$2/cache"
    ;;
  --rows)
    [ $# -ge 2 ] || { echo "fm-dashboard: --rows needs a statedir" >&2; exit 2; }
    dash_rows "$2/cache" \
      "$(dash_read_state "$2" sort priority)" \
      "$(dash_read_state "$2" filter all)"
    ;;
  --snapshot-reload)
    # ctrl-r: re-read the fleet, then emit the freshly filtered/sorted rows.
    [ $# -ge 2 ] || { echo "fm-dashboard: --snapshot-reload needs a statedir" >&2; exit 2; }
    dash_snapshot "$2/cache"
    dash_rows "$2/cache" \
      "$(dash_read_state "$2" sort priority)" \
      "$(dash_read_state "$2" filter all)"
    ;;
  --cycle-sort)
    [ $# -ge 2 ] || { echo "fm-dashboard: --cycle-sort needs a statedir" >&2; exit 2; }
    dash_next_sort "$(dash_read_state "$2" sort priority)" > "$2/sort"
    ;;
  --cycle-filter)
    [ $# -ge 2 ] || { echo "fm-dashboard: --cycle-filter needs a statedir" >&2; exit 2; }
    dash_next_filter "$(dash_read_state "$2" filter all)" > "$2/filter"
    ;;
  --preview)
    dash_preview "${2:-}" "${3:-}"
    ;;
  '')
    dash_run
    ;;
  *)
    echo "fm-dashboard: unknown argument: $1" >&2
    usage >&2
    exit 2
    ;;
esac
