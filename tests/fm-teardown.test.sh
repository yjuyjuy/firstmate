#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh's landed-work safety and stale-lock recovery.
#
# The check refuses to tear down a worktree whose work has not LANDED, because
# treehouse return hard-resets the worktree. "Landed" means reachable from a remote
# OR - for a normal ship task whose commits are not so reachable - its PR is merged
# and GitHub reports a PR head that contains the current local work, or its content
# is already in the up-to-date default branch.
#
# "Landed" also covers CONTAINMENT: HEAD's exact commit already reachable from a
# default branch that outlives the worktree.
#
# Covers four fixes:
#   - local-only fork-remote: a fork IS a remote, so fork-pushed upstream-
#     contribution PRs are teardown-eligible (the pre-fix code false-refused them).
#   - squash-merge-then-delete-branch: the branch's own commits live nowhere on a
#     remote after a squash merge deletes the head branch, yet the change is fully in
#     main. Reachability alone false-refused this common GitHub flow; the check now
#     recognizes a merged PR head containing the local work (or the content already
#     in main) as landed.
#   - branch-name false refusal: the landed test matched on the local branch NAME,
#     so a lane that finished on a detached HEAD or a scratch branch, or that landed
#     by merging rather than by pushing that name, was refused even though its exact
#     commit was already in the default branch. Containment in a SURVIVING default
#     branch now counts; a standalone clone's own default branch still does not.
#   - teardown-lock-race: a killed crew process can leave a transient worktree
#     git index.lock that blocks teardown. The return path retries on the lock
#     error signature (even if the lock self-clears mid-check), then only removes a
#     provably stale lock before re-running safety checks.
#
# Matrix:
#   (a) local-only + HEAD on a fork remote-tracking branch     -> ALLOW  (fork fix)
#   (b) local-only + truly unpushed work (no remote, not main) -> REFUSE (safety)
#   (c) local-only + merged into local main, no remote         -> ALLOW  (no regression)
#   (d) no-mistakes + HEAD on origin remote-tracking branch    -> ALLOW  (no regression)
#   (e) no-mistakes + unpushed, no PR, content not in default  -> REFUSE (safety)
#   (f) local-only + truly unpushed + --force                  -> ALLOW  (escape hatch)
#   (g) no-mistakes + squash-merged PR, exact PR head          -> ALLOW  (squash fix)
#   (h) no-mistakes + no PR but content already in default     -> ALLOW  (content fallback)
#   (i) no-mistakes + dirty worktree, even when work landed     -> REFUSE (dirty wins)
#   (j) no-mistakes + gh lookup errors + content not in default -> REFUSE (fail-safe)
#   (k) no-mistakes + merged PR but HEAD moved afterward        -> REFUSE (stale PR)
#   (l) no-mistakes + stale origin/main but fetched content     -> ALLOW  (fresh fetch)
#   (m) no-mistakes + local HEAD ancestor of merged PR head     -> ALLOW  (lagging local)
#   (n) no-mistakes + replayed unpushed patch in merged PR head -> ALLOW  (replayed local)
#   (o) fm-pr-check rerun after HEAD moved                      -> no stale pr_head
#   (p) fm-pr-check when local HEAD lags                        -> record remote PR head
#   (q) no-mistakes + NO pr= recorded, PR discovered by branch  -> ALLOW  (yolo/no-CI merge)
#   (z) no-mistakes + branch pushed, unmerged, stale local ref   -> ALLOW  (release-on-pushed, queued)
#   (aa) no-mistakes + pushed base + extra unpushed local commit -> REFUSE (unpushed wins)
#   (bb) no-mistakes + pushed branch but dirty worktree          -> REFUSE (dirty wins)
#   (cc) no-mistakes + pushed branch but origin unreachable      -> REFUSE (unverifiable)
#   (dd) direct-push + detached HEAD at the origin default tip    -> ALLOW  (containment)
#   (ee) direct-push + scratch branch name at origin default tip  -> ALLOW  (containment)
#   (ff) direct-push + merged into the shared local default       -> ALLOW  (local landing)
#   (gg) no-mistakes + merged into the shared local default only  -> ALLOW  (local landing)
#   (hh) local default of a STANDALONE clone contains HEAD        -> REFUSE (ref dies with it)
#   (ii) contained in the default branch but dirty                -> REFUSE (dirty wins)
#   (jj) detached HEAD absent from every default branch           -> REFUSE (safety)
#   (kk) HEAD pushed to origin under a DIFFERENT branch name        -> ALLOW  (any origin ref)
#   (ll) direct-push + HEAD on origin under a different branch name -> ALLOW  (any origin ref)
#   (mm) HEAD reachable from origin's default branch via any ref    -> ALLOW  (any origin ref)
#   (nn) recorded branch absent + no origin ref contains HEAD       -> REFUSE (safety)
#
# Also covers backlog teardown-lock-race: a git index.lock left in the worktree by a
# killed crew process (bin/fm-teardown.sh's teardown_treehouse_return).
#   (r) provably-stale index.lock (old mtime, no live holder) -> lock removed, ALLOW
#   (s) index.lock with a live holder, any age                -> lock kept, REFUSE
#   (t) lsof error while checking index.lock                  -> lock kept, REFUSE
#   (u) dirty worktree after stale lock cleanup               -> lock removed, REFUSE
#   (v) non-linked repo index.lock                            -> lock removed, ALLOW
#   (w) index.lock mtime read failure                         -> lock kept, REFUSE
#   (x) transient lock cleared after first failed return      -> retry ALLOW
#   (y) persistent lock (never clears, not provably stale)    -> REFUSE loudly
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-tests)
REAL_GIT_FOR_TEST=$(command -v git)
export REAL_GIT_FOR_TEST

# Build a fresh sandbox for one test case. Sets up:
#   $CASE/state/        - firstmate state dir (with a fresh watcher beacon)
#   $CASE/fakebin/      - mocks for treehouse, tmux (PATH-prepended by caller)
#   $CASE/origin.git/   - bare upstream repo (so the project clone has origin)
#   $CASE/project/      - clone of origin; acts as the firstmate project dir
#   $CASE/wt/           - a worktree of the project (the task worktree)
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$fakebin"

  # Mocks for the post-check teardown steps. Refuse logic exits before these
  # run; the ALLOW cases need them so the script can complete cleanly.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# `treehouse return --force <wt>`: succeed silently.
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
# tmux kill-window etc.: succeed silently.
exit 0
SH
  # Default gh-axi mock: no PR is associated with the branch, and viewing any PR
  # number fails. This keeps the landed-work check hermetic (never reaching the real
  # gh-axi) and represents the common "no GitHub PR" baseline. Tests that need a
  # merged PR or a lookup error override this file with the helpers below.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh"

  # Bare origin so the clone has an `origin` remote and origin/HEAD.
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  # Seed origin with one commit BEFORE cloning so the clone is not empty.
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  # Clone as the project; give it a `main` branch and an origin/HEAD.
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  # Add a worktree on a fresh task branch; that branch is where the crewmate commits.
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  # Fresh watcher beacon so fm-guard stays quiet.
  touch "$case_dir/state/.last-watcher-beat"

  printf '%s\n' "$case_dir"
}

add_compatible_tasks_axi() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.1'
  exit 0
