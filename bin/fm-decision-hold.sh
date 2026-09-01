#!/usr/bin/env bash
# fm-decision-hold.sh - deterministic mechanics for durable captain decisions.
#
# The semantic policy is owned once by
# .agents/skills/decision-hold-lifecycle/SKILL.md. This script never reads report,
# visual-review, chat, or terminal prose to guess whether a decision exists.
# The invoking agent inventories unresolved decisions, assigns stable keys, and
# routes dependent work. This script supplies deterministic identities, creates
# and verifies structured tasks-axi captain holds, records completion attestation
# in the originating task's metadata, and closes a hold only after a durable
# decision record has been linked to existing dependent work.
#
# A hold identity is <origin-id>-decision-<decision-key>. Origin ids and decision
# keys must already be privacy-safe slugs. Repeating `hold` with the same identity
# is idempotent. A different decision key creates a different backlog identity.
# All backlog mutations run in the active FM_HOME, which keeps main-home and
# secondmate-home ownership aligned with the work that discovered the decision.
#
# Usage:
#   fm-decision-hold.sh id <origin-id> <decision-key>
#   fm-decision-hold.sh hold <origin-id> <decision-key> \
#     --title <title> --reason <reason> [--repo <repo>] [--blocking]
#   fm-decision-hold.sh complete <origin-id> (--none | <decision-key>...)
#   fm-decision-hold.sh verify <origin-id>
#   fm-decision-hold.sh resolve <origin-id> <decision-key> \
#     --decision-file <path> --routed-to <task-id> [--routed-to <task-id>...]
#   fm-decision-hold.sh close <hold-id>
#   fm-decision-hold.sh guard [--restore]
#
# `complete` is the shared investigation and visual-review completion gate.
# `--none` is an explicit semantic attestation that the just-reviewed surface has
# no unresolved captain decision. Later review passes may add keys; a live task's
# metadata inventory is unioned idempotently. A post-teardown visual review can
# complete against the surviving report and holds without recreating task state.
# `verify` is read-only and is called by scout teardown so teardown cannot erase a
# source before this gate has succeeded. `verify` only checks a single origin's own
# inventory, so it never sees a sibling hold being buried; `guard` is the ledger-wide
# backstop for that. `guard` reads the active backlog and the retention archive and
# fails closed if any kind captain hold is Done while still bearing the
# "State: awaiting captain decision." sentinel (closed without routing through
# `resolve`). `--restore` reopens and re-holds active-backlog offenders; an archived
# offender is reported for manual un-archiving because tasks-axi cannot address an item
# once retention pruning has moved it into the archive file. fm-teardown.sh runs the
# read-only `guard` as a fail-closed gate before its own close-and-prune reminder, the
# closest firstmate-owned point ahead of the pruning `tasks-axi done`.
#
# `resolve` requires every --routed-to task to exist and to be blocked by the hold.
# It writes the captain decision and routed identities into the hold body, clears
# those dependency edges, and only then marks the hold Done. A failure before the
# final step leaves the captain hold open.
#
# `close` is the close-time catch for the retention-loss bug. It is the safe way to
# mark a captain hold Done: it refuses a bare `done` on a kind captain hold that still
# bears the "State: awaiting captain decision." sentinel (i.e. one closed without ever
# routing through `resolve`), naming the offending hold and the exact `resolve` recipe,
# so the corruption is caught at close time rather than only detected later by `guard`
# at teardown. A durably resolved hold, an ordinary captain hold with no sentinel, and a
# non-captain item all pass straight through to a plain `tasks-axi done`.
#
# `hold --blocking` marks a decision that blocks live work, as distinct from a
# review-when-convenient one. It maps onto the tasks-axi priority field (priority 0,
# the highest band; the field runs 0 highest to 4 lowest) so the existing backlog
# ordering already surfaces it ahead of convenience holds, and downstream renderers
# (bearings) sort blocking holds first, then oldest-first within each band. Omitting
# --blocking leaves the priority field untouched, the unchanged default behavior.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-hold: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

