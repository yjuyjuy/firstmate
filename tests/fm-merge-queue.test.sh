#!/usr/bin/env bash
# Tests for the durable merge queue (bin/fm-merge-queue-lib.sh, bin/fm-merge-queue.sh).
#
# The queue records ship branches that were released by teardown while pushed to
# origin but not yet merged, so a released-but-unmerged branch is never forgotten.
#
# Covers:
#   - record then list surfaces the entry as a compare link
#   - recording the same id twice replaces (not duplicates) the entry
#   - unsafe fields (embedded tab) are refused without writing
#   - remove drops one entry; count reflects the queue size
#   - sweep clears a branch merged into its base (content-in-base) and keeps an
#     unmerged one
#   - the merged check uses content-in-base, not a PR lookup, so it works for a
#     Bitbucket-style repo with no PR automation
#   - task ids are matched literally, so a dotted id cannot clobber another entry
#   - an entry whose head object is gone clears only when origin provably no longer
#     carries the branch, and is kept on an inconclusive probe
#   - a rewrite that would truncate the queue is refused, keeping the file intact
#   - record and remove fail rather than proceed unlocked when the lock is held
#   - a branch-gone sweep clears with distinct wording, never worded as a merge
#   - compare-url builds github and bitbucket links and falls back for unknown hosts
#   - auto-merge eligibility is an ORIGIN allowlist: an owned github.com/<owner>
#     clone is eligible, a Bitbucket product clone and a non-owned github clone are
#     skipped, and a missing/originless clone is skipped (fail closed)
#   - the dispatch plan groups the queue by clone and classifies each as
#     eligible/below-threshold/skip, keeping product repos off the eligible list
#   - the dispatch CLI prints a dry plan and spawns nothing by default, and
#     --execute spawns one worker only per eligible clone, never for a product repo
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=bin/fm-merge-queue-lib.sh disable=SC1091
. "$ROOT/bin/fm-merge-queue-lib.sh"
CLI="$ROOT/bin/fm-merge-queue.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-queue-tests)

# Re-source the lib so a test that stubs one of its functions cannot leak that stub
# into later tests.
restore_lib() {
  # shellcheck source=bin/fm-merge-queue-lib.sh disable=SC1091
  . "$ROOT/bin/fm-merge-queue-lib.sh"
}

run_cli() {
  local data=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$data" "$CLI" "$@"
}

test_record_and_list() {
  local data="$TMP_ROOT/rl/data"
  mkdir -p "$data"
  fm_merge_queue_record "$data" task-a /proj fm/a deadbeef main \
    'https://github.com/o/r/compare/main...fm/a' || fail "record failed"
  out=$(run_cli "$data" list)
  printf '%s\n' "$out" | grep -F 'task-a' >/dev/null || fail "list missing id: $out"
  printf '%s\n' "$out" | grep -F 'compare/main...fm/a' >/dev/null || fail "list missing url: $out"
  pass "record then list surfaces the entry as a compare link"
}

test_record_replaces_same_id() {
  local data="$TMP_ROOT/replace/data"
  mkdir -p "$data"
  fm_merge_queue_record "$data" task-b /proj fm/b c1 main url1
  fm_merge_queue_record "$data" task-b /proj fm/b c2 main url2
  local n
  n=$(run_cli "$data" count)
  [ "$n" = 1 ] || fail "expected 1 entry after re-record, got $n"
  run_cli "$data" list --raw | grep -F 'c2' >/dev/null || fail "re-record did not update head"
  run_cli "$data" list --raw | grep -F 'c1' >/dev/null && fail "old entry survived re-record"
  pass "recording the same id twice replaces the entry"
}

test_unsafe_field_refused() {
  local data="$TMP_ROOT/unsafe/data"
  mkdir -p "$data"
  local bad
  bad=$(printf 'fm/%s\tx' bad)
  if fm_merge_queue_record "$data" task-c /proj "$bad" c1 main url 2>/dev/null; then
    fail "record accepted a tab-bearing field"
  fi
  [ ! -f "$data/merge-queue.tsv" ] || {
    grep -q task-c "$data/merge-queue.tsv" && fail "unsafe record was written"
  }
  pass "unsafe field with an embedded tab is refused without writing"
}

test_remove_and_count() {
  local data="$TMP_ROOT/rm/data"
  mkdir -p "$data"
  fm_merge_queue_record "$data" task-d /proj fm/d c1 main url
  fm_merge_queue_record "$data" task-e /proj fm/e c2 main url
  [ "$(run_cli "$data" count)" = 2 ] || fail "expected 2 before remove"
  run_cli "$data" remove task-d >/dev/null
  [ "$(run_cli "$data" count)" = 1 ] || fail "expected 1 after remove"
  run_cli "$data" list --raw | grep -F task-e >/dev/null || fail "wrong entry removed"
  pass "remove drops one entry; count reflects the queue size"
}

# Build a bare origin + clone with a task branch pushed. Echoes "<origin> <clone>".
make_repo_with_pushed_branch() {
  local dir=$1 branch=$2
  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/seed" 2>/dev/null
  git -C "$dir/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
  git -C "$dir/seed" push -q origin main
  rm -rf "$dir/seed"
  git clone -q "$dir/origin.git" "$dir/clone"
  git -C "$dir/clone" checkout -q -b "$branch"
  printf '%s\n' feature > "$dir/clone/feature.txt"
  git -C "$dir/clone" add -- feature.txt
  git -C "$dir/clone" -c user.email=t@t -c user.name=t commit -q -m "work on $branch"
  git -C "$dir/clone" push -q origin "$branch"
}

