#!/usr/bin/env bash
# Behavior tests for the read-only fleet snapshot and its human renderer.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
VIEW="$ROOT/bin/fm-fleet-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
case "${1:-}" in
  display-message)
    case "$*" in
      *pane_current_command*)
        case "$target" in
          *dead-secondmate*) printf 'zsh\n' ;;
          *) printf 'codex\n' ;;
        esac
        ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    case "$target" in
      *ship-task*|*active-secondmate*) printf 'work in progress\nesc to interrupt\n' ;;
      *) printf 'all quiet\n> \n' ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

write_fixture() {  # <home>
  local home=$1
  mkdir -p "$home/projects/alpha-worktree" "$home/projects/scout-worktree" "$home/secondmate-home"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] scout-task - Scout Task data/scout-task/report.md (repo: alpha) (kind: scout) (since 2026-07-07)
- [ ] ship-task - Ship Task https://github.com/kunchenguid/firstmate/pull/9 (repo: alpha) (kind: ship) (priority: 2) (since 2026-07-07)
  Preserve this detail for bearings.

## Queued
- [ ] queued-task - Queued Task blocked-by: ship-task (repo: alpha) (kind: ship) (since 2026-07-08)
handoff note without canonical syntax

## Done
- [x] done-task - Done Task https://github.com/kunchenguid/firstmate/pull/7 (repo: alpha) (kind: ship) (merged 2026-07-06)
EOF
  mkdir -p "$home/data/scout-task"
  printf '# Scout\n' > "$home/data/scout-task/report.md"
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/alpha-worktree" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=https://github.com/kunchenguid/firstmate/pull/9"
  printf 'needs-decision: choose an API shape\n' > "$home/state/ship-task.status"
  fm_write_meta "$home/state/scout-task.meta" \
    "window=firstmate:fm-scout-task" \
    "worktree=$home/projects/scout-worktree" \
    "project=alpha" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout" \
    "yolo=off"
  printf 'done: report ready\n' > "$home/state/scout-task.status"
  fm_write_meta "$home/state/secondmate-task.meta" \
    "window=firstmate:fm-secondmate-task" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha, beta, gamma, "
  printf 'working: watching delegated scope\n' > "$home/state/secondmate-task.status"
  fm_write_meta "$home/state/cmux-task.meta" \
    "backend=cmux" \
    "window=workspace:surface" \
    "worktree=$home/projects/missing-cmux" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
}