fi
if [ "${1:-}" = update ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi update <id> [flags]'
  printf '%s\n' '  --body-file <path>'
  printf '%s\n' '  --archive-body'
  exit 0
fi
if [ "${1:-}" = mv ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

# Compatible tasks-axi that also RECORDS every `tasks-axi done` invocation (one line
# per call, the full argument list) to $case_dir/tasks-axi-done.log, so the auto-close
# behavior can be asserted. Args: case_dir
add_recording_tasks_axi() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then printf '%s\n' '0.1.1'; exit 0; fi
if [ "\${1:-}" = update ] && [ "\${2:-}" = --help ]; then printf '%s\n' '  --archive-body'; exit 0; fi
if [ "\${1:-}" = mv ] && [ "\${2:-}" = --help ]; then printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <p>'; exit 0; fi
if [ "\${1:-}" = done ]; then printf '%s\n' "\$*" >> "$case_dir/tasks-axi-done.log"; exit 0; fi
exit 0
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

# Compatible tasks-axi whose `done` subcommand always FAILS (records the attempt, then
# exits non-zero with an error on stderr), to prove a backlog-close failure never
# blocks the worktree release. Args: case_dir
add_failing_done_tasks_axi() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then printf '%s\n' '0.1.1'; exit 0; fi
if [ "\${1:-}" = update ] && [ "\${2:-}" = --help ]; then printf '%s\n' '  --archive-body'; exit 0; fi
if [ "\${1:-}" = mv ] && [ "\${2:-}" = --help ]; then printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <p>'; exit 0; fi
if [ "\${1:-}" = done ]; then printf '%s\n' "\$*" >> "$case_dir/tasks-axi-done.log"; echo "error: task not found" >&2; exit 1; fi
exit 0
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

# Merge the worktree's task branch into origin's default branch with a real merge
# commit, so the branch tip is a fresh ancestor of origin/main. This reproduces the
# direct-push autoland flow, where the worker merged its own fm/<id> branch onto the
# origin default. Args: case_dir
merge_task_branch_into_origin_default() {
  local case_dir=$1 tmp
  git -C "$case_dir/wt" push -q origin fm/task-x1
  tmp="$case_dir/_merge"
  git clone -q "$case_dir/origin.git" "$tmp"
  git -C "$tmp" fetch -q origin fm/task-x1
  git -C "$tmp" checkout -q main
  git -C "$tmp" -c user.email=t@t -c user.name=t merge -q --no-ff --no-edit origin/fm/task-x1
  git -C "$tmp" push -q origin main
  rm -rf "$tmp"
  git -C "$case_dir/project" fetch -q origin
}

# Write a meta file for the task. Args: case_dir mode kind
write_meta() {
  local case_dir=$1 mode=$2 kind=$3
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode"
}

# Commit something on the worktree's task branch. Args: case_dir [message]
wt_commit() {
  local case_dir=$1 msg=${2:-wt work}
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "$msg"
}

# Add a fork bare repo and register it as a remote on the project, then push
# the worktree's task branch to it and fetch into the project so the worktree
# sees the remote-tracking ref. Args: case_dir
add_fork_with_pushed_branch() {
  local case_dir=$1
  git init -q --bare "$case_dir/fork.git"
  git -C "$case_dir/project" remote add fork "$case_dir/fork.git"
  # Push the task branch from the worktree to the fork, then fetch into project
  # so refs/remotes/fork/fm-task-x1 is visible from the worktree (shared object db).
  git -C "$case_dir/wt" push -q fork fm/task-x1
  git -C "$case_dir/project" fetch -q fork
}

# Commit a real file change on the worktree's task branch (unlike wt_commit, which
# makes an empty commit). A non-empty tree is what the content-in-default check
# inspects. Args: case_dir file content [message]
wt_commit_file() {
  local case_dir=$1 file=$2 content=$3 msg=${4:-add $2}
  printf '%s\n' "$content" > "$case_dir/wt/$file"
  git -C "$case_dir/wt" add -- "$file"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "$msg"
}

# Land <file>=<content> as a single commit on origin's default branch, simulating a
# squash merge whose net change matches the task branch but whose commit differs.
# After this, the branch's content is in origin/main even though the branch's own
# commits are not reachable from it. Args: case_dir file content
land_on_origin_main() {
  local case_dir=$1 file=$2 content=$3 tmp
  tmp="$case_dir/_land"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash $file"
  git -C "$tmp" push -q origin HEAD:main
  rm -rf "$tmp"
}

# Override GitHub lookups to report PR 7 as merged with the supplied head.
add_gh_pr_merged_for_head() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list")
    printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged" ; exit 0 ;;
  "pr view")
    printf '%s\n' "pull_request:" "  number: 7" "  state: merged" '  merged: "2026-06-26T00:00:00Z"' ; exit 0 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid"*) printf '%s\t%s\n' 'MERGED' '$head' ; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

append_pr_meta_for_current_head() {
  local case_dir=$1 head
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$head" >> "$case_dir/state/task-x1.meta"
}

append_pr_meta_url() {
  local case_dir=$1
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
}

commit_tree_from_wt_head() {
  local case_dir=$1 parent=$2 msg=$3 tree
  tree=$(git -C "$case_dir/wt" rev-parse "$parent^{tree}") || return 1
  printf '%s\n' "$msg" | git -C "$case_dir/wt" commit-tree "$tree" -p "$parent"
}

land_equivalent_patch_on_origin_branch() {
  local case_dir=$1 branch=$2 file=$3 content=$4 msg=$5 tmp
  tmp="$case_dir/_equiv"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "$msg"
  git -C "$tmp" push -q origin "HEAD:refs/heads/$branch"
  git -C "$case_dir/project" fetch -q origin "$branch"
  rm -rf "$tmp"
  git -C "$case_dir/project" rev-parse "refs/remotes/origin/$branch"
}

# Override gh-axi so every call fails, simulating an API/network error.
add_gh_axi_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "error: gh-axi unavailable" >&2
exit 1
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "error: gh unavailable" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Override fakebin/treehouse so `treehouse return --force <wt>` fails with a
# git "file exists" lock error whenever the worktree's real index.lock is
# present, and succeeds once it is gone. This drives the lock through
# fm-teardown.sh's own retry-then-stale-cleanup logic (teardown_treehouse_return
# in bin/fm-teardown.sh) rather than hand-simulating that logic in the test.
add_lock_aware_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return fails once with the index.lock signature, then clears the lock
# (simulating a dying crew git process finishing) so the next retry succeeds.
# The first failure always reports the lock path even if the file is removed in
# the same attempt - matching the production race where the lock self-clears
# between the failed return and the supervisor's existence check.
add_transient_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  count_file="${TREEHOUSE_ATTEMPT_FILE:?}"
  count=0
  if [ -f "$count_file" ]; then
    count=$(cat "$count_file")
  fi
  count=$(( count + 1 ))
  printf '%s\n' "$count" > "$count_file"
  if [ "$count" -eq 1 ]; then
    # Emit the real git signature, then drop the lock so a lock-existence-only
    # recovery path would wrongly abort without retrying.
    if [ -n "$lock" ]; then
      echo "fatal: Unable to create '$lock': File exists." >&2
      rm -f "$lock"
    else
      echo "fatal: Unable to create 'index.lock': File exists." >&2
    fi
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return always fails with the lock signature while the lock file
# remains; used to assert exhausted retries still refuse loudly.
add_persistent_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -z "$lock" ]; then
    lock="index.lock"
  fi
  echo "fatal: Unable to create '$lock': File exists." >&2
  exit 128
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

git_index_lock_path() {
  local dir=$1 lock abs_dir
  lock=$(git -C "$dir" rev-parse --git-path index.lock)
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(cd "$dir" && pwd -P)
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

# fakebin/lsof stub: no process ever holds anything open (lsof's not-found exit
# code), so a lock's staleness is decided by age alone.
add_lsof_no_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$case_dir/fakebin/lsof"
}

# fakebin/lsof stub: a live process holds every queried path open, so a lock is
# never judged stale regardless of its age.
add_lsof_live_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_lsof_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
echo "lsof: simulated failure for ${1:-unknown}" >&2
exit 2
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_stat_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
echo "stat: simulated failure" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/stat"
}

add_git_status_lock_failure() {
  local case_dir=$1
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
dir=
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      dir=$2
      args+=("$1" "$2")
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
if [ -n "$dir" ] && [ "${args[2]:-}" = status ] && [ "${args[3]:-}" = --porcelain ]; then
  lock=$("$real" -C "$dir" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$dir/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
fi
exec "$real" "${args[@]}"
SH
  chmod +x "$case_dir/fakebin/git"
}

# Run teardown with PATH mocking. Args: case_dir [extra args...]
run_teardown() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

# Push the worktree's task branch to origin, then delete the LOCAL remote-tracking
# ref so `git log --not --remotes` still shows the commit as "unpushed" even though
# the branch is durable on origin. This reproduces the real-world staleness the
# fresh-fetch release-on-pushed check must handle. Args: case_dir
push_branch_then_forget_local_ref() {
  local case_dir=$1
  git -C "$case_dir/wt" push -q origin fm/task-x1
  # refs/remotes are shared across worktrees via the common dir; delete once.
  git -C "$case_dir/project" update-ref -d refs/remotes/origin/fm/task-x1 2>/dev/null || true
}

# Push the worktree's HEAD to origin under a DIFFERENT branch name than the recorded
# fm/task-x1, leaving the recorded branch absent from origin. This reproduces a lane
# whose exact work is durable on origin under an alternate ref (a rebase that renamed
# and pushed the branch). The local remote-tracking refs are pruned so the release
# proof must come from a fresh fetch, not a stale local ref. Args: case_dir alt_branch
push_head_to_alternate_origin_branch() {
  local case_dir=$1 alt=$2
  git -C "$case_dir/wt" push -q origin "HEAD:refs/heads/$alt"
  # Drop the local remote-tracking refs so only a fresh fetch can prove durability.
  # The for-each-ref prefix is refs/remotes/origin with NO trailing /*: a /* glob
  # matches only one path component and would leave a slashed ref like
  # refs/remotes/origin/fm/task-x1-renamed behind.
  git -C "$case_dir/project" for-each-ref --format='%(refname)' refs/remotes/origin \
    | while IFS= read -r ref; do
        git -C "$case_dir/project" update-ref -d "$ref" 2>/dev/null || true
      done
}

test_local_only_fork_remote_allows() {
  local case_dir rc
  case_dir=$(make_case fork-allow)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "fork-allow: teardown should succeed when HEAD is on a fork remote"
  ! grep -q REFUSED "$case_dir/stderr" || fail "fork-allow: teardown printed a REFUSED line"
  pass "local-only worktree with HEAD on a fork remote is torn down (fix holds)"
}

# A scout report that opens with a TL;DR header block tears down cleanly with no
# warning: the supervisor can relay the verdict without deep-reading.
test_scout_report_with_tldr_no_warning() {
  local case_dir rc
  case_dir=$(make_case scout-tldr-ok)
  write_meta "$case_dir" scout scout
  printf 'decisions_reviewed=1\n' >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/data/task-x1"
  printf '# TL;DR\nverdict: fine\nrec: ship\n\n## Detail\nbody\n' > "$case_dir/data/task-x1/report.md"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "scout-tldr-ok: teardown should succeed with a report present"
  ! grep -q REFUSED "$case_dir/stderr" || fail "scout-tldr-ok: teardown printed a REFUSED line"
  ! grep -qi 'no TL;DR' "$case_dir/stderr" || fail "scout-tldr-ok: teardown warned despite a TL;DR block"
  pass "scout report with a TL;DR header block tears down with no warning"
}

# A scout report missing the TL;DR block WARNS but never refuses: the block is a
# supervisor-relay aid, not a landed-work check.
test_scout_report_without_tldr_warns_but_allows() {
  local case_dir rc
  case_dir=$(make_case scout-tldr-missing)
  write_meta "$case_dir" scout scout
  printf 'decisions_reviewed=1\n' >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/data/task-x1"
  printf '# Findings\nlong report body with no summary up top\n' > "$case_dir/data/task-x1/report.md"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "scout-tldr-missing: teardown must still succeed (warn, not refuse)"
  ! grep -q REFUSED "$case_dir/stderr" || fail "scout-tldr-missing: teardown refused instead of warning"
  grep -q 'WARNING:.*no TL;DR' "$case_dir/stderr" \
    || fail "scout-tldr-missing: teardown did not warn about the missing TL;DR block"
  pass "scout report without a TL;DR block warns but is still torn down"
}

test_teardown_prompts_tasks_axi_done_when_compatible() {
  local case_dir out
  case_dir=$(make_case tasks-axi-reminder)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  add_compatible_tasks_axi "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with compatible tasks-axi"
  printf '%s\n' "$out" | grep -F 'tasks-axi done task-x1 --pr https://github.com/example/repo/pull/7' >/dev/null \
    || fail "teardown did not prompt tasks-axi done: $out"
  printf '%s\n' "$out" | grep -F 'tasks-axi ready' >/dev/null \
    || fail "teardown did not prompt tasks-axi ready: $out"
  printf '%s\n' "$out" | grep -F 'check date gates' >/dev/null \
    || fail "teardown did not preserve date-gate check: $out"
  printf '%s\n' "$out" | grep -F 'keep Done to the 10 most recent' >/dev/null \
    && fail "teardown kept manual Done pruning in compatible tasks-axi prompt: $out"
  pass "teardown prompts tasks-axi backlog refresh when compatible"
}

test_teardown_manual_backend_prompts_hand_edit_even_when_tasks_axi_present() {
  local case_dir out
  case_dir=$(make_case tasks-axi-manual-optout)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' manual > "$case_dir/config/backlog-backend"
  add_compatible_tasks_axi "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with manual backlog backend"
  printf '%s\n' "$out" | grep -F 'Update data/backlog.md - move task-x1 to Done' >/dev/null \
    || fail "teardown did not prompt manual backlog update under opt-out: $out"
  printf '%s\n' "$out" | grep -F 'tasks-axi done' >/dev/null \
    && fail "teardown prompted tasks-axi despite manual backend opt-out: $out"
  pass "teardown honors config/backlog-backend=manual even when tasks-axi is compatible"
}

test_local_only_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case truly-unpushed)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"
  # No fork, no push to origin, not merged into main.

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "truly-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "truly-unpushed: no REFUSED line in stderr"
  pass "local-only worktree with truly unpushed work is refused (safety preserved)"
}