test_sweep_clears_merged_keeps_unmerged() {
  local data="$TMP_ROOT/sweep/data" repo="$TMP_ROOT/sweep/repo"
  mkdir -p "$data" "$repo"
  make_repo_with_pushed_branch "$repo" fm/merged
  local head
  head=$(git -C "$repo/clone" rev-parse HEAD)
  # Land the branch content into origin/main (fast-forward merge).
  git -C "$repo/clone" push -q origin HEAD:main
  fm_merge_queue_record "$data" task-m "$repo/clone" fm/merged "$head" main url-m
  # A second, genuinely unmerged branch.
  make_repo_with_pushed_branch "$repo/u" fm/open
  local uhead
  uhead=$(git -C "$repo/u/clone" rev-parse HEAD)
  fm_merge_queue_record "$data" task-o "$repo/u/clone" fm/open "$uhead" main url-o
  run_cli "$data" sweep >/dev/null
  run_cli "$data" list --raw | grep -F task-m >/dev/null && fail "merged branch not swept"
  run_cli "$data" list --raw | grep -F task-o >/dev/null || fail "unmerged branch wrongly swept"
  pass "sweep clears a merged branch and keeps an unmerged one"
}

test_sweep_uses_content_not_pr_lookup() {
  # A squash-style landing: base gains a commit with the same net content but a
  # different commit id; the branch tip is NOT an ancestor of base. content-in-base
  # must still recognize it as merged, with no PR machinery involved.
  local data="$TMP_ROOT/squash/data" repo="$TMP_ROOT/squash/repo"
  mkdir -p "$data" "$repo"
  make_repo_with_pushed_branch "$repo" fm/squash
  local head
  head=$(git -C "$repo/clone" rev-parse HEAD)
  # Land equivalent content on main via a distinct commit.
  git clone -q "$repo/origin.git" "$repo/land"
  printf '%s\n' feature > "$repo/land/feature.txt"
  git -C "$repo/land" add -- feature.txt
  git -C "$repo/land" -c user.email=t@t -c user.name=t commit -q -m "squash feature"
  git -C "$repo/land" push -q origin HEAD:main
  fm_merge_queue_record "$data" task-s "$repo/clone" fm/squash "$head" main url-s
  run_cli "$data" sweep >/dev/null
  run_cli "$data" list --raw | grep -F task-s >/dev/null && fail "content-merged branch not swept"
  pass "sweep merged check uses content-in-base, not a PR lookup"
}

test_id_is_matched_literally() {
  # A task id may contain '.', which is a regex metacharacter: matching it as a
  # pattern would let 'a.b' delete an unrelated 'aXb' entry.
  local data="$TMP_ROOT/literal/data"
  mkdir -p "$data"
  fm_merge_queue_record "$data" aXb /proj fm/x c1 main url-x
  fm_merge_queue_record "$data" a.b /proj fm/dot c2 main url-dot
  [ "$(run_cli "$data" count)" = 2 ] || fail "re-record with a dotted id clobbered another entry"
  run_cli "$data" remove a.b >/dev/null
  run_cli "$data" list --raw | grep -F aXb >/dev/null || fail "remove of a dotted id took the wrong entry"
  [ "$(run_cli "$data" count)" = 1 ] || fail "expected 1 entry after removing the dotted id"
  pass "task ids are matched literally, so a dotted id cannot clobber another entry"
}

test_sweep_clears_when_head_gone_and_branch_deleted() {
  # After teardown the local branch is gone; a pruning fetch plus gc can drop the
  # last copy of the head object for a branch the forge deleted on merge. The entry
  # must clear rather than stick forever.
  local data="$TMP_ROOT/gone/data" repo="$TMP_ROOT/gone/repo"
  mkdir -p "$data" "$repo"
  make_repo_with_pushed_branch "$repo" fm/gone
  local head
  head=$(git -C "$repo/clone" rev-parse HEAD)
  git -C "$repo/origin.git" update-ref -d refs/heads/fm/gone
  fm_merge_queue_record "$data" task-g "$repo/clone" fm/gone 0000000000000000000000000000000000000000 main url-g
  run_cli "$data" sweep >/dev/null
  run_cli "$data" list --raw | grep -F task-g >/dev/null && fail "unresolvable head with deleted branch not swept"
  [ -n "$head" ] || fail "fixture head unset"
  pass "sweep clears an entry whose head is gone and whose branch no longer exists on origin"
}

test_sweep_keeps_when_head_gone_but_branch_alive() {
  # Same unresolvable head, but the branch still exists on origin: that is not
  # evidence of a merge, so the entry must be kept.
  local data="$TMP_ROOT/alive/data" repo="$TMP_ROOT/alive/repo"
  mkdir -p "$data" "$repo"
  make_repo_with_pushed_branch "$repo" fm/alive
  fm_merge_queue_record "$data" task-a2 "$repo/clone" fm/alive 0000000000000000000000000000000000000000 main url-a
  run_cli "$data" sweep >/dev/null
  run_cli "$data" list --raw | grep -F task-a2 >/dev/null || fail "entry cleared while its branch still exists on origin"
  pass "sweep keeps an entry whose head is gone while the branch still exists on origin"
}

