#!/usr/bin/env bash
# Behavior tests for bin/fm-dashboard.sh, the captain's dashboard TUI tracer
# bullet (firstmate issue #198, ADR-0032).
#
# fzf itself is interactive and out of scope here; the script factors its read,
# merge, filter, sort, and preview logic into non-interactive subcommands, and
# these tests drive those directly. Covers:
#   - the snapshot merges the PRIMARY home and every registered secondmate home,
#     tagging each row with its home
#   - the single-parser rule: reads flow ONLY through the tasks-axi command, with
#     a per-home --file, and NEVER by reading a backlog file directly (proven by a
#     stub tasks-axi whose output ignores a deliberately poisoned backlog file)
#   - a secondmate home with an empty queue contributes no rows and does not fail
#   - the tasks-axi CSV dialect (embedded commas, quotes, backslashes) decodes
#     into single clean rows
#   - state filter cycling (all -> queued -> in_flight) and its filtering
#   - sort cycling (priority -> age -> repo) and its ordering
#   - the preview subcommand reads the selected row through tasks-axi show --full
#   - --help prints the header; an unknown argument fails loudly
#   - the interactive entry exits cleanly (rc 2, no leftover process) when fzf is
#     absent
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DASH="$ROOT/bin/fm-dashboard.sh"

# A stub tasks-axi that RECORDS every invocation to $TA_LOG and serves canned
# per-file output, deliberately ignoring the on-disk backlog contents so a test
# can poison the file and prove the dashboard never parses it directly. It
# understands exactly the two read verbs the dashboard uses: `list ... --file F`
# and `show ID --full --file F`.
make_stub_tasks_axi() {  # <fakebin-dir>
  local fb=$1
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
echo "tasks-axi $*" >> "$TA_LOG"
verb=$1; shift
file=""
id=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --file) file="${args[$((i+1))]}" ;;
    --file=*) file="${args[$i]#--file=}" ;;
  esac
done
case "$verb" in
  list)
    case "$file" in
      *primary*)
        cat <<'OUT'
count: 4
tasks[4]{id,state,kind,repo,priority,title,created}:
  alpha-1,queued,ship,webapp,1,Fix login bug,2026-08-20
  beta-2,in_flight,scout,"-","-",Investigate slow query,2026-08-10
  gamma-3,queued,ship,"acme, inc","-","Title, with comma and \"quotes\" and \\slash",2026-08-25
  delta-4,done,ship,webapp,1,Completed and shipped,2026-08-01
help[1]:
  - Run tasks-axi show <id>
OUT
        ;;
      *emptysm*)
        cat <<'OUT'
count: 0
tasks: 0 tasks in this backlog
help[2]:
  - "Run tasks-axi add"
OUT
        ;;
      *sm*)
        cat <<'OUT'
count: 1
tasks[1]{id,state,kind,repo,priority,title,created}:
  sm-task-1,queued,ship,"-",2,Secondmate work item,2026-08-05
help[1]:
  - Run tasks-axi show <id>
OUT
        ;;
      *)
        echo "count: 0"
        echo "tasks: 0 tasks in this backlog"
        ;;
    esac
    ;;
  show)
    id=$1
    echo "task:"
    echo "  id: $id"
    echo "  title: FULL BODY for $id from $file"
    echo "  state: queued"
    ;;
  *)
    echo "stub tasks-axi: unhandled verb $verb" >&2
    exit 3
    ;;
esac
SH
  chmod +x "$fb/tasks-axi"
}

# Build a primary home with a poisoned backlog file plus a registry naming one
# populated and (optionally) one empty secondmate home. Echoes the primary home
# path. Sets FM_HOME/FM_DATA_OVERRIDE via the caller.
build_fleet() {  # <root> [empty-sm]
  local base=$1 want_empty=${2:-no}
  local primary="$base/primary" sm="$base/sm" esm="$base/emptysm"
  mkdir -p "$primary/data" "$sm/data" "$esm/data"
  # Poison every backlog file: if the dashboard ever parsed one directly, these
  # bytes would corrupt or crash the parse. The stub tasks-axi ignores them.
  printf 'GARBAGE NOT A BACKLOG <<<>>>\n' > "$primary/data/backlog.md"
  printf 'ALSO GARBAGE\n' > "$sm/data/backlog.md"
  printf 'MORE GARBAGE\n' > "$esm/data/backlog.md"
  {
    printf -- '- designer - design work (home: %s; scope: design; projects: alpha; added 2026-08-31)\n' "$sm"
    if [ "$want_empty" = yes ]; then
      printf -- '- triage - triage work (home: %s; scope: triage; projects: beta; added 2026-08-31)\n' "$esm"
    fi
  } > "$primary/data/secondmates.md"
  printf '%s\n' "$primary"
}

# Run a dashboard subcommand with the stub tasks-axi on the resolution seam.
run_dash() {  # <primary> <statedir> <args...>
  local primary=$1 statedir=$2; shift 2
  FM_HOME="$primary" \
  FM_DATA_OVERRIDE="$primary/data" \
  FM_DASHBOARD_TASKS_AXI="$FAKEBIN/tasks-axi" \
  TA_LOG="$TA_LOG" \
    "$DASH" "$@" "$statedir"
}

TMP_ROOT=$(fm_test_tmproot fm-dashboard)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
make_stub_tasks_axi "$FAKEBIN"

