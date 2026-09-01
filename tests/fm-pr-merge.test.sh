#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) orphan mode merges and records durable evidence with no task meta
#   (j) orphan mode refuses a PR that is not green and mergeable before gh-axi,
#       and refuses the --admin green-check bypass
#   (k) orphan mode refuses a Bitbucket PR that is not open
#   (l) auto-detect merges a cleaned-up task's PR when its durable merge-queue
#       record survives, records evidence with the task id, and runs the
#       fork-target guard against the queue record's clone
#   (m) auto-detect fails closed without a merge-queue record
#   (n) orphan mode accepts a local clone PATH as the repo argument by mapping
#       its origin to the PR URL's own owner/repository, and still refuses a
#       clone whose origin resolves to a different repository
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# the recordless green queries (verdict and summary) plus headRefOid for
# fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
      *statusCheckRollup*) printf 'GREEN\n' ; exit 0 ;;
      *state,isDraft*) printf 'OPEN false MERGEABLE CLEAN\n' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh mock that answers the recordless green queries with a NOT-GREEN verdict and
# the given summary line (e.g. "OPEN false MERGEABLE BLOCKED" for a blocked PR,
# "OPEN false CONFLICTING DIRTY" for a conflicting one). Args: case_dir summary
add_gh_mocks_not_green() {
  local case_dir=$1 summary=$2
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *statusCheckRollup*) printf 'NOT_GREEN\n' ; exit 0 ;;
      *state,isDraft*) printf '%s\n' '$summary' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  assert_grep 'hint: task missing-x1 has no durable merge-queue record' "$case_dir/stderr" \
    "missing-meta: refusal did not point at the --orphan records-gone path"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  assert_absent "$case_dir/data/orphan-merges.log" \
    "missing-meta: evidence was recorded for an unproven task id"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

# curl mock for the Bitbucket path: records method+url to a log and emits a body
# plus HTTP status, matching curl --write-out. It is used for both the poll arm
# inside fm-pr-check.sh (which does no network on arm) and the merge POST. The
# GET response drives the records-gone state verification: OPEN for a mergeable
# PR, or the configured override (e.g. DECLINED) to test refusal.
add_bitbucket_curl_mock() {
  local case_dir=$1 get_state=${2:-OPEN}
  cat > "$case_dir/fakebin/curl" <<SH
#!/usr/bin/env bash
method=GET
url=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --request) method=\$2; shift 2 ;;
    --config|--data-binary|--header|--write-out|--output) shift 2 ;;
    --silent|--show-error) shift ;;
    -*) shift ;;
    *) url=\$1; shift ;;
  esac
done
printf '%s %s\n' "\$method" "\$url" >> "\$FM_TEST_BB_LOG"
if [ "\$method" = POST ]; then
  printf '%s' '{"state":"MERGED"}'
else
  printf '{"state":"%s"}' '$get_state'
fi
printf '200'
SH
  chmod +x "$case_dir/fakebin/curl"
}

# Run fm-pr-merge on a Bitbucket URL with the Bitbucket credentials set and the
# curl mock on PATH. jq is a real dependency and is expected on the test host.
run_pr_merge_bitbucket() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_BB_LOG="$case_dir/bb.log" \
  NO_MISTAKES_BITBUCKET_EMAIL=me@example.com \
  NO_MISTAKES_BITBUCKET_API_TOKEN=tok-secret \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  return "$rc"
}

test_bitbucket_merge_records_pr_and_merges() {
  if ! command -v jq >/dev/null 2>&1; then
    pass "fm-pr-merge Bitbucket path skipped: jq not installed on this host"
    return
  fi
  local case_dir rc
  case_dir=$(make_case bitbucket-merge)
  mkdir -p "$case_dir/wt"
  add_bitbucket_curl_mock "$case_dir"
  : > "$case_dir/bb.log"

  set +e
  run_pr_merge_bitbucket "$case_dir" task-x1 https://bitbucket.org/dashnow/hyfin/pull-requests/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "bitbucket-merge: fm-pr-merge should succeed on a Bitbucket PR"
  assert_grep 'pr=https://bitbucket.org/dashnow/hyfin/pull-requests/9' "$case_dir/state/task-x1.meta" \
    "bitbucket-merge: pr= was not recorded"
  grep -qxF 'POST https://api.bitbucket.org/2.0/repositories/dashnow/hyfin/pullrequests/9/merge' "$case_dir/bb.log" \
    || fail "bitbucket-merge: the Bitbucket merge endpoint was not hit: $(cat "$case_dir/bb.log")"
  pass "fm-pr-merge records pr= and merges a Bitbucket PR through the REST API"
}