test_sweep_keeps_when_origin_unreachable() {
  # Inconclusive probe (origin URL points nowhere): never clear on an unverifiable
  # claim.
  local data="$TMP_ROOT/unreach/data" repo="$TMP_ROOT/unreach/repo"
  mkdir -p "$data" "$repo"
  make_repo_with_pushed_branch "$repo" fm/unreach
  git -C "$repo/clone" remote set-url origin "$repo/does-not-exist.git"
  fm_merge_queue_record "$data" task-u "$repo/clone" fm/unreach 0000000000000000000000000000000000000000 main url-u
  run_cli "$data" sweep >/dev/null
  run_cli "$data" list --raw | grep -F task-u >/dev/null || fail "entry cleared on an unreachable origin"
  pass "sweep keeps an entry when the origin probe is inconclusive"
}

test_remove_refuses_short_rewrite() {
  # A truncated rewrite would erase every other queued branch, the worst possible
  # failure for a guard whose whole purpose is that nothing is forgotten.
  local data="$TMP_ROOT/short/data"
  mkdir -p "$data"
  fm_merge_queue_record "$data" task-s1 /proj fm/s1 c1 main url-1
  fm_merge_queue_record "$data" task-s2 /proj fm/s2 c2 main url-2
  local before
  before=$(cat "$data/merge-queue.tsv")
  fm_merge_queue_drop_id() { printf ''; }
  if fm_merge_queue_remove "$data" task-s1 2>/dev/null; then
    restore_lib
    fail "remove accepted a truncating rewrite"
  fi
  restore_lib
  [ "$(cat "$data/merge-queue.tsv")" = "$before" ] || fail "queue was modified by a refused remove"
  pass "remove refuses a short rewrite and keeps the queue intact"
}

test_lock_timeout_fails_closed() {
  # An unlocked read-modify-write can lose an entry, so a lock that cannot be taken
  # must fail the record and the remove rather than proceed racy.
  local data="$TMP_ROOT/lock/data"
  mkdir -p "$data"
  fm_merge_queue_record "$data" task-l1 /proj fm/l1 c1 main url-l1
  fm_merge_queue_lock() { return 1; }
  if fm_merge_queue_record "$data" task-l2 /proj fm/l2 c2 main url-l2 2>/dev/null; then
    restore_lib
    fail "record proceeded without the lock"
  fi
  if fm_merge_queue_remove "$data" task-l1 2>/dev/null; then
    restore_lib
    fail "remove proceeded without the lock"
  fi
  restore_lib
  run_cli "$data" list --raw | grep -F task-l1 >/dev/null || fail "existing entry lost by a refused write"
  run_cli "$data" list --raw | grep -F task-l2 >/dev/null && fail "entry recorded despite a refused lock"
  pass "record and remove fail closed when the queue lock cannot be taken"
}

test_sweep_branch_gone_wording_is_distinct() {
  # Clearing because origin no longer carries the branch is NOT a verified merge and
  # must never read like one.
  local data="$TMP_ROOT/wording/data" repo="$TMP_ROOT/wording/repo" out
  mkdir -p "$data" "$repo"
  make_repo_with_pushed_branch "$repo" fm/word
  git -C "$repo/origin.git" update-ref -d refs/heads/fm/word
  fm_merge_queue_record "$data" task-w "$repo/clone" fm/word 0000000000000000000000000000000000000000 main url-w
  out=$(run_cli "$data" sweep)
  printf '%s\n' "$out" | grep -F 'merge unverified' >/dev/null || fail "branch-gone sweep missing distinct wording: $out"
  printf '%s\n' "$out" | grep -F 'merged into' >/dev/null && fail "branch-gone sweep claimed a merge: $out"
  pass "sweep reports a branch-gone clear distinctly from a verified merge"
}

test_compare_url_hosts() {
  local u
  u=$(fm_merge_queue_compare_url 'git@github.com:yjuyjuy/firstmate.git' main fm/x)
  [ "$u" = 'https://github.com/yjuyjuy/firstmate/compare/main...fm/x' ] || fail "github ssh url wrong: $u"
  u=$(fm_merge_queue_compare_url 'https://github.com/o/r.git' main fm/x)
  [ "$u" = 'https://github.com/o/r/compare/main...fm/x' ] || fail "github https url wrong: $u"
  u=$(fm_merge_queue_compare_url 'git@bitbucket.org:team/hyfin.git' develop fm/y)
  [ "$u" = 'https://bitbucket.org/team/hyfin/branch/fm/y?dest=develop' ] || fail "bitbucket url wrong: $u"
  u=$(fm_merge_queue_compare_url 'git@example.com:o/r.git' main fm/z)
  case "$u" in *'fm/z'*'main'*) : ;; *) fail "unknown host fallback missing branch/base: $u" ;; esac
  pass "compare-url builds github and bitbucket links and falls back for unknown hosts"
}

# Make a bare git repo that stands in for a clone with a chosen origin URL. The
# eligibility gate only reads `git remote get-url origin`, so a directory that is
# a git repo with that origin set is a sufficient fixture - no commits needed.
# Echoes the clone dir path.
make_clone_with_origin() {
  local dir=$1 origin=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$origin"
  printf '%s\n' "$dir"
}

test_repo_auto_mergeable_owned_github() {
  local base="$TMP_ROOT/elig-owned" clone
  clone=$(make_clone_with_origin "$base/firstmate" 'git@github.com:yjuyjuy/firstmate.git')
  local out rc=0
  out=$(fm_merge_queue_repo_auto_mergeable "$clone") || rc=$?
  [ "$rc" -eq 0 ] || fail "owned github clone not eligible (rc=$rc): $out"
  case "$out" in eligible:*) : ;; *) fail "owned github reason not 'eligible:': $out" ;; esac
  pass "auto-merge eligibility accepts an owned github.com tooling fork"
}

