#!/usr/bin/env bash
# Tests for bin/fm-merge-queue-poll.sh, the Bitbucket merge-queue watch:
# silent poll semantics over data/merge-queue.tsv (merged/declined wake lines,
# open and no-PR silence, GitHub and malformed entries skipped, credential and
# tool guards, .env fallback), and the arm/disarm custom-check lifecycle against
# the real fm-check-register.sh. All API traffic goes through a mock curl, so
# no network is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POLL="$ROOT/bin/fm-merge-queue-poll.sh"
REGISTER="$ROOT/bin/fm-check-register.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-queue-poll)

# Canned Bitbucket pullrequests responses, one file per branch with '/' mapped
# to '__' (a two-character mapping needs sed, not tr) so branches can be
# filenames, plus a default empty response for unknown branches.
resp_path() {
  printf '%s\n' "$1/$(printf '%s' "$2" | sed 's#/#__#g').json"
}

write_response() {
  local dir=$1 branch=$2 body=$3
  mkdir -p "$dir"
  printf '%s' "$body" > "$(resp_path "$dir" "$branch")"
}

default_response() {
  local dir=$1 f
  mkdir -p "$dir"
  # Overwrite every canned response with the empty body (no deletion), so a
  # caller can turn the whole fixture into "no pull requests anywhere".
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    printf '%s' '{"size":0,"values":[]}' > "$f"
  done
  printf '%s' '{"size":0,"values":[]}' > "$dir/_default.json"
}

pr_json() {
  local id=$1 state=$2
  printf '{"id":%s,"state":"%s","source":{"branch":{"name":"x"}},"destination":{"branch":{"name":"dev"}}}' \
    "$id" "$state"
}