test_local_only_merged_to_local_main_allows() {
  local case_dir rc
  case_dir=$(make_case merged-main)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  # Fast-forward the project's main to the worktree's HEAD commit so HEAD is
  # reachable from main. update-ref works whether or not main is checked out,
  # and the worktree shares the project's object db so the commit is visible.
  local wt_head
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "merged-main: teardown should succeed when work is merged into local main"
  ! grep -q REFUSED "$case_dir/stderr" || fail "merged-main: teardown printed a REFUSED line"
  pass "local-only worktree with work merged into local main is torn down (no regression)"
}

test_no_mistakes_origin_remote_allows() {
  local case_dir rc
  case_dir=$(make_case nm-origin)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  # Push the task branch to origin and fetch so the worktree sees it.
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "nm-origin: teardown should succeed when HEAD is on origin"
  ! grep -q REFUSED "$case_dir/stderr" || fail "nm-origin: teardown printed a REFUSED line"
  grep -F 'blockers are gone and date is due' "$case_dir/stdout" >/dev/null \
    || fail "nm-origin: teardown manual prompt did not preserve date-gate check"
  pass "no-mistakes worktree with HEAD on origin is torn down (no regression)"
}

test_no_mistakes_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case nm-unpushed)
  write_meta "$case_dir" no-mistakes ship
  # Real content that is not pushed, has no PR (default gh-axi mock), and never
  # landed on origin/main: genuinely unlanded work that must still refuse.
  wt_commit_file "$case_dir" feature.txt hello "unpushed work"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nm-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "nm-unpushed: no REFUSED line in stderr"
  pass "no-mistakes worktree with genuinely unlanded work is refused (safety preserved)"
}

test_squash_merged_branch_deleted_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-merged)
  write_meta "$case_dir" no-mistakes ship
  # Real branch content that is NOT pushed and NOT on origin/main: a squash merge
  # rewrote it into a different commit on main and auto-deleted the head branch, so
  # HEAD is unreachable from every remote-tracking branch. The matching merged PR is
  # the only signal that the work landed.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-merged: teardown should succeed when the PR is merged"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-merged: teardown printed a REFUSED line"
  pass "squash-merged + deleted-branch worktree (PR merged) is torn down (the fix)"
}

test_squash_merged_pr_allows_when_head_ancestor_of_pr_head() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case squash-ancestor)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-ancestor: teardown should succeed when local HEAD is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-ancestor: teardown printed a REFUSED line"
  pass "squash-merged PR accepts a local HEAD that is an ancestor of the final PR head"
}

test_no_pr_recorded_discovers_merged_pr_by_branch_allows() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case no-pr-branch-discovery)
  write_meta "$case_dir" no-mistakes ship
  # Reproduces the real false-refusal report exactly, with NO pr=/pr_head=
  # recorded in meta at all (fm-pr-check.sh was never run, e.g. a yolo merge on
  # a repo with no PR CI so the "checks green" trigger that fires it never
  # happened): a branch with a commit, a no-mistakes auto-fix commit pushed on
  # top that never made it back into the local worktree, a squash merge onto
  # main under a brand-new SHA, and the head branch deleted (simulated here by
  # never pushing fm/task-x1 at all, so no refs/remotes/origin/fm/task-x1
  # exists to make HEAD "reachable").
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes auto-fix")
  land_on_origin_main "$case_dir" feature.txt hello
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  # No append_pr_meta_* call: state/task-x1.meta has no pr= or pr_head= line.

  ! grep -qE '^(pr|pr_head)=' "$case_dir/state/task-x1.meta" \
    || fail "no-pr-branch-discovery: test setup bug, meta unexpectedly has a pr= line"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-pr-branch-discovery: teardown should succeed by discovering the merged PR from the branch name"
  ! grep -q REFUSED "$case_dir/stderr" || fail "no-pr-branch-discovery: teardown printed a REFUSED line"
  pass "teardown discovers a merged PR by branch name and tears down when no pr= was ever recorded"
}

test_squash_merged_pr_allows_replayed_unpushed_patch() {
  local case_dir rc parent_head pr_head
  case_dir=$(make_case squash-replayed-patch)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" local-parent.txt parent "local parent"
  parent_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin "$parent_head:refs/heads/fm/task-x1"
  git -C "$case_dir/project" fetch -q origin fm/task-x1
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  pr_head=$(land_equivalent_patch_on_origin_branch "$case_dir" pr-head feature.txt hello "add feature")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-replayed-patch: teardown should succeed when unpushed local patch is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-replayed-patch: teardown printed a REFUSED line"
  pass "squash-merged PR accepts replayed unpushed local patches contained in the PR head"
}

test_merged_pr_with_later_local_commit_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case stale-pr-head)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-pr-head: teardown should refuse when HEAD moved after PR recording"
  grep -q REFUSED "$case_dir/stderr" || fail "stale-pr-head: no REFUSED line in stderr"
  pass "merged PR does not allow teardown after a later local commit"
}

test_pr_check_does_not_refresh_stale_pr_head() {
  local case_dir rc pr_head new_head count
  case_dir=$(make_case pr-check-stale)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  new_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  count=$(grep -c '^pr_head=' "$case_dir/state/task-x1.meta" || true)
  expect_code 1 "$count" "pr-check-stale: stale rerun should not append a second pr_head"
  ! grep -qxF "pr_head=$new_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-stale: stale rerun recorded the later local HEAD"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pr-check-stale: teardown should refuse after a later local commit"
  grep -q REFUSED "$case_dir/stderr" || fail "pr-check-stale: no REFUSED line in stderr"
  pass "fm-pr-check does not refresh PR head after HEAD moves"
}

test_pr_check_records_remote_head_when_local_lags() {
  local case_dir local_head pr_head
  case_dir=$(make_case pr-check-local-lags)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  grep -qxF "pr_head=$pr_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: did not record GitHub PR head"
  ! grep -qxF "pr_head=$local_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: recorded local HEAD instead of remote PR head"
  pass "fm-pr-check records the remote PR head when the local worktree lags"
}

test_content_in_default_fallback_allows() {
  local case_dir rc
  case_dir=$(make_case content-landed)
  write_meta "$case_dir" no-mistakes ship
  # No pr= recorded and the default gh-axi mock reports no PR, so the merged-PR path
  # cannot fire and the content check must carry it. The branch adds feature.txt, and
  # the same net change has independently landed on origin/main via a squash commit.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-landed: teardown should succeed when content is already in the default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-landed: teardown printed a REFUSED line"
  pass "worktree whose content already landed in the default branch is torn down (content fallback)"
}

test_content_fallback_refreshes_stale_origin_ref() {
  local case_dir rc
  case_dir=$(make_case content-stale-ref)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  git -C "$case_dir/project" config --unset-all remote.origin.fetch
  git -C "$case_dir/project" config --add remote.origin.fetch '+refs/heads/not-main:refs/remotes/origin/not-main'
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-stale-ref: teardown should use the freshly fetched default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-stale-ref: teardown printed a REFUSED line"
  pass "content fallback refreshes origin default before comparing trees"
}

test_dirty_worktree_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case dirty-wt)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # The committed work has fully landed (merged PR + content in default), but an
  # uncommitted edit remains. Dirtiness must refuse regardless: the reset would
  # discard those changes.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  printf '%s\n' "uncommitted edit" > "$case_dir/wt/feature.txt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-wt: teardown should refuse a dirty worktree even when the committed work has landed"
  grep -q REFUSED "$case_dir/stderr" || fail "dirty-wt: no REFUSED line in stderr"
  grep -q "uncommitted changes" "$case_dir/stderr" || fail "dirty-wt: refusal did not cite uncommitted changes"
  pass "dirty worktree is refused even when its committed work has landed (dirty always wins)"
}

test_gh_error_and_content_absent_refuses() {
  local case_dir rc
  case_dir=$(make_case gh-error)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # Real content not pushed, the PR lookup errors, and origin/main never gained the
  # content. The fail-safe must refuse rather than allow on a transient gh failure.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gh-error: teardown should refuse when the PR lookup errors and content is not landed"
  grep -q REFUSED "$case_dir/stderr" || fail "gh-error: no REFUSED line in stderr"
  pass "gh lookup error with content not in default refuses (fail-safe)"
}

