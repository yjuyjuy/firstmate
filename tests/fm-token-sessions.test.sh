#!/usr/bin/env bash
# Tests for the durable token-session ledger + crew-session resolver
# (bin/fm-token-sessions-lib.sh) and its integration into bin/fm-spawn.sh
# (post-launch capture), bin/fm-session-start.sh (own-session sentinel), and the
# teardown durability guarantee.
#
# Design of record: data/design-token-usage-visibility/report.md, PR-T3.
# The ledger makes per-ticket token/cost rollup exact and PERMANENT: it survives
# teardown (which removes state/<id>.meta) and sums EVERY session a ticket ran,
# so a compact/relaunch or stuck-recovery relaunch appends an additional row for
# the same id (many-rows-per-id, never deduped by id alone).
#
# Covers, per the brief acceptance criteria:
#   - resolve picks the newest created_at at/after spawn for a matching worktree
#     (pooled-slot reuse: an older session sharing the worktree must NOT win)
#   - resolve fails closed (empty) when nothing matches (no worktree, no harness)
#   - record appends one correct row; a second session for the same id appends a
#     SECOND row; the same (id, session_id) is idempotent (no double-append)
#   - a jcode spawn writes exactly one row with the correct session id
#   - an unresolvable session appends NO row and does NOT fail the spawn
#   - session-start appends the __firstmate__ sentinel row for its own session
#   - teardown does NOT remove or truncate the ledger
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=bin/fm-token-sessions-lib.sh disable=SC1091
. "$ROOT/bin/fm-token-sessions-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-token-sessions-tests)

entry_count() {
  grep -cvE '^[[:space:]]*(#|$)' "$1" 2>/dev/null || echo 0
}

# Write a jcode-shaped session json. Args: dir sid working_dir created_at.
# The stored id mirrors the real store shape (session_<sid>), matching the
# filename base, so a test asserts against the same id the resolver returns.
write_session() {
  local dir=$1 sid=$2 wd=$3 created=$4
  cat > "$dir/session_$sid.json" <<EOF
{"id":"session_$sid","created_at":"$created","working_dir":"$wd","updated_at":"$created"}
EOF
}

# --- resolver ---------------------------------------------------------------

test_resolve_newest_at_or_after_spawn() {
  local base="$TMP_ROOT/res" sdir="$TMP_ROOT/res/sessions" wt="$TMP_ROOT/res/wt"
  mkdir -p "$sdir" "$wt"
  # Pooled-slot reuse: an OLDER session shares the same worktree; it must lose.
  write_session "$sdir" old "$wt" "2026-08-17T10:00:00.000Z"
  write_session "$sdir" crew "$wt" "2026-08-17T12:00:05.123456789Z"
  write_session "$sdir" other "$base/elsewhere" "2026-08-17T13:00:00Z"
  local got
  got=$(fm_resolve_crew_session_id "$wt" "2026-08-17T12:00:00Z" "$sdir")
  [ "$got" = "session_crew" ] || fail "resolve returned '$got', want session_crew"
  # A floor earlier than both still picks the NEWEST matching session.
  got=$(fm_resolve_crew_session_id "$wt" "2026-08-17T09:00:00Z" "$sdir")
  [ "$got" = "session_crew" ] || fail "newest-wins failed: got '$got'"
  pass "resolve picks the newest created_at at/after spawn for the matching worktree"
}

test_resolve_fails_closed_on_no_match() {
  local sdir="$TMP_ROOT/nomatch/sessions" wt="$TMP_ROOT/nomatch/wt"
  mkdir -p "$sdir" "$wt"
  write_session "$sdir" crew "$wt" "2026-08-17T12:00:00Z"
  local got status
  # A floor AFTER the only session: nothing at/after spawn -> empty, non-zero.
  got=$(fm_resolve_crew_session_id "$wt" "2026-08-17T14:00:00Z" "$sdir")
  status=$?
  [ -z "$got" ] || fail "resolve force-fit a stale session: '$got'"
  [ "$status" -ne 0 ] || fail "resolve returned 0 with no match"
  # A worktree that no session ran in -> empty.
  got=$(fm_resolve_crew_session_id "$TMP_ROOT/nomatch/never" "" "$sdir")
  [ -z "$got" ] || fail "resolve matched a non-existent worktree: '$got'"
  # A sessions dir that does not exist -> empty (unsupported/unknown harness).
  got=$(fm_resolve_crew_session_id "$wt" "" "$TMP_ROOT/nomatch/nostore")
  [ -z "$got" ] || fail "resolve matched with no store: '$got'"
  pass "resolve fails closed (empty) with no matching session, worktree, or store"
}

