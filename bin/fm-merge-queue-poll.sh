#!/usr/bin/env bash
# Bitbucket merge-queue watch: silent watcher poll over data/merge-queue.tsv,
# plus arm/disarm for the registered custom check. When a queued branch's
# Bitbucket pull request is MERGED or DECLINED (or left SUPERSEDED with no open
# replacement), the poll prints one wake line per finding; on any other state,
# error, or missing prerequisite it prints nothing, so a failed lookup can never
# be misread as a merge or decline. A merged branch is then cleared by
# bin/fm-merge-queue.sh sweep; a declined or superseded one stays queued until
# firstmate resolves it with the captain (remove the entry, or delete the branch
# so the sweep's branch-gone check clears it).
#
# The poll reads the queue through the format owner (bin/fm-merge-queue-lib.sh)
# and watches only entries whose compare link is a bitbucket.org branch URL, so
# GitHub entries stay untouched. It authenticates with the same
# NO_MISTAKES_BITBUCKET_EMAIL / NO_MISTAKES_BITBUCKET_API_TOKEN credentials the
# rest of the Bitbucket path uses, sourced from $FM_HOME/.env when not already
# in the environment, and passes them to curl only through a private --config
# file, never on the command line.
#
# The watcher never runs these bytes directly for this poll: it runs a small
# registered shim (state/<id>.check.sh) that exports FM_HOME and execs this
# script, exactly like the X-mode connector shim. The shim is bound to its bytes
# by bin/fm-check-register.sh.
#
# Usage:
#   fm-merge-queue-poll.sh [--debug]      poll mode (the watcher's check program)
#   fm-merge-queue-poll.sh arm <id>       write and register state/<id>.check.sh
#   fm-merge-queue-poll.sh disarm <id>    remove state/<id>.check.sh and its trust
#   fm-merge-queue-poll.sh -h|--help      print this header
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-merge-queue-lib.sh
. "$SCRIPT_DIR/fm-merge-queue-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Ensure both Bitbucket credential parts are present, falling back to the
# home's private .env exactly like the documented Bitbucket PR flow. Returns 0
# when present, 1 when still missing.
ensure_credentials() {
  if [ -z "${NO_MISTAKES_BITBUCKET_EMAIL:-}" ] || [ -z "${NO_MISTAKES_BITBUCKET_API_TOKEN:-}" ]; then
    if [ -f "$FM_HOME/.env" ] && [ ! -L "$FM_HOME/.env" ]; then
      # Source the private env file with -u suspended: a captain-authored line
      # referencing an unset variable must never abort the whole poll.
      case $- in *u*) set +u ;; esac
      set -a
      # shellcheck disable=SC1090,SC1091
      . "$FM_HOME/.env" || true
      set +a
      case $- in *u*) ;; *) set -u ;; esac
    fi
  fi
  [ -n "${NO_MISTAKES_BITBUCKET_EMAIL:-}" ] && [ -n "${NO_MISTAKES_BITBUCKET_API_TOKEN:-}" ]
}

debug_msg() {
  [ "${1:-0}" -eq 1 ] || return 0
  shift
  printf '%s\n' "$*" >&2
}

# Resolve the API base the same way bin/fm-bitbucket-lib.sh does: a plain https
# override or the default; anything else is refused (silently in poll mode).
api_base() {
  local base=${NO_MISTAKES_BITBUCKET_API_BASE_URL:-https://api.bitbucket.org}
  case "$base" in
    https://*) ;;
    *) return 1 ;;
  esac
  case "$base" in
    *[[:space:]]*) return 1 ;;
  esac
  printf '%s\n' "${base%/}"
}