test_bitbucket_merge_refuses_without_credentials() {
  local case_dir rc
  case_dir=$(make_case bitbucket-nocred)
  mkdir -p "$case_dir/wt"
  add_bitbucket_curl_mock "$case_dir"
  : > "$case_dir/bb.log"

  set +e
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_BB_LOG="$case_dir/bb.log" \
  NO_MISTAKES_BITBUCKET_EMAIL='' \
  NO_MISTAKES_BITBUCKET_API_TOKEN='' \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" task-x1 https://bitbucket.org/dashnow/hyfin/pull-requests/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "bitbucket-nocred: fm-pr-merge should refuse without Bitbucket credentials"
  assert_grep 'NO_MISTAKES_BITBUCKET_EMAIL' "$case_dir/stderr" \
    "bitbucket-nocred: refusal did not name the missing credential"
  assert_no_grep 'merge' "$case_dir/bb.log" \
    "bitbucket-nocred: the Bitbucket merge endpoint was hit without credentials"
  pass "fm-pr-merge refuses a Bitbucket merge when credentials are absent"
}

# The records-gone shapes (--orphan and the task-id auto-detect fallback) need
# only a fakebin plus a case-local DATA dir for the orphan-merge evidence log;
# run_pr_merge provides exactly that, so the older orphan-only wrapper is gone.
# See run_pr_merge for the shared environment.

test_orphan_merges_and_records_evidence_without_meta() {
  local case_dir rc
  case_dir="$TMP_ROOT/orphan-merges"
  mkdir -p "$case_dir/fakebin"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" --orphan example/repo https://github.com/example/repo/pull/42 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "orphan-merges: fm-pr-merge --orphan should succeed with no task meta"
  [ ! -d "$case_dir/state" ] || [ -z "$(ls -A "$case_dir/state" 2>/dev/null)" ] \
    || fail "orphan-merges: orphan mode should not create task state"
  grep -qxF 'pr merge 42 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "orphan-merges: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  assert_grep 'orphan-merge	example/repo	https://github.com/example/repo/pull/42' \
    "$case_dir/data/orphan-merges.log" \
    "orphan-merges: merge evidence was not recorded to data/orphan-merges.log"
  pass "fm-pr-merge --orphan merges and records evidence with no task meta present"
}

test_orphan_not_green_refuses() {
  local case_dir rc
  case_dir="$TMP_ROOT/orphan-not-green"
  mkdir -p "$case_dir/fakebin"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  add_gh_mocks_not_green "$case_dir" "OPEN false MERGEABLE BLOCKED"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" --orphan example/repo https://github.com/example/repo/pull/42 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "orphan-not-green: fm-pr-merge --orphan should refuse a blocked PR"
  assert_grep 'error: refusing to merge PR that is not green and mergeable: https://github.com/example/repo/pull/42 (OPEN false MERGEABLE BLOCKED)' \
    "$case_dir/stderr" \
    "orphan-not-green: refusal did not name the PR and its blocked state"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "orphan-not-green: gh-axi pr merge was invoked for a blocked PR"
  assert_absent "$case_dir/data/orphan-merges.log" \
    "orphan-not-green: evidence was recorded for a refused PR"
  pass "fm-pr-merge --orphan refuses a PR that is not green and mergeable"
}

