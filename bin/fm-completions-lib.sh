#!/usr/bin/env bash
# Append-only completion ledger format owner. Sourced by bin/fm-teardown.sh at the
# authoritative completion point. NEVER executed directly.
#
# The ledger is a durable, never-pruned record of every task that reaches teardown,
# so the work-report skill can query precise ticket-completion data instead of
# falling back to imprecise git-commit heuristics. Unlike the backlog Done-history
# retention (which trims to the most recent entries), this file is NEVER pruned.
#
# Storage: data/completions.tsv, one entry per line, tab-separated:
#   <id>\t<closed-ts>\t<kind>\t<repo>\t<landing-sha>
# where <closed-ts> is a full ISO-8601 UTC timestamp (date +%Y-%m-%dT%H:%M:%SZ),
# <kind> is ship/scout/secondmate, <repo> is the project name or 'firstmate', and
# <landing-sha> is the merge/landing commit SHA when known, else empty. Comment
# lines start with '#'.
#
# BACKWARD COMPATIBILITY: rows appended before 2026-09 carry a bare date-only
# close field (YYYY-MM-DD) instead of a full timestamp. Historical rows are NEVER
# rewritten. Every reader that date-windows on this field must tolerate BOTH
# formats: normalize the field to its leading date with fm_completions_day (the
# first 10 characters), which is correct for a bare date and for a timestamp,
# then compare that day against the (whole-date) window bounds.
#
# Appends are atomic: a single line is written with one O_APPEND write, never a
# read-modify-write of the whole file, so a crash cannot corrupt earlier entries.
# Idempotency: if the same id + closed-DAY already ends the file, nothing is
# appended, so a retried teardown (which stamps a fresh timestamp seconds later)
# never double-records the same completion. The day is compared, not the exact
# timestamp, so a same-day retry still no-ops exactly as the date-only ledger did.
# A tab or newline in any field is rejected loudly rather than silently corrupting
# the tab-separated layout.

# True when a value is a safe single-line field (no tab, no newline). Empty is
# allowed only for the landing-sha column, which the caller passes through.
fm_completions_field_safe() {
  local v=$1
  case "$v" in
    *"	"*) return 1 ;;
  esac
  [ "$(printf '%s' "$v" | wc -l | tr -d ' ')" = 0 ] || return 1
  return 0
}

fm_completions_file() {
  local data_dir=$1
  printf '%s\n' "$data_dir/completions.tsv"
}

# Normalize a close field to its calendar day (YYYY-MM-DD). The field is either a
# bare date (legacy rows) or a full ISO-8601 UTC timestamp (rows appended from
# 2026-09 on); both begin with the 10-character date, so the leading 10 chars are
# the day in either case. This is the single dual-format normalizer every reader
# uses before date-windowing, so no reader hand-slices the column.
fm_completions_day() {
  printf '%s' "${1:0:10}"
}

# Append one completion line. Args: data_dir id closed_date kind repo landing_sha.
# landing_sha may be empty (unknown); every other field must be non-empty and safe.
# Returns non-zero without writing on any unsafe field or a write failure. When the
# same id + closed-DAY already ends the file, returns 0 without appending (the day
# is compared, not the exact timestamp, so a same-day retried teardown no-ops).
fm_completions_record() {
  local data_dir=$1 id=$2 closed_date=$3 kind=$4 repo=$5 landing_sha=$6 file line last f
  for f in "$id" "$closed_date" "$kind" "$repo"; do
    [ -n "$f" ] || { echo "completions: empty required field for '$id'" >&2; return 1; }
  done
  for f in "$id" "$closed_date" "$kind" "$repo" "$landing_sha"; do
    fm_completions_field_safe "$f" || { echo "completions: unsafe field for '$id'" >&2; return 1; }
  done
  mkdir -p "$data_dir" || return 1
  file=$(fm_completions_file "$data_dir")
  line=$(printf '%s\t%s\t%s\t%s\t%s' "$id" "$closed_date" "$kind" "$repo" "$landing_sha")
  if [ -f "$file" ]; then
    last=$(grep -vE '^[[:space:]]*(#|$)' "$file" | tail -1 || true)
    if [ -n "$last" ]; then
      local last_id last_date
      last_id=${last%%$'\t'*}
      last_date=${last#*$'\t'}
      last_date=${last_date%%$'\t'*}
      if [ "$last_id" = "$id" ] && [ "$(fm_completions_day "$last_date")" = "$(fm_completions_day "$closed_date")" ]; then
        return 0
      fi
    fi
  else
    printf '%s\n' \
      '# firstmate completion ledger: append-only, never pruned.' \
      '# Format: <id>\t<closed-ts>\t<kind>\t<repo>\t<landing-sha>' \
      '# Owned by bin/fm-completions-lib.sh; appended from bin/fm-teardown.sh.' \
      >> "$file" || return 1
  fi
  printf '%s\n' "$line" >> "$file" || return 1
  return 0
}

# Look up every recorded completion for an exact task id. Args: data_dir id.
# Prints one matching ledger line per completion (verbatim, tab-separated), in
# file order, and returns 0 when at least one match exists. Returns 1 without
# printing when the id has never reached teardown or the ledger is absent. The
# id is matched against the first tab-separated field only, so a substring of
# another id or a field value elsewhere on the line is never a false hit.
# Comment lines are skipped. This is the single read path for the pre-spawn
# duplicate-dispatch guard, so callers never hand-parse columns.
fm_completions_lookup() {
  local data_dir=$1 id=$2 file found=1 rec_id line
  file=$(fm_completions_file "$data_dir")
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    rec_id=${line%%$'\t'*}
    if [ "$rec_id" = "$id" ]; then
      printf '%s\n' "$line"
      found=0
    fi
  done < "$file"
  return "$found"
}
