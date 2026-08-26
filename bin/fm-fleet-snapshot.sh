#!/usr/bin/env bash
# fm-fleet-snapshot.sh - read-only structured fleet snapshot.
#
# Output contract: `--json` prints one object with schema
# `fm-fleet-snapshot.v1`.
# The command is read-only: it does not acquire the session lock, drain wakes,
# arm watchers, mutate backlog state, or write reports.
#
# Default output is a COMPACT projection (mode:"compact") bounded by a hard
# size ceiling, so a per-call read stays cheap no matter how the fleet grows.
# `--full` restores the complete serialization (the historical shape, byte for
# byte), and `--fields <name,...>` restores individual fat surfaces:
#   body        - backlog raw lines, full bodies, body excerpts, full titles
#   events      - per-task status-log last event, last-event text, current-state raw
#   actions     - per-task watch/steer/send actions
#   paths       - per-task path values (compact keeps only presence flags)
#   secondmates - full secondmate_current records and the full landed roll-up
#   reports     - the full scout-report pointer list
# The compact default keeps: record identity, state, title capped at 120 chars
# with an inline full-source pointer, decision/PR metadata (blocked_by,
# hold_reason, hold_kind, PR links, completion, captain_actionable), aggregate
# summary counts, and a projection block that discloses every truncation with
# its reveal command. Presence (ABSENT vs empty vs content) is preserved, and
# the ceiling is enforced mechanically by trimming rows in a fixed order with
# disclosure, never by silent elision.
# `--summary` prints only the aggregate counts object.
#
# Top-level fields:
#   schema: stable schema id.
#   mode: "compact" (default) or "full" (--full); absent in the historical
#     full shape, which --full reproduces byte for byte.
#   projection: compact-only block with ceiling, chars, restored fields,
#     truncated[] disclosure (surface, shown, total, reveal), and the
#     full-output hint.
#   summary: compact-only aggregate counts (backlog by state, captain holds,
#     tasks, working, secondmates, open decisions, landed, scout reports).
#   generated: UTC observation time for this fresh command execution.
#   fm_home: resolved operational home.
#   roots: resolved root/config/data/state/projects directories.
#   backlog: {path,present,records[]} where records are ordered as written in
#     data/backlog.md and cover In flight, Queued, and Done.
#     Canonical tasks-axi rows are structured; free-form non-empty lines in
#     those sections are preserved as unstructured records.
#     Structured rows preserve captain-hold metadata such as hold_kind and
#     hold_reason when tasks-axi emits it. They also carry normalized current_role,
#     requires_child_metadata, blocked_by_ids, unresolved_blocker_ids, and
#     captain_actionable fields. Repeated blocker tokens remain ordered; a blocker
#     resolves only when its structured record is Done, and missing ids stay open.
#     Compact rows additionally carry body_lines_count and records_shown,
#     records_total, records_truncated on the backlog object.
#   tasks[]: one row per state/<id>.meta, sorted by id.
#     current_state is parsed from bin/fm-crew-state.sh <id> and preserves
#     state, source, detail, and raw line separately.
#     paths.status_log.last_event is historical wake-event data only, never
#     current state.
#     hints.open_decisions is the keyed open-decision set returned by
#     fm-classify-lib.sh's authoritative status_open_decisions fold and reconciled
#     against current_state; hints.pending_decision and hints.blocked_event are
#     booleans derived from that set.
#     endpoint.exists is the cheap backend endpoint-presence read.
#     endpoint.agent_alive is populated for secondmates only, where it is useful
#     return-channel supervision data; other tasks use "not_checked".
#     telemetry is the state/<id>.telemetry sub-object (bin/fm-telemetry-lib.sh);
#     only keys present in the file are rendered, so absent data is {}, never a
#     fabricated zero.
#   scout_reports[]: present data/<id>/report.md pointers.
#   main_inventory: {valid,reason,orphan_in_flight[],unstructured_current_count} -
#     main-home current-inventory checks shared with secondmate_home_summary_json
#     (orphan structured in-flight ids with no state/<id>.meta, and unstructured
#     current backlog rows). Does not invent live tasks; meta remains truth for
#     workers. Bearings maps failures into omitted[] disclosure (and a Charted
#     Next gate line) rather than silent empty Underway.
#   secondmate_current: {records[],total,shown,truncated} - bounded current summaries
#     for registered secondmates, selected from validated structured state inside
#     each home with explicit provenance, freshness, endpoint evidence, and unknown
#     failure reasons. Parent status and bounded terminal evidence are historical,
#     untrusted supplements only and never override readable structured-home facts.
#     Each structured-home record carries active_children, decisions_open, holds,
#     queued, landed, endpoints, counts, and omitted. Actionable captain holds
#     appear in decisions_open; blocked captain holds remain queued with metadata.
#     Compact records keep id, home, current, provenance, freshness,
#     active_children, decisions_open (summaries capped with a pointer), counts,
#     omitted, and contradiction; holds/queued/landed/parent evidence restore
#     via --fields secondmates.
#   secondmate_landed: {records[],truncated[],unreadable[],partial[]} - the
#     compatibility landed-work roll-up derived from secondmate_current. Readable
#     structured homes with an unknown current classification are partial, not
#     unreadable, and retain independently trustworthy structured surfaces.
#     Compact mode adds records_total/records_shown and caps the list.
#   secondmate_guidance: return-channel action note for renderers and bearings.
#
# Compatibility: JSON is the primary machine-readable surface.
# Human views must render this output instead of parsing state files again.
# Consumers that render fat fields pass --fields/--full so their view is
# unaffected by the compact default (fm-fleet-view.sh, fm-bearings-snapshot.sh).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
BACKLOG="$DATA/backlog.md"
SNAPSHOT_NOW=${FM_SNAPSHOT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
if [ -n "${FM_SNAPSHOT_NOW_EPOCH:-}" ]; then
  SNAPSHOT_EPOCH=$FM_SNAPSHOT_NOW_EPOCH
else
  SNAPSHOT_EPOCH=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$SNAPSHOT_NOW" +%s 2>/dev/null \
    || date -u -d "$SNAPSHOT_NOW" +%s 2>/dev/null \
    || date +%s)
fi
case "$SNAPSHOT_EPOCH" in ''|*[!0-9]*) SNAPSHOT_EPOCH=$(date +%s) ;; esac

# Cross-home bounds are explicit so one broken or unexpectedly large home cannot
# hang or explode the parent snapshot.
FM_SNAPSHOT_SECONDMATES=${FM_SNAPSHOT_SECONDMATES:-20}
FM_SNAPSHOT_SECONDMATE_TIMEOUT=${FM_SNAPSHOT_SECONDMATE_TIMEOUT:-8}
FM_SNAPSHOT_SECONDMATE_MAX_BYTES=${FM_SNAPSHOT_SECONDMATE_MAX_BYTES:-262144}
FM_SNAPSHOT_SECONDMATE_CHILDREN=${FM_SNAPSHOT_SECONDMATE_CHILDREN:-20}
FM_SNAPSHOT_SECONDMATE_QUEUED=${FM_SNAPSHOT_SECONDMATE_QUEUED:-20}
FM_SNAPSHOT_SECONDMATE_DECISIONS=${FM_SNAPSHOT_SECONDMATE_DECISIONS:-20}
FM_SNAPSHOT_TERMINAL_LINES=${FM_SNAPSHOT_TERMINAL_LINES:-8}
FM_SNAPSHOT_TERMINAL_BYTES=${FM_SNAPSHOT_TERMINAL_BYTES:-4096}
FM_SNAPSHOT_TERMINAL_TIMEOUT=${FM_SNAPSHOT_TERMINAL_TIMEOUT:-2}
FM_SNAPSHOT_PARENT_ACTIVITY_LINES=${FM_SNAPSHOT_PARENT_ACTIVITY_LINES:-256}
FM_SNAPSHOT_PARENT_ACTIVITY_BYTES=${FM_SNAPSHOT_PARENT_ACTIVITY_BYTES:-65536}
FM_SNAPSHOT_PARENT_ACTIVITIES=${FM_SNAPSHOT_PARENT_ACTIVITIES:-20}
FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT=${FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT:-2}
FM_SNAPSHOT_REGISTRY_LINES=${FM_SNAPSHOT_REGISTRY_LINES:-256}
FM_SNAPSHOT_REGISTRY_BYTES=${FM_SNAPSHOT_REGISTRY_BYTES:-65536}
FM_SNAPSHOT_REGISTRY_RECORDS=${FM_SNAPSHOT_REGISTRY_RECORDS:-40}
FM_SNAPSHOT_REGISTRY_TIMEOUT=${FM_SNAPSHOT_REGISTRY_TIMEOUT:-2}
# Gap 3: a status EVENT older than this (seconds) is marked OLD when the current
# state has a FRESHER authoritative source (run-step/pane), so a supervisor never
# reads a stale wake event as current truth. Default 600s (the slow-poll cadence).
FM_SNAPSHOT_EVENT_OLD_THRESHOLD=${FM_SNAPSHOT_EVENT_OLD_THRESHOLD:-600}
case "$FM_SNAPSHOT_EVENT_OLD_THRESHOLD" in ''|*[!0-9]*) FM_SNAPSHOT_EVENT_OLD_THRESHOLD=600 ;; esac
validate_positive_bound() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*|0)
      printf 'fm-fleet-snapshot: %s must be a positive integer\n' "$1" >&2
      exit 2
      ;;
  esac
}
case "$FM_SNAPSHOT_SECONDMATES" in
  ''|*[!0-9]*)
    echo "fm-fleet-snapshot: FM_SNAPSHOT_SECONDMATES must be a non-negative integer" >&2
    exit 2
    ;;
esac
validate_positive_bound FM_SNAPSHOT_SECONDMATE_TIMEOUT "$FM_SNAPSHOT_SECONDMATE_TIMEOUT"
validate_positive_bound FM_SNAPSHOT_SECONDMATE_MAX_BYTES "$FM_SNAPSHOT_SECONDMATE_MAX_BYTES"
validate_positive_bound FM_SNAPSHOT_SECONDMATE_CHILDREN "$FM_SNAPSHOT_SECONDMATE_CHILDREN"
validate_positive_bound FM_SNAPSHOT_SECONDMATE_QUEUED "$FM_SNAPSHOT_SECONDMATE_QUEUED"
validate_positive_bound FM_SNAPSHOT_SECONDMATE_DECISIONS "$FM_SNAPSHOT_SECONDMATE_DECISIONS"
validate_positive_bound FM_SNAPSHOT_TERMINAL_LINES "$FM_SNAPSHOT_TERMINAL_LINES"
validate_positive_bound FM_SNAPSHOT_TERMINAL_BYTES "$FM_SNAPSHOT_TERMINAL_BYTES"
validate_positive_bound FM_SNAPSHOT_TERMINAL_TIMEOUT "$FM_SNAPSHOT_TERMINAL_TIMEOUT"
validate_positive_bound FM_SNAPSHOT_PARENT_ACTIVITY_LINES "$FM_SNAPSHOT_PARENT_ACTIVITY_LINES"
validate_positive_bound FM_SNAPSHOT_PARENT_ACTIVITY_BYTES "$FM_SNAPSHOT_PARENT_ACTIVITY_BYTES"
validate_positive_bound FM_SNAPSHOT_PARENT_ACTIVITIES "$FM_SNAPSHOT_PARENT_ACTIVITIES"
validate_positive_bound FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT "$FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT"
validate_positive_bound FM_SNAPSHOT_REGISTRY_LINES "$FM_SNAPSHOT_REGISTRY_LINES"
validate_positive_bound FM_SNAPSHOT_REGISTRY_BYTES "$FM_SNAPSHOT_REGISTRY_BYTES"
validate_positive_bound FM_SNAPSHOT_REGISTRY_RECORDS "$FM_SNAPSHOT_REGISTRY_RECORDS"
validate_positive_bound FM_SNAPSHOT_REGISTRY_TIMEOUT "$FM_SNAPSHOT_REGISTRY_TIMEOUT"

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-ff-lib.sh"  # validate_secondmate_home: shared seeded-home boundary checks

