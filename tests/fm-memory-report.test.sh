#!/usr/bin/env bash
# tests/fm-memory-report.test.sh - contract tests for bin/fm-memory-report.sh,
# the one command that answers "what is eating this machine's memory, and who
# owns it" the same way every time.
#
# The script exists because that question was answered wrong three times in a row
# on 2026-07-24, each time by a distinct reproducible trap. These tests pin the
# defense against each trap, because a defense nobody tests is a defense that
# quietly rots back into the original bug:
#
#   1. A FILTERED OR TRUNCATED PROCESS TABLE REPORTED AS TRUTH.
#      -> test_refuses_* : the script must exit 3 printing NO table.
#   2. THE FLEET EXCLUDED BY A NAME FILTER (agents are `claude`, not `node`).
#      -> test_enumeration_is_unfiltered, test_agent_named_claude_is_counted.
#   3. rss COMPARED AGAINST phys_footprint AS IF THEY WERE ONE QUANTITY.
#      -> test_ranks_by_footprint_not_rss, test_both_columns_labelled.
#   4. OWNERSHIP GUESSED INSTEAD OF READ FROM state/*.meta.
#      -> test_attributes_*, test_unowned_vs_unclassified_are_distinct,
#         test_ancestry_never_overrides_records.
#
# The primary memory measurement is platform-specific: top(1) on macOS, /proc
# on Linux. The tests under "the Linux /proc reader" pin the Linux branch
# hermetically through the FM_MEMREPORT_PROC seam (a proc-shaped directory
# stands in for /proc, so the branch runs on ANY host) plus one native
# end-to-end run guarded to Linux hosts. Before the fix the Linux branch did
# not exist and the script died with RC=1 and "top(1) produced no output" on
# every Linux host in the fleet.
#
# Process listings are always INJECTED (FM_MEMREPORT_TOP / _PS / _LSOF), so no
# assertion depends on what happens to be running on the machine executing it.
#
# Records are a different matter. Most tests write their own records into a temp
# home, and that is exactly why the first version of this suite stayed green
# while ownership was broken against every real lane: a fixture the test authored
# cannot be missing the way a real home can, so the suite proved the matching
# logic and never exercised record DISCOVERY. The tests under "attribution
# against REAL state/*.meta content" therefore read the operating home's actual
# records - once, into a snapshot (see real_home) so they stay deterministic -
# and skip with a pass on a host that has no fleet records, such as CI.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPORT="$ROOT/bin/fm-memory-report.sh"

assert_present "$REPORT" "bin/fm-memory-report.sh is missing"
[ -x "$REPORT" ] || fail "bin/fm-memory-report.sh must be executable"

TMPROOT=$(fm_test_tmproot fm-memory-report)
HOME_DIR="$TMPROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects/alpha"

WT_TASK="$TMPROOT/wt/task-one"
WT_SECOND="$TMPROOT/wt/second-home"
WT_STALE="$TMPROOT/wt/stale-copy"
# The shared dev backend: a long-running server serving the whole fleet, started
# by a lane that has since torn down, so NO record claims it - which is exactly
# what a shared stack looks like, not evidence it is disposable. It sits in a git
# checkout (the incident's "unclaimed checkout") AND reports ppid 1 (reparented
# when its starting lane exited), so on the pre-fix code it landed squarely in
# RECLAIMABLE. It must never be reclaimable, because it holds a LISTEN socket.
WT_BACKEND="$TMPROOT/wt/shared-backend"
mkdir -p "$WT_TASK" "$WT_SECOND" "$WT_STALE" "$WT_BACKEND"
# A checkout marker so the "leftover in a checkout no record claims" class can be
# exercised: that class is a filesystem fact, not a guess about the path shape.
: > "$WT_STALE/.git"
: > "$WT_TASK/.git"
: > "$WT_BACKEND/.git"

fm_write_meta "$HOME_DIR/state/task-one.meta" \
  "window=firstmate:fm-task-one" \
  "worktree=$WT_TASK" \
  "project=$HOME_DIR/projects/alpha" \
  "harness=claude" \
  "kind=ship" \
  "mode=direct-PR"
fm_write_secondmate_meta "$HOME_DIR/state/second-home.meta" "$WT_SECOND"
cat > "$HOME_DIR/data/secondmates.md" <<EOF
- second-home - A persistent domain. (home: $WT_SECOND; scope: things; projects: alpha; added 2026-07-24)
EOF

# --- injected listings ------------------------------------------------------
#
# A synthetic machine large enough to clear the plausibility floors: one agent,
# its language server, a secondmate agent, an editor, a stale leftover, plus
# enough filler daemons to look like a real host.

TOP="$TMPROOT/top.raw"
PS="$TMPROOT/ps.raw"
LSOF="$TMPROOT/lsof.tsv"
LISTEN="$TMPROOT/listen.tsv"

build_listings() {
  local n
  {
    printf 'Processes: 220 total, 2 running, 218 sleeping, 900 threads \n'
    printf '2026/07/24 21:00:00\n'
    printf 'Load Avg: 2.00, 2.00, 2.00 \n'
    printf 'CPU usage: 3.0%% user, 10.0%% sys, 87.0%% idle \n'
    printf 'SharedLibs: 547M resident, 123M data, 70M linkedit.\n'
    printf 'MemRegions: 500591 total, 4746M resident, 191M private, 1753M shared.\n'
    printf 'PhysMem: 8G used (2798M wired, 1823M compressor), 1731M unused.\n'
    printf 'VM: 269T vsize, 5702M framework vsize, 100(0) swapins, 200(0) swapouts.\n'
    printf 'Networks: packets: 1/1G in, 2/2G out.\n'
    printf 'Disks: 3/3G read, 4/4G written.\n'
    printf '\n'
    printf 'PID    MEM   COMMAND         \n'
    # The language server is deliberately FOUR TIMES its agent: the whole point
    # of the rollup is that a per-process ranking understates a worker's cost.
    printf '1001   1200M lsp\n'
    printf '1002   300M  agent\n'
    printf '1003   280M  second\n'
    printf '1004   900M  editor\n'
    printf '1005   700M  stale\n'
    printf '1006   50M   self\n'
    printf '1007   40M   mystery\n'
    printf '1008   60M   foreign\n'
    # The shared dev backend, 800M - substantial, but deliberately below the
    # language server (1200M) so the footprint-vs-rss ranking test keeps its clean
    # two-way comparison. Its rss (below) is kept below the editor's so the
    # editor stays the rss-heaviest process the ranking test relies on.
    printf '1010   800M  backend\n'
    for n in $(seq 1 210); do printf '2%03d   30M   filler\n' "$n"; done
  } > "$TOP"

  {
    printf '1001 1 99000 cyuan node /opt/ts/node_modules/typescript/bin/tsserver --stdio\n'
    printf '1002 900 150000 cyuan claude --dangerously-skip-permissions --model opus\n'
    printf '1003 900 140000 cyuan claude --dangerously-skip-permissions --model opus\n'
    printf '1004 1 400000 cyuan /Applications/Cursor.app/Contents/MacOS/Cursor\n'
    printf '1005 1 200000 cyuan node /opt/ts/node_modules/typescript/bin/tsserver --stdio\n'
    printf '1006 900 20000 cyuan /bin/bash %s\n' "$REPORT"
    # No lsof entry below and nothing recognisable in its path: its facts cannot
    # be read, so it must land in `unclassified` and never in a finding bucket.
    printf '1007 900 30000 cyuan /opt/vendor/mystery-daemon --serve\n'
    # A third agent, deliberately NOT in any recorded directory: a foreign agent
    # (another tool's, or the captain's own). One unowned agent out of three is
    # normal and must stay quiet; three out of three is the wrong-home signature.
    printf '1008 900 40000 cyuan /usr/local/bin/opencode serve --port 1234\n'
    # The shared dev backend: node in an unclaimed checkout, reparented to ppid 1.
    # Its kind is `tooling` (node) and it is in a git checkout no record claims,
    # so before the fix every reclaim-list criterion matched it. The LISTEN socket
    # below is what keeps it out.
    printf '1010 1 300000 cyuan node %s/server.js --port 4500\n' "$WT_BACKEND"
    for n in $(seq 1 210); do printf '2%03d 1 8000 root /usr/libexec/filler%s\n' "$n" "$n"; done
  } > "$PS"

  {
    printf '1001\t%s\n' "$WT_TASK"
    printf '1002\t%s\n' "$WT_TASK"
    printf '1003\t%s\n' "$WT_SECOND"
    printf '1005\t%s\n' "$WT_STALE"
    # The foreign agent's cwd must NOT be an ancestor of the unclaimed checkout
    # (WT_STALE): shares_agent_dir adopts tooling under a live agent's cwd, so a
    # cwd of /tmp would shadow the leftover on hosts whose temp root is /tmp
    # (CI), classifying it as "live agent, not this fleet" instead of unclaimed.
    printf '1008\t%s\n' "$TMPROOT/foreign-agent"
    printf '1006\t%s\n' "$HOME_DIR"
    printf '1010\t%s\n' "$WT_BACKEND"
  } > "$LSOF"

  # Listening TCP sockets, as pid<TAB>port. Only the shared backend holds one:
  # that single fact is what moves it out of RECLAIMABLE and into `server`.
  {
    printf '1010\t4500\n'
  } > "$LISTEN"
}
build_listings