test_stale_index_lock_cleared_and_teardown_succeeds() {
  local case_dir rc lock
  case_dir=$(make_case stale-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "stale-index-lock: teardown should succeed after clearing the provably stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "stale-index-lock: stale lock file should have been removed"
  pass "provably-stale worktree index.lock (old, no live holder) is cleared and teardown succeeds"
}

test_live_index_lock_is_never_removed_and_teardown_refuses() {
  local case_dir rc lock
  case_dir=$(make_case live-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Even an old mtime must not be enough on its own: a live holder always wins.
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "live-index-lock: teardown should refuse when the lock has a live holder"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "live-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "live-index-lock: teardown removed a lock with a live holder"
  [ -e "$lock" ] || fail "live-index-lock: live-held lock file was removed"
  pass "live-held worktree index.lock is never removed and teardown refuses"
}

test_lsof_error_never_clears_index_lock() {
  local case_dir rc lock
  case_dir=$(make_case lsof-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "lsof-error-index-lock: teardown should refuse when lsof errors"
  assert_grep "lsof check failed" "$case_dir/stderr" \
    "lsof-error-index-lock: teardown did not report the lsof failure"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "lsof-error-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "lsof-error-index-lock: teardown removed a lock after lsof failed"
  [ -e "$lock" ] || fail "lsof-error-index-lock: lock file was removed after lsof failed"
  pass "lsof errors leave worktree index.lock in place and refuse teardown"
}

test_stale_index_lock_cleanup_rechecks_dirty_worktree() {
  local case_dir rc lock
  case_dir=$(make_case stale-lock-dirty-recheck)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt landed "landed work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  printf '%s\n' dirty > "$case_dir/wt/feature.txt"

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_git_status_lock_failure "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-lock-dirty-recheck: teardown should refuse dirty work after clearing the stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not report clearing the stale lock"
  assert_grep "uncommitted changes present" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not re-run the dirty check"
  assert_absent "$lock" "stale-lock-dirty-recheck: stale lock file should have been removed"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "stale-lock-dirty-recheck: teardown completed despite dirty work"
  pass "stale lock cleanup rechecks and refuses dirty worktree before return"
}

test_non_linked_index_lock_path_is_checked_from_worktree() {
  local case_dir rc lock
  case_dir=$(make_case non-linked-index-lock)
  git -C "$case_dir/project" worktree remove --force "$case_dir/wt"
  git clone -q "$case_dir/origin.git" "$case_dir/wt"
  git -C "$case_dir/wt" checkout -q -b fm/task-x1
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable normal clone work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/wt" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "non-linked-index-lock: teardown should clear a normal repo index.lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "non-linked-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "non-linked-index-lock: stale lock file should have been removed"
  pass "normal repo index.lock is resolved from the worktree and cleared when stale"
}

test_index_lock_mtime_read_failure_refuses() {
  local case_dir rc lock
  case_dir=$(make_case mtime-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_stat_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mtime-error-index-lock: teardown should refuse when lock mtime cannot be read"
  assert_grep "cannot read mtime for git lock" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not report the mtime read failure"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "mtime-error-index-lock: teardown removed a lock after mtime read failed"
  [ -e "$lock" ] || fail "mtime-error-index-lock: lock file was removed after mtime read failed"
  pass "lock mtime read failures leave worktree index.lock in place and refuse teardown"
}

test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case transient-index-lock-retry)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Fresh lock: not old enough for the force-remove path; patience must win.
  touch "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "transient-index-lock: teardown should succeed on retry after lock self-clears"
  assert_grep "succeeded on retry" "$case_dir/stderr" \
    "transient-index-lock: teardown did not report success on retry"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "transient-index-lock: teardown force-removed a lock that only needed patience"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "transient-index-lock: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  assert_absent "$lock" "transient-index-lock: lock should remain cleared after success"
  pass "transient index.lock cleared after first failed return is retried successfully without force-remove"
}

test_persistent_index_lock_exhausts_retries_and_refuses_loudly() {
  local case_dir rc lock
  case_dir=$(make_case persistent-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  # Fresh lock with a live holder: never provably stale, never force-removed.
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "persistent-index-lock: teardown should refuse when the lock never clears"
  assert_grep "persisted across" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not mention the exhausted retry window"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "persistent-index-lock: teardown removed a non-stale lock"
  [ -e "$lock" ] || fail "persistent-index-lock: lock file was removed"
  [ -f "$case_dir/state/task-x1.meta" ] \
    || fail "persistent-index-lock: teardown completed despite persistent lock"
  pass "persistent index.lock exhausts retries and refuses without force-removing the lock"
}

test_empty_retry_wait_uses_default_without_aborting() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case empty-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "empty-retry-wait: teardown should fall back to the default wait"
  assert_grep "waiting 1s and retrying" "$case_dir/stderr" \
    "empty-retry-wait: teardown did not use the default retry wait"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "empty-retry-wait: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  pass "empty retry wait overrides use the default without aborting teardown"
}

test_fractional_legacy_retry_wait_refuses_without_arithmetic_error() {
  local case_dir rc lock
  case_dir=$(make_case fractional-legacy-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0.1 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "fractional-legacy-retry-wait: teardown should fail only for the persistent lock"
  assert_grep "waiting 0.1s each" "$case_dir/stderr" \
    "fractional-legacy-retry-wait: teardown did not preserve the legacy fractional wait"
  assert_not_contains "$(cat "$case_dir/stderr")" "syntax error" \
    "fractional-legacy-retry-wait: teardown hit an arithmetic error"
  pass "fractional legacy retry wait remains supported without arithmetic"
}

test_local_only_force_overrides_unpushed() {
  local case_dir rc
  case_dir=$(make_case force-override)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "force-override: --force should bypass the unpushed-work check"
  ! grep -q REFUSED "$case_dir/stderr" || fail "force-override: REFUSED printed despite --force"
  pass "local-only worktree with unpushed work is torn down under --force (escape hatch)"
}

test_herdr_teardown_clears_escalation_marker() {
  local case_dir marker
  case_dir=$(make_case herdr-marker-cleanup)
  write_meta "$case_dir" local-only ship
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' 'backend=herdr' >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/herdr"
  marker="$case_dir/state/.herdr-escalated-default_wG_pQ"
  : > "$marker"

  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-marker-cleanup: forced teardown failed"
  [ ! -e "$marker" ] || fail "herdr-marker-cleanup: teardown left the pane's escalation marker behind"
  pass "herdr teardown removes pane-owned escalation dedupe state"
}

configure_herdr_projection_teardown_case() {  # <case-dir>
  local case_dir=$1 token=AbCdEfGhIjKlMnOpQrStUv
  sed -i.bak 's/^window=.*/window=fmtest:w1:p2/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=fmtest' \
    'herdr_workspace_id=w1' \
    'herdr_tab_id=w1:t2' \
    'herdr_pane_id=w1:p2' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' \
    'version=1' \
    'task_id=task-x1' \
    "projection_id=$token" > "$case_dir/state/task-x1.herdr-presentation"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "workspace list")
    if [ -e "${FM_FAKE_HERDR_RESTORED:?}" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":false}]}}'
    elif [ -e "${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":true}]}}'
    else
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t2","label":"firstmate/task-x1 · p:AbCdEfGhIjKlMnOpQrStUv","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":false}]}}'
    fi
    ;;
  "tab list")
    case "$*" in
      *"--workspace w2"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","focused":true}]}}' ;;
      *"--workspace w3"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"w3:t1","focused":true}]}}' ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}'
    ;;
  "pane close")
    if [ "${FM_FAKE_HERDR_CLOSE_FAIL:-0}" = 1 ]; then
      exit 1
    fi
    : > "${FM_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    if [ -e "${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1"}}}'
    ;;
  "tab get")
    printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2"}}}'
    ;;
  "tab focus")
    : > "${FM_FAKE_HERDR_RESTORED:?}"
    printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2","focused":true}}}'
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_herdr_projection_teardown_retires_journal_only_after_confirmed_close() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-confirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-projection-confirmed-close: forced teardown failed"
  [ ! -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "confirmed exact-pane close did not retire the presentation journal"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "projected teardown must never call workspace close"
  assert_contains "$(cat "$log")" "tab focus w2:t2" \
    "projected teardown did not restore the exact pre-close active tab"
  pass "herdr projection teardown retires its journal only after confirming the exact recorded pane is gone"
}

test_herdr_projection_teardown_retains_journal_when_close_unconfirmed() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-unconfirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" FM_FAKE_HERDR_CLOSE_FAIL=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-projection-unconfirmed-close: teardown should preserve best-effort endpoint semantics"
  [ -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "unconfirmed task-pane close incorrectly retired the presentation journal"
  assert_grep "close could not be confirmed" "$case_dir/stderr" \
    "unconfirmed projected close did not explain why the journal was retained"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "unconfirmed projected close must not escalate to workspace cleanup"
  pass "herdr projection teardown retains the stale journal and attempts no workspace cleanup when exact-pane close is unconfirmed"
}

# Give the project a bare "no-mistakes" remote and push the task branch to it,
# then fetch so the worktree sees refs/remotes/no-mistakes/*. This reproduces the
# pipeline's internal validation remote, which makes the generic "commits not on a
# remote" check come back empty even though origin never received the branch.
add_no_mistakes_internal_remote_with_pushed_branch() {
  local case_dir=$1
  git init -q --bare "$case_dir/no-mistakes.git"
  git -C "$case_dir/project" remote add no-mistakes "$case_dir/no-mistakes.git"
  git -C "$case_dir/wt" push -q no-mistakes fm/task-x1
  git -C "$case_dir/project" fetch -q no-mistakes
}

add_git_ls_remote_failure() {
  local case_dir=$1
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
# Simulate an unreachable origin: every network op against it fails. A real
# offline/unreachable origin breaks fetch as well as ls-remote, so failing only
# ls-remote would let the fresh-fetch durability check (head_on_any_origin_ref /
# branch_fully_pushed_to_origin) still prove the work is on origin and release it.
# The point of this case is that origin CANNOT be queried, so both must fail.
for arg in "$@"; do
  case "$arg" in
    ls-remote|fetch)
      echo "fatal: simulated origin failure" >&2
      exit 128
      ;;
  esac
