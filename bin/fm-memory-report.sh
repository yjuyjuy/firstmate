#!/usr/bin/env bash
# fm-memory-report.sh - answer "what is actually eating this machine's memory,
# and who owns it" accurately and the SAME way every time.
#
# Invoked MANUALLY, on request, like bin/fm-desk-refresh.sh. No daemon, no
# watcher wiring, no schedule. It is READ-ONLY over the system and the fleet: it
# kills nothing, stops nothing, and shortens no work.
#
# Usage:
#   fm-memory-report.sh              compact ranking, owner groups, reclaim list
#   fm-memory-report.sh --all        every process, not just the top slice
#   fm-memory-report.sh --limit N    show N processes in the ranking (default 20)
#   fm-memory-report.sh --tree       group every process under its owner
#   fm-memory-report.sh --json       machine-readable form for other scripts
#   fm-memory-report.sh --verify     cross-check the reading against footprint(1)
#   fm-memory-report.sh --help
#
# Exit status:
#   0  a reading was taken and reported
#   1  a required input could not be collected at all
#   3  REFUSED - the reading or the record set cannot be stood behind; no table
#      was printed. A refusal is the correct output when the instrument is broken
#   64 usage error
#
# WHAT IT MEASURES. phys_footprint, the same quantity Activity Monitor's Memory
# column shows, read from top(1) and cross-checkable with --verify. On Linux the
# measured quantity is pss, each process's proportional resident share read from
# /proc/<pid>/smaps_rollup (VmRSS from status when a mapping table is
# unreadable), with host totals from /proc/meminfo; the platform guard keeps
# macOS on top(1). rss is shown only beside it, always labelled, and never sorts
# the ranking: under swap the two diverge badly and unevenly in BOTH directions.
#
# HOW IT ATTRIBUTES. Every process is enumerated with no name filter deciding
# what counts; names only label a process already counted. Ownership is read from
# durable records - state/*.meta `worktree=`/`home=`/`tasktmp=`,
# data/secondmates.md, $FM_HOME, and the project clones - matched against each
# process's working directory. Ancestry is never the first word, because a
# reparented process reports ppid 1 and cannot be told from a daemon that way.
# "unowned" means the records were read and none matched; a process whose facts
# could not be read is "unclassified" and never becomes a finding.
#
# NEVER WAKES. This script must never call bin/fm-wake-lib.sh, fm_wake_append,
# bin/fm-send.sh, or append to a status file - the same contract
# bin/fm-desk-refresh.sh documents. Taking a reading is not captain-facing
# progress (AGENTS.md section 8), so it reports to its caller and interrupts
# nobody.
#
# NOT bin/fm-resource-check.sh. That script answers a different question - host
# pressure and the concurrent-agent ceiling - and other code depends on its
# contract. This script never calls it and never changes it.
#
# WHY IT IS BUILT THIS WAY. docs/memory-report.md is the single owner of the
# rationale and the measurements: the incident that produced it, the top(1) vs
# footprint(1) evidence, the rss divergence figures, why pstree is not an input,
# the language-server rollup, the self-check thresholds, and the attribution
# defect of 2026-07-24. Read it before changing any threshold or bucket rule.
#
# A LISTENING SERVER IS NEVER A LEFTOVER. A process holding a LISTEN socket is
# serving something - a shared dev backend, a database proxy, a web server. On
# this fleet a shared stack is started deliberately by one lane to serve the
# WHOLE fleet, so it has NO owning task by design: once its starting lane tore
# down, "unowned" is its natural state, not evidence it is disposable. Billing
# such a server as reclaimable once cost a lane its test gate (docs/memory-report.md,
# 2026-08-01). So a process with a listening socket is surfaced in its own
# `server` class WITH its ports and is excluded from the reclaim list entirely.
# The listen socket is positive evidence the process is serving something, never
# a guess from the path shape - and note absence of a local mongod is NOT used as
# a liveness test, because a shared stack's database is remote and it needs no
# local mongod.
#
# Test seams: FM_MEMREPORT_TOP and FM_MEMREPORT_PS read a captured listing from a
# file instead of running the tool, FM_MEMREPORT_LSOF likewise for working
# directories, FM_MEMREPORT_LISTEN likewise for listening-socket ports (a
# pid<TAB>port listing), FM_MEMREPORT_PROC points the Linux reader at a
# proc-shaped directory instead of /proc, and FM_MEMREPORT_SELF_PID overrides
# which pid the self-check requires to be present.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Platform split: the primary memory source is top(1) on macOS and /proc on
# Linux, and the host totals come from different places too. Everything else -
# parsing, self-checks, attribution, rendering - is shared, because the Linux
# reader emits the same normalized listing shape parse_top already reads.
case "$(uname -s)" in
  Linux) PLATFORM=linux; OS_LABEL=linux ;;
  Darwin) PLATFORM=macos; OS_LABEL=macOS ;;
  *) PLATFORM=other; OS_LABEL=macOS ;;
esac

# What the ranking column measures, stated where the report names its own
# quantity. The macOS defaults describe top(1)'s phys_footprint; the Linux
# reader overrides them with pss.
MEASURED_LABEL=phys_footprint
MEASURED_DESC='the same quantity Activity Monitor shows'
MEASURED_PAREN='Activity Monitor Memory column'

