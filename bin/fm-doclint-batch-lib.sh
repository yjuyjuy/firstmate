#!/usr/bin/env bash
# Batched document+lint recovery pass: format, arithmetic, and marker-ref owner.
# Sourced by bin/fm-doclint-batch.sh (CLI) and tests. NEVER executed directly.
#
# WHY THIS EXISTS: small / doc-irrelevant lanes run
# `no-mistakes axi run --skip document,lint` to save the ~5.3 agent-hours that
# document+lint historically spent to earn only ~5 fixes across 138 changes
# (data/learnings.md anchor no-mistakes-cost-model). Skipping per-lane is
# correct, but the skipped lanes then get NO doc/lint at all, so drift and lint
# rot accumulate silently on a repo's dev. This is the cheap recovery half: run
# document+lint ONCE over the accumulated merged changes when a batch is big
# enough. See data/batch-doclint-pass/report.md for the full design.
#
# THE MARKER REF: refs/fm/doclint-base/<repo> is a durable per-repo ref, kept in
# the local clone, that records the dev commit the last pass covered. It only
# tracks provenance ("dev was doc/lint-clean as of this sha") and drives the
# threshold count; it does NOT drive no-mistakes' base (no-mistakes has no
# per-run base flag - see the report's "Key constraints"). Its advance discipline
# mirrors bin/fm-merge-queue-lib.sh: fail-closed, fast-forward-only, and it NEVER
# forces or deletes a ref (standing captain rule C1).
#
# THE THRESHOLD: a pass is "ready" when whichever fires first -
#   (a) FM_DOCLINT_LANE_THRESHOLD (default 8) landed ship lanes on the repo's dev
#       since the last pass, OR
#   (b) FM_DOCLINT_DAY_CEILING (default 14) days since the last pass with >= 1 lane.
# Count every landed ship lane since the last pass (no completions.tsv schema
# change); document/lint no-op on lanes that already ran them.

FM_DOCLINT_LANE_THRESHOLD_DEFAULT=8
FM_DOCLINT_DAY_CEILING_DEFAULT=14

# A repo name safe for a ref path and a shell field: git ref names forbid many
# characters, and this value is interpolated into refs/fm/doclint-base/<repo>.
fm_doclint_repo_safe() {  # <repo>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    .*|*..*) return 1 ;;
  esac
  return 0
}

fm_doclint_marker_ref() {  # <repo>
  printf 'refs/fm/doclint-base/%s\n' "$1"
}

# Read the marker sha for <repo>, or nothing when unset. Read-only.
fm_doclint_marker_read() {  # <project-dir> <repo>
  local project=$1 repo=$2 ref
  fm_doclint_repo_safe "$repo" || return 1
  [ -d "$project" ] || return 1
  ref=$(fm_doclint_marker_ref "$repo")
  git -C "$project" rev-parse --quiet --verify "$ref" 2>/dev/null || return 0
}

# Advance the marker to <sha>, fast-forward ONLY. Refuses (non-zero, no write) a
# backward move, a divergent move, an unsafe repo, an unknown sha, or a repo that
# is not a git dir. It NEVER passes --force and NEVER deletes the ref, so a wrong
# call can only be refused, never lose the recorded base (captain rule C1).
fm_doclint_marker_advance() {  # <project-dir> <repo> <sha>
  local project=$1 repo=$2 sha=$3 ref old
  fm_doclint_repo_safe "$repo" || { echo "doclint: unsafe repo '$repo'" >&2; return 1; }
  [ -n "$sha" ] || { echo "doclint: empty sha for $repo" >&2; return 1; }
  [ -d "$project" ] || { echo "doclint: no project dir $project" >&2; return 1; }
  git -C "$project" rev-parse --git-dir >/dev/null 2>&1 || {
    echo "doclint: $project is not a git repo" >&2; return 1; }
  git -C "$project" cat-file -e "$sha^{commit}" 2>/dev/null || {
    echo "doclint: unknown commit $sha in $project" >&2; return 1; }
  ref=$(fm_doclint_marker_ref "$repo")
  old=$(git -C "$project" rev-parse --quiet --verify "$ref" 2>/dev/null || true)
  if [ -n "$old" ]; then
    # Only a strict fast-forward: <sha> must be a descendant of the old marker,
    # and must not equal it (nothing to advance).
    if [ "$old" = "$sha" ]; then
      return 0
    fi
    if ! git -C "$project" merge-base --is-ancestor "$old" "$sha" 2>/dev/null; then
      echo "doclint: refusing non-fast-forward marker advance for $repo ($old -> $sha)" >&2
      return 1
    fi
    # git update-ref with an <oldvalue> is a compare-and-swap, never a force.
    git -C "$project" update-ref "$ref" "$sha" "$old" 2>/dev/null || {
      echo "doclint: marker advance CAS failed for $repo" >&2; return 1; }
  else
    # Create only when it does not already exist (oldvalue = zero).
    git -C "$project" update-ref "$ref" "$sha" "" 2>/dev/null || {
      echo "doclint: marker create failed for $repo" >&2; return 1; }
  fi
  return 0
}

# The ISO date of a commit (UTC, YYYY-MM-DD), or nothing when unknown.
fm_doclint_commit_date() {  # <project-dir> <sha>
  local project=$1 sha=$2
  [ -n "$sha" ] || return 0
  git -C "$project" show -s --format=%cd --date=format-local:%Y-%m-%d "$sha" 2>/dev/null || return 0
}

