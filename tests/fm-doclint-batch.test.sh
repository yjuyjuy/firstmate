#!/usr/bin/env bash
# Tests for the batched document+lint recovery pass (bin/fm-doclint-batch.sh and
# its format/arithmetic library bin/fm-doclint-batch-lib.sh).
#
# WHY THIS EXISTS: small / doc-irrelevant lanes run no-mistakes with
# `--skip document,lint`, so doc/lint drift accumulates silently on a repo's
# dev. This pass is the cheap recovery half: run document+lint ONCE over the
# accumulated merged changes when a batch is big enough. See
# data/batch-doclint-pass/report.md for the design of record.
#
# Covers, per the build brief:
#   (a) threshold arithmetic from a fixture completions.tsv + marker ref:
#       - >= 8 landed ship lanes since the last pass fires (lane condition)
#       - >= 14 days since the last pass with >= 1 lane fires (time ceiling)
#       - a fresh, small batch does not fire
#       - no marker yet counts every ship lane for the repo
#   (b) the `brief` command emits the two-phase flow: a document+lint-only pass run
#       (`--skip rebase,review,test,push,pr,ci`, no delivery steps) off origin/dev, then,
#       only when the pass produced fixes, a push-legal delivery run
#       (`--skip document,lint,test`) that ends at a PR for captain merge with no
#       hand-push, and a clean pass preserved as a valid no-PR success
#   (c) marker-ref advance is fast-forward-only and never forces or deletes
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=bin/fm-doclint-batch-lib.sh disable=SC1091
. "$ROOT/bin/fm-doclint-batch-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-doclint-batch-tests)

CLI="$ROOT/bin/fm-doclint-batch.sh"

# Write a completions.tsv with the standard header plus the given raw entry
# lines (each already tab-separated).
write_completions() {
  local file=$1
  shift
  {
    printf '%s\n' '# firstmate completion ledger: append-only, never pruned.'
    local line
    for line in "$@"; do
      printf '%s\n' "$line"
    done
  } > "$file"
}

# Make an ISO date N days before today (UTC).
days_ago() {
  date -u -d "$1 days ago" +%Y-%m-%d
}

# Build a bare-minimum git repo with a commit dated <iso-date>, echo its sha.
commit_at() {
  local repo=$1 date=$2 msg=$3
  local stamp="${date}T12:00:00+0000"
  GIT_AUTHOR_DATE="$stamp" GIT_COMMITTER_DATE="$stamp" \
    git -C "$repo" commit -q --allow-empty -m "$msg"
  git -C "$repo" rev-parse HEAD
}

new_repo() {
  local repo=$1
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email fmtest@example.invalid
  git -C "$repo" config user.name fmtest
}

# --- (a) threshold arithmetic -----------------------------------------------

test_threshold_fires_on_lane_count() {
  local repo="$TMP_ROOT/lanes/proj" comp="$TMP_ROOT/lanes/completions.tsv"
  new_repo "$repo"
  local base
  base=$(commit_at "$repo" "$(days_ago 3)" base)
  fm_doclint_marker_advance "$repo" alpha "$base" || fail "advance failed"
  # 8 ship lanes landed AFTER the marker date (yesterday), plus noise.
  local y; y=$(days_ago 1)
  local lines=() i
  for i in 1 2 3 4 5 6 7 8; do
    lines+=("$(printf 'lane-%s\t%s\tship\talpha\tsha%s' "$i" "$y" "$i")")
  done
  lines+=("$(printf 'scout-x\t%s\tscout\talpha\t' "$y")")
  lines+=("$(printf 'other\t%s\tship\tbeta\tshab' "$y")")
  write_completions "$comp" "${lines[@]}"
  local n
  n=$(fm_doclint_count_since "$comp" alpha "$(days_ago 3)")
  [ "$n" = 8 ] || fail "expected 8 lanes since marker, got $n"
  fm_doclint_threshold_met 8 3 || fail "8 lanes should meet the threshold"
  pass "threshold fires on >= 8 landed ship lanes since the last pass"
}

test_threshold_fires_on_time_ceiling() {
  # Only 2 lanes, but the last pass was 20 days ago: the time ceiling fires.
  fm_doclint_threshold_met 2 20 || fail "2 lanes over 20 days should fire on time"
  # ... but 0 lanes never fires, however old.
  ! fm_doclint_threshold_met 0 40 || fail "0 lanes must never fire even after 40 days"
  pass "threshold fires on >= 14 days with >= 1 lane, never on 0 lanes"
}