# Was FM_HOME chosen by the caller, or are we falling back to this code root?
# The distinction matters: an explicit home is honored exactly, while a fallback
# may be redirected below. Recorded before the fallback assignment overwrites it.
FM_HOME_EXPLICIT=${FM_HOME+yes}
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# HOME RESOLUTION. This script is frequently invoked from a disposable worktree
# of firstmate - a crewmate checking the machine it is working on. A worktree has
# no state/ of its own, so falling back to the code root found ZERO records while
# every fleet process kept its working directory. The report then said "no record
# claims it" about live lanes, having read no records at all, and listed 4.23 GB
# of live work as reclaimable. That is the exact failure class this script
# exists to prevent, so the fallback now resolves to the real home instead.
#
# A git worktree's common dir is the primary checkout's .git, which is a durable
# fact rather than a guess about paths. Only ever consulted when the caller did
# NOT set FM_HOME, and only accepted when it actually holds records.
if [ -z "$FM_HOME_EXPLICIT" ] && [ -z "${FM_ROOT_OVERRIDE:-}" ] && [ -z "${FM_STATE_OVERRIDE:-}" ]; then
  if ! compgen -G "$FM_HOME/state/*.meta" >/dev/null 2>&1; then
    _common=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null || true)
    if [ -n "$_common" ]; then
      case "$_common" in /*) : ;; *) _common="$FM_ROOT/$_common" ;; esac
      _primary=$(cd "$(dirname "$_common")" 2>/dev/null && pwd -P) || _primary=
      if [ -n "$_primary" ] && compgen -G "$_primary/state/*.meta" >/dev/null 2>&1; then
        FM_HOME=$_primary
        FM_HOME_REDIRECTED=$_primary
      fi
    fi
    unset _common _primary
  fi
fi

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# Share of agent-kind processes that may come back unowned before the reading is
# treated as suspect. Fleet agents run inside recorded worktrees, so a high share
# is the signature of records not being read - not of an idle machine.
UNOWNED_AGENT_WARN_PCT=${FM_MEMREPORT_AGENT_WARN_PCT:-60}

# Self-check thresholds. Deliberately generous: they exist to catch an
# obviously broken instrument (the 31-process reading), not to police normal
# sampling drift between two tools read a fraction of a second apart.
MIN_PROCS=${FM_MEMREPORT_MIN_PROCS:-50}
COUNT_TOLERANCE_PCT=30
# The summed footprint normally sits ABOVE used memory, because footprint counts
# compressed pages and charges shared regions to each process. Measured on this
# machine 2026-07-24: 111% across five consecutive samples, and 126% under
# heavier load. The floor is therefore one-sided and set at 60% - a 1.85x margin
# below the lowest reading actually observed, while still catching a listing that
# has lost most of the machine's memory.
FOOTPRINT_FLOOR_PCT=60
# On Linux the summed pss NEVER runs above used memory: kernel memory and page
# cache are not process memory, so the floor is anchored to the process listing
# instead - summed pss against the ps listing's summed rss, measured 66% on
# 2026-08-26 and floored at 30% (2.2x margin). docs/memory-report.md owns the
# evidence for both rules.
FOOTPRINT_FLOOR_PCT_LINUX=30
# The upper bound on the same ratio, guarding double-counted rows rather than a
# truncated listing. Set far above the observed 111-126% so ordinary shared
# memory never trips it.
FOOTPRINT_CEILING_PCT=400

# The header comment IS the help text: every line from the description down to
# the first line of code. Derived rather than a hardcoded line range so the help
# cannot drift out of sync with the header it is quoting.
usage() {
  awk 'NR==1 { next } /^[^#]/ { exit } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

die() { printf 'fm-memory-report: %s\n' "$1" >&2; exit "${2:-1}"; }

# refuse <reason> <detail>...: the SELF-CHECK failure path. Prints what is wrong
# and exits 3 WITHOUT printing a ranking. Never soften this into a warning: a
# confident wrong table is the exact failure this script was built to end.
refuse() {
  local reason=$1
  shift
  {
    printf 'fm-memory-report: REFUSING to report - the reading is not trustworthy.\n'
    printf '  problem: %s\n' "$reason"
    local line
    for line in "$@"; do printf '  %s\n' "$line"; done
    printf '  No ranking was printed. A refusal is the correct output when the\n'
    printf '  instrument is broken; re-run to take a fresh reading.\n'
  } >&2
  exit 3
}

# --- argument parsing -------------------------------------------------------

mode=text
show_all=0
show_tree=0
verify=0
limit=20

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --all) show_all=1 ;;
    --tree) show_tree=1 ;;
    --json) mode=json ;;
    --verify) verify=1 ;;
    --limit)
      shift
      [ "$#" -gt 0 ] || die "--limit needs a number" 64
      case "$1" in ''|*[!0-9]*) die "--limit needs a number, got '$1'" 64 ;; esac
      limit=$1
      ;;
    *) die "unknown option '$1' (see --help)" 64 ;;
  esac
  shift
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-memory-report.XXXXXX") || die "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT

SELF_PID=${FM_MEMREPORT_SELF_PID:-$$}

# --- collection -------------------------------------------------------------

# top(1) is the primary measurement on macOS: its MEM column is phys_footprint
# (see MEASUREMENT above). Captured whole so the header counters used by the
# self-check come from the SAME sample as the per-process numbers. Linux gets
# the /proc reader below; the two share one output shape.
collect_top() {
  if [ -n "${FM_MEMREPORT_TOP:-}" ]; then
    [ -r "$FM_MEMREPORT_TOP" ] || die "FM_MEMREPORT_TOP is not readable: $FM_MEMREPORT_TOP"
    cat "$FM_MEMREPORT_TOP" > "$TMP/top.raw"
    return 0
  fi
  if [ -n "${FM_MEMREPORT_PROC:-}" ] || [ "$PLATFORM" = linux ]; then
    collect_top_linux
    return 0
  fi
  command -v top >/dev/null 2>&1 || die "top(1) not found; it is the primary memory source"
  top -l 1 -n 20000 -o mem -stats pid,mem > "$TMP/top.raw" 2>/dev/null || true
  [ -s "$TMP/top.raw" ] || die "top(1) produced no output"
}

# Linux primary source: enumerate /proc and read each process's PSS in one pass,
# then emit a listing in the SAME normalized shape parse_top reads (Processes: /
# PhysMem: / PID rows), so every downstream gate and renderer is shared with the
# macOS path. PSS is the honest Linux analog of phys_footprint: unlike rss it
# charges shared pages proportionally, so it never double-counts a shared
# library and never overstates a swapped-out process. When smaps_rollup is
# unreadable (a mapping table needs ptrace permission), fall back to VmRSS from
# status, which is world-readable; that is a fact about readability, not about
# ownership, and the process is still counted - the same stance the lsof-denied
# cwd takes. A zero-RSS process (kernel thread, zombie) still gets its 0K row so
# the two enumerations keep agreeing.
collect_top_linux() {
  local procdir used_kb n p
  local -a pids=()
  procdir=${FM_MEMREPORT_PROC:-/proc}
  [ -d "$procdir" ] || die "the process table is not readable: $procdir"
  used_kb=$(awk '
    /^MemTotal:/ { t = $2 }
    /^MemAvailable:/ { a = $2 }
    END { printf "%d", (t > a ? t - a : 0) }
  ' "$procdir/meminfo" 2>/dev/null || printf '0')
  for p in "$procdir"/[0-9]*; do
    [ -d "$p" ] || continue
    pids+=("${p##*/}")
  done
  [ "${#pids[@]}" -gt 0 ] || die "no processes found under $procdir"
  n=${#pids[@]}
  MEASURED_LABEL=pss
  MEASURED_DESC='the per-process proportional resident share, summed from /proc'
  MEASURED_PAREN='proportional resident share from /proc'
  {
    printf 'Processes: %s total\n' "$n"
    printf 'PhysMem: %sK used (from /proc/meminfo)\n' "$used_kb"
    printf 'PID    MEM   COMMAND\n'
    printf '%s\n' "${pids[@]}" | sort -n | awk -v proc="$procdir" '
      {
        pid = $0
        kb = 0
        f = proc "/" pid "/smaps_rollup"
        while ((getline line < f) > 0) {
          if (line ~ /^Pss:/) { split(line, a, " "); kb = a[2] + 0; break }
        }
        close(f)
        if (kb == 0) {
          f = proc "/" pid "/status"
          while ((getline line < f) > 0) {
            if (line ~ /^VmRSS:/) { split(line, a, " "); kb = a[2] + 0; break }
          }
          close(f)
        }
        printf "%s  %dK  proc\n", pid, kb
      }
    '
  } > "$TMP/top.raw"
  [ -s "$TMP/top.raw" ] || die "the /proc reading produced no output"
}

collect_ps() {
  if [ -n "${FM_MEMREPORT_PS:-}" ]; then
    [ -r "$FM_MEMREPORT_PS" ] || die "FM_MEMREPORT_PS is not readable: $FM_MEMREPORT_PS"
    cat "$FM_MEMREPORT_PS" > "$TMP/ps.raw"
    return 0
  fi
  # No name filter and no head/sort: the full table, always. Trap 2 was a filter
  # deciding what counted.
  ps -Ao pid=,ppid=,rss=,user=,command= > "$TMP/ps.raw" 2>/dev/null || true
  [ -s "$TMP/ps.raw" ] || die "ps(1) produced no output"
}