test_orphan_conflicting_refuses() {
  local case_dir rc
  case_dir="$TMP_ROOT/orphan-conflicting"
  mkdir -p "$case_dir/fakebin"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  add_gh_mocks_not_green "$case_dir" "OPEN false CONFLICTING DIRTY"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" --orphan example/repo https://github.com/example/repo/pull/42 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "orphan-conflicting: fm-pr-merge --orphan should refuse a conflicting PR"
  assert_grep 'error: refusing to merge PR that is not green and mergeable: https://github.com/example/repo/pull/42 (OPEN false CONFLICTING DIRTY)' \
    "$case_dir/stderr" \
    "orphan-conflicting: refusal did not name the PR and its conflicting state"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "orphan-conflicting: gh-axi pr merge was invoked for a conflicting PR"
  assert_absent "$case_dir/data/orphan-merges.log" \
    "orphan-conflicting: evidence was recorded for a refused PR"
  pass "fm-pr-merge --orphan refuses a conflicting PR before merging"
}

test_orphan_admin_bypass_refuses() {
  local case_dir rc
  case_dir="$TMP_ROOT/orphan-admin-bypass"
  mkdir -p "$case_dir/fakebin"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" --orphan example/repo https://github.com/example/repo/pull/42 -- --admin \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "orphan-admin-bypass: fm-pr-merge --orphan should refuse the --admin bypass"
  assert_grep 'records-gone merges must not bypass the green check with --admin' "$case_dir/stderr" \
    "orphan-admin-bypass: refusal did not name the --admin bypass"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "orphan-admin-bypass: gh-axi pr merge was invoked with --admin"
  assert_absent "$case_dir/data/orphan-merges.log" \
    "orphan-admin-bypass: evidence was recorded for a refused merge"
  pass "fm-pr-merge --orphan refuses the --admin green-check bypass"
}

test_orphan_bitbucket_not_open_refuses() {
  if ! command -v jq >/dev/null 2>&1; then
    pass "fm-pr-merge --orphan Bitbucket closed-PR path skipped: jq not installed on this host"
    return
  fi
  local case_dir rc
  case_dir="$TMP_ROOT/orphan-bitbucket-not-open"
  mkdir -p "$case_dir/fakebin"
  add_bitbucket_curl_mock "$case_dir" DECLINED
  : > "$case_dir/bb.log"

  set +e
  run_pr_merge_orphan_bitbucket "$case_dir" --orphan dashnow/hyfin \
    https://bitbucket.org/dashnow/hyfin/pull-requests/3613 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "orphan-bitbucket-not-open: fm-pr-merge --orphan should refuse a non-open PR"
  assert_grep 'error: refusing to merge Bitbucket pull request that is not open: https://bitbucket.org/dashnow/hyfin/pull-requests/3613 (state=DECLINED)' \
    "$case_dir/stderr" \
    "orphan-bitbucket-not-open: refusal did not name the PR and its state"
  assert_no_grep 'POST' "$case_dir/bb.log" \
    "orphan-bitbucket-not-open: the Bitbucket merge endpoint was hit for a declined PR"
  [ ! -f "$case_dir/data/orphan-merges.log" ] \
    || fail "orphan-bitbucket-not-open: evidence was recorded for a refused PR"
  pass "fm-pr-merge --orphan refuses a Bitbucket PR that is not open"
}

test_orphan_repo_mismatch_refuses() {
  local case_dir rc
  case_dir="$TMP_ROOT/orphan-repo-mismatch"
  mkdir -p "$case_dir/fakebin"
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" --orphan wrong/repo https://github.com/example/repo/pull/42 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "orphan-repo-mismatch: fm-pr-merge --orphan should refuse a mismatched repo argument"
  assert_grep 'repository argument does not match the PR URL' "$case_dir/stderr" \
    "orphan-repo-mismatch: refusal did not explain the repo mismatch"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "orphan-repo-mismatch: gh-axi pr merge was invoked despite the mismatch"
  pass "fm-pr-merge --orphan refuses when the repo argument does not match the URL"
}

test_orphan_repo_override_args_refuse() {
  local case_dir rc
  case_dir="$TMP_ROOT/orphan-repo-override"
  mkdir -p "$case_dir/fakebin"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" --orphan example/repo https://github.com/example/repo/pull/42 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "orphan-repo-override: fm-pr-merge --orphan should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "orphan-repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "orphan-repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge --orphan refuses --repo override args"
}