# An empty listening-socket listing, for the custom invocations below that build
# their own environment. Injected so no assertion ever falls through to the real
# lsof of whatever host runs the suite - the same hermeticity the other seams get.
EMPTY_LISTEN="$TMPROOT/empty.listen"
: > "$EMPTY_LISTEN"

# run_report <args...>: run against the injected listings with pid 1006 (the
# script's stand-in) as the pid the self-check requires to be present.
run_report() {
  FM_HOME="$HOME_DIR" \
  FM_MEMREPORT_TOP="$TOP" \
  FM_MEMREPORT_PS="$PS" \
  FM_MEMREPORT_LSOF="$LSOF" \
  FM_MEMREPORT_LISTEN="$LISTEN" \
  FM_MEMREPORT_SELF_PID=1006 \
    "$REPORT" "$@" 2>&1
}

# run_broken <top> <ps> [selfpid]: run with a deliberately broken instrument.
run_broken() {
  FM_HOME="$HOME_DIR" \
  FM_MEMREPORT_TOP="$1" \
  FM_MEMREPORT_PS="$2" \
  FM_MEMREPORT_LSOF="$LSOF" \
  FM_MEMREPORT_LISTEN="$LISTEN" \
  FM_MEMREPORT_SELF_PID="${3:-1006}" \
    "$REPORT" 2>&1
}

# --- trap 1: refuse rather than print a confident wrong table ---------------

test_refuses_truncated_memory_listing() {
  local out rc trunc
  trunc="$TMPROOT/trunc.top"
  head -20 "$TOP" > "$trunc"
  out=$(run_broken "$trunc" "$PS"); rc=$?
  expect_code 3 "$rc" "a truncated memory listing must refuse"
  assert_contains "$out" "REFUSING" "the refusal must say so plainly"
  assert_not_contains "$out" "TOP PROCESSES" "a refusal must print NO ranking"
  pass "refuses a truncated memory listing and prints no table"
}

test_refuses_truncated_process_listing() {
  local out rc trunc
  trunc="$TMPROOT/trunc.ps"
  head -6 "$PS" > "$trunc"
  out=$(run_broken "$TOP" "$trunc"); rc=$?
  expect_code 3 "$rc" "a truncated process listing must refuse"
  assert_not_contains "$out" "TOP PROCESSES" "a refusal must print NO ranking"
  pass "refuses a truncated process listing and prints no table"
}

test_refuses_when_own_pid_is_absent() {
  local out rc
  # Nothing can enumerate every process while missing the one doing the asking.
  out=$(run_broken "$TOP" "$PS" 999999); rc=$?
  expect_code 3 "$rc" "a listing missing the reader's own pid must refuse"
  assert_contains "$out" "own pid" "the refusal must name the missing-self problem"
  assert_not_contains "$out" "TOP PROCESSES" "a refusal must print NO ranking"
  pass "refuses a listing that cannot see the process reading it"
}

test_refuses_impossibly_small_total() {
  local out rc tiny
  # The incident's decisive shape: plenty of processes, but a total far too
  # small to describe a machine with 8G in use.
  tiny="$TMPROOT/tiny.top"
  awk 'f && $1 ~ /^[0-9]+$/ { printf "%s  2M\n", $1; next } { print } /^PID/ { f = 1 }' "$TOP" > "$tiny"
  out=$(run_broken "$tiny" "$PS"); rc=$?
  expect_code 3 "$rc" "an impossibly small total must refuse"
  assert_contains "$out" "impossibly small" "the refusal must name the implausible total"
  assert_not_contains "$out" "TOP PROCESSES" "a refusal must print NO ranking"
  pass "refuses a total too small to describe the machine"
}

test_refuses_when_listings_disagree() {
  local out rc few
  few="$TMPROOT/few.ps"
  head -80 "$PS" > "$few"
  out=$(run_broken "$TOP" "$few"); rc=$?
  expect_code 3 "$rc" "two disagreeing enumerations must refuse"
  assert_not_contains "$out" "TOP PROCESSES" "a refusal must print NO ranking"
  pass "refuses when the two process listings disagree"
}

test_healthy_reading_does_not_refuse() {
  local out rc
  out=$(run_report); rc=$?
  expect_code 0 "$rc" "a healthy reading must report"
  assert_not_contains "$out" "REFUSING" "a healthy reading must not refuse"
  assert_contains "$out" "TOP PROCESSES" "a healthy reading must print the ranking"
  pass "a healthy reading reports normally"
}

# --- trap 2: enumeration is never decided by a name filter ------------------

test_agent_named_claude_is_counted() {
  local out
  out=$(run_report --all)
  # Filtering on `node` was what hid the fleet: agents run as `claude`.
  assert_contains "$out" "1002" "the claude agent must appear in the ranking"
  assert_contains "$out" "agent" "the agent must be labelled as one"
  pass "an agent running as claude is counted, not missed by a node filter"
}