test_repo_auto_mergeable_skips_bitbucket_product() {
  # The hard captain rule: a Bitbucket dashnow product repo is NEVER eligible.
  local base="$TMP_ROOT/elig-bb" clone
  clone=$(make_clone_with_origin "$base/hyfin-server" 'git@bitbucket.org:dashnow/hyfin-server.git')
  local out rc=0
  out=$(fm_merge_queue_repo_auto_mergeable "$clone") || rc=$?
  [ "$rc" -eq 1 ] || fail "bitbucket product clone was NOT skipped (rc=$rc): $out"
  case "$out" in skip:*) : ;; *) fail "bitbucket product reason not 'skip:': $out" ;; esac
  pass "auto-merge eligibility skips a Bitbucket product repo (hard captain rule)"
}

test_repo_auto_mergeable_skips_unowned_github() {
  # A github.com repo under a different owner is not ours to merge.
  local base="$TMP_ROOT/elig-unowned" clone
  clone=$(make_clone_with_origin "$base/paseo" 'git@github.com:getpaseo/paseo.git')
  local rc=0
  fm_merge_queue_repo_auto_mergeable "$clone" >/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "non-owned github clone was NOT skipped (rc=$rc)"
  pass "auto-merge eligibility skips a github repo under an owner we do not own"
}

test_repo_auto_mergeable_fails_closed_on_missing_clone() {
  # A missing clone path cannot be verified as ours, so it must be skipped, never
  # eligible. This is the fail-closed guarantee.
  local rc=0
  fm_merge_queue_repo_auto_mergeable "$TMP_ROOT/does-not-exist-clone" >/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "missing clone was treated as eligible (rc=$rc)"
  rc=0
  # An originless git repo is likewise unverifiable -> skip.
  local noremote="$TMP_ROOT/noremote"
  mkdir -p "$noremote"; git -C "$noremote" init -q
  fm_merge_queue_repo_auto_mergeable "$noremote" >/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "originless clone was treated as eligible (rc=$rc)"
  pass "auto-merge eligibility fails closed on a missing or originless clone"
}

test_repo_auto_mergeable_owner_override() {
  # The owned owner is configurable via FM_MERGE_QUEUE_OWNED_GITHUB_OWNER so a
  # differently-forked fleet is not hard-wired to one owner.
  local base="$TMP_ROOT/elig-override" clone rc=0
  clone=$(make_clone_with_origin "$base/tool" 'https://github.com/acme/tool.git')
  FM_MERGE_QUEUE_OWNED_GITHUB_OWNER=acme fm_merge_queue_repo_auto_mergeable "$clone" >/dev/null || rc=$?
  [ "$rc" -eq 0 ] || fail "override owner clone not eligible (rc=$rc)"
  rc=0
  # yjuyjuy is now NOT the owned owner, so an old yjuyjuy clone is skipped.
  local other
  other=$(make_clone_with_origin "$base/other" 'git@github.com:yjuyjuy/firstmate.git')
  FM_MERGE_QUEUE_OWNED_GITHUB_OWNER=acme fm_merge_queue_repo_auto_mergeable "$other" >/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "non-override owner clone was eligible (rc=$rc)"
  pass "auto-merge eligibility honors the owned-owner override both ways"
}

test_dispatch_plan_groups_and_classifies() {
  # Build a queue spanning one owned tooling clone (2 branches), one Bitbucket
  # product clone (1 branch), and one non-owned github clone (1 branch). The plan
  # must group by clone, mark only the owned one eligible, and skip the rest.
  local data="$TMP_ROOT/plan/data" base="$TMP_ROOT/plan/repos"
  mkdir -p "$data"
  local tool prod unowned
  tool=$(make_clone_with_origin "$base/firstmate" 'git@github.com:yjuyjuy/firstmate.git')
  prod=$(make_clone_with_origin "$base/hyfin-server" 'git@bitbucket.org:dashnow/hyfin-server.git')
  unowned=$(make_clone_with_origin "$base/paseo" 'git@github.com:getpaseo/paseo.git')
  fm_merge_queue_record "$data" t1 "$tool" fm/t1 c1 main url1
  fm_merge_queue_record "$data" t2 "$tool" fm/t2 c2 main url2
  fm_merge_queue_record "$data" p1 "$prod" fm/p1 c3 dev url3
  fm_merge_queue_record "$data" u1 "$unowned" fm/u1 c4 main url4
  local plan
  plan=$(fm_merge_queue_dispatch_plan "$data" 1)
  # Owned tooling clone: eligible with count 2.
  printf '%s\n' "$plan" | grep -F "$(printf 'eligible\t%s\t2' "$tool")" >/dev/null \
    || fail "owned clone not eligible with count 2: $plan"
  # Product clone: skip, never eligible.
  printf '%s\n' "$plan" | grep -F "$(printf 'skip\t%s' "$prod")" >/dev/null \
    || fail "product clone not marked skip: $plan"
  printf '%s\n' "$plan" | grep -E "^eligible	$prod	" >/dev/null \
    && fail "product clone wrongly marked eligible: $plan"
  # Non-owned github clone: skip.
  printf '%s\n' "$plan" | grep -F "$(printf 'skip\t%s' "$unowned")" >/dev/null \
    || fail "non-owned clone not marked skip: $plan"
  pass "dispatch plan groups by clone and marks only owned tooling eligible"
}