# --- snapshot merges homes and tags each row --------------------------------
test_snapshot_merges_and_tags_homes() {
  local base="$TMP_ROOT/merge" primary sd
  primary=$(build_fleet "$base")
  sd="$base/state"; mkdir -p "$sd"
  export TA_LOG="$base/talog"; : > "$TA_LOG"
  run_dash "$primary" "$sd" --snapshot
  local cache="$sd/cache" out
  out=$(cat "$cache")
  assert_contains "$out" $'primary\t' "primary rows must be tagged 'primary'"
  assert_contains "$out" $'designer\t' "secondmate rows must be tagged with the registry id 'designer'"
  assert_grep "alpha-1" "$cache" "primary task alpha-1 missing from merged snapshot"
  assert_grep "sm-task-1" "$cache" "secondmate task sm-task-1 missing from merged snapshot"
  pass "snapshot merges primary + secondmate homes and tags each row"
}

# --- single-parser rule -----------------------------------------------------
test_reads_flow_only_through_tasks_axi() {
  local base="$TMP_ROOT/single" primary sd
  primary=$(build_fleet "$base")
  sd="$base/state"; mkdir -p "$sd"
  export TA_LOG="$base/talog"; : > "$TA_LOG"
  run_dash "$primary" "$sd" --snapshot
  # Every read went through the tasks-axi command, one list per home, each with a
  # --file target - and NOTHING read the poisoned backlog files.
  assert_grep "tasks-axi list --all" "$TA_LOG" "snapshot must read via 'tasks-axi list'"
  assert_grep "primary/data/backlog.md" "$TA_LOG" "list must target the primary home's backlog via --file"
  assert_grep "sm/data/backlog.md" "$TA_LOG" "list must target the secondmate home's backlog via --file"
  # The poisoned files never became data: their garbage marker is absent from the
  # snapshot cache, proving no direct file parse happened.
  assert_no_grep "GARBAGE" "$sd/cache" "poisoned backlog bytes leaked into the snapshot: a direct file parse happened"
  # And the real task rows (served only by the stub) are present.
  assert_grep "Fix login bug" "$sd/cache" "stub-served task title missing; the read path is not tasks-axi"
  pass "reads flow only through tasks-axi --file, never a direct backlog parse"
}

# --- empty secondmate queue -------------------------------------------------
test_empty_secondmate_queue_is_graceful() {
  local base="$TMP_ROOT/empty" primary sd
  primary=$(build_fleet "$base" yes)
  sd="$base/state"; mkdir -p "$sd"
  export TA_LOG="$base/talog"; : > "$TA_LOG"
  run_dash "$primary" "$sd" --snapshot
  # The empty secondmate ('triage'/emptysm) contributes zero rows but must still
  # be READ (proving enumeration reached it) and must not break the merge.
  assert_grep "emptysm/data/backlog.md" "$TA_LOG" "the empty secondmate home was never read"
  assert_no_grep "triage" "$sd/cache" "an empty secondmate must contribute no rows"
  assert_grep "sm-task-1" "$sd/cache" "the populated secondmate row is missing"
  pass "an empty secondmate queue contributes nothing and does not fail the merge"
}

# --- CSV dialect decodes cleanly --------------------------------------------
test_csv_dialect_decodes_to_single_rows() {
  local base="$TMP_ROOT/csv" primary sd
  primary=$(build_fleet "$base")
  sd="$base/state"; mkdir -p "$sd"
  export TA_LOG="$base/talog"; : > "$TA_LOG"
  run_dash "$primary" "$sd" --snapshot
  # gamma-3's title holds a comma, escaped quotes, and a backslash; its repo holds
  # a comma. The decoded cache row must keep them intact on ONE line with the repo
  # and title in their own columns.
  local line
  line=$(grep gamma-3 "$sd/cache")
  [ "$(printf '%s\n' "$line" | wc -l)" -eq 1 ] || fail "gamma-3 decoded to more than one row"
  assert_contains "$line" "acme, inc" "repo field with an embedded comma did not decode"
  assert_contains "$line" 'Title, with comma and "quotes" and \slash' "title with comma/quote/backslash did not decode"
  # Field integrity: home, id, state, repo, title land in the right TSV columns.
  local repo title
  repo=$(printf '%s\n' "$line" | cut -f6)
  title=$(printf '%s\n' "$line" | cut -f9)
  [ "$repo" = "acme, inc" ] || fail "repo column wrong after decode: '$repo'"
  [ "$title" = 'Title, with comma and "quotes" and \slash' ] || fail "title column wrong after decode: '$title'"
  pass "tasks-axi CSV dialect (commas, quotes, backslashes) decodes into clean single rows"
}