test_resolve_matches_symlinked_worktree() {
  local sdir="$TMP_ROOT/sym/sessions" real="$TMP_ROOT/sym/real" link="$TMP_ROOT/sym/link"
  mkdir -p "$sdir" "$real"
  ln -s "$real" "$link"
  # Session recorded the REAL path; caller asks with the symlink path.
  write_session "$sdir" crew "$real" "2026-08-17T12:00:00Z"
  local got
  got=$(fm_resolve_crew_session_id "$link" "" "$sdir")
  [ "$got" = "session_crew" ] || fail "symlinked worktree did not match: '$got'"
  pass "resolve normalizes paths so a symlinked worktree still matches"
}

# --- ledger append ----------------------------------------------------------

test_record_appends_one_correct_row() {
  local data="$TMP_ROOT/rec/data"
  mkdir -p "$data"
  fm_token_sessions_record "$data" task-a session_x /wt/a 2026-08-17T12:00:00Z jcode \
    || fail "record failed"
  local file line
  file=$(fm_token_sessions_file "$data")
  [ -f "$file" ] || fail "ledger not created"
  [ "$(entry_count "$file")" = 1 ] || fail "expected exactly 1 row"
  line=$(grep -vE '^[[:space:]]*(#|$)' "$file")
  [ "$line" = "$(printf 'task-a\tsession_x\t/wt/a\t2026-08-17T12:00:00Z\tjcode')" ] \
    || fail "row content wrong: $line"
  pass "record appends exactly one correct row"
}

test_second_session_same_id_appends_second_row() {
  local data="$TMP_ROOT/multi/data"
  mkdir -p "$data"
  fm_token_sessions_record "$data" task-a session_1 /wt/a 2026-08-17T12:00:00Z jcode
  # A relaunch/recovery spawns a NEW session for the SAME ticket id -> new row.
  fm_token_sessions_record "$data" task-a session_2 /wt/a 2026-08-17T13:00:00Z jcode
  local file count
  file=$(fm_token_sessions_file "$data")
  [ "$(entry_count "$file")" = 2 ] || fail "expected 2 rows for a multi-session ticket"
  count=$(grep -c '^task-a	' "$file")
  [ "$count" = 2 ] || fail "expected 2 rows for task-a, got $count"
  pass "a second session for the same id appends a second row (many-rows-per-id)"
}

test_same_session_is_idempotent() {
  local data="$TMP_ROOT/idem/data"
  mkdir -p "$data"
  fm_token_sessions_record "$data" task-a session_1 /wt/a 2026-08-17T12:00:00Z jcode
  fm_token_sessions_record "$data" task-a session_1 /wt/a 2026-08-17T12:00:00Z jcode \
    || fail "repeat record returned non-zero"
  local file
  file=$(fm_token_sessions_file "$data")
  [ "$(entry_count "$file")" = 1 ] || fail "same (id, session_id) double-appended"
  pass "the same (id, session_id) is idempotent, never double-appended"
}

test_unsafe_or_empty_field_refused() {
  local data="$TMP_ROOT/unsafe/data"
  mkdir -p "$data"
  fm_token_sessions_record "$data" "$(printf 'bad\tid')" s /wt a jcode \
    && fail "tab in id was not refused"
  fm_token_sessions_record "$data" task-a '' /wt a jcode \
    && fail "empty session_id was not refused"
  local file
  file=$(fm_token_sessions_file "$data")
  [ ! -f "$file" ] || [ "$(entry_count "$file")" = 0 ] \
    || fail "unsafe/empty field wrote a row"
  pass "unsafe or empty fields are refused without writing"
}

# --- read path ---------------------------------------------------------------

