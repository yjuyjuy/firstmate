#!/usr/bin/env bash
# fm-dashboard.sh - the captain's dashboard TUI (ADR-0032, CONTEXT.md glossary).
#
# The captain runs `bin/fm-dashboard.sh` in any shell pane and sees the fleet as
# a set of fzf panels cycled by keybind, one list at a time (ADR-0032):
#   backlog    every task from the PRIMARY home plus every registered secondmate
#              home, each row a collapsed one-liner tagged with its home.
#   decisions  every CAPTAIN DECISION across the fleet (CONTEXT.md glossary): an
#              item blocked solely on captain judgment, merged from three
#              sources and each row tagged with its home AND its source -
#              captain-kind backlog holds (source `hold`), decision-desk requests
#              (source `desk`), and unanswered transcript questions (source
#              `question`). Expand (preview) shows the full body.
# ctrl-p cycles between the panels without losing the fzf session. The
# snapshot/render seam is panel-shaped: each panel has its own cache and its own
# reentrancy subcommands, but they share one fzf process, one fuzzy filter, and
# one refresh key. This grew from the tracer bullet (firstmate issue #198); the
# decisions panel is issue #199.
#
# Interactive keys:
#   type            fuzzy-filter the current panel (fzf native)
#   ctrl-p          cycle panel: backlog <-> decisions (keeps the session)
#   ctrl-s          backlog only: cycle sort priority -> age -> repo -> priority
#   ctrl-t          cycle a filter: backlog state all/queued/in-flight;
#                   decisions source all/hold/desk/question
#   ctrl-r          refresh: re-read the fleet for the ACTIVE panel, no restart
#   preview pane    the selected row's full body (collapsed by default)
#   enter / esc     quit, leaving NOTHING running
#
# Read discipline (the single-parser rule, ADR-0032): every read flows ONLY
# through an owning tool, run read-only per home, and this script NEVER parses an
# owned format directly nor writes into any home's state. The owners are:
#   backlog + holds   `tasks-axi list/show ... --file <home>/data/backlog.md`
#   decision-desk     `fm-decision-desk-ledger.sh list` (per home's data dir)
#   transcript        `fm-desk-transcript.sh list` (per home's state feed), whose
#                     jsonl is decoded with jq (the JSON tool), never hand-parsed
# Secondmate homes are resolved from the registry (data/secondmates.md) through
# fm-ff-lib.sh's registry reader.
#
# No standing process, no polling: each panel is a snapshot at launch plus the
# manual ctrl-r refresh. Quitting leaves no background process.
#
# Usage:
#   fm-dashboard.sh                 launch the interactive dashboard
#   fm-dashboard.sh --help          print this header
# Internal reentrancy subcommands (invoked by fzf keybinds, not by hand):
#   fm-dashboard.sh --snapshot <statedir>          re-read all homes into the backlog cache
#   fm-dashboard.sh --decisions-snapshot <statedir>  re-read all homes into the decisions cache
#   fm-dashboard.sh --snapshot-reload <statedir>   re-read the ACTIVE panel, then print rows
#   fm-dashboard.sh --rows <statedir>              print fzf rows for the ACTIVE panel
#   fm-dashboard.sh --cycle-panel <statedir>       switch the active panel
#   fm-dashboard.sh --cycle-sort <statedir>        rotate the backlog sort mode
#   fm-dashboard.sh --cycle-filter <statedir>      rotate the active panel's filter
#   fm-dashboard.sh --preview <a> <b> <c>          render one selected row's full body
#
# Environment overrides (mainly for tests):
#   FM_ROOT_OVERRIDE, FM_HOME     resolve the code root and the primary home
#   FM_DATA_OVERRIDE              the primary home's data/ dir (registry lives here)
#   FM_DASHBOARD_TASKS_AXI        the tasks-axi command (default: tasks-axi)
#   FM_DASHBOARD_LEDGER           the decision-desk ledger tool (default: sibling script)
#   FM_DASHBOARD_TRANSCRIPT       the transcript producer (default: sibling script)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
TASKS_AXI="${FM_DASHBOARD_TASKS_AXI:-tasks-axi}"
LEDGER_TOOL="${FM_DASHBOARD_LEDGER:-$SCRIPT_DIR/fm-decision-desk-ledger.sh}"
TRANSCRIPT_TOOL="${FM_DASHBOARD_TRANSCRIPT:-$SCRIPT_DIR/fm-desk-transcript.sh}"

# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$SCRIPT_PATH"
}

# --- home enumeration -------------------------------------------------------
#
# dash_home_dirs prints one "tag<TAB>datadir<TAB>statedir" line per home to read:
# the primary home first, then each registered secondmate home. The tag is the
# home's registry id (or "primary"). This is the single home-enumeration seam;
# every panel derives its per-home read targets from it (backlog.md and the
# decision-desk ledger live under datadir; the transcript feed under statedir).
dash_home_dirs() {
  printf 'primary\t%s\t%s\n' "$DATA" "${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  local reg="$DATA/secondmates.md" id home
  [ -f "$reg" ] || return 0
  while IFS=$'\t' read -r id home; do
    [ -n "$id" ] || continue
    [ -n "$home" ] || continue
    printf '%s\t%s\t%s\n' "$id" "$home/data" "$home/state"
  done < <(secondmate_registry_entries "$reg")
}

# dash_home_pairs prints one "tag<TAB>backlog-file" line per home for the backlog
# panel. The backlog file is <datadir>/backlog.md, never opened here - only
# handed to tasks-axi as its --file target.
dash_home_pairs() {
  local tag data _state
  while IFS=$'\t' read -r tag data _state; do
    [ -n "$tag" ] || continue
    printf '%s\t%s/backlog.md\n' "$tag" "$data"
  done < <(dash_home_dirs)
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

# --- decisions panel: read side --------------------------------------------
#
# A CAPTAIN DECISION (CONTEXT.md glossary) is any item blocked solely on captain
# judgment, from three sources. Each source has ONE owner and is read only
# through it (the single-parser rule); this panel NEVER hand-parses backlog.md,
# the ledger table, or the transcript jsonl. The decisions cache is a 5-column
# TSV, one row per decision:
#   1 home  2 source  3 rowid  4 display-title  5 body(base64)
# The body is base64 so a multi-line body (a `tasks-axi show` dump) survives as
# a single cache line; the preview decodes it. rowid is unique per snapshot
# ("<home>:<source>:<n>") and is the token the preview looks up.

# b64enc / b64dec: encode a body to a single line and back. base64 wraps output
# by default, so strip the newlines on the way in; the reader tolerates either.
b64enc() { base64 | tr -d '\n'; }
b64dec() { base64 -d 2>/dev/null || true; }

# One tab/newline-free display title cell.
dash_clean_title() { printf '%s' "$1" | tr '\t\n' '  '; }

# dash_home_holds <home> <backlog-file> <cache-tmp> <counter-var>: captain-kind
# backlog holds. Read ONLY through tasks-axi: `list --state held` with the
# hold_kind/hold_reason fields, then `show --full` for the body. Schema of the
# list rows: id,state,kind,repo,priority,title,hold_kind,hold_reason.
dash_home_holds() {
  local home=$1 file=$2 tmp=$3 out n=0 line
  out=$("$TASKS_AXI" list --all --state held --fields hold_kind,hold_reason --file "$file" 2>/dev/null) || return 0
  # Decode the CSV dialect the same way dash_home_rows does, emitting a
  # tab-joined "id<TAB>title<TAB>reason" for each captain-kind held task.
  while IFS=$'\t' read -r id title reason; do
    [ -n "$id" ] || continue
    n=$((n + 1))
    local body rowid
    body=$("$TASKS_AXI" show "$id" --full --file "$file" 2>/dev/null) || body="$title"
    [ -n "$body" ] || body="$title"
    rowid="$home:hold:$n"
    line=$(dash_clean_title "$id: ${reason:-$title}")
    printf '%s\thold\t%s\t%s\t%s\n' "$home" "$rowid" "$line" "$(printf '%s' "$body" | b64enc)" >> "$tmp"
  done < <(printf '%s\n' "$out" | awk '
    function decode(s,   i,c,cur,inq,esc,nf) {
      nf=0; cur=""; inq=0; esc=0
      for (i=1;i<=length(s);i++) {
        c=substr(s,i,1)
        if (esc) { cur=cur c; esc=0; continue }
        if (c=="\\") { esc=1; continue }
        if (c=="\"") { inq=!inq; continue }
        if (c=="," && !inq) { f[++nf]=cur; cur=""; continue }
        cur=cur c
      }
      f[++nf]=cur; return nf
    }
    BEGIN { intasks=0 }
    /^tasks\[[0-9]+\]\{/ { intasks=1; next }
    /^help\[/ { intasks=0; next }
    /^count:/ { next }
    /^tasks:/ { next }
    {
      if (!intasks) next
      row=$0; sub(/^  /,"",row)
      if (row ~ /^- /) next
      if (row=="") next
      nf=decode(row)
      if (nf < 8) next
      # id,state,kind,repo,priority,title,hold_kind,hold_reason
      if (f[7] != "captain") next
      t=f[6]; r=f[8]
      gsub(/\t/," ",t); gsub(/\t/," ",r)
      printf "%s\t%s\t%s\n", f[1], t, r
    }')
}

# dash_home_desk <home> <datadir> <cache-tmp> <counter-start>: pending
# decision-desk requests. Read ONLY through the ledger owner's `list` verb (TSV:
# subject<TAB>question<TAB>when<TAB>status); the body is the question.
dash_home_desk() {
  local home=$1 datadir=$2 tmp=$3 n=0 subject question when status rowid line
  while IFS=$'\t' read -r subject question when status; do
    [ -n "$subject" ] || continue
    n=$((n + 1))
    rowid="$home:desk:$n"
    line=$(dash_clean_title "$subject: $question")
    printf '%s\tdesk\t%s\t%s\t%s\n' "$home" "$rowid" "$line" \
      "$(printf 'decision-desk request (%s)\nsubject: %s\nasked: %s\n\n%s\n' \
         "$status" "$subject" "$when" "$question" | b64enc)" >> "$tmp"
  done < <(FM_DATA_OVERRIDE="$datadir" "$LEDGER_TOOL" list 2>/dev/null || true)
}

# dash_home_questions <home> <statedir> <cache-tmp> <counter-start>: unanswered
# transcript questions. Read ONLY through the transcript owner's `list` verb
# (jsonl); jq (the JSON tool) selects question records with an empty/absent
# answer. Never hand-parse the jsonl. The feed is append-only, so a question is
# "answered" by a later record for the same text carrying an answer: collapse to
# the LATEST record per question and keep it only when that record is unanswered,
# so answering a question drops it on the next refresh.
dash_home_questions() {
  local home=$1 statedir=$2 tmp=$3 n=0 q rowid line
  command -v jq >/dev/null 2>&1 || return 0
  local feed="$statedir/desk-transcript.jsonl"
  while IFS= read -r q; do
    [ -n "$q" ] || continue
    n=$((n + 1))
    rowid="$home:question:$n"
    line=$(dash_clean_title "$q")
    printf '%s\tquestion\t%s\t%s\t%s\n' "$home" "$rowid" "$line" \
      "$(printf 'unanswered captain question\n\n%s\n' "$q" | b64enc)" >> "$tmp"
  done < <(FM_DESK_TRANSCRIPT="$feed" "$TRANSCRIPT_TOOL" list 2>/dev/null \
    | jq -rs '[ .[] | select(.kind == "question") ]
              | reverse | unique_by(.q)
              | .[] | select((.a // "") == "") | .q' 2>/dev/null || true)
}

# dash_decisions_snapshot <cache-file>: rebuild the merged decisions cache by
# reading every home's three sources once. The whole read side of the panel.
dash_decisions_snapshot() {
  local cache=$1 tag data state tmp
  tmp="$cache.tmp.$$"
  : > "$tmp"
  while IFS=$'\t' read -r tag data state; do
    [ -n "$tag" ] || continue
    dash_home_holds "$tag" "$data/backlog.md" "$tmp"
    dash_home_desk "$tag" "$data" "$tmp"
    dash_home_questions "$tag" "$state" "$tmp"
  done < <(dash_home_dirs)
  mv "$tmp" "$cache"
}

# dash_decisions_rows <cache-file> <filter>: filter the decisions cache by source
# and print fzf input lines. Each line is "<display>\tdecision\t<cache>\t<rowid>":
# fzf shows only the display column and the hidden columns feed the preview.
dash_decisions_rows() {
  local cache=$1 filter=$2
  [ -f "$cache" ] || return 0
  awk -F'\t' -v filter="$filter" -v cache="$cache" '
    {
      home=$1; source=$2; rowid=$3; title=$4
      if (filter != "all" && filter != source) next
      display=sprintf("[%s] %-8s %s", home, source, title)
      printf "%s\tdecision\t%s\t%s\n", display, cache, rowid
    }
  ' "$cache" | LC_ALL=C sort -t$'\t' -k1,1
}

# dash_next_decisions_filter: rotate the decisions source filter.
dash_next_decisions_filter() {
  case "$1" in
    all) printf 'hold\n' ;;
    hold) printf 'desk\n' ;;
    desk) printf 'question\n' ;;
    *) printf 'all\n' ;;
  esac
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
      if (state != "queued" && state != "in_flight") next
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

# --- panel dispatch ---------------------------------------------------------
#
# Both panels share ONE fzf session (ADR-0032: cycling must not lose it). The
# active panel is a scrap of state; ctrl-p flips it and the row/refresh/filter
# keybinds route to whichever panel is active. Caches are per-panel:
#   $statedir/cache   backlog rows      $statedir/dcache  decisions rows

dash_next_panel() {
  case "$1" in
    backlog) printf 'decisions\n' ;;
    *) printf 'backlog\n' ;;
  esac
}

# dash_active_rows <statedir>: print the fzf rows for whichever panel is active.
dash_active_rows() {
  local sd=$1 panel
  panel=$(dash_read_state "$sd" panel backlog)
  if [ "$panel" = decisions ]; then
    dash_decisions_rows "$sd/dcache" "$(dash_read_state "$sd" dfilter all)"
  else
    dash_rows "$sd/cache" \
      "$(dash_read_state "$sd" sort priority)" \
      "$(dash_read_state "$sd" filter all)"
  fi
}

# dash_active_snapshot_reload <statedir>: re-read the fleet for the active panel
# (ctrl-r), then print its freshly filtered rows.
dash_active_snapshot_reload() {
  local sd=$1 panel
  panel=$(dash_read_state "$sd" panel backlog)
  if [ "$panel" = decisions ]; then
    dash_decisions_snapshot "$sd/dcache"
  else
    dash_snapshot "$sd/cache"
  fi
  dash_active_rows "$sd"
}

# dash_active_cycle_filter <statedir>: rotate the active panel's filter (ctrl-t).
dash_active_cycle_filter() {
  local sd=$1 panel
  panel=$(dash_read_state "$sd" panel backlog)
  if [ "$panel" = decisions ]; then
    dash_next_decisions_filter "$(dash_read_state "$sd" dfilter all)" > "$sd/dfilter"
  else
    dash_next_filter "$(dash_read_state "$sd" filter all)" > "$sd/filter"
  fi
}

# dash_cycle_panel <statedir>: flip the active panel and lazily build the panel's
# cache on first visit, so the decisions snapshot is not paid unless it is shown.
dash_cycle_panel() {
  local sd=$1 next
  next=$(dash_next_panel "$(dash_read_state "$sd" panel backlog)")
  printf '%s' "$next" > "$sd/panel"
  if [ "$next" = decisions ] && [ ! -f "$sd/dcache" ]; then
    dash_decisions_snapshot "$sd/dcache"
  elif [ "$next" = backlog ] && [ ! -f "$sd/cache" ]; then
    dash_snapshot "$sd/cache"
  fi
}

# dash_active_header <statedir>: the fzf header line for the active panel, naming
# its live keybinds. One footer form for both panels keeps the seam uniform.
dash_active_header() {
  local sd=$1 panel
  panel=$(dash_read_state "$sd" panel backlog)
  if [ "$panel" = decisions ]; then
    printf 'Captain decisions  |  ctrl-p panel  ctrl-t source  ctrl-r refresh  enter/esc quit'
  else
    printf 'Fleet backlog  |  ctrl-p panel  ctrl-s sort  ctrl-t state  ctrl-r refresh  enter/esc quit'
  fi
}

# --- preview ----------------------------------------------------------------
#
# dash_preview <a> <b> <c>: render the selected row's full body. One preview
# serves both panels, discriminated by the row's hidden marker column:
#   backlog row   "<display>\t<backlog-file>\t<id>"        -> a=file  b=id
#   decision row  "<display>\tdecision\t<cache>\t<rowid>"  -> a=decision b=cache c=rowid
# A backlog body reads through tasks-axi show --full (the single-parser path); a
# decision body is the base64 body already captured in the decisions cache by
# its owner-only read. Empty args (the fzf empty-list case) print nothing.
dash_preview() {
  local a=${1:-} b=${2:-} c=${3:-}
  if [ "$a" = decision ]; then
    dash_decision_preview "$b" "$c"
    return 0
  fi
  local file=$a id=$b
  [ -n "$id" ] || return 0
  [ -n "$file" ] || return 0
  "$TASKS_AXI" show "$id" --full --file "$file" 2>/dev/null || true
}

# dash_decision_preview <cache> <rowid>: print the decoded body of the decisions
# cache row whose rowid matches. The body was captured through the source owner
# at snapshot time, so nothing is re-parsed here.
dash_decision_preview() {
  local cache=$1 rowid=$2 b64
  [ -n "$rowid" ] || return 0
  [ -f "$cache" ] || return 0
  b64=$(awk -F'\t' -v want="$rowid" '$3 == want { print $5; exit }' "$cache")
  [ -n "$b64" ] || return 0
  printf '%s' "$b64" | b64dec
}

# --- interactive entry ------------------------------------------------------

dash_run() {
  command -v fzf >/dev/null 2>&1 || {
    echo "fm-dashboard: fzf is required but not installed" >&2
    return 2
  }
  local statedir
  statedir=$(mktemp -d "${TMPDIR:-/tmp}/fm-dashboard.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf '$statedir'" EXIT
  printf 'backlog' > "$statedir/panel"
  printf 'priority' > "$statedir/sort"
  printf 'all' > "$statedir/filter"
  printf 'all' > "$statedir/dfilter"
  dash_snapshot "$statedir/cache"

  # One fzf session serves both panels (ADR-0032). ctrl-p flips the active panel
  # and reloads its rows + header WITHOUT restarting fzf, so the session and its
  # fuzzy query survive the cycle. ctrl-s/ctrl-t/ctrl-r route to the active panel.
  fzf --ansi \
    --delimiter=$'\t' --with-nth=1 \
    --header="$(dash_active_header "$statedir")" \
    --preview "$SCRIPT_PATH --preview {2} {3} {4}" \
    --preview-window 'right,55%,wrap' \
    --bind "ctrl-p:execute-silent($SCRIPT_PATH --cycle-panel $statedir)+transform-header($SCRIPT_PATH --header $statedir)+reload($SCRIPT_PATH --rows $statedir)" \
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
  --decisions-snapshot)
    [ $# -ge 2 ] || { echo "fm-dashboard: --decisions-snapshot needs a statedir" >&2; exit 2; }
    dash_decisions_snapshot "$2/dcache"
    ;;
  --rows)
    [ $# -ge 2 ] || { echo "fm-dashboard: --rows needs a statedir" >&2; exit 2; }
    dash_active_rows "$2"
    ;;
  --snapshot-reload)
    # ctrl-r: re-read the fleet for the ACTIVE panel, then emit its fresh rows.
    [ $# -ge 2 ] || { echo "fm-dashboard: --snapshot-reload needs a statedir" >&2; exit 2; }
    dash_active_snapshot_reload "$2"
    ;;
  --cycle-panel)
    [ $# -ge 2 ] || { echo "fm-dashboard: --cycle-panel needs a statedir" >&2; exit 2; }
    dash_cycle_panel "$2"
    ;;
  --header)
    [ $# -ge 2 ] || { echo "fm-dashboard: --header needs a statedir" >&2; exit 2; }
    dash_active_header "$2"
    ;;
  --cycle-sort)
    [ $# -ge 2 ] || { echo "fm-dashboard: --cycle-sort needs a statedir" >&2; exit 2; }
    dash_next_sort "$(dash_read_state "$2" sort priority)" > "$2/sort"
    ;;
  --cycle-filter)
    # ctrl-t: rotate whichever filter the ACTIVE panel owns.
    [ $# -ge 2 ] || { echo "fm-dashboard: --cycle-filter needs a statedir" >&2; exit 2; }
    dash_active_cycle_filter "$2"
    ;;
  --preview)
    dash_preview "${2:-}" "${3:-}" "${4:-}"
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