# Compact default projection: identity + state + title capped at 120 with an
# inline full-source pointer + decision/PR metadata + aggregate counts, bounded
# by the ceiling. Presence (ABSENT vs empty vs content) survives; fat fields
# restore via --fields; the empty home still renders explicit absence markers.
test_compact_default_projection() {
  local home out chars
  home=$(make_home compact-default)
  write_fixture "$home"
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  chars=$(printf '%s' "$out" | LC_ALL=C wc -c | tr -d ' ')
  [ "$chars" -le 20000 ] || fail "compact default must stay under the default ceiling, got $chars chars"
  printf '%s' "$out" | jq -e '
    .schema == "fm-fleet-snapshot.v1"
      and .mode == "compact"
      and .projection.mode == "compact"
      and .projection.ceiling == 20000
      and (.projection.truncated | length) == 0
      and (.backlog.records | length) == 5
      and .backlog.records[0].title == "Scout Task"
      and (.backlog.records[0] | has("raw") | not)
      and (.backlog.records[0] | has("body_lines") | not)
      and (.backlog.records[0] | has("body_excerpt") | not)
      and (.tasks | any(.[]; .id == "ship-task" and ((.actions | has("watch")) | not)))
      and (.tasks | any(.[]; .id == "ship-task" and ((.paths.meta | has("path")) | not)))
      and (.tasks | any(.[]; .id == "ship-task" and ((.paths.worktree.path // "") != "")))
      and (.tasks | any(.[]; .id == "secondmate-task" and ((.paths.home.path // "") != "")))
      and .summary.backlog_total == 5
      and .summary.backlog_in_flight == 2
      and .summary.backlog_queued == 2
      and .summary.backlog_done == 1
      and .summary.tasks_total == 4
      and .summary.tasks_secondmates == 1
      and .summary.landed == 1
      and .summary.scout_reports_total == 1
  ' >/dev/null || fail "compact default projection shape wrong: $out"
  # Presence survives the projection: an empty home keeps explicit ABSENT
  # markers and a true empty inventory in compact mode.
  home=$(make_home compact-empty)
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .mode == "compact"
      and .backlog.present == false
      and .backlog.records == []
      and .main_inventory.valid == true
      and .main_inventory.reason == null
      and (.tasks | length) == 0
      and .summary.backlog_total == 0
      and .summary.tasks_total == 0
  ' >/dev/null || fail "compact empty home lost ABSENT markers: $out"
  pass "compact default stays under the ceiling with identity, state, titles, counts, and presence"
}

test_compact_fields_body_restores_full_backlog() {
  local home out
  home=$(make_home compact-body)
  write_fixture "$home"
  out=$(FM_HOME="$home" "$SNAPSHOT" --json --fields body)
  printf '%s' "$out" | jq -e '
    .mode == "compact"
      and (.backlog.records | length) == 5
      and (.backlog.records[] | select(.id == "ship-task")
        | .raw == "- [ ] ship-task - Ship Task https://github.com/kunchenguid/firstmate/pull/9 (repo: alpha) (kind: ship) (priority: 2) (since 2026-07-07)"
          and .body_lines == ["Preserve this detail for bearings."]
          and .body_excerpt == "Preserve this detail for bearings."
          and .title == "Ship Task")
      and (.backlog.records[] | select(.id == "queued-task")
        | .body_lines == [] and .unresolved_blocker_ids == ["ship-task"])
  ' >/dev/null || fail "--fields body must restore raw, bodies, excerpts, and full titles: $out"
  pass "--fields body restores the full backlog bodies"
}

test_compact_title_truncation_carries_pointer() {
  local home out
  home=$(make_home compact-title)
  mkdir -p "$home/projects/t-wt"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] long-title - $(printf 'word%.0s ' {1..40}) (repo: alpha) (kind: ship)
## Queued
free-form queued note with no canonical syntax and a long tail $(printf 'word%.0s ' {1..40})
## Done
EOF
  fm_write_meta "$home/state/t.meta" \
    "window=firstmate:fm-t" \
    "worktree=$home/projects/t-wt" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    (.backlog.records[] | select(.id == "long-title"))
    | (.title | length) <= 175
      and (.title | startswith("word"))
      and (.title | contains("… (full: tasks-axi show long-title)"))
  ' >/dev/null || fail "structured title truncation lost its inline pointer: $out"
  printf '%s' "$out" | jq -e '
    (.backlog.records[] | select(.structured == false))
    | (.title | contains("… (full: "))
  ' >/dev/null || fail "unstructured row pointer must name the full-source path: $out"
  pass "compact title truncation carries the full-source pointer inline"
}

test_summary_mode_counts() {
  local home out
  home=$(make_home summary-mode)
  write_fixture "$home"
  out=$(FM_HOME="$home" "$SNAPSHOT" --summary)
  printf '%s' "$out" | jq -e '
    .schema == "fm-fleet-snapshot.v1"
      and .mode == "summary"
      and (.summary | has("backlog_total") and has("backlog_in_flight")
           and has("backlog_queued") and has("backlog_done")
           and has("captain_actionable") and has("tasks_total")
           and has("tasks_working") and has("tasks_secondmates")
           and has("decisions_open") and has("landed")
           and has("scout_reports_total") and has("secondmates_total"))
      and .summary.backlog_total == 5
      and .summary.tasks_total == 4
      and .summary.landed == 1
      and .summary.scout_reports_total == 1
  ' >/dev/null || fail "--summary counts wrong: $out"
  pass "--summary emits the aggregate counts object"
}

test_compact_ceiling_trims_with_disclosure() {
  local home out chars i body
  home=$(make_home compact-ceiling)
  mkdir -p "$home/projects/t-wt"
  body=$(printf 'x%.0s' {1..300})
  {
    printf '## In flight\n'
    for i in $(seq 1 200); do
      printf -- '- [ ] big-%03d - Big Task %03d %s (repo: alpha) (kind: ship) (since 2026-07-07)\n' "$i" "$i" "$body"
    done
  } > "$home/data/backlog.md"
  fm_write_meta "$home/state/big-001.meta" \
    "window=firstmate:fm-big-001" \
    "worktree=$home/projects/t-wt" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  out=$(FM_HOME="$home" FM_SNAPSHOT_COMPACT_CEILING=6000 "$SNAPSHOT" --json)
  chars=$(printf '%s' "$out" | LC_ALL=C wc -c | tr -d ' ')
  [ "$chars" -le 6000 ] || fail "compact output must respect the ceiling, got $chars chars"
  printf '%s' "$out" | jq -e '
    .projection.ceiling == 6000
      and .projection.chars <= 6000
      and .summary.backlog_total == 200
      and (.backlog.records | length) < 200
      and .backlog.records_truncated == true
      and (.backlog.records_total == 200)
      and (.projection.truncated | any(.[];
        .surface == "backlog records" and .total == 200 and .shown < 200 and (.reveal | startswith("fm-fleet-snapshot.sh --json --fields body"))))
      and (.projection.full_hint == "fm-fleet-snapshot.sh --json --full")
  ' >/dev/null || fail "ceiling trim lacked disclosure: $out"
  pass "the hard ceiling trims rows with full aggregate and reveal disclosure"
}

test_compact_unknown_field_fails_closed() {
  local home
  home=$(make_home compact-badfield)
  FM_HOME="$home" "$SNAPSHOT" --json --fields bogus >/dev/null 2>&1 \
    && fail "an unknown --fields name must fail closed"
  pass "unknown --fields names are rejected instead of silently ignored"
}

test_empty_fleet_json() {
  local home out view
  home=$(make_home empty)
  out=$(FM_HOME="$home" "$SNAPSHOT" --json --full)
  printf '%s' "$out" | jq -e '
    .schema == "fm-fleet-snapshot.v1"
      and .backlog.present == false
      and (.tasks|length == 0)
      and .main_inventory.valid == true
      and .main_inventory.reason == null
      and (.main_inventory.orphan_in_flight | length) == 0
      and .main_inventory.unstructured_current_count == 0
  ' >/dev/null \
    || fail "empty snapshot schema or absence markers wrong: $out"
  view=$(FM_HOME="$home" "$VIEW")
  assert_contains "$view" "No live task metadata found." "empty fleet view should say no live metadata"
  pass "empty fleet snapshot and view use explicit absence markers"
}

test_fixture_snapshot_json() {
  local home fakebin out ids
  home=$(make_home fixture)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json --full)
  printf '%s' "$out" | jq -e . >/dev/null || fail "snapshot must be valid JSON"
  ids=$(printf '%s' "$out" | jq -r '.tasks | map(.id) | join(",")')
  [ "$ids" = "cmux-task,scout-task,secondmate-task,ship-task" ] \
    || fail "task ordering must be stable by id, got $ids"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "ship-task")
    | .current_state.state == "working"
      and .current_state.source == "pane"
      and .pr.url == "https://github.com/kunchenguid/firstmate/pull/9"
      and .backlog.body_excerpt == "Preserve this detail for bearings."
      and .hints.pending_decision == false
      and .paths.status_log.kind == "event_history"
  ' >/dev/null || fail "ship task state, PR, body, and stale event hints wrong"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "scout-task")
    | .paths.report.present == true
      and .hints.scout_report_present == true
  ' >/dev/null || fail "scout report pointer missing"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "secondmate-task")
    | .secondmate_projects == ["alpha","beta","gamma"]
      and .endpoint.agent_alive == "alive"
      and (.actions.watch | contains("do not routinely fm-peek"))
  ' >/dev/null || fail "secondmate return-channel guidance missing"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "cmux-task")
    | .backend == "cmux"
      and .paths.worktree.present == false
      and .current_state.state == "unknown"
  ' >/dev/null || fail "cmux missing-file row missing"
  printf '%s' "$out" | jq -e '
    [.backlog.records[] | select(.state == "queued")] | length == 2
  ' >/dev/null || fail "queued canonical and unstructured backlog records missing"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-task")
    | .state == "done" and .pr_url == "https://github.com/kunchenguid/firstmate/pull/7"
  ' >/dev/null || fail "done backlog PR row missing"
  pass "fixture snapshot covers task rows, backlog rows, pointers, and stable ordering"
}

# R1 owner contract: main_inventory discloses orphan in-flight and unstructured
# current rows without inventing task rows.
test_main_inventory_orphan_and_unstructured_disclosure() {
  local home fakebin out
  home=$(make_home main-inventory)
  mkdir -p "$home/projects/visible"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
free-form current note
- [ ] orphan-ship - Structured without meta (repo: alpha) (kind: ship) (since 2026-07-11)
- [ ] visible-ship - Structured with meta (repo: alpha) (kind: ship) (since 2026-07-11)

## Queued
another free-form queued note
- [ ] queued-ship - Structured queued (repo: alpha) (kind: ship)

## Done
EOF
  fm_write_meta "$home/state/visible-ship.meta" \
    "window=firstmate:fm-visible-ship" \
    "worktree=$home/projects/visible" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'working: visible\n' > "$home/state/visible-ship.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json --full)
  printf '%s' "$out" | jq -e '
    .main_inventory.valid == false
      and .main_inventory.reason == "unstructured current backlog row"
      and .main_inventory.unstructured_current_count == 2
      and (.main_inventory.orphan_in_flight == ["orphan-ship"])
      and ([.tasks[].id] == ["visible-ship"])
  ' >/dev/null || fail "main_inventory did not disclose orphan/unstructured: $out"
  # Counterfactual: add meta for the orphan and strip free-form current lines.
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] orphan-ship - Structured without meta (repo: alpha) (kind: ship) (since 2026-07-11)
- [ ] visible-ship - Structured with meta (repo: alpha) (kind: ship) (since 2026-07-11)

## Queued
- [ ] queued-ship - Structured queued (repo: alpha) (kind: ship)

## Done
EOF
  fm_write_meta "$home/state/orphan-ship.meta" \
    "window=firstmate:fm-orphan-ship" \
    "worktree=$home/projects/visible" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'working: orphan now live\n' > "$home/state/orphan-ship.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json --full)
  printf '%s' "$out" | jq -e '
    .main_inventory.valid == true
      and .main_inventory.reason == null
      and .main_inventory.unstructured_current_count == 0
      and (.main_inventory.orphan_in_flight | length) == 0
      and (([.tasks[].id] | sort) == ["orphan-ship", "visible-ship"])
  ' >/dev/null || fail "main_inventory stayed invalid after meta + structured cleanup: $out"
  pass "main_inventory discloses orphan/unstructured and clears when inventory is consistent"
}

test_normalized_roles_and_plural_blocker_readiness() {
  local home fakebin out
  home=$(make_home normalized-records)
  mkdir -p "$home/projects/worker"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)
- [ ] worker - Real worker (repo: alpha) (kind: ship)
- [ ] orphan - Ordinary missing worker (repo: alpha) (kind: ship)

## Queued
- [ ] review - Security review (repo: alpha) (kind: ship)
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
EOF
  fm_write_meta "$home/state/worker.meta" \
    "window=firstmate:fm-worker" "worktree=$home/projects/worker" "project=alpha" \
    "harness=codex" "kind=ship" "mode=ship"
  printf 'working: preparing canary\n' > "$home/state/worker.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json --full)
  printf '%s' "$out" | jq -e '
    .main_inventory.orphan_in_flight == ["orphan"]
      and (.backlog.records[] | select(.id == "program")
        | .current_role == "program" and .requires_child_metadata == false)
      and (.backlog.records[] | select(.id == "observation")
        | .current_role == "held" and .requires_child_metadata == false)
      and (.backlog.records[] | select(.id == "orphan")
        | .current_role == "worker" and .requires_child_metadata == true)
      and (.backlog.records[] | select(.id == "captain-run")
        | .blocked_by == "review"
          and .blocked_by_ids == ["worker", "review"]
          and .unresolved_blocker_ids == ["worker", "review"]
          and .captain_actionable == false)
  ' >/dev/null || fail "normalized role or plural blocker fields were wrong: $out"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)

## Queued
- [ ] review - Security review (repo: alpha) (kind: ship)
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] worker - Real worker (repo: alpha) (kind: ship) (done 2026-07-22)
EOF
  rm "$home/state/worker.meta" "$home/state/worker.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json --full)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by == "review"
      and .blocked_by_ids == ["worker", "review"]
      and .unresolved_blocker_ids == ["review"]
      and .captain_actionable == false
  ' >/dev/null || fail "one completed blocker did not leave exactly one unresolved id: $out"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)

## Queued
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] worker - Real worker (repo: alpha) (kind: ship) (done 2026-07-22)
- [x] review - Security review (repo: alpha) (kind: ship) (done 2026-07-22)
EOF
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json --full)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by == "review"
      and .blocked_by_ids == ["worker", "review"]
      and .unresolved_blocker_ids == []
      and .captain_actionable == true
  ' >/dev/null || fail "completed blockers did not make the captain hold actionable: $out"

  sed 's/blocked-by: review/blocked-by: missing/' "$home/data/backlog.md" > "$home/data/backlog.next"
  mv "$home/data/backlog.next" "$home/data/backlog.md"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json --full)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by_ids == ["worker", "missing"]
      and .unresolved_blocker_ids == ["missing"]
      and .captain_actionable == false
  ' >/dev/null || fail "a missing blocker was incorrectly treated as resolved: $out"
  pass "backlog normalization preserves strict roles and resolves every blocker compatibly"
}