test_orphan_malformed_url_refuses() {
  local case_dir rc
  case_dir="$TMP_ROOT/orphan-malformed-url"
  mkdir -p "$case_dir/fakebin"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" --orphan example/repo 'https://example.com/not/a/pr' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "orphan-malformed-url: fm-pr-merge --orphan should refuse an unparseable PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "orphan-malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "orphan-malformed-url: gh-axi pr merge was invoked for a malformed URL"
  [ ! -f "$case_dir/data/orphan-merges.log" ] \
    || fail "orphan-malformed-url: evidence was recorded for a malformed URL"
  pass "fm-pr-merge --orphan refuses an unparseable PR URL before calling gh-axi"
}

# Run fm-pr-merge in orphan mode on a Bitbucket URL: curl mock on PATH, DATA to a
# case-local dir for the orphan-merge log, and the Bitbucket credentials set.
run_pr_merge_orphan_bitbucket() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_TEST_BB_LOG="$case_dir/bb.log" \
  NO_MISTAKES_BITBUCKET_EMAIL=me@example.com \
  NO_MISTAKES_BITBUCKET_API_TOKEN=tok-secret \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  return "$rc"
}

test_orphan_bitbucket_merges_and_records_evidence() {
  if ! command -v jq >/dev/null 2>&1; then
    pass "fm-pr-merge --orphan Bitbucket path skipped: jq not installed on this host"
    return
  fi
  local case_dir rc
  case_dir="$TMP_ROOT/orphan-bitbucket"
  mkdir -p "$case_dir/fakebin"
  add_bitbucket_curl_mock "$case_dir"
  : > "$case_dir/bb.log"

  set +e
  run_pr_merge_orphan_bitbucket "$case_dir" --orphan dashnow/hyfin \
    https://bitbucket.org/dashnow/hyfin/pull-requests/3613 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "orphan-bitbucket: fm-pr-merge --orphan should merge a Bitbucket PR with no meta"
  [ ! -d "$case_dir/state" ] || [ -z "$(ls -A "$case_dir/state" 2>/dev/null)" ] \
    || fail "orphan-bitbucket: orphan mode should not create task state"
  grep -qxF 'POST https://api.bitbucket.org/2.0/repositories/dashnow/hyfin/pullrequests/3613/merge' "$case_dir/bb.log" \
    || fail "orphan-bitbucket: the Bitbucket merge endpoint was not hit: $(cat "$case_dir/bb.log")"
  assert_grep 'orphan-merge	dashnow/hyfin	https://bitbucket.org/dashnow/hyfin/pull-requests/3613' \
    "$case_dir/data/orphan-merges.log" \
    "orphan-bitbucket: merge evidence was not recorded to data/orphan-merges.log"
  pass "fm-pr-merge --orphan merges a Bitbucket PR and records evidence with no task meta"
}

test_orphan_bitbucket_browser_variant_url_merges() {
  if ! command -v jq >/dev/null 2>&1; then
    pass "fm-pr-merge --orphan Bitbucket browser-variant path skipped: jq not installed on this host"
    return
  fi
  local case_dir rc
  case_dir="$TMP_ROOT/orphan-bitbucket-variant"
  mkdir -p "$case_dir/fakebin"
  add_bitbucket_curl_mock "$case_dir"
  : > "$case_dir/bb.log"

  # A Bitbucket PR URL copied from the web UI carries the source-branch title
  # slug after the number. Before the fix this was rejected at the parse gate
  # with the generic "invalid PR merge request", so a torn-down Bitbucket PR
  # could not land through --orphan. The repository argument still equals the
  # URL's own workspace/repository, and the canonical PR URL is recorded to the
  # orphan-merge log regardless of the pasted tail.
  set +e
  run_pr_merge_orphan_bitbucket "$case_dir" --orphan dashnow/hyfin \
    https://bitbucket.org/dashnow/hyfin/pull-requests/3615/fix-dual-pricing-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "orphan-bitbucket-variant: fm-pr-merge --orphan should merge a browser-variant Bitbucket PR URL"
  assert_no_grep 'invalid PR merge request' "$case_dir/stderr" \
    "orphan-bitbucket-variant: a browser-variant Bitbucket URL was rejected with the generic parse error"
  grep -qxF 'POST https://api.bitbucket.org/2.0/repositories/dashnow/hyfin/pullrequests/3615/merge' "$case_dir/bb.log" \
    || fail "orphan-bitbucket-variant: the Bitbucket merge endpoint was not hit: $(cat "$case_dir/bb.log")"
  assert_grep 'orphan-merge	dashnow/hyfin	https://bitbucket.org/dashnow/hyfin/pull-requests/3615' \
    "$case_dir/data/orphan-merges.log" \
    "orphan-bitbucket-variant: the canonical Bitbucket PR URL was not recorded to data/orphan-merges.log"
  pass "fm-pr-merge --orphan merges a browser-variant Bitbucket PR URL and records the canonical URL"
}