test_threshold_quiet_on_fresh_small_batch() {
  ! fm_doclint_threshold_met 3 2 || fail "3 lanes at 2 days must stay quiet"
  ! fm_doclint_threshold_met 7 13 || fail "7 lanes at 13 days must stay quiet"
  pass "a fresh, small batch does not fire"
}

test_no_marker_counts_all_ship_lanes() {
  local comp="$TMP_ROOT/nomarker/completions.tsv"
  mkdir -p "$TMP_ROOT/nomarker"
  local d; d=$(days_ago 5)
  write_completions "$comp" \
    "$(printf 'a\t%s\tship\talpha\ts1' "$d")" \
    "$(printf 'b\t%s\tship\talpha\ts2' "$d")" \
    "$(printf 'c\t%s\tscout\talpha\t' "$d")" \
    "$(printf 'd\t%s\tship\tbeta\ts3' "$d")"
  # Empty since-date means "no last pass": count every ship lane for the repo.
  local n
  n=$(fm_doclint_count_since "$comp" alpha "")
  [ "$n" = 2 ] || fail "no-marker count should be 2 ship alpha lanes, got $n"
  # oldest ship date for the repo drives the drift clock when no marker exists.
  local oldest
  oldest=$(fm_doclint_oldest_ship_date "$comp" alpha)
  [ "$oldest" = "$d" ] || fail "oldest ship date wrong: $oldest"
  pass "no marker yet counts every ship lane for the repo"
}

test_dual_format_close_field_windows_by_day() {
  # A mixed ledger: legacy bare-date rows AND new full-timestamp rows. Both must
  # window on their calendar day against a bare-date marker/since bound.
  local comp="$TMP_ROOT/mixed/completions.tsv"
  mkdir -p "$TMP_ROOT/mixed"
  local since y
  since=$(days_ago 3)
  y=$(days_ago 1)
  write_completions "$comp" \
    "$(printf 'old-in\t%s\tship\talpha\ts1' "$y")" \
    "$(printf 'new-in\t%sT01:35:29Z\tship\talpha\ts2' "$y")" \
    "$(printf 'old-out\t%s\tship\talpha\ts3' "$since")" \
    "$(printf 'new-out\t%sT23:59:59Z\tship\talpha\ts4' "$since")"
  # since is exclusive (day <= since is dropped): the two <y> rows count, the two
  # <since>-day rows (bare and timestamped) are both excluded.
  local n
  n=$(fm_doclint_count_since "$comp" alpha "$since")
  [ "$n" = 2 ] || fail "mixed-format count since marker wrong: expected 2, got $n"
  # oldest ship day must be the <since> day, taken from EITHER format's day.
  local oldest
  oldest=$(fm_doclint_oldest_ship_date "$comp" alpha)
  [ "$oldest" = "$since" ] || fail "mixed-format oldest ship day wrong: $oldest"
  pass "doclint counts/ages a mixed legacy-and-timestamped ledger by calendar day"
}

test_status_line_shape() {
  local repo="$TMP_ROOT/shape/proj" comp="$TMP_ROOT/shape/completions.tsv"
  new_repo "$repo"
  local base; base=$(commit_at "$repo" "$(days_ago 20)" base)
  fm_doclint_marker_advance "$repo" alpha "$base"
  local y; y=$(days_ago 1)
  write_completions "$comp" "$(printf 'lane-1\t%s\tship\talpha\tsha1' "$y")"
  local line
  line=$(fm_doclint_status "$repo" "$comp" alpha)
  assert_contains "$line" "alpha:" "status line names the repo"
  assert_contains "$line" "1 lanes since" "status line reports the lane count"
  assert_contains "$line" "threshold met=yes" "1 lane over 20 days should read met=yes"
  pass "status line shape matches the report"
}

# --- (b) brief content ------------------------------------------------------