# --- terminal-state tasks are excluded from the backlog ---------------------
test_terminal_state_tasks_never_appear() {
  local base="$TMP_ROOT/terminal" primary sd rows
  primary=$(build_fleet "$base")
  sd="$base/state"; mkdir -p "$sd"
  export TA_LOG="$base/talog"; : > "$TA_LOG"
  printf priority > "$sd/sort"; printf all > "$sd/filter"
  run_dash "$primary" "$sd" --snapshot
  # delta-4 is a done-state task returned by `list --all`; the 'all' filter means
  # all BACKLOG (queued+in_flight), so it must never surface as a row.
  rows=$(run_dash "$primary" "$sd" --rows)
  assert_not_contains "$rows" "delta-4" "filter=all must exclude done-state delta-4"
  assert_contains "$rows" "alpha-1" "filter=all must still include queued alpha-1"
  assert_contains "$rows" "beta-2" "filter=all must still include in-flight beta-2"
  # It is likewise absent under the queued and in_flight filters.
  run_dash "$primary" "$sd" --cycle-filter
  rows=$(run_dash "$primary" "$sd" --rows)
  assert_not_contains "$rows" "delta-4" "filter=queued must exclude done-state delta-4"
  pass "terminal-state tasks (done/cancelled) never appear in the backlog"
}

# --- state filter cycle -----------------------------------------------------
test_state_filter_cycles_and_filters() {
  local base="$TMP_ROOT/filter" primary sd
  primary=$(build_fleet "$base")
  sd="$base/state"; mkdir -p "$sd"
  export TA_LOG="$base/talog"; : > "$TA_LOG"
  printf priority > "$sd/sort"; printf all > "$sd/filter"
  run_dash "$primary" "$sd" --snapshot
  # all -> every task shows.
  local rows
  rows=$(run_dash "$primary" "$sd" --rows)
  assert_contains "$rows" "alpha-1" "filter=all must include queued alpha-1"
  assert_contains "$rows" "beta-2" "filter=all must include in-flight beta-2"
  # cycle -> queued: only queued rows.
  run_dash "$primary" "$sd" --cycle-filter
  [ "$(cat "$sd/filter")" = queued ] || fail "filter did not cycle to queued"
  rows=$(run_dash "$primary" "$sd" --rows)
  assert_contains "$rows" "alpha-1" "filter=queued must keep queued alpha-1"
  assert_not_contains "$rows" "beta-2" "filter=queued must drop in-flight beta-2"
  # cycle -> in_flight: only in-flight rows.
  run_dash "$primary" "$sd" --cycle-filter
  [ "$(cat "$sd/filter")" = in_flight ] || fail "filter did not cycle to in_flight"
  rows=$(run_dash "$primary" "$sd" --rows)
  assert_contains "$rows" "beta-2" "filter=in_flight must keep in-flight beta-2"
  assert_not_contains "$rows" "alpha-1" "filter=in_flight must drop queued alpha-1"
  # cycle -> back to all.
  run_dash "$primary" "$sd" --cycle-filter
  [ "$(cat "$sd/filter")" = all ] || fail "filter did not cycle back to all"
  pass "state filter cycles all->queued->in_flight->all and filters rows"
}

# --- sort cycle -------------------------------------------------------------
test_sort_cycles_and_orders() {
  local base="$TMP_ROOT/sort" primary sd
  primary=$(build_fleet "$base")
  sd="$base/state"; mkdir -p "$sd"
  export TA_LOG="$base/talog"; : > "$TA_LOG"
  printf priority > "$sd/sort"; printf all > "$sd/filter"
  run_dash "$primary" "$sd" --snapshot
  # priority: alpha-1 (p1) before sm-task-1 (p2) before the unset-priority rows.
  local rows first
  rows=$(run_dash "$primary" "$sd" --rows)
  first=$(printf '%s\n' "$rows" | head -1)
  assert_contains "$first" "alpha-1" "priority sort must put p1 alpha-1 first"
  # cycle -> age: oldest created first. beta-2 is 2026-08-05? no: sm-task-1 is
  # 2026-08-05, the oldest, so it leads.
  run_dash "$primary" "$sd" --cycle-sort
  [ "$(cat "$sd/sort")" = age ] || fail "sort did not cycle to age"
  rows=$(run_dash "$primary" "$sd" --rows)
  first=$(printf '%s\n' "$rows" | head -1)
  assert_contains "$first" "sm-task-1" "age sort must put the oldest (2026-08-05 sm-task-1) first"
  # cycle -> repo: 'acme, inc' sorts before 'webapp'; unset repo ('-') sorts last.
  run_dash "$primary" "$sd" --cycle-sort
  [ "$(cat "$sd/sort")" = repo ] || fail "sort did not cycle to repo"
  rows=$(run_dash "$primary" "$sd" --rows)
  first=$(printf '%s\n' "$rows" | head -1)
  assert_contains "$first" "gamma-3" "repo sort must put 'acme, inc' (gamma-3) first"
  # cycle -> back to priority.
  run_dash "$primary" "$sd" --cycle-sort
  [ "$(cat "$sd/sort")" = priority ] || fail "sort did not cycle back to priority"
  pass "sort cycles priority->age->repo->priority and orders rows"
}

# --- preview ----------------------------------------------------------------
test_preview_reads_selected_row_full_body() {
  local base="$TMP_ROOT/preview" primary sd out
  primary=$(build_fleet "$base")
  sd="$base/state"; mkdir -p "$sd"
  export TA_LOG="$base/talog"; : > "$TA_LOG"
  out=$(FM_HOME="$primary" FM_DATA_OVERRIDE="$primary/data" \
    FM_DASHBOARD_TASKS_AXI="$FAKEBIN/tasks-axi" TA_LOG="$TA_LOG" \
    "$DASH" --preview "$primary/data/backlog.md" alpha-1)
  assert_contains "$out" "FULL BODY for alpha-1" "preview must render the selected row's full body"
  assert_grep "tasks-axi show alpha-1 --full" "$TA_LOG" "preview must read via 'tasks-axi show <id> --full'"
  # An empty selection (fzf empty-list case) prints nothing and does not fail.
  out=$(FM_DASHBOARD_TASKS_AXI="$FAKEBIN/tasks-axi" TA_LOG="$TA_LOG" "$DASH" --preview "" "")
  [ -z "$out" ] || fail "empty preview selection must print nothing"
  pass "preview reads the selected row's full body via tasks-axi show --full"
}