# Working directories for every enumerated pid in ONE batched lsof call (~0.2s
# for 600 pids). A pid missing from the result is permission-denied, which is a
# fact about readability, not about ownership - it becomes via=none downstream.
collect_cwd() {
  : > "$TMP/cwd.tsv"
  if [ -n "${FM_MEMREPORT_LSOF:-}" ]; then
    [ -r "$FM_MEMREPORT_LSOF" ] || die "FM_MEMREPORT_LSOF is not readable: $FM_MEMREPORT_LSOF"
    cat "$FM_MEMREPORT_LSOF" > "$TMP/cwd.tsv"
    return 0
  fi
  command -v lsof >/dev/null 2>&1 || return 0
  local pidlist
  pidlist=$(cut -f1 "$TMP/top.tsv" | paste -sd, -)
  [ -n "$pidlist" ] || return 0
  lsof -a -d cwd -Fpn -p "$pidlist" 2>/dev/null \
    | awk '
        /^p/ { pid = substr($0, 2); next }
        /^n/ { if (pid != "") { printf "%s\t%s\n", pid, substr($0, 2); pid = "" } }
      ' > "$TMP/cwd.tsv" || true
}

# Listening TCP sockets for every enumerated pid, as pid<TAB>port. A process
# holding a LISTEN socket is serving something and is never an abandoned
# leftover (see the header). Read from lsof, so it is a fact about the kernel's
# socket table, not a guess about the process's path or name. A pid absent from
# the result simply holds no listening socket. Multiple ports per pid produce
# multiple rows; downstream collapses them into a sorted port list.
collect_listen() {
  : > "$TMP/listen.tsv"
  if [ -n "${FM_MEMREPORT_LISTEN:-}" ]; then
    [ -r "$FM_MEMREPORT_LISTEN" ] || die "FM_MEMREPORT_LISTEN is not readable: $FM_MEMREPORT_LISTEN"
    cat "$FM_MEMREPORT_LISTEN" > "$TMP/listen.tsv"
    return 0
  fi
  command -v lsof >/dev/null 2>&1 || return 0
  local pidlist
  pidlist=$(cut -f1 "$TMP/top.tsv" | paste -sd, -)
  [ -n "$pidlist" ] || return 0
  # -iTCP -sTCP:LISTEN restricts to listening TCP sockets; -P and -n keep ports
  # numeric and skip DNS. The name field looks like "*:4500" or "127.0.0.1:4500";
  # the port is whatever follows the last colon.
  lsof -a -iTCP -sTCP:LISTEN -P -n -Fpn -p "$pidlist" 2>/dev/null \
    | awk '
        /^p/ { pid = substr($0, 2); next }
        /^n/ {
          if (pid != "") {
            name = substr($0, 2)
            n = split(name, a, ":")
            port = a[n]
            if (port ~ /^[0-9]+$/) printf "%s\t%s\n", pid, port
          }
        }
      ' > "$TMP/listen.tsv" || true
}

# Parse top's per-process rows into pid<TAB>footprint_kb, and its header counters
# into top.vars. MEM carries a B/K/M/G/T suffix and may be fractional.
parse_top() {
  awk '
    function tokb(v,   u, n) {
      u = substr(v, length(v), 1)
      n = substr(v, 1, length(v) - 1) + 0
      if (u == "B") return n / 1024
      if (u == "K") return n
      if (u == "M") return n * 1024
      if (u == "G") return n * 1024 * 1024
      if (u == "T") return n * 1024 * 1024 * 1024
      return -1
    }
    NR == 1 && /^Processes:/ { procs = $2 }
    /^PhysMem:/ {
      # PhysMem: 14G used (2798M wired, 1823M compressor), 1731M unused.
      for (i = 1; i <= NF; i++) if ($i == "used") { used = tokb($(i - 1)); break }
    }
    /^PID/ { rows = 1; next }
    rows && NF >= 2 && $1 ~ /^[0-9]+$/ {
      kb = tokb($2)
      if (kb >= 0) { printf "%s\t%d\n", $1, kb > TSV; n++ }
    }
    END {
      printf "top_header_procs=%d\n", procs + 0 > VARS
      printf "top_rows=%d\n", n + 0 > VARS
      printf "physmem_used_kb=%d\n", used + 0 > VARS
    }
  ' TSV="$TMP/top.tsv" VARS="$TMP/top.vars" "$TMP/top.raw"
  [ -f "$TMP/top.tsv" ] || : > "$TMP/top.tsv"
  [ -f "$TMP/top.vars" ] || : > "$TMP/top.vars"
}

# ps rows into pid<TAB>ppid<TAB>rss_kb<TAB>user<TAB>command. The command is the
# rest of the line and may contain anything, including tabs, so it is
# whitespace-normalised into the final field.
parse_ps() {
  awk '
    $1 ~ /^[0-9]+$/ && NF >= 5 {
      pid = $1; ppid = $2; rss = $3; user = $4
      cmd = ""
      for (i = 5; i <= NF; i++) cmd = cmd (i > 5 ? " " : "") $i
      gsub(/\t/, " ", cmd)
      printf "%s\t%s\t%s\t%s\t%s\n", pid, ppid, rss, user, cmd
    }
  ' "$TMP/ps.raw" > "$TMP/ps.tsv"
}

# --- self-check -------------------------------------------------------------
#
# Every gate here exists because a real wrong answer got past its absence.

