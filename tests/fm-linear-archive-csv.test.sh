#!/usr/bin/env bash
# Behavior tests for bin/fm-linear-archive-csv.py - the DEV-46 done-archive to
# Linear CSV converter.
#
# The converter drives a ONE-SHOT import of ~1.4k issues into Linear that would
# be tedious to undo, so these cases pin the properties a reviewer has to trust
# before the captain uploads anything:
#   (a) grammar: headers, bullets, indented continuations, bullet-less headers
#   (b) nothing is silently dropped - an unclassifiable line is reported, and
#       --strict makes it a non-zero exit
#   (c) an orphan indented block (real captain-decision text with no task line)
#       becomes an archive-note issue instead of vanishing
#   (d) the CSV header is exactly the subset Linear's importer reads, and the
#       Archived column is never emitted (a non-empty Archived makes the
#       importer skip the row)
#   (e) every description carries the fm-meta duplicate-detection marker, whose
#       key is stable across runs and distinct for a reused task id
#   (f) date semantics: Completed is the archive header date, Created is the
#       earliest in-body date signal and never later than Completed
#   (g) determinism: two runs over the same input produce byte-identical CSV
#   (h) CSV safety: embedded commas, quotes, and newlines round-trip through a
#       real CSV reader, and a formula-leading cell is escaped Linear-style
#   (i) an optional pass over a REAL archive when FM_DEV46_ARCHIVE points at
#       one. The archive is a fleet's private operational history and is never
#       committed here, so this case is skipped rather than failed when unset;
#       every other case runs on generated fixtures and needs no fleet data.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONV="$ROOT/bin/fm-linear-archive-csv.py"
TMP_ROOT=$(fm_test_tmproot fm-linear-archive-csv)

if ! command -v python3 >/dev/null 2>&1; then
  echo "skip: python3 not found"
  exit 0
fi

# A small archive exercising every shape the real file contains.
write_sample() {  # <path>
  cat > "$1" <<'MD'
## Archived 2026-07-13
- [x] alpha-task - Ship the alpha thing (repo: alpha-repo) (kind: ship) (done 2026-07-11)
  follow-up note on the alpha thing

## Archived 2026-07-14
- [x] beta-task - Investigate, "quoted", and comma, separated (repo: beta-repo) (kind: scout) (reported 2026-07-12)

## Archived 2026-07-15

## Archived 2026-07-16
- [x] gamma-task - No metadata at all
- [x] delta-task - Second bullet under one header (kind: captain)
MD
}

# --- (a)(d)(e) basic conversion shape ---------------------------------------

test_basic_shape() {
  local dir=$TMP_ROOT/basic
  mkdir -p "$dir"
  write_sample "$dir/archive.md"
  python3 "$CONV" "$dir/archive.md" --csv "$dir/out.csv" --quiet --strict \
    || fail "converter failed on the sample archive"

  local header
  header=$(head -1 "$dir/out.csv")
  [ "$header" = 'Id,Title,Description,Status,Priority,Project,Labels,Created,Completed' ] \
    || fail "unexpected CSV header: $header"
  assert_not_contains "$header" 'Archived' \
    "the Archived column must never be emitted (the importer skips rows that have one)"

  local rows
  rows=$(python3 - "$dir/out.csv" <<'PY'
import csv, sys
print(len(list(csv.DictReader(open(sys.argv[1])))))
PY
)
  [ "$rows" = 4 ] || fail "expected 4 issues from the sample, got $rows"
  pass "basic shape: exact Linear column set, no Archived column, one row per task"
}