# --- help and error handling ------------------------------------------------
test_help_and_unknown_arg() {
  local out rc
  out=$("$DASH" --help)
  assert_contains "$out" "the captain's dashboard TUI" "--help must print the header"
  assert_contains "$out" "single-parser rule" "--help must document the read discipline"
  assert_contains "$out" "decisions" "--help must document the decisions panel"
  assert_contains "$out" "ctrl-p" "--help must document the panel-cycle keybind"
  rc=0
  "$DASH" --bogus >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an unknown argument must fail with exit 2"
  pass "--help prints the header; an unknown argument fails loudly"
}

# --- clean exit when fzf is absent ------------------------------------------
test_interactive_exits_clean_without_fzf() {
  local base="$TMP_ROOT/nofzf" primary rc procs_before procs_after
  primary=$(build_fleet "$base")
  export TA_LOG="$base/talog"; : > "$TA_LOG"
  # Shadow fzf out of PATH so the interactive entry hits the missing-fzf branch.
  local nofzfbin="$base/nofzfbin"; mkdir -p "$nofzfbin"
  procs_before=$(pgrep -f fm-dashboard.sh | wc -l || true)
  rc=0
  PATH="$FAKEBIN:$nofzfbin:/usr/bin:/bin" \
  FM_HOME="$primary" FM_DATA_OVERRIDE="$primary/data" \
  FM_DASHBOARD_TASKS_AXI="$FAKEBIN/tasks-axi" TA_LOG="$TA_LOG" \
    "$DASH" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "interactive entry must exit 2 when fzf is unavailable"
  procs_after=$(pgrep -f fm-dashboard.sh | wc -l || true)
  [ "$procs_after" -le "$procs_before" ] || fail "a dashboard process leaked after exit"
  pass "interactive entry exits clean (rc 2, no leftover process) when fzf is absent"
}

# ============================================================================
# Decisions panel (firstmate issue #199). The panel merges three sources, each
# read ONLY through its owner: captain-kind holds via tasks-axi, decision-desk
# requests via fm-decision-desk-ledger.sh, unanswered questions via the
# transcript feed producer. These tests stub all three owners (mirroring how the
# backlog tests stub tasks-axi) and drive the non-interactive subcommands.
# ============================================================================

# A stub tasks-axi for the decisions panel: it answers `list --state held` with
# per-home captain-kind held tasks (schema id,state,kind,repo,priority,title,
# hold_kind,hold_reason) and `show --full` with a recognizable body, ignoring the
# poisoned on-disk backlog so a direct parse would be caught.
make_stub_tasks_axi_decisions() {  # <fakebin-dir>
  local fb=$1
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
echo "tasks-axi $*" >> "$TA_LOG"
verb=$1; shift
file=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --file) file="${args[$((i+1))]}" ;;
    --file=*) file="${args[$i]#--file=}" ;;
  esac
done
case "$verb" in
  list)
    # Held (captain-decision) rows per home. gamma-hold's reason carries a comma,
    # quotes, and a backslash to prove the CSV dialect decodes.
    case "$file" in
      *primary*)
        cat <<'OUT'
count: 2
tasks[2]{id,state,kind,repo,priority,title,hold_kind,hold_reason}:
  p-hold,queued,captain,webapp,1,Auth model,captain,"OAuth or session, cookies?"
  p-ops,queued,ops,"-","-",Not a captain hold,ops,routine ops hold
help[1]:
  - Run tasks-axi show <id>
OUT
        ;;
      *emptysm*)
        echo "count: 0"
        echo "tasks: 0 tasks in this backlog"
        ;;
      *sm*)
        cat <<'OUT'
count: 1
tasks[1]{id,state,kind,repo,priority,title,hold_kind,hold_reason}:
  sm-hold,queued,captain,"-","-",Schema shape,captain,flat or nested?
help[1]:
  - Run tasks-axi show <id>
OUT
        ;;
      *)
        echo "count: 0"
        echo "tasks: 0 tasks in this backlog"
        ;;
    esac
    ;;
  show)
    id=$1
    echo "task:"
    echo "  id: $id"
    echo "  hold_kind: captain"
    echo "  body: FULL HOLD BODY for $id"
    ;;
  *)
    echo "stub tasks-axi: unhandled verb $verb" >&2
    exit 3
    ;;
esac
SH
  chmod +x "$fb/tasks-axi"
}

# A stub decision-desk ledger tool: emits pending desk requests as the owner's
# TSV (subject<TAB>question<TAB>when<TAB>status) for the resolving home, keyed off
# FM_DATA_OVERRIDE so per-home reads are distinguishable and recorded.
make_stub_ledger() {  # <fakebin-dir>
  local fb=$1
  cat > "$fb/ledger" <<'SH'
#!/usr/bin/env bash
echo "ledger $* data=$FM_DATA_OVERRIDE" >> "$LEDGER_LOG"
[ "$1" = list ] || exit 0
case "$FM_DATA_OVERRIDE" in
  *primary*)
    printf 'p-migration\tdrop legacy table?\t2026-08-31T00:00:00Z\trouted\n'
    ;;
  *sm*)
    printf 'sm-desk\tnew index?\t2026-08-30T00:00:00Z\trouted\n'
    ;;