# Count landed ship lanes for <repo> in a completions.tsv, counting only entries
# whose closed-date is strictly AFTER <since-date>. An empty <since-date> means
# "no last pass", so every ship lane for the repo counts. Reads the append-only
# ledger format owned by bin/fm-completions-lib.sh: <id>\t<date>\t<kind>\t<repo>\t<sha>.
fm_doclint_count_since() {  # <completions-file> <repo> <since-date>
  local file=$1 repo=$2 since=$3
  [ -f "$file" ] || { printf '0'; return 0; }
  awk -F'\t' -v repo="$repo" -v since="$since" '
    /^[[:space:]]*#/ { next }
    NF < 4 { next }
    $3 != "ship" { next }
    $4 != repo { next }
    since != "" && $2 <= since { next }
    { n++ }
    END { printf "%d", n + 0 }
  ' "$file"
}

# The oldest ship-lane date for <repo> in the ledger, or nothing. Used only when
# no marker exists yet, to age the drift clock from the first un-doc/lint-ed lane.
fm_doclint_oldest_ship_date() {  # <completions-file> <repo>
  local file=$1 repo=$2
  [ -f "$file" ] || return 0
  awk -F'\t' -v repo="$repo" '
    /^[[:space:]]*#/ { next }
    NF < 4 { next }
    $3 != "ship" { next }
    $4 != repo { next }
    { if (oldest == "" || $2 < oldest) oldest = $2 }
    END { if (oldest != "") print oldest }
  ' "$file"
}

# Whole days between an ISO date (YYYY-MM-DD) and today (UTC). 0 when the date is
# empty or unparseable, so a missing base never fabricates drift.
fm_doclint_days_since() {  # <iso-date>
  local date=$1 epoch now
  [ -n "$date" ] || { printf '0'; return 0; }
  epoch=$(date -u -d "$date" +%s 2>/dev/null || printf '')
  [ -n "$epoch" ] || { printf '0'; return 0; }
  now=$(date -u +%s)
  printf '%d' $(( (now - epoch) / 86400 ))
}

# The active lane threshold and day ceiling, honoring env overrides with a
# fail-safe fall back to the defaults on a malformed value.
fm_doclint_lane_threshold() {
  local v=${FM_DOCLINT_LANE_THRESHOLD:-$FM_DOCLINT_LANE_THRESHOLD_DEFAULT}
  case "$v" in ''|*[!0-9]*|0) v=$FM_DOCLINT_LANE_THRESHOLD_DEFAULT ;; esac
  printf '%s' "$v"
}

fm_doclint_day_ceiling() {
  local v=${FM_DOCLINT_DAY_CEILING:-$FM_DOCLINT_DAY_CEILING_DEFAULT}
  case "$v" in ''|*[!0-9]*|0) v=$FM_DOCLINT_DAY_CEILING_DEFAULT ;; esac
  printf '%s' "$v"
}

# True (0) when a batch of <lanes> lanes accumulated over <days> days is ready:
# lanes >= the lane threshold, OR (days >= the day ceiling AND lanes >= 1).
# Zero lanes never fires, however old, so an already-clean repo never triggers.
fm_doclint_threshold_met() {  # <lanes> <days>
  local lanes=$1 days=$2 lane_t day_c
  case "$lanes" in ''|*[!0-9]*) return 1 ;; esac
  case "$days" in ''|*[!0-9]*) days=0 ;; esac
  [ "$lanes" -ge 1 ] || return 1
  lane_t=$(fm_doclint_lane_threshold)
  day_c=$(fm_doclint_day_ceiling)
  [ "$lanes" -ge "$lane_t" ] && return 0
  [ "$days" -ge "$day_c" ] && return 0
  return 1
}

# One status line for <repo>:
#   "<repo>: <N> lanes since <sha-or-none> (<days>d), threshold met=yes/no"
# Cheap and read-only: reads the marker ref and the ledger, computes nothing that
# touches the network. When no marker exists, counts every ship lane and ages
# from the oldest such lane.
fm_doclint_status() {  # <project-dir> <completions-file> <repo>
  local project=$1 comp=$2 repo=$3 marker since short lanes days met
  fm_doclint_repo_safe "$repo" || { echo "doclint: unsafe repo '$repo'" >&2; return 1; }
  marker=$(fm_doclint_marker_read "$project" "$repo" 2>/dev/null || true)
  if [ -n "$marker" ]; then
    since=$(fm_doclint_commit_date "$project" "$marker")
    short=$(printf '%s' "$marker" | cut -c1-12)
  else
    since=""
    short="none"
  fi
  lanes=$(fm_doclint_count_since "$comp" "$repo" "$since")
  if [ -n "$since" ]; then
    days=$(fm_doclint_days_since "$since")
  else
    days=$(fm_doclint_days_since "$(fm_doclint_oldest_ship_date "$comp" "$repo")")
  fi
  if fm_doclint_threshold_met "$lanes" "$days"; then met=yes; else met=no; fi
  printf '%s: %s lanes since %s (%sd), threshold met=%s\n' \
    "$repo" "$lanes" "$short" "$days" "$met"
}