hold_id() {  # <origin-id> <decision-key>
  validate_slug origin-id "$1"
  validate_slug decision-key "$2"
  printf '%s-decision-%s\n' "$1" "$2"
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail "tasks-axi does not expose the captain-hold contract"
}

task_show() {  # <id>
  tasks_axi show "$1" --full 2>/dev/null
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

origin_exists_here() {  # <origin-id>
  [ -f "$STATE/$1.meta" ] && return 0
  [ -f "$DATA/$1/report.md" ] && return 0
  task_show "$1" >/dev/null 2>&1
}

list_has_key() {  # <comma-list> <key>
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

sorted_key_union() {  # <comma-list> <newline-or-space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

origin_open_decisions() {  # <origin-id>
  local origin=$1 meta="$STATE/$1.meta" status_file="$STATE/$1.status" open kind last verb
  open=$(status_open_decisions "$status_file")
  [ -n "$open" ] || return 0
  [ -f "$meta" ] || { printf '%s' "$open"; return 0; }
  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" != secondmate ]; then
    last=$(last_status_line "$status_file")
    verb=$(status_line_verb "$last")
    case "$verb" in
      done|failed) return 0 ;;
    esac
  fi
  printf '%s' "$open"
}

verify_hold_active() {  # <hold-id>
  local id=$1 show state held kind hold_kind
  show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  [ "$state" = queued ] || fail "captain hold $id is not queued (state=$state)"
  [ "$held" = yes ] || fail "captain hold $id is not active"
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  [ "$hold_kind" = captain ] || fail "backlog item $id is not held for the captain"
}

# A captain decision hold is created with the sentinel body line
# "State: awaiting captain decision." (command_hold) and resolve() replaces the whole
# body with a "Resolution recorded by fm-decision-hold." record. So the presence of
# the sentinel, or the absence of the resolution record, is the byte-level truth of
# whether the captain has actually answered - never the tasks-axi Done flag alone.
body_has_resolution() {  # <body>
  case "$1" in
    *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
  esac
  return 1
}

body_awaiting_captain() {  # <body>
  case "$1" in
    *"State: awaiting captain decision."*) return 0 ;;
  esac
  return 1
}

verify_hold_resolved() {  # <hold-id>
  local id=$1 show state kind body
  show=$(task_show "$id") || return 1
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  body=$(show_field "$show" body)
  [ "$state" = "done" ] || return 1
  [ "$kind" = captain ] || return 1
  body_has_resolution "$body"
}

verify_hold_durable() {  # <hold-id>
  local id=$1 show state held kind hold_kind body
  show=$(task_show "$id") || fail "captain decision $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  body=$(show_field "$show" body)
  if [ "$state" = queued ] && [ "$held" = yes ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ]; then
    return 0
  fi
  if [ "$state" = "done" ] && [ "$kind" = captain ] && body_has_resolution "$body"; then
    return 0
  fi
  fail "captain decision $id is neither actively held nor durably resolved"
}

verify_resolution_identity() {
  local id=$1 hold_body=$2 decision_digest=$3 routed_csv=$4 resolution_prefix resolution_fields recorded_digest recorded_routes
  resolution_prefix='"Resolution recorded by fm-decision-hold.\nDecision digest: '
  case "$hold_body" in
    "$resolution_prefix"*) resolution_fields=${hold_body#"$resolution_prefix"} ;;
    *) fail "captain hold $id has no retry identity record" ;;
  esac
  case "$resolution_fields" in
    *'\nRouted identities: '*'\n\nCaptain decision:'*) : ;;
    *) fail "captain hold $id has an invalid retry identity record" ;;
  esac
  recorded_digest=${resolution_fields%%\\n*}
  resolution_fields=${resolution_fields#*\\nRouted identities: }
  recorded_routes=${resolution_fields%%\\n*}
  [ "$recorded_digest" = "$decision_digest" ] \
    || fail "captain hold $id records a different captain decision"
  [ "$recorded_routes" = "$routed_csv" ] \
    || fail "captain hold $id records different routed work"
}

command_id() {
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  hold_id "$1" "$2"
}