# Poll one queue entry. Parse the bitbucket.org branch compare link into
# workspace/repository/branch, query that branch's pull requests, and print a
# single wake line when the branch's PRs are closed without an open replacement.
# Returns 0 when silent, 1 when the entry was skipped (debug prints the reason).
poll_entry() {
  local debug=$1 id=$2 branch=$3 base=$4 url=$5
  local rest ws repo qbranch seg api_base_v cfg response states state label pr_id pr_url
  case "$url" in
    https://bitbucket.org/*) ;;
    *) debug_msg "$debug" "$id: not a bitbucket.org compare link"; return 1 ;;
  esac
  url=${url%%\?*}
  rest=${url#https://bitbucket.org/}
  ws=${rest%%/*}
  rest=${rest#*/}
  repo=${rest%%/*}
  rest=${rest#*/}
  case "$rest" in
    branch/*) ;;
    *) debug_msg "$debug" "$id: compare link has no branch path"; return 1 ;;
  esac
  qbranch=${rest#branch/}
  fm_pr_bitbucket_slug_valid "$ws" || { debug_msg "$debug" "$id: unsafe workspace $ws"; return 1; }
  fm_pr_bitbucket_slug_valid "$repo" || { debug_msg "$debug" "$id: unsafe repository $repo"; return 1; }
  # The branch name is embedded in Bitbucket's q query as a quoted string, so a
  # double quote would break out of the string and change the query semantics;
  # whitespace is rejected too, and every other unsafe entry stays silent.
  # (A backslash cannot break out of the quoted string - it only escapes the
  # next character inside it - so it needs no special case.)
  case "$qbranch" in
    ''|*'"'*|*[[:space:]]*) debug_msg "$debug" "$id: unsafe branch name"; return 1 ;;
  esac
  rest=$qbranch
  while [ -n "$rest" ]; do
    case "$rest" in
      */*) seg=${rest%%/*}; rest=${rest#*/} ;;
      *) seg=$rest; rest= ;;
    esac
    fm_pr_bitbucket_slug_valid "$seg" || { debug_msg "$debug" "$id: unsafe branch segment $seg"; return 1; }
  done
  api_base_v=$(api_base) || { debug_msg "$debug" "$id: invalid API base"; return 1; }
  command -v curl >/dev/null 2>&1 || { debug_msg "$debug" "$id: curl missing"; return 1; }
  command -v jq >/dev/null 2>&1 || { debug_msg "$debug" "$id: jq missing"; return 1; }
  cfg=$(mktemp "${TMPDIR:-/tmp}/fm-mq-poll.XXXXXX") || { debug_msg "$debug" "$id: no temp file"; return 1; }
  printf 'user = "%s:%s"\n' "$NO_MISTAKES_BITBUCKET_EMAIL" "$NO_MISTAKES_BITBUCKET_API_TOKEN" \
    > "$cfg" || { rm -f -- "$cfg"; debug_msg "$debug" "$id: could not write credential file"; return 1; }
  response=$(curl --silent --show-error --config "$cfg" --get --max-time 10 \
    --header 'Accept: application/json' \
    --data-urlencode 'state=ALL' \
    --data-urlencode 'pagelen=50' \
    --data-urlencode "q=source.branch.name=\"$qbranch\"" \
    "$api_base_v/2.0/repositories/$ws/$repo/pullrequests" 2>/dev/null)
  rm -f -- "$cfg"
  [ -n "$response" ] || { debug_msg "$debug" "$id: empty API response"; return 1; }
  states=$(printf '%s' "$response" | jq -r '.values[]?.state // empty' 2>/dev/null | tr '\n' ' ') \
    || { debug_msg "$debug" "$id: unparsable API response"; return 1; }
  # MERGED outranks everything (the branch's work landed); an OPEN PR outranks
  # the closed states (the branch is still pending); DECLINED and SUPERSEDED
  # both mean closed without landing and wake firstmate to resolve the entry.
  case " $states " in
    *' MERGED '*) state=MERGED ;;
    *' OPEN '*) return 0 ;;
    *' DECLINED '*) state=DECLINED ;;
    *' SUPERSEDED '*) state=SUPERSEDED ;;
    *) debug_msg "$debug" "$id: no pull requests"; return 1 ;;
  esac
  case "$state" in
    MERGED) label=merged ;;
    DECLINED) label=declined ;;
    SUPERSEDED) label=superseded ;;
  esac
  pr_id=$(printf '%s' "$response" | jq -r --arg s "$state" \
    '.values[] | select(.state == $s) | .id' 2>/dev/null | head -1) || pr_id=
  case "$pr_id" in
    ''|*[!0-9]*) pr_id= ;;
  esac
  if [ -n "$pr_id" ]; then
    pr_url="https://bitbucket.org/$ws/$repo/pull-requests/$pr_id"
  else
    pr_url=$url
  fi
  printf '%s: %s %s -> %s %s\n' "$label" "$id" "$branch" "$base" "$pr_url"
}

