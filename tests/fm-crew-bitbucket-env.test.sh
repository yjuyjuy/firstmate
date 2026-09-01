#!/usr/bin/env bash
# Behavior tests for bin/fm-crew-bitbucket-env-lib.sh: the credential-forwarding
# helper fm-spawn.sh uses to hand the Bitbucket PR credentials to a crew whose
# project origin is a bitbucket.org repository, and to hand nothing to any other
# lane.
#
# These test the library directly against real throwaway git clones (a real
# bitbucket.org origin URL and a real github.com origin URL) plus a throwaway
# private .env, so no spawn, tmux, or network is needed. A secret value is only
# ever compared for presence in the FORWARDED lines, never printed to the test
# log verbatim, so a passing run never leaks the token into CI output.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# fm_crew_bitbucket_env_lines depends on fm_pr_bitbucket_origin_slug.
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-crew-bitbucket-env-lib.sh
. "$ROOT/bin/fm-crew-bitbucket-env-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-crew-bitbucket-env)

# The fake credential values. SECRET_TOKEN is never echoed to the log directly;
# assertions check its presence in captured output via grep -c, not by printing.
FAKE_EMAIL='crew-bot@example.com'
SECRET_TOKEN='sk-bitbucket-supersecret-should-not-leak'
FAKE_BASE='https://api.bitbucket.example.com'

# Build a throwaway git repo with the given origin URL. Prints the repo path.
make_repo_with_origin() {  # <name> <origin-url>
  local name=$1 origin=$2 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$origin"
  printf '%s\n' "$dir"
}

# Write a private .env carrying the Bitbucket creds plus an unrelated secret that
# must never be forwarded. Prints the .env path.
make_env_file() {  # <name>
  local name=$1 env_file
  env_file="$TMP_ROOT/$name.env"
  cat > "$env_file" <<EOF
NO_MISTAKES_BITBUCKET_EMAIL=$FAKE_EMAIL
NO_MISTAKES_BITBUCKET_API_TOKEN=$SECRET_TOKEN
UNRELATED_SECRET=must-not-be-forwarded
EOF
  printf '%s\n' "$env_file"
}

# --- reproduce the gap: the creds are NOT in a plain child shell -------------

test_gap_creds_absent_in_plain_shell() {
  local out
  # A fresh shell with no forwarding and the vars scrubbed sees them unset:
  # exactly the crew-shell state that makes the pipeline skip the PR step.
  # The single-quoted body is deliberate: the child shell must expand these, not
  # this shell.
  # shellcheck disable=SC2016
  out=$(env -u NO_MISTAKES_BITBUCKET_EMAIL -u NO_MISTAKES_BITBUCKET_API_TOKEN \
    bash -c 'printf "%s|%s" "${NO_MISTAKES_BITBUCKET_EMAIL-UNSET}" "${NO_MISTAKES_BITBUCKET_API_TOKEN-UNSET}"')
  [ "$out" = "UNSET|UNSET" ] \
    || fail "expected both creds UNSET in a plain child shell, got: $out"
  pass "gap: Bitbucket creds are absent in a plain (crew-equivalent) shell"
}

# --- bitbucket-origin lane forwards the creds from .env ----------------------