done
exec "$real" "$@"
SH
  chmod +x "$case_dir/fakebin/git"
}

# Merge the worktree's task branch into the PROJECT clone's local default branch
# with --no-ff, without pushing. The task worktree is a linked worktree of that
# clone, so the merge commit and everything it reaches live in a shared object
# store that outlives the worktree. Args: case_dir
merge_task_branch_into_shared_local_default() {
  local case_dir=$1
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t \
    merge -q --no-ff --no-edit fm/task-x1
}

# Land <file>=<content> on origin's default branch, refresh the clone's
# remote-tracking refs, and leave the task worktree detached at exactly that
# commit - the shape of a lane that finished on a detached HEAD. Args: case_dir
detach_worktree_at_origin_default() {
  local case_dir=$1 file=$2 content=$3
  land_on_origin_main "$case_dir" "$file" "$content"
  git -C "$case_dir/project" fetch -q origin
  git -C "$case_dir/wt" checkout -q --detach refs/remotes/origin/main
}

# (dd) direct-push + detached HEAD at the origin default tip -> ALLOW.
# The lane finished on a detached HEAD, so there is no branch name to look up on
# origin, but the exact commit is origin's default branch head. Nothing is lost.
test_direct_push_detached_head_contained_in_origin_default_allows() {
  local case_dir rc
  case_dir=$(make_case dp-detached-contained)
  write_meta "$case_dir" direct-push ship
  detach_worktree_at_origin_default "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "dp-detached-contained: teardown should release a detached HEAD already on origin's default branch"
  ! grep -q REFUSED "$case_dir/stderr" \
    || fail "dp-detached-contained: teardown printed a REFUSED line for landed work"
  pass "direct-push worktree detached at the origin default tip is torn down (containment beats the branch name)"
}

# (ee) direct-push + scratch local branch name never pushed, HEAD at the origin
#      default tip -> ALLOW. Matches the batch-merge lane that landed on origin and
#      left fm/land-batch-tmp pointing at exactly that commit.
test_direct_push_scratch_branch_at_origin_default_allows() {
  local case_dir rc
  case_dir=$(make_case dp-scratch-branch-contained)
  write_meta "$case_dir" direct-push ship
  land_on_origin_main "$case_dir" feature.txt hello
  git -C "$case_dir/project" fetch -q origin
  git -C "$case_dir/wt" checkout -q -B fm/land-batch-tmp refs/remotes/origin/main

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "dp-scratch-branch-contained: teardown should release a scratch branch sitting on origin's default branch"
  ! grep -q REFUSED "$case_dir/stderr" \
    || fail "dp-scratch-branch-contained: teardown printed a REFUSED line for landed work"
  pass "direct-push worktree on a scratch branch at the origin default tip is torn down"
}

# (ff) direct-push + HEAD merged into the SHARED local default branch, which is
#      ahead of origin -> ALLOW. The merge commit lives in the project clone's
#      object store, which teardown does not remove.
test_direct_push_contained_in_shared_local_default_allows() {
  local case_dir rc
  case_dir=$(make_case dp-shared-local-default)
  write_meta "$case_dir" direct-push ship
  wt_commit_file "$case_dir" feature.txt hello "validated work"
  # The pipeline's internal validation remote holds the branch, so the generic
  # "commits not on a remote" probe comes back empty exactly as it does in production.
  add_no_mistakes_internal_remote_with_pushed_branch "$case_dir"
  merge_task_branch_into_shared_local_default "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "dp-shared-local-default: teardown should release work merged into the shared local default branch"
  ! grep -q REFUSED "$case_dir/stderr" \
    || fail "dp-shared-local-default: teardown printed a REFUSED line for landed work"
  pass "direct-push worktree merged into the shared local default branch is torn down"
}

# (gg) no-mistakes + merged --no-ff into the shared local default branch and nowhere
#      on any remote -> ALLOW. This is the firstmate repo's merge-locally landing
#      target: origin exists but is not where the work lands.
test_merged_into_shared_local_default_allows() {
  local case_dir rc
  case_dir=$(make_case nm-shared-local-default)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "fast-lane work"
  merge_task_branch_into_shared_local_default "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "nm-shared-local-default: teardown should release work merged into local main even though origin never saw it"
  ! grep -q REFUSED "$case_dir/stderr" \
    || fail "nm-shared-local-default: teardown printed a REFUSED line for locally landed work"
  pass "worktree merged into the shared local default branch is torn down (local landing target)"
}

# (hh) local default branch of a STANDALONE clone contains HEAD -> REFUSE. The ref
#      lives in the worktree's own repository, which teardown removes, so it proves
#      nothing about survival. This pins the boundary that keeps the containment
#      fallback from becoming "origin is optional".
test_standalone_clone_local_default_does_not_count_as_landed() {
  local case_dir rc standalone
  case_dir=$(make_case standalone-local-default)
  standalone="$case_dir/standalone"
  git clone -q "$case_dir/origin.git" "$standalone"
  git -C "$standalone" remote set-head origin main 2>/dev/null || true
  git -C "$standalone" checkout -q -b fm/task-x1
  printf '%s\n' hello > "$standalone/feature.txt"
  git -C "$standalone" add -- feature.txt
  git -C "$standalone" -c user.email=t@t -c user.name=t commit -q -m "standalone work"
  git -C "$standalone" checkout -q main
  git -C "$standalone" -c user.email=t@t -c user.name=t merge -q --no-ff --no-edit fm/task-x1
  git -C "$standalone" checkout -q fm/task-x1
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$standalone" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "standalone-local-default: teardown should refuse when the only containing ref dies with the worktree"
  grep -q REFUSED "$case_dir/stderr" \
    || fail "standalone-local-default: no REFUSED line in stderr"
  pass "a local default branch that does not outlive the worktree never counts as landed"
}

# (ii) contained in the default branch but the worktree is dirty -> REFUSE.
#      Uncommitted changes are never landed, whatever the containment proof says.
test_contained_in_default_but_dirty_refuses() {
  local case_dir rc
  case_dir=$(make_case contained-dirty)
  write_meta "$case_dir" direct-push ship
  detach_worktree_at_origin_default "$case_dir" feature.txt hello
  printf '%s\n' dirty > "$case_dir/wt/uncommitted.txt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "contained-dirty: teardown should refuse a dirty worktree even when HEAD is on the default branch"
  assert_grep "uncommitted changes" "$case_dir/stderr" \
    "contained-dirty: refusal did not name the uncommitted changes"
  pass "uncommitted changes are refused even when HEAD is contained in the default branch (dirty wins)"
}

# (jj) detached HEAD whose commit is on no default branch anywhere -> REFUSE, with
#      the same clarity as before. Containment must not turn a detached HEAD into a
#      free pass.
test_detached_head_absent_from_every_default_refuses() {
  local case_dir rc
  case_dir=$(make_case detached-absent)
  write_meta "$case_dir" direct-push ship
  wt_commit_file "$case_dir" feature.txt hello "unlanded work"
  git -C "$case_dir/wt" checkout -q --detach HEAD

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "detached-absent: teardown should refuse a detached HEAD that landed nowhere"
  grep -q REFUSED "$case_dir/stderr" || fail "detached-absent: no REFUSED line in stderr"
  pass "detached HEAD absent from every default branch is refused (safety preserved)"
}

test_direct_push_branch_absent_from_origin_refuses() {
  local case_dir rc
  case_dir=$(make_case dp-no-origin)
  write_meta "$case_dir" direct-push ship
  wt_commit_file "$case_dir" feature.txt hello "validated work"
  add_no_mistakes_internal_remote_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dp-no-origin: teardown should refuse when the branch never reached origin"
  assert_grep "never pushed to origin" "$case_dir/stderr" \
    "dp-no-origin: teardown did not refuse for the missing origin branch"
  assert_grep "the validation remote never counts as landed" "$case_dir/stderr" \
    "dp-no-origin: refusal did not explain the internal validation remote"
  pass "direct-push worktree whose branch is absent from origin is refused"
}

test_direct_push_ls_remote_failure_refuses() {
  local case_dir rc
  case_dir=$(make_case dp-ls-remote-error)
  write_meta "$case_dir" direct-push ship
  wt_commit_file "$case_dir" feature.txt hello "validated work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  add_git_ls_remote_failure "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dp-ls-remote-error: teardown should refuse when origin cannot be queried"
  assert_grep "cannot confirm direct-push worktree" "$case_dir/stderr" \
    "dp-ls-remote-error: teardown did not fail closed on the origin probe error"
  pass "direct-push teardown refuses rather than releasing when the origin probe errors"
}

test_direct_push_branch_on_origin_allows() {
  local case_dir rc
  case_dir=$(make_case dp-origin)
  write_meta "$case_dir" direct-push ship
  wt_commit_file "$case_dir" feature.txt hello "validated work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "dp-origin: teardown should succeed when the branch is on origin"
  ! grep -q REFUSED "$case_dir/stderr" || fail "dp-origin: teardown printed a REFUSED line"
  pass "direct-push worktree whose branch is on origin is torn down"
}

test_direct_push_stale_origin_ref_refuses() {
  local case_dir rc
  case_dir=$(make_case dp-stale-origin)
  write_meta "$case_dir" direct-push ship
  wt_commit_file "$case_dir" feature.txt hello "validated work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  wt_commit_file "$case_dir" feature.txt later "later work never pushed to origin"
  add_no_mistakes_internal_remote_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dp-stale-origin: teardown should refuse when origin lags the worktree head"
  assert_grep "has commits after what origin holds" "$case_dir/stderr" \
    "dp-stale-origin: teardown did not refuse for the stale origin ref"
  assert_no_grep "never pushed to origin" "$case_dir/stderr" \
    "dp-stale-origin: stale-ref refusal must read differently from the branch-absent refusal"
  pass "direct-push worktree whose origin ref lags its head is refused"
}