test_rows_for_reads_exact_id_in_order() {
  # The report CLI's single read path: exact first-column id match, file order,
  # comment lines skipped, never a substring false hit.
  local data="$TMP_ROOT/rows/data"
  mkdir -p "$data"
  fm_token_sessions_record "$data" task-a session_1 /wt/a 2026-08-17T12:00:00Z jcode
  fm_token_sessions_record "$data" task-a session_2 /wt/a 2026-08-17T13:00:00Z jcode
  fm_token_sessions_record "$data" task-bb session_x /wt/b 2026-08-17T14:00:00Z jcode
  local out want
  out=$(fm_token_sessions_rows_for "$data" task-a)
  want=$(printf 'task-a\tsession_1\t/wt/a\t2026-08-17T12:00:00Z\tjcode\ntask-a\tsession_2\t/wt/a\t2026-08-17T13:00:00Z\tjcode\n')
  [ "$out" = "$want" ] || fail "rows_for returned the wrong rows: $out"
  # task-bb must NOT match task-b, and an unknown id returns non-zero.
  out=$(fm_token_sessions_rows_for "$data" task-b) || true
  [ -z "$out" ] || fail "rows_for matched a prefix id: $out"
  fm_token_sessions_rows_for "$data" nope >/dev/null 2>&1 \
    && fail "rows_for returned success for an unknown id"
  local missing="$TMP_ROOT/rows/nodata"
  fm_token_sessions_rows_for "$missing" task-a >/dev/null 2>&1 \
    && fail "rows_for succeeded with an absent ledger"
  pass "rows_for returns exactly the ledger rows for an id, in order, no prefix or unknown-id false hits"
}

# --- spawn integration ------------------------------------------------------

# Drive the REAL bin/fm-spawn.sh with a fake tmux backend (the same shape the
# other spawn tests use) against a real own-clone worktree and a fake jcode
# session store, and assert the ledger row + the meta session_id stamp.
SPAWN="$ROOT/bin/fm-spawn.sh"

# A fake tmux: reports the settled worktree path for pane_current_path, answers
# display-message with a client name, and swallows send-keys. Mirrors
# tests/fm-spawn-heavy-slots-file.test.sh.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# Build a jcode-crew home with one own-clone project + worktree. Echoes:
# home|proj|wt|fakebin
make_spawn_home() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$home/projects/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$case_dir/sessions"
  printf 'jcode\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin"
}

run_spawn_jcode() {  # <home> <proj> <wt> <fakebin> <id> <sessions_dir>
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5 sdir=$6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$wt" \
    FM_SPAWN_JCODE_READY_POLLS=0 \
    FM_TOKEN_CAPTURE_RETRIES=0 FM_TOKEN_CAPTURE_SLEEP=0 \
    JCODE_SESSIONS_DIR="$sdir" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" 2>&1
}

test_spawn_captures_jcode_session() {
  command -v git >/dev/null 2>&1 || { echo "skip: git not found"; return 0; }
  command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; return 0; }
  local rec home proj wt fakebin id sdir out status
  id=tok-spawn-1
  rec=$(make_spawn_home spawn1 "$id")
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  sdir="$TMP_ROOT/spawn1/sessions"
  # The crew session points at the leased worktree (real path) with a far-future
  # created_at so it is always at or after the spawn instant. An OLDER pooled
  # session shares the worktree and must lose.
  local wt_real
  wt_real=$(cd "$wt" && pwd -P)
  write_session "$sdir" pooled "$wt_real" "2020-01-01T00:00:00Z"
  write_session "$sdir" crew "$wt_real" "2099-01-01T00:00:00Z"
  out=$(run_spawn_jcode "$home" "$proj" "$wt" "$fakebin" "$id" "$sdir")
  status=$?
  expect_code 0 "$status" "jcode spawn should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  local file
  file=$(fm_token_sessions_file "$home/data")
  [ -f "$file" ] || fail "spawn wrote no ledger"
  [ "$(entry_count "$file")" = 1 ] || fail "spawn wrote other than 1 row"
  local line
  line=$(grep -vE '^[[:space:]]*(#|$)' "$file")
  case "$line" in
    "$id	session_crew	$wt_real	"*"	jcode") : ;;
    *) fail "spawn ledger row wrong: $line" ;;
  esac
  # The meta must also carry the session_id stamp.
  assert_grep "session_id=session_crew" "$home/state/$id.meta" \
    "spawn did not stamp session_id into meta"
  pass "a jcode spawn writes one ledger row with the correct session id (newest at/after spawn)"
}

