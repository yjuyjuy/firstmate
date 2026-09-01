#!/usr/bin/env bash
# Tests for the append-only completion ledger (bin/fm-completions-lib.sh) and its
# integration into bin/fm-teardown.sh.
#
# The ledger is a durable, never-pruned record of every task that reaches teardown,
# so the work-report skill can query precise ticket-completion data.
#
# Covers, per the build brief:
#   (a) a ship completion appends exactly one correct line
#   (b) a second completion appends a second line without disturbing the first
#   (c) idempotent no-double-append on a repeated identical completion
#   (d) an unknown landing-sha leaves the column empty, not the literal "unknown"
# Plus: unsafe (tab-containing) fields are refused without writing, and the teardown
# path appends one correct line at the authoritative completion point.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=bin/fm-completions-lib.sh disable=SC1091
. "$ROOT/bin/fm-completions-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-completions-tests)

# Count non-comment, non-blank entry lines in a ledger file.
entry_count() {
  grep -cvE '^[[:space:]]*(#|$)' "$1" 2>/dev/null || echo 0
}

test_ship_appends_one_line() {
  local data="$TMP_ROOT/a/data"
  mkdir -p "$data"
  fm_completions_record "$data" task-a 2026-08-06 ship firstmate deadbeef1234 \
    || fail "record failed"
  local file
  file=$(fm_completions_file "$data")
  [ -f "$file" ] || fail "ledger file not created"
  [ "$(entry_count "$file")" = 1 ] || fail "expected exactly 1 entry"
  local line
  line=$(grep -vE '^[[:space:]]*(#|$)' "$file")
  [ "$line" = "$(printf 'task-a\t2026-08-06\tship\tfirstmate\tdeadbeef1234')" ] \
    || fail "line content wrong: $line"
  pass "a ship completion appends exactly one correct line"
}

test_second_completion_appends_without_disturbing_first() {
  local data="$TMP_ROOT/b/data"
  mkdir -p "$data"
  fm_completions_record "$data" task-a 2026-08-06 ship firstmate sha-a
  fm_completions_record "$data" task-b 2026-08-06 scout alpha ''
  local file
  file=$(fm_completions_file "$data")
  [ "$(entry_count "$file")" = 2 ] || fail "expected 2 entries"
  grep -qF "$(printf 'task-a\t2026-08-06\tship\tfirstmate\tsha-a')" "$file" \
    || fail "first entry disturbed"
  grep -qF "$(printf 'task-b\t2026-08-06\tscout\talpha\t')" "$file" \
    || fail "second entry missing"
  pass "a second completion appends without disturbing the first"
}

test_idempotent_no_double_append() {
  local data="$TMP_ROOT/c/data"
  mkdir -p "$data"
  fm_completions_record "$data" task-a 2026-08-06 ship firstmate sha-a
  fm_completions_record "$data" task-a 2026-08-06 ship firstmate sha-a \
    || fail "repeat record returned non-zero"
  local file
  file=$(fm_completions_file "$data")
  [ "$(entry_count "$file")" = 1 ] || fail "repeated identical completion double-appended"
  pass "idempotent no-double-append on a repeated identical completion"
}

test_unknown_landing_sha_leaves_column_empty() {
  local data="$TMP_ROOT/d/data"
  mkdir -p "$data"
  fm_completions_record "$data" task-a 2026-08-06 ship alpha '' || fail "record failed"
  local file line
  file=$(fm_completions_file "$data")
  line=$(grep -vE '^[[:space:]]*(#|$)' "$file")
  [ "$line" = "$(printf 'task-a\t2026-08-06\tship\talpha\t')" ] \
    || fail "empty sha not represented as empty column: $line"
  printf '%s\n' "$line" | grep -qF 'unknown' && fail "literal 'unknown' leaked into ledger"
  pass "an unknown landing-sha leaves the column empty, not the literal 'unknown'"
}