test_dispatch_plan_below_threshold() {
  # A single queued branch on an owned clone is eligible only at min_batch 1; at
  # min_batch 2 it becomes below-threshold, not skip (still ours, just not a batch).
  local data="$TMP_ROOT/thresh/data" base="$TMP_ROOT/thresh/repos" tool
  mkdir -p "$data"
  tool=$(make_clone_with_origin "$base/no-mistakes" 'git@github.com:yjuyjuy/no-mistakes.git')
  fm_merge_queue_record "$data" o1 "$tool" fm/o1 c1 main url1
  local plan
  plan=$(fm_merge_queue_dispatch_plan "$data" 2)
  printf '%s\n' "$plan" | grep -E "^below-threshold	$tool	1" >/dev/null \
    || fail "single owned branch not below-threshold at min_batch 2: $plan"
  plan=$(fm_merge_queue_dispatch_plan "$data" 1)
  printf '%s\n' "$plan" | grep -E "^eligible	$tool	1" >/dev/null \
    || fail "single owned branch not eligible at min_batch 1: $plan"
  pass "dispatch plan holds an eligible clone below the batch threshold rather than skipping it"
}

# Run the dispatch CLI through a shim bin dir: every real bin entry is symlinked
# in so the CLI's sourced libs resolve, then a fake fm-spawn.sh is overlaid so an
# execute run records its invocations instead of launching anything real. Echoes
# the shim CLI path so a caller can invoke "<shim>/fm-merge-queue.sh".
build_dispatch_shim_bin() {
  local shimbin=$1 spawnlog=$2 f
  mkdir -p "$shimbin"
  for f in "$ROOT"/bin/*.sh; do
    ln -sf "$f" "$shimbin/$(basename "$f")"
  done
  rm -f "$shimbin/fm-spawn.sh"
  cat > "$shimbin/fm-spawn.sh" <<SPAWN
#!/usr/bin/env bash
printf 'SPAWN %s\n' "\$*" >> "$spawnlog"
echo "spawned \$1 (fake)"
SPAWN
  chmod +x "$shimbin/fm-spawn.sh"
  printf '%s\n' "$shimbin"
}

test_dispatch_cli_dry_run_spawns_nothing() {
  local data="$TMP_ROOT/cli-dry/data" home="$TMP_ROOT/cli-dry/home" base="$TMP_ROOT/cli-dry/repos"
  mkdir -p "$data" "$home/state" "$home/config"
  local tool prod
  tool=$(make_clone_with_origin "$base/firstmate" 'git@github.com:yjuyjuy/firstmate.git')
  prod=$(make_clone_with_origin "$base/hyfin-server" 'git@bitbucket.org:dashnow/hyfin-server.git')
  fm_merge_queue_record "$data" c1 "$tool" fm/c1 s1 main url1
  fm_merge_queue_record "$data" c2 "$prod" fm/c2 s2 dev url2
  local out
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_DATA_OVERRIDE="$data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    "$CLI" dispatch 2>&1)
  printf '%s\n' "$out" | grep -F 'DISPATCH' | grep -F "$tool" >/dev/null \
    || fail "dry plan did not mark the owned clone for dispatch: $out"
  printf '%s\n' "$out" | grep -F 'SKIP' | grep -F "$prod" >/dev/null \
    || fail "dry plan did not mark the product clone skip: $out"
  printf '%s\n' "$out" | grep -F 'Dry run' >/dev/null || fail "dry plan missing dry-run notice: $out"
  # No worker metadata may have been written for either clone.
  local m meta_found=0
  for m in "$home"/state/*.meta; do
    [ -e "$m" ] && meta_found=1
  done
  [ "$meta_found" -eq 0 ] || fail "dry run left task metadata behind"
  pass "dispatch dry run prints the plan and spawns nothing"
}

test_dispatch_cli_execute_spawns_only_eligible() {
  # --execute must spawn a worker for the owned clone and NEVER for the product
  # clone. fm-spawn.sh is shimmed so nothing real launches.
  local data="$TMP_ROOT/cli-exec/data" home="$TMP_ROOT/cli-exec/home" base="$TMP_ROOT/cli-exec/repos"
  local shimbin="$TMP_ROOT/cli-exec/shimbin" spawnlog="$TMP_ROOT/cli-exec/spawn.log"
  mkdir -p "$data" "$home/state" "$home/config"
  : > "$spawnlog"
  build_dispatch_shim_bin "$shimbin" "$spawnlog" >/dev/null
  local tool prod
  tool=$(make_clone_with_origin "$base/firstmate" 'git@github.com:yjuyjuy/firstmate.git')
  prod=$(make_clone_with_origin "$base/hyfin-server" 'git@bitbucket.org:dashnow/hyfin-server.git')
  fm_merge_queue_record "$data" e1 "$tool" fm/e1 s1 main url1
  fm_merge_queue_record "$data" e2 "$tool" fm/e2 s2 main url2
  fm_merge_queue_record "$data" e3 "$prod" fm/e3 s3 dev url3
  local out
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_DATA_OVERRIDE="$data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    "$shimbin/fm-merge-queue.sh" dispatch --execute 2>&1)
  # Exactly one spawn, for the owned tooling clone.
  local spawn_count
  spawn_count=$(grep -c '^SPAWN ' "$spawnlog" || true)
  [ "$spawn_count" = 1 ] || fail "expected exactly 1 spawn, got $spawn_count: $(cat "$spawnlog")"
  grep -F "$tool" "$spawnlog" >/dev/null || fail "owned clone was not spawned: $(cat "$spawnlog")"
  grep -F "$prod" "$spawnlog" >/dev/null && fail "PRODUCT clone was spawned - hard rule violated: $(cat "$spawnlog")"
  printf '%s\n' "$out" | grep -F '1 worker(s) spawned' >/dev/null || fail "execute summary wrong: $out"
  # The worker's brief was written and embeds ONLY the owned clone's branches.
  local brief b
  brief=
  for b in "$data"/merge-batch-firstmate-*/brief.md; do
    [ -e "$b" ] && { brief=$b; break; }
  done
  [ -n "$brief" ] || fail "no merge-worker brief written"
  grep -F 'fm/e1' "$brief" >/dev/null || fail "brief missing owned branch fm/e1"
  grep -F 'fm/e2' "$brief" >/dev/null || fail "brief missing owned branch fm/e2"
  grep -F 'fm/e3' "$brief" >/dev/null && fail "brief leaked a product branch fm/e3"
  grep -F 'yjuyjuy/firstmate' "$brief" >/dev/null || fail "brief missing the owned slug"
  pass "dispatch --execute spawns only the eligible tooling clone, never the product repo"
}