test_every_row_carries_fm_meta() {
  local dir=$TMP_ROOT/meta
  mkdir -p "$dir"
  write_sample "$dir/archive.md"
  python3 "$CONV" "$dir/archive.md" --csv "$dir/out.csv" --quiet

  local missing
  missing=$(python3 - "$dir/out.csv" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
print(sum(1 for r in rows if "fm-meta: v1 id=" not in r["Description"]))
PY
)
  [ "$missing" = 0 ] || fail "$missing rows have no fm-meta marker"

  local keys
  keys=$(python3 "$CONV" "$dir/archive.md" --keys)
  assert_contains "$keys" 'fm-meta: v1 id=alpha-task' "keys output must carry the task id"
  assert_contains "$keys" 'digest=' "keys output must carry a content digest"
  pass "fm-meta: every description carries the duplicate-detection marker"
}

test_fm_meta_key_is_stable_and_distinguishes_reused_ids() {
  local dir=$TMP_ROOT/keys
  mkdir -p "$dir"
  write_sample "$dir/archive.md"
  local first second
  first=$(python3 "$CONV" "$dir/archive.md" --keys)
  second=$(python3 "$CONV" "$dir/archive.md" --keys)
  [ "$first" = "$second" ] || fail "fm-meta keys are not stable across runs"

  # The same task id archived twice with different bodies (the real archive has
  # 9 such ids) must not collide, or a re-import check would treat one as the
  # other.
  cat > "$dir/dup.md" <<'MD'
## Archived 2026-07-13
- [x] same-id - first run of this lane

## Archived 2026-07-20
- [x] same-id - second, different run of the same lane
MD
  local digests
  digests=$(python3 "$CONV" "$dir/dup.md" --keys | sed 's/.*digest=//' | sort -u | wc -l)
  [ "$digests" -eq 2 ] || fail "a reused task id must still produce distinct fm-meta digests"
  pass "fm-meta key is stable across runs and distinct for a reused task id"
}

# --- (f) date semantics -----------------------------------------------------

test_date_semantics() {
  local dir=$TMP_ROOT/dates
  mkdir -p "$dir"
  write_sample "$dir/archive.md"
  python3 "$CONV" "$dir/archive.md" --csv "$dir/out.csv" --quiet

  local out
  out=$(python3 - "$dir/out.csv" <<'PY'
import csv, sys
rows = {r["Description"].split(":")[0][:5] or "x": r for r in []}
rows = list(csv.DictReader(open(sys.argv[1])))
by_id = {r["Description"].split("id=")[1].split()[0]: r for r in rows}
a = by_id["alpha-task"]
g = by_id["gamma-task"]
print(a["Created"], a["Completed"], g["Created"], g["Completed"])
print(sum(1 for r in rows if r["Created"] > r["Completed"]))
PY
)
  local line1 inverted
  line1=$(printf '%s\n' "$out" | sed -n 1p)
  inverted=$(printf '%s\n' "$out" | sed -n 2p)
  [ "$line1" = '2026-07-11 2026-07-13 2026-07-16 2026-07-16' ] \
    || fail "unexpected dates: $line1"
  [ "$inverted" = 0 ] || fail "$inverted rows have Created later than Completed"
  pass "dates: Completed is the archive date, Created is the earliest body date, never inverted"
}

# --- (b)(c) nothing is dropped ----------------------------------------------

test_unparsed_line_is_reported_and_strict_fails() {
  local dir=$TMP_ROOT/unparsed
  mkdir -p "$dir"
  cat > "$dir/archive.md" <<'MD'
## Archived 2026-07-13
- [x] alpha-task - fine

this line belongs to no task and no header shape
MD
  local out rc
  out=$(python3 "$CONV" "$dir/archive.md" --csv "$dir/out.csv" --summary "$dir/sum.md" 2>&1)
  rc=$?
  expect_code 0 "$rc" "an unparsed line alone must not fail without --strict"
  assert_contains "$out" '1 unparsed lines' "the stderr report must count unparsed lines"
  assert_grep 'this line belongs to no task' "$dir/sum.md" \
    "the summary must quote every unparsed line verbatim"

  out=$(python3 "$CONV" "$dir/archive.md" --csv "$dir/out.csv" --strict 2>&1)
  rc=$?
  expect_code 2 "$rc" "--strict must fail on an unparsed line"
  assert_contains "$out" 'unparsed L4' "--strict must name the offending line number"
  pass "an unclassifiable line is reported, never dropped, and --strict fails on it"
}