test_unsafe_field_refused() {
  local data="$TMP_ROOT/unsafe/data"
  mkdir -p "$data"
  fm_completions_record "$data" "$(printf 'bad\tid')" 2026-08-06 ship firstmate '' \
    && fail "tab in id was not refused"
  local file
  file=$(fm_completions_file "$data")
  [ ! -f "$file" ] || [ "$(entry_count "$file")" = 0 ] \
    || fail "unsafe field wrote an entry"
  fm_completions_record "$data" task-a 2026-08-06 ship "$(printf 're\tpo')" '' \
    && fail "tab in repo was not refused"
  pass "unsafe (tab-containing) fields are refused without writing"
}

test_idempotency_only_on_trailing_entry() {
  # Idempotency guards only the LAST entry: the same id completing again after
  # another task must still append (a genuinely distinct later completion).
  local data="$TMP_ROOT/trail/data"
  mkdir -p "$data"
  fm_completions_record "$data" task-a 2026-08-06 ship firstmate sha-a
  fm_completions_record "$data" task-b 2026-08-06 ship firstmate sha-b
  fm_completions_record "$data" task-a 2026-08-07 ship firstmate sha-a2
  local file
  file=$(fm_completions_file "$data")
  [ "$(entry_count "$file")" = 3 ] || fail "distinct later completion was suppressed"
  pass "idempotency guards only the trailing entry, not the whole file"
}

# --- teardown integration ---

# Build a project clone (origin + a pushed ship branch) and a linked worktree, then
# run fm-teardown with a fakebin treehouse/tmux stub (mirroring tests/fm-teardown.test.sh)
# and assert exactly one correct ledger line was appended at the completion point.
test_teardown_appends_ledger_line() {
  command -v git >/dev/null 2>&1 || { echo "skip: git not found"; return 0; }
  local base="$TMP_ROOT/td"
  local origin="$base/origin.git" proj="$base/proj" wt="$base/wt"
  local state="$base/state" data="$base/data" config="$base/config" fakebin="$base/fakebin"
  mkdir -p "$state" "$data" "$config" "$fakebin"

  # Stubs: treehouse return and tmux succeed silently; gh reports no PR (hermetic).
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
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
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh"

  git init -q --bare "$origin"
  git -C "$origin" symbolic-ref HEAD refs/heads/main
  git clone -q "$origin" "$proj" 2>/dev/null
  ( cd "$proj" || return 1
    git config user.email fmtest@example.invalid
    git config user.name fmtest
    echo seed > seed.txt
    git add seed.txt
    git commit --quiet -m seed
    git branch -M main
    git push -q origin main 2>/dev/null
    git remote set-head origin main 2>/dev/null || true
    git worktree add -q -b fm/task-td "$wt" main
  )
  ( cd "$wt" || return 1
    echo change > change.txt
    git add change.txt
    git commit --quiet -m change
    git push -q origin fm/task-td 2>/dev/null
  )
  local head
  head=$(git -C "$wt" rev-parse HEAD)

  cat > "$state/task-td.meta" <<EOF
window=fm-task-td
worktree=$wt
project=$proj
kind=ship
mode=direct-push
pr_head=$head
EOF
  touch "$state/task-td.status" "$state/.last-watcher-beat"

  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
    FM_CONFIG_OVERRIDE="$config" FM_DATA_OVERRIDE="$data" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-teardown.sh" task-td >/dev/null 2>&1 || true

  local file
  file=$(fm_completions_file "$data")
  [ -f "$file" ] || fail "teardown did not create the ledger"
  [ "$(entry_count "$file")" = 1 ] || fail "teardown appended other than 1 line"
  local line
  line=$(grep -vE '^[[:space:]]*(#|$)' "$file")
  case "$line" in
    "task-td	"*"	ship	proj	$head") : ;;
    *) fail "teardown ledger line wrong: $line" ;;
  esac
  # The close field must be a full ISO-8601 UTC timestamp (2026-09 format), not a
  # bare date: teardown now stamps the hour, not just the day.
  local close_field
  close_field=$(printf '%s' "$line" | cut -f2)
  case "$close_field" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) : ;;
    *) fail "teardown close field is not a full UTC timestamp: $close_field" ;;
  esac
  pass "teardown appends one correct ledger line with the landing sha"
}