test_bitbucket_lane_forwards_from_env_file() {
  local repo env_file out
  repo=$(make_repo_with_origin bb-https 'https://bitbucket.org/hyfin-team/hyfin-server.git')
  env_file=$(make_env_file bb-https)
  # Scrub the process env so the ONLY source is the .env fallback.
  out=$(env -u NO_MISTAKES_BITBUCKET_EMAIL -u NO_MISTAKES_BITBUCKET_API_TOKEN \
    -u NO_MISTAKES_BITBUCKET_API_BASE_URL \
    bash -c '
      . "'"$ROOT"'/bin/fm-pr-lib.sh"
      . "'"$ROOT"'/bin/fm-crew-bitbucket-env-lib.sh"
      fm_crew_bitbucket_env_lines "'"$repo"'" "'"$env_file"'"
    ')
  printf '%s\n' "$out" | grep -qx "NO_MISTAKES_BITBUCKET_EMAIL=$FAKE_EMAIL" \
    || fail "bitbucket lane did not forward EMAIL from .env; got: $out"
  # Assert the SECRET line is present WITHOUT printing the token: grep -c yields a
  # count only, so the token never lands in the test log.
  [ "$(printf '%s\n' "$out" | grep -cx "NO_MISTAKES_BITBUCKET_API_TOKEN=$SECRET_TOKEN")" -eq 1 ] \
    || fail "bitbucket lane did not forward API_TOKEN from .env"
  # The unrelated secret must never be forwarded.
  printf '%s\n' "$out" | grep -q 'UNRELATED_SECRET' \
    && fail "forwarded a non-allowlisted var from .env (leak)"
  pass "bitbucket-origin lane forwards allowlisted creds from .env, not other vars"
}

test_bitbucket_lane_scp_origin_forwards() {
  local repo env_file out
  # scp-like origin (git@bitbucket.org:workspace/repo) must be recognized too.
  repo=$(make_repo_with_origin bb-scp 'git@bitbucket.org:hyfin-team/hyfin.git')
  env_file=$(make_env_file bb-scp)
  out=$(env -u NO_MISTAKES_BITBUCKET_EMAIL -u NO_MISTAKES_BITBUCKET_API_TOKEN \
    bash -c '
      . "'"$ROOT"'/bin/fm-pr-lib.sh"
      . "'"$ROOT"'/bin/fm-crew-bitbucket-env-lib.sh"
      fm_crew_bitbucket_env_lines "'"$repo"'" "'"$env_file"'"
    ')
  printf '%s\n' "$out" | grep -qx "NO_MISTAKES_BITBUCKET_EMAIL=$FAKE_EMAIL" \
    || fail "scp-origin bitbucket lane did not forward EMAIL; got: $out"
  pass "bitbucket-origin lane recognizes the scp-like origin form"
}

test_process_env_wins_over_env_file() {
  local repo env_file out
  repo=$(make_repo_with_origin bb-envwin 'https://bitbucket.org/hyfin-team/hyfin-server.git')
  env_file=$(make_env_file bb-envwin)
  # A value present in the process env must win over the .env fallback.
  out=$(NO_MISTAKES_BITBUCKET_EMAIL='from-process-env@example.com' \
    env NO_MISTAKES_BITBUCKET_EMAIL='from-process-env@example.com' \
    bash -c '
      . "'"$ROOT"'/bin/fm-pr-lib.sh"
      . "'"$ROOT"'/bin/fm-crew-bitbucket-env-lib.sh"
      fm_crew_bitbucket_env_lines "'"$repo"'" "'"$env_file"'"
    ')
  printf '%s\n' "$out" | grep -qx 'NO_MISTAKES_BITBUCKET_EMAIL=from-process-env@example.com' \
    || fail "process-env value did not win over .env; got: $out"
  pass "process-env credential value wins over the .env fallback"
}

test_optional_base_url_forwarded_when_set() {
  local repo out
  repo=$(make_repo_with_origin bb-base 'https://bitbucket.org/hyfin-team/hyfin.git')
  out=$(env -u NO_MISTAKES_BITBUCKET_API_BASE_URL \
    NO_MISTAKES_BITBUCKET_EMAIL="$FAKE_EMAIL" \
    NO_MISTAKES_BITBUCKET_API_TOKEN="$SECRET_TOKEN" \
    NO_MISTAKES_BITBUCKET_API_BASE_URL="$FAKE_BASE" \
    bash -c '
      . "'"$ROOT"'/bin/fm-pr-lib.sh"
      . "'"$ROOT"'/bin/fm-crew-bitbucket-env-lib.sh"
      fm_crew_bitbucket_env_lines "'"$repo"'" "/nonexistent.env"
    ')
  printf '%s\n' "$out" | grep -qx "NO_MISTAKES_BITBUCKET_API_BASE_URL=$FAKE_BASE" \
    || fail "optional API_BASE_URL not forwarded when set; got: $out"
  pass "optional API_BASE_URL is forwarded when set"
}

# --- github-origin lane forwards NOTHING -------------------------------------

test_github_lane_forwards_nothing() {
  local repo env_file out status
  repo=$(make_repo_with_origin gh-lane 'https://github.com/acme/widget.git')
  env_file=$(make_env_file gh-lane)
  out=$(NO_MISTAKES_BITBUCKET_EMAIL="$FAKE_EMAIL" \
    NO_MISTAKES_BITBUCKET_API_TOKEN="$SECRET_TOKEN" \
    bash -c '
      . "'"$ROOT"'/bin/fm-pr-lib.sh"
      . "'"$ROOT"'/bin/fm-crew-bitbucket-env-lib.sh"
      fm_crew_bitbucket_env_lines "'"$repo"'" "'"$env_file"'"
    ')
  status=$?
  [ "$status" -ne 0 ] || fail "github lane should return non-zero (nothing forwarded)"
  [ -z "$out" ] || fail "github lane must forward NOTHING; got: $out"
  pass "github-origin lane forwards no Bitbucket credential (no leak to a GitHub crew)"
}

test_no_origin_forwards_nothing() {
  local repo out status
  # A repo with no origin remote at all resolves no bitbucket.org slug.
  repo="$TMP_ROOT/no-origin"
  mkdir -p "$repo"
  git -C "$repo" init -q
  out=$(NO_MISTAKES_BITBUCKET_EMAIL="$FAKE_EMAIL" \
    NO_MISTAKES_BITBUCKET_API_TOKEN="$SECRET_TOKEN" \
    bash -c '
      . "'"$ROOT"'/bin/fm-pr-lib.sh"
      . "'"$ROOT"'/bin/fm-crew-bitbucket-env-lib.sh"
      fm_crew_bitbucket_env_lines "'"$repo"'" "/nonexistent.env"
    ')
  status=$?
  [ "$status" -ne 0 ] || fail "no-origin lane should return non-zero"
  [ -z "$out" ] || fail "no-origin lane must forward nothing; got: $out"
  pass "lane with no resolvable origin forwards nothing"
}

# --- bitbucket lane with no creds available forwards nothing (soft) ----------

test_bitbucket_lane_no_creds_forwards_nothing() {
  local repo out status
  repo=$(make_repo_with_origin bb-nocreds 'https://bitbucket.org/hyfin-team/hyfin.git')
  # Origin is bitbucket, but no creds anywhere: emit nothing, return non-zero, so
  # the crew reports the SAME expected "missing NO_MISTAKES_BITBUCKET_EMAIL" it
  # does today rather than the spawn hard-failing.
  out=$(env -u NO_MISTAKES_BITBUCKET_EMAIL -u NO_MISTAKES_BITBUCKET_API_TOKEN \
    -u NO_MISTAKES_BITBUCKET_API_BASE_URL \
    bash -c '
      . "'"$ROOT"'/bin/fm-pr-lib.sh"
      . "'"$ROOT"'/bin/fm-crew-bitbucket-env-lib.sh"
      fm_crew_bitbucket_env_lines "'"$repo"'" "/nonexistent.env"
    ')
  status=$?
  [ "$status" -ne 0 ] || fail "bitbucket lane with no creds should return non-zero"
  [ -z "$out" ] || fail "bitbucket lane with no creds must forward nothing; got: $out"
  pass "bitbucket lane with no credentials available forwards nothing (soft, non-fatal)"
}

# --- value with a newline is refused (cannot be one export line) -------------

test_newline_value_refused() {
  local repo out
  repo=$(make_repo_with_origin bb-newline 'https://bitbucket.org/hyfin-team/hyfin.git')
  # A token carrying a newline cannot be forwarded as a single export line: the
  # EMAIL is still forwarded, the malformed TOKEN is skipped.
  out=$(NO_MISTAKES_BITBUCKET_EMAIL="$FAKE_EMAIL" \
    NO_MISTAKES_BITBUCKET_API_TOKEN=$'line1\nline2' \
    bash -c '
      . "'"$ROOT"'/bin/fm-pr-lib.sh"
      . "'"$ROOT"'/bin/fm-crew-bitbucket-env-lib.sh"
      fm_crew_bitbucket_env_lines "'"$repo"'" "/nonexistent.env"
    ')
  printf '%s\n' "$out" | grep -q 'line2' \
    && fail "a newline-bearing token must not be forwarded"
  printf '%s\n' "$out" | grep -qx "NO_MISTAKES_BITBUCKET_EMAIL=$FAKE_EMAIL" \
    || fail "EMAIL should still be forwarded when TOKEN is malformed; got: $out"
  pass "a credential value containing a newline is refused"
}

test_gap_creds_absent_in_plain_shell
test_bitbucket_lane_forwards_from_env_file
test_bitbucket_lane_scp_origin_forwards
test_process_env_wins_over_env_file
test_optional_base_url_forwarded_when_set
test_github_lane_forwards_nothing
test_no_origin_forwards_nothing
test_bitbucket_lane_no_creds_forwards_nothing
test_newline_value_refused