test_enumeration_is_unfiltered() {
  local out n
  out=$(run_report --all)
  # Every process in the injected listing must survive to the output. A name
  # filter deciding what counts is exactly trap 2.
  n=$(printf '%s\n' "$out" | awk '$1 ~ /^(1001|1002|1003|1004|1005|1006)$/ { c++ } END { print c + 0 }')
  [ "$n" -eq 6 ] || fail "expected all 6 named processes in --all output, got $n"
  n=$(printf '%s\n' "$out" | awk '$1 ~ /^2[0-9][0-9][0-9]$/ { c++ } END { print c + 0 }')
  [ "$n" -ge 200 ] || fail "expected the filler daemons to be enumerated too, got $n"
  pass "--all enumerates every process, with no name filter deciding what counts"
}

# --- trap 3: phys_footprint is primary; rss is never a substitute -----------

test_ranks_by_footprint_not_rss() {
  local out first
  out=$(run_report)
  # By footprint the language server (1200M) leads. By rss the editor (400000K)
  # would - which is the inversion that produced "the agents are the hogs".
  first=$(printf '%s\n' "$out" | awk '/^  PID / { got = 1; next } got && $1 ~ /^[0-9]+$/ { print $1; exit }')
  [ "$first" = 1001 ] \
    || fail "ranking must be by phys_footprint (expected 1001 first, got '$first')"
  pass "the ranking is ordered by phys_footprint, not rss"
}

test_both_columns_labelled() {
  local out
  out=$(run_report)
  assert_contains "$out" "FOOTPRINT" "the footprint column must be labelled"
  assert_contains "$out" "RSS" "the rss column must be labelled as rss"
  assert_contains "$out" "phys_footprint" "the report must name the quantity it measured"
  assert_contains "$out" "Activity Monitor" "the report must say which column it matches"
  pass "footprint and rss are shown as distinct, labelled quantities"
}

# --- trap 4: ownership is read from records, never guessed ------------------

test_attributes_a_live_fleet_task() {
  local out
  out=$(run_report --all)
  printf '%s\n' "$out" | awk '$1 == 1002' | grep -Fq "task:task-one" \
    || fail "the agent in the task worktree must be attributed to that task"
  pass "a live fleet task is attributed from state/*.meta and the working directory"
}

test_attributes_a_secondmate() {
  local out
  out=$(run_report --all)
  printf '%s\n' "$out" | awk '$1 == 1003' | grep -Fq "secondmate:second-home" \
    || fail "the agent in the secondmate home must be attributed to that secondmate"
  pass "a registered secondmate is attributed from the registry"
}

test_attributes_editor_tooling() {
  local out
  out=$(run_report --all)
  printf '%s\n' "$out" | awk '$1 == 1004' | grep -Fq "editor" \
    || fail "the editor process must be labelled editor/tooling"
  pass "an editor process is classified as editor / language tooling"
}

test_language_server_rolls_up_to_its_owner() {
  local out line
  out=$(run_report)
  # THE point of the rollup: the worker costs agent + language server, and the
  # group must show BOTH its own footprint and the total with children.
  line=$(printf '%s\n' "$out" | awk '/task:task-one|task +task-one/ { print; exit }')
  [ -n "$line" ] || fail "no owner group line for task-one"
  case "$line" in
    *"1.46 GB"*|*"1.4"*" GB"*) : ;;
    *) fail "task-one's total must include its language server, got: $line" ;;
  esac
  case "$line" in
    *"agent itself"*) : ;;
    *) fail "the group must show the agent's own footprint too, got: $line" ;;
  esac
  case "$line" in
    *"language server"*) : ;;
    *) fail "the group must name the language server it rolled up, got: $line" ;;
  esac
  pass "a language server rolls up to its owner, showing own and total-with-children"
}

test_ancestry_never_overrides_records() {
  local out
  out=$(run_report --all)
  # pid 1001 reports ppid 1 (reparented when its spawner died) but its working
  # directory is the live task's worktree. Records win; ancestry does not get to
  # call it an orphan. This is the exact misjudgement that started all this.
  printf '%s\n' "$out" | awk '$1 == 1001' | grep -Fq "task:task-one" \
    || fail "a reparented (ppid 1) process must still be owned via its working directory"
  printf '%s\n' "$out" | awk '$1 == 1001' | grep -Fq "cwd" \
    || fail "that attribution must be recorded as coming from the working directory"
  pass "ppid 1 never overrides what the durable records say about ownership"
}

test_unowned_vs_unclassified_are_distinct() {
  local out
  out=$(run_report --all)
  # 1005 sits in a checkout no record claims: genuinely unowned, and a reclaim
  # candidate. The filler daemons have no readable working directory at all -
  # that is unclassified, and must never be presented as a finding.
  printf '%s\n' "$out" | awk '$1 == 1005' | grep -Fq "checkout no record claims" \
    || fail "a leftover in an unclaimed checkout must read as unowned"
  assert_contains "$out" "unclassified" "unclassified must exist as its own bucket"
  printf '%s\n' "$out" | awk '$1 == 1005' | grep -Fqv "unclassified" \
    || fail "an unowned process must not be reported as unclassified"
  pass "unowned (records read, none claimed it) is distinct from unclassified"
}

test_unreadable_facts_never_become_findings() {
  local out empty owned_line
  # The sharpest form of the rule: if the working-directory source yields
  # NOTHING, every process that needed one must fall to `unclassified` and none
  # of it may appear as a reclaim candidate. Degrading into "unowned" here would
  # manufacture a multi-gigabyte finding out of a missing input - trap 4 with
  # better manners.
  empty="$TMPROOT/empty.lsof"
  : > "$empty"
  out=$(FM_HOME="$HOME_DIR" FM_MEMREPORT_TOP="$TOP" FM_MEMREPORT_PS="$PS" \
        FM_MEMREPORT_LSOF="$empty" FM_MEMREPORT_LISTEN="$EMPTY_LISTEN" FM_MEMREPORT_SELF_PID=1006 "$REPORT" 2>&1)
  assert_contains "$out" "unclassified" "a missing cwd source must produce unclassified"
  owned_line=$(printf '%s\n' "$out" | awk '/^ +unowned /')
  [ -z "$owned_line" ] \
    || fail "unreadable facts must never be reported as unowned, got: $owned_line"
  printf '%s\n' "$out" | awk '/RECLAIMABLE/, /never kills/' | grep -Fq "no record claims" \
    && fail "unreadable facts must never appear as a reclaim candidate"
  pass "when facts cannot be read the result is unclassified, never a finding"
}

test_reclaim_classes_do_not_overlap() {
  local out
  out=$(run_report)
  assert_contains "$out" "RECLAIMABLE" "the reclaim grouping must be shown"
  assert_contains "$out" "do not overlap" "the reclaim classes must state they are disjoint"
  assert_contains "$out" "never kills anything" "the read-only contract must be stated"
  pass "the reclaim grouping is disjoint and states its read-only contract"
}