usage() {
  cat <<'EOF'
usage: fm-fleet-snapshot.sh [--json] [--full] [--summary] [--fields <name,...>]
       fm-fleet-snapshot.sh --secondmate-home-summary

Print a read-only structured snapshot of the firstmate fleet.
JSON is the stable machine-readable output contract.

--fields <name,...>  opt in to fat surfaces in the compact default:
  body        backlog raw lines, full bodies, body excerpts, full titles
  events      per-task status-log last event, last-event text, current-state raw
  actions     per-task watch/steer/send actions
  paths       per-task path values (compact keeps presence flags only)
  secondmates full secondmate_current records and the full landed roll-up
  reports     the full scout-report pointer list
--full        the complete serialization (historical shape, byte for byte);
              overrides --fields.
--summary     print only the aggregate counts object (schema fm-fleet-snapshot.v1,
              mode "summary") and exit.
The default compact projection carries identity, state, titles capped at 120
chars with inline full-source pointers, decision/PR metadata, aggregate counts,
and a projection block disclosing every truncation with its reveal command.
The output is bounded by FM_SNAPSHOT_COMPACT_CEILING (default 20000 chars),
enforced by trimming rows in a fixed order with disclosure, never silence.

--secondmate-home-summary emits the bounded structured summary used after a
validated registered-home handoff. It is local-only, skips nested secondmate
aggregation, and marks inventory contradictions or unavailable child state invalid.
Its invalidity object names the normalized failure kind and affected ids.
Actionable tasks-axi captain holds appear as decisions_open and stay visible in
queued with hold_reason, hold_kind, and plural blocker fields for downstream
projections. A captain hold is actionable only when every blocker is Done.
Cross-home reads use FM_SNAPSHOT_SECONDMATES (default 20, 0 lifts the count
bound), FM_SNAPSHOT_SECONDMATE_TIMEOUT, and FM_SNAPSHOT_SECONDMATE_MAX_BYTES.
Terminal contradiction evidence uses
FM_SNAPSHOT_TERMINAL_LINES, FM_SNAPSHOT_TERMINAL_BYTES, and
FM_SNAPSHOT_TERMINAL_TIMEOUT and never becomes canonical current state.
Parent activity evidence uses FM_SNAPSHOT_PARENT_ACTIVITY_LINES,
FM_SNAPSHOT_PARENT_ACTIVITY_BYTES, FM_SNAPSHOT_PARENT_ACTIVITIES, and
FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT, with truncation disclosed in the result.
The registered secondmate table uses FM_SNAPSHOT_REGISTRY_LINES,
FM_SNAPSHOT_REGISTRY_BYTES, FM_SNAPSHOT_REGISTRY_RECORDS, and
FM_SNAPSHOT_REGISTRY_TIMEOUT, with unavailability and truncation disclosed.
EOF
}

# Compact-default hard ceiling. Enforced by trimming rows in a fixed order with
# disclosure (projection.truncated[]), never by silent elision.
FM_SNAPSHOT_COMPACT_CEILING=${FM_SNAPSHOT_COMPACT_CEILING:-20000}
case "$FM_SNAPSHOT_COMPACT_CEILING" in
  ''|*[!0-9]*|0) echo "fm-fleet-snapshot: FM_SNAPSHOT_COMPACT_CEILING must be a positive integer" >&2; exit 2 ;;
esac

OUTPUT_MODE=json
FULL=0
SUMMARY=0
FIELDS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) OUTPUT_MODE=json ;;
    --secondmate-home-summary) OUTPUT_MODE=secondmate-home-summary ;;
    --full) FULL=1 ;;
    --summary) SUMMARY=1 ;;
    --fields) shift; FIELDS="${FIELDS:+$FIELDS,}${1:-}" ;;
    --fields=*) FIELDS="${FIELDS:+$FIELDS,}${1#--fields=}" ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

if [ -n "$FIELDS" ]; then
  # Normalize to a comma-joined set in a fixed order, rejecting unknown names
  # so a typo fails closed instead of silently printing the compact default.
  NORMALIZED_FIELDS=""
  for name in body events actions paths secondmates reports; do
    case ",$FIELDS," in
      *",$name,"*) NORMALIZED_FIELDS="${NORMALIZED_FIELDS:+$NORMALIZED_FIELDS,}$name" ;;
    esac
  done
  for name in $(printf '%s' "$FIELDS" | tr ',' ' '); do
    case "$name" in
      body|events|actions|paths|secondmates|reports) ;;
      *)
        echo "fm-fleet-snapshot: unknown --fields name '$name' (valid: body, events, actions, paths, secondmates, reports)" >&2
        exit 2
        ;;
    esac
  done
  FIELDS=$NORMALIZED_FIELDS
fi

command -v jq >/dev/null 2>&1 || { echo "fm-fleet-snapshot: jq not found" >&2; exit 1; }

bool_json() {
  if [ "$1" = 1 ]; then printf 'true'; else printf 'false'; fi
}

path_present_json() {  # <path>
  local present=0
  [ -e "$1" ] && present=1
  jq -n --arg path "$1" --argjson present "$(bool_json "$present")" \
    '{path:$path,present:$present}'
}

meta_value() {  # <meta-file> <key>
  fm_meta_get "$1" "$2"
}

last_nonempty_line() {  # <file>
  [ -f "$1" ] || return 1
  grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1
}

crew_state_json() {  # <id>
  local id=$1 raw rest state source detail sep superseded
  raw=$(
    FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$STATE" \
      FM_DATA_OVERRIDE="$DATA" \
      FM_PROJECTS_OVERRIDE="$PROJECTS" \
      FM_CONFIG_OVERRIDE="$CONFIG" \
      "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null || true
  )
  raw=$(printf '%s\n' "$raw" | head -1)
  sep=' · '
  state=unknown
  source=none
  detail=
  case "$raw" in
    state:\ *"$sep"source:\ *)
      rest=${raw#state: }
      state=${rest%%"$sep"source: *}
      rest=${rest#*"$sep"source: }
      case "$rest" in
        *"$sep"*) source=${rest%%"$sep"*}; detail=${rest#*"$sep"} ;;
        *) source=$rest ;;
      esac
      ;;
  esac
  # Surface the superseded reconciliation fm-crew-state.sh already computes
  # (bin/fm-crew-state.sh:38-42): a needs-decision/blocked status-log line that the
  # authoritative run-step has moved past appends a "superseded" note to the detail.
  # This is a pure surfacing of an existing value, not a new computation.
  superseded=0
  case "$detail" in *superseded*) superseded=1 ;; esac
  jq -n --arg raw "$raw" --arg state "$state" --arg source "$source" --arg detail "$detail" \
    --argjson superseded "$(bool_json "$superseded")" \
    '{state:$state,source:$source,detail:$detail,superseded:$superseded,raw:$raw}'
}

# Human "2h10m"/"47m" age for an event, used by renderers to pair a status EVENT
# with a freshness marker. Empty input (no status file / unknown mtime) -> "".
snapshot_event_age_label() {  # <seconds>
  local s=${1:-}
  case "$s" in ''|*[!0-9]*) printf ''; return 0 ;; esac
  if [ "$s" -lt 3600 ]; then
    printf '%dm' $(( s / 60 ))
  else
    printf '%dh%dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
  fi
}

status_event_json() {  # <status-log>
  local log=$1 present=0 raw='' verb='' note='' event_epoch='' age_seconds='' age_label=''
  if [ -f "$log" ]; then
    present=1
    raw=$(last_nonempty_line "$log" || true)
    verb=$(status_line_verb "$raw")
    note=$(status_line_note "$raw")
    # Freshness age of the LAST wake event: its file mtime against snapshot NOW.
    # Renderers pair this age with the current state so a stale event is never
    # shown as if it were current truth (Gap 3). file_mtime_epoch is defined
    # below and resolved at call time (this function only runs from the meta loop).
    event_epoch=$(file_mtime_epoch "$log")
    case "$event_epoch" in
      ''|*[!0-9]*) event_epoch=''; age_seconds=''; age_label='' ;;
      *)
        age_seconds=$(( SNAPSHOT_EPOCH - event_epoch ))
        [ "$age_seconds" -lt 0 ] && age_seconds=0
        age_label=$(snapshot_event_age_label "$age_seconds")
        ;;
    esac
  fi
  jq -n \
    --arg path "$log" \
    --arg raw "$raw" \
    --arg verb "$verb" \
    --arg note "$note" \
    --arg age_label "$age_label" \
    --argjson age_seconds "$(if [ -n "$age_seconds" ]; then printf '%s' "$age_seconds"; else printf 'null'; fi)" \
    --argjson present "$(bool_json "$present")" \
    '{path:$path,present:$present,kind:"event_history",
      last_event:{state:$verb,note:$note,raw:$raw,
        age_seconds:$age_seconds,
        age_label:(if $age_label == "" then null else $age_label end)}}'
}

first_pr_url_in_file() {  # <file>
  [ -f "$1" ] || return 1
  grep -Eo 'https?://[^[:space:])"]+/pull/[0-9]+' "$1" 2>/dev/null | head -1
}