test_dispatch_cli_execute_requires_harness_with_dispatch_profile() {
  # When a crew-dispatch profile file is active, --execute without --harness must
  # refuse, mirroring fm-spawn.sh, so the profile is never silently skipped.
  local data="$TMP_ROOT/cli-harness/data" home="$TMP_ROOT/cli-harness/home" base="$TMP_ROOT/cli-harness/repos"
  mkdir -p "$data" "$home/state" "$home/config"
  printf '{}\n' > "$home/config/crew-dispatch.json"
  local tool
  tool=$(make_clone_with_origin "$base/firstmate" 'git@github.com:yjuyjuy/firstmate.git')
  fm_merge_queue_record "$data" h1 "$tool" fm/h1 s1 main url1
  local rc=0
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_DATA_OVERRIDE="$data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    "$CLI" dispatch --execute >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "execute did not refuse a missing harness under an active dispatch profile"
  pass "dispatch --execute refuses without --harness when a crew-dispatch profile is active"
}

# --- Problem A: squash/rebase merge the content check cannot recognize --------

# Build a clone whose branch was squash-merged into main AND whose base later
# touched the same file, so merge-tree returns CONFLICT and the content-in-base
# check is INCONCLUSIVE. This is the case that keeps an entry queued forever.
# Echoes "<repo-root> <clone> <head>".
make_squash_then_base_touch() {
  local dir=$1 branch=$2
  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/seed"
  git -C "$dir/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
  printf 'line1\n' > "$dir/seed/shared.txt"
  git -C "$dir/seed" add -- shared.txt
  git -C "$dir/seed" -c user.email=t@t -c user.name=t commit -q -m addshared
  git -C "$dir/seed" push -q origin main
  rm -rf "$dir/seed"
  git clone -q "$dir/origin.git" "$dir/clone"
  git -C "$dir/clone" checkout -q -b "$branch"
  printf 'line1\nfeature\n' > "$dir/clone/shared.txt"
  git -C "$dir/clone" add -- shared.txt
  git -C "$dir/clone" -c user.email=t@t -c user.name=t commit -q -m "work on $branch"
  git -C "$dir/clone" push -q origin "$branch"
  local head
  head=$(git -C "$dir/clone" rev-parse HEAD)
  # Land equivalent content on main via a distinct (squash-style) commit.
  git clone -q "$dir/origin.git" "$dir/land"
  printf 'line1\nfeature\n' > "$dir/land/shared.txt"
  git -C "$dir/land" add -- shared.txt
  git -C "$dir/land" -c user.email=t@t -c user.name=t commit -q -m "squash feature"
  git -C "$dir/land" push -q origin HEAD:main
  # Base LATER touches the same file, so merge-tree of the old branch conflicts.
  printf 'line1\nfeature\nbaselater\n' > "$dir/land/shared.txt"
  git -C "$dir/land" add -- shared.txt
  git -C "$dir/land" -c user.email=t@t -c user.name=t commit -q -m "base later touches shared"
  git -C "$dir/land" push -q origin HEAD:main
  printf '%s %s %s\n' "$dir" "$dir/clone" "$head"
}

test_content_check_inconclusive_on_squash_then_base_touch() {
  # Guard the premise of Problem A: the content-in-base check itself must be
  # inconclusive (kept) for this fixture, so the forge-confirmed path is what
  # actually clears it below. If git ever recognizes this as merged directly,
  # this test tells us the premise changed.
  local repo="$TMP_ROOT/premise/repo" out clone head
  mkdir -p "$repo"
  out=$(make_squash_then_base_touch "$repo" fm/premise)
  read -r _ clone head <<EOF
$out
EOF
  local rc=0
  fm_merge_queue_branch_merged "$clone" fm/premise "$head" main || rc=$?
  [ "$rc" -ne 0 ] || fail "content check unexpectedly recognized the squash+base-touch case as merged"
  [ "$rc" != "$FM_MERGE_QUEUE_BRANCH_GONE" ] || fail "premise wrong: branch is gone, not merely inconclusive"
  pass "content-in-base check is inconclusive for a squash merge the base later touched"
}