test_orphan_indented_block_becomes_an_archive_note() {
  local dir=$TMP_ROOT/orphan
  mkdir -p "$dir"
  cat > "$dir/archive.md" <<'MD'
## Archived 2026-07-24
- [x] alpha-task - fine

## Archived 2026-07-24

  Captain decision:
  # Decision: fee base on a partly-paid record
  the ruling body
MD
  python3 "$CONV" "$dir/archive.md" --csv "$dir/out.csv" --quiet --strict \
    || fail "an orphan indented block must convert clean under --strict"

  local out
  out=$(python3 - "$dir/out.csv" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
note = [r for r in rows if "kind:archive-note" in r["Labels"]]
print(len(rows), len(note))
print(note[0]["Title"])
print("body-kept" if "the ruling body" in note[0]["Description"] else "BODY-LOST")
PY
)
  assert_contains "$out" '2 1' "the orphan block must add exactly one archive-note issue"
  assert_contains "$out" 'Archive note 2026-07-24: Decision: fee base on a partly-paid record' \
    "the note title must come from its own Markdown heading"
  assert_contains "$out" 'body-kept' "the note body must survive into the description"
  pass "an orphan indented block becomes an archive-note issue instead of vanishing"
}

test_bulletless_header_adds_no_issue() {
  local dir=$TMP_ROOT/empty
  mkdir -p "$dir"
  cat > "$dir/archive.md" <<'MD'
## Archived 2026-07-13

## Archived 2026-07-14
- [x] alpha-task - only real task
MD
  python3 "$CONV" "$dir/archive.md" --csv "$dir/out.csv" --summary "$dir/sum.md" --quiet --strict \
    || fail "a bullet-less header must convert clean"
  # Count with a real CSV reader: every description spans several physical
  # lines (the fm-meta marker sits on its own line), so `wc -l` would lie.
  local rows
  rows=$(python3 - "$dir/out.csv" <<'PY'
import csv, sys
print(len(list(csv.DictReader(open(sys.argv[1])))))
PY
)
  [ "$rows" -eq 1 ] || fail "a bullet-less header must contribute no issue, got $rows rows"
  assert_grep '1 with no task' "$dir/sum.md" "the summary must count bullet-less headers"
  pass "a bullet-less archive header contributes no issue and is counted"
}

# --- (h) CSV safety ---------------------------------------------------------

test_csv_quoting_round_trips() {
  local dir=$TMP_ROOT/quoting
  mkdir -p "$dir"
  write_sample "$dir/archive.md"
  python3 "$CONV" "$dir/archive.md" --csv "$dir/out.csv" --quiet

  local out
  out=$(python3 - "$dir/out.csv" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
beta = [r for r in rows if "id=beta-task" in r["Description"]][0]
alpha = [r for r in rows if "id=alpha-task" in r["Description"]][0]
print("quote-kept" if '"quoted"' in beta["Description"] else "QUOTE-LOST")
print("comma-kept" if "comma, separated" in beta["Description"] else "COMMA-LOST")
print("continuation-kept" if "follow-up note" in alpha["Description"] else "CONTINUATION-LOST")
print("newline-kept" if "\n" in alpha["Description"] else "NEWLINE-LOST")
PY
)
  assert_contains "$out" 'quote-kept' "an embedded double quote must round-trip"
  assert_contains "$out" 'comma-kept' "an embedded comma must round-trip"
  assert_contains "$out" 'continuation-kept' "an indented continuation must land in the description"
  assert_contains "$out" 'newline-kept' "a multi-line description must round-trip as one cell"
  pass "CSV quoting: commas, quotes, and newlines survive a real CSV reader"
}