esac
SH
  chmod +x "$fb/ledger"
}

# A stub transcript producer: emits the home's jsonl for `list`, keyed off the
# FM_DESK_TRANSCRIPT feed path so per-home state reads are distinguishable. The
# primary feed carries one unanswered question, one answered question, and a
# later answer record for a previously-unanswered question (append-only "answer"
# model), so the panel must collapse to the latest record per question.
make_stub_transcript() {  # <fakebin-dir>
  local fb=$1
  cat > "$fb/transcript" <<'SH'
#!/usr/bin/env bash
echo "transcript $* feed=$FM_DESK_TRANSCRIPT" >> "$TR_LOG"
[ "$1" = list ] || exit 0
case "$FM_DESK_TRANSCRIPT" in
  *primary*)
    printf '%s\n' '{"ts":1,"kind":"question","q":"which region?","a":""}'
    printf '%s\n' '{"ts":2,"kind":"turn","who":"captain","text":"hi","unread":false}'
    printf '%s\n' '{"ts":3,"kind":"question","q":"already answered?","a":"yes"}'
    printf '%s\n' '{"ts":4,"kind":"question","q":"pick a name?","a":""}'
    printf '%s\n' '{"ts":5,"kind":"question","q":"pick a name?","a":"acme"}'
    ;;
  *sm*)
    printf '%s\n' '{"ts":1,"kind":"question","q":"deploy where?","a":""}'
    ;;
esac
SH
  chmod +x "$fb/transcript"
}

# Build a fleet for the decisions panel: a primary home plus one populated and
# (optionally) one empty secondmate, all with poisoned on-disk sources. Echoes
# the primary home path.
build_decisions_fleet() {  # <root> [empty-sm]
  local base=$1 want_empty=${2:-no}
  local primary="$base/primary" sm="$base/sm" esm="$base/emptysm"
  mkdir -p "$primary/data" "$primary/state" "$sm/data" "$sm/state" "$esm/data" "$esm/state"
  # Poison every owned source so a direct parse would corrupt/crash it.
  printf 'GARBAGE BACKLOG\n' > "$primary/data/backlog.md"
  printf 'GARBAGE BACKLOG\n' > "$sm/data/backlog.md"
  printf 'GARBAGE BACKLOG\n' > "$esm/data/backlog.md"
  printf 'GARBAGE LEDGER <<>>\n' > "$primary/data/decision-desk-ledger.md"
  printf 'GARBAGE JSONL {not json\n' > "$primary/state/desk-transcript.jsonl"
  printf 'GARBAGE JSONL {not json\n' > "$sm/state/desk-transcript.jsonl"
  {
    printf -- '- designer - design (home: %s; scope: design; projects: alpha; added 2026-08-31)\n' "$sm"
    if [ "$want_empty" = yes ]; then
      printf -- '- triage - triage (home: %s; scope: triage; projects: beta; added 2026-08-31)\n' "$esm"
    fi
  } > "$primary/data/secondmates.md"
  printf '%s\n' "$primary"
}

# Run a dashboard subcommand with all three stub owners on the resolution seam.
run_dash_decisions() {  # <primary> <statedir> <args...>
  local primary=$1 statedir=$2; shift 2
  FM_HOME="$primary" \
  FM_DATA_OVERRIDE="$primary/data" \
  FM_STATE_OVERRIDE="$primary/state" \
  FM_DASHBOARD_TASKS_AXI="$FAKEBIN/tasks-axi" \
  FM_DASHBOARD_LEDGER="$FAKEBIN/ledger" \
  FM_DASHBOARD_TRANSCRIPT="$FAKEBIN/transcript" \
  TA_LOG="$TA_LOG" LEDGER_LOG="$LEDGER_LOG" TR_LOG="$TR_LOG" \
    "$DASH" "$@" "$statedir"
}

# --- three sources merge, each tagged home + source ------------------------
test_decisions_merge_and_tag_sources() {
  local base="$TMP_ROOT/dmerge" primary sd
  primary=$(build_decisions_fleet "$base")
  sd="$base/state"; mkdir -p "$sd"
  export TA_LOG="$base/talog" LEDGER_LOG="$base/ledgerlog" TR_LOG="$base/trlog"
  : > "$TA_LOG"; : > "$LEDGER_LOG"; : > "$TR_LOG"
  run_dash_decisions "$primary" "$sd" --decisions-snapshot
  local cache="$sd/dcache" out
  out=$(cat "$cache")
  # A hold, a desk request, and a question from the PRIMARY home, each tagged.
  assert_contains "$out" $'primary\thold\t' "a primary captain hold must be tagged primary/hold"
  assert_contains "$out" $'primary\tdesk\t' "a primary desk request must be tagged primary/desk"
  assert_contains "$out" $'primary\tquestion\t' "a primary question must be tagged primary/question"
  # And the secondmate's captain hold appears, tagged with its registry id.
  assert_contains "$out" $'designer\thold\t' "a secondmate captain hold must appear, tagged designer/hold"
  assert_contains "$out" $'designer\tdesk\t' "a secondmate desk request must appear, tagged designer/desk"
  assert_contains "$out" $'designer\tquestion\t' "a secondmate question must appear, tagged designer/question"
  pass "all three sources merge fleet-wide, each row tagged with home and source"
}