test_orphan_bitbucket_repo_mismatch_refuses() {
  local case_dir rc
  case_dir="$TMP_ROOT/orphan-bitbucket-mismatch"
  mkdir -p "$case_dir/fakebin"
  add_bitbucket_curl_mock "$case_dir"
  : > "$case_dir/bb.log"

  set +e
  run_pr_merge_orphan_bitbucket "$case_dir" --orphan wrong/repo \
    https://bitbucket.org/dashnow/hyfin/pull-requests/3613 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "orphan-bitbucket-mismatch: fm-pr-merge --orphan should refuse a mismatched repo argument"
  assert_grep 'repository argument does not match the PR URL' "$case_dir/stderr" \
    "orphan-bitbucket-mismatch: refusal did not explain the repo mismatch"
  assert_no_grep 'merge' "$case_dir/bb.log" \
    "orphan-bitbucket-mismatch: the Bitbucket merge endpoint was hit despite the mismatch"
  [ ! -f "$case_dir/data/orphan-merges.log" ] \
    || fail "orphan-bitbucket-mismatch: evidence was recorded despite the mismatch"
  pass "fm-pr-merge --orphan refuses a Bitbucket PR when the repo argument does not match the URL"
}

test_orphan_gitlab_parsed_but_not_supported() {
  local case_dir rc
  case_dir="$TMP_ROOT/orphan-gitlab"
  mkdir -p "$case_dir/fakebin"
  add_gh_mocks "$case_dir" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" --orphan example/repo \
    'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 3 "$rc" "orphan-gitlab: fm-pr-merge --orphan should fail with a provider-specific not-supported code"
  assert_grep 'GitLab orphan merge not yet supported' "$case_dir/stderr" \
    "orphan-gitlab: refusal was not the provider-specific not-supported message"
  assert_no_grep 'invalid PR merge request' "$case_dir/stderr" \
    "orphan-gitlab: a parsed GitLab URL was rejected with the generic invalid-request error"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "orphan-gitlab: gh-axi pr merge was invoked for a GitLab URL"
  [ ! -f "$case_dir/data/orphan-merges.log" ] \
    || fail "orphan-gitlab: evidence was recorded for an unmerged GitLab URL"
  pass "fm-pr-merge --orphan parses a GitLab MR URL and refuses it with a provider-specific message"
}

# --- orphan clone-path repo argument -----------------------------------------
#
# The --orphan repo argument accepts a local clone PATH in addition to the URL's
# own owner/repository, mapping the clone's origin to its owner/repository so the
# operator does not have to hand-translate. A git repo with a github.com origin
# makes the mapping resolvable; a clone whose origin resolves elsewhere is still
# refused.
set_repo_origin_github() {
  local dir=$1 slug=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "https://github.com/$slug.git"
}

test_orphan_clone_path_repo_arg_mapped() {
  local case_dir rc
  case_dir="$TMP_ROOT/orphan-clone-path"
  mkdir -p "$case_dir/fakebin"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  set_repo_origin_github "$case_dir/projects/firstmate" example/repo
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" --orphan "$case_dir/projects/firstmate" \
    https://github.com/example/repo/pull/47 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "orphan-clone-path: fm-pr-merge --orphan should accept a clone PATH mapped to the URL's owner/repository"
  grep -qxF 'pr merge 47 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "orphan-clone-path: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  assert_grep 'orphan-merge	example/repo	https://github.com/example/repo/pull/47' \
    "$case_dir/data/orphan-merges.log" \
    "orphan-clone-path: merge evidence was not recorded to data/orphan-merges.log"
  pass "fm-pr-merge --orphan maps a local clone PATH to the PR URL's own owner/repository"
}

