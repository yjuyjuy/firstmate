#!/usr/bin/env bash
# Characterization tests for bin/fm-bitbucket-pr.sh - the CLI that opens a
# Bitbucket Cloud pull request (the Bitbucket counterpart to `gh-axi pr create`).
#
# fm-bitbucket-lib.sh's own API functions are covered by fm-bitbucket-lib.test.sh;
# this file pins the ENTRYPOINT's argument handling and workspace/repo resolution:
#   - subcommand and required-argument validation exit before any network call.
#   - workspace/repo resolve from the git clone's bitbucket.org origin when not
#     given, and must be passed explicitly when origin is not a Bitbucket clone.
#   - an invalid workspace/repo slug is refused before curl is called.
#   - a successful open builds the canonical PR URL and hits the pullrequests
#     endpoint; the title defaults to the source branch when not given.
# All network is mocked with a fake curl (matching fm-bitbucket-lib.test.sh's
# scenario protocol: body then HTTP status, request logged to FM_TEST_BB_LOG). No
# real Bitbucket is ever contacted.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_CLI="$ROOT/bin/fm-bitbucket-pr.sh"
TMP_ROOT=$(fm_test_tmproot fm-bitbucket-pr-tests)

# A fake curl matching the library's --write-out '%{http_code}' contract: it
# prints the configured body then the status code, and logs "METHOD URL" so a
# test can assert the endpoint hit. Driven by FM_TEST_BB_BODY / FM_TEST_BB_STATUS.
make_fakebin() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/curl" <<'SH'
#!/usr/bin/env bash
method=GET
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --request) method=$2; shift 2 ;;
    --config) shift 2 ;;
    --data-binary) shift 2 ;;
    --header|--write-out|--output) shift 2 ;;
    --silent|--show-error) shift ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
printf '%s %s\n' "$method" "$url" >> "$FM_TEST_BB_LOG"
printf '%s' "${FM_TEST_BB_BODY:-}"
printf '%s' "${FM_TEST_BB_STATUS:-200}"
SH
  chmod +x "$dir/curl"
}

# Build a git clone whose origin is a bitbucket.org SSH URL for <ws>/<repo>.
make_bb_clone() {  # <dir> <ws> <repo>
  local dir=$1 ws=$2 repo=$3
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "git@bitbucket.org:$ws/$repo.git"
}

# Run the CLI. Args after <case_dir> are the CLI argv. Echoes stdout+stderr; exit
# status goes to $RC_FILE (read after the $(...) capture). The fake curl is on
# PATH and credentials are set so fm_bitbucket_ready passes unless a test clears
# them.
RC_FILE="$TMP_ROOT/bb-pr-rc"
run_cli() {  # <case_dir> <cli-args...>
  local case_dir=$1; shift
  mkdir -p "$case_dir/fakebin"
  make_fakebin "$case_dir/fakebin"
  FM_TEST_BB_LOG="$case_dir/curl.log" \
  NO_MISTAKES_BITBUCKET_EMAIL="${NO_MISTAKES_BITBUCKET_EMAIL-me@example.com}" \
  NO_MISTAKES_BITBUCKET_API_TOKEN="${NO_MISTAKES_BITBUCKET_API_TOKEN-tok-secret}" \
  FM_TEST_BB_BODY="${FM_TEST_BB_BODY-}" \
  FM_TEST_BB_STATUS="${FM_TEST_BB_STATUS-200}" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CLI" "$@" 2>&1
  printf '%s' "$?" > "$RC_FILE"
}
cli_rc() { cat "$RC_FILE"; }

test_no_subcommand_usage() {
  local case_dir="$TMP_ROOT/nosub" out
  out=$(run_cli "$case_dir")
  expect_code 2 "$(cli_rc)" "no subcommand must exit 2"
  [ ! -s "$case_dir/curl.log" ] || fail "curl was called with no subcommand"
  pass "no subcommand prints usage and exits 2 before any network call"
}

test_unknown_subcommand() {
  local case_dir="$TMP_ROOT/badsub" out
  out=$(run_cli "$case_dir" close --source a --dest b)
  expect_code 2 "$(cli_rc)" "an unknown subcommand must exit 2"
  assert_contains "$out" "unknown subcommand: close" "the bad subcommand must be named"
  [ ! -s "$case_dir/curl.log" ] || fail "curl was called for an unknown subcommand"
  pass "an unknown subcommand is refused before any network call"
}