# fm_completions_lookup is the single read path for the pre-spawn
# duplicate-dispatch guard (bin/fm-spawn.sh). It must: return 0 and print every
# matching line for a hit, return 1 without printing for a miss or an absent
# ledger, match the id against the first field only (no substring false hit),
# and skip comment lines.
test_lookup_hit_prints_line_and_succeeds() {
  local data="$TMP_ROOT/lk-hit/data" out
  mkdir -p "$data"
  fm_completions_record "$data" task-lk 2026-08-06 ship proj cafef00d || fail "record failed"
  out=$(fm_completions_lookup "$data" task-lk) || fail "lookup returned non-zero on a hit"
  case "$out" in
    "task-lk	2026-08-06	ship	proj	cafef00d") : ;;
    *) fail "lookup printed wrong line: $out" ;;
  esac
  pass "lookup returns 0 and prints the matching line on a hit"
}

test_lookup_miss_is_silent_and_fails() {
  local data="$TMP_ROOT/lk-miss/data" out status
  mkdir -p "$data"
  fm_completions_record "$data" task-present 2026-08-06 ship proj "" || fail "record failed"
  out=$(fm_completions_lookup "$data" task-absent)
  status=$?
  [ "$status" -ne 0 ] || fail "lookup returned 0 on a miss"
  [ -z "$out" ] || fail "lookup printed on a miss: $out"
  pass "lookup returns non-zero and prints nothing on a miss"
}

test_lookup_absent_ledger_fails() {
  local data="$TMP_ROOT/lk-none/data" status
  mkdir -p "$data"
  fm_completions_lookup "$data" anything
  status=$?
  [ "$status" -ne 0 ] || fail "lookup returned 0 with no ledger file"
  pass "lookup returns non-zero when the ledger is absent"
}

test_lookup_matches_first_field_only() {
  local data="$TMP_ROOT/lk-field/data" out status
  mkdir -p "$data"
  # The date field 'ship' would substring-match a naive scan; the id is exact.
  fm_completions_record "$data" build-batch 2026-08-06 ship build-batch-repo abc || fail "record failed"
  # A different id whose value appears in another column must not match.
  out=$(fm_completions_lookup "$data" build-batch-repo)
  status=$?
  [ "$status" -ne 0 ] || fail "lookup false-matched a value from a non-id column"
  [ -z "$out" ] || fail "lookup printed on a non-id-column match: $out"
  # The real id still matches.
  fm_completions_lookup "$data" build-batch >/dev/null || fail "lookup missed the exact id"
  pass "lookup matches the id field only, never a value from another column"
}

test_lookup_returns_all_matches() {
  local data="$TMP_ROOT/lk-multi/data" out count
  mkdir -p "$data"
  fm_completions_record "$data" task-multi 2026-08-06 ship proj aaa || fail "record 1 failed"
  fm_completions_record "$data" task-multi 2026-08-07 ship proj bbb || fail "record 2 failed"
  out=$(fm_completions_lookup "$data" task-multi) || fail "lookup failed on a multi-hit"
  count=$(printf '%s\n' "$out" | grep -c '^task-multi	')
  [ "$count" = 2 ] || fail "lookup returned $count matches, expected 2"
  pass "lookup returns every matching completion line"
}

# --- full-timestamp close field (2026-09 onward) + backward compatibility ---

test_day_helper_normalizes_both_formats() {
  [ "$(fm_completions_day 2026-08-06)" = 2026-08-06 ] \
    || fail "bare date not normalized to its day"
  [ "$(fm_completions_day 2026-08-06T01:35:29Z)" = 2026-08-06 ] \
    || fail "full timestamp not normalized to its day"
  pass "fm_completions_day returns the calendar day for a bare date and a full timestamp"
}