backlog_json() {  # [<backlog-path>] - defaults to this home's $BACKLOG
  local backlog=${1:-$BACKLOG}
  if [ ! -f "$backlog" ]; then
    jq -n --arg path "$backlog" '{path:$path,present:false,records:[]}'
    return 0
  fi

  # shellcheck disable=SC2094
  jq -Rn --arg path "$backlog" '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def section_state:
      if . == "In flight" then "in_flight"
      elif . == "Queued" then "queued"
      elif . == "Done" then "done"
      else null end;
    def cap($rest; $re):
      (((($rest | capture($re)?) // {}) | .v) // null) as $v
      | if $v == null then null else ($v | trim) end;
    def metadata($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + ":[[:space:]]*(?<v>[^,)]*)");
    def metadata_word($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + "[[:space:]]+(?<v>[^,)]*)");
    def url_pattern: "https?://[^[:space:])\"<>]+";
    def wrapped_url_pattern: "<?" + url_pattern + ">?";
    def links($rest): [$rest | scan(url_pattern)];
    def strip_trailing_metadata:
      reduce range(0; 20) as $_ (.;
        sub("[[:space:]]*\\([[:space:]]*(?:(?:repo|kind|priority|hold|hold-kind):[[:space:]]*[^)]*|(?:since|merged|reported|done)[[:space:]]+[^)]*)[[:space:]]*\\)[[:space:]]*$"; ""));
    def strip_title_artifacts:
      sub("[[:space:]]+-[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
      | sub("[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
      | sub("[[:space:]]+-[[:space:]]+local main$"; "")
      | sub("[[:space:]]+local main$"; "")
      | sub("[[:space:]]+-[[:space:]]*$"; "");
    def clean_title:
      strip_trailing_metadata
      | strip_title_artifacts
      | gsub("[[:space:]]+"; " ")
      | trim;
    def title_of($rest):
      $rest
      | gsub(wrapped_url_pattern; "")
      | sub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:])]+[[:space:]]+-[[:space:]]+.*$"; "")
      | gsub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:]]+"; "")
      | clean_title;
    def blocked_by_ids($rest):
      [ $rest | scan("blocked-by:[[:space:]]+(?<id>[^[:space:])]+)") | .[0] ]
      | reduce .[] as $id ([]; if index($id) == null then . + [$id] else . end);
    def blocked_reason($rest):
      cap($rest; ".*blocked-by:[[:space:]]*[^[:space:])]+[[:space:]]+-[[:space:]]*(?<v>.*)$") as $reason
      | if $reason == null then null
        else ($reason | clean_title | if . == "" then null else . end)
        end;
    def local_note($rest):
      cap(($rest | strip_trailing_metadata); ".*(?:^|[[:space:]]+-[[:space:]]+|[[:space:]])(?<v>local main)$");
    def completion($rest):
      (metadata_word($rest; "merged")) as $merged
      | (metadata_word($rest; "reported")) as $reported
      | (metadata_word($rest; "done")) as $done
      | if $merged != null then {verb:"merged",date:$merged}
        elif $reported != null then {verb:"reported",date:$reported}
        elif $done != null then {verb:"done",date:$done}
        else {verb:null,date:null} end;
    def row_match($line):
      (($line | capture("^[-*][[:space:]]+\\[(?<check>[ xX])\\][[:space:]]+(?<id>[^[:space:]]+)[[:space:]]+-[[:space:]]+(?<rest>.*)$")?) //
       (($line | capture("^[-*][[:space:]]+\\*\\*(?<id>[^*]+)\\*\\*[[:space:]]+-[[:space:]]+(?<rest>.*)$")?)
        | if . == null then null else . + {check:" "} end));
    def structured_row($line):
      ($line | test("^[-*][[:space:]]+\\[[ xX]\\][[:space:]]+[^[:space:]]+[[:space:]]+-[[:space:]]+"))
      or ($line | test("^[-*][[:space:]]+\\*\\*[^*]+\\*\\*[[:space:]]+-[[:space:]]+"));
    def parse_row($line; $section; $order):
      row_match($line) as $m
      | if $m == null then
          {order:$order,state:$section,structured:false,id:null,raw:$line,body_lines:[],body_excerpt:null}
        else
          ($m.rest) as $rest
          | {order:$order,
             state:$section,
             structured:true,
             id:($m.id | trim),
             checked:($m.check | test("[xX]")),
             title:title_of($rest),
             repo:metadata($rest; "repo"),
             kind:metadata($rest; "kind"),
             priority:metadata($rest; "priority"),
             hold_reason:metadata($rest; "hold"),
             hold_kind:metadata($rest; "hold-kind"),
             blocked_by:cap($rest; ".*blocked-by:[[:space:]]*(?<v>[^[:space:])]+).*"),
             blocked_by_ids:blocked_by_ids($rest),
             blocked_reason:blocked_reason($rest),
             since:metadata_word($rest; "since"),
             merged:metadata_word($rest; "merged"),
             reported:metadata_word($rest; "reported"),
             done:metadata_word($rest; "done"),
             completion:completion($rest),
             links:links($rest),
             pr_url:((links($rest) | map(select(test("/pull/[0-9]+"))) | .[0]) // null),
             report_path:cap($rest; ".*(?<v>data/[^[:space:])]+/report\\.md).*"),
             local_note:local_note($rest),
             raw:$line,
             body_lines:[],
             body_excerpt:null}
        end;
    reduce inputs as $line
      ({path:$path,present:true,records:[],section:null,order:0};
       if ($line | test("^##[[:space:]]+")) then
         .section = (($line | sub("^##[[:space:]]+";"") | trim) | section_state)
       elif .section == null or ($line | trim) == "" then
         .
       elif structured_row($line) then
         .order += 1
         | .records += [parse_row($line; .section; .order)]
       elif ((.records | length) > 0 and (.records[-1].structured == true) and ($line | test("^[[:space:]]+"))) then
         ($line | trim) as $body
         | if $body == "" then .
           else .records[-1].body_lines += [$body] end
       else
         .order += 1
         | .records += [{order:.order,state:.section,structured:false,id:null,raw:$line,body_lines:[],body_excerpt:null}]
       end)
    | .records |= map(
        if (.body_lines | length) > 0 then
          .body_excerpt = ((.body_lines | join(" "))[:240])
        else . end)
    | .records as $records
    | (reduce ($records[] | select(.structured)) as $record ({};
         .[$record.id] = ((.[$record.id] // true) and ($record.state == "done")))) as $resolved_ids
    | .records |= map(
        if .structured then
          . as $record
          | .unresolved_blocker_ids = [
              $record.blocked_by_ids[] as $blocker
              | select($resolved_ids[$blocker] != true)
              | $blocker
            ]
          | .current_role =
              (if .state == "in_flight" and .hold_reason != null and .hold_kind != null then "held"
               elif .state == "in_flight" and .kind == "program" then "program"
               elif .state == "in_flight" then "worker"
               elif .state == "queued" then "queued"
               else "done" end)
          | .requires_child_metadata = (.current_role == "worker")
          | .captain_actionable =
              (.state == "queued" and .kind == "captain" and .hold_kind == "captain"
               and .hold_reason != null and (.unresolved_blocker_ids | length) == 0)
        else . end)
    | del(.section,.order)
  ' < "$backlog"
}

task_json_lines() {
  local meta id kind harness mode yolo project worktree home projects backend target status_log report_path
  local pr pr_source event_json current_json endpoint_exists agent_alive meta_json status_json report_json worktree_json home_json
  local last_event_raw current_state current_source pending_decision blocked_event report_present=0 pr_from_status
  local open_decisions_tsv open_decisions_json telemetry_file telemetry_json

  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(meta_value "$meta" kind)
    [ -n "$kind" ] || kind=ship
    harness=$(meta_value "$meta" harness)
    mode=$(meta_value "$meta" mode)
    yolo=$(meta_value "$meta" yolo)
    project=$(meta_value "$meta" project)
    worktree=$(meta_value "$meta" worktree)
    home=$(meta_value "$meta" home)
    projects=$(meta_value "$meta" projects)
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    status_log="$STATE/$id.status"
    report_path="$DATA/$id/report.md"
    pr=$(meta_value "$meta" pr)
    pr_source=meta
    if [ -z "$pr" ]; then
      pr_from_status=$(first_pr_url_in_file "$status_log" || true)
      pr=$pr_from_status
      pr_source=status_event
    fi
    if [ -z "$pr" ]; then
      pr_source=absent
    fi

    current_json=$(crew_state_json "$id")
    event_json=$(status_event_json "$status_log")
    last_event_raw=$(printf '%s' "$event_json" | jq -r '.last_event.raw // ""')
    current_state=$(printf '%s' "$current_json" | jq -r '.state // ""')
    current_source=$(printf '%s' "$current_json" | jq -r '.source // ""')

    # Gap 3 OLD marker: the last wake event is OLD only when it is older than the
    # threshold AND the current state has a FRESHER authoritative source than the
    # event (run-step or pane). A young event, or one whose only current-state
    # source IS the status log, is never OLD - there is nothing fresher to trust.
    event_age_seconds=$(printf '%s' "$event_json" | jq -r '.last_event.age_seconds // ""')
    event_old=0
    case "$current_source" in
      run-step|pane)
        case "$event_age_seconds" in
          ''|*[!0-9]*) : ;;
          *) [ "$event_age_seconds" -gt "$FM_SNAPSHOT_EVENT_OLD_THRESHOLD" ] && event_old=1 ;;
        esac
        ;;
    esac
    event_json=$(printf '%s' "$event_json" \
      | jq --argjson old "$(bool_json "$event_old")" '.last_event.old = $old')

    # Durable keyed open-decision set: fold the WHOLE status stream
    # (fm-classify-lib.sh's status_open_decisions) so a later unrelated event can
    # never mask a still-open captain decision. The set is derived purely from the
    # keyed fold - never from report bodies or decision-like prose - and then
    # reconciled against the crew LIFECYCLE, which only clears a stale decision the
    # crew has provably moved past. Two lifecycle signals clear it, neither of which
    # reads any report content:
    #   - a live activity read (run-step or busy pane) that is working/done, so a
    #     crew that resumed past a gate is not still reported as parked; and
    #   - a TERMINAL done/failed state on a single-owner task (scout or ship), whose
    #     deliverable is its report or PR, so a COMPLETED scout surfaces only as a
    #     report POINTER, never as a reopened pending decision.
    # Secondmates are excluded from lifecycle clearing: they are persistent and
    # multiplex many concerns onto one stream, so activity on one concern must
    # never clear another concern's keyed decision. A parked/blocked state, or a
    # non-authoritative status-log/none read on a still-live task, keeps the fold's
    # open decision surfacing.
    open_decisions_tsv=$(status_open_decisions "$status_log")
    if [ "$kind" != secondmate ] && \
       { { { [ "$current_source" = run-step ] || [ "$current_source" = pane ]; } \
           && [ "$current_state" != parked ] && [ "$current_state" != blocked ]; } \
         || { [ "$current_state" = "done" ] || [ "$current_state" = "failed" ]; }; }; then
      open_decisions_tsv=""
    fi
    open_decisions_json=$(printf '%s' "$open_decisions_tsv" | jq -R -s '
      [ splits("\n") | select(length > 0)
        | (capture("^(?<key>[^\t]*)\t(?<verb>[^\t]*)\t(?<summary>.*)$")?)
        | select(. != null) ]')
    pending_decision=$(printf '%s' "$open_decisions_json" | jq 'if any(.[]; .verb == "needs-decision") then 1 else 0 end')
    blocked_event=$(printf '%s' "$open_decisions_json" | jq 'if any(.[]; .verb == "blocked") then 1 else 0 end')

    endpoint_exists=null
    if [ -n "$target" ]; then
      if fm_backend_target_exists "$backend" "$target" "fm-$id" >/dev/null 2>&1; then
        endpoint_exists=true
      else
        endpoint_exists=false
      fi
    fi
    agent_alive=not_checked
    if [ "$kind" = secondmate ] && [ -n "$target" ]; then
      agent_alive=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null || printf unknown)
    fi

    [ -f "$report_path" ] && report_present=1 || report_present=0
    meta_json=$(path_present_json "$meta")
    status_json=$event_json
    report_json=$(path_present_json "$report_path")
    if [ -n "$worktree" ]; then worktree_json=$(path_present_json "$worktree"); else worktree_json=$(jq -n '{path:null,present:false}'); fi
    if [ -n "$home" ]; then home_json=$(path_present_json "$home"); else home_json=$(jq -n '{path:null,present:false}'); fi

    # Gap-1 shared telemetry sub-object (state/<id>.telemetry, the same key=value
    # shape as .meta, read with fm_meta_get's parser). Only keys PRESENT in the
    # file are rendered: absent = unknown, NEVER zero. A task with no telemetry
    # file yet renders the empty object, so the dashboard and fleet view always
    # read a `telemetry:{}` row.
    telemetry_file="$STATE/$id.telemetry"
    if [ -f "$telemetry_file" ]; then
      # A single pipeline: jq must ALWAYS consume grep's output on a match
      # (a bare `|| true` after grep would short-circuit jq on the success
      # path and leak raw key=value text as the JSON). `|| printf '{}'`
      # guards the pipeline itself, so a grep/jq failure yields the empty
      # object.
      telemetry_json=$(grep -E '^[A-Za-z0-9_]+=' "$telemetry_file" 2>/dev/null \
        | jq -R -s '
            [splits("\n") | select(length > 0)
              | capture("^(?<key>[A-Za-z0-9_]+)=(?<value>.*)$")?
              | select(. != null) ]
            | from_entries' 2>/dev/null || printf '{}')
    else
      telemetry_json='{}'
    fi
    case "$telemetry_json" in ''|null) telemetry_json='{}' ;; esac

    jq -n \
      --arg id "$id" \
      --arg kind "$kind" \
      --arg harness "$harness" \
      --arg mode "$mode" \
      --arg yolo "$yolo" \
      --arg project "$project" \
      --arg worktree "$worktree" \
      --arg home "$home" \
      --arg projects "$projects" \
      --arg backend "$backend" \
      --arg target "$target" \
      --arg pr "$pr" \
      --arg pr_source "$pr_source" \
      --arg agent_alive "$agent_alive" \
      --arg observed_at "$SNAPSHOT_NOW" \
      --arg last_event_raw "$last_event_raw" \
      --argjson current_state "$current_json" \
      --argjson meta_path "$meta_json" \
      --argjson status_log "$status_json" \
      --argjson report "$report_json" \
      --argjson worktree_path "$worktree_json" \
      --argjson home_path "$home_json" \
      --argjson endpoint_exists "$endpoint_exists" \
      --argjson open_decisions "$open_decisions_json" \
      --argjson pending_decision "$(bool_json "$pending_decision")" \
      --argjson blocked_event "$(bool_json "$blocked_event")" \
      --argjson report_present "$(bool_json "$report_present")" \
      --argjson telemetry "$telemetry_json" \
      '{
        id:$id,
        kind:$kind,
        harness:($harness // ""),
        mode:($mode // ""),
        yolo:($yolo // ""),
        project:($project // ""),
        backend:$backend,
        telemetry:$telemetry,
        paths:{
          meta:$meta_path,
          status_log:$status_log,
          worktree:$worktree_path,
          home:$home_path,
          report:$report
        },
        secondmate_projects:($projects | if . == "" then [] else split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(. != "")) end),
        current_state:($current_state + {observed_at:$observed_at,freshness:"fresh"}),
        endpoint:{target:($target | if . == "" then null else . end),exists:$endpoint_exists,agent_alive:$agent_alive,
          status:(if $endpoint_exists == false then "absent"
                  elif $agent_alive == "alive" or $agent_alive == "dead" then $agent_alive
                  else "unknown" end),
          observed_at:$observed_at,freshness:"fresh"},
        pr:{url:($pr | if . == "" then null else . end),source:$pr_source},
        hints:{
          pending_decision:$pending_decision,
          blocked_event:$blocked_event,
          open_decisions:$open_decisions,
          scout_report_present:$report_present,
          last_event_text:$last_event_raw
        },
        actions:(
          if $kind == "secondmate" then
            {send:"bin/fm-send.sh fm-\($id) \u0027<request>\u0027",
             watch:"read status/doc return channel; do not routinely fm-peek a secondmate for answers",
             return_channel_note:"Secondmate answers come back through status/doc paths after a marked fm-send request."}
          else
            {watch:"bin/fm-peek.sh fm-\($id)",
             steer:"bin/fm-send.sh fm-\($id) \u0027<instruction>\u0027",
             return_channel_note:null}
          end)
      }'
  done | jq -s 'sort_by(.id)'
}

# Main-home current-inventory validity: same orphan / unstructured-current checks
# used by secondmate_home_summary_json, without inventing live task rows.
# Meta inventory remains the sole source of live workers; this object only
# discloses backlog↔task inconsistency for renderers (Bearings omitted/gates).
main_inventory_json() {  # <backlog-json> <tasks-json>
  # Feed the large backlog/tasks blobs on stdin and bind them with `input`
  # rather than passing them as --argjson argv strings. A single argv string is
  # capped at MAX_ARG_STRLEN (128KB) regardless of total ARG_MAX, and these
  # blobs now exceed that, which crashed jq with "Argument list too long".
  printf '%s\n%s\n' "$1" "$2" | jq -n '
    (input) as $backlog | (input) as $tasks
    | ([ $backlog.records[]?
       | select((.state == "in_flight" or .state == "queued") and (.structured | not)) ]) as $unstructured_current
    | ([ $backlog.records[]?
         | select(.state == "in_flight" and .structured and .requires_child_metadata) ]) as $owned_in_flight
    | ([ $owned_in_flight[]
         | select(.id as $id | [$tasks[].id] | index($id) | not)
         | .id ]) as $orphan_in_flight
    | (($unstructured_current | length) == 0
       and ($orphan_in_flight | length) == 0) as $valid
    | (if ($unstructured_current | length) > 0 then "unstructured current backlog row"
       elif ($orphan_in_flight | length) > 0 then "in-flight backlog item has no child metadata"
       else null end) as $reason
    | {
        valid:$valid,
        reason:$reason,
        orphan_in_flight:$orphan_in_flight,
        unstructured_current_count:($unstructured_current | length)
      }'
}

# Project one home's canonical structured inventory into the bounded shape a
# validated parent read needs.
# This mode never reads parent events or terminal text and never aggregates
# nested secondmates.
secondmate_home_summary_json() {  # <backlog-json> <tasks-json>
  # Large backlog/tasks blobs come in on stdin via `input` (see
  # main_inventory_json for the MAX_ARG_STRLEN rationale); only the small
  # scalar args stay as --arg/--argjson.
  printf '%s\n%s\n' "$1" "$2" | jq -n \
    --arg generated "$SNAPSHOT_NOW" \
    --arg home "$FM_HOME" \
    --argjson child_n "$FM_SNAPSHOT_SECONDMATE_CHILDREN" \
    --argjson queued_n "$FM_SNAPSHOT_SECONDMATE_QUEUED" \
    --argjson decisions_n "$FM_SNAPSHOT_SECONDMATE_DECISIONS" \
    --argjson landed_n "$FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME" '
    (input) as $backlog | (input) as $tasks
    | def trunc($n):
      tostring | gsub("\\s+"; " ")
      | if length > $n then .[:$n] + "…" else . end;
    ([ $backlog.records[]?
       | select((.state == "in_flight" or .state == "queued") and (.structured | not)) ]) as $unstructured_current
    | ([ $backlog.records[]? | select(.state == "in_flight" and .structured) ]) as $owned_in_flight
    | ([ $backlog.records[]?
         | select(.structured and
             (.state == "queued" or
              (.state == "in_flight" and .current_role == "held"
               and (.id as $id
                    | any($tasks[]; .id == $id and .current_state.state == "working") | not)))) ]) as $queued_all
    | ([ $queued_all[]
         | select(.captain_actionable == true)
         | {id,key:.id,verb:"captain-hold",summary:(.title | trunc(160)),
            reason:(.hold_reason | trunc(160)),
            priority:(.priority // null),since:(.since // null),
            blocking:(.priority == "0"),source:"backlog"} ]) as $captain_holds_all
    | ([ $backlog.records[]? | select(.state == "done" and .structured and .kind != "captain")
         | {id:(.id | trunc(120)),title:(.title | trunc(120)),
            pr_url:((.pr_url // null) | if . == null then null else trunc(500) end),
            report_path:((.report_path // null) | if . == null then null else trunc(500) end),
            local_note:((.local_note // null) | if . == null then null else trunc(120) end),completion} ]
       | sort_by([(.completion.date // ""), .id]) | reverse) as $landed_all
    | ([ $tasks[] | select(.current_state.state == "unknown") ]) as $unknown_children
    | ([ $owned_in_flight[]
         | select(.requires_child_metadata)
         | select(.id as $id | [$tasks[].id] | index($id) | not) ]) as $orphan_in_flight
    | ([ $tasks[]
         | select(.id as $id | [$owned_in_flight[].id] | index($id) | not)
         | {id,state:.current_state.state} ]) as $unowned_children
    | ([ $owned_in_flight[] as $work
         | $tasks[]
         | select(.id == $work.id and (.current_state.state == "done" or .current_state.state == "failed"))
         | {id,state:.current_state.state} ]) as $terminal_in_flight
    | ([if $backlog.present != true then
          {kind:"missing_backlog",ids:[],reason:"missing structured backlog"}
        else empty end,
        if ($unstructured_current | length) > 0 then
          {kind:"unstructured_current",ids:[],reason:"unstructured current backlog row"}
        else empty end,
        if ($orphan_in_flight | length) > 0 then
          {kind:"orphan_in_flight",ids:($orphan_in_flight | map(.id)),
           reason:("in-flight backlog item has no child metadata: " + ($orphan_in_flight | map(.id) | join(", ")))}
        else empty end,
        if ($unowned_children | length) > 0 then
          {kind:"unowned_current",ids:($unowned_children | map(.id)),
           reason:("live child state has no in-flight backlog item: " +
                   ($unowned_children | map(.id + "=" + .state) | join(", ")))}
        else empty end,
        if ($terminal_in_flight | length) > 0 then
          {kind:"terminal_in_flight",ids:($terminal_in_flight | map(.id)),
           reason:("in-flight backlog item has terminal child state: " +
                   ($terminal_in_flight | map(.id + "=" + .state) | join(", ")))}
        else empty end]) as $strict_invalidities
    | ([ $owned_in_flight[] as $work
         | select($work.current_role != "program")
         | $tasks[]
         | select(.id == $work.id and .current_state.state == "working")
         | {id,kind,state:.current_state.state,source:.current_state.source,
            doing:((.current_state.detail // "") | trunc(120))} ]) as $active_all
    | ($captain_holds_all
       + ([ $tasks[] as $t | ($t.hints.open_decisions // [])[]
            | {id:$t.id,key,verb,summary:(.summary | trunc(160)),reason:null,source:"status"} ])) as $decisions_all
    | ([ $queued_all[]
         | select((.unresolved_blocker_ids | length) > 0 or (.hold_reason != null and .hold_kind != null))
         | {id:(.id | trunc(120)),title:(.title | trunc(90)),
            blocked_by:((.unresolved_blocker_ids | join(",")) | if . == "" then null else trunc(120) end),
            blocked_by_ids:(.blocked_by_ids | map(trunc(120))),
            unresolved_blocker_ids:(.unresolved_blocker_ids | map(trunc(120))),
            reason:((.hold_reason // .blocked_reason // "blocked") | trunc(120)),source:"backlog"} ]
       + [ $owned_in_flight[] as $work
           | $tasks[]
           | select(.id == $work.id and (.current_state.state == "parked" or .current_state.state == "paused" or .current_state.state == "blocked"))
           | select(($work.hold_reason != null and $work.hold_kind != null) | not)
           | {id,title:((.backlog.title // .id) | trunc(90)),blocked_by:null,
              blocked_by_ids:[],unresolved_blocker_ids:[],
              reason:((.current_state.detail // .current_state.state) | trunc(120)),source:"child-state"} ]) as $holds_all
    | ($backlog.present == true
       and ($unstructured_current | length) == 0
       and ($unknown_children | length) == 0
       and ($orphan_in_flight | length) == 0
       and ($unowned_children | length) == 0
       and ($terminal_in_flight | length) == 0) as $valid
    | (if ($strict_invalidities | length) > 0 then $strict_invalidities[0].reason
       elif ($unknown_children | length) > 0 then
         "child current state unavailable: " + ($unknown_children | map(.id) | join(", "))
       else null end) as $reason
    | (if ($strict_invalidities | length) > 0 then $strict_invalidities[0] | del(.reason)
       elif ($unknown_children | length) > 0 then {kind:"child_current_unavailable",ids:($unknown_children | map(.id))}
       else {kind:null,ids:[]} end) as $invalidity
    | (if $valid | not then "unknown"
       elif any($decisions_all[]; .verb == "needs-decision" or .verb == "captain-hold") then "captain_decision"
       elif ($active_all | length) > 0 then "active_child_work"
       elif ($holds_all | length) > 0 then "externally_held"
       else "no_active_work" end) as $state
    | {
        schema:"fm-secondmate-home-summary.v1",
        generated:$generated,
        home:$home,
        valid:$valid,
        reason:$reason,
        invalidity:$invalidity,
        state:$state,
        active_children:$active_all[:$child_n],
        decisions_open:$decisions_all[:$decisions_n],
        holds:$holds_all[:$queued_n],
        queued:([$queued_all[] | {id:(.id | trunc(120)),title:(.title | trunc(120)),
          blocked_by:((.blocked_by // null) | if . == null then null else trunc(120) end),
          blocked_by_ids:((.blocked_by_ids // []) | map(trunc(120))),
          unresolved_blocker_ids:((.unresolved_blocker_ids // []) | map(trunc(120))),
          blocked_reason:((.blocked_reason // null) | if . == null then null else trunc(160) end),
          hold_reason:((.hold_reason // null) | if . == null then null else trunc(160) end),
          hold_kind:((.hold_kind // null) | if . == null then null else trunc(40) end),
          captain_actionable:(.captain_actionable // false),
          repo:((.repo // null) | if . == null then null else trunc(120) end),
          kind:((.kind // null) | if . == null then null else trunc(40) end)}][:$queued_n]),
        landed:(if $landed_n == 0 then $landed_all else $landed_all[:$landed_n] end),
        endpoints:([$tasks[] | {id,state:.current_state.state,source:.current_state.source,
          endpoint:(.endpoint + {target:((.endpoint.target // null) | if . == null then null else trunc(240) end)})}][:$child_n]),
        counts:{
          active_children:($active_all | length),
          decisions_open:($decisions_all | length),
          holds:($holds_all | length),
          queued:($queued_all | length),
          landed:($landed_all | length),
          endpoints:($tasks | length)
        },
        omitted:[
          (if ($active_all | length) > $child_n then {surface:"active_children",count:(($active_all | length) - $child_n)} else empty end),
          (if ($decisions_all | length) > $decisions_n then {surface:"decisions_open",count:(($decisions_all | length) - $decisions_n)} else empty end),
          (if ($queued_all | length) > $queued_n then {surface:"queued",count:(($queued_all | length) - $queued_n)} else empty end),
          (if ($tasks | length) > $child_n then {surface:"endpoints",count:(($tasks | length) - $child_n)} else empty end),
          (if $landed_n > 0 and ($landed_all | length) > $landed_n then {surface:"landed",count:(($landed_all | length) - $landed_n)} else empty end)
        ]
      }'
}

# Current registered-secondmate aggregation.
# The validated home summary is canonical.
# Parent status and bounded terminal capture remain untrusted supplemental evidence
# with explicit provenance, and can only produce a contradiction or unknown fallback.
FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME=${FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME:-10}
case "$FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME" in ''|*[!0-9]*) FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME=10 ;; esac

run_timed() {  # <seconds> <command...>
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$seconds" "$@"
  else
    return 124
  fi
}

# GNU stat treats -f as a filesystem-report command, so a BSD-first fallback can
# pollute arithmetic input before failing. Select the platform syntax once.
if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
  SNAPSHOT_STAT_STYLE=bsd
  file_mtime_epoch() { stat -f '%m' "$1" 2>/dev/null || true; }
  file_mode_octal() { stat -f '%Lp' "$1" 2>/dev/null || true; }
else
  SNAPSHOT_STAT_STYLE=gnu
  file_mtime_epoch() { stat -c '%Y' "$1" 2>/dev/null || true; }
  file_mode_octal() { stat -c '%a' "$1" 2>/dev/null || true; }
fi

registry_secondmates_json() {
  local reg="$DATA/secondmates.md" out rc reason mode script parse_filter output_filter
  if [ ! -f "$reg" ]; then
    jq -n --arg path "$reg" --arg observed "$SNAPSHOT_NOW" \
      '{present:false,available:true,complete:true,reason:null,provenance:"registered-table",path:$path,freshness:{status:"fresh",observed_at:$observed},records:[],input_truncated:false,records_truncated:false,reasons:[],lines_in_window:0,records_in_window:0}'
    return 0
  fi
  mode=$(file_mode_octal "$reg")
  if [ -z "$mode" ] || [ $((8#$mode & 0444)) -eq 0 ]; then
    jq -n --arg path "$reg" --arg observed "$SNAPSHOT_NOW" \
      --arg reason "registered secondmate table is unreadable" \
      '{present:true,available:false,complete:false,reason:$reason,provenance:"registered-table",path:$path,freshness:{status:"unavailable",observed_at:$observed},records:[],input_truncated:false,records_truncated:false,reasons:[$reason],lines_in_window:0,records_in_window:0}'
    return 0
  fi
  script=$(cat <<'BASH'
    f=$1
    max_lines=$2
    max_bytes=$3
    max_records=$4
    path=$5
    observed=$6
    parse_filter=$7
    output_filter=$8
    content=$(LC_ALL=C head -c "$((max_bytes + 1))" "$f" || exit 3; printf "\036") || exit 3
    content=${content%$'\036'}
    bytes=$(printf "%s" "$content" | LC_ALL=C wc -c | tr -d " ")
    byte_truncated=false
    if [ "$bytes" -gt "$max_bytes" ]; then
      byte_truncated=true
      content=$(printf "%s" "$content" | LC_ALL=C head -c "$max_bytes")
      complete=${content%$'\n'*}
      if [ "$complete" != "$content" ]; then
        content=$complete
      else
        content=
      fi
    fi
    if [ -n "$content" ]; then
      lines=$(printf "%s\n" "$content" | awk "END {print NR}")
    else
      lines=0
    fi
    line_truncated=false
    if [ "$lines" -gt "$max_lines" ]; then line_truncated=true; fi
    window=$(printf "%s\n" "$content" | LC_ALL=C head -n "$max_lines") || exit 3
    if [ -n "$window" ]; then
      lines_in_window=$(printf "%s\n" "$window" | awk "END {print NR}")
    else
      lines_in_window=0
    fi
    records=$(printf "%s\n" "$window" | jq -Rn "$parse_filter") || exit 3
    records_in_window=$(printf "%s" "$records" | jq "length") || exit 3
    records_truncated=false
    if [ "$records_in_window" -gt "$max_records" ]; then records_truncated=true; fi
    printf "%s" "$records" | jq \
      --arg path "$path" --arg observed "$observed" \
      --argjson byte_truncated "$byte_truncated" \
      --argjson line_truncated "$line_truncated" \
      --argjson records_truncated "$records_truncated" \
      --argjson lines_in_window "$lines_in_window" \
      --argjson records_in_window "$records_in_window" \
      --argjson max_records "$max_records" "$output_filter"
BASH
  )
  parse_filter=$(cat <<'JQ'
      [ inputs
        | select(startswith("- "))
        | (capture("^- (?<id>[^[:space:]]+)")?) as $id
        | select($id != null)
        | (capture("\\(home:[[:space:]]*(?<home>[^;)]*);")?) as $home
        | {id:$id.id,home:($home.home // null),registered:true,
           registry_error:(if $home == null or ($home.home | length) == 0 then "registry entry has no home" else null end)} ]
      | group_by(.id)
      | map(if length > 1 then .[0] + {registry_error:"duplicate secondmate id in registry"} else .[0] end)
JQ
  )
  output_filter=$(cat <<'JQ'
      {present:true,available:true,reason:null,provenance:"registered-table",path:$path,
       freshness:{status:"fresh",observed_at:$observed},
       records:(if length > $max_records then .[:$max_records] else . end),
       input_truncated:($byte_truncated or $line_truncated),records_truncated:$records_truncated,
       complete:(($byte_truncated or $line_truncated or $records_truncated) | not),
       reasons:[
         (if $byte_truncated then "byte_limit" else empty end),
         (if $line_truncated then "line_limit" else empty end),
         (if $records_truncated then "record_limit" else empty end)
       ],lines_in_window:$lines_in_window,records_in_window:$records_in_window}
JQ
  )
  out=$(run_timed "$FM_SNAPSHOT_REGISTRY_TIMEOUT" bash -c "$script" \
    fm-secondmate-registry "$reg" "$FM_SNAPSHOT_REGISTRY_LINES" \
    "$FM_SNAPSHOT_REGISTRY_BYTES" "$FM_SNAPSHOT_REGISTRY_RECORDS" "$reg" "$SNAPSHOT_NOW" \
    "$parse_filter" "$output_filter" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | jq -e '
    .available == true and (.records | type) == "array"
  ' >/dev/null 2>&1; then
    printf '%s' "$out"
    return 0
  fi
  [ "$rc" -eq 124 ] && reason="registered secondmate table read timed out" \
    || reason="registered secondmate table is unreadable"
  jq -n --arg path "$reg" --arg observed "$SNAPSHOT_NOW" --arg reason "$reason" \
    '{present:true,available:false,complete:false,reason:$reason,provenance:"registered-table",path:$path,freshness:{status:"unavailable",observed_at:$observed},records:[],input_truncated:false,records_truncated:false,reasons:[$reason],lines_in_window:0,records_in_window:0}'
}

bounded_parent_activities_json() {  # <status-file>
  local f=$1 out rc reason script
  if [ ! -f "$f" ]; then
    jq -n '{records:[],available:true,input_truncated:false,retained_truncated:false,reasons:[],lines_in_window:0,records_in_window:0}'
    return 0
  fi
  script=$(cat <<'BASH'
    classify=$1
    f=$2
    max_lines=$3
    max_bytes=$4
    max_records=$5
    stat_style=$6
    . "$classify"
    if [ "$stat_style" = bsd ]; then
      size=$(stat -f "%z" "$f" 2>/dev/null) || exit 3
    else
      size=$(stat -c "%s" "$f" 2>/dev/null) || exit 3
    fi
    content=$(LC_ALL=C tail -c "$max_bytes" "$f") || exit 3
    byte_truncated=false
    if [ "$size" -gt "$max_bytes" ]; then
      byte_truncated=true
      complete=${content#*$'\n'}
      if [ "$complete" != "$content" ]; then
        content=$complete
      else
        content=
      fi
    fi
    if [ -n "$content" ]; then
      lines_in_chunk=$(printf "%s\n" "$content" | awk "END {print NR}")
    else
      lines_in_chunk=0
    fi
    line_truncated=false
    if [ "$lines_in_chunk" -gt "$max_lines" ]; then line_truncated=true; fi
    window=$(printf "%s\n" "$content" | LC_ALL=C tail -n "$max_lines") || exit 3
    if [ -n "$window" ]; then
      lines_in_window=$(printf "%s\n" "$window" | awk "END {print NR}")
    else
      lines_in_window=0
    fi
    records=$(printf "%s\n" "$window" | status_open_activities - \
      | jq -R -s '[splits("\n") | select(length > 0)
          | (capture("^(?<key>[^\t]*)\t(?<verb>[^\t]*)\t(?<summary>.*)$")?)
          | select(. != null)]') || exit 3
    records_in_window=$(printf "%s" "$records" | jq "length") || exit 3
    retained_truncated=false
    if [ "$records_in_window" -gt "$max_records" ]; then retained_truncated=true; fi
    printf "%s" "$records" | jq \
      --argjson byte_truncated "$byte_truncated" \
      --argjson line_truncated "$line_truncated" \
      --argjson retained_truncated "$retained_truncated" \
      --argjson lines_in_window "$lines_in_window" \
      --argjson records_in_window "$records_in_window" \
      --argjson max_records "$max_records" '
        {records:(if length > $max_records then .[-$max_records:] else . end),
         available:true,
         input_truncated:($byte_truncated or $line_truncated),
         retained_truncated:$retained_truncated,
         reasons:[
           (if $byte_truncated then "byte_limit" else empty end),
           (if $line_truncated then "line_limit" else empty end),
           (if $retained_truncated then "activity_limit" else empty end)
         ],
         lines_in_window:$lines_in_window,
         records_in_window:$records_in_window}'
BASH
  )
  out=$(run_timed "$FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT" bash -c "$script" \
    fm-parent-activities "$SCRIPT_DIR/fm-classify-lib.sh" "$f" \
    "$FM_SNAPSHOT_PARENT_ACTIVITY_LINES" "$FM_SNAPSHOT_PARENT_ACTIVITY_BYTES" \
    "$FM_SNAPSHOT_PARENT_ACTIVITIES" "$SNAPSHOT_STAT_STYLE" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | jq -e '
    (.records | type) == "array" and (.available | type) == "boolean"
  ' >/dev/null 2>&1; then
    printf '%s' "$out"
    return 0
  fi
  [ "$rc" -eq 124 ] && reason="timeout" || reason="read_failed"
  jq -n --arg reason "$reason" \
    '{records:[],available:false,input_truncated:false,retained_truncated:false,reasons:[$reason],lines_in_window:0,records_in_window:0}'
}

terminal_evidence_json() {  # <parent-task-json> <event-note> <evidence-contradicts>
  local task=$1 note=$2 evidence_contradicts=$3 backend target exists expected out rc clean bytes lines seen=false contradiction=false reason=''
  backend=$(printf '%s' "$task" | jq -r '.backend // ""')
  target=$(printf '%s' "$task" | jq -r '.endpoint.target // ""')
  exists=$(printf '%s' "$task" | jq -r '.endpoint.exists // "unknown"')
  expected=$(printf '%s' "$task" | jq -r '"fm-" + (.id // "")')
  if [ -z "$target" ] || [ "$exists" = false ]; then
    [ "$exists" = false ] && reason="recorded endpoint is absent" || reason="no recorded endpoint"
    jq -n --arg observed "$SNAPSHOT_NOW" --arg reason "$reason" \
      '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"unknown",reason:$reason,lines:0,bytes:0,event_note_seen:false,contradiction:false}'
    return 0
  fi
  # shellcheck disable=SC2016 # Positional parameters expand inside the child bash, not here.
  out=$(run_timed "$FM_SNAPSHOT_TERMINAL_TIMEOUT" bash -c \
    '. "$1"; fm_backend_capture "$2" "$3" "$4" "$5" | LC_ALL=C head -c "$6"; rc=${PIPESTATUS[0]}; [ "$rc" -eq 141 ] && rc=0; exit "$rc"' \
    fm-terminal-capture "$SCRIPT_DIR/fm-backend.sh" "$backend" "$target" "$FM_SNAPSHOT_TERMINAL_LINES" "$expected" "$FM_SNAPSHOT_TERMINAL_BYTES" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -eq 124 ] && reason="terminal capture timed out" || reason="terminal capture unavailable"
    jq -n --arg observed "$SNAPSHOT_NOW" --arg reason "$reason" \
      '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"unknown",reason:$reason,lines:0,bytes:0,event_note_seen:false,contradiction:false}'
    return 0
  fi
  clean=$(printf '%s' "$out" | tail -n "$FM_SNAPSHOT_TERMINAL_LINES" | LC_ALL=C head -c "$FM_SNAPSHOT_TERMINAL_BYTES")
  if command -v perl >/dev/null 2>&1; then
    clean=$(printf '%s' "$clean" | perl -pe 's/\e\[[0-?]*[ -\/]*[@-~]//g; s/[^\x09\x0A\x0D\x20-\x7E]//g')
  else
    clean=$(printf '%s' "$clean" | LC_ALL=C tr -cd '\11\12\15\40-\176')
  fi
  bytes=$(printf '%s' "$clean" | LC_ALL=C wc -c | tr -d ' ')
  if [ -n "$clean" ]; then
    lines=$(printf '%s\n' "$clean" | wc -l | tr -d ' ')
  else
    lines=0
  fi
  if [ -n "$note" ]; then
    case "$clean" in *"$note"*) seen=true ;; esac
  fi
  if [ "$seen" = true ] && [ "$evidence_contradicts" = true ]; then contradiction=true; fi
  jq -n \
    --arg observed "$SNAPSHOT_NOW" \
    --argjson lines "$lines" \
    --argjson bytes "$bytes" \
    --argjson seen "$seen" \
    --argjson contradiction "$contradiction" \
    '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:true,observed_at:$observed,freshness:"fresh",reason:null,lines:$lines,bytes:$bytes,event_note_seen:$seen,contradiction:$contradiction}'
}

parent_evidence_reconciliation_json() {  # <summary-json> <activities-json> <decisions-json>
  jq -n --argjson summary "$1" --argjson activities "$2" --argjson decisions "$3" '
    def keyed: . != null and . != "" and . != "default";
    def result($e; $matches; $complete; $surface):
      $e + {
        verdict:(if ($e.key | keyed | not) then "inconclusive"
                 elif ($matches | length) > 0 then "corroborates"
                 elif $complete then "contradicts"
                 else "inconclusive" end),
        compared_to:$surface,
        matched:(if ($e.key | keyed) then ($matches[0] // null) else null end)
      };
    ([ $activities[] as $e
       | if $e.verb == "working" then
           ([ $summary.active_children[]
              | select(if ($e.key | keyed) then .id == $e.key else true end)
              | {surface:"active_children",id,key:null,verb:"working"}]) as $matches
           | result($e; $matches;
               $summary.counts.active_children == ($summary.active_children | length);
               "active_children")
         elif $e.verb == "paused" then
           ([ $summary.holds[]
              | select(if ($e.key | keyed) then .id == $e.key or .blocked_by == $e.key else true end)
              | {surface:"holds",id,key:(.blocked_by // null),verb:"paused"}]) as $matches
           | result($e; $matches;
               $summary.counts.holds == ($summary.holds | length);
               "holds")
         else
           $e + {verdict:"inconclusive",compared_to:null,matched:null}
         end ]) as $activity_results
    | ([ $decisions[] as $e
         | if $e.verb == "needs-decision" then
             ([ $summary.decisions_open[]
                | select(.verb == "needs-decision")
                | select(if ($e.key | keyed) then .key == $e.key else true end)
                | {surface:"decisions_open",id,key,verb}]) as $matches
             | result($e; $matches;
                 $summary.counts.decisions_open == ($summary.decisions_open | length);
                 "decisions_open")
           elif $e.verb == "blocked" then
             ([ $summary.decisions_open[]
                | select(.verb == "blocked")
                | select(if ($e.key | keyed) then .key == $e.key or .id == $e.key else true end)
                | {surface:"decisions_open",id,key,verb}]
              + [ $summary.holds[]
                  | select(if ($e.key | keyed) then .id == $e.key or .blocked_by == $e.key else true end)
                  | {surface:"holds",id,key:(.blocked_by // null),verb:"blocked"}]) as $matches
             | result($e; $matches;
                 ($summary.counts.decisions_open == ($summary.decisions_open | length)
                  and $summary.counts.holds == ($summary.holds | length));
                 "decisions_open_or_holds")
           else
             $e + {verdict:"inconclusive",compared_to:null,matched:null}
           end ]) as $decision_results
    | {provenance:"parent-status-keyed-fold",trust:"untrusted-supplement",
       activities:$activity_results,decisions:$decision_results,
       contradiction:any(($activity_results + $decision_results)[]; .verdict == "contradicts"),
       inconclusive:any(($activity_results + $decision_results)[]; .verdict == "inconclusive")}'
}

secondmate_current_json() {  # <parent-tasks-json>
  local tasks=$1 registry union rows total_registered total shown truncated
  local row id home registered registry_error task status_file event_raw event_note event_epoch event_age
  local activity_scan activities decisions reconciliation provenance freshness reason summary summary_rc summary_bytes summary_valid summary_reason summary_invalidity state current_reason terminal terminal_contradiction contradiction
  local records='[]' seen_homes=''
  registry=$(registry_secondmates_json) || return 1
  # $tasks can exceed MAX_ARG_STRLEN, so feed both blobs on stdin via `input`
  # rather than as --argjson argv strings.
  union=$(printf '%s\n%s\n' "$registry" "$tasks" | jq -n '
    (input) as $registry | (input) as $tasks
    | ($registry.records // []) as $registered
    | (($registered | map(.id)) // []) as $registered_ids
    | ([ $registered[] as $r
         | $r + {parent_task:([$tasks[] | select(.id == $r.id)][0] // null)} ]
       + [ $tasks[] | select(.kind == "secondmate") as $t
           | select(($registered_ids | index($t.id)) == null)
           | {id:$t.id,home:($t.paths.home.path // null),
              registered:(if $registry.complete == true then false else null end),
              registry_error:(if $registry.complete == true
                              then "secondmate metadata is not registered"
                              else "secondmate registration is unknown because the registry read is incomplete or unavailable" end),
              parent_task:$t} ])
    | sort_by(.id)
    | {registry:$registry,records:.}') || return 1
  total_registered=$(printf '%s' "$union" | jq '[.records[] | select(.registered)] | length')
  total=$(printf '%s' "$union" | jq '.records | length')
  rows=$(printf '%s' "$union" | jq -c --argjson cap "$FM_SNAPSHOT_SECONDMATES" '(if $cap == 0 then .records else .records[:$cap] end)[]')
  shown=$(printf '%s\n' "$rows" | grep -c . || true)
  truncated=$((total - shown))

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id=$(printf '%s' "$row" | jq -r '.id')
    home=$(printf '%s' "$row" | jq -r '.home // ""')
    registered=$(printf '%s' "$row" | jq -r '.registered')
    registry_error=$(printf '%s' "$row" | jq -r '.registry_error // ""')
    task=$(printf '%s' "$row" | jq -c '.parent_task // {}')
    status_file=$(printf '%s' "$task" | jq -r '.paths.status_log.path // ""')
    event_raw=$(printf '%s' "$task" | jq -r '.paths.status_log.last_event.raw // ""')
    event_note=$(printf '%s' "$task" | jq -r '.paths.status_log.last_event.note // ""')
    activity_scan=$(bounded_parent_activities_json "$status_file")
    activities=$(printf '%s' "$activity_scan" | jq -c '.records')
    decisions=$(printf '%s' "$task" | jq -c '.hints.open_decisions // []')
    event_epoch=$(file_mtime_epoch "$status_file")
    event_age=null
    if [ -n "$event_epoch" ]; then
      event_age=$((SNAPSHOT_EPOCH - event_epoch))
      [ "$event_age" -lt 0 ] && event_age=0
    fi

    reason=$registry_error
    summary='{}'
    summary_valid=false
    if [ -z "$reason" ] && [ -z "$home" ]; then reason="no recorded secondmate home"; fi
    if [ -z "$reason" ]; then
      case "$home" in
        /*) : ;;
        *) reason="invalid home: registered path is not absolute" ;;
      esac
    fi
    if [ -z "$reason" ]; then
      if ! validate_secondmate_home "$id" "$home" 2>/dev/null; then
        reason="invalid home: $VALIDATION_ERROR"
      else
        home=$VALIDATED_HOME
        case " $seen_homes " in
          *" $home "*) reason="invalid home: duplicate resolved home route" ;;
          *) seen_homes="$seen_homes $home" ;;
        esac
      fi
    fi
    if [ -z "$reason" ]; then
      summary=$(run_timed "$FM_SNAPSHOT_SECONDMATE_TIMEOUT" env \
        FM_ROOT_OVERRIDE="$FM_ROOT" \
        FM_HOME="$home" \
        FM_STATE_OVERRIDE="$home/state" \
        FM_DATA_OVERRIDE="$home/data" \
        FM_CONFIG_OVERRIDE="$home/config" \
        FM_PROJECTS_OVERRIDE="$home/projects" \
        FM_SNAPSHOT_NOW="$SNAPSHOT_NOW" \
        FM_SNAPSHOT_NOW_EPOCH="$SNAPSHOT_EPOCH" \
        FM_SNAPSHOT_SECONDMATE_CHILDREN="$FM_SNAPSHOT_SECONDMATE_CHILDREN" \
        FM_SNAPSHOT_SECONDMATE_QUEUED="$FM_SNAPSHOT_SECONDMATE_QUEUED" \
        FM_SNAPSHOT_SECONDMATE_DECISIONS="$FM_SNAPSHOT_SECONDMATE_DECISIONS" \
        FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME="$FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME" \
        "$SCRIPT_DIR/fm-fleet-snapshot.sh" --secondmate-home-summary 2>/dev/null)
      summary_rc=$?
      if [ "$summary_rc" -ne 0 ]; then
        [ "$summary_rc" -eq 124 ] && reason="structured home snapshot timed out" || reason="structured home snapshot failed"
      else
        summary_bytes=$(printf '%s' "$summary" | LC_ALL=C wc -c | tr -d ' ')
        if [ "$summary_bytes" -gt "$FM_SNAPSHOT_SECONDMATE_MAX_BYTES" ]; then
          reason="structured home snapshot exceeded byte limit"
        elif ! printf '%s' "$summary" | jq -e --arg home "$home" --arg generated "$SNAPSHOT_NOW" '
          .schema == "fm-secondmate-home-summary.v1" and .home == $home and .generated == $generated
          and (.valid | type) == "boolean" and (.state | type) == "string"
          and (.invalidity | type) == "object" and (.invalidity.ids | type) == "array"
          and (.active_children | type) == "array" and (.decisions_open | type) == "array"
          and (.holds | type) == "array" and (.queued | type) == "array"
          and (.landed | type) == "array" and (.endpoints | type) == "array"
          and (.counts | type) == "object" and (.omitted | type) == "array"
        ' >/dev/null 2>&1; then
          reason="structured home snapshot was malformed or stale"
        else
          summary_valid=$(printf '%s' "$summary" | jq -r '.valid')
          if [ "$summary_valid" != true ]; then
            summary_reason=$(printf '%s' "$summary" | jq -r '.reason // "unknown reason"')
            summary_invalidity=$(printf '%s' "$summary" | jq -r '.invalidity.kind // "unknown"')
            if [ "$summary_invalidity" != child_current_unavailable ]; then
              reason="structured home state invalid: $summary_reason"
            fi
          fi
        fi
      fi
    fi

    if [ -z "$reason" ]; then
      state=$(printf '%s' "$summary" | jq -r '.state')
      current_reason=
      if [ "$summary_valid" != true ]; then
        current_reason="structured home state invalid: $(printf '%s' "$summary" | jq -r '.reason // "unknown reason"')"
      fi
      reconciliation=$(parent_evidence_reconciliation_json "$summary" "$activities" "$decisions")
      contradiction=$(printf '%s' "$reconciliation" | jq -r '.contradiction')
      terminal_contradiction=$(printf '%s' "$reconciliation" | jq -r --arg note "$event_note" '
        any(.activities[]; .verdict == "contradicts" and .summary == $note)')
      if [ "$terminal_contradiction" = true ]; then
        terminal=$(terminal_evidence_json "$task" "$event_note" true)
      else
        terminal=$(jq -n --arg observed "$SNAPSHOT_NOW" \
          '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"not-collected",reason:"no useful contradiction check",lines:0,bytes:0,event_note_seen:false,contradiction:false}')
      fi
      if printf '%s' "$terminal" | jq -e '.contradiction == true' >/dev/null; then contradiction=true; fi
      record=$(jq -n \
        --arg id "$id" --arg home "$home" --arg state "$state" --arg current_reason "$current_reason" --arg observed "$SNAPSHOT_NOW" \
        --argjson registered "$registered" --argjson summary "$summary" --argjson summary_valid "$summary_valid" --argjson decisions "$decisions" \
        --argjson activities "$activities" --argjson activity_scan "$activity_scan" \
        --argjson reconciliation "$reconciliation" --argjson terminal "$terminal" --argjson contradiction "$contradiction" \
        --arg event_raw "$event_raw" --arg event_note "$event_note" --argjson event_age "$event_age" '
        {id:$id,home:$home,registered:$registered,
         current:{state:$state,reason:($current_reason | if . == "" then null else . end)},invalidity:$summary.invalidity,
         provenance:{selected:"structured-home",structured_home:$home,summary_valid:$summary_valid,
           trust:(if $summary_valid then "complete" else "partial-structured" end),parent_event_role:"historical-only"},
         freshness:{status:"fresh",observed_at:$observed,age_seconds:0},
         active_children:$summary.active_children,
         decisions_open:$summary.decisions_open,holds:$summary.holds,queued:$summary.queued,
         landed:$summary.landed,endpoints:$summary.endpoints,counts:$summary.counts,omitted:$summary.omitted,
         parent_event:{raw:$event_raw,note:$event_note,age_seconds:$event_age,open_activities:$activities,open_decisions:$decisions,activity_scan:$activity_scan,reconciliation:$reconciliation},
         terminal_evidence:$terminal,contradiction:$contradiction}')
    else
      if [ -n "$event_raw" ]; then
        provenance='parent-event-fallback'
        freshness=historical-event
      else
        provenance=unknown
        freshness=unknown
      fi
      if [ -n "$event_raw" ]; then
        terminal=$(terminal_evidence_json "$task" "$event_note" false)
      else
        terminal=$(jq -n --arg observed "$SNAPSHOT_NOW" \
          '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"not-collected",reason:"no parent event to compare",lines:0,bytes:0,event_note_seen:false,contradiction:false}')
      fi
      record=$(jq -n \
        --arg id "$id" --arg home "$home" --arg reason "$reason" --arg observed "$SNAPSHOT_NOW" \
        --arg provenance "$provenance" --arg freshness "$freshness" --arg event_raw "$event_raw" --arg event_note "$event_note" \
        --argjson registered "$registered" --argjson event_age "$event_age" --argjson activities "$activities" --argjson activity_scan "$activity_scan" \
        --argjson decisions "$decisions" --argjson terminal "$terminal" '
        {id:$id,home:($home | if . == "" then null else . end),registered:$registered,
         current:{state:"unknown",reason:$reason},invalidity:null,
         provenance:{selected:$provenance,structured_home:($home | if . == "" then null else . end),parent_event_role:"fallback-only-not-current"},
         freshness:{status:$freshness,observed_at:$observed,age_seconds:$event_age},
         active_children:[],decisions_open:[],holds:[],queued:[],landed:[],endpoints:[],counts:{active_children:0,decisions_open:0,holds:0,queued:0,landed:0,endpoints:0},omitted:[],
         parent_event:{raw:$event_raw,note:$event_note,age_seconds:$event_age,open_activities:$activities,open_decisions:$decisions,activity_scan:$activity_scan},
         terminal_evidence:$terminal,contradiction:false}')
    fi
    records=$(jq -n --argjson records "$records" --argjson record "$record" '$records + [$record]')
  done <<EOF
$rows
EOF
  jq -n \
    --argjson registry "$(printf '%s' "$union" | jq '.registry')" \
    --argjson records "$records" \
    --argjson total_registered "$total_registered" \
    --argjson total "$total" \
    --argjson shown "$shown" \
    --argjson truncated "$truncated" \
    '{registry:$registry,records:$records,total_registered:$total_registered,total:$total,shown:$shown,truncated:$truncated}'
}

secondmate_landed_from_current_json() {  # <secondmate-current-json>
  # The current-json blob can grow past ARG_MAX once a secondmate home has many
  # landed records, so feed it on stdin rather than as an --argjson argv value.
  printf '%s' "$1" | jq '. as $current |
    {records:[ $current.records[]
      | select(.provenance.selected == "structured-home") as $mate
      | $mate.landed[]
      | . + {home:$mate.home,home_id:$mate.id}],
     truncated:[ $current.records[]
       | select(.provenance.selected == "structured-home" and (.counts.landed > (.landed | length)))
       | .home],
     unreadable:[ $current.records[]
       | select(.current.state == "unknown" and .provenance.selected != "structured-home")
       | .home // ("<" + .id + ": unavailable>")],
     partial:[ $current.records[]
       | select(.current.state == "unknown" and .provenance.selected == "structured-home")
       | .home // ("<" + .id + ": partial>")]}
    | .records |= sort_by([(.completion.date // ""), .id]) | .records |= reverse'
}

scout_report_lines() {
  local report id
  if [ ! -d "$DATA" ]; then
    jq -n '[]'
    return 0
  fi
  LC_ALL=C find "$DATA" -mindepth 2 -maxdepth 2 -type f -name report.md -print \
    | sort \
    | while IFS= read -r report; do
      id=$(basename "$(dirname "$report")")
      jq -n --arg id "$id" --arg path "$report" '{id:$id,path:$path}'
    done \
    | jq -s 'sort_by(.id)'
}

full_assembly() {  # <backlog> <tasks> <main-inventory> <scout-reports> <secondmate-current> <secondmate-landed>
  printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" | jq -n \
    --arg generated "$SNAPSHOT_NOW" \
    --arg fm_home "$FM_HOME" \
    --arg fm_root "$FM_ROOT" \
    --arg state "$STATE" \
    --arg data "$DATA" \
    --arg config "$CONFIG" \
    --arg projects "$PROJECTS" \
    '(input) as $backlog | (input) as $tasks
     | (input) as $main_inventory | (input) as $scout_reports
     | (input) as $secondmate_current | (input) as $secondmate_landed
     | def backlog_by_id($id): ($backlog.records[]? | select(.structured == true and .id == $id) | .) // null;
     def task_by_id($id): ($tasks[]? | select(.id == $id) | .) // null;
     def report_kind($id): (task_by_id($id).kind // backlog_by_id($id).kind // "scout");
     {
       schema:"fm-fleet-snapshot.v1",
       generated:$generated,
       fm_home:$fm_home,
       roots:{fm_root:$fm_root,state:$state,data:$data,config:$config,projects:$projects},
       backlog:$backlog,
       tasks:($tasks | map(. + {backlog:backlog_by_id(.id)})),
       main_inventory:($main_inventory | .orphan_in_flight_total = (.orphan_in_flight | length)),
       scout_reports:($scout_reports | map(. + {kind:report_kind(.id)})),
       secondmate_current:$secondmate_current,
       secondmate_landed:$secondmate_landed,
       secondmate_guidance:{
         note:"For kind=secondmate, bearings selects validated structured state from that registered home; parent events and bounded terminal evidence are fallback-only supplements and never current-state authority."
       }
     }'
}

# Compact default assembly: identity + state + title (capped 120 with an inline
# full-source pointer) + decision/PR metadata + aggregate counts, with fat fields
# restored only when --fields names them. Rows trim in a fixed priority order
# (scratch pointers first, then history, then backlog, then secondmate records,
# then live tasks) until the hard ceiling holds; every cut is disclosed in
# projection.truncated[] with its reveal command. A compact projection NEVER
# fails to silence: the header, roots, main_inventory, summary counts, and the
# projection block always survive.
compact_assembly() {  # <fields> <ceiling>
  local fields=$1 ceiling=$2 compact chars trim_target step
  compact=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$BACKLOG_JSON" "$TASKS_JSON" \
    "$MAIN_INVENTORY_JSON" "$SCOUT_REPORTS_JSON" \
    "$SECONDMATE_CURRENT_JSON" "$SECONDMATE_LANDED_JSON" | jq -c -n \
    --arg generated "$SNAPSHOT_NOW" \
    --arg fm_home "$FM_HOME" \
    --arg fm_root "$FM_ROOT" \
    --arg state "$STATE" \
    --arg data "$DATA" \
    --arg config "$CONFIG" \
    --arg projects "$PROJECTS" \
    --arg fields "$fields" \
    --argjson cap_backlog 60 \
    --argjson cap_reports 8 \
    --argjson cap_landed 15 \
    '
    def trunc_s($n): tostring | gsub("\\s+"; " ") | if (length > $n) then (.[:$n] + "…") else . end;
    def title_row($id; $path):
      if . == null then null else
      (tostring | gsub("\\s+"; " ")) as $t
      | if (($t | length) > 120) then
          $t[:120] + "… (full: " + (if $id != null then "tasks-axi show \($id)" else $path end) + ")"
        else $t end
      end;
    def dec_row($n; $source_path):
      if . == null then null else
        (tostring | gsub("\\s+"; " ") | if (length > $n) then (.[:$n] + "… (full: \($source_path))") else . end)
      end;
    def drop_empty: with_entries(select(.value != null and .value != "" and .value != []));
    (input) as $backlog | (input) as $tasks
    | (input) as $main_inventory | (input) as $scout_reports
    | (input) as $secondmate_current | (input) as $secondmate_landed
    | ($fields | split(",") | map(select(. != ""))) as $fl
    | ((($fl | index("body")) != null)) as $f_body
    | ((($fl | index("events")) != null)) as $f_events
    | ((($fl | index("actions")) != null)) as $f_actions
    | ((($fl | index("paths")) != null)) as $f_paths
    | ((($fl | index("secondmates")) != null)) as $f_secondmates
    | ((($fl | index("reports")) != null)) as $f_reports
    | def backlog_by_id($id): ($backlog.records[]? | select(.structured == true and .id == $id) | .) // null;
      def task_by_id($id): ($tasks[]? | select(.id == $id) | .) // null;
      def report_kind($id): (task_by_id($id).kind // backlog_by_id($id).kind // "scout");
    {
      schema:"fm-fleet-snapshot.v1",
      mode:"compact",
      generated:$generated,
      fm_home:$fm_home,
      roots:{fm_root:$fm_root,state:$state,data:$data,config:$config,projects:$projects},
      backlog:(if $f_body then $backlog
               else $backlog + {
                 records:([ $backlog.records[]
                            | select(.state == "in_flight" or .state == "queued" or .state == "done")
                            | (.id) as $rid
                            | . + {title:(if .structured then (.title | title_row($rid; $backlog.path))
                                          else (.raw | title_row(null; $backlog.path)) end),
                                   body_lines_count:(.body_lines | length),
                                   completion:(if (.completion.verb != null) then .completion else null end)}
                            | del(.raw, .body_lines, .body_excerpt)
                            | (if .state == "in_flight" then 0
                               elif .state == "queued" then 1
                               else 2 end) as $prio
                            | . + {_prio:$prio} ]
                          | sort_by(._prio, .order)
                          | .[:$cap_backlog] | map(del(._prio) | drop_empty)),
                 records_shown: ([([ $backlog.records[] | select(.state == "in_flight" or .state == "queued" or .state == "done")] | length), $cap_backlog] | min),
                 records_total: ($backlog.records | length),
                 records_truncated: (($backlog.records | length) > $cap_backlog)
               } end),
      tasks:([ $tasks[] as $t
               | {id:$t.id, kind:$t.kind, backend:$t.backend, project:$t.project,
                  telemetry:$t.telemetry,
                  paths:{meta:{present:$t.paths.meta.present},
                         status_log:{present:$t.paths.status_log.present},
                         worktree:{path:$t.paths.worktree.path, present:$t.paths.worktree.present},
                         home:{path:$t.paths.home.path, present:$t.paths.home.present},
                         report:{present:$t.paths.report.present}},
                  current_state:{state:$t.current_state.state,
                                 source:$t.current_state.source,
                                 detail:($t.current_state.detail | dec_row(200; $t.paths.status_log.path // ""))},
                  endpoint:{target:$t.endpoint.target, exists:$t.endpoint.exists, agent_alive:$t.endpoint.agent_alive},
                  pr:{url:($t.pr.url // null), source:$t.pr.source},
                  hints:{pending_decision:$t.hints.pending_decision,
                         blocked_event:$t.hints.blocked_event,
                         scout_report_present:$t.hints.scout_report_present,
                         open_decisions:[ ($t.hints.open_decisions // [])[]? | . + {summary:(.summary | dec_row(160; $t.paths.status_log.path // ""))} ]}}
               | if $f_events then
                   .paths.status_log = $t.paths.status_log
                   | .current_state = $t.current_state
                   | .hints.last_event_text = $t.hints.last_event_text
                 else . end
               | if $f_actions then .actions = $t.actions else . end
               | if $f_paths then .paths = $t.paths else . end
               | if $f_secondmates then . + {secondmate_projects:$t.secondmate_projects} else . end ]
               | map(. + {backlog:backlog_by_id(.id)})),
      main_inventory:($main_inventory | .orphan_in_flight_total = (.orphan_in_flight | length)),
      scout_reports:(if $f_reports
                     then ($scout_reports | map(. + {kind:report_kind(.id)}))
                     else ($scout_reports[:$cap_reports] | map(. + {kind:report_kind(.id)})) end),
      secondmate_current:(if $f_secondmates then $secondmate_current
                          else $secondmate_current + {
                            records:[ $secondmate_current.records[]
                                      | (.home // "") as $mhome
                                      | {id,home,registered,
                                         current:{state:.current.state,reason:.current.reason},
                                         invalidity,
                                         provenance:({selected:.provenance.selected,trust:.provenance.trust} | drop_empty),
                                         freshness:({status:.freshness.status} | drop_empty),
                                         active_children,
                                         decisions_open:[ (.decisions_open // [])[]? | . + {summary:(.summary | dec_row(160; "secondmate home " + $mhome))} ],
                                         endpoints,counts,omitted,contradiction}
                                      | drop_empty ] } end),
      secondmate_landed:(if $f_secondmates
                         then $secondmate_landed | .records_total = (.records | length) | .records_shown = (.records | length)
                         else $secondmate_landed
                           | .records = [.records[:$cap_landed][]? | . as $rec | $rec + {
                               title:($rec.title | title_row($rec.id; "secondmate backlog")),
                               id:($rec.id | trunc_s(120)),
                               home_id:($rec.home_id | trunc_s(120))} | drop_empty ]
                           | .records_total = (.["records_total"] // (($secondmate_landed.records | length)))
                           | .records_shown = (.records | length) end),
      secondmate_guidance:{
        note:"For kind=secondmate, bearings selects validated structured state from that registered home; parent events and bounded terminal evidence are fallback-only supplements and never current-state authority."
      },
      summary:{
        backlog_total:($backlog.records | length),
        backlog_in_flight:([ $backlog.records[] | select(.state == "in_flight")] | length),
        backlog_queued:([ $backlog.records[] | select(.state == "queued")] | length),
        backlog_done:([ $backlog.records[] | select(.state == "done")] | length),
        captain_actionable:([ $backlog.records[] | select(.captain_actionable == true)] | length),
        tasks_total:($tasks | length),
        tasks_working:([ $tasks[] | select(.current_state.state == "working")] | length),
        tasks_secondmates:([ $tasks[] | select(.kind == "secondmate")] | length),
        decisions_open:([ $tasks[] | .hints.open_decisions[]? ] | length),
        landed:(([ $backlog.records[] | select(.state == "done" and .structured and .kind != "captain")] | length) + ($secondmate_landed.records | length)),
        scout_reports_total:($scout_reports | length),
        secondmates_total:($secondmate_current.total)
      }
    }')
  chars=$(printf '%s' "$compact" | LC_ALL=C wc -c | tr -d ' ')
  # Reserve headroom for the projection wrap so the final output cannot exceed
  # the ceiling; rows trim in priority order (pointers, history, backlog,
  # secondmate records, live tasks) and every cut is disclosed at wrap time.
  # A surface restored via --fields is NEVER trimmed: the caller asked for it.
  trim_target=$((ceiling - 2048))
  # shellcheck disable=SC2016  # each step is a literal jq filter, not a shell expression
  if [ "$chars" -gt "$trim_target" ]; then
    for step in \
      '(if (($fields | split(",") | index("reports")) == null) then .scout_reports = .scout_reports[:5] else . end)' \
      '(if (($fields | split(",") | index("secondmates")) == null) then .secondmate_landed.records = .secondmate_landed.records[:8] else . end)' \
      '(if (($fields | split(",") | index("body")) == null) then .backlog.records = .backlog.records[:40] else . end)' \
      '(if (($fields | split(",") | index("body")) == null) then .main_inventory.orphan_in_flight = .main_inventory.orphan_in_flight[:20] else . end)' \
      '(if (($fields | split(",") | index("reports")) == null) then .scout_reports = .scout_reports[:2] else . end)' \
      '(if (($fields | split(",") | index("secondmates")) == null) then .secondmate_landed.records = .secondmate_landed.records[:4] else . end)' \
      '(if (($fields | split(",") | index("body")) == null) then .backlog.records = .backlog.records[:25] else . end)' \
      '(if (($fields | split(",") | index("secondmates")) == null) then .secondmate_current.records = .secondmate_current.records[:6] else . end)' \
      '(if (($fields | split(",") | index("reports")) == null) then .scout_reports = [] else . end)' \
      '(if (($fields | split(",") | index("body")) == null) then .backlog.records = .backlog.records[:15] else . end)' \
      '(if (($fields | split(",") | index("events")) == null and (($fields | split(",") | index("actions")) == null) and (($fields | split(",") | index("paths")) == null)) then .tasks = .tasks[:8] else . end)' \
      '(if (($fields | split(",") | index("secondmates")) == null) then .secondmate_current.records = .secondmate_current.records[:4] else . end)' \
      '(if (($fields | split(",") | index("body")) == null) then .backlog.records = .backlog.records[:8] else . end)' \
      '(if (($fields | split(",") | index("secondmates")) == null) then .secondmate_landed.records = [] else . end)' \
      '(if (($fields | split(",") | index("events")) == null and (($fields | split(",") | index("actions")) == null) and (($fields | split(",") | index("paths")) == null)) then .tasks = .tasks[:5] else . end)' \
      '(if (($fields | split(",") | index("secondmates")) == null) then .secondmate_current.records = .secondmate_current.records[:2] else . end)' \
      '(if (($fields | split(",") | index("events")) == null and (($fields | split(",") | index("actions")) == null) and (($fields | split(",") | index("paths")) == null)) then .tasks = .tasks[:3] else . end)' \
      '(if (($fields | split(",") | index("body")) == null) then .backlog.records = .backlog.records[:3] else . end)' \
    ; do
      compact=$(printf '%s' "$compact" | jq -c --arg fields "$fields" "$step")
      chars=$(printf '%s' "$compact" | LC_ALL=C wc -c | tr -d ' ')
      [ "$chars" -le "$trim_target" ] && break
    done
  fi
  compact=$(printf '%s' "$compact" | jq -c \
    --argjson ceiling "$ceiling" \
    --arg fields "$fields" \
    '
    def truncated($surface; $shown; $total; $reveal):
      if ($shown < $total) then [{surface:$surface,shown:$shown,total:$total,reveal:$reveal}] else [] end;
    . as $d
    | .backlog.records_shown = (.backlog.records | length)
    | .backlog.records_truncated = ((.backlog.records | length) < .backlog.records_total)
    | .secondmate_landed.records_shown = (.secondmate_landed.records | length)
    | .mode = "compact"
    | .projection = {
        mode:"compact",
        ceiling:$ceiling,
        chars:null,
        fields:($fields | split(",") | map(select(. != ""))),
        title_truncated_at:120,
        decision_summary_truncated_at:160,
        truncated:(
          truncated("backlog records"; (.backlog.records | length); .backlog.records_total; "fm-fleet-snapshot.sh --json --fields body") +
          truncated("task rows"; (.tasks | length); .summary.tasks_total; "fm-fleet-snapshot.sh --json --fields events,actions,paths") +
          truncated("scout report pointers"; (.scout_reports | length); .summary.scout_reports_total; "fm-fleet-snapshot.sh --json --fields reports") +
          truncated("secondmate records"; (.secondmate_current.records | length); .summary.secondmates_total; "fm-fleet-snapshot.sh --json --fields secondmates") +
          truncated("secondmate landed rows"; (.secondmate_landed.records | length); .secondmate_landed.records_total; "fm-fleet-snapshot.sh --json --fields secondmates") +
          truncated("main inventory orphan ids"; (.main_inventory.orphan_in_flight | length); .main_inventory.orphan_in_flight_total; "fm-fleet-snapshot.sh --json --full")
        ),
        full_hint:"fm-fleet-snapshot.sh --json --full",
        note:"Compact default projection: identity, state, title capped at 120 (inline full-source pointer), decision/PR metadata, and aggregate counts. Fat per-record text restores via --fields; the ceiling is enforced here, never silently."
      }')
  chars=$(printf '%s' "$compact" | LC_ALL=C wc -c | tr -d ' ')
  if [ "$chars" -gt "$ceiling" ] && [ -z "$fields" ]; then
    # Hard backstop: header, roots, main_inventory, summary counts, and the
    # projection block always survive; row arrays clear with full disclosure.
    compact=$(printf '%s' "$compact" | jq -c \
      '.backlog.records=[] | .tasks=[] | .scout_reports=[]
       | .secondmate_current.records=[] | .secondmate_landed.records=[]
       | .main_inventory.orphan_in_flight=[]
       | .projection.chars = null')
    compact=$(printf '%s' "$compact" | jq --argjson ceiling "$ceiling" --arg fields "$fields" '
      def truncated($surface; $shown; $total; $reveal):
        if ($shown < $total) then [{surface:$surface,shown:$shown,total:$total,reveal:$reveal}] else [] end;
      . as $d
      | .backlog.records_shown = 0
      | .backlog.records_truncated = ((.backlog.records | length) < .backlog.records_total)
      | .secondmate_landed.records_shown = 0
      | .mode = "compact"
      | .projection = {
          mode:"compact", ceiling:$ceiling, chars:null,
          fields:($fields | split(",") | map(select(. != ""))),
          title_truncated_at:120, decision_summary_truncated_at:160,
          truncated:(
            truncated("backlog records"; 0; .summary.backlog_total; "fm-fleet-snapshot.sh --json --fields body") +
            truncated("task rows"; 0; .summary.tasks_total; "fm-fleet-snapshot.sh --json --fields events,actions,paths") +
            truncated("scout report pointers"; 0; .summary.scout_reports_total; "fm-fleet-snapshot.sh --json --fields reports") +
            truncated("secondmate records"; 0; .summary.secondmates_total; "fm-fleet-snapshot.sh --json --fields secondmates") +
            truncated("secondmate landed rows"; 0; .summary.landed; "fm-fleet-snapshot.sh --json --fields secondmates") +
            truncated("main inventory orphan ids"; 0; .main_inventory.orphan_in_flight_total; "fm-fleet-snapshot.sh --json --full")
          ),
          full_hint:"fm-fleet-snapshot.sh --json --full",
          note:"Compact default projection: identity, state, title capped at 120 (inline full-source pointer), decision/PR metadata, and aggregate counts. This output hit the hard ceiling and row arrays cleared; the summary counts above are complete."
        }')
    chars=$(printf '%s' "$compact" | LC_ALL=C wc -c | tr -d ' ')
  fi
  compact=$(printf '%s' "$compact" | jq -c --argjson chars "$chars" --arg fields "$fields" '.projection.chars = $chars
  | if (.projection.chars > .projection.ceiling) and ($fields != "") then
      .projection.note = (.projection.note + " This call restored fields via --fields, so the ceiling does not bind the restored surfaces; chars " + (.projection.chars|tostring) + " exceed ceiling " + (.projection.ceiling|tostring) + ".")
    else . end')
  # The compact default prints as one JSON line: its whole contract is a size
  # bound. --full keeps the pretty historical shape.
  printf '%s\n' "$compact"
}

BACKLOG_JSON=$(backlog_json) || { echo "fm-fleet-snapshot: backlog read failed" >&2; exit 1; }
TASKS_JSON=$(task_json_lines) || { echo "fm-fleet-snapshot: task snapshot failed" >&2; exit 1; }

if [ "$OUTPUT_MODE" = secondmate-home-summary ]; then
  secondmate_home_summary_json "$BACKLOG_JSON" "$TASKS_JSON" \
    || { echo "fm-fleet-snapshot: secondmate home summary failed" >&2; exit 1; }
  exit 0
fi

SCOUT_REPORTS_JSON=$(scout_report_lines)
MAIN_INVENTORY_JSON=$(main_inventory_json "$BACKLOG_JSON" "$TASKS_JSON") \
  || { echo "fm-fleet-snapshot: main inventory summary failed" >&2; exit 1; }
SECONDMATE_CURRENT_JSON=$(secondmate_current_json "$TASKS_JSON") \
  || { echo "fm-fleet-snapshot: registered secondmate aggregation failed" >&2; exit 1; }
SECONDMATE_LANDED_JSON=$(secondmate_landed_from_current_json "$SECONDMATE_CURRENT_JSON") \
  || { echo "fm-fleet-snapshot: secondmate landed projection failed" >&2; exit 1; }

if [ "$SUMMARY" = 1 ]; then
  compact_assembly "$FIELDS" "$FM_SNAPSHOT_COMPACT_CEILING" \
    | jq '{schema, mode:"summary", generated, fm_home, summary}'
  exit 0
fi

if [ "$FULL" = 1 ]; then
  full_assembly "$BACKLOG_JSON" "$TASKS_JSON" \
    "$MAIN_INVENTORY_JSON" "$SCOUT_REPORTS_JSON" \
    "$SECONDMATE_CURRENT_JSON" "$SECONDMATE_LANDED_JSON"
  exit 0
fi

compact_assembly "$FIELDS" "$FM_SNAPSHOT_COMPACT_CEILING"