test_spawn_relaunch_appends_second_row() {
  command -v git >/dev/null 2>&1 || { echo "skip: git not found"; return 0; }
  command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; return 0; }
  local rec home proj wt fakebin id sdir wt_real
  id=tok-spawn-2
  rec=$(make_spawn_home spawn2 "$id")
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  sdir="$TMP_ROOT/spawn2/sessions"
  wt_real=$(cd "$wt" && pwd -P)
  # First spawn resolves session_first.
  write_session "$sdir" first "$wt_real" "2099-01-01T00:00:00Z"
  run_spawn_jcode "$home" "$proj" "$wt" "$fakebin" "$id" "$sdir" >/dev/null 2>&1
  # A relaunch/recovery spawns a NEW session for the SAME id; add it, newer.
  write_session "$sdir" second "$wt_real" "2099-06-01T00:00:00Z"
  # A relaunch re-uses the same id and worktree; clear the stale meta first as a
  # recovery relaunch would, so the spawn re-runs cleanly.
  rm -f "$home/state/$id.meta"
  run_spawn_jcode "$home" "$proj" "$wt" "$fakebin" "$id" "$sdir" >/dev/null 2>&1
  local file count
  file=$(fm_token_sessions_file "$home/data")
  count=$(grep -c "^$id	" "$file")
  [ "$count" = 2 ] || fail "relaunch did not append a second row for the same id (got $count)"
  grep -q "^$id	session_first	" "$file" || fail "first session row missing"
  grep -q "^$id	session_second	" "$file" || fail "relaunch session row missing"
  pass "a relaunch/second spawn for the same id appends a second ledger row"
}

test_spawn_unresolvable_writes_nothing() {
  command -v git >/dev/null 2>&1 || { echo "skip: git not found"; return 0; }
  command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; return 0; }
  local rec home proj wt fakebin id sdir out status
  id=tok-spawn-3
  rec=$(make_spawn_home spawn3 "$id")
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  sdir="$TMP_ROOT/spawn3/sessions"
  # A session store with NO session in the leased worktree: resolve is empty.
  write_session "$sdir" elsewhere "$TMP_ROOT/spawn3/elsewhere" "2099-01-01T00:00:00Z"
  out=$(run_spawn_jcode "$home" "$proj" "$wt" "$fakebin" "$id" "$sdir")
  status=$?
  # The spawn must still SUCCEED - capture is best-effort, never a blocker.
  expect_code 0 "$status" "unresolvable capture must not fail the spawn"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  local file
  file=$(fm_token_sessions_file "$home/data")
  [ ! -f "$file" ] || [ "$(entry_count "$file")" = 0 ] \
    || fail "an unresolvable session wrote a ledger row"
  assert_no_grep "session_id=" "$home/state/$id.meta" \
    "an unresolvable session stamped session_id into meta"
  pass "an unresolvable session records no row and does not fail the spawn"
}

# --- capture: retry + verify + diagnostic -----------------------------------

test_capture_happy_path_records_and_prints_id() {
  command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; return 0; }
  local base="$TMP_ROOT/cap1" data="$TMP_ROOT/cap1/data" sdir="$TMP_ROOT/cap1/sessions" wt="$TMP_ROOT/cap1/wt"
  mkdir -p "$data" "$sdir" "$wt"
  local wt_real; wt_real=$(cd "$wt" && pwd -P)
  write_session "$sdir" crew "$wt_real" "2099-01-01T00:00:00Z"
  local out
  out=$(FM_TOKEN_CAPTURE_RETRIES=1 FM_TOKEN_CAPTURE_SLEEP=0 \
    fm_token_sessions_capture "$data" cap-a "$wt_real" 2026-08-17T12:00:00Z jcode "$sdir") \
    || fail "capture returned non-zero on a resolvable session"
  [ "$out" = session_crew ] || fail "capture did not print the resolved id: '$out'"
  local file; file=$(fm_token_sessions_file "$data")
  [ "$(entry_count "$file")" = 1 ] || fail "capture wrote other than 1 row"
  grep -q "^cap-a	session_crew	" "$file" || fail "capture row missing/wrong"
  pass "capture records one row and prints the resolved session id"
}