# A fake gh-axi that answers `api repos/<slug>/commits/<sha>/pulls` from a table
# of merged shas. Writes its argv to a log for assertions.
build_fake_gh_axi() {
  local bindir=$1 merged_sha=$2 log=$3
  mkdir -p "$bindir"
  cat > "$bindir/gh-axi" <<GH
#!/usr/bin/env bash
printf 'GHAXI %s\n' "\$*" >> "$log"
# Only the commits/<sha>/pulls merged-count query is emulated.
path=
for a in "\$@"; do
  case "\$a" in repos/*/commits/*/pulls) path=\$a ;; esac
done
if [ -n "\$path" ]; then
  sha=\${path#*/commits/}
  sha=\${sha%/pulls}
  if [ "\$sha" = "$merged_sha" ]; then echo 1; else echo 0; fi
  exit 0
fi
exit 1
GH
  chmod +x "$bindir/gh-axi"
}

test_sweep_forge_confirms_squash_merge_github() {
  # The content check is inconclusive (squash + base touch), but the forge (gh-axi)
  # confirms the head's PR is merged, so the entry must clear.
  local data="$TMP_ROOT/forge-gh/data" repo="$TMP_ROOT/forge-gh/repo"
  local bindir="$TMP_ROOT/forge-gh/bin" log="$TMP_ROOT/forge-gh/gh.log"
  mkdir -p "$data"
  : > "$log"
  local out clone head
  out=$(make_squash_then_base_touch "$repo" fm/gh-squash)
  read -r _ clone head <<EOF
$out
EOF
  # Point the clone origin at an owned GitHub slug so the forge path engages.
  git -C "$clone" remote set-url origin 'git@github.com:yjuyjuy/tool.git'
  build_fake_gh_axi "$bindir" "$head" "$log"
  fm_merge_queue_record "$data" task-gh "$clone" fm/gh-squash "$head" main \
    "https://github.com/yjuyjuy/tool/compare/main...fm/gh-squash"
  local sweep_out
  sweep_out=$(PATH="$bindir:$PATH" run_cli "$data" sweep)
  printf '%s\n' "$sweep_out" | grep -F 'task-gh' >/dev/null || fail "forge-confirmed sweep said nothing about task-gh: $sweep_out"
  run_cli "$data" list --raw | grep -F task-gh >/dev/null && fail "forge-confirmed squash merge not swept: $(run_cli "$data" list --raw)"
  grep -F "commits/$head/pulls" "$log" >/dev/null || fail "sweep did not query the forge for the head's merged PR: $(cat "$log")"
  pass "sweep clears a squash merge the content check missed once the forge confirms it merged"
}

test_sweep_keeps_when_forge_says_not_merged() {
  # Same inconclusive content check, but the forge does NOT confirm a merge (no
  # merged PR for this head): the entry must be KEPT, never cleared on a guess.
  local data="$TMP_ROOT/forge-keep/data" repo="$TMP_ROOT/forge-keep/repo"
  local bindir="$TMP_ROOT/forge-keep/bin" log="$TMP_ROOT/forge-keep/gh.log"
  mkdir -p "$data"
  : > "$log"
  local out clone head
  out=$(make_squash_then_base_touch "$repo" fm/gh-open)
  read -r _ clone head <<EOF
$out
EOF
  git -C "$clone" remote set-url origin 'git@github.com:yjuyjuy/tool.git'
  # The fake reports merged only for a DIFFERENT sha, so this head is not merged.
  build_fake_gh_axi "$bindir" 0000000000000000000000000000000000000000 "$log"
  fm_merge_queue_record "$data" task-open "$clone" fm/gh-open "$head" main \
    "https://github.com/yjuyjuy/tool/compare/main...fm/gh-open"
  PATH="$bindir:$PATH" run_cli "$data" sweep >/dev/null
  run_cli "$data" list --raw | grep -F task-open >/dev/null || fail "entry wrongly cleared when the forge did not confirm a merge"
  pass "sweep keeps an inconclusive entry when the forge does not confirm a merge"
}

test_sweep_content_fallback_still_works_without_forge() {
  # With NO forge automation available (gh-axi absent), a genuine content-in-base
  # squash landing must STILL sweep via the fallback content check. This proves
  # the forge path is an ADDITION, not a replacement.
  local data="$TMP_ROOT/fallback/data" repo="$TMP_ROOT/fallback/repo"
  local emptybin="$TMP_ROOT/fallback/bin"
  mkdir -p "$data" "$emptybin"
  make_repo_with_pushed_branch "$repo" fm/fb-squash
  local head
  head=$(git -C "$repo/clone" rev-parse HEAD)
  git clone -q "$repo/origin.git" "$repo/land"
  printf '%s\n' feature > "$repo/land/feature.txt"
  git -C "$repo/land" add -- feature.txt
  git -C "$repo/land" -c user.email=t@t -c user.name=t commit -q -m "squash feature"
  git -C "$repo/land" push -q origin HEAD:main
  fm_merge_queue_record "$data" task-fb "$repo/clone" fm/fb-squash "$head" main url-fb
  # A bare git-only PATH: no gh-axi, no curl, so no forge automation exists.
  local gitbin
  gitbin=$(dirname "$(command -v git)")
  PATH="$emptybin:$gitbin" run_cli "$data" sweep >/dev/null
  run_cli "$data" list --raw | grep -F task-fb >/dev/null && fail "content-fallback squash landing not swept without forge automation"
  pass "content-in-base fallback still clears a clean squash landing when no forge automation is available"
}