test_event_hints_follow_reconciled_current_state() {
  local home fakebin out
  home=$(make_home event-hints)
  mkdir -p \
    "$home/projects/active-decision" \
    "$home/projects/active-blocked" \
    "$home/projects/stale-decision" \
    "$home/projects/stale-blocked"
  fm_write_meta "$home/state/active-decision.meta" \
    "window=firstmate:fm-active-decision" \
    "worktree=$home/projects/active-decision" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'needs-decision: choose an API shape\n' > "$home/state/active-decision.status"
  fm_write_meta "$home/state/active-blocked.meta" \
    "window=firstmate:fm-active-blocked" \
    "worktree=$home/projects/active-blocked" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'blocked: waiting on access\n' > "$home/state/active-blocked.status"
  fm_write_meta "$home/state/stale-decision.meta" \
    "window=firstmate:fm-stale-decision-ship-task" \
    "worktree=$home/projects/stale-decision" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'needs-decision: already answered\n' > "$home/state/stale-decision.status"
  fm_write_meta "$home/state/stale-blocked.meta" \
    "window=firstmate:fm-stale-blocked-ship-task" \
    "worktree=$home/projects/stale-blocked" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'blocked: old failure\n' > "$home/state/stale-blocked.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json --full)
  printf '%s' "$out" | jq -e '
    def task($id): (.tasks[] | select(.id == $id));
    task("active-decision").current_state.state == "parked"
      and task("active-decision").hints.pending_decision == true
      and task("active-blocked").current_state.state == "blocked"
      and task("active-blocked").hints.blocked_event == true
      and task("stale-decision").current_state.state == "working"
      and task("stale-decision").hints.pending_decision == false
      and task("stale-blocked").current_state.state == "working"
      and task("stale-blocked").hints.blocked_event == false
  ' >/dev/null || fail "event hints must follow reconciled current state"
  pass "snapshot event hints follow reconciled current state"
}