poll() {
  local debug=${1:-0}
  ensure_credentials || { debug_msg "$debug" "no Bitbucket credentials"; return 0; }
  command -v curl >/dev/null 2>&1 || { debug_msg "$debug" "curl missing"; return 0; }
  command -v jq >/dev/null 2>&1 || { debug_msg "$debug" "jq missing"; return 0; }
  local entries
  entries=$(fm_merge_queue_entries "$DATA") || return 0
  [ -n "$entries" ] || return 0
  while IFS='	' read -r id project branch head base url; do
    [ -n "$id" ] || continue
    poll_entry "$debug" "$id" "$branch" "$base" "$url" \
      || debug_msg "$debug" "$id: skipped"
  done <<EOF
$entries
EOF
}

# The registered check bytes: a static shim that exports FM_HOME and execs the
# trusted poll script, so the watcher's hash validation binds a tiny file while
# the real program stays tracked and reviewable in bin/.
shim_content() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by bin/fm-merge-queue-poll.sh - Bitbucket merge-queue watch poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted poll script.' \
    "export FM_HOME=$(printf '%q' "$FM_HOME")" \
    "exec $(printf '%q' "$FM_ROOT/bin/fm-merge-queue-poll.sh")"
}

arm() {
  local id=$1
  fm_pr_task_id_valid "$id" || { echo "error: invalid task id: $id" >&2; return 2; }
  # Arming is the one point the poll's silent-failure contract can be checked
  # loudly: never arm a watch that can never fire.
  command -v curl >/dev/null 2>&1 || { echo "error: Bitbucket merge-queue watch requires curl on PATH" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: Bitbucket merge-queue watch requires jq on PATH" >&2; return 1; }
  ensure_credentials || {
    echo "error: Bitbucket merge-queue watch requires NO_MISTAKES_BITBUCKET_EMAIL and NO_MISTAKES_BITBUCKET_API_TOKEN (env or $FM_HOME/.env)" >&2
    return 1
  }
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: state directory is unavailable" >&2; return 1; }
  local shim existing expected
  shim="$STATE/$id.check.sh"
  expected=$(shim_content) || return 1
  if [ -e "$shim" ] || [ -L "$shim" ]; then
    existing=$(cat "$shim" 2>/dev/null) || existing=
    if [ "$existing" != "$expected" ]; then
      echo "error: $shim exists with different content; disarm it before re-arming" >&2
      return 1
    fi
  fi
  umask 077
  # TMP is deliberately a global: the EXIT trap below fires after arm() has
  # returned, when its locals no longer exist, so a local name would abort the
  # script under set -u.
  TMP=$(mktemp "$STATE/.fm-mq-poll-shim.XXXXXX") || return 1
  trap '[ -z "$TMP" ] || rm -f -- "$TMP"' EXIT HUP INT TERM
  printf '%s\n' "$expected" > "$TMP" || return 1
  chmod 0700 "$TMP" || return 1
  mv -f -- "$TMP" "$shim" || return 1
  TMP=
  if ! "$SCRIPT_DIR/fm-check-register.sh" "$id"; then
    rm -f -- "$shim"
    echo "error: could not register $shim" >&2
    return 1
  fi
  printf 'armed: state/%s.check.sh\n' "$id"
}

disarm() {
  local id=$1
  fm_pr_task_id_valid "$id" || { echo "error: invalid task id: $id" >&2; return 2; }
  rm -f -- "$STATE/$id.check.sh" "$STATE/$id.check-trust"
  printf 'disarmed: state/%s.check.sh\n' "$id"
}

cmd=${1-}
case "$cmd" in
  ''|poll)
    poll 0
    ;;
  --debug)
    poll 1
    ;;
  arm)
    shift
    id=${1-}
    [ -n "$id" ] || { echo "usage: fm-merge-queue-poll.sh arm <id>" >&2; exit 2; }
    arm "$id"
    ;;
  disarm)
    shift
    id=${1-}
    [ -n "$id" ] || { echo "usage: fm-merge-queue-poll.sh disarm <id>" >&2; exit 2; }
    disarm "$id"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "error: unknown command '$cmd'" >&2
    usage >&2
    exit 2
    ;;
esac