#!/usr/bin/env bash
# fm-mm-lib.sh - shared helpers for Mattermost captain<->firstmate messaging.
#
# This is a sourced library, never executed directly. It owns config resolution,
# the Mattermost REST v4 primitives, control-channel identity resolution, and the
# self-user cache that keeps firstmate from ingesting its own posts as captain
# input. bin/fm-mm-poll.sh (inbound) and bin/fm-mm-post.sh (outbound) are the two
# CLIs built on it. See docs/mattermost-messaging.md for the design and
# docs/configuration.md for the config contract.
#
# Mattermost messaging is inert by default: absent a non-empty MM_TOKEN in the
# home's gitignored .env (or the environment), every entry point is a hard no-op.
# This mirrors X mode (bin/fm-x-lib.sh) exactly, of which this is the private,
# single-captain sibling.
#
# Config (home .env, MM_ENV_FILE, or environment):
#   MM_TOKEN        required opt-in; a Mattermost personal access token. Absent
#                   or empty means the feature is fully inert.
#   MM_SERVER_URL   Mattermost base URL, e.g. https://mattermost.example.com.
#   MM_TEAM         team NAME (the URL segment), e.g. dashnow. Used with MM_CHANNEL
#                   to resolve the control channel id.
#   MM_CHANNEL      control channel NAME (the URL segment), e.g. fm-cyuan.
#   MM_CHANNEL_ID   optional explicit channel id; when set it wins over name
#                   resolution and no team/name lookup is done.
#   MM_ENV_FILE     optional alternate .env-style file for direct invocations.
#
# Resolved values are exported into the MM_* names below after fm_mm_load_config.
# Callers must have FM_HOME set before calling fm_mm_load_config.

# Resolved config, populated by fm_mm_load_config. These are NOT pre-initialized
# to empty here on purpose: several share a name with the environment variable a
# caller may set (MM_TOKEN, MM_TEAM, MM_CHANNEL, MM_CHANNEL_ID), and a source-time
# reset would wipe that inherited value before fm_mm_load_config could read it.
# fm_mm_load_config captures the inherited environment first, then assigns the
# resolved value back into these same names. MM_SERVER and MM_DRY carry distinct
# input names (MM_SERVER_URL, MM_DRY_RUN), so they are safe to pre-declare.
MM_SERVER=
MM_DRY=

# Read the value of KEY from a .env-style file: last assignment wins; tolerates a
# leading "export ", surrounding whitespace, and one layer of matching quotes.
# Prints nothing (and succeeds) when the file or key is absent, so callers can
# treat empty output as "unset". Byte-identical semantics to fmx_env_get.
fm_mm_env_get() {
  local key=$1 file=$2 line val
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}   # strip leading whitespace
  val=${val%"${val##*[![:space:]]}"}   # strip trailing whitespace (incl. CR)
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}

# Resolve config: an explicit environment variable wins over the .env file, so a
# test or a direct invocation can override any value without editing .env. The
# server URL has its trailing slash stripped so path joins never double up.
fm_mm_load_config() {
  local env_file="${MM_ENV_FILE:-$FM_HOME/.env}" dry
  if [ -n "${MM_TOKEN+x}" ] && [ -n "${MM_TOKEN}" ]; then :; else
    MM_TOKEN=$(fm_mm_env_get MM_TOKEN "$env_file")
  fi
  if [ -n "${MM_SERVER_URL+x}" ] && [ -n "${MM_SERVER_URL}" ]; then
    MM_SERVER=${MM_SERVER_URL}
  else
    MM_SERVER=$(fm_mm_env_get MM_SERVER_URL "$env_file")
  fi
  MM_SERVER=${MM_SERVER%/}
  if [ -n "${MM_TEAM+x}" ] && [ -n "${MM_TEAM}" ]; then :; else
    MM_TEAM=$(fm_mm_env_get MM_TEAM "$env_file")
  fi
  if [ -n "${MM_CHANNEL+x}" ] && [ -n "${MM_CHANNEL}" ]; then :; else
    MM_CHANNEL=$(fm_mm_env_get MM_CHANNEL "$env_file")
  fi
  if [ -n "${MM_CHANNEL_ID+x}" ] && [ -n "${MM_CHANNEL_ID}" ]; then :; else
    MM_CHANNEL_ID=$(fm_mm_env_get MM_CHANNEL_ID "$env_file")
  fi
  if [ -n "${MM_DRY_RUN+x}" ]; then
    dry=${MM_DRY_RUN-}
  else
    dry=$(fm_mm_env_get MM_DRY_RUN "$env_file")
  fi
  case "$(printf '%s' "$dry" | tr '[:upper:]' '[:lower:]')" in
    ''|0|false|no|off) MM_DRY="" ;;
    *) MM_DRY=1 ;;
  esac
  # shellcheck disable=SC2034 # MM_DRY is read by callers (fm-mm-post.sh) after sourcing.
  : "$MM_DRY"
}

# True when the feature is opted in: a non-empty token is the single gate.
fm_mm_enabled() {
  [ -n "$MM_TOKEN" ]
}

# Write the bearer auth header to a private 0600 temp file and print its path, so
# the token never appears in a command line (where `ps` could read it) and never
# lands in the fakebin curl log during tests. The caller owns cleanup. Mirrors
# fmx_auth_header_file.
fm_mm_auth_header_file() {
  local tmp
  [ -n "$MM_TOKEN" ] || return 1
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-mm-auth.XXXXXX") || return 1
  printf 'Authorization: Bearer %s\n' "$MM_TOKEN" > "$tmp" || { rm -f "$tmp"; return 1; }
  printf '%s' "$tmp"
}