test_scout_reports_include_teardown_reports() {
  local home out
  home=$(make_home teardown-reports)
  mkdir -p "$home/data/reported-scout" "$home/data/untracked-scout"
  cat > "$home/data/backlog.md" <<EOF
## Done
- [x] reported-scout - Reported Scout data/reported-scout/report.md (repo: alpha, reported 2026-07-07) (kind: scout)
EOF
  printf '# Reported Scout\n' > "$home/data/reported-scout/report.md"
  printf '# Untracked Scout\n' > "$home/data/untracked-scout/report.md"
  out=$(FM_HOME="$home" "$SNAPSHOT" --json --full)
  printf '%s' "$out" | jq -e --arg home "$home" '
    (.tasks | length) == 0
      and .scout_reports == [
        {id:"reported-scout",path:($home + "/data/reported-scout/report.md"),kind:"scout"},
        {id:"untracked-scout",path:($home + "/data/untracked-scout/report.md"),kind:"scout"}
      ]
  ' >/dev/null || fail "durable scout reports should remain visible after meta teardown"
  pass "snapshot includes durable scout reports after teardown"
}

test_backlog_tasks_axi_forms_and_overrides() {
  local home data projects fakebin out view
  home=$(make_home overrides)
  data=$TMP_ROOT/override-data
  projects=$TMP_ROOT/override-projects
  mkdir -p "$data/bold-task" "$projects/bold-worktree"
  cat > "$data/backlog.md" <<EOF
## In flight
- **bold-task** - Bold Task data/bold-task/report.md (repo: alpha, since 2026-07-07) (kind: scout)
  Bold body survives.

## Queued
- [ ] queued-comma - Queued Comma Task (repo: beta, since 2026-07-08) (kind: ship)
- [ ] parenthetical-title - Refresh sidebar (mobile) (repo: beta) (kind: ship)
- [ ] blocked-reason - Blocked Reason (repo: beta) (kind: ship) blocked-by: queued-comma - waits on queued-comma
- [ ] sample-decision-route - Choose sample route (repo: sample) (kind: captain) (since 2026-07-14) (hold: captain route choice pending) (hold-kind: captain)

## Done
- [x] done-comma - Done Comma Task https://github.com/kunchenguid/firstmate/pull/42 (repo: gamma, merged 2026-07-09) (kind: ship)
- [x] done-bracket-pr - Done Bracket PR - <https://github.com/kunchenguid/firstmate/pull/43> (repo: gamma, merged 2026-07-12) (kind: ship)
- [x] reported-comma - Reported Scout data/reported-comma/report.md (repo: gamma, reported 2026-07-10) (kind: scout)
- [x] done-note - Done Note local main (repo: delta, done 2026-07-11) (kind: ship)
EOF
  printf '# Bold Scout\n' > "$data/bold-task/report.md"
  fm_write_meta "$home/state/bold-task.meta" \
    "window=firstmate:fm-bold-task" \
    "worktree=$projects/bold-worktree" \
    "project=alpha" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'done: report ready\n' > "$home/state/bold-task.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_PROJECTS_OVERRIDE="$projects" "$SNAPSHOT" --json --full)
  printf '%s' "$out" | jq -e --arg data "$data" --arg projects "$projects" '
    .roots.data == $data
      and .roots.projects == $projects
      and .backlog.path == ($data + "/backlog.md")
  ' >/dev/null || fail "snapshot did not respect data/projects overrides"
  printf '%s' "$out" | jq -e --arg data "$data" '
    .backlog.records[] | select(.id == "bold-task")
    | .structured == true
      and .state == "in_flight"
      and .checked == false
      and .repo == "alpha"
      and .since == "2026-07-07"
      and .kind == "scout"
      and .title == "Bold Task"
      and .body_excerpt == "Bold body survives."
      and .report_path == "data/bold-task/report.md"
  ' >/dev/null || fail "bold in-flight backlog row did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "queued-comma")
    | .repo == "beta" and .since == "2026-07-08"
  ' >/dev/null || fail "queued comma metadata did not split"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "parenthetical-title")
    | .title == "Refresh sidebar (mobile)" and .repo == "beta"
  ' >/dev/null || fail "title parenthetical was stripped with metadata"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "blocked-reason")
    | .title == "Blocked Reason"
      and .repo == "beta"
      and .blocked_by == "queued-comma"
      and .blocked_reason == "waits on queued-comma"
  ' >/dev/null || fail "blocked suffix did not parse into title and reason"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "sample-decision-route")
    | .title == "Choose sample route"
      and .repo == "sample"
      and .kind == "captain"
      and .hold_reason == "captain route choice pending"
      and .hold_kind == "captain"
  ' >/dev/null || fail "tasks-axi captain-hold metadata did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-comma")
    | .repo == "gamma"
      and .merged == "2026-07-09"
      and .completion == {verb:"merged",date:"2026-07-09"}
  ' >/dev/null || fail "done comma metadata did not split"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-bracket-pr")
    | .repo == "gamma"
      and .title == "Done Bracket PR"
      and .pr_url == "https://github.com/kunchenguid/firstmate/pull/43"
      and .links == ["https://github.com/kunchenguid/firstmate/pull/43"]
      and .completion == {verb:"merged",date:"2026-07-12"}
  ' >/dev/null || fail "bracketed PR artifact did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "reported-comma")
    | .repo == "gamma"
      and .title == "Reported Scout"
      and .reported == "2026-07-10"
      and .completion == {verb:"reported",date:"2026-07-10"}
  ' >/dev/null || fail "reported closure metadata did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-note")
    | .repo == "delta"
      and .title == "Done Note"
      and .local_note == "local main"
      and .done == "2026-07-11"
      and .completion == {verb:"done",date:"2026-07-11"}
  ' >/dev/null || fail "done closure metadata did not parse"
  printf '%s' "$out" | jq -e --arg data "$data" '
    .tasks[] | select(.id == "bold-task")
    | .backlog.id == "bold-task"
      and .paths.report.path == ($data + "/bold-task/report.md")
      and .paths.report.present == true
  ' >/dev/null || fail "bold task did not join to override-backed backlog and report"
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_PROJECTS_OVERRIDE="$projects" "$VIEW")
  assert_contains "$view" "| bold-task | done / status-log · event(0m): done: report ready | scout | alpha | tmux | present | $data/bold-task/report.md" \
    "view should render bold in-flight row with paired current-state and event"
  assert_contains "$view" "| blocked-reason | Blocked Reason | beta | ship | queued-comma - waits on queued-comma | - |" \
    "view should render blocked reason without title metadata"
  assert_contains "$view" "| done-bracket-pr | Done Bracket PR | gamma | ship | - | https://github.com/kunchenguid/firstmate/pull/43 |" \
    "view should render bracketed PR artifact outside the title"
  assert_contains "$view" "| done-note | Done Note | delta | ship | - | local main |" \
    "view should render local-only done artifact outside the title"
  pass "snapshot parses tasks-axi rows and respects operational overrides"
}