command_hold() {
  local origin=${1:-} key=${2:-} title='' reason='' repo='' blocking=0 id show state kind existing_title body
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      --blocking) blocking=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_one_line title "$title"
  validate_one_line reason "$reason"
  case "$reason" in *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;; esac
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  id=$(hold_id "$origin" "$key")
  if show=$(task_show "$id"); then
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    existing_title=$(show_field "$show" title)
    [ "$kind" = captain ] || fail "existing backlog identity $id is not kind captain"
    # A Done hold is "already resolved" only when it carries the durable resolution
    # record. A Done hold without that record still bears the awaiting sentinel: it was
    # closed without an answer (the retention-loss bug), so recover it rather than
    # refusing. Keying off state=done alone was the hold/verify contradiction: hold
    # called every Done hold resolved while verify_hold_durable, which checks the
    # record, called the same id neither held nor resolved.
    if [ "$state" = "done" ]; then
      ! body_has_resolution "$(show_field "$show" body)" \
        || fail "captain decision $id is already durably resolved; use a new decision key for a new decision"
      tasks_axi reopen "$id" >/dev/null \
        || fail "could not reopen unanswered captain hold $id to recover it"
    fi
    [ "$existing_title" = "$title" ] || fail "existing captain hold $id has a different title"
  else
    if [ -z "$repo" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    body=$(printf 'Origin: %s\nDecision key: %s\nState: awaiting captain decision.' "$origin" "$key")
    tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
      || fail "could not create captain decision item $id"
  fi
  tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
    || fail "could not activate captain hold $id"
  # A blocking decision maps onto priority 0 (highest band) so the existing backlog
  # and bearings ordering surface it ahead of convenience holds. Without --blocking the
  # priority field is left untouched, preserving the unchanged default behavior.
  if [ "$blocking" = 1 ]; then
    tasks_axi update "$id" --priority 0 >/dev/null \
      || fail "could not mark captain hold $id blocking"
  fi
  verify_hold_active "$id"
  printf '%s\n' "$id"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' key status_file open raw_open key_seen=0 has_meta=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with decision keys"
      validate_slug decision-key "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  if [ "$has_meta" = 1 ]; then
    previous=$(meta_value "$meta" decision_keys)
  fi
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  raw_open=$(status_open_decisions "$status_file")
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key has no captain-held inventory entry"
  done <<EOF
$open
EOF

  if [ "$has_meta" = 1 ]; then
    if [ "$(meta_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$keys" >> "$meta"
    fi

    # Transfer any still-open status decision to its durable backlog owner so the
    # live status fold does not duplicate the same Captain's Call item.
    while IFS=$'\t' read -r key _verb _summary; do
      [ -n "$key" ] || continue
      list_has_key "$keys" "$key" || continue
      printf 'captain-held [key=%s]: tracked by %s\n' "$key" "$(hold_id "$origin" "$key")" >> "$status_file"
      key_seen=1
    done <<EOF
$raw_open
EOF
  fi
  : "$key_seen"
  printf 'complete: %s decision inventory reviewed%s\n' "$origin" "${keys:+ ($keys)}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys key open
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed unresolved-decision inventory"
  keys=$(meta_value "$meta" decision_keys)
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key is outside the reviewed inventory"
    verify_hold_durable "$(hold_id "$origin" "$key")"
  done <<EOF
$open
EOF
  printf 'verified: %s unresolved-decision inventory\n' "$origin"
}

command_resolve() {
  local origin=${1:-} key=${2:-} decision_file='' id='' decision='' decision_digest='' body='' routed='' routed_csv='' dep show blocked state hold_show hold_body resolution_recorded=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  [ -n "$decision_file" ] || fail "--decision-file is required"
  [ -f "$decision_file" ] || fail "decision file does not exist: $decision_file"
  decision=$(cat "$decision_file")
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  [ -n "$routed" ] || fail "at least one --routed-to task is required"
  routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  decision_digest=$(sha256_text "$decision")
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  if verify_hold_resolved "$id"; then
    hold_show=$(task_show "$id")
    hold_body=$(show_field "$hold_show" body)
    verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
    printf 'resolved: %s\n' "$id"
    return 0
  fi
  verify_hold_active "$id"
  hold_show=$(task_show "$id")
  hold_body=$(show_field "$hold_show" body)
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*)
      verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
      resolution_recorded=1
      ;;
  esac

  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep does not exist in the active home"
    state=$(show_field "$show" state)
    [ "$state" != "done" ] || [ "$resolution_recorded" = 1 ] \
      || fail "routed task $dep is already done"
    # tasks-axi quotes multi-entry blocked_by as "a,b,c"; strip so edge ids match.
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*) : ;;
      *)
        case "$hold_body" in
          *"Resolution recorded by fm-decision-hold."*"- $dep"*) : ;;
          *) fail "routed task $dep is not durably blocked by $id" ;;
        esac
        ;;
    esac
  done

  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: %s\n\nCaptain decision:\n%s\n\nRouted work:\n' "$decision_digest" "$routed_csv" "$decision")
  for dep in $routed; do
    body="${body}- ${dep}"$'\n'
  done
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep disappeared before routing"
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*)
        tasks_axi unblock "$dep" --by "$id" >/dev/null \
          || fail "could not route the recorded decision to $dep"
        ;;
    esac
  done
  tasks_axi "done" "$id" >/dev/null || fail "could not close resolved captain hold $id"
  verify_hold_resolved "$id" || fail "captain hold $id did not retain its durable resolution record"
  printf 'resolved: %s -> %s\n' "$id" "$routed"
}