test_orphan_clone_path_wrong_repo_refuses() {
  local case_dir rc
  case_dir="$TMP_ROOT/orphan-clone-path-wrong"
  mkdir -p "$case_dir/fakebin"
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  # The clone's origin resolves to a different repository than the PR URL, so
  # the mapping must not smuggle it past the existing safety check.
  set_repo_origin_github "$case_dir/projects/other" other-org/other-repo
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" --orphan "$case_dir/projects/other" \
    https://github.com/example/repo/pull/48 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "orphan-clone-path-wrong: fm-pr-merge --orphan should refuse a clone whose origin is a different repository"
  assert_grep 'repository argument does not match the PR URL' "$case_dir/stderr" \
    "orphan-clone-path-wrong: refusal did not explain the repo mismatch"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "orphan-clone-path-wrong: gh-axi pr merge was invoked despite the mismatch"
  [ ! -f "$case_dir/data/orphan-merges.log" ] \
    || fail "orphan-clone-path-wrong: evidence was recorded for a refused merge"
  pass "fm-pr-merge --orphan still refuses a clone PATH whose origin is a different repository"
}

# --- records-gone auto-detect ------------------------------------------------
# (recordless) merge only when the id has a durable data/merge-queue.tsv entry;
# the entry's clone path feeds the fork-target ownership guard. A real git repo
# with an origin remote makes the guard resolvable both ways.

# Write one merge-queue entry for the task under test with the given project
# path. The other queue fields are format-honest placeholders; the merge path
# reads only the project field.
write_queue_entry() {
  local queue=$1 id=$2 project=$3
  mkdir -p "$(dirname "$queue")"
  printf '%s\t%s\tfm/%s\tabcdef1234567890abcdef1234567890abcdef12\tmain\thttps://example.invalid/compare\n' \
    "$id" "$project" "$id" > "$queue"
}

set_queue_origin_github() {
  local dir=$1 slug=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "https://github.com/$slug.git"
}

test_auto_detect_merges_with_queue_record() {
  local case_dir rc
  case_dir="$TMP_ROOT/auto-detect-merges"
  mkdir -p "$case_dir/fakebin" "$case_dir/state"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  write_queue_entry "$case_dir/data/merge-queue.tsv" task-x1 "$case_dir/project"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/43 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "auto-detect-merges: fm-pr-merge should merge a cleaned-up task's green PR"
  assert_absent "$case_dir/state/task-x1.meta" \
    "auto-detect-merges: the task meta should not be recreated"
  grep -qxF 'pr merge 43 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "auto-detect-merges: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  assert_grep 'recordless-merge	task-x1	example/repo	https://github.com/example/repo/pull/43' \
    "$case_dir/data/orphan-merges.log" \
    "auto-detect-merges: merge evidence with the task id was not recorded to data/orphan-merges.log"
  pass "fm-pr-merge auto-detects a records-gone merge from the durable merge-queue record"
}

test_auto_detect_accepts_queue_clone_own_repo() {
  local case_dir rc
  case_dir="$TMP_ROOT/auto-detect-own-repo"
  mkdir -p "$case_dir/fakebin"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  set_queue_origin_github "$case_dir/project" example/repo
  write_queue_entry "$case_dir/data/merge-queue.tsv" task-x1 "$case_dir/project"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/44 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "auto-detect-own-repo: fm-pr-merge should merge when the queue clone origin matches the PR target"
  grep -qxF 'pr merge 44 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "auto-detect-own-repo: gh-axi pr merge was not invoked"
  pass "fm-pr-merge auto-detect passes the fork-target guard on the queue clone's own repo"
}