test_view_renders_snapshot() {
  local home fakebin view
  home=$(make_home view)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" "| ship-task | working / pane · event(0m): needs-decision: choose an API shape | ship | alpha | tmux | present | https://github.com/kunchenguid/firstmate/pull/9" \
    "view should render ship row with paired current-state and event"
  assert_contains "$view" "| queued-task | Queued Task | alpha | ship | ship-task | -" \
    "view should render queued backlog row"
  assert_contains "$view" "| done-task | Done Task | alpha | ship | - | https://github.com/kunchenguid/firstmate/pull/7 |" \
    "view should render done backlog row"
  assert_contains "$view" "bin/fm-send.sh fm-secondmate-task" \
    "view should show secondmate send guidance"
  assert_contains "$view" "| secondmate-task | working / status-log · event(0m): working: watching delegated scope | secondmate | $home/secondmate-home | tmux | present / alive |" \
    "view should show secondmate endpoint agent liveness"
  assert_not_contains "$view" "fm-peek.sh fm-secondmate-task" \
    "view must not tell firstmate to routinely peek secondmates"
  pass "fleet view renders the snapshot without secondmate peek guidance"
}

test_view_renders_dead_secondmate_agent_status() {
  local home fakebin view
  home=$(make_home dead-secondmate)
  fm_write_meta "$home/state/dead-secondmate.meta" \
    "window=firstmate:fm-dead-secondmate" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha, beta"
  printf 'working: watching delegated scope\n' > "$home/state/dead-secondmate.status"
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" "| dead-secondmate | unknown / none · event(0m): working: watching delegated scope | secondmate | $home/secondmate-home | tmux | present / dead |" \
    "view should distinguish a present secondmate endpoint from a dead agent"
  assert_contains "$view" "| dead-secondmate | unknown / none · event(0m): working: watching delegated scope | secondmate | $home/secondmate-home | tmux | present / dead | - | $home/secondmate-home (absent) |" \
    "view should show a recorded missing secondmate home path"
  pass "fleet view renders secondmate agent liveness"
}

# Gap 3: a running-run fakebin plus a real worktree on the crew branch, so the
# authoritative run-step reports working while the status EVENT still says
# needs-decision. The renderers must (a) always pair the event with the current
# state and a freshness age, (b) mark the event OLD when it is older than the
# threshold and the current source is fresher (run-step), and (c) tag SUPERSEDED
# because the run-step provably moved past the needs-decision event.
make_running_run_fakebin() {  # <dir> <branch> <head>
  local dir=$1 branch=$2 head=$3 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/no-mistakes" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  axi)
    shift
    case "\${1:-}" in
      status)
        cat <<'RUN'