# GET <path> into <body-file>, printing the HTTP status code. Bounded and quiet:
# a failure prints nothing and returns non-zero, so a caller treats it as "no
# result this cycle". -m 5 keeps the inbound poll well inside the watcher's
# per-check timeout so the supervision loop is never starved.
fm_mm_api_get() {  # <path> <body-file> <auth-header-file>
  local path=$1 body=$2 auth=$3 code
  code=$(curl -m 5 -s -o "$body" -w '%{http_code}' \
    -H "@$auth" \
    -H 'Accept: application/json' \
    "$MM_SERVER$path" 2>/dev/null) || return 1
  printf '%s' "$code"
}

# POST <json-payload-file> to <path> into <body-file>, printing the HTTP status
# code. A slightly longer timeout than the poll because an outbound escalation
# post is worth waiting a little longer on, but still bounded.
fm_mm_api_post() {  # <path> <payload-file> <body-file> <auth-header-file>
  local path=$1 payload=$2 body=$3 auth=$4 code
  code=$(curl -m 10 -s -o "$body" -w '%{http_code}' \
    -X POST \
    -H "@$auth" \
    -H 'Content-Type: application/json' \
    --data-binary "@$payload" \
    "$MM_SERVER$path" 2>/dev/null) || return 1
  printf '%s' "$code"
}

# The cached self (bot) user id file. Kept out of the inbox so it survives inbox
# drains, and private because it identifies the account the token belongs to.
fm_mm_self_user_file() {  # <state>
  printf '%s/mm-self-user' "$1"
}

# Resolve firstmate's own Mattermost user id (the account the token belongs to)
# and cache it, so the inbound poll can filter out firstmate's own posts. Reads
# the cache first; on a miss it calls GET /api/v4/users/me. Prints the id on
# success, nothing on failure. A resolution failure is not fatal to the poll: the
# caller falls back to ingesting nothing rather than risking an echo loop.
fm_mm_self_user_id() {  # <state> <auth-header-file>
  local state=$1 auth=$2 cache id body code
  cache=$(fm_mm_self_user_file "$state")
  id=$(head -n 1 "$cache" 2>/dev/null || true)
  case "$id" in
    ''|*[!A-Za-z0-9]*) id= ;;
  esac
  if [ -n "$id" ]; then
    printf '%s' "$id"
    return 0
  fi
  body=$(mktemp "${TMPDIR:-/tmp}/fm-mm-me.XXXXXX") || return 1
  code=$(fm_mm_api_get /api/v4/users/me "$body" "$auth") || { rm -f "$body"; return 1; }
  if [ "$code" = 200 ]; then
    id=$(jq -r '.id // empty' "$body" 2>/dev/null) || id=
  fi
  rm -f "$body"
  case "$id" in
    ''|*[!A-Za-z0-9]*) return 1 ;;
  esac
  ( umask 077; printf '%s\n' "$id" > "$cache" ) 2>/dev/null || true
  printf '%s' "$id"
}

# The cached control-channel id file. Kept out of the inbox for the same reason.
fm_mm_channel_id_file() {  # <state>
  printf '%s/mm-channel-id' "$1"
}

# Resolve the control channel id. An explicit MM_CHANNEL_ID wins with no network
# call. Otherwise the id is resolved once from MM_TEAM + MM_CHANNEL via
# GET /api/v4/teams/name/{team}/channels/name/{channel} and cached to
# state/mm-channel-id, so the un-discoverable id the captain named by URL is
# recorded exactly once. Prints the id on success, nothing on failure.
fm_mm_channel_id() {  # <state> <auth-header-file>
  local state=$1 auth=$2 cache id body code
  if [ -n "$MM_CHANNEL_ID" ]; then
    case "$MM_CHANNEL_ID" in
      *[!A-Za-z0-9]*) return 1 ;;
    esac
    printf '%s' "$MM_CHANNEL_ID"
    return 0
  fi
  cache=$(fm_mm_channel_id_file "$state")
  id=$(head -n 1 "$cache" 2>/dev/null || true)
  case "$id" in
    ''|*[!A-Za-z0-9]*) id= ;;
  esac
  if [ -n "$id" ]; then
    printf '%s' "$id"
    return 0
  fi
  [ -n "$MM_TEAM" ] && [ -n "$MM_CHANNEL" ] || return 1
  # The team and channel names are URL path segments. Mattermost segment names are
  # a restricted slug, so reject anything outside it rather than trust it into a
  # path.
  case "$MM_TEAM" in
    ''|*[!a-z0-9._-]*) return 1 ;;
  esac
  case "$MM_CHANNEL" in
    ''|*[!a-z0-9._-]*) return 1 ;;
  esac
  body=$(mktemp "${TMPDIR:-/tmp}/fm-mm-chan.XXXXXX") || return 1
  code=$(fm_mm_api_get "/api/v4/teams/name/$MM_TEAM/channels/name/$MM_CHANNEL" "$body" "$auth") \
    || { rm -f "$body"; return 1; }
  if [ "$code" = 200 ]; then
    id=$(jq -r '.id // empty' "$body" 2>/dev/null) || id=
  fi
  rm -f "$body"
  case "$id" in
    ''|*[!A-Za-z0-9]*) return 1 ;;
  esac
  ( umask 077; printf '%s\n' "$id" > "$cache" ) 2>/dev/null || true
  printf '%s' "$id"
}