# --- attribution self-checks -------------------------------------------------
#
# These pin the defect that shipped: 25 synthetic-fixture tests were green while
# ownership was broken against every real lane on the machine. The reading was
# fine; the RECORD SET was empty, and "unowned" was asserted about live work on
# the strength of records that had never been read.

test_refuses_when_records_cannot_be_read() {
  local out rc nostate
  # The question is whether the record store was READABLE, not whether it
  # happened to be empty. A missing store is the shape that caused the shipped
  # defect: run from a worktree, which has no state/ at all, the report called
  # every live lane unowned having read nothing.
  nostate="$TMPROOT/nostatehome"
  mkdir -p "$nostate/data"
  out=$(FM_HOME="$nostate" FM_MEMREPORT_TOP="$TOP" FM_MEMREPORT_PS="$PS" \
        FM_MEMREPORT_LSOF="$LSOF" FM_MEMREPORT_LISTEN="$LISTEN" FM_MEMREPORT_SELF_PID=1006 "$REPORT" 2>&1); rc=$?
  expect_code 3 "$rc" "an unreadable record store must refuse, not label live work unowned"
  assert_contains "$out" "could not be read" "the refusal must name the unreadable store"
  assert_not_contains "$out" "TOP PROCESSES" "a refusal must print NO ranking"
  # The decisive property: it must never have called anything unowned.
  assert_not_contains "$out" "no record claims it" \
    "with no records read, nothing may be described as unowned"
  pass "refuses rather than calling live work unowned when records cannot be read"
}

test_idle_fleet_is_not_a_broken_instrument() {
  local out rc empty
  # An empty but READABLE store means the fleet is genuinely idle. Refusing there
  # would make the report useless exactly when the machine is quiet, which is a
  # perfectly ordinary time to ask what is using memory.
  empty="$TMPROOT/idlehome"
  mkdir -p "$empty/state" "$empty/data"
  out=$(FM_HOME="$empty" FM_MEMREPORT_TOP="$TOP" FM_MEMREPORT_PS="$PS" \
        FM_MEMREPORT_LSOF="$LSOF" FM_MEMREPORT_LISTEN="$LISTEN" FM_MEMREPORT_SELF_PID=1006 "$REPORT" 2>&1); rc=$?
  expect_code 0 "$rc" "an idle fleet must still report; it is not a broken instrument"
  assert_contains "$out" "TOP PROCESSES" "an idle fleet must still get its ranking"
  pass "an idle but readable record store reports normally"
}

test_live_agents_are_never_reclaimable() {
  local out reclaim
  # THE safety property of the reclaim list. A running agent that no record of
  # THIS home claims belongs to another tool, another home, or the captain - it
  # is live work. Billing it as free memory is the original incident one layer
  # out. pid 1008 is exactly that: an agent in no recorded directory.
  out=$(run_report --all)
  printf '%s\n' "$out" | awk '$1 == 1008' | grep -Fq "live agent" \
    || fail "an unclaimed running agent must be bucketed as a live foreign agent"
  reclaim=$(printf '%s\n' "$out" | awk '/RECLAIMABLE/, /never kills/')
  assert_contains "$reclaim" "NOT listed" "the reclaim list must say what it excluded"
  case "$reclaim" in
    *"live agent"*) : ;;
    *) fail "the reclaim list must name the live agents it excluded" ;;
  esac
  pass "a running agent no record claims is never offered as reclaimable"
}

test_editor_is_surfaced_but_not_billed_as_free() {
  local out reclaim
  # The editor is the single largest available win, so it must be visible - but
  # on this fleet the terminal emulator hosts the tmux session every agent runs
  # in, so "no live work depends on it" would be flatly false.
  out=$(run_report)
  reclaim=$(printf '%s\n' "$out" | awk '/RECLAIMABLE/, /never kills/')
  assert_contains "$reclaim" "YOUR CALL" "closing the editor must be offered as a human decision"
  # The editor's 900M must NOT be inside the freed-if-reclaimed total. The only
  # qualifying leftover in the fixture is the language server in the stale
  # checkout, so the total is that alone.
  case "$reclaim" in
    *"leftovers in a checkout no record claims"*) : ;;
    *) fail "the genuine leftover class must still be reported" ;;
  esac
  printf '%s\n' "$reclaim" | awk '/total, if all of the above were freed/' | grep -Fq "900" \
    && fail "the editor must not be inside the reclaimable total"
  pass "the editor is surfaced as a decision, not billed as reclaimable"
}

# --- a listening server is never a leftover ----------------------------------
#
# The incident of 2026-08-01: `--tree` listed the fleet's SHARED dev backend - a
# deliberately-started long-running server serving the whole fleet - under
# RECLAIMABLE, because it was "unowned / a leftover in a checkout no record
# claims" with "no-live-parent". All three were true and all three were
# irrelevant: a shared stack has NO owning task BY DESIGN, so "unowned" is its
# natural state, not evidence it is disposable. Firstmate acted on that list and
# killed the shared stack, costing a lane its test gate. The fixture backend
# (pid 1010) reproduces every pre-fix trigger - node kind, unclaimed git
# checkout, ppid 1 - and is kept out of the reclaim list solely by its LISTEN
# socket.

test_listening_server_is_never_reclaimable() {
  local out reclaim
  # THE regression. A process holding a listening socket in an unclaimed checkout
  # must NEVER appear in the reclaimable list, even though every other criterion
  # (node tooling, git checkout, reparented) matches the leftover shape.
  out=$(run_report)
  reclaim=$(printf '%s\n' "$out" | awk '/RECLAIMABLE/, /never kills/')
  # The backend's 800 MB must not be inside the freed-if-reclaimed total.
  printf '%s\n' "$reclaim" | awk '/total, if all of the above were freed/' | grep -Fq "800 MB" \
    && fail "the listening server must not be inside the reclaimable total"
  # Nor may it be named as a leftover in any reclaim-candidate line. The only
  # genuine leftover in the fixture is the language server in the stale checkout.
  printf '%s\n' "$reclaim" | grep -F "shared-backend" \
    && fail "the listening server must not appear as a reclaim candidate"
  printf '%s\n' "$reclaim" | grep -F "4500" | grep -Fq "no record claims" \
    && fail "the server's port must not be presented as a leftover"
  pass "a listening server in an unclaimed checkout is never offered as reclaimable"
}

test_listening_server_gets_its_own_class_with_ports() {
  local out line json
  # A listening server is surfaced in its own labelled `server` class WITH its
  # ports, so a human can see what it is serving rather than wondering where the
  # memory went.
  out=$(run_report --all)
  # The owner group must show a server class.
  printf '%s\n' "$out" | awk '/^BY OWNER/,/^RECLAIMABLE/' | grep -Fq "server" \
    || fail "a listening server must appear in its own owner class"
  # The port must travel with it, in both the group label and the process row.
  printf '%s\n' "$out" | grep -F "listening server" | grep -Fq "4500" \
    || fail "the server class must name the port it is listening on"
  line=$(printf '%s\n' "$out" | awk '$1 == 1010')
  [ -n "$line" ] || fail "the backend process must appear in the ranking"
  case "$line" in
    *"listen"*) : ;;
    *) fail "the backend row must record it was attributed via its listen socket, got: $line" ;;
  esac
  # And the reclaim context must name it as excluded, so nothing is silently lost.
  printf '%s\n' "$out" | awk '/RECLAIMABLE/, /never kills/' \
    | grep -Fq "listening server" \
    || fail "the reclaim context must name the listening server it excluded"
  # --json carries the class and ports as structured fields.
  json=$(run_report --json)
  printf '%s\n' "$json" | grep -F '"pid":1010' | grep -Fq '"owner_kind":"server"' \
    || fail "--json must classify the server with owner_kind server"
  printf '%s\n' "$json" | grep -F '"pid":1010' | grep -Fq 'listening:4500' \
    || fail "--json must carry the listening flag with the port"
  pass "a listening server is surfaced in its own class with its ports"
}