test_direct_push_origin_ahead_of_head_allows() {
  local case_dir rc
  case_dir=$(make_case dp-origin-ahead)
  write_meta "$case_dir" direct-push ship
  wt_commit_file "$case_dir" feature.txt hello "validated work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  wt_commit_file "$case_dir" feature.txt later "later work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/wt" reset -q --hard HEAD~1
  git -C "$case_dir/project" fetch -q origin

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "dp-origin-ahead: origin containing the head should be treated as landed"
  ! grep -q REFUSED "$case_dir/stderr" || fail "dp-origin-ahead: teardown printed a REFUSED line"
  pass "direct-push worktree whose head is contained in origin is torn down"
}

test_direct_push_force_overrides_missing_origin_branch() {
  local case_dir rc
  case_dir=$(make_case dp-force)
  write_meta "$case_dir" direct-push ship
  wt_commit_file "$case_dir" feature.txt hello "validated work"
  add_no_mistakes_internal_remote_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "dp-force: --force should still override the origin check"
  ! grep -q REFUSED "$case_dir/stderr" || fail "dp-force: teardown printed a REFUSED line"
  pass "direct-push origin check honors the explicit discard escape hatch"
}

# (z) no-mistakes + branch pushed to origin but unmerged, local remote ref stale ->
#     ALLOW (release-on-pushed) and record the branch in the merge queue.
test_pushed_unmerged_releases_and_records_merge_queue() {
  local case_dir rc
  case_dir=$(make_case pushed-unmerged)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "pushed unmerged work"
  push_branch_then_forget_local_ref "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "pushed-unmerged: teardown should release a fully pushed branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "pushed-unmerged: teardown printed a REFUSED line"
  grep -F 'fm/task-x1' "$case_dir/data/merge-queue.tsv" >/dev/null \
    || fail "pushed-unmerged: branch not recorded in the merge queue"
  grep -E '^task-x1	' "$case_dir/data/merge-queue.tsv" >/dev/null \
    || fail "pushed-unmerged: merge-queue entry missing task id"
  pass "no-mistakes worktree fully pushed but unmerged is released and queued for merge"
}

# (z2) forced teardown of a pushed-but-unmerged branch still records the merge queue:
#      recording is read-only, and a forced release is exactly when a pushed branch is
#      most easily lost.
test_forced_pushed_unmerged_still_records_merge_queue() {
  local case_dir rc
  case_dir=$(make_case pushed-unmerged-forced)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "pushed unmerged work"
  push_branch_then_forget_local_ref "$case_dir"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "pushed-unmerged-forced: forced teardown should succeed"
  grep -E '^task-x1	' "$case_dir/data/merge-queue.tsv" >/dev/null \
    || fail "pushed-unmerged-forced: forced teardown did not queue the released branch"
  pass "forced teardown of a pushed-but-unmerged branch is still queued for merge"
}

# Land a squash commit on origin/main whose NET content equals the task branch, while
# the task branch itself stays pushed to origin under its own name and its own commits
# are NOT reachable from origin/main. This is the #124/#125 shape: content_in_default
# reports "already landed" (merge-tree of origin/main + HEAD == origin/main's tree)
# even though the branch's PR is still open and unmerged. Args: case_dir file content
land_equivalent_content_on_origin_main_keeping_branch() {
  local case_dir=$1 file=$2 content=$3 tmp
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  tmp="$case_dir/_equiv_main"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash equivalent $file"
  git -C "$tmp" push -q origin HEAD:main
  rm -rf "$tmp"
  git -C "$case_dir/project" fetch -q origin
}

# (z3) REGRESSION for the #124/#125 incident: a branch that IS pushed to origin and
#      NOT merged (its own commits are not reachable from origin/main), whose NET
#      content nonetheless already appears in origin/main via an equivalent squash
#      commit, MUST still be recorded in the merge queue. The pre-fix recorder skipped
#      on content_in_default's say-so and silently dropped exactly this branch.
test_pushed_unmerged_content_equivalent_still_records_merge_queue() {
  local case_dir rc
  case_dir=$(make_case pushed-unmerged-content-equiv)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "pushed unmerged work"
  land_equivalent_content_on_origin_main_keeping_branch "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-equiv-unmerged: teardown should release a fully pushed branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-equiv-unmerged: teardown printed a REFUSED line"
  grep -F 'fm/task-x1' "$case_dir/data/merge-queue.tsv" >/dev/null \
    || fail "content-equiv-unmerged: pushed-but-unmerged branch not recorded despite content match (#124/#125 regression)"$'\n'"$(cat "$case_dir/stderr")"
  pass "pushed-but-unmerged branch is recorded even when its content already appears in the default branch (#124/#125 regression)"
}

# (z4) a provably-merged branch (merged PR whose head contains the local work) is
#      correctly SKIPPED: nothing to track, and no spurious merge-queue entry.
test_merged_pr_branch_is_not_recorded_in_merge_queue() {
  local case_dir rc pr_head
  case_dir=$(make_case merged-pr-no-record)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "merged work"
  push_branch_then_forget_local_ref "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  append_pr_meta_for_current_head "$case_dir"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "merged-pr-no-record: teardown should release a merged branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "merged-pr-no-record: teardown printed a REFUSED line"
  [ ! -f "$case_dir/data/merge-queue.tsv" ] \
    || ! grep -q task-x1 "$case_dir/data/merge-queue.tsv" \
    || fail "merged-pr-no-record: a provably-merged branch must not be queued"
  pass "a provably-merged branch is skipped and never queued"
}

# (z5) an ERRORED / INCONCLUSIVE merge check on an unproven-landed branch must REPORT
#      LOUDLY to stderr and still record, never silently drop. Reproduced by forcing
#      the recorder down its ambiguous path with --force on a branch that is not on
#      origin, not merged, and whose content is not in the default branch.
test_errored_unproven_branch_reports_and_records() {
  local case_dir rc
  case_dir=$(make_case errored-unproven-records)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "unproven work"
  add_gh_axi_error "$case_dir"
  # Branch is never pushed to origin, so no origin ref contains HEAD and its content is
  # absent from origin/main. --force skips the safety refusal so the recorder runs on
  # this genuinely ambiguous, never-proven-landed branch.
  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "errored-unproven: forced teardown should complete"
  grep -F 'teardown: WARNING' "$case_dir/stderr" >/dev/null \
    || fail "errored-unproven: no loud WARNING for an unproven-landed branch"$'\n'"$(cat "$case_dir/stderr")"
  grep -F 'fm/task-x1' "$case_dir/data/merge-queue.tsv" >/dev/null \
    || fail "errored-unproven: an unproven branch must still be recorded, not silently dropped"$'\n'"$(cat "$case_dir/stderr")"
  pass "an errored/inconclusive unproven-landed branch reports loudly and is still recorded"
}

# (aa) no-mistakes + pushed base commit + an EXTRA local commit past the origin ref ->
#      REFUSE (a commit absent from the remote ref is still unpushed).
test_pushed_with_extra_local_commit_refuses() {
  local case_dir rc
  case_dir=$(make_case pushed-extra-commit)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "base pushed work"
  push_branch_then_forget_local_ref "$case_dir"
  # A further local commit that was never pushed to origin.
  wt_commit_file "$case_dir" extra.txt more "unpushed extra commit"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pushed-extra-commit: teardown should refuse extra unpushed work"
  grep -q REFUSED "$case_dir/stderr" || fail "pushed-extra-commit: no REFUSED line"
  [ ! -f "$case_dir/data/merge-queue.tsv" ] \
    || ! grep -q task-x1 "$case_dir/data/merge-queue.tsv" \
    || fail "pushed-extra-commit: refused work must not be queued"
  pass "branch with a local commit absent from its remote ref is refused (safety preserved)"
}

# (bb) no-mistakes + pushed branch but dirty worktree -> REFUSE (dirty wins over pushed).
test_pushed_but_dirty_refuses() {
  local case_dir rc
  case_dir=$(make_case pushed-dirty)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "pushed work"
  push_branch_then_forget_local_ref "$case_dir"
  printf '%s\n' dirty > "$case_dir/wt/uncommitted.txt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pushed-dirty: teardown should refuse a dirty worktree even when pushed"
  grep -q REFUSED "$case_dir/stderr" || fail "pushed-dirty: no REFUSED line"
  pass "fully pushed branch with a dirty worktree is refused (dirty wins)"
}

# (cc) no-mistakes + branch pushed but origin unreachable (offline) -> REFUSE rather
#      than release on an unverifiable claim.
test_pushed_but_origin_unreachable_refuses() {
  local case_dir rc
  case_dir=$(make_case pushed-offline)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "pushed work"
  push_branch_then_forget_local_ref "$case_dir"
  # Simulate offline: point origin at a nonexistent path so every fetch fails.
  git -C "$case_dir/wt" remote set-url origin "$case_dir/no-such-origin.git"
  git -C "$case_dir/project" remote set-url origin "$case_dir/no-such-origin.git"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pushed-offline: teardown should refuse when the remote is unverifiable"
  grep -q REFUSED "$case_dir/stderr" || fail "pushed-offline: no REFUSED line"
  pass "pushed branch with an unreachable origin is refused (no release on unverifiable claim)"
}

# (kk) no-mistakes + HEAD pushed to origin under a DIFFERENT branch name than the
#      recorded fm/task-x1 (rebase renamed and pushed the branch) -> ALLOW. The exact
#      work is durable on origin under an alternate ref, so the local copy is
#      disposable even though the recorded branch name is absent from origin.
test_head_on_alternate_origin_branch_allows() {
  local case_dir rc
  case_dir=$(make_case alt-origin-branch)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "work landed under a renamed branch"
  push_head_to_alternate_origin_branch "$case_dir" fm/task-x1-renamed

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "alt-origin-branch: teardown should release work pushed to origin under a different branch name"
  ! grep -q REFUSED "$case_dir/stderr" \
    || fail "alt-origin-branch: teardown printed a REFUSED line for work durable on origin"
  pass "worktree whose head is on origin under an alternate branch name is torn down"
}