test_capture_retries_a_transient_miss() {
  command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; return 0; }
  # The session json is written ASYNCHRONOUSLY, appearing only AFTER capture has
  # already begun polling. A single-shot resolve would miss it and drop the row
  # silently (the live leak). Capture must retry until the store settles.
  local base="$TMP_ROOT/cap2" data="$TMP_ROOT/cap2/data" sdir="$TMP_ROOT/cap2/sessions" wt="$TMP_ROOT/cap2/wt"
  mkdir -p "$data" "$sdir" "$wt"
  local wt_real; wt_real=$(cd "$wt" && pwd -P)
  # Background writer: create the session file shortly after capture starts.
  ( sleep 0.2; write_session "$sdir" crew "$wt_real" "2099-01-01T00:00:00Z" ) &
  local writer=$!
  local out status
  out=$(FM_TOKEN_CAPTURE_RETRIES=60 FM_TOKEN_CAPTURE_SLEEP=0.05 \
    fm_token_sessions_capture "$data" cap-b "$wt_real" 2026-08-17T12:00:00Z jcode "$sdir")
  status=$?
  wait "$writer" 2>/dev/null || true
  [ "$status" -eq 0 ] || fail "capture failed to retry a transient miss (status=$status)"
  [ "$out" = session_crew ] || fail "capture did not resolve after retry: '$out'"
  local file; file=$(fm_token_sessions_file "$data")
  grep -q "^cap-b	session_crew	" "$file" || fail "retry did not land a ledger row"
  pass "capture retries a transient store miss and still lands the row"
}

test_capture_gives_up_with_diagnostic_no_row() {
  command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; return 0; }
  # A readable store that never yields a matching session: capture exhausts its
  # bounded retries, writes NO row, and logs ONE clear diagnostic (not silent).
  local base="$TMP_ROOT/cap3" data="$TMP_ROOT/cap3/data" sdir="$TMP_ROOT/cap3/sessions" wt="$TMP_ROOT/cap3/wt"
  mkdir -p "$data" "$sdir" "$wt"
  local wt_real; wt_real=$(cd "$wt" && pwd -P)
  write_session "$sdir" elsewhere "$base/other" "2099-01-01T00:00:00Z"
  local out status err
  err=$(FM_TOKEN_CAPTURE_RETRIES=2 FM_TOKEN_CAPTURE_SLEEP=0 \
    fm_token_sessions_capture "$data" cap-c "$wt_real" 2026-08-17T12:00:00Z jcode "$sdir" 2>&1 >/dev/null)
  status=$?
  [ "$status" -ne 0 ] || fail "capture returned 0 on a permanent miss"
  case "$err" in
    *"capture MISS"*"cap-c"*) : ;;
    *) fail "capture did not log a clear MISS diagnostic: '$err'" ;;
  esac
  local file; file=$(fm_token_sessions_file "$data")
  [ ! -f "$file" ] || [ "$(entry_count "$file")" = 0 ] || fail "give-up wrote a ledger row"
  pass "capture gives up after bounded retries with a diagnostic and no row"
}

test_capture_skips_unreadable_harness_without_noise() {
  # A harness whose store this fleet cannot read is skipped WITHOUT retrying or
  # logging a false alarm - retry cannot make an unreadable store resolve.
  local data="$TMP_ROOT/cap4/data"
  mkdir -p "$data"
  fm_harness_session_store_readable jcode || fail "jcode store must be readable"
  fm_harness_session_store_readable opencode && fail "opencode store must be unreadable today"
  fm_harness_session_store_readable deepseek && fail "deepseek store must be unreadable today"
  local out status err
  err=$(FM_TOKEN_CAPTURE_RETRIES=99 FM_TOKEN_CAPTURE_SLEEP=9 \
    fm_token_sessions_capture "$data" cap-d /wt/x 2026-08-17T12:00:00Z opencode "$TMP_ROOT/cap4/none" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "capture returned 0 for an unreadable harness"
  [ -z "$err" ] || fail "capture logged noise for an unreadable harness: '$err'"
  local file; file=$(fm_token_sessions_file "$data")
  [ ! -f "$file" ] || [ "$(entry_count "$file")" = 0 ] || fail "unreadable harness wrote a row"
  pass "capture skips an unreadable harness immediately, no retry, no diagnostic"
}

# --- session-start sentinel -------------------------------------------------

test_session_start_records_sentinel() {
  command -v git >/dev/null 2>&1 || { echo "skip: git not found"; return 0; }
  command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; return 0; }
  local base="$TMP_ROOT/ss"
  local home="$base/home" sdir="$base/sessions" fakebin="$base/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$sdir" "$fakebin"
  # FM_ROOT is firstmate's own working_dir. Put a jcode session there.
  local fmroot
  fmroot=$(cd "$home" && pwd -P)
  write_session "$sdir" fmself "$fmroot" "2026-08-17T08:00:00Z"
  # Force a jcode primary and a readable store; stub the heavy subcommands so
  # session-start runs hermetically. We only assert the sentinel side effect.
  fm_fake_exit0 "$fakebin" tmux
  cat > "$fakebin/fm-harness.sh" <<'SH'
#!/usr/bin/env bash
printf jcode
SH
  chmod +x "$fakebin/fm-harness.sh"
  # Run session-start with overrides; JCODE_SESSIONS_DIR points at the fake store.
  JCODE_SESSIONS_DIR="$sdir" \
  FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$fmroot" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_CONFIG_OVERRIDE="$home/config" \
  PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-session-start.sh" >/dev/null 2>&1 || true
  local file
  file=$(fm_token_sessions_file "$home/data")
  [ -f "$file" ] || { echo "skip: session-start did not reach the sentinel step (read-only or lock refused in this env)"; return 0; }
  grep -q '^__firstmate__	session_fmself	' "$file" \
    || fail "session-start did not append the __firstmate__ sentinel row"
  pass "session-start appends the __firstmate__ sentinel row for its own session"
}