test_brief_emits_two_phase_pr_delivery() {
  local out
  out=$(FM_ROOT_OVERRIDE="$ROOT" "$CLI" brief hyfin)
  assert_contains "$out" "no-mistakes axi run --skip rebase,review,test,push,pr,ci" \
    "brief must run the pass with document+lint only and the delivery steps skipped"
  assert_contains "$out" "no-mistakes axi run --skip document,lint,test" \
    "brief must deliver fixes through a second push-legal run (review + push + PR)"
  assert_not_contains "$out" "--skip review,test,rebase" \
    "brief must not carry the refused skip-review run"
  assert_not_contains "$out" "Land the fixes via" \
    "brief must not tell the lane to land via normal delivery (the hand-push bypass)"
  assert_contains "$out" "for captain merge" \
    "brief must end a with-fixes pass at a PR for captain merge"
  assert_contains "$out" "git rev-list --count origin/dev..HEAD" \
    "brief must distinguish a clean pass from a pass with fixes"
  assert_contains "$out" "done: doclint pass clean, no fixes" \
    "brief must keep a clean pass as a valid no-PR success"
  assert_contains "$out" "fm/doclint-hyfin-" "brief cuts a dated doclint branch"
  assert_contains "$out" "origin/dev" "brief bases the pass on origin/dev"
  assert_contains "$out" "marker-advance" "brief tells the lane to advance the marker ref"
  pass "brief emits the two-phase pass+PR flow off origin/dev without a hand-push bypass"
}

# The emitted brief must carry the SAME structural safety scaffold every ship
# brief gets from bin/fm-brief.sh: the Setup/worktree-isolation verification
# section that step 1 already points at ("Setup below"), the Rule-1
# never-push-to-the-default-branch guard, and the C1-C6 captain-rules block. The
# mode-correct "never hand-push / never merge / PR for captain merge" delivery
# wording (landed in #185) must survive alongside it. History: a 2026-08-20 lane
# followed a raw self-land instruction and hand-pushed to hyfin origin/dev.
test_brief_carries_ship_safety_scaffold() {
  local out
  out=$(FM_ROOT_OVERRIDE="$ROOT" "$CLI" brief hyfin)
  # Setup / worktree-isolation section that step 1's "Setup below" points at.
  assert_contains "$out" "# Setup" \
    "brief must carry the Setup section its step 1 points at"
  assert_contains "$out" "Verify isolation before anything else" \
    "brief must carry the worktree-isolation verification"
  # Rule-1 default-branch guard.
  assert_contains "$out" "Never push to the default branch" \
    "brief must carry the Rule-1 default-branch guard"
  # The C1-C6 captain-rules block.
  assert_contains "$out" "# Standing captain rules" \
    "brief must carry the standing captain-rules block"
  assert_contains "$out" "C1. Never force anything" \
    "brief must carry the C1 never-force rule"
  assert_contains "$out" "C6. If this task came from a Mattermost thread" \
    "brief must carry the full C1-C6 block through C6"
  # The mode-correct delivery wording (#185) must survive the scaffold add.
  assert_contains "$out" "Never hand-push, never merge" \
    "brief must keep the never-hand-push / never-merge delivery wording"
  assert_contains "$out" "for captain merge" \
    "brief must keep the PR-for-captain-merge delivery wording"
  pass "brief carries the ship safety scaffold (Setup, Rule-1, C1-C6) with delivery wording intact"
}

# --- (c) marker-ref advance safety ------------------------------------------

test_marker_advance_fast_forward_only() {
  local repo="$TMP_ROOT/ff/proj"
  new_repo "$repo"
  local c1 c2
  c1=$(commit_at "$repo" "$(days_ago 5)" c1)
  fm_doclint_marker_advance "$repo" alpha "$c1" || fail "initial advance failed"
  [ "$(fm_doclint_marker_read "$repo" alpha)" = "$c1" ] || fail "marker not set to c1"
  c2=$(commit_at "$repo" "$(days_ago 4)" c2)   # descendant of c1
  fm_doclint_marker_advance "$repo" alpha "$c2" || fail "fast-forward advance failed"
  [ "$(fm_doclint_marker_read "$repo" alpha)" = "$c2" ] || fail "marker did not advance to c2"
  pass "marker advances on a fast-forward"
}