run:
  id: "01RUN"
  branch: $branch
  status: running
  head: "$head"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
RUN
        ;;
    esac
    ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

test_gap3_pairs_event_with_current_state_old_and_superseded() {
  local home fakebin wt head out now old_epoch view
  home=$(make_home gap3)
  wt="$home/projects/gap3-worktree"
  mkdir -p "$wt"
  git -C "$wt" init -q
  git -C "$wt" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q --allow-empty -m init
  git -C "$wt" checkout -q -b fm/gap3-ship-task
  head=$(git -C "$wt" rev-parse HEAD)
  fm_write_meta "$home/state/gap3-ship-task.meta" \
    "window=firstmate:fm-gap3-ship-task" \
    "worktree=$wt" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  # A needs-decision EVENT the run-step has moved past, aged well beyond the
  # default 600s OLD threshold via an old mtime, with snapshot NOW pinned.
  printf 'needs-decision: choose an API shape\n' > "$home/state/gap3-ship-task.status"
  now=1800000000
  old_epoch=$(( now - 2820 ))  # 47m ago
  touch -d "@$old_epoch" "$home/state/gap3-ship-task.status" 2>/dev/null \
    || touch -t "$(date -r "$old_epoch" +%Y%m%d%H%M.%S 2>/dev/null)" "$home/state/gap3-ship-task.status"
  fakebin=$(make_running_run_fakebin "$home" fm/gap3-ship-task "$head")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW_EPOCH="$now" \
    FM_SNAPSHOT_NOW="2027-01-15T08:00:00Z" "$SNAPSHOT" --json --full)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "gap3-ship-task")
    | .current_state.state == "working"
      and .current_state.source == "run-step"
      and .current_state.superseded == true
      and .paths.status_log.last_event.raw == "needs-decision: choose an API shape"
      and .paths.status_log.last_event.age_label == "47m"
      and .paths.status_log.last_event.age_seconds == 2820
      and .paths.status_log.last_event.old == true
  ' >/dev/null || fail "snapshot did not pair event with current state, age, OLD, and SUPERSEDED: $out"
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW_EPOCH="$now" \
    FM_SNAPSHOT_NOW="2027-01-15T08:00:00Z" "$VIEW")
  assert_contains "$view" "| gap3-ship-task | working / run-step [SUPERSEDED] · event(47m) (OLD): needs-decision: choose an API shape |" \
    "view must render the paired shape with SUPERSEDED and OLD, never the event alone"
  pass "Gap 3: renderers pair event with current state, freshness age, OLD, and SUPERSEDED"
}

# The complementary safety property: a FRESH event whose current source is the
# status log itself is never marked OLD (nothing fresher to trust) and never
# SUPERSEDED (the run-step did not move past it), but is still PAIRED.
test_gap3_fresh_agreeing_event_is_paired_without_markers() {
  local home fakebin out view
  home=$(make_home gap3-fresh)
  mkdir -p "$home/projects/fresh-wt"
  fm_write_meta "$home/state/fresh-ship.meta" \
    "window=firstmate:fm-fresh-ship" \
    "worktree=$home/projects/fresh-wt" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'blocked: waiting on access\n' > "$home/state/fresh-ship.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json --full)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "fresh-ship")
    | .current_state.superseded == false
      and .paths.status_log.last_event.old == false
      and .paths.status_log.last_event.raw == "blocked: waiting on access"
  ' >/dev/null || fail "a fresh status-log-sourced event must not be OLD or SUPERSEDED: $out"
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" "· event(0m): blocked: waiting on access |" \
    "view must still pair a fresh event with the current state"
  assert_not_contains "$view" "fresh-ship | blocked / status-log (OLD)" \
    "view must not mark a fresh event OLD"
  pass "Gap 3: a fresh agreeing event is paired without OLD or SUPERSEDED"
}

# Gap 1: the snapshot task rows expose the shared account/quota telemetry
# (state/<id>.telemetry) as a telemetry:{} sub-object, mirrors of the meta:/
# status_log: rows. Keys are all optional: a task with no telemetry file gets
# the empty object, a present key is a real value, and an absent field NEVER
# renders as zero.
test_telemetry_subobject_on_task_rows() {
  local home fakebin out
  home=$(make_home telemetry)
  mkdir -p "$home/projects/t1-wt" "$home/projects/t2-wt"
  fm_write_meta "$home/state/t1.meta" \
    "window=firstmate:fm-t1" \
    "worktree=$home/projects/t1-wt" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  fm_write_meta "$home/state/t2.meta" \
    "window=firstmate:fm-t2" \
    "worktree=$home/projects/t2-wt" \
    "project=alpha" \
    "harness=jcode" \
    "kind=ship" \
    "mode=ship"
  # t1 carries a full account/quota telemetry line set; t2 has NONE (a task
  # that predates the producer or was never reached by it).
  cat > "$home/state/t1.telemetry" <<'EOF'
account=claude-2
account_source=spawn
quota_pct=8
quota_window=seven_day
quota_reset_ts=1784841600
last_429_ts=1784800000
count_429=2
observed_at=1784841300
EOF
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json --full)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "t1")
    | .telemetry.account == "claude-2"
      and .telemetry.account_source == "spawn"
      and .telemetry.quota_pct == "8"
      and .telemetry.quota_window == "seven_day"
      and .telemetry.quota_reset_ts == "1784841600"
      and .telemetry.count_429 == "2"
      and (.telemetry | keys | length) == 8
  ' >/dev/null || fail "t1 telemetry sub-object missing or wrong: $out"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "t2")
    | .telemetry == {}
  ' >/dev/null || fail "a task with no telemetry file must render the EMPTY object, got $out"
  # Absent-key safety: t1 has no composer_stuck key, so the object must not
  # fabricate it (absent = unknown, never zero).
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "t1")
    | (.telemetry | has("composer_stuck")) | not
  ' >/dev/null || fail "an absent telemetry key must stay absent, never rendered as zero: $out"
  pass "telemetry sub-object appears on task rows and is absent-key-safe"
}