test_timestamp_close_field_stored_verbatim() {
  local data="$TMP_ROOT/ts/data" file line
  mkdir -p "$data"
  fm_completions_record "$data" task-ts 2026-09-01T01:35:29Z ship firstmate sha-ts \
    || fail "record with full timestamp failed"
  file=$(fm_completions_file "$data")
  line=$(grep -vE '^[[:space:]]*(#|$)' "$file")
  [ "$line" = "$(printf 'task-ts\t2026-09-01T01:35:29Z\tship\tfirstmate\tsha-ts')" ] \
    || fail "full timestamp not stored verbatim: $line"
  pass "a full-timestamp close field is stored verbatim on the new row"
}

test_idempotent_same_day_different_timestamp() {
  # A retried teardown stamps a fresh timestamp seconds later on the same day; the
  # dedup compares the DAY, so the second call must still no-op.
  local data="$TMP_ROOT/ts-idem/data" file
  mkdir -p "$data"
  fm_completions_record "$data" task-r 2026-09-01T01:35:29Z ship firstmate sha-r \
    || fail "first record failed"
  fm_completions_record "$data" task-r 2026-09-01T01:35:47Z ship firstmate sha-r \
    || fail "same-day retry returned non-zero"
  file=$(fm_completions_file "$data")
  [ "$(entry_count "$file")" = 1 ] || fail "same-day retried teardown double-appended"
  pass "a same-day retried teardown with a fresh timestamp still no-ops"
}

test_distinct_day_timestamp_appends() {
  # A genuinely later completion (next day) must still append, even timestamped.
  local data="$TMP_ROOT/ts-next/data" file
  mkdir -p "$data"
  fm_completions_record "$data" task-n 2026-09-01T23:59:00Z ship firstmate sha-1
  fm_completions_record "$data" task-n 2026-09-02T00:01:00Z ship firstmate sha-2
  file=$(fm_completions_file "$data")
  [ "$(entry_count "$file")" = 2 ] || fail "distinct-day later completion was suppressed"
  pass "a distinct-day later completion still appends with timestamps"
}

test_mixed_format_ledger_lookup() {
  # A ledger holding BOTH legacy date-only rows and new timestamped rows for one
  # id returns every matching line verbatim, unaffected by the field format.
  local data="$TMP_ROOT/ts-mixed/data" file out count
  mkdir -p "$data"
  file=$(fm_completions_file "$data")
  {
    printf '# firstmate completion ledger\n'
    printf 'task-mix\t2026-08-06\tship\tproj\told-sha\n'
    printf 'task-mix\t2026-09-01T01:35:29Z\tship\tproj\tnew-sha\n'
  } > "$file"
  out=$(fm_completions_lookup "$data" task-mix) || fail "lookup failed on mixed-format ledger"
  count=$(printf '%s\n' "$out" | grep -c '^task-mix	')
  [ "$count" = 2 ] || fail "mixed-format lookup returned $count matches, expected 2"
  pass "lookup reads a mixed legacy-and-timestamped ledger without error"
}

test_ship_appends_one_line
test_second_completion_appends_without_disturbing_first
test_idempotent_no_double_append
test_unknown_landing_sha_leaves_column_empty
test_unsafe_field_refused
test_idempotency_only_on_trailing_entry
test_teardown_appends_ledger_line
test_lookup_hit_prints_line_and_succeeds
test_lookup_miss_is_silent_and_fails
test_lookup_absent_ledger_fails
test_lookup_matches_first_field_only
test_lookup_returns_all_matches
test_day_helper_normalizes_both_formats
test_timestamp_close_field_stored_verbatim
test_idempotent_same_day_different_timestamp
test_distinct_day_timestamp_appends
test_mixed_format_ledger_lookup