# --- single-parser rule: reads flow ONLY through the owners -----------------
test_decisions_reads_flow_only_through_owners() {
  local base="$TMP_ROOT/downer" primary sd
  primary=$(build_decisions_fleet "$base")
  sd="$base/state"; mkdir -p "$sd"
  export TA_LOG="$base/talog" LEDGER_LOG="$base/ledgerlog" TR_LOG="$base/trlog"
  : > "$TA_LOG"; : > "$LEDGER_LOG"; : > "$TR_LOG"
  run_dash_decisions "$primary" "$sd" --decisions-snapshot
  # Each source was read through its owner, per home.
  assert_grep "list --all --state held" "$TA_LOG" "holds must be read via tasks-axi list --state held"
  assert_grep "ledger list" "$LEDGER_LOG" "desk requests must be read via the ledger owner's list"
  assert_grep "transcript list" "$TR_LOG" "questions must be read via the transcript owner's list"
  # None of the poisoned bytes leaked into the cache: no direct parse happened.
  assert_no_grep "GARBAGE" "$sd/dcache" "poisoned source bytes leaked: a direct parse happened"
  pass "decisions reads flow only through the three owners, never a direct parse"
}

# --- non-captain holds are excluded ----------------------------------------
test_decisions_only_captain_holds() {
  local base="$TMP_ROOT/dcap" primary sd
  primary=$(build_decisions_fleet "$base")
  sd="$base/state"; mkdir -p "$sd"
  export TA_LOG="$base/talog" LEDGER_LOG="$base/ledgerlog" TR_LOG="$base/trlog"
  : > "$TA_LOG"; : > "$LEDGER_LOG"; : > "$TR_LOG"
  run_dash_decisions "$primary" "$sd" --decisions-snapshot
  assert_grep "p-hold" "$sd/dcache" "a captain-kind hold must appear"
  assert_no_grep "p-ops" "$sd/dcache" "a non-captain (ops) hold must be excluded"
  pass "only captain-kind holds count as captain decisions"
}

# --- answered question drops (append-only latest-record-per-question) -------
test_decisions_answered_question_excluded() {
  local base="$TMP_ROOT/dans" primary sd out
  primary=$(build_decisions_fleet "$base")
  sd="$base/state"; mkdir -p "$sd"
  export TA_LOG="$base/talog" LEDGER_LOG="$base/ledgerlog" TR_LOG="$base/trlog"
  : > "$TA_LOG"; : > "$LEDGER_LOG"; : > "$TR_LOG"
  run_dash_decisions "$primary" "$sd" --decisions-snapshot
  out=$(cat "$sd/dcache")
  assert_contains "$out" "which region?" "an unanswered question must appear"
  assert_not_contains "$out" "already answered?" "an answered question must be excluded"
  # 'pick a name?' was unanswered then answered by a later record: the latest
  # record wins, so it drops.
  assert_not_contains "$out" "pick a name?" "a later answer record must drop the question"
  pass "answered questions (incl. later answer records) are excluded"
}

# --- CSV dialect in a hold reason decodes -----------------------------------
test_decisions_hold_reason_csv_decodes() {
  local base="$TMP_ROOT/dcsv" primary sd line
  primary=$(build_decisions_fleet "$base")
  sd="$base/state"; mkdir -p "$sd"
  export TA_LOG="$base/talog" LEDGER_LOG="$base/ledgerlog" TR_LOG="$base/trlog"
  : > "$TA_LOG"; : > "$LEDGER_LOG"; : > "$TR_LOG"
  run_dash_decisions "$primary" "$sd" --decisions-snapshot
  line=$(grep p-hold "$sd/dcache")
  [ "$(printf '%s\n' "$line" | wc -l)" -eq 1 ] || fail "p-hold decoded to more than one row"
  assert_contains "$line" "OAuth or session, cookies?" "a hold reason with an embedded comma must decode intact"
  pass "a captain hold reason in the tasks-axi CSV dialect decodes into one clean row"
}