# A still-open decision must survive a LATER, UNRELATED terminal event on the same
# append-only stream. This is the fmdev masking bug: last-event-wins read the trailing
# `done` and reported pending_decision=false while a needs-decision was still open. The
# durable keyed fold (fm-classify-lib.sh) keeps it open until an explicit resolution.
test_open_decision_survives_later_unrelated_event() {
  local home fakebin out
  home=$(make_home masking)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/masked-decision.meta" \
    "window=firstmate:fm-masked-decision" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  # needs-decision opened, then two LATER unrelated events (no resolution).
  printf 'needs-decision [key=race]: fix the reconcile-before-subscribe race\n' > "$home/state/masked-decision.status"
  printf 'working: implementing an unrelated subsystem\n' >> "$home/state/masked-decision.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/masked-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json --full)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "masked-decision")
    | .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "race"
      and .hints.open_decisions[0].verb == "needs-decision"
  ' >/dev/null || fail "later unrelated done must not mask an open needs-decision: $out"
  pass "durable fold keeps an open decision past a later unrelated event"
}

test_secondmate_open_decision_survives_live_endpoint() {
  local home fakebin out
  home=$(make_home active-secondmate)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/active-secondmate.meta" \
    "window=firstmate:fm-active-secondmate" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  printf 'needs-decision [key=race]: choose ordering\n' > "$home/state/active-secondmate.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json --full)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "active-secondmate")
    | .endpoint.agent_alive == "alive"
      and .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
  ' >/dev/null || fail "a live secondmate endpoint must not clear an unrelated keyed decision: $out"
  pass "a live secondmate endpoint preserves unrelated open decisions"
}

# An open decision clears ONLY on an explicit resolution referencing its key, never
# on an unrelated terminal line.
test_open_decision_transfers_to_captain_hold() {
  local home fakebin out
  home=$(make_home captain-held-transfer)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/transferred-decision.meta" \
    "window=firstmate:fm-transferred-decision" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=sample"
  printf 'needs-decision [key=route]: choose a sample route\n' > "$home/state/transferred-decision.status"
  printf 'captain-held [key=route]: tracked by transferred-decision-route\n' >> "$home/state/transferred-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json --full)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "transferred-decision")
    | .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
  ' >/dev/null || fail "captain-held transfer must close only the duplicate status copy: $out"
  pass "durable captain-held transfer closes the duplicate live status decision"
}

test_open_decision_clears_on_keyed_resolution() {
  local home fakebin out
  home=$(make_home resolution)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/resolved-decision.meta" \
    "window=firstmate:fm-resolved-decision" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  printf 'needs-decision [key=race]: fix the reconcile-before-subscribe race\n' > "$home/state/resolved-decision.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/resolved-decision.status"
  printf 'resolved [key=race]: captain chose subscribe-then-reconcile\n' >> "$home/state/resolved-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json --full)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "resolved-decision")
    | .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
  ' >/dev/null || fail "keyed resolution must clear the open decision: $out"
  pass "durable fold clears a decision only on a keyed resolution"
}

# A COMPLETED scout report must never be read as a pending decision. A scout that
# raised a needs-decision and then finished (done) - its report delivered, its
# decision either answered or captured in the report for the captain - must surface
# only as a report POINTER, not a reopened pending decision, even when the report
# body and the stale status line contain decision-like prose. This is the Lavish-103
# defect: a terminal single-owner task's stale, never-keyed-resolved needs-decision
# must not linger as pending. Decisions come purely from the keyed fold reconciled
# against the crew lifecycle; report prose never opens or reopens a decision.
test_completed_scout_report_is_pointer_not_pending() {
  local home fakebin out
  home=$(make_home completed-scout)
  mkdir -p "$home/projects/scout-wt" "$home/data/lavish-103"
  fm_write_meta "$home/state/lavish-103.meta" \
    "window=firstmate:fm-lavish-103" \
    "worktree=$home/projects/scout-wt" \
    "project=firstmate" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  # Stale needs-decision, then the scout finished (done). No keyed resolution.
  printf 'needs-decision: adopt approach A or B for Lavish issue 103\n' > "$home/state/lavish-103.status"
  printf 'done: report ready at data/lavish-103/report.md\n' >> "$home/state/lavish-103.status"
  # Completed report whose PROSE reads like the decision.
  printf '# Lavish 103\nThe open question is whether to adopt approach A or B.\nThis needs a captain decision. Recommendation: A.\n' > "$home/data/lavish-103/report.md"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json --full)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "lavish-103")
    | .current_state.state == "done"
      and .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
      and .hints.scout_report_present == true
  ' >/dev/null || fail "a completed scout report must be a pointer, not a pending decision: $out"
  pass "a completed scout's stale decision surfaces as a report pointer, not pending"
}

# The complementary safety property: a scout still PARKED at a decision (its last
# event is the needs-decision, it has not finished) DOES stay pending. The terminal
# clear must not over-fire on a live, undecided scout.
test_parked_scout_decision_stays_pending() {
  local home fakebin out
  home=$(make_home parked-scout)
  mkdir -p "$home/projects/scout-wt2"
  fm_write_meta "$home/state/parked-scout.meta" \
    "window=firstmate:fm-parked-scout" \
    "worktree=$home/projects/scout-wt2" \
    "project=firstmate" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'needs-decision [key=q1]: adopt approach A or B\n' > "$home/state/parked-scout.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json --full)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "parked-scout")
    | .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "q1"
  ' >/dev/null || fail "a scout still parked at a decision must stay pending: $out"
  pass "a scout still parked at a decision stays pending (terminal clear does not over-fire)"
}

