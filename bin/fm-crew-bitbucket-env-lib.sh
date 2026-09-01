#!/usr/bin/env bash
# Forward the Bitbucket PR credentials into a crew spawn's pane shell, but ONLY
# for a lane whose project origin is a bitbucket.org repository.
#
# Why this exists. A crew running the no-mistakes pipeline on a Bitbucket product
# repository (hyfin, hyfin-server, hyfin-website) passes every local gate and
# then SKIPS the PR + CI steps, because the pipeline's Bitbucket PR path reads
# NO_MISTAKES_BITBUCKET_EMAIL / NO_MISTAKES_BITBUCKET_API_TOKEN and those are
# unset in the crew's pane shell. They live in the home's private .env, but the
# crew spawn env does not carry them through, so every Bitbucket PR falls to
# firstmate to open by hand. Forwarding the exact credential vars the Bitbucket
# path needs lets the crew complete its own PR path end to end.
#
# Security. These are credentials, so the forwarding is deliberately narrow:
#   - Only the specific NO_MISTAKES_BITBUCKET_* vars the Bitbucket path reads are
#     forwarded, never the whole .env. The allowlist below is the single owner of
#     that set (docs/bitbucket-pr.md and bin/fm-bitbucket-lib.sh define the vars).
#   - Forwarding happens ONLY for a lane whose project origin resolves to a
#     bitbucket.org repository. A GitHub-origin lane, or any lane with no
#     resolvable bitbucket.org origin, receives nothing, so a token never reaches
#     a crew that has no Bitbucket work to do.
#   - No secret value is hardcoded anywhere. Values are read at spawn time from
#     the current process environment first, then from the home's private .env as
#     a fallback (the same precedence bin/fm-merge-queue-poll.sh's
#     ensure_credentials uses for the merge-queue watcher).
#
# Dependency. fm_pr_bitbucket_origin_slug (bin/fm-pr-lib.sh) provides the
# bitbucket.org origin detection. fm-spawn.sh sources fm-pr-lib.sh before this
# library, so the function is already available there; a standalone caller (a
# test) must source fm-pr-lib.sh first.

# The exact credential vars the Bitbucket PR path reads (bin/fm-bitbucket-lib.sh,
# bin/fm-pr-poll.sh, bin/fm-merge-queue-poll.sh). EMAIL and API_TOKEN are the
# Basic-auth username and password; API_BASE_URL is an optional host override.
# This list is the security boundary: nothing outside it is ever forwarded.
FM_CREW_BITBUCKET_ENV_ALLOWLIST="NO_MISTAKES_BITBUCKET_EMAIL NO_MISTAKES_BITBUCKET_API_TOKEN NO_MISTAKES_BITBUCKET_API_BASE_URL"

# Read a single allowlisted var's value: the current process environment wins,
# else the value parsed from the private .env file. Prints the value (which may
# be empty) to stdout. A value containing a newline is refused (returns 1,
# prints nothing) because it cannot be forwarded safely as one export line.
#
# The .env fallback is parsed in an isolated subshell that sources the file with
# `set -u` suspended and reads back only the one requested key, so a captain
# authored .env line referencing an unset variable cannot abort the caller and
# no non-allowlisted assignment escapes the subshell.
fm_crew_bitbucket_env_value() {  # <key> <env-file>
  local key=$1 env_file=${2-} val
  # Current environment first.
  val=$(eval "printf '%s' \"\${$key-}\"")
  if [ -z "$val" ] && [ -n "$env_file" ] && [ -f "$env_file" ] && [ ! -L "$env_file" ]; then
    val=$(
      set +u
      set -a
      # shellcheck disable=SC1090,SC1091
      . "$env_file" >/dev/null 2>&1 || true
      set +a
      eval "printf '%s' \"\${$key-}\""
    )
  fi
  case "$val" in
    *$'\n'*) return 1 ;;
  esac
  printf '%s' "$val"
}

# Emit the KEY=VAL lines to forward into the crew pane shell for this lane, one
# per line, for each allowlisted var that has a non-empty value. Prints nothing
# and returns 1 when the lane's project origin is not a bitbucket.org repository,
# so a GitHub lane forwards nothing. Prints nothing and returns 1 when the origin
# IS bitbucket.org but no credential value is available (the crew then reports
# the same expected "missing NO_MISTAKES_BITBUCKET_EMAIL" it does today, never a
# hard failure). Returns 0 only when at least one credential line was emitted.
#
# Args: $1 project directory (used for bitbucket.org origin detection),
#       $2 private .env file path (credential fallback source).
fm_crew_bitbucket_env_lines() {  # <project-dir> <env-file>
  local proj_dir=${1-} env_file=${2-} key val emitted=0
  [ -n "$proj_dir" ] || return 1
  # Forward ONLY for a bitbucket.org-origin lane. fm_pr_bitbucket_origin_slug
  # returns non-zero for a GitHub origin or any unresolvable origin.
  fm_pr_bitbucket_origin_slug "$proj_dir" >/dev/null 2>&1 || return 1
  for key in $FM_CREW_BITBUCKET_ENV_ALLOWLIST; do
    val=$(fm_crew_bitbucket_env_value "$key" "$env_file") || continue
    [ -n "$val" ] || continue
    printf '%s=%s\n' "$key" "$val"
    emitted=1
  done
  [ "$emitted" -eq 1 ]
}