# --- source filter cycles and filters --------------------------------------
test_decisions_source_filter_cycles() {
  local base="$TMP_ROOT/dfilt" primary sd rows
  primary=$(build_decisions_fleet "$base")
  sd="$base/state"; mkdir -p "$sd"
  export TA_LOG="$base/talog" LEDGER_LOG="$base/ledgerlog" TR_LOG="$base/trlog"
  : > "$TA_LOG"; : > "$LEDGER_LOG"; : > "$TR_LOG"
  printf decisions > "$sd/panel"; printf all > "$sd/dfilter"
  run_dash_decisions "$primary" "$sd" --decisions-snapshot
  # all -> every source shows.
  rows=$(run_dash_decisions "$primary" "$sd" --rows)
  assert_contains "$rows" "hold" "filter=all must include holds"
  assert_contains "$rows" "desk" "filter=all must include desk requests"
  assert_contains "$rows" "question" "filter=all must include questions"
  # cycle -> hold only.
  run_dash_decisions "$primary" "$sd" --cycle-filter
  [ "$(cat "$sd/dfilter")" = hold ] || fail "decisions filter did not cycle to hold"
  rows=$(run_dash_decisions "$primary" "$sd" --rows)
  assert_contains "$rows" "p-hold" "filter=hold must keep holds"
  assert_not_contains "$rows" "p-migration" "filter=hold must drop desk requests"
  assert_not_contains "$rows" "which region" "filter=hold must drop questions"
  # cycle -> desk, -> question, -> back to all.
  run_dash_decisions "$primary" "$sd" --cycle-filter
  [ "$(cat "$sd/dfilter")" = desk ] || fail "decisions filter did not cycle to desk"
  run_dash_decisions "$primary" "$sd" --cycle-filter
  [ "$(cat "$sd/dfilter")" = question ] || fail "decisions filter did not cycle to question"
  run_dash_decisions "$primary" "$sd" --cycle-filter
  [ "$(cat "$sd/dfilter")" = all ] || fail "decisions filter did not cycle back to all"
  pass "decisions source filter cycles all->hold->desk->question->all and filters"
}

# --- preview renders the full body per source type -------------------------
test_decisions_preview_per_source() {
  local base="$TMP_ROOT/dprev" primary sd rowid out
  primary=$(build_decisions_fleet "$base")
  sd="$base/state"; mkdir -p "$sd"
  export TA_LOG="$base/talog" LEDGER_LOG="$base/ledgerlog" TR_LOG="$base/trlog"
  : > "$TA_LOG"; : > "$LEDGER_LOG"; : > "$TR_LOG"
  run_dash_decisions "$primary" "$sd" --decisions-snapshot
  local cache="$sd/dcache"
  # hold body.
  rowid=$(awk -F'\t' '$1=="primary" && $2=="hold" {print $3; exit}' "$cache")
  out=$("$DASH" --preview decision "$cache" "$rowid")
  assert_contains "$out" "FULL HOLD BODY for p-hold" "a hold preview must render its tasks-axi show body"
  # desk body.
  rowid=$(awk -F'\t' '$1=="primary" && $2=="desk" {print $3; exit}' "$cache")
  out=$("$DASH" --preview decision "$cache" "$rowid")
  assert_contains "$out" "drop legacy table?" "a desk preview must render the request question"
  # question body.
  rowid=$(awk -F'\t' '$1=="primary" && $2=="question" {print $3; exit}' "$cache")
  out=$("$DASH" --preview decision "$cache" "$rowid")
  assert_contains "$out" "which region?" "a question preview must render the question text"
  # An unknown rowid prints nothing and does not fail.
  out=$("$DASH" --preview decision "$cache" "nope:x:9")
  [ -z "$out" ] || fail "an unknown decision rowid must print nothing"
  pass "decision preview renders the full body for each source type"
}

# --- released hold / resolved request / answered question drop on refresh ---
test_decisions_refresh_drops_cleared_items() {
  local base="$TMP_ROOT/drefresh" primary sd out
  primary=$(build_decisions_fleet "$base")
  sd="$base/state"; mkdir -p "$sd"
  export TA_LOG="$base/talog" LEDGER_LOG="$base/ledgerlog" TR_LOG="$base/trlog"
  : > "$TA_LOG"; : > "$LEDGER_LOG"; : > "$TR_LOG"
  printf decisions > "$sd/panel"; printf all > "$sd/dfilter"
  run_dash_decisions "$primary" "$sd" --decisions-snapshot
  out=$(cat "$sd/dcache")
  assert_contains "$out" "p-hold" "the hold must be present before it clears"
  assert_contains "$out" "p-migration" "the desk request must be present before it clears"
  # Swap the stub owners for ones that report EVERYTHING cleared, then refresh
  # via the ctrl-r subcommand. The cleared items must vanish.
  cat > "$FAKEBIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ "$1" = list ] && { echo "count: 0"; echo "tasks: 0 tasks in this backlog"; }
[ "$1" = show ] && echo "task:"
exit 0
SH
  chmod +x "$FAKEBIN/tasks-axi"
  cat > "$FAKEBIN/ledger" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$FAKEBIN/ledger"
  cat > "$FAKEBIN/transcript" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$FAKEBIN/transcript"
  run_dash_decisions "$primary" "$sd" --snapshot-reload >/dev/null
  out=$(cat "$sd/dcache")
  assert_not_contains "$out" "p-hold" "a released hold must drop after refresh"
  assert_not_contains "$out" "p-migration" "a resolved request must drop after refresh"
  assert_not_contains "$out" "which region" "an answered question must drop after refresh"
  [ "$(printf '%s' "$out" | grep -c . || true)" -eq 0 ] || fail "cleared fleet must leave no decision rows"
  # Restore the panel stubs for any later test in the run.
  make_stub_tasks_axi_decisions "$FAKEBIN"
  make_stub_ledger "$FAKEBIN"
  make_stub_transcript "$FAKEBIN"
  pass "a released hold, resolved request, and answered question all drop after refresh"
}