# --- close: the close-time catch for the retention-loss bug ------------------
# The safe replacement for a bare `tasks-axi done` on a captain hold. It refuses to
# close a kind captain hold that still bears the awaiting sentinel and carries no
# resolution record, so the corruption `guard` later detects at teardown is caught here
# at close time instead. Everything else passes straight through to `tasks-axi done`.
command_close() {
  local id=${1:-} show kind body origin key
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug hold-id "$id"
  require_tasks_axi
  if ! show=$(task_show "$id"); then
    fail "backlog item $id is absent from the active home $FM_HOME"
  fi
  kind=$(show_field "$show" kind)
  body=$(show_field "$show" body)
  # A kind captain hold still awaiting a decision, with no durable resolution record, is
  # exactly the state a bare done would bury. Refuse and inline the resolve recipe. A
  # durably resolved hold, an ordinary captain hold with no sentinel, and any non-captain
  # item all fall through to the plain done below.
  if [ "$kind" = captain ] && body_awaiting_captain "$body" && ! body_has_resolution "$body"; then
    origin=${id%-decision-*}
    key=${id##*-decision-}
    echo "close: REFUSED - captain decision hold $id is still awaiting a captain answer." >&2
    echo "A bare done would bury it unanswered (the retention-loss bug). Record the answer and route it, which closes the hold:" >&2
    if [ "$origin" != "$id" ] && [ "$key" != "$id" ]; then
      echo "  bin/fm-decision-hold.sh resolve $origin $key --decision-file <path> --routed-to <task-id>" >&2
    else
      echo "  bin/fm-decision-hold.sh resolve <origin-id> <decision-key> --decision-file <path> --routed-to <task-id>" >&2
    fi
    fail "refusing to close unanswered captain hold $id; resolve it instead"
  fi
  tasks_axi "done" "$id" >/dev/null || fail "could not close backlog item $id"
  printf 'closed: %s\n' "$id"
}

# --- guard: the structural retention-loss backstop --------------------------
# Owns the invariant that no captain decision hold may be Done while its body still
# reads the "State: awaiting captain decision." sentinel, i.e. while it was closed
# without ever routing through resolve(). It reads both the active backlog and the
# retention archive directly, because tasks-axi cannot address an item once retention
# pruning has moved it into the archive (the archive is a flat, non-backlog file).

toml_markdown_value() {  # <key> -> value from the [markdown] table of FM_HOME/.tasks.toml
  local key=$1 toml="$FM_HOME/.tasks.toml"
  [ -f "$toml" ] || return 0
  awk -v k="$key" '
    /^[[:space:]]*\[/ { in_md = ($0 ~ /^[[:space:]]*\[markdown\]/); next }
    in_md && $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, ""); gsub(/^"|"[[:space:]]*$/, ""); print; exit
    }
  ' "$toml"
}