test_listening_server_ports_are_sorted_and_deduplicated() {
  local multi out
  # A server on several ports must read as one deterministic, numerically-sorted,
  # deduplicated list, so the same server looks the same every run and cannot be
  # confused for several findings.
  multi="$TMPROOT/multi.listen"
  {
    printf '1010\t4500\n'
    printf '1010\t443\n'
    printf '1010\t80\n'
    printf '1010\t4500\n'
  } > "$multi"
  out=$(FM_HOME="$HOME_DIR" FM_MEMREPORT_TOP="$TOP" FM_MEMREPORT_PS="$PS" \
        FM_MEMREPORT_LSOF="$LSOF" FM_MEMREPORT_LISTEN="$multi" \
        FM_MEMREPORT_SELF_PID=1006 "$REPORT" --json 2>&1)
  printf '%s\n' "$out" | grep -F '"pid":1010' | grep -Fq 'listening:80,443,4500' \
    || fail "multiple ports must be numerically sorted and deduplicated"
  pass "a multi-port server reports one sorted, deduplicated port list"
}

test_a_leftover_without_a_listen_socket_still_reclaims() {
  local out reclaim
  # The fix must NOT disarm the genuine leftover class. The stale-checkout
  # language server (pid 1005) holds no listening socket, so it must still be
  # offered as reclaimable exactly as before - otherwise the fix would have
  # thrown away the very finding the script exists to make.
  out=$(run_report)
  reclaim=$(printf '%s\n' "$out" | awk '/RECLAIMABLE/, /never kills/')
  case "$reclaim" in
    *"leftovers in a checkout no record claims"*) : ;;
    *) fail "a genuine leftover with no listen socket must still be reclaimable" ;;
  esac
  pass "a leftover without a listening socket is still offered as reclaimable"
}