# Build a fakebin curl that logs its argv to FM_TEST_LOG and copies the
# --config credential file to FM_TEST_CFG, then answers from the response
# directory by matching the branch name inside the q argument (response files
# map '/' to '__' so branches can be filenames).
make_fakebin() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/curl" <<'SH'
#!/usr/bin/env bash
url=
enc=
cfg=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) cfg=$2; shift 2 ;;
    --data-urlencode) enc="$enc $2"; shift 2 ;;
    --request) url="$2 $url"; shift 2 ;;
    --max-time) shift 2 ;;
    --header|--write-out|--output|--get) shift 2 ;;
    --silent|--show-error) shift ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
{ printf 'URL %s\n' "$url"; printf 'ENC%s\n' "$enc"; } >> "$FM_TEST_LOG"
[ -z "$cfg" ] || cat "$cfg" > "$FM_TEST_CFG" 2>/dev/null || true
resp=
for f in "$FM_TEST_RESP"/*.json; do
  [ -e "$f" ] || continue
  b=$(basename "$f" .json)
  b=${b//__/\/}
  case "$enc" in
    *"$b"*) resp=$f; break ;;
  esac
done
[ -n "$resp" ] || resp="$FM_TEST_RESP/_default.json"
cat "$resp"
SH
  chmod +x "$dir/curl"
}

# Run the poll against one fixture home. Env vars named as arguments are passed
# through; credentials are set to defaults unless the caller unsets them.
run_poll() {
  local fixture=$1; shift
  local envs=()
  while [ "$#" -gt 0 ]; do
    envs+=("$1")
    shift
  done
  env \
    FM_HOME="$fixture/home" \
    FM_DATA_OVERRIDE="$fixture/data" \
    FM_STATE_OVERRIDE="$fixture/state" \
    NO_MISTAKES_BITBUCKET_EMAIL="${NO_MISTAKES_BITBUCKET_EMAIL-me@example.com}" \
    NO_MISTAKES_BITBUCKET_API_TOKEN="${NO_MISTAKES_BITBUCKET_API_TOKEN-tok-secret}" \
    "${envs[@]}" \
    "$POLL"
}

# Standard fixture: a single Bitbucket entry whose branch resolves to a MERGED
# PR, plus canned responses for the branches the poll may be pointed at.
# Tests that need more queue entries append them to the queue file themselves.
make_fixture() {
  local fixture=$1
  mkdir -p "$fixture/data" "$fixture/state" "$fixture/fakebin" "$fixture/resp" "$fixture/home"
  default_response "$fixture/resp"
  write_response "$fixture/resp" fm/merged-branch \
    "{\"size\":1,\"values\":[$(pr_json 42 MERGED)]}"
  write_response "$fixture/resp" fm/open-branch \
    "{\"size\":1,\"values\":[$(pr_json 43 OPEN)]}"
  write_response "$fixture/resp" fm/declined-branch \
    "{\"size\":1,\"values\":[$(pr_json 44 DECLINED)]}"
  cat > "$fixture/data/merge-queue.tsv" <<'TSV'
# firstmate merge queue: fixture queue for fm-merge-queue-poll tests.
merged-task	/opt/hyfin-server	fm/merged-branch	abc123	dev	https://bitbucket.org/dashnow/hyfin-server/branch/fm/merged-branch?dest=dev
TSV
  make_fakebin "$fixture/fakebin"
}

test_merged_wakes_with_canonical_url() {
  local fixture; fixture="$TMP_ROOT/merged"; make_fixture "$fixture"
  write_response "$fixture/resp" fm/merged-branch \
    "{\"size\":1,\"values\":[$(pr_json 42 MERGED)]}"
  local out
  out=$(FM_TEST_LOG="$fixture/curl.log" FM_TEST_CFG="$fixture/cfg.captured" \
    FM_TEST_RESP="$fixture/resp" PATH="$fixture/fakebin:$PATH" run_poll "$fixture")
  grep -qxF 'merged: merged-task fm/merged-branch -> dev https://bitbucket.org/dashnow/hyfin-server/pull-requests/42' \
    <<<"$out" || fail "merged wake line wrong: $out"
  grep -qxF 'URL https://api.bitbucket.org/2.0/repositories/dashnow/hyfin-server/pullrequests' "$fixture/curl.log" \
    || fail "wrong endpoint hit: $(cat "$fixture/curl.log")"
  grep -qF 'q=source.branch.name="fm/merged-branch"' "$fixture/curl.log" \
    || fail "q query missing branch: $(cat "$fixture/curl.log")"
  grep -qF 'tok-secret' "$fixture/cfg.captured" || fail "token not passed via --config file"
  if grep -qF 'tok-secret' "$fixture/curl.log"; then
    fail "token leaked into curl argv"
  fi
  pass "merged PR wakes one line with the canonical PR URL"
}

test_open_is_silent() {
  local fixture; fixture="$TMP_ROOT/open"; make_fixture "$fixture"
  write_response "$fixture/resp" fm/merged-branch \
    "{\"size\":1,\"values\":[$(pr_json 42 OPEN)]}"
  local out
  out=$(FM_TEST_LOG="$fixture/curl.log" FM_TEST_CFG="$fixture/cfg.captured" \
    FM_TEST_RESP="$fixture/resp" PATH="$fixture/fakebin:$PATH" run_poll "$fixture")
  [ -z "$out" ] || fail "open PR should stay silent, got: $out"
  pass "open PR poll stays silent"
}

test_declined_wakes() {
  local fixture; fixture="$TMP_ROOT/declined"; make_fixture "$fixture"
  write_response "$fixture/resp" fm/merged-branch \
    "{\"size\":1,\"values\":[$(pr_json 42 DECLINED)]}"
  local out
  out=$(FM_TEST_LOG="$fixture/curl.log" FM_TEST_CFG="$fixture/cfg.captured" \
    FM_TEST_RESP="$fixture/resp" PATH="$fixture/fakebin:$PATH" run_poll "$fixture")
  grep -qxF 'declined: merged-task fm/merged-branch -> dev https://bitbucket.org/dashnow/hyfin-server/pull-requests/42' \
    <<<"$out" || fail "declined wake line wrong: $out"
  pass "declined PR wakes one line"
}

test_open_outranks_declined() {
  local fixture; fixture="$TMP_ROOT/mixed-declined-open"; make_fixture "$fixture"
  write_response "$fixture/resp" fm/merged-branch \
    "{\"size\":2,\"values\":[$(pr_json 41 DECLINED),$(pr_json 42 OPEN)]}"
  local out
  out=$(FM_TEST_LOG="$fixture/curl.log" FM_TEST_CFG="$fixture/cfg.captured" \
    FM_TEST_RESP="$fixture/resp" PATH="$fixture/fakebin:$PATH" run_poll "$fixture")
  [ -z "$out" ] || fail "an OPEN PR should silence a branch with a declined history, got: $out"
  pass "an open PR outranks a declined history"
}

test_merged_outranks_everything() {
  local fixture; fixture="$TMP_ROOT/mixed-declined-merged"; make_fixture "$fixture"
  write_response "$fixture/resp" fm/merged-branch \
    "{\"size\":2,\"values\":[$(pr_json 41 DECLINED),$(pr_json 42 MERGED)]}"
  local out
  out=$(FM_TEST_LOG="$fixture/curl.log" FM_TEST_CFG="$fixture/cfg.captured" \
    FM_TEST_RESP="$fixture/resp" PATH="$fixture/fakebin:$PATH" run_poll "$fixture")
  grep -qxF 'merged: merged-task fm/merged-branch -> dev https://bitbucket.org/dashnow/hyfin-server/pull-requests/42' \
    <<<"$out" || fail "merged should outrank declined, got: $out"
  pass "a merged PR outranks older closed states"
}

test_superseded_wakes_when_no_open_replacement() {
  local fixture; fixture="$TMP_ROOT/superseded"; make_fixture "$fixture"
  write_response "$fixture/resp" fm/merged-branch \
    "{\"size\":1,\"values\":[$(pr_json 42 SUPERSEDED)]}"
  local out
  out=$(FM_TEST_LOG="$fixture/curl.log" FM_TEST_CFG="$fixture/cfg.captured" \
    FM_TEST_RESP="$fixture/resp" PATH="$fixture/fakebin:$PATH" run_poll "$fixture")
  grep -qxF 'superseded: merged-task fm/merged-branch -> dev https://bitbucket.org/dashnow/hyfin-server/pull-requests/42' \
    <<<"$out" || fail "superseded wake line wrong: $out"
  pass "a superseded PR without an open replacement wakes"
}

test_no_prs_is_silent() {
  local fixture; fixture="$TMP_ROOT/nopr"; make_fixture "$fixture"
  default_response "$fixture/resp"
  local out
  out=$(FM_TEST_LOG="$fixture/curl.log" FM_TEST_CFG="$fixture/cfg.captured" \
    FM_TEST_RESP="$fixture/resp" PATH="$fixture/fakebin:$PATH" run_poll "$fixture")
  [ -z "$out" ] || fail "a branch without PRs should stay silent, got: $out"
  pass "a branch with no pull requests stays silent"
}

test_github_and_malformed_entries_skipped() {
  local fixture; fixture="$TMP_ROOT/skips"; make_fixture "$fixture"
  write_response "$fixture/resp" fm/merged-branch \
    "{\"size\":1,\"values\":[$(pr_json 42 MERGED)]}"
  cat >> "$fixture/data/merge-queue.tsv" <<'TSV'
github-task	/opt/firstmate	fm/gh-branch	abc126	main	https://github.com/yjuyjuy/firstmate/compare/main...fm/gh-branch
bad-url-task	/opt/hyfin-server	fm/unsafe"branch	abc127	dev	not a url
TSV
  local out
  out=$(FM_TEST_LOG="$fixture/curl.log" FM_TEST_CFG="$fixture/cfg.captured" \
    FM_TEST_RESP="$fixture/resp" PATH="$fixture/fakebin:$PATH" run_poll "$fixture")
  [ "$(wc -l <<<"$out" | tr -d ' ')" = 1 ] || fail "only the bitbucket entry should wake, got: $out"
  grep -qxF 'merged: merged-task fm/merged-branch -> dev https://bitbucket.org/dashnow/hyfin-server/pull-requests/42' \
    <<<"$out" || fail "unexpected wake set: $out"
  pass "GitHub and malformed entries are skipped silently"
}

test_all_states_from_one_queue() {
  local fixture; fixture="$TMP_ROOT/queue-states"; make_fixture "$fixture"
  cat >> "$fixture/data/merge-queue.tsv" <<'TSV'
open-task	/opt/hyfin-server	fm/open-branch	abc124	dev	https://bitbucket.org/dashnow/hyfin-server/branch/fm/open-branch?dest=dev
declined-task	/opt/hyfin-server	fm/declined-branch	abc125	dev	https://bitbucket.org/dashnow/hyfin-server/branch/fm/declined-branch?dest=dev
TSV
  local out
  out=$(FM_TEST_LOG="$fixture/curl.log" FM_TEST_CFG="$fixture/cfg.captured" \
    FM_TEST_RESP="$fixture/resp" PATH="$fixture/fakebin:$PATH" run_poll "$fixture")
  grep -qxF 'merged: merged-task fm/merged-branch -> dev https://bitbucket.org/dashnow/hyfin-server/pull-requests/42' \
    <<<"$out" || fail "merged line missing: $out"
  grep -qxF 'declined: declined-task fm/declined-branch -> dev https://bitbucket.org/dashnow/hyfin-server/pull-requests/44' \
    <<<"$out" || fail "declined line missing: $out"
  if grep -q 'open-task' <<<"$out"; then
    fail "open entry should stay silent: $out"
  fi
  pass "one queue poll wakes merged and declined and stays silent on open"
}

test_missing_queue_is_silent() {
  local fixture; fixture="$TMP_ROOT/absent"; make_fixture "$fixture"
  rm -f "$fixture/data/merge-queue.tsv"
  local out
  out=$(FM_TEST_LOG="$fixture/curl.log" FM_TEST_CFG="$fixture/cfg.captured" \
    FM_TEST_RESP="$fixture/resp" PATH="$fixture/fakebin:$PATH" run_poll "$fixture")
  [ -z "$out" ] || fail "absent queue should stay silent, got: $out"
  pass "an absent queue stays silent"
}

test_env_credentials_only() {
  local fixture; fixture="$TMP_ROOT/env-creds"; make_fixture "$fixture"
  write_response "$fixture/resp" fm/merged-branch \
    "{\"size\":1,\"values\":[$(pr_json 42 MERGED)]}"
  printf 'NO_MISTAKES_BITBUCKET_EMAIL=env@example.com\nNO_MISTAKES_BITBUCKET_API_TOKEN=env-tok\n' \
    > "$fixture/home/.env"
  chmod 0600 "$fixture/home/.env"
  local out
  out=$(env \
    FM_HOME="$fixture/home" \
    FM_DATA_OVERRIDE="$fixture/data" \
    FM_STATE_OVERRIDE="$fixture/state" \
    NO_MISTAKES_BITBUCKET_EMAIL= \
    NO_MISTAKES_BITBUCKET_API_TOKEN= \
    FM_TEST_LOG="$fixture/curl.log" \
    FM_TEST_CFG="$fixture/cfg.captured" \
    FM_TEST_RESP="$fixture/resp" \
    PATH="$fixture/fakebin:$PATH" \
    "$POLL")
  grep -qxF 'merged: merged-task fm/merged-branch -> dev https://bitbucket.org/dashnow/hyfin-server/pull-requests/42' \
    <<<"$out" || fail "poll should read credentials from .env, got: $out"
  grep -qF 'env-tok' "$fixture/cfg.captured" || fail "env-sourced token not used"
  pass "credentials fall back to the home .env"
}

test_no_credentials_is_silent() {
  local fixture; fixture="$TMP_ROOT/nocreds"; make_fixture "$fixture"
  local out
  out=$(env \
    FM_HOME="$fixture/home" \
    FM_DATA_OVERRIDE="$fixture/data" \
    FM_STATE_OVERRIDE="$fixture/state" \
    NO_MISTAKES_BITBUCKET_EMAIL= \
    NO_MISTAKES_BITBUCKET_API_TOKEN= \
    FM_TEST_LOG="$fixture/curl.log" \
    FM_TEST_CFG="$fixture/cfg.captured" \
    FM_TEST_RESP="$fixture/resp" \
    PATH="$fixture/fakebin:$PATH" \
    "$POLL")
  [ -z "$out" ] || fail "missing credentials should stay silent, got: $out"
  pass "missing credentials stay silent"
}

test_api_error_is_silent() {
  local fixture; fixture="$TMP_ROOT/apierr"; make_fixture "$fixture"
  # A Bitbucket error body has no .values; the poll must stay silent.
  write_response "$fixture/resp" fm/merged-branch \
    '{"type":"error","error":{"message":"boom"}}'
  local out
  out=$(FM_TEST_LOG="$fixture/curl.log" FM_TEST_CFG="$fixture/cfg.captured" \
    FM_TEST_RESP="$fixture/resp" PATH="$fixture/fakebin:$PATH" run_poll "$fixture")
  [ -z "$out" ] || fail "an API error body should stay silent, got: $out"
  pass "an API error stays silent"
}

test_unparsable_body_is_silent() {
  local fixture; fixture="$TMP_ROOT/garbage"; make_fixture "$fixture"
  write_response "$fixture/resp" fm/merged-branch '<html>gateway error</html>'
  local out
  out=$(FM_TEST_LOG="$fixture/curl.log" FM_TEST_CFG="$fixture/cfg.captured" \
    FM_TEST_RESP="$fixture/resp" PATH="$fixture/fakebin:$PATH" run_poll "$fixture")
  [ -z "$out" ] || fail "an unparsable body should stay silent, got: $out"
  pass "an unparsable API body stays silent"
}

test_missing_tools_are_silent() {
  local fixture; fixture="$TMP_ROOT/notools"; make_fixture "$fixture"
  # The poll itself checks curl/jq on PATH before any request, so running with
  # an empty PATH must silence the poll even when the queue has findings.
  local out
  out=$(env \
    FM_HOME="$fixture/home" FM_DATA_OVERRIDE="$fixture/data" FM_STATE_OVERRIDE="$fixture/state" \
    NO_MISTAKES_BITBUCKET_EMAIL=me@example.com NO_MISTAKES_BITBUCKET_API_TOKEN=tok-secret \
    PATH="/nonexistent" \
    "$(command -v bash)" "$POLL")
  [ -z "$out" ] || fail "missing curl/jq should stay silent, got: $out"
  pass "missing tools stay silent"
}

test_arm_writes_and_registers_shim() {
  local fixture; fixture="$TMP_ROOT/arm"; make_fixture "$fixture"
  local out shim
  out=$(env \
    FM_HOME="$fixture/home" FM_DATA_OVERRIDE="$fixture/data" FM_STATE_OVERRIDE="$fixture/state" \
    NO_MISTAKES_BITBUCKET_EMAIL=me@example.com NO_MISTAKES_BITBUCKET_API_TOKEN=tok-secret \
    "$POLL" arm merge-queue-poll)
  grep -qxF 'armed: state/merge-queue-poll.check.sh' <<<"$out" || fail "arm output wrong: $out"
  shim="$fixture/state/merge-queue-poll.check.sh"
  [ -f "$shim" ] || fail "arm did not write the shim"
  [ "$(stat -c %a "$shim")" = 700 ] || fail "shim mode is not 0700: $(stat -c %a "$shim")"
  grep -qF "export FM_HOME=$(printf '%q' "$fixture/home")" "$shim" \
    || fail "shim does not export the home"
  grep -qF "exec $(printf '%q' "$ROOT/bin/fm-merge-queue-poll.sh")" "$shim" \
    || fail "shim does not exec the poll script"
  [ -f "$fixture/state/merge-queue-poll.check-trust" ] || fail "arm did not register the shim"
  # The registered shim is the check the watcher runs; it must be a valid
  # registered check per the register tool's own validation.
  env FM_HOME="$fixture/home" FM_STATE_OVERRIDE="$fixture/state" "$REGISTER" merge-queue-poll \
    >/dev/null || fail "registered shim fails its own registration check"
  out=$(env FM_HOME="$fixture/home" FM_STATE_OVERRIDE="$fixture/state" \
    NO_MISTAKES_BITBUCKET_EMAIL=me@example.com NO_MISTAKES_BITBUCKET_API_TOKEN=tok-secret \
    FM_TEST_LOG="$fixture/curl.log" FM_TEST_CFG="$fixture/cfg.captured" \
    FM_TEST_RESP="$fixture/resp" PATH="$fixture/fakebin:$PATH" \
    "$POLL" arm merge-queue-poll)
  grep -qxF 'armed: state/merge-queue-poll.check.sh' <<<"$out" || fail "re-arm output wrong: $out"
  pass "arm writes the shim and registers it against the check tool"
}

test_arm_refuses_without_credentials_or_tools() {
  local fixture; fixture="$TMP_ROOT/arm-refuse"; make_fixture "$fixture"
  if env FM_HOME="$fixture/home" FM_DATA_OVERRIDE="$fixture/data" FM_STATE_OVERRIDE="$fixture/state" \
    NO_MISTAKES_BITBUCKET_EMAIL= NO_MISTAKES_BITBUCKET_API_TOKEN= \
    "$POLL" arm merge-queue-poll >/dev/null 2>&1; then
    fail "arm should refuse without credentials"
  fi
  [ ! -e "$fixture/state/merge-queue-poll.check.sh" ] || fail "arm left a shim behind on refusal"
  if env FM_HOME="$fixture/home" FM_DATA_OVERRIDE="$fixture/data" FM_STATE_OVERRIDE="$fixture/state" \
    NO_MISTAKES_BITBUCKET_EMAIL=me@example.com NO_MISTAKES_BITBUCKET_API_TOKEN=tok-secret \
    PATH="/nonexistent" "$POLL" arm merge-queue-poll >/dev/null 2>&1; then
    fail "arm should refuse without curl/jq"
  fi
  pass "arm refuses loudly when the watch could never fire"
}

test_arm_disarm_cycle() {
  local fixture; fixture="$TMP_ROOT/disarm"; make_fixture "$fixture"
  env FM_HOME="$fixture/home" FM_DATA_OVERRIDE="$fixture/data" FM_STATE_OVERRIDE="$fixture/state" \
    NO_MISTAKES_BITBUCKET_EMAIL=me@example.com NO_MISTAKES_BITBUCKET_API_TOKEN=tok-secret \
    "$POLL" arm merge-queue-poll >/dev/null || fail "arm failed"
  local out
  out=$(env FM_HOME="$fixture/home" FM_DATA_OVERRIDE="$fixture/data" FM_STATE_OVERRIDE="$fixture/state" \
    NO_MISTAKES_BITBUCKET_EMAIL=me@example.com NO_MISTAKES_BITBUCKET_API_TOKEN=tok-secret \
    "$POLL" disarm merge-queue-poll)
  grep -qxF 'disarmed: state/merge-queue-poll.check.sh' <<<"$out" || fail "disarm output wrong: $out"
  [ ! -e "$fixture/state/merge-queue-poll.check.sh" ] || fail "disarm left the shim"
  [ ! -e "$fixture/state/merge-queue-poll.check-trust" ] || fail "disarm left the trust"
  out=$(env FM_HOME="$fixture/home" FM_DATA_OVERRIDE="$fixture/data" FM_STATE_OVERRIDE="$fixture/state" \
    "$POLL" disarm merge-queue-poll)
  grep -qxF 'disarmed: state/merge-queue-poll.check.sh' <<<"$out" || fail "second disarm should be idempotent"
  pass "disarm removes the shim and its trust and is idempotent"
}

test_arm_refuses_invalid_id() {
  local fixture; fixture="$TMP_ROOT/arm-badid"; make_fixture "$fixture"
  if env FM_HOME="$fixture/home" FM_DATA_OVERRIDE="$fixture/data" FM_STATE_OVERRIDE="$fixture/state" \
    NO_MISTAKES_BITBUCKET_EMAIL=me@example.com NO_MISTAKES_BITBUCKET_API_TOKEN=tok-secret \
    "$POLL" arm 'bad/id' >/dev/null 2>&1; then
    fail "arm should refuse an invalid task id"
  fi
  pass "arm refuses an invalid task id"
}

test_unknown_command_usage() {
  local fixture; fixture="$TMP_ROOT/usage"; make_fixture "$fixture"
  if env FM_HOME="$fixture/home" "$POLL" frobnicate >/dev/null 2>&1; then
    fail "unknown command should exit non-zero"
  fi
  pass "unknown commands exit non-zero with usage"
}

test_merged_wakes_with_canonical_url
test_open_is_silent
test_declined_wakes
test_open_outranks_declined
test_merged_outranks_everything
test_superseded_wakes_when_no_open_replacement
test_no_prs_is_silent
test_github_and_malformed_entries_skipped
test_all_states_from_one_queue
test_missing_queue_is_silent
test_env_credentials_only
test_no_credentials_is_silent
test_api_error_is_silent
test_unparsable_body_is_silent
test_missing_tools_are_silent
test_arm_writes_and_registers_shim
test_arm_refuses_without_credentials_or_tools
test_arm_disarm_cycle
test_arm_refuses_invalid_id
test_unknown_command_usage