# --- panel cycle preserves the session and flips rows + header --------------
test_panel_cycle_flips_rows_and_header() {
  local base="$TMP_ROOT/dpanel" primary sd hdr rows
  primary=$(build_decisions_fleet "$base")
  sd="$base/state"; mkdir -p "$sd"
  export TA_LOG="$base/talog" LEDGER_LOG="$base/ledgerlog" TR_LOG="$base/trlog"
  : > "$TA_LOG"; : > "$LEDGER_LOG"; : > "$TR_LOG"
  printf backlog > "$sd/panel"
  printf priority > "$sd/sort"; printf all > "$sd/filter"; printf all > "$sd/dfilter"
  run_dash_decisions "$primary" "$sd" --snapshot
  # Backlog panel: header names sort, rows are backlog rows (the held p-hold task
  # is queued so it appears in the backlog list too).
  hdr=$(run_dash_decisions "$primary" "$sd" --header)
  assert_contains "$hdr" "Fleet backlog" "the backlog header must name the backlog panel"
  assert_contains "$hdr" "ctrl-s sort" "the backlog header must name the sort keybind"
  # Cycle to decisions: state flips, and the decisions cache is built lazily.
  run_dash_decisions "$primary" "$sd" --cycle-panel
  [ "$(cat "$sd/panel")" = decisions ] || fail "ctrl-p did not flip the panel to decisions"
  [ -f "$sd/dcache" ] || fail "cycling to decisions must build its cache lazily"
  hdr=$(run_dash_decisions "$primary" "$sd" --header)
  assert_contains "$hdr" "Captain decisions" "the decisions header must name the decisions panel"
  assert_contains "$hdr" "ctrl-t source" "the decisions header must name the source keybind"
  rows=$(run_dash_decisions "$primary" "$sd" --rows)
  assert_contains "$rows" "decision" "the decisions rows must carry the decision marker column"
  assert_contains "$rows" "which region" "the decisions rows must show a question decision"
  # Cycle back to backlog: rows return to backlog form; the shared state (the
  # separate caches) is intact, proving the session is not lost/rebuilt.
  run_dash_decisions "$primary" "$sd" --cycle-panel
  [ "$(cat "$sd/panel")" = backlog ] || fail "ctrl-p did not flip back to backlog"
  rows=$(run_dash_decisions "$primary" "$sd" --rows)
  assert_contains "$rows" "p-hold" "returning to backlog must show backlog rows again"
  pass "panel cycle flips rows and header without losing the session state"
}

# --- empty sources render cleanly ------------------------------------------
test_decisions_empty_sources_are_graceful() {
  local base="$TMP_ROOT/dempty" primary sd rows rc
  # A fleet whose only registered secondmate is the empty one, and whose owners
  # all report nothing for it.
  primary="$base/primary"
  mkdir -p "$primary/data" "$primary/state"
  printf 'GARBAGE\n' > "$primary/data/backlog.md"
  : > "$primary/data/secondmates.md"
  export TA_LOG="$base/talog" LEDGER_LOG="$base/ledgerlog" TR_LOG="$base/trlog"
  : > "$TA_LOG"; : > "$LEDGER_LOG"; : > "$TR_LOG"
  # Owners that report nothing at all.
  cat > "$FAKEBIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
echo "tasks-axi $*" >> "$TA_LOG"
[ "$1" = list ] && { echo "count: 0"; echo "tasks: 0 tasks in this backlog"; }
exit 0
SH
  chmod +x "$FAKEBIN/tasks-axi"
  cat > "$FAKEBIN/ledger" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$FAKEBIN/ledger"
  cat > "$FAKEBIN/transcript" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$FAKEBIN/transcript"
  sd="$base/state"; mkdir -p "$sd"
  printf decisions > "$sd/panel"; printf all > "$sd/dfilter"
  rc=0
  run_dash_decisions "$primary" "$sd" --decisions-snapshot || rc=$?
  [ "$rc" -eq 0 ] || fail "an empty decisions snapshot must not fail, got rc $rc"
  [ "$(wc -l < "$sd/dcache")" -eq 0 ] || fail "an empty fleet must produce zero decision rows"
  rows=$(run_dash_decisions "$primary" "$sd" --rows)
  [ -z "$rows" ] || fail "an empty decisions panel must render no rows, got: $rows"
  # Restore the panel stubs for any later test in the run.
  make_stub_tasks_axi_decisions "$FAKEBIN"
  make_stub_ledger "$FAKEBIN"
  make_stub_transcript "$FAKEBIN"
  pass "empty decision sources render cleanly with no rows and no failure"
}

test_snapshot_merges_and_tags_homes
test_reads_flow_only_through_tasks_axi
test_empty_secondmate_queue_is_graceful
test_csv_dialect_decodes_to_single_rows
test_terminal_state_tasks_never_appear
test_state_filter_cycles_and_filters
test_sort_cycles_and_orders
test_preview_reads_selected_row_full_body
test_help_and_unknown_arg
test_interactive_exits_clean_without_fzf

# Decisions panel (#199): install its three stub owners, then run its suite.
make_stub_ledger "$FAKEBIN"
make_stub_transcript "$FAKEBIN"
make_stub_tasks_axi_decisions "$FAKEBIN"
test_decisions_merge_and_tag_sources
test_decisions_reads_flow_only_through_owners
test_decisions_only_captain_holds
test_decisions_answered_question_excluded
test_decisions_hold_reason_csv_decodes
test_decisions_source_filter_cycles
test_decisions_preview_per_source
test_decisions_refresh_drops_cleared_items
test_panel_cycle_flips_rows_and_header
test_decisions_empty_sources_are_graceful