test_requires_source_and_dest() {
  local case_dir="$TMP_ROOT/noargs" out
  out=$(run_cli "$case_dir" open --workspace ws --repo r)
  expect_code 2 "$(cli_rc)" "missing --source/--dest must exit 2"
  assert_contains "$out" "--source and --dest are both required" "the missing-arg reason must be named"
  [ ! -s "$case_dir/curl.log" ] || fail "curl was called without source/dest"
  pass "missing --source/--dest is refused before any network call"
}

test_unknown_argument() {
  local case_dir="$TMP_ROOT/badarg" out
  out=$(run_cli "$case_dir" open --source a --dest b --bogus x)
  expect_code 2 "$(cli_rc)" "an unknown argument must exit 2"
  assert_contains "$out" "unknown argument: --bogus" "the unknown argument must be named"
  pass "an unknown argument is refused"
}

test_resolves_workspace_repo_from_origin() {
  local case_dir="$TMP_ROOT/resolve"
  mkdir -p "$case_dir"
  make_bb_clone "$case_dir/clone" dashnow hyfin
  local out
  out=$(FM_TEST_BB_BODY='{"id":77,"state":"OPEN"}' FM_TEST_BB_STATUS=201 \
    run_cli "$case_dir" open --source fm/x1 --dest dev -C "$case_dir/clone")
  expect_code 0 "$(cli_rc)" "a resolved open must exit 0"
  assert_contains "$out" "https://bitbucket.org/dashnow/hyfin/pull-requests/77" "canonical PR URL must be printed"
  # The endpoint uses the origin-resolved workspace/repo (FM_TEST_BB_LOG is an
  # absolute path, so the -C cwd change does not move it).
  grep -qxF 'POST https://api.bitbucket.org/2.0/repositories/dashnow/hyfin/pullrequests' "$case_dir/curl.log" \
    || fail "wrong endpoint hit: $(cat "$case_dir/curl.log")"
  pass "workspace/repo resolve from the clone's bitbucket origin"
}

test_requires_explicit_slug_without_bb_origin() {
  local case_dir="$TMP_ROOT/nonbb"
  mkdir -p "$case_dir/clone"
  git -C "$case_dir/clone" init -q
  git -C "$case_dir/clone" remote add origin 'git@github.com:o/r.git'
  local out
  out=$(run_cli "$case_dir" open --source fm/x1 --dest dev -C "$case_dir/clone")
  expect_code 1 "$(cli_rc)" "a non-bitbucket origin with no explicit slug must exit 1"
  assert_contains "$out" "could not resolve the Bitbucket workspace/repository" "must ask for --workspace/--repo"
  [ ! -s "$case_dir/curl.log" ] || fail "curl was called without a resolvable slug"
  pass "a non-Bitbucket origin requires explicit --workspace/--repo"
}

test_refuses_invalid_slug() {
  local case_dir="$TMP_ROOT/badslug" out
  out=$(run_cli "$case_dir" open --source fm/x1 --dest dev --workspace 'bad ws' --repo r)
  expect_code 1 "$(cli_rc)" "an invalid workspace slug must exit 1"
  assert_contains "$out" "invalid Bitbucket workspace" "the invalid slug must be named"
  [ ! -s "$case_dir/curl.log" ] || fail "curl was called for an invalid slug"
  pass "an invalid workspace slug is refused before any network call"
}

test_title_defaults_to_source_branch() {
  # No --title given: the entrypoint defaults it to the source branch. We prove it
  # by the successful open (jq builds the body from that title) plus the canonical
  # URL; the endpoint and success are the observable characterization.
  local case_dir="$TMP_ROOT/title" out
  out=$(FM_TEST_BB_BODY='{"id":5,"state":"OPEN"}' FM_TEST_BB_STATUS=201 \
    run_cli "$case_dir" open --source fm/title-branch --dest main --workspace ws --repo r)
  expect_code 0 "$(cli_rc)" "open with a defaulted title must exit 0"
  assert_contains "$out" "https://bitbucket.org/ws/r/pull-requests/5" "canonical PR URL must be printed"
  pass "the title defaults to the source branch and the open succeeds"
}

test_no_subcommand_usage
test_unknown_subcommand
test_requires_source_and_dest
test_unknown_argument
test_resolves_workspace_repo_from_origin
test_requires_explicit_slug_without_bb_origin
test_refuses_invalid_slug
test_title_defaults_to_source_branch

echo "# all fm-bitbucket-pr tests passed"