run_self_check() {
  local top_rows top_header physmem_used ps_count
  # shellcheck source=/dev/null
  . "$TMP/top.vars"
  top_rows=${top_rows:-0}
  top_header=${top_header_procs:-0}
  physmem_used=${physmem_used_kb:-0}
  ps_count=$(wc -l < "$TMP/ps.tsv" | tr -d ' ')

  [ "$top_rows" -gt 0 ] \
    || refuse "top(1) yielded no parseable process rows" \
              "the memory source produced a header but no measurements"

  [ "$ps_count" -gt 0 ] \
    || refuse "ps(1) yielded no parseable process rows" \
              "the identity source produced nothing to attribute"

  # Trap 1, exactly as observed: a table so small it cannot describe this machine.
  [ "$top_rows" -ge "$MIN_PROCS" ] \
    || refuse "the memory listing is implausibly short: $top_rows processes" \
              "a live machine always runs far more than $MIN_PROCS processes" \
              "this is the signature of a truncated or filtered process table"
  [ "$ps_count" -ge "$MIN_PROCS" ] \
    || refuse "the process listing is implausibly short: $ps_count processes" \
              "a live machine always runs far more than $MIN_PROCS processes" \
              "this is the signature of a truncated or filtered process table"

  # The tool's own pid must be in its own listing. Nothing can enumerate every
  # process while missing the one doing the asking.
  awk -F'\t' -v p="$SELF_PID" '$1 == p { found = 1 } END { exit !found }' "$TMP/top.tsv" \
    || refuse "this script's own pid ($SELF_PID) is absent from the memory listing" \
              "a listing that cannot see the process reading it is not complete"
  awk -F'\t' -v p="$SELF_PID" '$1 == p { found = 1 } END { exit !found }' "$TMP/ps.tsv" \
    || refuse "this script's own pid ($SELF_PID) is absent from the process listing" \
              "a listing that cannot see the process reading it is not complete"

  # The two independent enumerations must broadly agree. They are sampled a
  # fraction of a second apart and count slightly differently, hence 30%.
  if [ "$top_header" -gt 0 ]; then
    local diff allowed
    diff=$(( top_rows > top_header ? top_rows - top_header : top_header - top_rows ))
    allowed=$(( top_header * COUNT_TOLERANCE_PCT / 100 ))
    [ "$allowed" -ge 20 ] || allowed=20
    [ "$diff" -le "$allowed" ] \
      || refuse "the memory listing is truncated: $top_rows rows for $top_header processes" \
                "top reported $top_header processes but only $top_rows measurements survived"
  fi

  local diff2 allowed2
  diff2=$(( ps_count > top_rows ? ps_count - top_rows : top_rows - ps_count ))
  allowed2=$(( top_rows * COUNT_TOLERANCE_PCT / 100 ))
  [ "$allowed2" -ge 20 ] || allowed2=20
  [ "$diff2" -le "$allowed2" ] \
    || refuse "the two process listings disagree: ps says $ps_count, top says $top_rows" \
              "one of the two enumerations is filtered or truncated" \
              "attribution built on disagreeing listings would be arbitrary"

  [ "$physmem_used" -gt 0 ] \
    || refuse "the memory source's PhysMem line did not parse" \
              "without the machine's real used memory there is nothing to sanity-check against"

  # Trap 1's decisive gate: 31 daemons topping out at 24 MB would sum to well
  # under 1% of used memory. Real mac readings run ABOVE used memory (footprint
  # counts compressed pages and shared regions per process; this machine
  # measured 17.6 GB summed against 14 GB used), so the floor is one-sided.
  # Linux never shows that shape - kernel memory and page cache are not process
  # memory, so summed pss sits well below used - and the floor is anchored to
  # the process listing itself: summed pss against the ps listing's summed rss
  # (docs/memory-report.md owns the evidence).
  local sum_kb floor_kb ceil_kb floor_ref floor_units
  sum_kb=$(awk -F'\t' '{ s += $2 } END { printf "%d", s }' "$TMP/top.tsv")
  if [ "$PLATFORM" = linux ]; then
    floor_ref=$(awk -F'\t' '{ s += $3 } END { printf "%d", s + 0 }' "$TMP/ps.tsv")
    [ "$floor_ref" -gt 0 ] \
      || refuse "the process listing carries no memory at all" \
                "ps(1) yielded $ps_count rows but zero summed rss, so nothing can be sanity-checked"
    floor_kb=$(( floor_ref * FOOTPRINT_FLOOR_PCT_LINUX / 100 ))
    floor_units='summed resident size'
  else
    floor_ref=$physmem_used
    floor_kb=$(( physmem_used * FOOTPRINT_FLOOR_PCT / 100 ))
    floor_units='used memory'
  fi
  [ "$sum_kb" -ge "$floor_kb" ] \
    || refuse "the measured total is impossibly small for this machine" \
              "summed footprint $(fmt_kb "$sum_kb") against $(fmt_kb "$floor_ref") of $floor_units" \
              "the listing is missing most of the machine's memory; it is filtered or truncated"

  # The other side of the same plausibility question. Exceeding used memory is
  # normal (measured 111-126%), but a total several times the machine's memory
  # means rows are being counted more than once, which would inflate every group
  # total and every reclaim figure. Generous, so normal sharing never trips it.
  ceil_kb=$(( physmem_used * FOOTPRINT_CEILING_PCT / 100 ))
  [ "$sum_kb" -le "$ceil_kb" ] \
    || refuse "the measured total is impossibly large for this machine" \
              "summed footprint $(fmt_kb "$sum_kb") against $(fmt_kb "$physmem_used") of used memory" \
              "processes are being counted more than once; every total would be inflated"

  SELF_PS_COUNT=$ps_count
  SELF_PHYSMEM_USED=$physmem_used
  SELF_FOOTPRINT_SUM=$sum_kb
}

# --- ownership records ------------------------------------------------------
#
# Every owner path here is READ from a durable record. Nothing is inferred from a
# path's shape, so "unowned" can mean "the records were read and none claimed
# it" rather than "I did not recognise this".