# Regression: a single argv string on Linux is capped at MAX_ARG_STRLEN (128KB)
# regardless of total ARG_MAX. fm-fleet-snapshot.sh once passed the whole
# backlog/tasks JSON to jq as one --argjson argv string, so once the backlog
# grew past ~128KB every live section of the captain's desk rendered the
# "Current fleet state could not be read" gap wording because jq died with
# "jq: Argument list too long". The blobs now travel on stdin, so a large
# backlog must still produce a full, valid snapshot.
test_large_backlog_survives_argv_limit() {
  local home out bytes i body
  home=$(make_home large-backlog)
  # ~180KB of active queued+blocked task bodies, well past MAX_ARG_STRLEN.
  body=$(printf 'x%.0s' {1..300})
  {
    printf '## In flight\n'
    for i in $(seq 1 400); do
      printf -- '- [ ] big-task-%03d - Big Task %03d %s (repo: alpha) (kind: ship) (priority: 3) (since 2026-07-07)\n' "$i" "$i" "$body"
    done
  } > "$home/data/backlog.md"
  bytes=$(wc -c < "$home/data/backlog.md")
  [ "$bytes" -gt 131072 ] \
    || fail "fixture backlog must exceed MAX_ARG_STRLEN (128KB), got $bytes bytes"
  out=$(FM_HOME="$home" "$SNAPSHOT" --json --full) \
    || fail "snapshot must not fail on a >128KB backlog (argv-limit regression)"
  printf '%s' "$out" | jq -e '
    .schema == "fm-fleet-snapshot.v1"
      and (.backlog.records | length) == 400
  ' >/dev/null \
    || fail "large-backlog snapshot must be full and valid, got: $(printf '%s' "$out" | head -c 200)"
  pass "a >128KB backlog still renders a full valid snapshot (argv-limit regression)"
}

# The secondmate landed/current blobs and the main-inventory/scout-reports blobs
# can each grow past ARG_MAX once a home accumulates many landed records. Passing
# them as --argjson argv values crashed the whole snapshot with
# "Argument list too long", which silently blanked the captain's desk. The fix
# feeds every large blob to jq on stdin via `input`. Guard that the two fixed
# assembly sites no longer route a large blob through --argjson.
test_large_blobs_reach_jq_via_stdin_not_argv() {
  local src landed_fn final_asm
  src=$ROOT/bin/fm-fleet-snapshot.sh
  # The secondmate-landed projection must consume its blob from stdin, never argv.
  landed_fn=$(awk '/^secondmate_landed_from_current_json\(\)/{f=1} f{print} /^}/{if(f)exit}' "$src")
  printf '%s' "$landed_fn" | grep -q -- '--argjson current' \
    && fail "secondmate_landed_from_current_json still passes the current blob as --argjson (ARG_MAX regression)"
  printf '%s' "$landed_fn" | grep -Eq 'printf .* \| jq' \
    || fail "secondmate_landed_from_current_json must feed the current blob to jq on stdin"
  # The final snapshot-assembly jq must not pass any of the four large blobs as
  # --argjson; they belong on the stdin stream as `(input)` reads.
  final_asm=$(awk '/\$BACKLOG_JSON" "\$TASKS_JSON"/{f=1} f{print} /report_kind\(\$id\)/{if(f)exit}' "$src")
  printf '%s' "$final_asm" | grep -Eq -- '--argjson (main_inventory|scout_reports|secondmate_current|secondmate_landed)' \
    && fail "final snapshot assembly still passes a large blob as --argjson (ARG_MAX regression)"
  # shellcheck disable=SC2016  # literal $VAR needle strings matched against the script source, not expansions
  printf '%s' "$final_asm" | grep -q 'MAIN_INVENTORY_JSON" "$SCOUT_REPORTS_JSON"' \
    || fail "final snapshot assembly must feed main_inventory/scout_reports on stdin"
  # shellcheck disable=SC2016  # literal $VAR needle strings matched against the script source, not expansions
  printf '%s' "$final_asm" | grep -q 'SECONDMATE_CURRENT_JSON" "$SECONDMATE_LANDED_JSON"' \
    || fail "final snapshot assembly must feed secondmate current/landed on stdin"
  pass "large snapshot blobs reach jq on stdin, never as --argjson argv (ARG_MAX regression)"
}

# Compact default projection: identity + state + title capped at 120 with an
# inline full-source pointer + decision/PR metadata + aggregate counts, bounded
# by the ceiling. Presence (ABSENT vs empty vs content) survives; fat fields
# restore via --fields; the empty home still renders explicit absence markers.
test_compact_default_projection
test_compact_fields_body_restores_full_backlog
test_compact_title_truncation_carries_pointer
test_summary_mode_counts
test_compact_ceiling_trims_with_disclosure
test_compact_unknown_field_fails_closed
test_empty_fleet_json
test_fixture_snapshot_json
test_main_inventory_orphan_and_unstructured_disclosure
test_normalized_roles_and_plural_blocker_readiness
test_event_hints_follow_reconciled_current_state
test_open_decision_survives_later_unrelated_event
test_secondmate_open_decision_survives_live_endpoint
test_open_decision_transfers_to_captain_hold
test_open_decision_clears_on_keyed_resolution
test_completed_scout_report_is_pointer_not_pending
test_parked_scout_decision_stays_pending
test_large_backlog_survives_argv_limit
test_large_blobs_reach_jq_via_stdin_not_argv
test_scout_reports_include_teardown_reports
test_backlog_tasks_axi_forms_and_overrides
test_view_renders_snapshot
test_view_renders_dead_secondmate_agent_status
test_gap3_pairs_event_with_current_state_old_and_superseded
test_gap3_fresh_agreeing_event_is_paired_without_markers
test_telemetry_subobject_on_task_rows