# --- teardown durability ----------------------------------------------------

test_teardown_preserves_ledger() {
  command -v git >/dev/null 2>&1 || { echo "skip: git not found"; return 0; }
  local base="$TMP_ROOT/td"
  local origin="$base/origin.git" proj="$base/proj" wt="$base/wt"
  local state="$base/state" data="$base/data" config="$base/config" fakebin="$base/fakebin"
  mkdir -p "$state" "$data" "$config" "$fakebin"
  fm_fake_exit0 "$fakebin" treehouse tmux
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0" ; exit 0 ;;
  "pr view") echo "not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/gh"

  git init -q --bare "$origin"
  git -C "$origin" symbolic-ref HEAD refs/heads/main
  git clone -q "$origin" "$proj" 2>/dev/null
  ( cd "$proj" || exit 1
    git config user.email fmtest@example.invalid
    git config user.name fmtest
    echo seed > seed.txt; git add seed.txt; git commit --quiet -m seed
    git branch -M main; git push -q origin main 2>/dev/null
    git remote set-head origin main 2>/dev/null || true
    git worktree add -q -b fm/task-td "$wt" main )
  ( cd "$wt" || exit 1
    echo change > change.txt; git add change.txt; git commit --quiet -m change
    git push -q origin fm/task-td 2>/dev/null )
  local head
  head=$(git -C "$wt" rev-parse HEAD)

  cat > "$state/task-td.meta" <<EOF
window=fm-task-td
worktree=$wt
project=$proj
kind=ship
mode=direct-push
pr_head=$head
session_id=session_td
EOF
  touch "$state/task-td.status" "$state/.last-watcher-beat"

  # Seed the durable ledger with this task's row BEFORE teardown.
  fm_token_sessions_record "$data" task-td session_td "$wt" 2026-08-17T12:00:00Z jcode \
    || fail "seed record failed"
  local file before
  file=$(fm_token_sessions_file "$data")
  before=$(cat "$file")

  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
    FM_CONFIG_OVERRIDE="$config" FM_DATA_OVERRIDE="$data" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-teardown.sh" task-td >/dev/null 2>&1 || true

  [ -f "$file" ] || fail "teardown removed the durable ledger"
  grep -q '^task-td	session_td	' "$file" || fail "teardown truncated the ledger row"
  [ "$(cat "$file")" = "$before" ] || fail "teardown altered the ledger content"
  pass "teardown does not remove or truncate the durable token-session ledger"
}

test_resolve_newest_at_or_after_spawn
test_resolve_fails_closed_on_no_match
test_resolve_matches_symlinked_worktree
test_record_appends_one_correct_row
test_second_session_same_id_appends_second_row
test_same_session_is_idempotent
test_unsafe_or_empty_field_refused
test_rows_for_reads_exact_id_in_order
test_spawn_captures_jcode_session
test_spawn_relaunch_appends_second_row
test_spawn_unresolvable_writes_nothing
test_capture_happy_path_records_and_prints_id
test_capture_retries_a_transient_miss
test_capture_gives_up_with_diagnostic_no_row
test_capture_skips_unreadable_harness_without_noise
test_session_start_records_sentinel
test_teardown_preserves_ledger
