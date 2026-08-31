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