# --- Problem B: queue-vs-live-meta drift -------------------------------------

test_reconcile_refreshes_stale_head_from_live_meta() {
  # A queue entry carries a STALE head while a live state/<id>.meta records a
  # NEWER pr_head. Reconcile must refresh the queued head to the meta's pr_head so
  # the merged check runs against the commit that actually landed.
  local data="$TMP_ROOT/drift/data" state="$TMP_ROOT/drift/state"
  mkdir -p "$data" "$state"
  local newhead=1111111111111111111111111111111111111111
  fm_merge_queue_record "$data" task-d /proj fm/d 0000000000000000000000000000000000000000 main url-d
  fm_write_meta "$state/task-d.meta" "window=fm:0" "worktree=/wt" "pr=https://x/pull/1" "pr_head=$newhead"
  fm_merge_queue_reconcile_drift "$data" "$state" >/dev/null
  run_cli "$data" list --raw | grep -F "$newhead" >/dev/null || fail "reconcile did not refresh the stale head: $(run_cli "$data" list --raw)"
  run_cli "$data" list --raw | grep -F '0000000000000000000000000000000000000000' >/dev/null \
    && fail "reconcile left the stale head in the queue"
  [ "$(run_cli "$data" count)" = 1 ] || fail "reconcile changed the entry count"
  pass "drift reconcile refreshes a stale queued head from the live meta's newer pr_head"
}

test_reconcile_no_meta_leaves_entry_untouched() {
  # No live meta for the id: reconcile must leave the entry exactly as recorded.
  local data="$TMP_ROOT/drift-none/data" state="$TMP_ROOT/drift-none/state"
  mkdir -p "$data" "$state"
  fm_merge_queue_record "$data" task-n /proj fm/n abc123abc123abc123abc123abc123abc123abcd main url-n
  local before
  before=$(run_cli "$data" list --raw)
  fm_merge_queue_reconcile_drift "$data" "$state" >/dev/null
  [ "$(run_cli "$data" list --raw)" = "$before" ] || fail "reconcile modified an entry with no live meta"
  pass "drift reconcile leaves an entry with no live meta untouched"
}

test_reconcile_same_head_is_noop() {
  # The live meta's pr_head equals the queued head: nothing to refresh.
  local data="$TMP_ROOT/drift-same/data" state="$TMP_ROOT/drift-same/state"
  mkdir -p "$data" "$state"
  local h=abc123abc123abc123abc123abc123abc123abcd
  fm_merge_queue_record "$data" task-s "$data" fm/s "$h" main url-s
  fm_write_meta "$state/task-s.meta" "pr_head=$h"
  local before
  before=$(run_cli "$data" list --raw)
  fm_merge_queue_reconcile_drift "$data" "$state" >/dev/null
  [ "$(run_cli "$data" list --raw)" = "$before" ] || fail "reconcile rewrote an entry whose head already matched"
  pass "drift reconcile is a no-op when the live meta pr_head equals the queued head"
}

test_sweep_runs_reconcile_first() {
  # sweep must reconcile drift before its merged checks, so a stale head that
  # never sweeps is refreshed to the live pr_head in the same pass.
  local data="$TMP_ROOT/drift-sweep/data" state="$TMP_ROOT/drift-sweep/state"
  mkdir -p "$data" "$state"
  local newhead=2222222222222222222222222222222222222222
  fm_merge_queue_record "$data" task-ds /proj fm/ds 0000000000000000000000000000000000000000 main url-ds
  fm_write_meta "$state/task-ds.meta" "pr_head=$newhead"
  FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$data" FM_STATE_OVERRIDE="$state" "$CLI" sweep >/dev/null
  FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$data" FM_STATE_OVERRIDE="$state" "$CLI" list --raw \
    | grep -F "$newhead" >/dev/null || fail "sweep did not reconcile the stale head before its merged checks"
  pass "sweep reconciles queue-vs-meta drift before running its merged checks"
}


test_record_and_list
test_record_replaces_same_id
test_unsafe_field_refused
test_remove_and_count
test_sweep_clears_merged_keeps_unmerged
test_sweep_uses_content_not_pr_lookup
test_id_is_matched_literally
test_sweep_clears_when_head_gone_and_branch_deleted
test_sweep_keeps_when_head_gone_but_branch_alive
test_sweep_keeps_when_origin_unreachable
test_remove_refuses_short_rewrite
test_lock_timeout_fails_closed
test_sweep_branch_gone_wording_is_distinct
test_compare_url_hosts
test_repo_auto_mergeable_owned_github
test_repo_auto_mergeable_skips_bitbucket_product
test_repo_auto_mergeable_skips_unowned_github
test_repo_auto_mergeable_fails_closed_on_missing_clone
test_repo_auto_mergeable_owner_override
test_dispatch_plan_groups_and_classifies
test_dispatch_plan_below_threshold
test_dispatch_cli_dry_run_spawns_nothing
test_dispatch_cli_execute_spawns_only_eligible
test_dispatch_cli_execute_requires_harness_with_dispatch_profile
test_content_check_inconclusive_on_squash_then_base_touch
test_sweep_forge_confirms_squash_merge_github
test_sweep_keeps_when_forge_says_not_merged
test_sweep_content_fallback_still_works_without_forge
test_reconcile_refreshes_stale_head_from_live_meta
test_reconcile_no_meta_leaves_entry_untouched
test_reconcile_same_head_is_noop
test_sweep_runs_reconcile_first