resolve_backlog_path() {  # <toml-key> <default-relative>
  local p; p=$(toml_markdown_value "$1"); [ -n "$p" ] || p=$2
  case "$p" in /*) printf '%s\n' "$p" ;; *) printf '%s/%s\n' "$FM_HOME" "$p" ;; esac
}

# Emit the id of every kind captain item in <file> that is Done (- [x]) yet still bears
# the awaiting sentinel and carries no resolution record - the exact corrupt state.
scan_unanswered_captain_dones() {  # <file>
  [ -f "$1" ] || return 0
  awk '
    function flush() {
      if (have && is_done && is_captain && awaiting && !resolution) print id
      have=0; is_done=0; is_captain=0; awaiting=0; resolution=0; id=""
    }
    /^- \[/ {
      flush(); have=1
      is_done = ($0 ~ /^- \[x\]/)
      is_captain = ($0 ~ /\(kind: captain\)/)
      s=$0; sub(/^- \[.\] /,"",s); sub(/ .*/,"",s); id=s
      if ($0 ~ /State: awaiting captain decision\./) awaiting=1
      if ($0 ~ /Resolution recorded by fm-decision-hold\./) resolution=1
      next
    }
    /^## / { flush(); next }
    have {
      if ($0 ~ /State: awaiting captain decision\./) awaiting=1
      if ($0 ~ /Resolution recorded by fm-decision-hold\./) resolution=1
    }
    END { flush() }
  ' "$1"
}

command_guard() {
  local restore=0 backlog archive active_ids archive_ids id rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --restore) restore=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  # Detection is pure file reading and never needs tasks-axi, so the read-only guard can
  # gate teardown even where the backend is unavailable. Only recovery mutates the backlog.
  [ "$restore" = 0 ] || require_tasks_axi
  backlog=$(resolve_backlog_path path data/backlog.md)
  archive=$(resolve_backlog_path archive data/done-archive.md)
  active_ids=$(scan_unanswered_captain_dones "$backlog")
  archive_ids=$(scan_unanswered_captain_dones "$archive")

  if [ -z "$active_ids" ] && [ -z "$archive_ids" ]; then
    printf 'guard: no unanswered captain hold is closed in %s or %s\n' "$backlog" "$archive"
    return 0
  fi

  if [ "$restore" = 0 ]; then
    echo "guard: REFUSED - captain decision hold(s) closed without a captain answer:" >&2
    for id in $active_ids; do printf '  %s (active backlog: %s)\n' "$id" "$backlog" >&2; done
    for id in $archive_ids; do printf '  %s (retention archive: %s)\n' "$id" "$archive" >&2; done
    fail "these hold(s) are Done while still awaiting a decision; run 'fm-decision-hold.sh guard --restore' (archived holds must be moved back into $backlog first)"
  fi

  # Restore recovers active-backlog offenders deterministically through tasks-axi.
  # The re-hold reason carries a 'verify not already shipped' warning because a
  # reopened hold fed one duplicate build in the double-build incident: reopening
  # a hold whose work already landed is exactly how a worker gets dispatched onto
  # finished work, so the operator is reminded to check before re-dispatching.
  for id in $active_ids; do
    tasks_axi reopen "$id" >/dev/null || { echo "guard: could not reopen $id" >&2; rc=1; continue; }
    tasks_axi hold "$id" --reason "reopened by guard: closed while awaiting a captain decision - verify not already shipped before re-dispatching" --kind captain >/dev/null \
      || { echo "guard: could not re-hold $id" >&2; rc=1; continue; }
    printf 'restored: %s (verify not already shipped before re-dispatching)\n' "$id"
  done
  # Archived offenders are outside tasks-axi's reach; report them for un-archiving.
  for id in $archive_ids; do
    printf 'archived-unanswered: %s (move from %s into %s, then rerun --restore)\n' "$id" "$archive" "$backlog" >&2
    rc=1
  done
  return "$rc"
}

case "${1:-}" in
  id) shift; command_id "$@" ;;
  hold) shift; command_hold "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  close) shift; command_close "$@" ;;
  guard) shift; command_guard "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