test_marker_advance_refuses_non_fast_forward() {
  local repo="$TMP_ROOT/nonff/proj"
  new_repo "$repo"
  local c1 c2 divergent
  c1=$(commit_at "$repo" "$(days_ago 5)" c1)
  c2=$(commit_at "$repo" "$(days_ago 4)" c2)
  fm_doclint_marker_advance "$repo" alpha "$c2" || fail "advance to c2 failed"
  # A divergent commit that is NOT a descendant of c2 must be refused.
  git -C "$repo" checkout -q -b side "$c1"
  divergent=$(commit_at "$repo" "$(days_ago 3)" divergent)
  fm_doclint_marker_advance "$repo" alpha "$divergent" \
    && fail "non-fast-forward advance was not refused"
  [ "$(fm_doclint_marker_read "$repo" alpha)" = "$c2" ] \
    || fail "refused advance still moved the marker (force leaked)"
  # A backward move to an ancestor is also refused.
  fm_doclint_marker_advance "$repo" alpha "$c1" \
    && fail "backward advance to an ancestor was not refused"
  [ "$(fm_doclint_marker_read "$repo" alpha)" = "$c2" ] \
    || fail "refused backward advance still moved the marker"
  pass "marker advance refuses a non-fast-forward and never forces"
}

test_marker_helpers_reject_unsafe_repo() {
  local repo="$TMP_ROOT/unsafe/proj"
  new_repo "$repo"
  local c1; c1=$(commit_at "$repo" "$(days_ago 5)" c1)
  fm_doclint_marker_advance "$repo" "$(printf 'bad/../etc')" "$c1" \
    && fail "unsafe repo name was not refused"
  pass "marker helpers reject an unsafe repo name"
}

# --- hourly review wiring ----------------------------------------------------
# A threshold-met repo surfaces as ONE actionable session-review finding, and a
# home with no ready repo stays silent (no second supervision cycle, no noise).
test_session_review_surfaces_ready_repo() {
  local home="$TMP_ROOT/rev-home"
  local state="$home/state" data="$home/data" projects="$home/projects"
  mkdir -p "$state" "$data" "$projects"
  # A registered repo with a local clone, an old marker, and >= 1 landed lane
  # older than the day ceiling: threshold met on the time condition.
  local repo="$projects/alpha"
  new_repo "$repo"
  local base; base=$(commit_at "$repo" "$(days_ago 30)" base)
  fm_doclint_marker_advance "$repo" alpha "$base"
  printf -- '- alpha [direct-push] - test repo (added 2026-01-01)\n' > "$data/projects.md"
  write_completions "$data/completions.tsv" \
    "$(printf 'lane-1\t%s\tship\talpha\tsha1' "$(days_ago 20)")"
  touch "$state/.last-watcher-beat"
  local out
  out=$(env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-session-review.sh" 2>&1)
  assert_contains "$out" "session review:" "review must surface a headline"
  assert_contains "$out" "alpha" "review must name the ready repo"
  # The full report carries the dispatch command.
  local report="$state/.hourly-review.latest"
  assert_present "$report" "review must write its report"
  assert_grep "fm-doclint-batch.sh brief alpha" "$report" \
    "report must carry the on-demand dispatch command"
  pass "session review surfaces a threshold-met repo as one actionable finding"
}

test_session_review_silent_when_no_repo_ready() {
  local home="$TMP_ROOT/rev-quiet"
  local state="$home/state" data="$home/data" projects="$home/projects"
  mkdir -p "$state" "$data" "$projects"
  local repo="$projects/alpha"
  new_repo "$repo"
  local base; base=$(commit_at "$repo" "$(days_ago 2)" base)
  fm_doclint_marker_advance "$repo" alpha "$base"
  printf -- '- alpha [direct-push] - test repo (added 2026-01-01)\n' > "$data/projects.md"
  # Only 1 recent lane, 2 days old: below both thresholds.
  write_completions "$data/completions.tsv" \
    "$(printf 'lane-1\t%s\tship\talpha\tsha1' "$(days_ago 1)")"
  touch "$state/.last-watcher-beat"
  local out
  out=$(env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-session-review.sh" 2>&1)
  assert_not_contains "$out" "alpha" "review must stay silent on a small fresh batch"
  pass "session review stays silent when no repo is ready"
}

test_threshold_fires_on_lane_count
test_threshold_fires_on_time_ceiling
test_threshold_quiet_on_fresh_small_batch
test_no_marker_counts_all_ship_lanes
test_dual_format_close_field_windows_by_day
test_status_line_shape
test_brief_emits_two_phase_pr_delivery
test_brief_carries_ship_safety_scaffold
test_marker_advance_fast_forward_only
test_marker_advance_refuses_non_fast_forward
test_marker_helpers_reject_unsafe_repo
test_session_review_surfaces_ready_repo
test_session_review_silent_when_no_repo_ready