# (ll) direct-push + HEAD pushed to origin under a DIFFERENT branch name than the
#      recorded one -> ALLOW. The any-origin-ref proof satisfies the direct-push
#      positive-proof requirement, so the branch-name probe is correctly skipped.
test_direct_push_head_on_alternate_origin_branch_allows() {
  local case_dir rc
  case_dir=$(make_case dp-alt-origin-branch)
  write_meta "$case_dir" direct-push ship
  wt_commit_file "$case_dir" feature.txt hello "validated work landed under a renamed branch"
  push_head_to_alternate_origin_branch "$case_dir" fm/task-x1-renamed

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "dp-alt-origin-branch: teardown should release direct-push work pushed to origin under a different branch name"
  ! grep -q REFUSED "$case_dir/stderr" \
    || fail "dp-alt-origin-branch: teardown printed a REFUSED line for work durable on origin"
  pass "direct-push worktree whose head is on origin under an alternate branch name is torn down"
}

# (mm) HEAD reachable from origin's DEFAULT branch under no branch name (merged/rebased
#      in on origin) -> ALLOW. head_on_any_origin_ref sees the origin default ref.
test_head_on_origin_default_via_any_ref_allows() {
  local case_dir rc
  case_dir=$(make_case any-ref-origin-default)
  write_meta "$case_dir" no-mistakes ship
  detach_worktree_at_origin_default "$case_dir" feature.txt hello
  # Drop the local remote-tracking refs so only a fresh fetch can prove durability.
  git -C "$case_dir/project" for-each-ref --format='%(refname)' refs/remotes/origin \
    | while IFS= read -r ref; do
        git -C "$case_dir/project" update-ref -d "$ref" 2>/dev/null || true
      done

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "any-ref-origin-default: teardown should release a head already on origin's default branch"
  ! grep -q REFUSED "$case_dir/stderr" \
    || fail "any-ref-origin-default: teardown printed a REFUSED line for merged-in work"
  pass "worktree whose head is reachable from origin's default branch is torn down"
}

# (nn) the alternate-branch broadening must NOT release genuinely unpushed work: the
#      recorded branch is absent from origin AND no other origin ref contains HEAD.
test_alternate_branch_broadening_still_refuses_unpushed() {
  local case_dir rc
  case_dir=$(make_case alt-branch-still-unpushed)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "genuinely unpushed work"
  # An unrelated branch exists on origin but does NOT contain HEAD.
  git -C "$case_dir/wt" push -q origin "HEAD~0:refs/heads/unrelated" 2>/dev/null || true
  git -C "$case_dir/project" for-each-ref --format='%(refname)' refs/remotes/origin \
    | while IFS= read -r ref; do
        git -C "$case_dir/project" update-ref -d "$ref" 2>/dev/null || true
      done
  # Now advance HEAD past what any origin ref holds so nothing on origin contains it.
  wt_commit_file "$case_dir" feature.txt more "further unpushed work never on origin"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "alt-branch-still-unpushed: teardown should refuse work no origin ref contains"
  grep -q REFUSED "$case_dir/stderr" \
    || fail "alt-branch-still-unpushed: no REFUSED line in stderr"
  pass "alternate-branch broadening still refuses work absent from every origin ref (safety preserved)"
}

# --- extra (separately-leased BE) worktree return -----------------------------
# A lane can lease a SECOND treehouse worktree beyond the primary (a full-stack
# lane's paired backend checkout). It is recorded at lease time as an
# extra_worktree=<clone>\t<worktree> meta line. Teardown must return BOTH worktrees
# to their pools, protect the extra worktree with the SAME unlanded-work refusal as
# the primary, and leave a lane WITHOUT a second worktree unchanged.

# Replace the treehouse mock with one that appends each `treehouse return --force
# <path>` target to $case_dir/returned.log, so a test can assert exactly which
# worktrees were returned. Args: case_dir
add_return_logging_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = return ]; then
  shift
  for a in "\$@"; do
    case "\$a" in
      --force) ;;
      *) printf '%s\n' "\$a" >> "$case_dir/returned.log" ;;
    esac
  done
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# Create a SECOND clone of the same origin plus a worktree of it on a task branch,
# then record it against the task as an extra_worktree line. Args: case_dir
add_extra_worktree() {
  local case_dir=$1
  git clone -q "$case_dir/origin.git" "$case_dir/project-be"
  git -C "$case_dir/project-be" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project-be" worktree add -q -b fm/task-x1-be "$case_dir/wt-be" main
  printf 'extra_worktree=%s\t%s\n' "$case_dir/project-be" "$case_dir/wt-be" \
    >> "$case_dir/state/task-x1.meta"
}

# (extra-1) a lane with a second BE worktree returns BOTH worktrees to their pools.
test_extra_worktree_returns_both() {
  local case_dir rc
  case_dir=$(make_case extra-both)
  add_return_logging_treehouse "$case_dir"
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "primary shippable"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  add_extra_worktree "$case_dir"
  # The BE worktree's branch is pushed too, so it is landed and teardown-eligible.
  git -C "$case_dir/wt-be" push -q origin fm/task-x1-be
  git -C "$case_dir/project-be" fetch -q origin

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "extra-both: teardown should succeed and return both worktrees"
  ! grep -q REFUSED "$case_dir/stderr" || fail "extra-both: teardown printed a REFUSED line"
  [ -f "$case_dir/returned.log" ] || fail "extra-both: no worktree return was logged"
  grep -qxF "$case_dir/wt" "$case_dir/returned.log" \
    || fail "extra-both: primary worktree was not returned"$'\n'"$(cat "$case_dir/returned.log")"
  grep -qxF "$case_dir/wt-be" "$case_dir/returned.log" \
    || fail "extra-both: extra BE worktree was not returned"$'\n'"$(cat "$case_dir/returned.log")"
  [ "$(wc -l < "$case_dir/returned.log")" -eq 2 ] \
    || fail "extra-both: expected exactly two worktree returns"$'\n'"$(cat "$case_dir/returned.log")"
  pass "a lane with a separately-leased BE worktree returns BOTH worktrees on teardown"
}

# (extra-2) a lane WITHOUT a second worktree is unchanged: exactly one return, no
# error, no false lease-return attempt.
test_no_extra_worktree_unchanged() {
  local case_dir rc
  case_dir=$(make_case extra-none)
  add_return_logging_treehouse "$case_dir"
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "primary shippable"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "extra-none: teardown should succeed with a single worktree"
  ! grep -q REFUSED "$case_dir/stderr" || fail "extra-none: teardown printed a REFUSED line"
  [ "$(wc -l < "$case_dir/returned.log")" -eq 1 ] \
    || fail "extra-none: expected exactly one worktree return"$'\n'"$(cat "$case_dir/returned.log")"
  grep -qxF "$case_dir/wt" "$case_dir/returned.log" \
    || fail "extra-none: primary worktree was not returned"
  pass "a lane without a second worktree is unchanged (single return, no error)"
}

# (extra-3) a second worktree with unpushed-and-unlanded work triggers the SAME
# refusal as the primary, and nothing is returned.
test_extra_worktree_unlanded_refuses() {
  local case_dir rc
  case_dir=$(make_case extra-unlanded)
  add_return_logging_treehouse "$case_dir"
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "primary shippable"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  add_extra_worktree "$case_dir"
  # The BE worktree has a real unpushed change not landed anywhere (an empty commit
  # would leave the tree equal to main and count as content-landed).
  printf '%s\n' unlanded > "$case_dir/wt-be/be-feature.txt"
  git -C "$case_dir/wt-be" add -- be-feature.txt
  git -C "$case_dir/wt-be" -c user.email=t@t -c user.name=t \
    commit -q -m "unpushed BE work"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "extra-unlanded: teardown should refuse when the BE worktree has unlanded work"
  grep -q REFUSED "$case_dir/stderr" || fail "extra-unlanded: no REFUSED line in stderr"
  grep -qF "$case_dir/wt-be" "$case_dir/stderr" \
    || fail "extra-unlanded: refusal did not name the BE worktree"$'\n'"$(cat "$case_dir/stderr")"
  [ ! -f "$case_dir/returned.log" ] \
    || fail "extra-unlanded: a worktree was returned despite the refusal"$'\n'"$(cat "$case_dir/returned.log")"
  pass "a second worktree with unpushed-and-unlanded work refuses teardown (same protection as primary)"
}

# (extra-4) --force discards an unlanded second worktree the same way it does the
# primary, and still returns both worktrees.
test_extra_worktree_force_overrides_unlanded() {
  local case_dir rc
  case_dir=$(make_case extra-force)
  add_return_logging_treehouse "$case_dir"
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "primary work"
  add_extra_worktree "$case_dir"
  git -C "$case_dir/wt-be" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "unpushed BE work"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "extra-force: --force teardown should succeed and return both worktrees"
  [ -f "$case_dir/returned.log" ] || fail "extra-force: no worktree return was logged"
  grep -qxF "$case_dir/wt-be" "$case_dir/returned.log" \
    || fail "extra-force: extra BE worktree was not returned under --force"
  pass "--force discards and returns an unlanded second worktree alongside the primary"
}

# Auto-close (a): a MERGED branch auto-closes the ticket. direct-push autoland flow -
# the task branch is merged into origin's default branch, so teardown runs
# `tasks-axi done` itself instead of only printing the reminder.
test_merged_branch_auto_closes_ticket() {
  local case_dir out
  case_dir=$(make_case autoclose-merged)
  write_meta "$case_dir" direct-push ship
  wt_commit_file "$case_dir" feature.txt hello "validated work"
  merge_task_branch_into_origin_default "$case_dir"
  add_recording_tasks_axi "$case_dir"

  out=$(run_teardown "$case_dir") || fail "autoclose-merged: teardown failed for a merged branch"
  [ -f "$case_dir/tasks-axi-done.log" ] \
    || fail "autoclose-merged: teardown never called tasks-axi done: $out"
  grep -F 'done task-x1' "$case_dir/tasks-axi-done.log" >/dev/null \
    || fail "autoclose-merged: tasks-axi done was not called for task-x1: $(cat "$case_dir/tasks-axi-done.log")"
  grep -F 'auto-closed at teardown' "$case_dir/tasks-axi-done.log" >/dev/null \
    || fail "autoclose-merged: close note missing the auto-close evidence: $(cat "$case_dir/tasks-axi-done.log")"
  printf '%s\n' "$out" | grep -F 'auto-closed task-x1 at teardown' >/dev/null \
    || fail "autoclose-merged: teardown did not report the auto-close: $out"
  printf '%s\n' "$out" | grep -F 'just finished. Run tasks-axi done' >/dev/null \
    && fail "autoclose-merged: teardown still printed the manual done reminder: $out"
  pass "a verifiably merged branch auto-closes its backlog ticket at teardown"
}