test_formula_leading_cell_is_escaped() {
  local dir=$TMP_ROOT/formula
  mkdir -p "$dir"
  cat > "$dir/archive.md" <<'MD'
## Archived 2026-07-13
- [x] =danger - =SUM(A1:A9) looks like a formula
MD
  python3 "$CONV" "$dir/archive.md" --csv "$dir/out.csv" --quiet
  local out
  out=$(python3 - "$dir/out.csv" <<'PY'
import csv, sys
row = list(csv.DictReader(open(sys.argv[1])))[0]
print("escaped" if row["Title"].startswith("'=") else "NOT-ESCAPED " + row["Title"][:20])
PY
)
  assert_contains "$out" 'escaped' "a formula-leading title must carry Linear's leading apostrophe"
  pass "a formula-leading cell is escaped the way Linear's own export escapes it"
}

# --- (g) determinism --------------------------------------------------------

test_determinism() {
  local dir=$TMP_ROOT/determinism
  mkdir -p "$dir"
  write_sample "$dir/archive.md"
  python3 "$CONV" "$dir/archive.md" --csv "$dir/a.csv" --quiet
  python3 "$CONV" "$dir/archive.md" --csv "$dir/b.csv" --quiet
  cmp -s "$dir/a.csv" "$dir/b.csv" || fail "two runs over the same archive must be byte-identical"
  pass "conversion is deterministic across runs"
}

# --- labels and titles ------------------------------------------------------

test_labels_and_titles() {
  local dir=$TMP_ROOT/labels
  mkdir -p "$dir"
  write_sample "$dir/archive.md"
  python3 "$CONV" "$dir/archive.md" --csv "$dir/out.csv" --quiet
  local out
  out=$(python3 - "$dir/out.csv" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
by = {r["Description"].split("id=")[1].split()[0]: r for r in rows}
print(by["alpha-task"]["Labels"])
print(by["gamma-task"]["Labels"])
print(by["alpha-task"]["Title"])
print(by["alpha-task"]["Status"])
PY
)
  assert_contains "$out" 'fm-archive, repo:alpha-repo, kind:ship' "labels must carry repo and kind"
  assert_contains "$out" 'alpha-task: Ship the alpha thing' "the title must prefix the task id"
  assert_not_contains "$out" 'alpha-task: Ship the alpha thing (repo' \
    "trailing metadata parens must be stripped from the title"
  assert_contains "$out" 'Done' "the default Status must be Done"
  pass "labels carry repo and kind, titles keep the task id and drop metadata parens"
}

test_long_title_is_truncated() {
  local dir=$TMP_ROOT/longtitle
  mkdir -p "$dir"
  {
    printf '## Archived 2026-07-13\n'
    printf -- '- [x] long-task - '
    for _ in $(seq 1 60); do printf 'wordy '; done
    printf '\n'
  } > "$dir/archive.md"
  python3 "$CONV" "$dir/archive.md" --csv "$dir/out.csv" --quiet
  local len
  len=$(python3 - "$dir/out.csv" <<'PY'
import csv, sys
print(len(list(csv.DictReader(open(sys.argv[1])))[0]["Title"]))
PY
)
  [ "$len" -le 120 ] || fail "a long title must be truncated to 120 characters, got $len"
  local full
  full=$(python3 - "$dir/out.csv" <<'PY'
import csv, sys
row = list(csv.DictReader(open(sys.argv[1])))[0]
print("full-body-kept" if row["Description"].count("wordy") == 60 else "BODY-TRUNCATED")
PY
)
  assert_contains "$full" 'full-body-kept' "truncating the title must never truncate the description"
  pass "a long title is truncated while the description keeps the full body"
}