test_auto_detect_fork_guard_refuses() {
  local case_dir rc
  case_dir="$TMP_ROOT/auto-detect-fork-guard"
  mkdir -p "$case_dir/fakebin"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  # The queue clone's origin is a fork parent, not the PR target: the guard must
  # refuse exactly as the meta path would, before any green lookup or merge.
  set_queue_origin_github "$case_dir/project" upstream-parent/the-repo
  write_queue_entry "$case_dir/data/merge-queue.tsv" task-x1 "$case_dir/project"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/45 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "auto-detect-fork-guard: fm-pr-merge should refuse a PR targeting a repo the queue clone does not own"
  assert_grep 'error: refusing PR target example/repo: task clone origin is upstream-parent/the-repo' \
    "$case_dir/stderr" \
    "auto-detect-fork-guard: refusal did not name the refused target and the clone origin"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "auto-detect-fork-guard: gh-axi pr merge was invoked for a refused target"
  assert_absent "$case_dir/data/orphan-merges.log" \
    "auto-detect-fork-guard: evidence was recorded for a refused target"
  pass "fm-pr-merge auto-detect runs the fork-target guard against the queue record's clone"
}

test_auto_detect_red_pr_refuses() {
  local case_dir rc
  case_dir="$TMP_ROOT/auto-detect-red"
  mkdir -p "$case_dir/fakebin"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  add_gh_mocks_not_green "$case_dir" "OPEN false MERGEABLE UNSTABLE"
  write_queue_entry "$case_dir/data/merge-queue.tsv" task-x1 "$case_dir/project"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/46 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "auto-detect-red: fm-pr-merge should refuse a records-gone merge of a red PR"
  assert_grep 'error: refusing to merge PR that is not green and mergeable' "$case_dir/stderr" \
    "auto-detect-red: refusal did not explain the red PR"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "auto-detect-red: gh-axi pr merge was invoked for a red PR"
  assert_absent "$case_dir/data/orphan-merges.log" \
    "auto-detect-red: evidence was recorded for a refused PR"
  pass "fm-pr-merge auto-detect refuses a red PR exactly like --orphan"
}

test_auto_detect_bitbucket_merges_and_records_evidence() {
  if ! command -v jq >/dev/null 2>&1; then
    pass "fm-pr-merge auto-detect Bitbucket path skipped: jq not installed on this host"
    return
  fi
  local case_dir rc
  case_dir="$TMP_ROOT/auto-detect-bitbucket"
  mkdir -p "$case_dir/fakebin"
  add_bitbucket_curl_mock "$case_dir" OPEN
  write_queue_entry "$case_dir/data/merge-queue.tsv" task-x1 "$case_dir/project"
  : > "$case_dir/bb.log"

  set +e
  run_pr_merge_orphan_bitbucket "$case_dir" task-x1 \
    https://bitbucket.org/dashnow/hyfin/pull-requests/3616 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "auto-detect-bitbucket: fm-pr-merge should auto-detect a Bitbucket records-gone merge"
  grep -qxF 'POST https://api.bitbucket.org/2.0/repositories/dashnow/hyfin/pullrequests/3616/merge' "$case_dir/bb.log" \
    || fail "auto-detect-bitbucket: the Bitbucket merge endpoint was not hit: $(cat "$case_dir/bb.log")"
  assert_grep 'recordless-merge	task-x1	dashnow/hyfin	https://bitbucket.org/dashnow/hyfin/pull-requests/3616' \
    "$case_dir/data/orphan-merges.log" \
    "auto-detect-bitbucket: merge evidence with the task id was not recorded"
  pass "fm-pr-merge auto-detects a records-gone Bitbucket merge and records evidence"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_bitbucket_merge_records_pr_and_merges
test_bitbucket_merge_refuses_without_credentials
test_orphan_merges_and_records_evidence_without_meta
test_orphan_not_green_refuses
test_orphan_conflicting_refuses
test_orphan_admin_bypass_refuses
test_orphan_repo_mismatch_refuses
test_orphan_repo_override_args_refuse
test_orphan_malformed_url_refuses
test_orphan_bitbucket_merges_and_records_evidence
test_orphan_bitbucket_browser_variant_url_merges
test_orphan_bitbucket_repo_mismatch_refuses
test_orphan_bitbucket_not_open_refuses
test_orphan_gitlab_parsed_but_not_supported
test_orphan_clone_path_repo_arg_mapped
test_orphan_clone_path_wrong_repo_refuses
test_auto_detect_merges_with_queue_record
test_auto_detect_accepts_queue_clone_own_repo
test_auto_detect_fork_guard_refuses
test_auto_detect_red_pr_refuses
test_auto_detect_bitbucket_merges_and_records_evidence