build_owners() {
  : > "$TMP/owners.tsv"
  local f id kind wt home tasktmp name

  # Secondmate registry first, so a secondmate home is labelled with its
  # registered name rather than its task id when both records name the path.
  if [ -r "$DATA/secondmates.md" ]; then
    while IFS=$'\t' read -r name home; do
      [ -n "$name" ] && [ -n "$home" ] || continue
      printf '%s\tsecondmate\t%s\n' "$home" "$name" >> "$TMP/owners.tsv"
    done < <(awk '
      /^- / {
        line = $0
        sub(/^- /, "", line)
        nm = line
        sub(/ - .*$/, "", nm)
        if (match(line, /home: [^;)]+/)) {
          h = substr(line, RSTART + 6, RLENGTH - 6)
          gsub(/^[ \t]+|[ \t]+$/, "", h)
          gsub(/^[ \t]+|[ \t]+$/, "", nm)
          if (nm != "" && h != "") printf "%s\t%s\n", nm, h
        }
      }
    ' "$DATA/secondmates.md")
  fi

  if [ -d "$STATE" ]; then
    for f in "$STATE"/*.meta; do
      [ -e "$f" ] || continue
      id=$(basename "$f" .meta)
      kind=$(awk -F= '/^kind=/ { print $2; exit }' "$f")
      wt=$(awk -F= '/^worktree=/ { print $2; exit }' "$f")
      home=$(awk -F= '/^home=/ { print $2; exit }' "$f")
      tasktmp=$(awk -F= '/^tasktmp=/ { print $2; exit }' "$f")
      local okind=task
      [ "$kind" = secondmate ] && okind=secondmate
      # NOTE: project= is deliberately NOT registered as an owner path. It is the
      # shared clone many tasks read from, so attributing it to whichever task
      # mentioned it last would be a guess - exactly trap 4.
      [ -n "$wt" ] && printf '%s\t%s\t%s\n' "$wt" "$okind" "$id" >> "$TMP/owners.tsv"
      [ -n "$home" ] && printf '%s\t%s\t%s\n' "$home" "$okind" "$id" >> "$TMP/owners.tsv"
      [ -n "$tasktmp" ] && printf '%s\t%s\t%s\n' "$tasktmp" "$okind" "$id" >> "$TMP/owners.tsv"
    done
  fi

  # The firstmate home itself, and each project clone under it. Longest-prefix
  # matching downstream keeps a clone from being swallowed by the home.
  printf '%s\tfirstmate\t%s\n' "$FM_HOME" "$(basename "$FM_HOME")" >> "$TMP/owners.tsv"
  if [ -d "$FM_HOME/projects" ]; then
    for f in "$FM_HOME"/projects/*; do
      [ -d "$f" ] || continue
      printf '%s\tproject\t%s\n' "$f" "$(basename "$f")" >> "$TMP/owners.tsv"
    done
  fi
}

# A working directory that is a git checkout but that NO record claims is the
# incident's "leftover indexing a throwaway worker copy". Testing for .git is a
# filesystem fact, not a guess about the path's shape.
build_git_cwds() {
  : > "$TMP/gitcwd.tsv"
  [ -s "$TMP/cwd.tsv" ] || return 0
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    [ -e "$c/.git" ] && printf '%s\n' "$c" >> "$TMP/gitcwd.tsv"
  done < <(cut -f2 "$TMP/cwd.tsv" | sort -u)
}

# --- attribution self-checks ------------------------------------------------
#
# The measurement self-check above proves the READING is sound. These two prove
# the ATTRIBUTION is sound, which is a separate failure mode and the one that
# actually shipped: a perfectly good reading was published with ownership
# resolved against an empty record set.

# "unowned" is a claim that the records were read and none of them matched. The
# question is therefore whether the record store was READABLE, not whether it
# happened to be empty.
#
# An unreadable store means the script cannot make that claim about anything, so
# it refuses. An empty but readable store means the fleet is genuinely idle,
# which is a normal state and NOT a broken instrument - refusing there would make
# the report useless exactly when the machine is quiet. The wrong-home case that
# motivated this check is caught by the missing-directory arm (a worktree has no
# state/ at all) and by check_agent_attribution below.
check_records_were_read() {
  if [ ! -d "$STATE" ]; then
    refuse "the fleet record store could not be read, so nothing can be called unowned" \
      "no such directory: $STATE" \
      "Reporting ownership without reading the records would mark every live lane" \
      "as claimed by nothing, and invite killing work that is running." \
      "Point the report at the operating home, for example:" \
      "  FM_HOME=/path/to/firstmate $(basename "${BASH_SOURCE[0]}")"
  fi
  [ -r "$STATE" ] || refuse "the fleet record store is not readable" "cannot read: $STATE"
}

# Records exist, but almost every agent still came back unowned. Fleet agents run
# inside recorded worktrees, so that shape means the records being read are not
# the ones describing these processes - most often the report is pointed at a
# secondmate's home while the main fleet runs elsewhere. The reading is correct
# FOR THAT HOME, so this warns loudly rather than refusing.
check_agent_attribution() {
  local agents unowned pct
  agents=$(awk -F'\t' '$9 == "agent" { n++ } END { print n + 0 }' "$TMP/rows.tsv")
  [ "$agents" -ge 3 ] || return 0
  # foreign-agent counts here too: it is precisely "an agent no record claimed",
  # which is the signal this guard exists to measure. Leaving it out would have
  # silently disarmed the guard the moment that bucket was introduced.
  unowned=$(awk -F'\t' '$9 == "agent" && ($6 == "unowned" || $6 == "unclassified" || $6 == "foreign-agent") { n++ } END { print n + 0 }' "$TMP/rows.tsv")
  pct=$(( unowned * 100 / agents ))
  [ "$pct" -gt "$UNOWNED_AGENT_WARN_PCT" ] || return 0
  ATTRIBUTION_WARNING="$unowned of $agents agent processes ($pct%) matched no record"
}

# Printed on STDOUT, deliberately. The warning qualifies the table's meaning, so
# it must travel with the table: on stderr it would be stripped by any caller
# that pipes the report, leaving exactly the confident wrong output this warning
# exists to prevent.
render_attribution_warning() {
  [ -n "${ATTRIBUTION_WARNING:-}" ] || return 0
  printf '\n!! ATTRIBUTION LOOKS WRONG - do not act on the reclaim list below.\n'
  printf '   %s.\n' "$ATTRIBUTION_WARNING"
  printf '   Fleet agents run inside recorded worktrees, so this usually means the\n'
  printf '   report is reading a different home than the one running this work.\n'
  printf '   Records were read from: %s\n' "$STATE"
  printf '   Re-run against the operating home before trusting any ownership here.\n'
}

# --- classification ---------------------------------------------------------

classify_rows() {
  awk -F'\t' '
    function basename(p,   n, a) { n = split(p, a, "/"); return a[n] }

    # kind is a LABEL applied to a process that is already counted. It never
    # decides whether a process appears - trap 2.
    function kind_of(cmd, user,   b, exe, i, a) {
      split(cmd, a, " ")
      exe = a[1]
      b = basename(exe)
      if (b ~ /^(claude|codex|opencode|grok|jcode)$/ || b == "pi") return "agent"
      if (cmd ~ /typescript-language-server|tsserver|\/tsgo|vtsls|rust-analyzer|gopls|pyright|pylsp|clangd|jdtls|lua-language-server|eslint_d|language-server/) return "lsp"
      if (exe ~ /^\/System\// || exe ~ /^\/usr\/libexec\// || exe ~ /^\/usr\/sbin\// || exe ~ /^\/sbin\// || exe ~ /^\/Library\/Apple\//) return "system"
      if (cmd ~ /Visual Studio Code|Code Helper|Cursor|Electron|Zed|Xcode|Sublime Text|JetBrains|Warp|iTerm/) return "editor"
      # A bundled app the captain is running is NOT an unowned leftover. Read
      # from the executable path, so Chrome and friends land in their own bucket
      # instead of inflating the leftover class the reclaim list acts on.
      if (exe ~ /^\/Applications\// || exe ~ /\/Applications\/[^\/]*\.app\// || exe ~ /\.app\/Contents\//) return "app"
      if (b ~ /^(node|npm|npx|bun|deno|python|python3|python3\.[0-9]+|ruby|java|cargo|go|rustc|tsc|vite|esbuild|webpack|jest|vitest|playwright|eslint|prettier)$/) return "tooling"
      if (cmd ~ /playwright|vitest|jest|next-server|webpack|esbuild/) return "tooling"
      if (b ~ /^(zsh|bash|sh|fish|tmux|screen|-zsh|login)$/ || b ~ /^-/) return "shell"
      if (user == "root" && exe ~ /^\/usr\//) return "system"
      return "other"
    }

    # Owner paths, longest prefix wins so a project clone beats the home above it.
    FILENAME == OWN {
      opath[++no] = $1; okind[no] = $2; olabel[no] = $3
      next
    }
    FILENAME == CWDF { cwd[$1] = $2; next }
    FILENAME == GITF { gitcwd[$0] = 1; next }
    FILENAME == TOPF { fp[$1] = $2; next }
    # Listening ports, one pid<TAB>port row each. Collapsed into a sorted,
    # comma-separated list per pid so a server on several ports reads cleanly.
    # Merely HOLDING a listen socket is what matters here - it is positive
    # evidence the process is serving something, so it is never a leftover.
    FILENAME == LISTENF {
      if ($2 !~ /^[0-9]+$/) next
      if (($1 SUBSEP $2) in seenport) next
      seenport[$1 SUBSEP $2] = 1
      # Guard the concatenation with a separate flag: writing listen[$1] on the
      # left of the assignment creates the element before the right side runs, so
      # "$1 in listen" would already be true and prepend a stray leading comma.
      if ($1 in haveport) listen[$1] = listen[$1] "," $2
      else { listen[$1] = $2; haveport[$1] = 1 }
      next
    }

    # ps rows arrive last: everything needed to classify is already loaded.
    FILENAME == PSF {
      pid = $1; ppid[$1] = $2; rss[$1] = $3; user[$1] = $4; cmd[$1] = $5
      pids[++np] = pid
      next
    }

    # True when a live agent is running in this directory or an ancestor of it.
    function shares_agent_dir(c,   i, a) {
      if (c == "") return 0
      for (i = 1; i <= na; i++) {
        a = agentcwd[i]
        if (c == a || index(c, a "/") == 1 || index(a, c "/") == 1) return 1
      }
      return 0
    }

    function match_owner(c,   i, best, bestlen, p) {
      best = 0; bestlen = -1
      if (c == "") return 0
      for (i = 1; i <= no; i++) {
        p = opath[i]
        if (p == "") continue
        if (c == p || index(c, p "/") == 1) {
          if (length(p) > bestlen) { bestlen = length(p); best = i }
        }
      }
      return best
    }

    # Numerically-sorted, deduplicated port list for one pid, e.g. "80,443,4500".
    # Deterministic so the same server reads the same way every run.
    function ports_of(p,   s, n, a, i, j, t) {
      if (!(p in listen)) return ""
      n = split(listen[p], a, ",")
      for (i = 1; i <= n; i++) {
        for (j = i + 1; j <= n; j++) {
          if (a[j] + 0 < a[i] + 0) { t = a[i]; a[i] = a[j]; a[j] = t }
        }
      }
      s = a[1]
      for (i = 2; i <= n; i++) s = s "," a[i]
      return s
    }

    END {
      # Pass 1: direct attribution from the working directory.
      for (i = 1; i <= np; i++) {
        p = pids[i]
        k[p] = kind_of(cmd[p], user[p])
        c = (p in cwd) ? cwd[p] : ""
        mi = match_owner(c)
        if (mi > 0) {
          okindof[p] = okind[mi]; olabelof[p] = olabel[mi]; via[p] = "cwd"
        } else {
          okindof[p] = ""; via[p] = (c == "") ? "none" : "unmatched"
        }
      }

      # Pass 2: ONLY where the working directory was unreadable may a parent
      # lend its cwd-derived owner - and never through ppid 1, the reparented
      # case that produced the original misjudgement.
      for (i = 1; i <= np; i++) {
        p = pids[i]
        if (okindof[p] != "" || via[p] != "none") continue
        pp = ppid[p]
        if (pp == "" || pp == "1" || pp == "0") continue
        if (pp in cwd && okindof[pp] != "" && via[pp] == "cwd") {
          okindof[p] = okindof[pp]; olabelof[p] = olabelof[pp]; via[p] = "ancestry"
        }
      }

      # A live agent adopts the tooling running in its directory. Without this,
      # an MCP server or language server started BY a live agent - in a checkout
      # no firstmate record claims, because the agent belongs to another tool or
      # another home - reads as an abandoned leftover and gets billed as free
      # memory. Killing it would break the agent that is using it.
      na = 0
      for (i = 1; i <= np; i++) {
        p = pids[i]
        if (k[p] == "agent" && (p in cwd) && cwd[p] != "" && cwd[p] != "/") {
          agentcwd[++na] = cwd[p]
        }
      }

      # Pass 3: buckets for everything the records did not claim, plus flags.
      for (i = 1; i <= np; i++) {
        p = pids[i]
        c = (p in cwd) ? cwd[p] : ""
        fl = ""
        # A listening socket travels as a flag on EVERY row, owned or not, so
        # the listening ports are always visible next to a server. It is also the
        # decisive signal below: a process serving a port is never a leftover.
        # NOTE: no apostrophes in this awk block - it is single-quoted.
        srvports = ports_of(p)
        if (srvports != "") fl = "listening:" srvports
        # ppid 1 is only evidence of a LOST parent for things that are always
        # spawned by something else. launchd legitimately starts apps and system
        # daemons with ppid 1, so flagging those would manufacture 98 fake
        # findings - ancestry lying again, in the other direction.
        if (ppid[p] == "1" && (k[p] == "lsp" || k[p] == "tooling" || k[p] == "agent")) fl = fl (fl == "" ? "" : ",") "no-live-parent"
        unclaimed = (okindof[p] == "" && c != "" && (c in gitcwd))
        if (unclaimed) fl = fl (fl == "" ? "" : ",") "unclaimed-checkout"

        if (okindof[p] == "") {
          if (k[p] == "agent") {
            # A RUNNING AGENT that no record of THIS home claims: belonging to
            # another tool, another home, or the captain directly. It is live
            # work, not a leftover, so it gets its own bucket and is excluded
            # from the reclaim list entirely. Billing a live agent as reclaimable
            # is the same incident one layer further out.
            # NOTE: no apostrophes in this awk block - it is single-quoted.
            okindof[p] = "foreign-agent"; olabelof[p] = "live agent, not this fleet"
          } else if (srvports != "") {
            # A LISTENING SERVER no record claims. On this fleet a shared dev
            # stack is started by one lane to serve the WHOLE fleet, so it has no
            # owning task by design and "unowned" is its NATURAL state, not
            # evidence it is disposable. Holding a listen socket is positive
            # evidence it is serving something, so it gets its own `server`
            # bucket WITH its ports and is excluded from the reclaim list
            # entirely. Billing such a server as reclaimable once killed a shared
            # stack and cost a lane its test gate (docs/memory-report.md).
            # Checked BEFORE the unclaimed-checkout and tooling leftover branches
            # so a node/python server sitting in an unclaimed checkout can never
            # fall through to the reclaim list.
            okindof[p] = "server"; olabelof[p] = "listening server, ports " srvports; via[p] = "listen"
          } else if (unclaimed && shares_agent_dir(c)) {
            # Tooling sitting in the same directory as a live agent: its work,
            # not an abandoned leftover.
            okindof[p] = "foreign-agent"; olabelof[p] = "live agent, not this fleet"
          } else if (unclaimed) {
            # A leftover in a checkout nothing claims: the incident case.
            okindof[p] = "unowned"; olabelof[p] = "checkout no record claims"
          } else if (k[p] == "app") {
            okindof[p] = "app"; olabelof[p] = "user applications"; via[p] = "path"
          } else if (k[p] == "editor" || k[p] == "lsp" || k[p] == "tooling") {
            okindof[p] = "tooling"; olabelof[p] = "editor / language tooling"
          } else if (k[p] == "system") {
            okindof[p] = "system"; olabelof[p] = OSLABEL; via[p] = "path"
          } else if (c != "") {
            okindof[p] = "unowned"; olabelof[p] = "no record claims it"
          } else {
            # Facts unreadable. NEVER a finding - a separate bucket entirely.
            okindof[p] = "unclassified"; olabelof[p] = "facts unreadable"
          }
        }
        if (fl == "") fl = "-"
        f = (p in fp) ? fp[p] : 0
        printf "%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
          p, ppid[p], f, rss[p], user[p], okindof[p], olabelof[p], via[p], k[p], fl, (c == "" ? "-" : c), cmd[p]
      }
    }
  ' OWN="$TMP/owners.tsv" CWDF="$TMP/cwd.tsv" GITF="$TMP/gitcwd.tsv" TOPF="$TMP/top.tsv" PSF="$TMP/ps.tsv" LISTENF="$TMP/listen.tsv" OSLABEL="$OS_LABEL" \
    "$TMP/owners.tsv" "$TMP/cwd.tsv" "$TMP/gitcwd.tsv" "$TMP/top.tsv" "$TMP/listen.tsv" "$TMP/ps.tsv" \
    | sort -t$'\t' -k3,3nr > "$TMP/rows.tsv"
}

# --- formatting -------------------------------------------------------------

fmt_kb() {
  awk -v kb="$1" 'BEGIN {
    if (kb >= 1024 * 1024) printf "%.2f GB", kb / 1024 / 1024
    else if (kb >= 1024) printf "%.0f MB", kb / 1024
    else printf "%.0f KB", kb
  }'
}

host_line() {
  local total_b total_kb swap
  if [ "$PLATFORM" = linux ]; then
    # /proc/meminfo is the Linux sysctl's place: MemTotal, and used is MemTotal
    # minus MemAvailable (the same quantity the self-check computes).
    total_kb=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)
    swap=$(awk '
      function fmt(kb) {
        if (kb >= 1024 * 1024) return sprintf("%.2f GB", kb / 1024 / 1024)
        if (kb >= 1024) return sprintf("%.0f MB", kb / 1024)
        return sprintf("%.0f KB", kb)
      }
      /^SwapTotal:/ { t = $2; next }
      /^SwapFree:/ { f = $2 }
      END {
        if (t > 0) printf "swap %s used of %s", fmt(t - f), fmt(t)
        else printf "swap none"
      }
    ' /proc/meminfo)
  else
    total_b=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    total_kb=$(( total_b / 1024 ))
    swap=$(sysctl -n vm.swapusage 2>/dev/null | awk '
      { for (i = 1; i <= NF; i++) {
          if ($i == "total") t = $(i + 2)
          if ($i == "used") u = $(i + 2)
        }
        if (t != "") printf "swap %s used of %s", u, t
      }')
  fi
  printf 'Host: %s total | %s used | %s\n' \
    "$(fmt_kb "$total_kb")" "$(fmt_kb "$SELF_PHYSMEM_USED")" "${swap:-swap unknown}"
}

# --- rendering --------------------------------------------------------------

render_groups() {
  printf '\nBY OWNER - total with children, rolled up by ownership, not ancestry\n'
  awk -F'\t' '
    { key = $6 "\t" $7; tot[key] += $3; n[key]++
      if ($9 == "agent") { agent[key] += $3; agents[key]++ }
      if ($9 == "lsp") { lsp[key] += $3; lsps[key]++ }
      grand += $3
    }
    END {
      for (key in tot) printf "%d\t%s\t%d\t%d\t%d\t%d\t%d\n", tot[key], key, n[key], agent[key], agents[key], lsp[key], lsps[key]
      printf "%d\tGRAND\t\t0\t0\t0\t0\t0\n", grand
    }
  ' "$TMP/rows.tsv" | sort -t$'\t' -k1,1nr | while IFS=$'\t' read -r tot okind olabel n agent nagent lsp nlsp; do
    if [ "$okind" = GRAND ]; then continue; fi
    local extra=""
    if [ "${nagent:-0}" -gt 0 ]; then
      extra=" (agent itself $(fmt_kb "$agent")"
      if [ "${nlsp:-0}" -gt 0 ]; then
        extra="$extra + $nlsp language server$([ "$nlsp" -gt 1 ] && echo s) $(fmt_kb "$lsp")"
      fi
      extra="$extra)"
    elif [ "${nlsp:-0}" -gt 0 ]; then
      extra=" ($nlsp language server$([ "$nlsp" -gt 1 ] && echo s) $(fmt_kb "$lsp"))"
    fi
    printf '  %-12s %-34s %10s  %3d proc%s\n' "$okind" "$(printf '%.34s' "$olabel")" "$(fmt_kb "$tot")" "$n" "$extra"
  done
}

# The classes below are DISJOINT and every process falls in at most one, so the
# numbers can be added up without overstating the win. Overlapping buckets would
# be their own kind of confident wrong answer.
render_reclaim() {
  printf '\nRECLAIMABLE - no live work depends on it (classes do not overlap)\n'
  # DELIBERATELY NARROW. Only two classes qualify, and a running agent is in
  # neither: a process is listed here only when there is positive evidence
  # nothing needs it. Everything else the records did not claim is reported
  # below as context, NOT as something to free - a captain's editor, terminal,
  # or monitor is not a leftover, and neither is another tool's live agent.
  awk -F'\t' '
    $9 == "agent" { next }
    # A LISTENING SERVER is never a leftover, whatever else it looks like. It is
    # serving something, so even a node/python server sitting in an unclaimed
    # checkout must never be billed as free. Its own `server` owner_kind already
    # keeps it out of the branches below, but this guard makes the exclusion
    # independent of that classification order - a listening flag alone is enough.
    $10 ~ /listening:/ { next }
    # Only language/build tooling qualifies as a leftover. A shell is a terminal
    # someone is sitting in, and a service is a service: neither is abandoned
    # just because no fleet record names its directory. The checkout test alone
    # is too weak to carry this - /opt/homebrew is itself a git checkout.
    $6 == "unowned" && $10 ~ /unclaimed-checkout/ && ($9 == "lsp" || $9 == "tooling") { u += $3; un++; next }
    # An EDITOR is not in this list. It is a running application someone is
    # working in - and on this fleet the terminal emulator hosts the tmux session
    # every agent lives in, so "nothing depends on it" would be flatly false.
    # Its cost is still surfaced separately below, because closing it IS the
    # single largest available win; that is just a decision for a human, not a
    # figure to bill as free.
    $6 == "tooling" && $9 == "editor" { e += $3; en++; next }
    $6 == "tooling" { t += $3; tn++; next }
    END {
      if (un + tn == 0) printf "  nothing qualifies; no leftovers found\n"
      if (un) printf "  %-42s %8s  %d processes\n", "leftovers in a checkout no record claims", sz(u), un
      if (tn) printf "  %-42s %8s  %d processes\n", "language / build tooling, no fleet work", sz(t), tn
      if (un + tn) printf "  %-42s %8s\n", "total, if all of the above were freed", sz(u + t)
      if (en) printf "  YOUR CALL: closing the editor/terminal would free %s (%d proc),\n             but the fleet may be running inside it\n", sz(e), en
    }
    function sz(kb) {
      if (kb >= 1024 * 1024) return sprintf("%.2f GB", kb / 1024 / 1024)
      return sprintf("%.0f MB", kb / 1024)
    }
  ' "$TMP/rows.tsv"
  # Context, not candidates. Named explicitly so the reader can see what was
  # excluded and why, rather than wondering where the rest of the machine went.
  awk -F'\t' '
    $9 == "agent" && ($6 == "foreign-agent" || $6 == "unowned") { a += $3; an++; next }
    # A listening server is surfaced as context WITH its ports, never billed as
    # free. An unclaimed shared stack is exactly what a fleet server looks like
    # once its starting lane tore down, so "no record claims it" is expected here.
    $6 == "server" || ($10 ~ /listening:/ && $9 != "agent") { s += $3; sn++; next }
    $6 == "unowned" || $6 == "app" { o += $3; on++; next }
    END {
      if (an) printf "  NOT listed: %d live agent process(es), %s - another tool or home owns them\n", an, sz(a)
      if (sn) printf "  NOT listed: %d listening server(s), %s - serving the fleet, not leftovers\n", sn, sz(s)
      if (on) printf "  NOT listed: %d application/other process(es), %s - in use, not leftovers\n", on, sz(o)
    }
    function sz(kb) {
      if (kb >= 1024 * 1024) return sprintf("%.2f GB", kb / 1024 / 1024)
      return sprintf("%.0f MB", kb / 1024)
    }
  ' "$TMP/rows.tsv"
  local lsp_n lsp_kb par_n
  lsp_n=$(awk -F'\t' '$9 == "lsp" { n++ } END { print n + 0 }' "$TMP/rows.tsv")
  if [ "$lsp_n" -gt 0 ]; then
    lsp_kb=$(awk -F'\t' '$9 == "lsp" { s += $3 } END { print s + 0 }' "$TMP/rows.tsv")
    printf '  Of these, %d language server%s totalling %s - each typically dwarfs the\n' \
      "$lsp_n" "$([ "$lsp_n" -gt 1 ] && echo s)" "$(fmt_kb "$lsp_kb")"
    printf '  agent that spawned it, so check the owner group above before acting.\n'
  fi
  par_n=$(awk -F'\t' '$10 ~ /no-live-parent/ { n++ } END { print n + 0 }' "$TMP/rows.tsv")
  if [ "$par_n" -gt 0 ]; then
    printf '  %d process%s flagged no-live-parent: its spawner is gone, so nothing will\n' \
      "$par_n" "$([ "$par_n" -gt 1 ] && echo es)"
    printf '  reap it. That is a hint only - a live task may still own it by working\n'
    printf '  directory, so read the OWNER column, never the parent, before acting.\n'
  fi
  printf '  Read-only: this script never kills anything. These are candidates.\n'
}

render_table() {
  local count=$limit
  [ "$show_all" -eq 1 ] && count=$(wc -l < "$TMP/rows.tsv" | tr -d ' ')
  printf '\nTOP PROCESSES by %s (%s)\n' "$MEASURED_LABEL" "$MEASURED_PAREN"
  printf '  %-7s %10s %10s  %-7s %-9s %-30s %s\n' PID FOOTPRINT RSS KIND VIA OWNER COMMAND
  head -n "$count" "$TMP/rows.tsv" | while IFS=$'\t' read -r pid _ppid fpkb rsskb _user okind olabel via kind flags _cwd cmd; do
    local owner
    case "$okind" in
      task|secondmate|project) owner="$okind:$olabel" ;;
      *) owner="$olabel" ;;
    esac
    [ "$flags" != "-" ] && owner="$owner [$flags]"
    printf '  %-7s %10s %10s  %-7s %-9s %-30s %.56s\n' \
      "$pid" "$(fmt_kb "$fpkb")" "$(fmt_kb "$rsskb")" "$kind" "$via" "$(printf '%.30s' "$owner")" "$cmd"
  done
  if [ "$show_all" -eq 0 ]; then
    local total
    total=$(wc -l < "$TMP/rows.tsv" | tr -d ' ')
    [ "$total" -gt "$count" ] && printf '  ... %d more (--all to show every process)\n' "$(( total - count ))"
  fi
}

render_tree() {
  printf '\nBY OWNER, EVERY PROCESS - grouped by ownership (pstree is not used: see header)\n'
  awk -F'\t' '{ tot[$6 "\t" $7] += $3 } END { for (k in tot) printf "%d\t%s\n", tot[k], k }' "$TMP/rows.tsv" \
    | sort -t$'\t' -k1,1nr | while IFS=$'\t' read -r tot okind olabel; do
    printf '\n  %s: %s - %s total\n' "$okind" "$olabel" "$(fmt_kb "$tot")"
    awk -F'\t' -v k="$okind" -v l="$olabel" '$6 == k && $7 == l' "$TMP/rows.tsv" \
      | while IFS=$'\t' read -r pid _ppid fpkb _rsskb _user _ok _ol via kind flags _cwd cmd; do
        printf '      %-7s %10s  %-7s %-7s %-18s %.52s\n' \
          "$pid" "$(fmt_kb "$fpkb")" "$kind" "$via" "$flags" "$cmd"
      done
  done
}

render_json() {
  printf '{\n'
  printf '  "kind": "memory-report",\n'
  printf '  "physmem_used_kb": %s,\n' "$SELF_PHYSMEM_USED"
  printf '  "footprint_sum_kb": %s,\n' "$SELF_FOOTPRINT_SUM"
  printf '  "process_count": %s,\n' "$SELF_PS_COUNT"
  printf '  "measured": "%s",\n' "$MEASURED_LABEL"
  printf '  "records_home": "%s",\n' "$STATE"
  printf '  "fleet_records": %s,\n' \
    "$FLEET_RECORD_COUNT"
  # A consumer must be able to see the same doubt a human sees, so the warning is
  # a field rather than a stderr line an automated caller would never read.
  printf '  "attribution_warning": %s,\n' \
    "$([ -n "${ATTRIBUTION_WARNING:-}" ] && printf '"%s"' "$ATTRIBUTION_WARNING" || printf 'null')"
  printf '  "processes": [\n'
  awk -F'\t' '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, " ", s); return s }
    {
      printf "%s    {\"pid\":%s,\"ppid\":%s,\"footprint_kb\":%s,\"rss_kb\":%s,\"user\":\"%s\",\"owner_kind\":\"%s\",\"owner\":\"%s\",\"via\":\"%s\",\"kind\":\"%s\",\"flags\":\"%s\",\"cwd\":\"%s\",\"command\":\"%s\"}", \
        (NR > 1 ? ",\n" : ""), $1, $2, $3, $4, esc($5), esc($6), esc($7), esc($8), esc($9), esc($10), esc($11), esc($12)
    }
    END { printf "\n" }
  ' "$TMP/rows.tsv"
  printf '  ],\n'
  printf '  "groups": [\n'
  awk -F'\t' '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    { key = $6 "\t" $7; tot[key] += $3; n[key]++ }
    END {
      first = 1
      for (k in tot) {
        split(k, a, "\t")
        printf "%s    {\"owner_kind\":\"%s\",\"owner\":\"%s\",\"footprint_kb\":%d,\"processes\":%d}", \
          (first ? "" : ",\n"), esc(a[1]), esc(a[2]), tot[k], n[k]
        first = 0
      }
      printf "\n"
    }
  ' "$TMP/rows.tsv"
  printf '  ]\n'
  printf '}\n'
}

# --verify: re-measure the largest processes with footprint(1) and report
# agreement. This is trap 3's standing regression check - the comparison that
# would have caught reporting rss as though it were the Activity Monitor number.
render_verify() {
  printf '\nVERIFY - top(1) MEM against footprint(1), the Activity Monitor quantity\n'
  if ! command -v footprint >/dev/null 2>&1; then
    printf '  footprint(1) unavailable; cannot cross-check\n'
    return 0
  fi
  printf '  %-7s %12s %12s %10s  %s\n' PID 'top(MEM)' 'footprint' DELTA COMMAND
  head -n 12 "$TMP/rows.tsv" | while IFS=$'\t' read -r pid _ppid fpkb _rss _user _ok _ol _via _kind _fl _cwd cmd; do
    local fkb delta
    fkb=$(footprint -p "$pid" 2>/dev/null | awk '
      /Footprint:/ {
        for (i = 1; i <= NF; i++) if ($i == "Footprint:") {
          n = $(i + 1) + 0; u = $(i + 2)
          if (u ~ /^KB/) print n
          else if (u ~ /^MB/) print n * 1024
          else if (u ~ /^GB/) print n * 1024 * 1024
          else print n / 1024
          exit
        }
      }')
    if [ -z "$fkb" ]; then
      printf '  %-7s %12s %12s %10s  %.40s\n' "$pid" "$(fmt_kb "$fpkb")" 'denied' '-' "$cmd"
      continue
    fi
    delta=$(awk -v a="$fpkb" -v b="$fkb" 'BEGIN { d = (a > b ? a - b : b - a); printf "%.1f%%", (b > 0 ? d * 100 / b : 0) }')
    printf '  %-7s %12s %12s %10s  %.40s\n' "$pid" "$(fmt_kb "$fpkb")" "$(fmt_kb "$fkb")" "$delta" "$cmd"
  done
  printf '  A few percent of drift is two samples taken moments apart, not disagreement.\n'
  printf '  footprint(1) reports "denied" for root-owned processes; top still measures them.\n'
}

# --- main -------------------------------------------------------------------

collect_top
collect_ps
parse_top
parse_ps
collect_cwd
collect_listen
run_self_check
build_owners
# One owner for the count every later caller reports; recomputing it per call
# site let the text report and the JSON drift apart in principle.
FLEET_RECORD_COUNT=$(awk -F'\t' '$2 == "task" || $2 == "secondmate" { n++ } END { print n + 0 }' "$TMP/owners.tsv")
check_records_were_read
build_git_cwds
classify_rows
check_agent_attribution

if [ "$mode" = json ]; then
  render_json
  exit 0
fi

host_line
printf 'Reading: %s processes, %s - %s.\n' "$SELF_PS_COUNT" "$MEASURED_LABEL" "$MEASURED_DESC"
printf 'Ownership read from %s fleet records in %s against each working directory.\n' \
  "$FLEET_RECORD_COUNT" "$STATE"
[ -n "${FM_HOME_REDIRECTED:-}" ] \
  && printf 'Invoked from a worktree with no records of its own; read the operating home above.\n'
render_attribution_warning
render_groups
render_reclaim
if [ "$show_tree" -eq 1 ]; then
  render_tree
else
  render_table
fi
[ "$verify" -eq 1 ] && render_verify
exit 0