test_status_and_project_overrides() {
  local dir=$TMP_ROOT/overrides
  mkdir -p "$dir"
  write_sample "$dir/archive.md"
  python3 "$CONV" "$dir/archive.md" --csv "$dir/out.csv" --quiet \
    --status 'Completed' --project 'Fleet archive'
  local out
  out=$(python3 - "$dir/out.csv" <<'PY'
import csv, sys
row = list(csv.DictReader(open(sys.argv[1])))[0]
print(row["Status"], "|", row["Project"])
PY
)
  assert_contains "$out" 'Completed | Fleet archive' "--status and --project must reach the CSV"
  pass "--status and --project override the defaults"
}

test_usage_errors() {
  local rc out
  out=$(python3 "$CONV" 2>&1); rc=$?
  expect_code 1 "$rc" "no arguments must exit 1"
  assert_contains "$out" 'Usage:' "no arguments must print the header"

  out=$(python3 "$CONV" /nonexistent/archive.md --csv /dev/null 2>&1); rc=$?
  expect_code 1 "$rc" "an unreadable archive must exit 1"
  assert_contains "$out" 'cannot read archive' "an unreadable archive must say so"

  local dir=$TMP_ROOT/usage
  mkdir -p "$dir"
  write_sample "$dir/archive.md"
  out=$(python3 "$CONV" "$dir/archive.md" 2>&1); rc=$?
  expect_code 1 "$rc" "no output flag must exit 1"
  assert_contains "$out" 'nothing to do' "no output flag must explain what is missing"

  out=$(python3 "$CONV" --help 2>&1); rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" 'fm-meta' "--help must document the duplicate marker"
  pass "usage errors are explicit and exit non-zero"
}

# --- (i) an optional real archive -------------------------------------------

test_real_archive_converts_clean() {
  local archive=${FM_DEV46_ARCHIVE:-}
  if [ -z "$archive" ]; then
    pass "real-archive pass skipped (set FM_DEV46_ARCHIVE to a done-archive to run it)"
    return 0
  fi
  [ -f "$archive" ] || fail "FM_DEV46_ARCHIVE points at a missing file: $archive"
  local dir=$TMP_ROOT/real out rc
  mkdir -p "$dir"
  out=$(python3 "$CONV" "$archive" --csv "$dir/out.csv" --summary "$dir/sum.md" --strict 2>&1)
  rc=$?
  expect_code 0 "$rc" "the real archive must convert with zero unparsed lines"
  assert_contains "$out" '0 unparsed lines' "the real archive must report no unparsed lines"

  local checks
  checks=$(python3 - "$dir/out.csv" <<'PY'
import csv, sys
csv.field_size_limit(10_000_000)
rows = list(csv.DictReader(open(sys.argv[1])))
ids = [r["Id"] for r in rows]
bad = [r for r in rows if not r["Title"] or "fm-meta: v1 id=" not in r["Description"]
       or not r["Completed"] or r["Created"] > r["Completed"]]
print(len(rows), len(set(ids)), len(bad))
PY
)
  local count uniq bad
  count=$(printf '%s' "$checks" | cut -d' ' -f1)
  uniq=$(printf '%s' "$checks" | cut -d' ' -f2)
  bad=$(printf '%s' "$checks" | cut -d' ' -f3)
  [ "$count" -gt 0 ] || fail "the real archive yielded no issues"
  [ "$count" = "$uniq" ] || fail "row Ids must be unique ($count rows, $uniq unique)"
  [ "$bad" = 0 ] || fail "$bad real-archive rows are missing a title, marker, or date"
  pass "the real archive converts clean: $count issues, unique ids, no malformed row"
}

test_basic_shape
test_every_row_carries_fm_meta
test_fm_meta_key_is_stable_and_distinguishes_reused_ids
test_date_semantics
test_unparsed_line_is_reported_and_strict_fails
test_orphan_indented_block_becomes_an_archive_note
test_bulletless_header_adds_no_issue
test_csv_quoting_round_trips
test_formula_leading_cell_is_escaped
test_determinism
test_labels_and_titles
test_long_title_is_truncated
test_status_and_project_overrides
test_usage_errors
test_real_archive_converts_clean

echo "all fm-linear-archive-csv tests passed"