# Auto-close (b): a pushed-but-UNMERGED branch does NOT auto-close. It goes to the
# merge queue and keeps the plain print-reminder, because the merge has not happened.
test_pushed_unmerged_does_not_auto_close_ticket() {
  local case_dir out
  case_dir=$(make_case autoclose-pushed-unmerged)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "pushed unmerged work"
  push_branch_then_forget_local_ref "$case_dir"
  add_recording_tasks_axi "$case_dir"

  out=$(run_teardown "$case_dir") || fail "autoclose-pushed-unmerged: teardown failed"
  [ -f "$case_dir/tasks-axi-done.log" ] \
    && fail "autoclose-pushed-unmerged: teardown wrongly auto-closed an unmerged branch: $(cat "$case_dir/tasks-axi-done.log")"
  printf '%s\n' "$out" | grep -F 'just finished. Run tasks-axi done' >/dev/null \
    || fail "autoclose-pushed-unmerged: teardown dropped the manual done reminder: $out"
  pass "a pushed-but-unmerged branch is NOT auto-closed (stays open for the merge queue)"
}

# Auto-close (c): config/backlog-backend=manual never auto-closes, even for a merged
# branch. It falls back to the manual hand-edit reminder.
test_manual_backend_does_not_auto_close_merged_ticket() {
  local case_dir out
  case_dir=$(make_case autoclose-manual-backend)
  write_meta "$case_dir" direct-push ship
  wt_commit_file "$case_dir" feature.txt hello "validated work"
  merge_task_branch_into_origin_default "$case_dir"
  add_recording_tasks_axi "$case_dir"
  printf '%s\n' manual > "$case_dir/config/backlog-backend"

  out=$(run_teardown "$case_dir") || fail "autoclose-manual-backend: teardown failed"
  [ -f "$case_dir/tasks-axi-done.log" ] \
    && fail "autoclose-manual-backend: manual backend still auto-closed via tasks-axi: $(cat "$case_dir/tasks-axi-done.log")"
  printf '%s\n' "$out" | grep -F 'Update data/backlog.md - move task-x1 to Done' >/dev/null \
    || fail "autoclose-manual-backend: manual hand-edit reminder missing: $out"
  pass "config/backlog-backend=manual never auto-closes, even for a merged branch"
}

# Auto-close (d): a FAILED close still completes teardown. The worktree is released,
# and teardown warns loudly and prints the manual done command rather than aborting.
test_failed_auto_close_still_completes_teardown() {
  local case_dir rc out err
  case_dir=$(make_case autoclose-close-fails)
  write_meta "$case_dir" direct-push ship
  wt_commit_file "$case_dir" feature.txt hello "validated work"
  merge_task_branch_into_origin_default "$case_dir"
  add_failing_done_tasks_axi "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  out=$(cat "$case_dir/stdout"); err=$(cat "$case_dir/stderr")

  expect_code 0 "$rc" "autoclose-close-fails: teardown must complete despite a backlog-close failure"
  printf '%s\n' "$out" | grep -F "teardown task-x1 complete" >/dev/null \
    || fail "autoclose-close-fails: worktree release did not complete: $out"
  printf '%s\n' "$err" | grep -F 'could not auto-close task-x1' >/dev/null \
    || fail "autoclose-close-fails: no loud warning about the failed close: $err"
  [ -f "$case_dir/tasks-axi-done.log" ] \
    || fail "autoclose-close-fails: teardown never attempted the close"
  pass "a failed backlog close warns loudly but never blocks the worktree release"
}

# An interactive task (kind=interactive) shares scout's scratch-report teardown
# contract: with no session log at data/<id>/report.md, teardown must REFUSE
# exactly as it does for a scout, naming the true kind in the message.
test_interactive_without_report_refuses() {
  local case_dir rc err
  case_dir=$(make_case interactive-no-report)
  write_meta "$case_dir" no-mistakes interactive
  # A scratch commit that a ship lane would need landed; interactive must not care.
  wt_commit "$case_dir" "scratch during the guided op"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  err=$(cat "$case_dir/stderr")

  expect_code 1 "$rc" "interactive-no-report: teardown should refuse without a session log"
  printf '%s\n' "$err" | grep -F 'REFUSED: interactive task task-x1 has no report' >/dev/null \
    || fail "interactive-no-report: refusal did not name the interactive kind: $err"
  pass "interactive teardown refuses when the session log is missing (scout scratch contract)"
}

# With the session log present and the unresolved-decision inventory reviewed, an
# interactive task tears down as a scratch lane even though its worktree carries
# unpushed commits a ship lane would have to land first.
test_interactive_with_report_allows_scratch() {
  local case_dir rc err
  case_dir=$(make_case interactive-report-ok)
  write_meta "$case_dir" no-mistakes interactive
  # Mark the unresolved-decision inventory reviewed, as fm-decision-hold complete does.
  printf '%s\n' 'decisions_reviewed=1' >> "$case_dir/state/task-x1.meta"
  # Unpushed scratch commit: a ship lane refuses on this; a scratch lane does not.
  wt_commit "$case_dir" "scratch during the guided op"
  # The session log is the surviving deliverable.
  mkdir -p "$case_dir/data/task-x1"
  printf '%s\n' '# interactive session log' > "$case_dir/data/task-x1/report.md"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  err=$(cat "$case_dir/stderr")

  expect_code 0 "$rc" "interactive-report-ok: teardown should release the scratch worktree"
  ! grep -q REFUSED "$case_dir/stderr" || fail "interactive-report-ok: teardown printed a REFUSED line: $err"
  pass "interactive teardown releases a scratch worktree once the session log exists"
}

test_local_only_fork_remote_allows
test_scout_report_with_tldr_no_warning
test_scout_report_without_tldr_warns_but_allows
test_pushed_unmerged_releases_and_records_merge_queue
test_extra_worktree_returns_both
test_no_extra_worktree_unchanged
test_extra_worktree_unlanded_refuses
test_extra_worktree_force_overrides_unlanded
test_forced_pushed_unmerged_still_records_merge_queue
test_pushed_unmerged_content_equivalent_still_records_merge_queue
test_merged_pr_branch_is_not_recorded_in_merge_queue
test_errored_unproven_branch_reports_and_records
test_pushed_with_extra_local_commit_refuses
test_pushed_but_dirty_refuses
test_pushed_but_origin_unreachable_refuses
test_teardown_prompts_tasks_axi_done_when_compatible
test_teardown_manual_backend_prompts_hand_edit_even_when_tasks_axi_present
test_local_only_truly_unpushed_refuses
test_local_only_merged_to_local_main_allows
test_no_mistakes_origin_remote_allows
test_no_mistakes_truly_unpushed_refuses
test_local_only_force_overrides_unpushed
test_herdr_teardown_clears_escalation_marker
test_herdr_projection_teardown_retires_journal_only_after_confirmed_close
test_herdr_projection_teardown_retains_journal_when_close_unconfirmed
test_squash_merged_branch_deleted_allows
test_squash_merged_pr_allows_when_head_ancestor_of_pr_head
test_no_pr_recorded_discovers_merged_pr_by_branch_allows
test_squash_merged_pr_allows_replayed_unpushed_patch
test_merged_pr_with_later_local_commit_refuses
test_pr_check_does_not_refresh_stale_pr_head
test_pr_check_records_remote_head_when_local_lags
test_content_in_default_fallback_allows
test_content_fallback_refreshes_stale_origin_ref
test_dirty_worktree_refuses
test_gh_error_and_content_absent_refuses
test_stale_index_lock_cleared_and_teardown_succeeds
test_live_index_lock_is_never_removed_and_teardown_refuses
test_lsof_error_never_clears_index_lock
test_stale_index_lock_cleanup_rechecks_dirty_worktree
test_non_linked_index_lock_path_is_checked_from_worktree
test_index_lock_mtime_read_failure_refuses
test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds
test_persistent_index_lock_exhausts_retries_and_refuses_loudly
test_empty_retry_wait_uses_default_without_aborting
test_fractional_legacy_retry_wait_refuses_without_arithmetic_error
test_direct_push_branch_absent_from_origin_refuses
test_direct_push_ls_remote_failure_refuses
test_direct_push_branch_on_origin_allows
test_direct_push_stale_origin_ref_refuses
test_direct_push_origin_ahead_of_head_allows
test_direct_push_force_overrides_missing_origin_branch
test_direct_push_detached_head_contained_in_origin_default_allows
test_direct_push_scratch_branch_at_origin_default_allows
test_direct_push_contained_in_shared_local_default_allows
test_merged_into_shared_local_default_allows
test_standalone_clone_local_default_does_not_count_as_landed
test_contained_in_default_but_dirty_refuses
test_detached_head_absent_from_every_default_refuses
test_head_on_alternate_origin_branch_allows
test_direct_push_head_on_alternate_origin_branch_allows
test_head_on_origin_default_via_any_ref_allows
test_alternate_branch_broadening_still_refuses_unpushed
test_merged_branch_auto_closes_ticket
test_pushed_unmerged_does_not_auto_close_ticket
test_manual_backend_does_not_auto_close_merged_ticket
test_failed_auto_close_still_completes_teardown
test_interactive_without_report_refuses
test_interactive_with_report_allows_scratch