test_warns_when_agents_match_no_record() {
  local out rc wrong f
  # Records exist, but they describe worktrees nothing is running in - the shape
  # produced by reading the wrong home. The reading is valid for that home, so
  # this warns loudly instead of refusing.
  wrong="$TMPROOT/wronghome"
  mkdir -p "$wrong/state" "$wrong/data"
  for f in "$HOME_DIR"/state/*.meta; do
    sed -e 's#^worktree=.*#worktree=/nonexistent/elsewhere#' \
        -e 's#^home=.*#home=/nonexistent/elsewhere-home#' "$f" \
        > "$wrong/state/$(basename "$f")"
  done
  out=$(FM_HOME="$wrong" FM_MEMREPORT_TOP="$TOP" FM_MEMREPORT_PS="$PS" \
        FM_MEMREPORT_LSOF="$LSOF" FM_MEMREPORT_LISTEN="$LISTEN" FM_MEMREPORT_SELF_PID=1006 "$REPORT" 2>&1); rc=$?
  expect_code 0 "$rc" "a valid reading of the wrong home must still report"
  assert_contains "$out" "ATTRIBUTION LOOKS WRONG" "the mismatch must be called out loudly"
  assert_contains "$out" "do not act on the reclaim list" \
    "the warning must tell the reader not to act on it"
  pass "warns loudly when agents match no record, the signature of the wrong home"
}

test_attribution_warning_survives_a_pipe() {
  local out wrong f
  # The warning qualifies the table, so it must be on the SAME stream. On stderr
  # a caller that pipes the report would get the table with the doubt stripped
  # off - the confident wrong output all over again.
  wrong="$TMPROOT/wronghome2"
  mkdir -p "$wrong/state" "$wrong/data"
  for f in "$HOME_DIR"/state/*.meta; do
    sed -e 's#^worktree=.*#worktree=/nonexistent/elsewhere#' \
        -e 's#^home=.*#home=/nonexistent/elsewhere-home#' "$f" \
        > "$wrong/state/$(basename "$f")"
  done
  out=$(FM_HOME="$wrong" FM_MEMREPORT_TOP="$TOP" FM_MEMREPORT_PS="$PS" \
        FM_MEMREPORT_LSOF="$LSOF" FM_MEMREPORT_LISTEN="$LISTEN" FM_MEMREPORT_SELF_PID=1006 "$REPORT" 2>/dev/null)
  assert_contains "$out" "ATTRIBUTION LOOKS WRONG" \
    "the warning must be on stdout so it survives a pipe"
  # And a machine consumer must see the same doubt.
  out=$(FM_HOME="$wrong" FM_MEMREPORT_TOP="$TOP" FM_MEMREPORT_PS="$PS" \
        FM_MEMREPORT_LSOF="$LSOF" FM_MEMREPORT_LISTEN="$LISTEN" FM_MEMREPORT_SELF_PID=1006 "$REPORT" --json 2>/dev/null)
  assert_contains "$out" '"attribution_warning": "' \
    "--json must carry the attribution warning as a field"
  pass "the attribution warning survives a pipe and reaches machine consumers"
}

test_healthy_attribution_is_quiet() {
  local out
  out=$(run_report)
  assert_not_contains "$out" "ATTRIBUTION LOOKS WRONG" \
    "a correctly attributed fleet must not warn"
  pass "correct attribution produces no warning"
}

# --- attribution against REAL state/*.meta content ---------------------------
#
# The synthetic fixtures above proved the matching logic against records this
# test file wrote itself, which is exactly why they stayed green through the
# defect. This drives the SAME logic against the real records on this machine:
# real key names, real path shapes, real secondmate `home=` entries.

# Echoes a SNAPSHOT of the operating home's real records, or fails if this host
# has none (CI). The snapshot is taken once and everything downstream reads it,
# so the assertions use real record content while staying deterministic: the live
# fleet gains and loses records constantly - a lane started during this very task
# - and a test that re-read the originals could see two different record sets
# between building its fixture and checking the result.
FM_REAL_SNAPSHOT=""
real_home() {
  local common primary snap
  [ -n "$FM_REAL_SNAPSHOT" ] && { printf '%s\n' "$FM_REAL_SNAPSHOT"; return 0; }
  common=$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in /*) : ;; *) common="$ROOT/$common" ;; esac
  primary=$(cd "$(dirname "$common")" 2>/dev/null && pwd -P) || return 1
  compgen -G "$primary/state/*.meta" >/dev/null 2>&1 || return 1
  snap="$TMPROOT/realsnap"
  mkdir -p "$snap/state" "$snap/data"
  cp "$primary"/state/*.meta "$snap/state/" 2>/dev/null || return 1
  [ -r "$primary/data/secondmates.md" ] && cp "$primary/data/secondmates.md" "$snap/data/"
  FM_REAL_SNAPSHOT=$snap
  printf '%s\n' "$snap"
}

test_attributes_against_real_meta_records() {
  local home f id path pid n=0 top ps lsof out
  if ! home=$(real_home); then
    pass "no real fleet records on this host; real-record attribution skipped"
    return 0
  fi
  top="$TMPROOT/real.top"; ps="$TMPROOT/real.ps"; lsof="$TMPROOT/real.lsof"
  head -12 "$TOP" > "$top"
  : > "$ps"; : > "$lsof"
  pid=3000
  # One synthetic agent per real record, placed in the directory that record
  # actually names. Every one must come back owned by that record's id.
  for f in "$home"/state/*.meta; do
    id=$(basename "$f" .meta)
    path=$(awk -F= '/^worktree=/ { print $2; exit }' "$f")
    [ -n "$path" ] || path=$(awk -F= '/^home=/ { print $2; exit }' "$f")
    [ -n "$path" ] || continue
    pid=$((pid + 1)); n=$((n + 1))
    printf '%s   40M   real\n' "$pid" >> "$top"
    printf '%s 900 30000 cyuan claude --dangerously-skip-permissions --model opus\n' "$pid" >> "$ps"
    printf '%s\t%s\n' "$pid" "$path" >> "$lsof"
    # A process one level DEEPER than the recorded path must attribute too: a
    # crewmate rarely sits at the worktree root.
    pid=$((pid + 1))
    printf '%s   40M   deep\n' "$pid" >> "$top"
    printf '%s 900 30000 cyuan node /opt/ts/bin/tsserver --stdio\n' "$pid" >> "$ps"
    printf '%s\t%s/src/nested\n' "$pid" "$path" >> "$lsof"
  done
  [ "$n" -gt 0 ] || { pass "real records carried no worktree/home path; skipped"; return 0; }
  # Pad to clear the plausibility floors, then reuse the fixture's tail.
  awk 'f && $1 ~ /^2[0-9]+$/ { print } /^PID/ { f = 1 }' "$TOP" >> "$top"
  awk '$1 ~ /^2[0-9][0-9][0-9]$/ { print }' "$PS" >> "$ps"
  printf '1006   50M   self\n' >> "$top"
  printf '1006 900 20000 cyuan /bin/bash %s\n' "$REPORT" >> "$ps"

  out=$(FM_HOME="$home" FM_MEMREPORT_TOP="$top" FM_MEMREPORT_PS="$ps" \
        FM_MEMREPORT_LSOF="$lsof" FM_MEMREPORT_LISTEN="$EMPTY_LISTEN" FM_MEMREPORT_SELF_PID=1006 "$REPORT" --all 2>&1)
  [ "${out#*REFUSING}" = "$out" ] || fail "real-record run refused: $out"
  assert_not_contains "$out" "ATTRIBUTION LOOKS WRONG" \
    "agents sitting in real recorded worktrees must attribute cleanly"

  # Compare exactly, from --json: the text OWNER column is width-truncated, and
  # comparing against a truncated label would pass on a wrong owner. Note two
  # real records may name the SAME worktree, so the assertion is that the
  # resolved owner is one of the records claiming that exact path - the check is
  # "attributed to a claiming record", never "attributed to nothing".
  command -v python3 >/dev/null 2>&1 || {
    pass "python3 unavailable for exact owner comparison; real-record depth check skipped"
    return 0
  }
  local json bad
  json=$(FM_HOME="$home" FM_MEMREPORT_TOP="$top" FM_MEMREPORT_PS="$ps" \
         FM_MEMREPORT_LSOF="$lsof" FM_MEMREPORT_LISTEN="$EMPTY_LISTEN" FM_MEMREPORT_SELF_PID=1006 "$REPORT" --json 2>/dev/null)
  bad=$(printf '%s' "$json" | REAL_HOME="$home" REAL_LSOF="$lsof" python3 -c '
import json, sys, os
d = json.load(sys.stdin)
home = os.environ["REAL_HOME"]
# path -> every record id that claims it
claims = {}
for name in os.listdir(os.path.join(home, "state")):
    if not name.endswith(".meta"):
        continue
    rid = name[:-5]
    for line in open(os.path.join(home, "state", name)):
        k, _, v = line.strip().partition("=")
        if k in ("worktree", "home") and v:
            claims.setdefault(v, set()).add(rid)
cwds = {}
for line in open(os.environ["REAL_LSOF"]):
    pid, _, path = line.strip().partition("\t")
    cwds[int(pid)] = path
bad = 0
for p in d["processes"]:
    path = cwds.get(p["pid"])
    if path is None:
        continue
    base = path[:-len("/src/nested")] if path.endswith("/src/nested") else path
    want = claims.get(base)
    if not want:
        continue
    if p["owner"] not in want or p["owner_kind"] not in ("task", "secondmate"):
        bad += 1
        print("pid %s in %s -> %s/%s, expected one of %s"
              % (p["pid"], path, p["owner_kind"], p["owner"], sorted(want)), file=sys.stderr)
print(bad)
' 2>&1 | tail -1)
  [ "$bad" = 0 ] || fail "$bad process(es) in real recorded directories were not attributed to a claiming record"
  pass "every real state/*.meta record attributes its worktree and one subdirectory deeper ($n records)"
}

test_real_secondmate_home_attributes() {
  local home f id path found=0 top ps lsof out
  if ! home=$(real_home); then
    pass "no real fleet records on this host; real secondmate check skipped"
    return 0
  fi
  # A secondmate's home is a firstmate worktree recorded as `home=`, so it will
  # never match a project-worktree shape. It must still attribute.
  for f in "$home"/state/*.meta; do
    awk -F= '/^kind=/ { print $2; exit }' "$f" | grep -Fqx secondmate || continue
    path=$(awk -F= '/^home=/ { print $2; exit }' "$f")
    [ -n "$path" ] || continue
    id=$(basename "$f" .meta); found=1; break
  done
  [ "$found" -eq 1 ] || { pass "no real secondmate records on this host; skipped"; return 0; }
  top="$TMPROOT/sm.top"; ps="$TMPROOT/sm.ps"; lsof="$TMPROOT/sm.lsof"
  sed 's/^1003   280M  second$/1003   280M  second/' "$TOP" > "$top"
  cp "$PS" "$ps"
  printf '1003\t%s\n' "$path" > "$lsof"
  printf '1006\t%s\n' "$home" >> "$lsof"
  out=$(FM_HOME="$home" FM_MEMREPORT_TOP="$top" FM_MEMREPORT_PS="$ps" \
        FM_MEMREPORT_LSOF="$lsof" FM_MEMREPORT_LISTEN="$EMPTY_LISTEN" FM_MEMREPORT_SELF_PID=1006 "$REPORT" --all 2>&1)
  printf '%s\n' "$out" | awk '$1 == 1003' | grep -Fq "$id" \
    || fail "a real secondmate home= record must attribute (expected $id)"
  pass "a real secondmate home= record attributes its agent"
}

test_worktree_invocation_finds_the_operating_home() {
  local out
  # THE regression: invoked from a firstmate worktree with no state/ of its own,
  # the report must resolve the operating home instead of reporting an empty
  # record set as though the fleet were unowned.
  if ! real_home >/dev/null; then
    pass "no real fleet records on this host; worktree-invocation check skipped"
    return 0
  fi
  out=$(cd "$ROOT" && ./bin/fm-memory-report.sh --limit 1 2>&1)
  [ "${out#*REFUSING}" = "$out" ] \
    || fail "invocation from a worktree must resolve the operating home, not refuse"
  assert_contains "$out" "fleet records" "the report must state how many records it read"
  case "$out" in
    *"Ownership read from 0 fleet records"*)
      fail "invocation from a worktree read zero records - the original defect" ;;
  esac
  pass "invoked from a worktree, the report resolves the operating home"
}

# --- the Linux /proc reader -------------------------------------------------
#
# On macOS the primary memory source is top(1). On Linux that call produces no
# output at all, so the reader is platform-specific: /proc is enumerated, each
# process's PSS is read from smaps_rollup (VmRSS from status when the mapping
# table is unreadable), and the result is emitted in the SAME normalized shape
# parse_top reads. The FM_MEMREPORT_PROC seam points the reader at a
# proc-shaped directory instead of /proc, so the whole branch is pinned on any
# host, macOS CI included; the native end-to-end test additionally runs the
# real /proc on Linux hosts.

LINUX_PS="$TMPROOT/linux.ps"
LINUX_PROC="$TMPROOT/fakeproc"
EMPTY_LSOF="$TMPROOT/empty.lsof"
: > "$EMPTY_LSOF"

build_fake_proc() {
  rm -rf "$LINUX_PROC"
  mkdir -p "$LINUX_PROC"
  cat > "$LINUX_PROC/meminfo" <<'EOF'
MemTotal:       16777216 kB
MemAvailable:    8388608 kB
SwapTotal:             0 kB
SwapFree:              0 kB
EOF
  # 55 PSS-bearing processes clear the MIN_PROCS floor; 3050 is the self pid.
  # 3059 has no smaps_rollup and zero VmRSS - the kernel-thread shape, which
  # must still be counted as a 0K row so the two enumerations agree. 3060 has
  # no smaps_rollup but a real VmRSS: the world-readable status fallback.
  local i pid
  for i in $(seq 1 55); do
    pid=$(( 3000 + i ))
    mkdir -p "$LINUX_PROC/$pid"
    printf 'Pss:\t %d kB\n' "$(( 200000 + i ))" > "$LINUX_PROC/$pid/smaps_rollup"
    printf 'VmRSS:\t %d kB\n' "$(( 250000 + i ))" > "$LINUX_PROC/$pid/status"
  done
  mkdir -p "$LINUX_PROC/3059" "$LINUX_PROC/3060"
  printf 'VmRSS:\t 0 kB\n' > "$LINUX_PROC/3059/status"
  printf 'VmRSS:\t 123456 kB\n' > "$LINUX_PROC/3060/status"
  {
    for i in $(seq 1 55); do
      pid=$(( 3000 + i ))
      printf '%s 900 %s root /usr/sbin/filler-%s\n' "$pid" "$(( 250000 + i ))" "$pid"
    done
    printf '3059 900 0 root /usr/sbin/filler-3059\n'
    printf '3060 900 123456 root /usr/sbin/filler-3060\n'
  } > "$LINUX_PS"
}
build_fake_proc

run_linux_proc() {
  FM_HOME="$HOME_DIR" \
  FM_MEMREPORT_PROC="$LINUX_PROC" \
  FM_MEMREPORT_PS="$LINUX_PS" \
  FM_MEMREPORT_LSOF="$EMPTY_LSOF" \
  FM_MEMREPORT_LISTEN="$EMPTY_LISTEN" \
  FM_MEMREPORT_SELF_PID=3050 \
    "$REPORT" "$@" 2>&1
}

test_linux_proc_reader_reports_pss_rows() {
  local out rc
  out=$(run_linux_proc --json); rc=$?
  expect_code 0 "$rc" "the Linux /proc reader must report through the seam"
  assert_contains "$out" '"measured": "pss"' "a /proc reading must name pss as its quantity"
  printf '%s\n' "$out" | grep -F '"pid":3001' | grep -Fq '"footprint_kb":200001' \
    || fail "a smaps_rollup Pss must reach the row, got: $(printf '%s\n' "$out" | grep -F '"pid":3001')"
  printf '%s\n' "$out" | grep -F '"pid":3060' | grep -Fq '"footprint_kb":123456' \
    || fail "an unreadable mapping table must fall back to VmRSS, got: $(printf '%s\n' "$out" | grep -F '"pid":3060')"
  printf '%s\n' "$out" | grep -F '"pid":3059' | grep -Fq '"footprint_kb":0' \
    || fail "a zero-RSS process must still be counted as a 0K row"
  printf '%s\n' "$out" | grep -Fq '"physmem_used_kb": 8388608' \
    || fail "the meminfo used total must flow into --json"
  pass "the Linux reader emits PSS rows, VmRSS fallback, and the meminfo used total"
}

test_linux_proc_reader_refuses_when_meminfo_is_missing() {
  local out rc broken
  broken="$TMPROOT/brokenproc"
  rm -rf "$broken"
  cp -r "$LINUX_PROC" "$broken"
  rm -f "$broken/meminfo"
  out=$(FM_HOME="$HOME_DIR" FM_MEMREPORT_PROC="$broken" FM_MEMREPORT_PS="$LINUX_PS" \
        FM_MEMREPORT_LSOF="$EMPTY_LSOF" FM_MEMREPORT_LISTEN="$EMPTY_LISTEN" \
        FM_MEMREPORT_SELF_PID=3050 "$REPORT" 2>&1); rc=$?
  expect_code 3 "$rc" "a proc tree without meminfo must refuse, not report"
  assert_contains "$out" "REFUSING" "the refusal must say so plainly"
  assert_not_contains "$out" "TOP PROCESSES" "a refusal must print NO ranking"
  pass "a proc tree without meminfo refuses under the self-check"
}

test_linux_proc_reader_dies_when_proc_is_empty() {
  local out rc empty
  empty="$TMPROOT/emptyproc"
  mkdir -p "$empty"
  out=$(FM_HOME="$HOME_DIR" FM_MEMREPORT_PROC="$empty" FM_MEMREPORT_PS="$LINUX_PS" \
        FM_MEMREPORT_LSOF="$EMPTY_LSOF" FM_MEMREPORT_LISTEN="$EMPTY_LISTEN" \
        FM_MEMREPORT_SELF_PID=3050 "$REPORT" 2>&1); rc=$?
  expect_code 1 "$rc" "an empty process table is an uncollectable required input"
  assert_contains "$out" "no processes found" "the failure must name the missing table"
  pass "an empty /proc dies with RC=1 and a clear message"
}

test_linux_native_reading_reports_real_processes() {
  [ "$(uname -s)" = Linux ] || { pass "not a Linux host; native /proc reading skipped"; return 0; }
  local out rc
  out=$(FM_HOME="$HOME_DIR" "$REPORT" --limit 5 2>&1); rc=$?
  expect_code 0 "$rc" "a native Linux reading must report with RC=0"
  assert_not_contains "$out" "produced no output" "the macOS-only top call must not run on Linux"
  assert_contains "$out" "TOP PROCESSES" "the native reading must print the ranking"
  assert_contains "$out" "pss" "a native Linux reading must name pss"
  printf '%s\n' "$out" | awk '/^Host:/ && /0 KB total/ { bad = 1 } END { exit bad + 0 }' \
    || fail "the Host line must report the real total, not 0 KB"
  pass "a Linux host reports a real /proc reading end to end"
}

# --- interface ---------------------------------------------------------------

test_json_is_machine_readable() {
  local out
  out=$(run_report --json)
  assert_contains "$out" '"kind": "memory-report"' "json must identify itself"
  assert_contains "$out" '"footprint_kb"' "json must carry the footprint quantity"
  assert_contains "$out" '"owner_kind"' "json must carry the attribution"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' \
      || fail "--json must emit valid JSON"
  fi
  pass "--json emits valid machine-readable output"
}

test_json_refusal_is_not_a_document() {
  local out rc trunc
  trunc="$TMPROOT/trunc2.top"
  head -20 "$TOP" > "$trunc"
  out=$(FM_HOME="$HOME_DIR" FM_MEMREPORT_TOP="$trunc" FM_MEMREPORT_PS="$PS" \
        FM_MEMREPORT_LSOF="$LSOF" FM_MEMREPORT_LISTEN="$LISTEN" FM_MEMREPORT_SELF_PID=1006 "$REPORT" --json 2>&1); rc=$?
  expect_code 3 "$rc" "--json must refuse too, not emit a broken document"
  assert_not_contains "$out" '"processes"' "a refused --json must not emit a process array"
  pass "--json refuses rather than emitting a document built on a broken reading"
}

test_limit_and_all() {
  local few many
  few=$(run_report --limit 3 | awk '/^  PID / { got = 1; next } got && $1 ~ /^[0-9]+$/ { c++ } END { print c + 0 }')
  [ "$few" -eq 3 ] || fail "--limit 3 must show 3 processes, got $few"
  many=$(run_report --all | awk '/^  PID / { got = 1; next } got && $1 ~ /^[0-9]+$/ { c++ } END { print c + 0 }')
  [ "$many" -gt 200 ] || fail "--all must show every process, got $many"
  pass "--limit bounds the ranking and --all shows everything"
}

test_tree_groups_by_owner() {
  local out
  out=$(run_report --tree)
  assert_contains "$out" "BY OWNER, EVERY PROCESS" "--tree must group by owner"
  assert_contains "$out" "task: task-one" "--tree must show the task group"
  pass "--tree groups every process under its owner"
}

test_usage_and_bad_flag() {
  local out rc
  out=$("$REPORT" --help); rc=$?
  expect_code 0 "$rc" "--help must succeed"
  assert_contains "$out" "Usage:" "help must show usage"
  assert_contains "$out" "NEVER WAKES" "help must carry the never-wakes contract"
  out=$("$REPORT" --nonsense 2>&1); rc=$?
  expect_code 64 "$rc" "an unknown flag must be a usage error"
  pass "--help prints the header contract and an unknown flag is a usage error"
}

# --- safety: read-only, and never wakes firstmate ---------------------------

test_never_wakes_and_writes_nothing() {
  local before after
  # The never-wakes contract bin/fm-desk-refresh.sh documents: no wake append,
  # no send, no status write. Asserted on the source so it cannot regress.
  # Comment lines are skipped deliberately - the header DOCUMENTS the prohibition
  # by naming these helpers, and the ban is on calling them, not on saying so.
  awk '/^[[:space:]]*#/ { next } /fm_wake_append|fm-wake-lib|fm-send\.sh/ { found = 1 } END { exit found }' "$REPORT" \
    || fail "fm-memory-report.sh must never call the wake or send helpers"
  awk '/^[[:space:]]*#/ { next } /\.status/ { found = 1 } END { exit found }' "$REPORT" \
    || fail "fm-memory-report.sh must never touch a status file"
  # And it must not mutate the home it read.
  before=$(find "$HOME_DIR" -type f | LC_ALL=C sort | md5 2>/dev/null || find "$HOME_DIR" -type f | LC_ALL=C sort | md5sum)
  run_report >/dev/null
  run_report --json >/dev/null
  after=$(find "$HOME_DIR" -type f | LC_ALL=C sort | md5 2>/dev/null || find "$HOME_DIR" -type f | LC_ALL=C sort | md5sum)
  [ "$before" = "$after" ] || fail "the report must not add or remove files in the home"
  pass "never wakes firstmate and leaves the home unchanged"
}

test_does_not_touch_resource_check() {
  # Same comment exclusion: the header explains why it stays away from that
  # script, which is not the same as calling it.
  awk '/^[[:space:]]*#/ { next } /fm-resource-check/ { found = 1 } END { exit found }' "$REPORT" \
    || fail "fm-memory-report.sh must not invoke bin/fm-resource-check.sh"
  pass "does not call or change bin/fm-resource-check.sh"
}

test_refuses_truncated_memory_listing
test_refuses_truncated_process_listing
test_refuses_when_own_pid_is_absent
test_refuses_impossibly_small_total
test_refuses_when_listings_disagree
test_healthy_reading_does_not_refuse
test_agent_named_claude_is_counted
test_enumeration_is_unfiltered
test_ranks_by_footprint_not_rss
test_both_columns_labelled
test_attributes_a_live_fleet_task
test_attributes_a_secondmate
test_attributes_editor_tooling
test_language_server_rolls_up_to_its_owner
test_ancestry_never_overrides_records
test_unowned_vs_unclassified_are_distinct
test_unreadable_facts_never_become_findings
test_reclaim_classes_do_not_overlap
test_refuses_when_records_cannot_be_read
test_idle_fleet_is_not_a_broken_instrument
test_live_agents_are_never_reclaimable
test_listening_server_is_never_reclaimable
test_listening_server_gets_its_own_class_with_ports
test_listening_server_ports_are_sorted_and_deduplicated
test_a_leftover_without_a_listen_socket_still_reclaims
test_editor_is_surfaced_but_not_billed_as_free
test_warns_when_agents_match_no_record
test_attribution_warning_survives_a_pipe
test_healthy_attribution_is_quiet
test_attributes_against_real_meta_records
test_real_secondmate_home_attributes
test_worktree_invocation_finds_the_operating_home
test_linux_proc_reader_reports_pss_rows
test_linux_proc_reader_refuses_when_meminfo_is_missing
test_linux_proc_reader_dies_when_proc_is_empty
test_linux_native_reading_reports_real_processes
test_json_is_machine_readable
test_json_refusal_is_not_a_document
test_limit_and_all
test_tree_groups_by_owner
test_usage_and_bad_flag
test_never_wakes_and_writes_nothing
test_does_not_touch_resource_check
