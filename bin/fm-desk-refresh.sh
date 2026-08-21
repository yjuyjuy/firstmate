#!/usr/bin/env bash
# fm-desk-refresh.sh - regenerate the captain's desk, a single reloadable page
# rendering this home's current fleet state in the captain's own vocabulary.
#
# The captain wanted one page carrying fleet status in their own vocabulary. The
# explicitly rejected alternative was a standing agent, so this is a plain
# script: no resident process, no memory cost, no supervision turn. It is
# READ-ONLY over fleet state and SILENT by construction - see NEVER WAKES below.
#
# Invoked MANUALLY, on request. It is deliberately not on any schedule and is not
# wired into the watcher cycle: the captain asks for the desk when they want it.
#
# Usage:
#   fm-desk-refresh.sh              render the desk to the stable output path
#   fm-desk-refresh.sh --path       print that stable output path and exit
#   fm-desk-refresh.sh --help
#
# Exit status:
#   0  the page was rendered and moved into place (possibly with noted gaps)
#   1  nothing was rendered - the output could not be written at all
#   64 usage error
#
# NEVER WAKES. This script must never call bin/fm-wake-lib.sh, fm_wake_append,
# bin/fm-send.sh, or append to a status file. Rendering a page is not
# captain-facing progress (AGENTS.md section 8), so it reports nothing and
# interrupts nobody; it just leaves a fresh page behind.
#
# DATA SOURCES - all LOCAL and cheap; no network call, no agent, no probe that
# costs more than a kernel read:
#   bin/fm-bearings-snapshot.sh --json   the canonical local fleet projection
#                                        (which itself wraps fm-fleet-snapshot.sh
#                                        and honors config/backlog-backend), for
#                                        work under way, open decisions, blocked
#                                        items, and recently landed work
#   bin/fm-merge-queue.sh list --raw     finished-but-unmerged branches
#   bin/fm-resource-check.sh             the host reading. NEVER --sweep: that
#                                        form probes every agent's liveness and
#                                        belongs to the watcher alone. The plain
#                                        form is a kernel read plus the
#                                        state/.resource-live cache the sweep
#                                        already wrote, so it costs milliseconds
#   state/.resource-status               the level the fleet is operating on
#   state/.afk                           whether the captain is away
#   data/completions.tsv                 the append-only completion ledger, for
#                                        the progress windows and per-repo stats.
#                                        It records the completion DATE only, not
#                                        an hour, so an hour-scale window is shown
#                                        by the calendar days it touches and the
#                                        page says so rather than implying a
#                                        precision the source does not carry
#   state/.last-watcher-beat             the monitoring liveness beacon, read by
#                                        mtime for the fleet-health line
#   tasks-axi (in FM_HOME)               the backlog, for the full captain-hold
#                                        list and the four ranked queue lists
#   state/desk-transcript.jsonl          the durable captain-private transcript
#                                        feed the running session publishes to
#                                        (bin/fm-desk-transcript.sh), the PRIMARY
#                                        source for sections 11 and 12. A bounded
#                                        tail read; absent/empty degrades to the
#                                        judgment-file fallback and then to a gap
#
# DEGRADE QUIETLY. Every source is optional. A missing, failing, or unparseable
# source is recorded as a gap, shown in the page, and the rest of the page is
# still rendered. The page is written to a temp path in the destination
# directory and moved into place, so a reload never catches a partial page.
#
# The page follows the captain-desk spec (data/captain-desk-spec.md): a sticky
# KPI strip pinned on scroll, then twelve sections in urgency order - decisions,
# blockers, ready-to-merge, slots and host, two progress windows, upcoming,
# captain-held tickets, four ranked queue lists, stats, recent questions, and a
# recent-conversation transcript panel. Sections 11 and 12 are transcript-
# sourced: they read the durable transcript feed the running session publishes
# (state/desk-transcript.jsonl, owned by bin/fm-desk-transcript.sh), falling back
# to the judgment file, and render as marked gaps when neither has published a
# turn yet.
#
# A Captain's Call panel (id sec-captains-call) sits between the count band and
# section 1, unnumbered like the second-mate and account panels so the twelve
# numbered section ids stay stable. It renders the SAME decisions_open the
# /bearings report leads with - in the projection's blocking-first order, which
# fm-bearings-snapshot.sh owns - plus the merge-queue count, so the live page
# and the dated report speak one vocabulary for what needs the captain. Every
# fleet fact on this page comes from that same fm-bearings-snapshot.sh
# projection, so the desk holds no separate gather path and can never disagree
# with the report.
#
# A dedicated per-secondmate panel (id sec-secondmates) sits between section 4
# (crew slots) and section 5. It is a re-layout of the same fleet projection: the
# per-secondmate state/doing/freshness the snapshot already carries, plus each
# second mate's home and scope parsed from data/secondmates.md and its own
# backlog queue depth from that home's data/backlog.md. It keeps the twelve
# numbered sections and their ids stable rather than renumbering them. The
# captain-desk spec (data/captain-desk-spec.md) is captain-private and lives
# outside version control, so this header is the tracked one-owner description of
# the panel; the spec mirror is updated by firstmate in the same change set.
#
# An accounts and quota panel (id sec-accounts) sits next, between the
# per-secondmate panel and section 5. It reads quota-axi --json (routed through
# the desk_bound self-degrade wrapper; FM_DESK_QUOTA_BIN overrides the tool for
# tests) and renders ONE row per account (quota-axi provider): its runway as the
# lowest percent remaining across that account's quota windows, the label of the
# binding window, and that binding window's projected-exhausted and reset times,
# plus a reading note. An account with no windows (unavailable or needs sign-in)
# renders a dash in its runway cell, never a confident zero. The sticky KPI strip
# carries the lowest runway across all accounts as its headline. The per-pane
# attribution half - which worker pane runs on which account, its runway at last
# reading, and its throttle flags - is a real table composed UNDER the per-account
# table, read from each live pane's state/<id>.telemetry (the shared per-task
# artifact bin/fm-telemetry-lib.sh writes and this desk only consumes). It is
# plain key=value, the SAME shape as .meta, so it is read with the same parser and
# never as JSON; every key is optional and an absent key renders a gap dash, never
# a confident zero. render_pane_telemetry near its own source loads owns that half
# in full; this line points there, it does not restate the mechanics.
#
# LANGUAGE. The page is captain-facing, so AGENTS.md section 9 applies in full.
# Free text lifted from fleet records is passed through desk_plain(), which
# rewrites internal vocabulary into the captain's nouns; DESK_TERMS below is the
# single owner of that mapping.
#
# JUDGMENT LAYER. Four sections need judgment a read-only script cannot
# synthesize: 1 (decisions needed) and 2 (blockers/failures) are thin, and 11
# (recent questions) and 12 (recent conversation) have NO local source at all.
# The running firstmate session writes ONE small bounded file, and this builder
# splices it in when present and fresh. This comment is the SINGLE OWNER of that
# file's schema; the /desk skill and AGENTS.md point here, they do not restate
# it.
#
#   Path:    $FM_HOME/state/desk-judgment.json (override: FM_DESK_JUDGMENT)
#   Freshness: read only when written within FM_DESK_JUDGMENT_MAX_AGE seconds
#              (default 900). A present-but-stale file degrades exactly like an
#              absent one, per section.
#   Written:  by the /desk skill, atomically (temp file + mv), one model pass at
#              build time, immediately BEFORE this builder runs. The builder
#              NEVER writes it and NEVER calls a model.
#
#   {
#     "schema": 1,                         REQUIRED integer; any other value is ignored
#     "written_at": 1734127200,            REQUIRED unix epoch the session wrote it; drives freshness
#     "decisions": [                       ENRICHES section 1 by task id (union, never replace)
#       { "id": "task-id",                 join key: matches a script decision card by id
#         "ask": "the decision in one captain-facing line",
#         "options": ["option a", "option b"],
#         "recommendation": "firstmate's recommended call",
#         "unblocks": "what landing this unblocks",
#         "money": false }                 optional; forces the money badge on
#     ],
#     "blockers": [                        ENRICHES section 2 by task id (union, never replace)
#       { "id": "task-id",                 join key: matches a script blocker card by id
#         "diagnosis": "what is actually stuck and why",
#         "needs": "what would unblock it" }
#     ],
#     "questions": [                       FALLBACK source for section 11 (feed is primary)
#       { "q": "question firstmate asked", "a": "captain's short answer, or empty" }
#     ],
#     "transcript": [                      FALLBACK source for section 12; newest LAST in array
#       { "who": "captain"|"firstmate", "text": "turn text", "unread": true }
#     ]
#   }
#
#   MERGE/UNION for sections 1 and 2 (captain directive): the SCRIPT stays
#   authoritative for WHICH items appear (backlog-derived open decisions for 1,
#   live blocked/failed in-flight work for 2). The judgment file only ENRICHES a
#   matching script card BY ID; a script card with no match renders as-is with a
#   subtle "no analysis" marker; a judgment id with no script match renders in a
#   clearly-labeled "firstmate also flags" sub-block. It ADDS, never suppresses,
#   and is keyed strictly by id so there are never duplicate cards.
#
#   FALLBACK SOURCE for sections 11 and 12: the durable transcript feed
#   (state/desk-transcript.jsonl, bin/fm-desk-transcript.sh) is the PRIMARY
#   source for these two panels; the judgment file's questions/transcript arrays
#   are the FALLBACK used only when the feed is absent or empty, so the /desk
#   synthesis still populates the panels with no feed. The two never compose into
#   one section, so a turn is never double-rendered. Absent, stale, or empty
#   everywhere degrades to today's exact gap note. The durable-transcript-feed
#   block near the source loads owns that precedence.
#
#   Every array is optional and independently degradable, so one missing array
#   degrades ONLY its section. Every value still passes through desk_text()
#   (translate + HTML-escape) defensively, and every id through desk_title().
#
# Test seams: FM_DESK_OUT overrides the output path, FM_DESK_TIMEOUT bounds each
# source command, FM_DESK_NOW injects the rendered timestamp, and
# FM_DESK_SNAPSHOT_BIN overrides the fleet-projection command (the canonical
# fm-bearings-snapshot.sh) so a test can drive the projection failure paths.
# FM_DESK_NOW_EPOCH injects the reference epoch the progress windows count back
# from, and FM_DESK_COMPLETIONS overrides the completion-ledger path.
# FM_DESK_TRANSCRIPT overrides the durable transcript-feed path (mirroring the
# producer's own seam) and FM_DESK_TRANSCRIPT_READ bounds how many feed lines
# are read. FM_DESK_QUOTA_BIN overrides the quota-axi command the accounts panel
# reads, so a test can drive that panel through an absent tool or a fixture.
# FM_DESK_TELEMETRY_MAX_AGE overrides the per-pane telemetry staleness bound (in
# seconds) so a test can drive a record across the fresh/stale boundary.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# Export the resolved home so every child source (fm-bearings-snapshot.sh,
# fm-merge-queue.sh, fm-resource-check.sh) reads the SAME home this desk resolved.
# Those children each default FM_HOME to their own script-relative code root when
# it is unset, so an unexported FM_HOME let them silently read a different,
# possibly empty, home than the ticket band - which cd's into FM_HOME explicitly -
# and render confident-empty sections for a populated fleet.
export FM_HOME

# The stable output path. The SAME file every refresh, never a dated one: an
# already-open browser tab must stay valid so the captain only reloads.
OUT="${FM_DESK_OUT:-$FM_HOME/.lavish/captain-desk.html}"

# Per-source wall-clock bound. The fleet projection is the only source that
# takes real time, and the desk must never be the reason a watcher cycle stalls.
DESK_TIMEOUT=${FM_DESK_TIMEOUT:-120}
case "$DESK_TIMEOUT" in ''|*[!0-9]*) DESK_TIMEOUT=120 ;; esac

# How much of each unbounded list the page shows before it stops being scannable.
DESK_MAX_DECISIONS=${FM_DESK_MAX_DECISIONS:-12}

# The header comment IS the help text: from the description line down to the
# last comment line before the first executable line. The stop point is found
# dynamically (the `set -u` that opens the body) so the header can grow without
# a hand-maintained line number drifting out of date.
usage() {
  awk 'NR>=2 { if ($0 ~ /^set -u/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

# --- internal-vocabulary translation ----------------------------------------
#
# AGENTS.md section 9 owns the rule; this table owns the mechanical rewrite for
# free text the page lifts out of fleet records. Longer forms come first so a
# plural or hyphenated form is not half-rewritten by its own singular. Scout and
# second mate are accepted house vocabulary and deliberately absent.
DESK_TERMS=$(cat <<'TERMS'
[Cc]rewmates	workers
[Cc]rewmate	worker
[Ss]econdmate agents	second mates
[Aa]gents	workers
[Aa]gent	worker
[Ww]orktrees	local copies
[Ww]orktree	local copy
[Pp]rimary checkout	main local copy
[Cc]heckouts	local copies
[Cc]heckout	local copy
[Tt]ear down	clean up
[Tt]eardown	cleanup
[Hh]eartbeats	routine checks
[Hh]eartbeat	routine check
[Ww]ake queue	notification queue
[Ww]akes	notifications
[Ww]ake	notification
[Ww]atchers	monitoring
[Ww]atcher	monitoring
[Ss]tale	unresponsive
[Hh]arnesses	worker tools
[Hh]arness	worker tool
[Bb]ackends	worker tools
[Bb]ackend	worker tool
[Aa]dapters	worker tools
[Aa]dapter	worker tool
[Bb]riefs	instructions
[Bb]rief	instructions
fails? clos(e|ed|es)	stops safely
[Ff]ail-closed	stops safely
fails? open	steps aside
[Ff]ail-open	steps aside
[Pp]ipelines	validation runs
[Pp]ipeline	validation
[Nn]o-mistakes	validation
fix-review	review findings
checks-passed	checks passed
needs-decision	waiting on your word
ask-user	your decision
[Ss]tatus files?	record
[Mm]etadata	record
TERMS
)
# Handed to awk through the environment rather than -v: the table is multi-line,
# and awk's -v assignment neither accepts a literal newline nor leaves backslash
# escapes alone.
export DESK_TERMS

# desk_plain: rewrite internal vocabulary in free text read from stdin.
desk_plain() {
  awk '
    BEGIN {
      n = split(ENVIRON["DESK_TERMS"], lines, "\n")
      for (i = 1; i <= n; i++) {
        if (lines[i] == "") continue
        split(lines[i], kv, "\t")
        pat[i] = kv[1]; rep[i] = kv[2]
      }
    }
    {
      for (i = 1; i <= n; i++) if (pat[i] != "") gsub(pat[i], rep[i])
      print
    }
  '
}

# desk_esc: HTML-escape stdin. Runs AFTER desk_plain so the mapping never has to
# reason about entities.
desk_esc() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# desk_text: the only way free text reaches the page - translate, then escape.
desk_text() {
  printf '%s' "$1" | desk_plain | desk_esc
}

# desk_title: turn a durable record id into a human title. Ids are internal, so
# they are never printed raw. Ids are also where internal vocabulary is most
# concentrated, so the same translation runs here, before capitalization.
desk_title() {
  printf '%s' "$1" \
    | tr '_-' '  ' \
    | sed -e 's/^ *//' -e 's/  */ /g' \
    | desk_plain \
    | awk '{ if (length($0) > 0) print toupper(substr($0,1,1)) substr($0,2); else print }' \
    | desk_esc
}

# desk_show_field: the FULL value of a named tasks-axi field for one id, read
# from `tasks-axi show <id> --full` so the desk never inherits the snapshot's
# 60-char description truncation. Prints nothing when the record or field is
# absent, so callers can fall back. The field value may be quoted and may carry
# escaped newlines from the backend; collapse them to spaces for one-line cards.
desk_show_field() {
  local id="$1" field="$2"
  (cd "$FM_HOME" 2>/dev/null && desk_bound tasks-axi show "$id" --full 2>/dev/null) \
    | awk -v f="$field" '
        $0 ~ "^[[:space:]]*" f ":" {
          sub("^[[:space:]]*" f ":[[:space:]]*", "")
          sub(/^"/, ""); sub(/"[[:space:]]*$/, "")
          gsub(/\\n/, " "); gsub(/[[:space:]]+/, " ")
          print; exit
        }'
}

# desk_full_title / desk_full_reason: full title / hold reason for an id,
# translated and escaped, falling back to the (possibly truncated) value the
# snapshot already provided when the record cannot be read.
desk_full_title() {
  local id="$1" fallback="$2" full
  full=$(desk_show_field "$id" title)
  [ -n "$full" ] && { printf '%s' "$full" | desk_plain | desk_esc; return 0; }
  desk_text "$fallback"
}
desk_full_reason() {
  local id="$1" fallback="$2" full
  full=$(desk_show_field "$id" hold_reason)
  [ -n "$full" ] && [ "$full" != "-" ] && { printf '%s' "$full" | desk_plain | desk_esc; return 0; }
  [ "$fallback" = "-" ] && return 0
  desk_text "$fallback"
}

# desk_state: the captain-facing rendering of a recorded work state.
desk_state() {
  case "$1" in
    working) printf 'under way' ;;
    needs-decision) printf 'waiting on your word' ;;
    blocked) printf 'stuck' ;;
    paused) printf 'waiting' ;;
    done) printf 'finished' ;;
    failed) printf 'failed' ;;
    no_active_work|idle) printf 'idle' ;;
    ''|unknown) printf 'unclear' ;;
    *) printf '%s' "$(printf '%s' "$1" | tr '_-' '  ')" ;;
  esac
}

# desk_state_badge: the DaisyUI badge tone matching that state.
desk_state_badge() {
  case "$1" in
    working) printf 'badge-info' ;;
    needs-decision|blocked) printf 'badge-warning' ;;
    failed) printf 'badge-error' ;;
    done) printf 'badge-success' ;;
    *) printf 'badge-neutral' ;;
  esac
}

# --- bounded source execution -----------------------------------------------

# desk_bound: run a command under DESK_TIMEOUT when a timeout tool exists, and
# unbounded otherwise rather than refusing to render at all.
DESK_TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  DESK_TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  DESK_TIMEOUT_BIN=gtimeout
fi
desk_bound() {
  if [ -n "$DESK_TIMEOUT_BIN" ]; then
    "$DESK_TIMEOUT_BIN" "$DESK_TIMEOUT" "$@"
  else
    "$@"
  fi
}

# Gaps accumulate as one plain-English line each and are shown in the page, so a
# missing source is visible to the captain rather than silently rendering as
# "nothing to report".
GAPS=""
note_gap() { GAPS="${GAPS}${1}
"; }

# --- collect ----------------------------------------------------------------

BEAR=""
HAVE_JQ=0
if command -v jq >/dev/null 2>&1; then
  HAVE_JQ=1
else
  note_gap "Fleet records could not be read on this machine, so work under way, decisions, and finished work are missing."
fi

DESK_SNAPSHOT_BIN="${FM_DESK_SNAPSHOT_BIN:-$SCRIPT_DIR/fm-bearings-snapshot.sh}"
if [ "$HAVE_JQ" -eq 1 ]; then
  # The desk is a strictly READ-ONLY projection that itself displays away
  # status, so it must render a full fleet snapshot even while away mode is
  # active. Skip ONLY the bearings away-return guard for this read; the bypass
  # does not clear the away gate or mutate any catch-up state (see
  # fm-bearings-snapshot.sh). Away or not, the projection output is identical,
  # so a non-away render stays byte-unchanged.
  if BEAR=$(FM_BEARINGS_SKIP_AFK_GUARD=1 desk_bound "$DESK_SNAPSHOT_BIN" --json 2>/dev/null) \
    && [ -n "$BEAR" ] && printf '%s' "$BEAR" | jq -e . >/dev/null 2>&1; then
    :
  else
    BEAR=""
    note_gap "Current fleet state could not be read just now, so work under way, decisions, and finished work are missing from this page."
  fi
fi

MERGEQ=""
if ! MERGEQ=$(desk_bound "$SCRIPT_DIR/fm-merge-queue.sh" list --raw 2>/dev/null); then
  MERGEQ=""
  note_gap "The list of finished-but-unmerged work could not be read, so that section may be incomplete."
fi

RES_LINE=""
if ! RES_LINE=$(desk_bound "$SCRIPT_DIR/fm-resource-check.sh" 2>/dev/null | head -n 1); then
  RES_LINE=""
fi
RES_LEVEL=$(cat "$STATE/.resource-status" 2>/dev/null || printf '')
if [ -z "$RES_LINE" ] && [ -z "$RES_LEVEL" ]; then
  note_gap "No reading of this machine's capacity was available."
fi

# The account quota report, read for the accounts/quota panel (sec-accounts) and
# the sticky KPI strip's lowest-runway headline. quota-axi --json is a cheap
# local sub-second read routed through desk_bound like every other source.
# Absent, unreadable, or non-JSON data degrades to a gap in the panel and an
# "unknown" headline, never a confident-zero runway. FM_DESK_QUOTA_BIN overrides
# the tool so a test can inject a fixture or drive the failure paths.
QUOTA=""
QUOTA_PRESENT=0
DESK_QUOTA_BIN="${FM_DESK_QUOTA_BIN:-quota-axi}"
if [ "$HAVE_JQ" -eq 1 ] \
  && QUOTA=$(desk_bound "$DESK_QUOTA_BIN" --json 2>/dev/null) \
  && [ -n "$QUOTA" ] && printf '%s' "$QUOTA" | jq -e . >/dev/null 2>&1; then
  QUOTA_PRESENT=1
else
  QUOTA=""
  note_gap "The account quota report could not be read, so runway figures are unknown on this page."
fi

AWAY=0
[ -e "$STATE/.afk" ] && AWAY=1

# The completion ledger, read for the two progress windows (sections 5 and 6)
# and the per-repo stats (section 10). It is append-only and never pruned, so a
# plain read is cheap. Absent is a real answer ("nothing recorded yet"), not a
# failure, so it does not raise a global gap; each consuming section notes its
# own gap when it genuinely cannot render.
COMPLETIONS="${FM_DESK_COMPLETIONS:-$FM_HOME/data/completions.tsv}"

# The reference epoch the progress windows count back from. FM_DESK_NOW is a
# display string and may be injected in any format, so the windows use a
# separate numeric seam and fall back to the wall clock.
NOW_EPOCH=${FM_DESK_NOW_EPOCH:-$(date +%s)}
case "$NOW_EPOCH" in ''|*[!0-9]*) NOW_EPOCH=$(date +%s) ;; esac

# --- judgment layer (the model-written enrichment file) ---------------------
#
# The running firstmate session writes state/desk-judgment.json through the
# /desk skill's step 0, one small model pass, immediately BEFORE this builder
# runs. This read-only builder only READS it, and only when it is present,
# well-formed, schema-1, and FRESH (written within JUDGMENT_MAX_AGE). See the
# JUDGMENT LAYER block in the header for the full schema; that comment is the
# single schema owner and the skill points to it.
#
# The load is fail-safe by construction: any failure - jq absent, file absent,
# unreadable, not valid JSON, wrong schema, missing/zero/non-numeric written_at,
# or stale - leaves JUDGMENT empty and JUDGMENT_PRESENT at 0, and every render
# function then degrades to EXACTLY today's mechanical/gap behavior. The
# judgment layer can only ADD to the page, never subtract from it, so a
# read-only builder never depends on a model to produce a complete section.
JUDGMENT=""
JUDGMENT_PRESENT=0
JUDGMENT_STAMP=""
JUDGMENT_PATH="${FM_DESK_JUDGMENT:-$STATE/desk-judgment.json}"
JUDGMENT_MAX_AGE=${FM_DESK_JUDGMENT_MAX_AGE:-900}
case "$JUDGMENT_MAX_AGE" in ''|*[!0-9]*) JUDGMENT_MAX_AGE=900 ;; esac
if [ "$HAVE_JQ" -eq 1 ] && [ -f "$JUDGMENT_PATH" ]; then
  _j=$(cat "$JUDGMENT_PATH" 2>/dev/null)
  if [ -n "$_j" ] && printf '%s' "$_j" | jq -e '.schema == 1' >/dev/null 2>&1; then
    _wa=$(printf '%s' "$_j" | jq -r '.written_at // 0' 2>/dev/null)
    case "$_wa" in ''|*[!0-9]*) _wa=0 ;; esac
    if [ "$_wa" -gt 0 ] && [ $(( NOW_EPOCH - _wa )) -le "$JUDGMENT_MAX_AGE" ] \
      && [ $(( NOW_EPOCH - _wa )) -ge 0 ]; then
      JUDGMENT="$_j"
      JUDGMENT_PRESENT=1
      # A human generated-at stamp from written_at, so a stale-but-present desk
      # is obvious. Falls back to the raw epoch when date cannot format it.
      JUDGMENT_STAMP=$(date -d "@$_wa" '+%Y-%m-%d %H:%M' 2>/dev/null \
        || date -r "$_wa" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$_wa")
    fi
  fi
fi

# --- durable transcript feed (sections 11 and 12) ---------------------------
#
# The SEPARATE, durable, captain-private rolling feed the running session
# appends to as real captain-facing turns happen. bin/fm-desk-transcript.sh is
# its single owner and only writer; this read-only builder only READS it, and
# only when it is present and has usable lines. It is a plain jsonl file under
# state/ (gitignored, captain-private), so a bounded tail read is cheap.
#
# SOURCE PRECEDENCE for sections 11 and 12 (stated once, here, where the panels
# consume it): the durable feed is the PRIMARY source when it is present and
# yields at least one usable record; the judgment file's .questions/.transcript
# remain the FALLBACK when the feed is absent or empty, so the existing /desk
# model synthesis still works with no feed. The two never compose into one
# section, so the same turn is never double-rendered. When neither source
# yields content, each panel degrades to EXACTLY today's gap note.
#
# Fail-safe by construction: jq absent, file absent, empty, or every line
# unparseable leaves FEED_QUESTIONS/FEED_TRANSCRIPT empty and FEED_PRESENT at 0,
# and the panels fall back to the judgment layer and then to today's gap. A
# malformed line is skipped individually rather than failing the whole section.
FEED_PRESENT=0
FEED_QUESTIONS=""
FEED_TRANSCRIPT=""
FEED_PATH="${FM_DESK_TRANSCRIPT:-$STATE/desk-transcript.jsonl}"
# How many trailing feed lines to read. A bounded tail keeps the read cheap even
# if the file ever grew; the producer already caps the file, so this is belt.
FEED_MAX_READ=${FM_DESK_TRANSCRIPT_READ:-200}
case "$FEED_MAX_READ" in ''|*[!0-9]*) FEED_MAX_READ=200 ;; esac
if [ "$HAVE_JQ" -eq 1 ] && [ -f "$FEED_PATH" ]; then
  _feed=$(tail -n "$FEED_MAX_READ" "$FEED_PATH" 2>/dev/null)
  if [ -n "$_feed" ]; then
    # Section 11: question records, oldest first as stored, one Q<TAB>A per line.
    # Each line is parsed on its own so a malformed line is skipped, never fatal.
    # tostring coerces a non-scalar q/a to a visible string rather than blanking
    # the row (the feed producer only writes strings, but a hand-edited feed
    # might not). This runs before DESK_JQ_PRELUDE is defined, so it is inline.
    FEED_QUESTIONS=$(printf '%s\n' "$_feed" | while IFS= read -r _l; do
      [ -n "$_l" ] || continue
      printf '%s' "$_l" | jq -r 'select(.kind == "question") | [((.q // "")|tostring), ((.a // "")|tostring)] | @tsv' 2>/dev/null
    done)
    # Section 12: turn records, reversed to newest-first, one who<TAB>unread<TAB>text
    # per line. Same per-line parse so one bad line cannot blank the panel. The
    # awk reverse is portable where tac (a GNU coreutils tool) is absent.
    FEED_TRANSCRIPT=$(printf '%s\n' "$_feed" | while IFS= read -r _l; do
      [ -n "$_l" ] || continue
      printf '%s' "$_l" | jq -r 'select(.kind == "turn") | [((.who // "")|tostring), (if .unread == true then "1" else "0" end), ((.text // "")|tostring)] | @tsv' 2>/dev/null
    done | awk '{ a[NR] = $0 } END { for (i = NR; i >= 1; i--) print a[i] }')
    if [ -n "$FEED_QUESTIONS" ] || [ -n "$FEED_TRANSCRIPT" ]; then
      FEED_PRESENT=1
    fi
  fi
fi

# The monitoring liveness beacon, read for the fleet-health line in section 2.
# The watcher touches it every poll, so a beacon older than a generous bound
# means the supervision cycle has lapsed. Empty when the beacon is absent.
WATCH_BEAT_AGE=""
if [ -e "$STATE/.last-watcher-beat" ]; then
  _beat_mtime=$(date -r "$STATE/.last-watcher-beat" +%s 2>/dev/null || printf '')
  if [ -n "$_beat_mtime" ]; then
    WATCH_BEAT_AGE=$(( NOW_EPOCH - _beat_mtime ))
    [ "$WATCH_BEAT_AGE" -lt 0 ] && WATCH_BEAT_AGE=0
  fi
fi

# --- ticket counts ----------------------------------------------------------
#
# The count band is REQUIRED and always rendered. Its figures come from the
# backlog through tasks-axi and are NEVER scraped out of prose.
#
# The definitions the captain fixed:
#   Landed     state done
#   In flight  state in_flight, whether or not it is also on hold - it is being
#              worked right now, which is what the figure claims
#   Queued     ONLY queued work that could actually start today
#   Blocked    every other queued item: waiting on a captain decision, or on
#              another ticket. Held-but-queued and dependency-blocked items are
#              blocked, never queued.
# Blocked breaks down into "needs the captain" (a captain hold) and "waiting on
# other work" (a dependency block, or a hold of any other kind).
#
# tasks-axi's held listing is an OVERLAY, not a fifth state: a held row still
# carries its own done/in_flight/queued state. So the grand total is
# done + in_flight + queued, and the four figures partition exactly that set.
# Both sums are computed independently and compared; a mismatch is shown rather
# than hidden.
TICKETS_OK=0
TK_LANDED=0; TK_INFLIGHT=0; TK_QUEUED=0; TK_BLOCKED=0
TK_CAPTAIN=0; TK_OTHER=0; TK_TOTAL=0; TK_DISCREPANCY=""

# tasks_rows: "<id> <state> <last-field>" for each listed row. tasks-axi rows are
# indented by two spaces, comma-separated, id first and state second; neither an
# id nor a hold kind can contain a comma, so the first and last fields are safe
# to take positionally even when a quoted title contains commas.
tasks_rows() {
  (cd "$FM_HOME" 2>/dev/null && desk_bound tasks-axi "$@" 2>/dev/null) \
    | awk -F, '/^  [^ ]/ { id = $1; sub(/^ +/, "", id); print id, $2, $NF }'
}

# count_lines: number of non-empty lines, always exiting 0 (an empty listing is
# a real answer of zero, not a failure).
count_lines() { printf '%s\n' "$1" | awk 'NF { n++ } END { print n + 0 }'; }

collect_tickets() {
  local queued dep held blocked capheld queued_total four
  command -v tasks-axi >/dev/null 2>&1 || return 1
  # One probe that must succeed, so a broken or incompatible tasks-axi reads as
  # "unknown" rather than as an empty backlog.
  (cd "$FM_HOME" 2>/dev/null && desk_bound tasks-axi list --state 'done' --limit 1 >/dev/null 2>&1) || return 1

  TK_LANDED=$(count_lines "$(tasks_rows list --state 'done' --limit 100000)")
  TK_INFLIGHT=$(count_lines "$(tasks_rows list --state in_flight --limit 100000)")
  queued=$(tasks_rows list --state queued --limit 100000 | awk '{print $1}' | sort -u)
  dep=$(tasks_rows list --blocked --limit 100000 | awk '$2 == "queued" {print $1}')
  held=$(tasks_rows list --state held --limit 100000 --fields hold_kind | awk '$2 == "queued" {print $1}')
  capheld=$(tasks_rows list --state held --limit 100000 --fields hold_kind \
    | awk '$2 == "queued" && $3 == "captain" {print $1}')

  # A queued item can be BOTH dependency-blocked and held, so the blocked figure
  # is the union, never the sum of the two listings.
  blocked=$(printf '%s\n%s\n' "$dep" "$held" | awk 'NF' | sort -u)
  TK_BLOCKED=$(count_lines "$blocked")
  TK_CAPTAIN=$(count_lines "$capheld")
  TK_OTHER=$(( TK_BLOCKED - TK_CAPTAIN ))
  [ "$TK_OTHER" -lt 0 ] && TK_OTHER=0

  queued_total=$(count_lines "$queued")
  TK_QUEUED=$(( queued_total - TK_BLOCKED ))
  [ "$TK_QUEUED" -lt 0 ] && TK_QUEUED=0
  TK_TOTAL=$(( TK_LANDED + TK_INFLIGHT + queued_total ))

  four=$(( TK_LANDED + TK_INFLIGHT + TK_QUEUED + TK_BLOCKED ))
  if [ "$four" -ne "$TK_TOTAL" ]; then
    TK_DISCREPANCY="The four figures add up to ${four}, but the backlog holds ${TK_TOTAL} tickets - ${TK_TOTAL} is the true count and the difference is unexplained."
  fi
  TICKETS_OK=1
  return 0
}

if ! collect_tickets; then
  TICKETS_OK=0
  note_gap "The ticket counts could not be read from the backlog, so the count band is blank."
fi

NOW=${FM_DESK_NOW:-$(date '+%Y-%m-%d %H:%M')}

# A jq helper prepended to every desk_json filter: coerce a non-scalar value to a
# string so a single object/array-valued field (which jq's @tsv rejects for the
# WHOLE stream) degrades to a visible string instead of blanking the section.
DESK_JQ_PRELUDE='def z: if (type == "array" or type == "object") then tostring else . end;'

# desk_json: read one jq expression out of the fleet projection.
#
# Return status is the caller's signal, so an unreadable source is never confused
# with a source that genuinely holds nothing:
#   0  the query ran; stdout is the result, which may legitimately be empty
#   2  the fleet projection is absent (a global gap is already recorded for it)
#   3  the query itself failed against present data (a section-level gap is due)
desk_json() {
  [ -n "$BEAR" ] || return 2
  local out st
  out=$(printf '%s' "$BEAR" | jq -r "$DESK_JQ_PRELUDE $1" 2>/dev/null)
  st=$?
  printf '%s' "$out"
  [ "$st" -eq 0 ] || return 3
  return 0
}

# desk_section_gap: a visible, in-section gap line. Shown when a section's source
# could not be read, so the section reads as "unknown", never as a confident
# empty state.
desk_section_gap() {
  printf '    <p class="text-sm text-warning">%s</p>\n' "$(desk_text "$1")"
}

# --- judgment accessors ------------------------------------------------------
#
# All four judgment sections read through these. Each returns non-empty ONLY
# when a fresh judgment file supplied that array, so a caller can branch on
# emptiness and degrade to today's behavior with no separate freshness check.

# desk_judgment_field <jq-expr>: run one jq query against the loaded judgment.
# Prints nothing when no fresh judgment is loaded or the query fails, so the
# whole judgment layer is a no-op unless a valid fresh file exists.
desk_judgment_field() {  # <jq filter>
  [ "$JUDGMENT_PRESENT" -eq 1 ] || return 0
  printf '%s' "$JUDGMENT" | jq -r "$DESK_JQ_PRELUDE $1" 2>/dev/null
}

# desk_judgment_ids <array>: the set of task ids the judgment carries for an
# enrichment array (decisions or blockers), one per line. Used to find the
# judgment-only ids that have no matching script card.
desk_judgment_ids() {  # <decisions|blockers>
  desk_judgment_field ".${1}[]? | .id | select(. != null and . != \"\")"
}

# desk_generated_stamp: the visible generated-at line. States the judgment
# freshness explicitly so a stale-but-present desk cannot masquerade as live -
# the judgment layer is time-sensitive and the page must say when it was
# synthesized. Renders a plain "no analysis layer" line when absent/stale.
render_generated_stamp() {
  if [ "$JUDGMENT_PRESENT" -eq 1 ]; then
    printf '    <p class="text-xs opacity-50 mb-6">Firstmate analysis for sections 1, 2, 11, and 12 was written %s (within the last %s minutes).</p>\n' \
      "$(desk_esc <<<"$JUDGMENT_STAMP")" "$(( JUDGMENT_MAX_AGE / 60 ))"
  else
    printf '    <p class="text-xs opacity-50 mb-6">No fresh firstmate analysis layer for sections 1, 2, 11, and 12; those show the mechanical view only.</p>\n'
  fi
}

# desk_no_analysis_marker: the subtle marker on a script card that has no
# matching judgment enrichment, so an un-analyzed item is honestly flagged
# rather than looking analyzed. Only shown when a judgment IS loaded (otherwise
# the whole page is mechanical and the marker would be noise).
desk_no_analysis_marker() {
  [ "$JUDGMENT_PRESENT" -eq 1 ] || return 0
  printf '          <p class="text-xs opacity-40">No firstmate analysis for this item.</p>\n'
}

# --- render -----------------------------------------------------------------
#
# Design source: DaisyUI 5 on the Tailwind browser runtime, matching the
# hand-built desk this replaces, so a captain who had the earlier page open
# recognizes the new one immediately.

render_header() {
  local running running_st decisions decisions_st unmerged summary
  running=$(desk_json '[.in_flight[] | select(.state != "done")] | length'); running_st=$?
  decisions=$(desk_json '.decisions_open | length'); decisions_st=$?
  unmerged=0
  [ -n "$MERGEQ" ] && unmerged=$(printf '%s\n' "$MERGEQ" | grep -c .)
  summary=""
  # A count the projection could not supply must not be stated as zero: that
  # would read as a confident "nothing", the exact failure mode being fixed.
  if [ "$decisions_st" -ne 0 ]; then
    summary="Current fleet state could not be read, so this summary is incomplete."
  else
    case "${decisions:-0}" in
      ''|0) summary="Nothing needs your word." ;;
      1) summary="One thing needs your word." ;;
      *) summary="${decisions} things need your word." ;;
    esac
    case "${running:-0}" in
      ''|0) [ "$running_st" -eq 0 ] && summary="$summary Nothing is running." ;;
      1) summary="$summary One job is running." ;;
      *) summary="$summary ${running} jobs are running." ;;
    esac
  fi
  [ "${unmerged:-0}" -gt 0 ] && summary="$summary ${unmerged} finished branches are waiting to merge."
  [ "$AWAY" -eq 1 ] && summary="$summary You are marked away."

  cat <<HTML
  <header class="mb-8">
    <div class="flex flex-wrap items-baseline justify-between gap-3">
      <h1 class="text-3xl font-bold tracking-tight">Captain's desk</h1>
      <div class="text-sm opacity-60">as of $(desk_text "$NOW")</div>
    </div>
    <p class="mt-2 opacity-70 text-sm">$(desk_text "$summary")</p>
  </header>
HTML
}

# The count band. ALWAYS rendered, even when the backlog could not be read: an
# absent band would read as "no tickets", which is a different claim.
render_tickets() {
  local total landed inflight queued blocked split
  if [ "$TICKETS_OK" -eq 1 ]; then
    total=$TK_TOTAL; landed=$TK_LANDED; inflight=$TK_INFLIGHT
    queued=$TK_QUEUED; blocked=$TK_BLOCKED
    split="${TK_CAPTAIN} need your decision &middot; ${TK_OTHER} wait on other work"
  else
    total='&mdash;'; landed='&mdash;'; inflight='&mdash;'
    queued='&mdash;'; blocked='&mdash;'
    split='breakdown unavailable'
  fi
  cat <<HTML
  <section class="mb-10">
    <div class="card bg-base-200">
      <div class="card-body gap-4">
        <div class="flex items-baseline justify-between gap-3 flex-wrap">
          <h2 class="text-lg font-semibold">Ticket count</h2>
          <div class="text-sm opacity-60">${total} total</div>
        </div>
        <div class="grid gap-3 grid-cols-2 lg:grid-cols-4">

          <div class="rounded-lg bg-base-100 p-4">
            <div class="text-3xl font-semibold text-success">${landed}</div>
            <div class="text-sm font-medium mt-1">Landed</div>
            <div class="text-xs opacity-60 mt-0.5">finished and recorded</div>
          </div>

          <div class="rounded-lg bg-base-100 p-4">
            <div class="text-3xl font-semibold text-info">${inflight}</div>
            <div class="text-sm font-medium mt-1">In flight</div>
            <div class="text-xs opacity-60 mt-0.5">being worked right now</div>
          </div>

          <div class="rounded-lg bg-base-100 p-4">
            <div class="text-3xl font-semibold">${queued}</div>
            <div class="text-sm font-medium mt-1">Queued</div>
            <div class="text-xs opacity-60 mt-0.5">ready to start, waiting on capacity</div>
          </div>

          <div class="rounded-lg bg-base-100 p-4">
            <div class="text-3xl font-semibold text-warning">${blocked}</div>
            <div class="text-sm font-medium mt-1">Blocked</div>
            <div class="text-xs opacity-60 mt-0.5">${split}</div>
          </div>

        </div>
        <p class="text-xs opacity-50">
          Landed + in flight + queued + blocked = ${total}. Queued counts only work that could start today;
          anything waiting on you or on another ticket is counted as blocked, not queued.
        </p>
HTML
  if [ -n "$TK_DISCREPANCY" ]; then
    printf '        <div class="alert alert-warning text-sm py-2">%s</div>\n' \
      "$(desk_text "$TK_DISCREPANCY")"
  fi
  cat <<'HTML'
      </div>
    </div>
  </section>
HTML
}

render_gaps() {
  [ -n "$GAPS" ] || return 0
  echo '  <div class="alert alert-warning mb-8 text-sm block">'
  echo '    <div class="font-medium mb-1">Some of this page is missing.</div>'
  echo '    <ul class="space-y-1">'
  printf '%s' "$GAPS" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '      <li>&bull; %s</li>\n' "$(desk_text "$line")"
  done
  echo '    </ul>'
  echo '  </div>'
}

# --- money detector ----------------------------------------------------------
# A cheap heuristic that flags a ticket or branch on the payment path so the
# captain can spot money-touching work at a glance, per the spec's "money-path
# flagged" requirement. It is deliberately generous: a false positive costs a
# harmless badge, a false negative hides a money change.
desk_is_money() {  # <free text...>
  printf '%s' "$*" | grep -qiE 'pay|price|charg|money|invoice|refund|billing|reprice|epdf|eplf|extrafee|dual.?pric'
}

# --- Captain's Call panel ----------------------------------------------------
# The live-page form of the /bearings report's first section: what needs the
# captain's word right now. It renders the SAME decisions_open the dated report
# leads with, in the projection's blocking-first order (fm-bearings-snapshot.sh
# owns that ordering, so this panel preserves it rather than re-sorting), plus
# the merge-queue count. It is a summary panel only: the detailed decision cards
# with judgment enrichment stay in section 1 and the full merge compare links
# stay in section 3, so this panel adds the bearings framing without duplicating
# card-level detail. Unnumbered, like the second-mate and account panels, so the
# twelve numbered section ids stay stable. On an unreadable projection it
# renders a visible gap, never a confident "nothing".
render_captains_call() {
  local rows st merge_count merge_line
  rows=$(desk_json ".decisions_open[:${DESK_MAX_DECISIONS}][] | [.id, ((.summary // \"\")|z), ((.blocking // false)|tostring)] | @tsv"); st=$?
  merge_count=0
  [ -n "$MERGEQ" ] && merge_count=$(printf '%s\n' "$MERGEQ" | grep -c .)
  echo '  <section id="sec-captains-call" class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">Captain'"'"'s Call</h2>'
  printf '    <p class="text-sm opacity-70 mb-3">What needs your word right now, from the same projection as the dated bearings report. Blocking calls come first; the rest wait for your convenience.</p>\n'
  if [ "$st" -ne 0 ]; then
    if [ "$merge_count" -gt 0 ]; then
      [ "$merge_count" -eq 1 ] && merge_line="1 finished branch is ready to merge." || merge_line="${merge_count} finished branches are ready to merge."
      printf '    <div class="card bg-base-200/60"><div class="card-body py-3"><p class="text-sm">%s <a class="link link-hover" href="#sec-merge">See Ready to merge below.</a></p></div></div>\n' \
        "$(desk_text "$merge_line")"
    fi
    desk_section_gap "The list of decisions waiting on you could not be read, so this panel is unknown right now."
    echo '  </section>'
    return 0
  fi
  if [ -z "$rows" ] && [ "$merge_count" -eq 0 ]; then
    echo '    <p class="text-sm opacity-60">Nothing needs your action right now.</p>'
    echo '  </section>'
    return 0
  fi
  echo '    <div class="space-y-2">'
  if [ -n "$rows" ]; then
    printf '%s\n' "$rows" | while IFS=$'\t' read -r id summary blocking; do
      [ -n "$id" ] || continue
      local badge=''
      [ "$blocking" = "true" ] && badge='<span class="badge badge-error badge-xs">blocking</span>'
      cat <<HTML
      <div class="card bg-base-200 rail" style="--rail: oklch(0.75 0.16 70)">
        <div class="card-body py-3 gap-1">
          <div class="flex items-start justify-between gap-2">
            <h3 class="font-medium text-sm">$(desk_title "$id")</h3>
            <span class="flex gap-1 shrink-0"><span class="badge badge-warning badge-sm">your call</span>${badge}</span>
          </div>
HTML
      if [ -n "$summary" ]; then
        printf '          <p class="text-sm opacity-70">%s</p>\n' "$(desk_text "$summary")"
      fi
      echo '        </div>'
      echo '      </div>'
    done
  fi
  if [ "$merge_count" -gt 0 ]; then
    [ "$merge_count" -eq 1 ] && merge_line="1 finished branch is ready to merge." || merge_line="${merge_count} finished branches are ready to merge."
    printf '    <div class="card bg-base-200/60 mt-3"><div class="card-body py-3"><p class="text-sm">%s <a class="link link-hover" href="#sec-merge">See Ready to merge below.</a></p></div></div>\n' \
      "$(desk_text "$merge_line")"
  fi
  echo '    </div>'
  echo '  </section>'
}

# --- section 1: decisions needed --------------------------------------------
# The SCRIPT is authoritative for WHICH decisions appear (backlog-derived
# decisions_open). The judgment file, when fresh, ENRICHES a matching card BY
# ID with the captain-facing ask, options, recommendation, and what it unblocks;
# a script card with no match shows a subtle no-analysis marker; a judgment id
# with no script card appears in a labeled "firstmate also flags" sub-block. It
# ADDS, never suppresses, and is keyed strictly by id so there are no duplicates.
# With no fresh judgment the section is byte-identical to its old mechanical form.

# desk_decision_enrich <id>: print the enrichment HTML for a matched decision id
# and return 0; return 1 when no fresh judgment carries this id.
desk_decision_enrich() {  # <id>
  [ "$JUDGMENT_PRESENT" -eq 1 ] || return 1
  local row ask options rec unblocks
  row=$(printf '%s' "$JUDGMENT" | jq -r --arg id "$1" "$DESK_JQ_PRELUDE"'
    first(.decisions[]? | select(.id == $id)) as $d
    | if $d == null then empty
      else [ (($d.ask // "")|z), (($d.options // [])|map(tostring)|join("\u001f")),
             (($d.recommendation // "")|z), (($d.unblocks // "")|z) ] | @tsv
      end' 2>/dev/null)
  [ -n "$row" ] || return 1
  IFS=$'\t' read -r ask options rec unblocks <<EOF
$row
EOF
  [ -n "$ask" ] && printf '          <p class="text-sm opacity-90">%s</p>\n' "$(desk_text "$ask")"
  if [ -n "$options" ]; then
    printf '          <ul class="text-xs opacity-70 list-disc pl-5">\n'
    printf '%s' "$options" | tr '\037' '\n' | while IFS= read -r opt; do
      [ -n "$opt" ] || continue
      printf '            <li>%s</li>\n' "$(desk_text "$opt")"
    done
    printf '          </ul>\n'
  fi
  [ -n "$rec" ] && printf '          <p class="text-xs opacity-70"><span class="font-medium">Recommend:</span> %s</p>\n' "$(desk_text "$rec")"
  [ -n "$unblocks" ] && printf '          <p class="text-xs opacity-50">Unblocks: %s</p>\n' "$(desk_text "$unblocks")"
  return 0
}

# desk_decisions_only <script-rows-tsv>: judgment decision ids with no matching
# script card, one per line. Empty unless a fresh judgment is loaded.
desk_decisions_only() {  # <script-rows-tsv>
  [ "$JUDGMENT_PRESENT" -eq 1 ] || return 0
  local scriptids jids
  scriptids=$(printf '%s\n' "$1" | awk -F'\t' 'NF{print $1}' | sort -u)
  jids=$(desk_judgment_ids decisions | awk 'NF' | sort -u)
  [ -n "$jids" ] || return 0
  comm -23 <(printf '%s\n' "$jids") <(printf '%s\n' "$scriptids" | awk 'NF')
}

render_decisions() {
  local rows st jonly
  rows=$(desk_json ".decisions_open[:${DESK_MAX_DECISIONS}][] | [.id, (.summary|z), (.owner|z), ((.summary_full // .summary)|z)] | @tsv"); st=$?
  echo '  <section id="sec-decisions" class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">1. Decisions needed</h2>'
  if [ "$st" -ne 0 ]; then
    desk_section_gap "The list of decisions waiting on you could not be read, so this section is unknown right now."
    echo '  </section>'
    return 0
  fi
  jonly=$(desk_decisions_only "$rows")
  if [ -z "$rows" ] && [ -z "$jonly" ]; then
    echo '    <p class="text-sm opacity-60">Nothing is waiting on you.</p>'
    echo '  </section>'
    return 0
  fi
  if [ -n "$rows" ]; then
    echo '    <div class="grid gap-4 md:grid-cols-2">'
    printf '%s\n' "$rows" | while IFS=$'\t' read -r id summary owner full; do
      [ -n "$id" ] || continue
      local money=''
      desk_is_money "$id $summary $full" && money='<span class="badge badge-error badge-sm">money</span>'
      if [ "$JUDGMENT_PRESENT" -eq 1 ] && [ -z "$money" ]; then
        local jmoney
        jmoney=$(printf '%s' "$JUDGMENT" | jq -r --arg id "$id" '(first(.decisions[]? | select(.id == $id)) | .money) // false' 2>/dev/null)
        [ "$jmoney" = "true" ] && money='<span class="badge badge-error badge-sm">money</span>'
      fi
      # Prefer the untruncated hold reason from tasks-axi; else the full summary
      # carried by the projection; else the truncated summary. Whichever wins, the
      # body is fully expandable so nothing stays cut off.
      local reason
      reason=$(desk_full_reason "$id" "$full")
      [ -n "$reason" ] || reason=$(desk_text "$full")
      [ -n "$reason" ] || reason=$(desk_text "$summary")
      cat <<HTML
      <div class="card bg-base-200 rail" style="--rail: oklch(0.75 0.16 70)">
        <div class="card-body gap-2">
          <div class="flex items-start justify-between gap-2">
            <h3 class="card-title text-base">$(desk_title "$id")</h3>
            <span class="flex gap-1 shrink-0">${money}<span class="badge badge-warning badge-sm">your call</span></span>
          </div>
          <details class="text-sm opacity-80 group">
            <summary class="cursor-pointer list-none marker:hidden [&::-webkit-details-marker]:hidden">
              <span class="align-middle">${reason}</span>
            </summary>
          </details>
HTML
      desk_decision_enrich "$id" || desk_no_analysis_marker
      cat <<HTML
          <div class="text-xs opacity-50">$(desk_text "$owner")</div>
        </div>
      </div>
HTML
    done
    echo '    </div>'
  fi
  if [ -n "$jonly" ]; then
    echo '    <div class="mt-4">'
    echo '      <h3 class="text-sm font-medium opacity-70 mb-2">Firstmate also flags</h3>'
    echo '      <div class="grid gap-4 md:grid-cols-2">'
    printf '%s\n' "$jonly" | while IFS= read -r id; do
      [ -n "$id" ] || continue
      local money=''
      local jmoney
      jmoney=$(printf '%s' "$JUDGMENT" | jq -r --arg id "$id" '(first(.decisions[]? | select(.id == $id)) | .money) // false' 2>/dev/null)
      { [ "$jmoney" = "true" ] || desk_is_money "$id"; } && money='<span class="badge badge-error badge-sm">money</span>'
      cat <<HTML
      <div class="card bg-base-200/60 rail" style="--rail: oklch(0.75 0.16 70)">
        <div class="card-body gap-2">
          <div class="flex items-start justify-between gap-2">
            <h3 class="card-title text-base">$(desk_title "$id")</h3>
            <span class="flex gap-1 shrink-0">${money}<span class="badge badge-ghost badge-sm">flagged</span></span>
          </div>
HTML
      desk_decision_enrich "$id"
      cat <<HTML
        </div>
      </div>
HTML
    done
    echo '      </div>'
    echo '    </div>'
  fi
  echo '  </section>'
}

# --- section 2: blockers and failures ---------------------------------------
# Distinct from decisions: this is "something is broken", not "choose please".
# Sourced from in-flight work whose live state is blocked or failed, plus a
# fleet-health line that reports the monitoring beacon and away posture. The
# builder is read-only and cannot cheaply prove a background daemon is alive or
# that a clone has drifted, so it says so rather than inventing a green light.
render_fleet_health() {
  local mon away
  if [ -n "$WATCH_BEAT_AGE" ]; then
    if [ "$WATCH_BEAT_AGE" -le 1800 ]; then
      mon="Monitoring is alive (last check about ${WATCH_BEAT_AGE}s ago)."
    else
      mon="Monitoring may have lapsed (last check about ${WATCH_BEAT_AGE}s ago)."
    fi
  else
    mon="Monitoring status is unknown; no recent check was recorded."
  fi
  if [ "$AWAY" -eq 1 ]; then away="You are marked away."; else away="You are present."; fi
  printf '    <p class="text-sm opacity-70 mb-3">%s %s Background daemon liveness and clone drift are not checked by this read-only page.</p>\n' \
    "$(desk_text "$mon")" "$(desk_text "$away")"
}

# The SCRIPT is authoritative for WHICH blockers appear (live blocked/failed
# in-flight work). The judgment file, when fresh, ENRICHES a matching card BY ID
# with a diagnosis and what would unblock it; an unmatched script card shows the
# no-analysis marker; a judgment id with no live script card appears in the
# labeled "firstmate also flags" sub-block. ADD, never suppress; keyed by id.

# desk_blocker_enrich <id>: enrichment HTML for a matched blocker id, return 0;
# return 1 when no fresh judgment carries it.
desk_blocker_enrich() {  # <id>
  [ "$JUDGMENT_PRESENT" -eq 1 ] || return 1
  local row diagnosis needs
  row=$(printf '%s' "$JUDGMENT" | jq -r --arg id "$1" "$DESK_JQ_PRELUDE"'
    first(.blockers[]? | select(.id == $id)) as $b
    | if $b == null then empty
      else [ (($b.diagnosis // "")|z), (($b.needs // "")|z) ] | @tsv end' 2>/dev/null)
  [ -n "$row" ] || return 1
  IFS=$'\t' read -r diagnosis needs <<EOF
$row
EOF
  [ -n "$diagnosis" ] && printf '          <p class="text-xs opacity-70"><span class="font-medium">Diagnosis:</span> %s</p>\n' "$(desk_text "$diagnosis")"
  [ -n "$needs" ] && printf '          <p class="text-xs opacity-50">Needs: %s</p>\n' "$(desk_text "$needs")"
  return 0
}

# desk_blockers_only <script-rows-tsv>: judgment blocker ids with no live script
# card. Empty unless a fresh judgment is loaded.
desk_blockers_only() {  # <script-rows-tsv>
  [ "$JUDGMENT_PRESENT" -eq 1 ] || return 0
  local scriptids jids
  scriptids=$(printf '%s\n' "$1" | awk -F'\t' 'NF{print $1}' | sort -u)
  jids=$(desk_judgment_ids blockers | awk 'NF' | sort -u)
  [ -n "$jids" ] || return 0
  comm -23 <(printf '%s\n' "$jids") <(printf '%s\n' "$scriptids" | awk 'NF')
}

render_blockers() {
  local rows st jonly
  rows=$(desk_json '[.in_flight[] | select(.state == "blocked" or .state == "failed")][] | [.id, (.state|z), (.doing|z)] | @tsv'); st=$?
  echo '  <section id="sec-blockers" class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">2. Blockers and failures</h2>'
  render_fleet_health
  if [ "$st" -ne 0 ]; then
    desk_section_gap "The list of stuck or failed work could not be read, so this section is unknown right now."
    echo '  </section>'
    return 0
  fi
  jonly=$(desk_blockers_only "$rows")
  if [ -z "$rows" ] && [ -z "$jonly" ]; then
    echo '    <p class="text-sm opacity-60">Nothing is broken or stuck right now.</p>'
    echo '  </section>'
    return 0
  fi
  if [ -n "$rows" ]; then
    echo '    <div class="grid gap-3 md:grid-cols-2">'
    printf '%s\n' "$rows" | while IFS=$'\t' read -r id state doing; do
      [ -n "$id" ] || continue
      cat <<HTML
      <div class="card bg-base-200 rail" style="--rail: oklch(0.6 0.2 25)">
        <div class="card-body py-4 gap-1">
          <div class="flex items-start justify-between gap-2">
            <h3 class="font-medium text-sm">$(desk_title "$id")</h3>
            <span class="badge $(desk_state_badge "$state") badge-sm shrink-0">$(desk_text "$(desk_state "$state")")</span>
          </div>
          <p class="text-sm opacity-70">$(desk_text "$doing")</p>
HTML
      desk_blocker_enrich "$id" || desk_no_analysis_marker
      cat <<HTML
        </div>
      </div>
HTML
    done
    echo '    </div>'
  fi
  if [ -n "$jonly" ]; then
    echo '    <div class="mt-4">'
    echo '      <h3 class="text-sm font-medium opacity-70 mb-2">Firstmate also flags</h3>'
    echo '      <div class="grid gap-3 md:grid-cols-2">'
    printf '%s\n' "$jonly" | while IFS= read -r id; do
      [ -n "$id" ] || continue
      cat <<HTML
      <div class="card bg-base-200/60 rail" style="--rail: oklch(0.6 0.2 25)">
        <div class="card-body py-4 gap-1">
          <div class="flex items-start justify-between gap-2">
            <h3 class="font-medium text-sm">$(desk_title "$id")</h3>
            <span class="badge badge-ghost badge-sm shrink-0">flagged</span>
          </div>
HTML
      desk_blocker_enrich "$id"
      cat <<HTML
        </div>
      </div>
HTML
    done
    echo '      </div>'
    echo '    </div>'
  fi
  echo '  </section>'
}

# --- section 4: slots and host ----------------------------------------------
# Per the spec, list EVERY occupied crew slot with what it is doing right now,
# each naming the agent, its kind, and its current activity. The snapshot
# already carries the live per-item .doing/.state for in-flight crew work, so
# the desk draws the per-slot activity from that single projection rather than N
# slow fm-crew-state calls, which keeps the section inside the wall-clock bound.
# Second mates are NOT listed here: they have their own dedicated panel
# (render_secondmates, section sec-secondmates) so they get proper alive/idle
# state, home, scope, and queue-depth columns instead of a folded-in slots row.
render_slots() {
  local crew crew_st
  crew=$(desk_json '[.in_flight[] | select(.state != "done")][] | [.id, (.kind|z), (.state|z), (.doing|z)] | @tsv'); crew_st=$?
  echo '  <section id="sec-slots" class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">4. Slots and host</h2>'
  render_machine_card
  # Standing postures line.
  local posture
  if [ "$AWAY" -eq 1 ]; then posture="Away mode is on."; else posture="Away mode is off."; fi
  printf '    <p class="text-sm opacity-70 mt-3 mb-3">%s Self-landing lanes run per the backlog; this page does not track them individually.</p>\n' \
    "$(desk_text "$posture")"
  echo '    <div class="overflow-x-auto">'
  echo '      <table class="table table-sm">'
  echo '        <thead><tr class="text-xs uppercase tracking-wide opacity-60">'
  echo '          <th class="w-56">Agent</th><th class="w-24">Kind</th><th class="w-28">Standing</th><th>What it is doing</th>'
  echo '        </tr></thead>'
  echo '        <tbody>'
  if [ "$crew_st" -eq 0 ] && [ -n "$crew" ]; then
    printf '%s\n' "$crew" | while IFS=$'\t' read -r id kind state doing; do
      [ -n "$id" ] || continue
      [ "$kind" = "-" ] && kind="work"
      cat <<HTML
          <tr>
            <td class="font-medium align-top">$(desk_title "$id")</td>
            <td class="align-top text-sm opacity-70">$(desk_text "$kind")</td>
            <td class="align-top"><span class="badge $(desk_state_badge "$state") badge-sm">$(desk_text "$(desk_state "$state")")</span></td>
            <td class="text-sm opacity-80">$(desk_text "$doing")</td>
          </tr>
HTML
    done
  fi
  echo '        </tbody>'
  echo '      </table>'
  echo '    </div>'
  if [ "$crew_st" -ne 0 ]; then
    desk_section_gap "Part of the live per-slot activity could not be read, so this list may be incomplete."
  elif [ -z "$crew" ]; then
    echo '    <p class="text-sm opacity-60">No crew slots are occupied right now.</p>'
  fi
  echo '  </section>'
}

# --- section sec-secondmates: per-secondmate panel --------------------------
# A dedicated panel for the standing second mates, split out of section 4 so
# each second mate gets a proper row instead of a folded-in slots entry. It is a
# pure RE-LAYOUT of data the snapshot already carries: the per-secondmate
# {id,state,doing,freshness,age_seconds,contradiction} comes from the same
# fm-bearings-snapshot.sh projection every other panel reads, so no new fleet
# read is added. Two cheap local reads enrich each row:
#   home + scope    one line parsed out of this home's data/secondmates.md
#                   registry (the file fm-home-seed.sh maintains)
#   queue depth     the count of open (unchecked) items in that second mate's
#                   OWN data/backlog.md - a single-file line count per home, NOT
#                   an N-spawn tasks-axi call per home, and routed through the
#                   desk_bound self-degrade wrapper like every other source
# Idle second mates are listed and marked idle (idle is healthy). The
# freshness/age/contradiction fields are surfaced so a stale or contradicted
# reading is visible, never hidden behind a confident row. When the registry is
# present but unreadable the panel renders a gap, never a confident-empty list.
SM_REG=""
SM_REG_STATUS="ok"      # ok | absent | unreadable
# desk_file_mode: the octal permission bits of a file, empty when they cannot be
# read. Mirrors fm-fleet-snapshot.sh so the readability check does not depend on
# whether the caller is root (root's cat ignores a 000 mode, but the mode bits
# still say unreadable).
if stat -c '%a' / >/dev/null 2>&1; then
  desk_file_mode() { stat -c '%a' "$1" 2>/dev/null || true; }
else
  desk_file_mode() { stat -f '%Lp' "$1" 2>/dev/null || true; }
fi
if [ -e "$FM_HOME/data/secondmates.md" ]; then
  _sm_mode=$(desk_file_mode "$FM_HOME/data/secondmates.md")
  if [ -n "$_sm_mode" ] && [ $((8#$_sm_mode & 0444)) -ne 0 ] \
    && SM_REG=$(cat "$FM_HOME/data/secondmates.md" 2>/dev/null); then
    SM_REG_STATUS="ok"
  else
    SM_REG=""
    SM_REG_STATUS="unreadable"
  fi
else
  SM_REG_STATUS="absent"
fi

# desk_sm_reg_field <id> <home|scope>: the named registry field for one second
# mate id, parsed from the single matching registry line. Empty when the id is
# absent from the registry or the field is not recorded. The id is anchored with
# a trailing space so a prefix id ("mirror") never matches a longer one
# ("mirror-desk"); ids are slugs with no sed-special characters.
desk_sm_reg_field() {  # <id> <field>
  local id="$1" field="$2"
  printf '%s\n' "$SM_REG" \
    | sed -n "s/^- ${id} .*${field}:[[:space:]]*\\([^;)]*\\).*/\\1/p" \
    | head -n 1 \
    | sed -e 's/[[:space:]]*$//'
}

# desk_sm_queue_depth <home>: the number of open (unchecked) backlog items in a
# second mate's own home, read as a single cheap line count of that home's
# data/backlog.md through desk_bound. Prints nothing and returns non-zero when
# the home is unknown or its backlog cannot be read, so the caller shows "-"
# rather than a confident zero.
desk_sm_queue_depth() {  # <home>
  local home="$1" bl n
  [ -n "$home" ] || return 1
  bl="$home/data/backlog.md"
  [ -f "$bl" ] || return 1
  local rc
  n=$(desk_bound grep -c '^- \[ \]' "$bl" 2>/dev/null); rc=$?
  [ "$rc" -le 1 ] || return 1
  [ "$rc" -eq 1 ] && n=0
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$n"
}

render_secondmates() {
  local rows st
  rows=$(desk_json '.secondmates[]? | [.id, (.state|z), (.doing|z), (.freshness|z), (.age_seconds|z), (.contradiction|z)] | @tsv'); st=$?
  echo '  <section id="sec-secondmates" class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">Second mates</h2>'
  if [ "$st" -ne 0 ]; then
    desk_section_gap "The list of second mates could not be read, so this panel is unknown right now."
    echo '  </section>'
    return 0
  fi
  if [ "$SM_REG_STATUS" = "unreadable" ]; then
    desk_section_gap "The second-mate registry could not be read, so home and scope may be missing below."
  fi
  if [ -z "$rows" ]; then
    echo '    <p class="text-sm opacity-60">No second mates are standing right now.</p>'
    echo '  </section>'
    return 0
  fi
  echo '    <p class="text-sm opacity-70 mb-3">Standing helpers. An idle second mate is healthy - it waits for work routed to it.</p>'
  echo '    <div class="overflow-x-auto">'
  echo '      <table class="table table-sm">'
  echo '        <thead><tr class="text-xs uppercase tracking-wide opacity-60">'
  echo '          <th class="w-48">Second mate</th><th class="w-24">State</th><th>What it is doing</th><th class="w-56">Scope</th><th class="w-20">Queued</th><th class="w-24">Reading</th>'
  echo '        </tr></thead>'
  echo '        <tbody>'
  printf '%s\n' "$rows" | while IFS=$'\t' read -r id state doing freshness age contradiction; do
    [ -n "$id" ] || continue
    local home scope depth depth_cell fresh_cell home_line
    home=$(desk_sm_reg_field "$id" home)
    scope=$(desk_sm_reg_field "$id" scope)
    if depth=$(desk_sm_queue_depth "$home"); then
      depth_cell="$depth"
    else
      depth_cell='<span class="opacity-50">-</span>'
    fi
    # Freshness cell: an unresponsive or contradicted reading is flagged so a
    # stale second-mate row is never shown as current truth.
    if [ "$contradiction" = "true" ]; then
      fresh_cell='<span class="badge badge-warning badge-xs">contradicted</span>'
    elif [ -n "$freshness" ] && [ "$freshness" != "fresh" ] && [ "$freshness" != "-" ]; then
      fresh_cell="<span class=\"badge badge-warning badge-xs\">$(desk_text "$(desk_state "$freshness")")</span>"
    elif [ -n "$age" ] && [ "$age" != "-" ] && [ "$age" != "null" ]; then
      fresh_cell="<span class=\"opacity-60\">$(desk_text "${age}s ago")</span>"
    else
      fresh_cell='<span class="opacity-50">-</span>'
    fi
    if [ -n "$home" ]; then
      home_line="<div class=\"text-xs opacity-40\">$(desk_text "$home")</div>"
    else
      home_line=''
    fi
    [ -n "$scope" ] || scope='-'
    cat <<HTML
          <tr>
            <td class="font-medium align-top">$(desk_title "$id") <span class="badge badge-ghost badge-xs">second mate</span>${home_line}</td>
            <td class="align-top"><span class="badge $(desk_state_badge "$state") badge-sm">$(desk_text "$(desk_state "$state")")</span></td>
            <td class="text-sm opacity-80 align-top">$(desk_text "$doing")</td>
            <td class="text-sm opacity-70 align-top">$(desk_text "$scope")</td>
            <td class="text-sm align-top">${depth_cell}</td>
            <td class="align-top">${fresh_cell}</td>
          </tr>
HTML
  done
  echo '        </tbody>'
  echo '      </table>'
  echo '    </div>'
  echo '  </section>'
}

# --- section sec-accounts: accounts and quota panel (per-account half) -------
# One row per account (a quota-axi provider). An account's runway is the lowest
# percent remaining across its quota windows - the window that throttles first is
# the binding constraint - and the window label, projected-exhausted time, and
# reset time shown are that binding window's. An account with no windows
# (unavailable or needs sign-in) renders a dash in its runway cell, never a
# confident zero. The per-pane attribution half (which worker pane runs on which
# account, with its throttle flags) is a labeled gap pending the visibility layer
# (design-workflow-dashboard section 4); it is never silently missing here. The
# lowest runway across all accounts feeds the sticky KPI strip headline.
#
# desk_quota_status: the captain-facing reading note for one account source.
desk_quota_status() {  # <state.status>
  case "$1" in
    fresh) printf 'ok' ;;
    auth_required) printf 'needs sign-in' ;;
    error|unavailable) printf 'unavailable' ;;
    '') printf 'no reading' ;;
    *) printf '%s' "$(printf '%s' "$1" | tr '_' ' ')" ;;
  esac
}

# desk_iso_time: a captain-friendly local "MM-DD HH:MM" for an ISO-8601 stamp.
# GNU date converts to local time; BSD date gets the same conversion; the last
# fallback slices the raw stamp so a readable time still shows no matter what.
desk_iso_time() {  # <iso8601>
  local iso="$1" out=""
  [ -n "$iso" ] || return 0
  out=$(date -d "$iso" '+%m-%d %H:%M' 2>/dev/null) || out=""
  [ -n "$out" ] && [ "$out" != "$iso" ] && { printf '%s' "$out"; return 0; }
  out=$(date -j -f '%Y-%m-%dT%H:%M:%S' "${iso%Z}" '+%m-%d %H:%M' 2>/dev/null) || out=""
  [ -n "$out" ] && [ "$out" != "$iso" ] && { printf '%s' "$out"; return 0; }
  printf '%s' "$iso" | sed -n -E 's/^[0-9]{4}-([0-9]{2})-([0-9]{2})[T ]([0-9]{2}:[0-9]{2}).*/\1-\2 \3/p'
}

# desk_bar_class: the DaisyUI progress tone for a 0-100 runway percent. A
# non-numeric value is treated as the worst case so it can never read as full.
# ONE owner for the runway threshold, shared by the per-account table and the
# per-pane telemetry table so the two colorings never drift apart.
desk_bar_class() {  # <pct>
  case "$1" in
    ''|*[!0-9]*) printf 'progress-error' ;;
    *)
      if [ "$1" -ge 50 ]; then printf 'progress-success'
      elif [ "$1" -ge 20 ]; then printf 'progress-warning'
      else printf 'progress-error'; fi
      ;;
  esac
}

# --- per-pane telemetry: the CONSUMER half of the accounts panel (PR3) --------
# One row per LIVE worker pane, read from that pane's state/<id>.telemetry - the
# shared per-task artifact the visibility layer PRODUCES (bin/fm-telemetry-lib.sh)
# and this desk only CONSUMES. That file is plain key=value, the SAME shape as
# state/<id>.meta, so it is read with the same grep/tail/cut parser fm_meta_get
# uses, NOT as JSON. The design report sketched a JSON telemetry shape, but the
# producer that actually shipped writes key=value; the seam contract (the design's
# section 4) is that the consumer matches the producer, so this reads the real
# landed format. Keys consumed, all OPTIONAL: account, quota_pct, quota_window,
# quota_reset_ts, count_429, last_429_ts, composer_stuck, and read_ts for
# freshness. An absent key renders a gap dash, NEVER a confident zero. A live
# pane whose telemetry file is absent or carries no parseable key renders a gap
# row (no reading), never a fake-current line. NO live pane at all is a confident
# empty. The desk NEVER writes a telemetry file - it is strictly read-only over
# this input, so a build leaves every telemetry file byte-unchanged.
#
# Freshness: read_ts drives the record age when the producer writes it (an epoch
# or an ISO-8601 stamp); when read_ts is absent the file mtime is the fallback. A
# record older than TELEMETRY_MAX_AGE is marked stale, so an out-of-date pane
# reading is flagged rather than shown as current. FM_DESK_TELEMETRY_MAX_AGE
# overrides the bound (default 1800s, matching the desk's watcher-beat bound).
TELEMETRY_MAX_AGE=${FM_DESK_TELEMETRY_MAX_AGE:-1800}
case "$TELEMETRY_MAX_AGE" in ''|*[!0-9]*) TELEMETRY_MAX_AGE=1800 ;; esac

# desk_tel_get: the LAST value of key= in a telemetry file, or empty when the
# file or key is absent. Mirrors fm_meta_get (bin/fm-backend.sh) exactly, because
# key=value is the producer's format; no JSON parser is introduced.
desk_tel_get() {  # <telemetry-file> <key>
  local file=$1 key=$2
  [ -f "$file" ] || return 0
  grep "^$key=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# desk_tel_age: a telemetry record's age in whole seconds, preferring a read_ts
# key (an epoch, or an ISO-8601 stamp converted on either platform) and falling
# back to the file mtime. Prints nothing when neither resolves, so the caller
# shows a dash rather than a fabricated age.
desk_tel_age() {  # <telemetry-file>
  local file=$1 rt ts mt age
  [ -f "$file" ] || return 0
  rt=$(desk_tel_get "$file" read_ts)
  ts=""
  case "$rt" in
    '') ;;
    *[!0-9]*)
      ts=$(date -d "$rt" +%s 2>/dev/null \
        || date -j -f '%Y-%m-%dT%H:%M:%S' "${rt%Z}" +%s 2>/dev/null || printf '')
      ;;
    *) ts=$rt ;;
  esac
  if [ -z "$ts" ]; then
    mt=$(date -r "$file" +%s 2>/dev/null || printf '')
    ts=$mt
  fi
  case "$ts" in ''|*[!0-9]*) return 0 ;; esac
  age=$(( NOW_EPOCH - ts ))
  [ "$age" -lt 0 ] && age=0
  printf '%s' "$age"
}

# render_pane_telemetry: the per-pane attribution table, composed UNDER the
# per-account table inside the SAME sec-accounts section (never a duplicate of
# the per-account view). The row set is the live panes from the single fleet
# projection every other panel reads, so no new fleet read is added; each row's
# columns come from that pane's own state/<id>.telemetry file read.
render_pane_telemetry() {
  local rows st
  rows=$(desk_json '[.in_flight[] | select(.state != "done")][] | [.id, (.state|z)] | @tsv'); st=$?
  echo '    <h3 class="text-sm font-medium opacity-70 mt-6 mb-2">Per-pane attribution</h3>'
  echo '    <p class="text-xs opacity-60 mb-3">Which worker pane runs on which account, its runway at last reading, and its throttle flags. Read from each pane own telemetry record; a pane with no reading shows a gap, never a zero.</p>'
  if [ "$st" -ne 0 ]; then
    desk_section_gap "The list of worker panes could not be read, so per-pane attribution is unknown right now."
    return 0
  fi
  if [ -z "$rows" ]; then
    echo '    <p class="text-sm opacity-60">No worker panes are running right now.</p>'
    return 0
  fi
  echo '    <div class="overflow-x-auto">'
  echo '      <table class="table table-sm">'
  echo '        <thead><tr class="text-xs uppercase tracking-wide opacity-60">'
  echo '          <th class="w-48">Pane</th><th class="w-28">Account</th><th class="w-48">Runway</th><th class="w-32">Throttling</th><th class="w-24">Composer</th><th class="w-28">Reading</th>'
  echo '        </tr></thead>'
  echo '        <tbody>'
  printf '%s\n' "$rows" | while IFS=$'\t' read -r id state; do
    [ -n "$id" ] || continue
    : "$state"
    local tel has_any account pct c429 last429 stuck age
    local acct_cell run_cell throttle_cell composer_cell read_cell
    tel="$STATE/$id.telemetry"
    # A gap row: the telemetry file is absent OR carries no parseable key= line
    # (an unparseable record). Either way every data cell is a dash and the
    # reading cell is a visible "no reading" gap, never a confident zero.
    has_any=0
    if [ -f "$tel" ] && grep -qE '^[A-Za-z0-9_]+=' "$tel" 2>/dev/null; then
      has_any=1
    fi
    if [ "$has_any" -eq 0 ]; then
      cat <<HTML
          <tr>
            <td class="font-medium align-top">$(desk_title "$id")</td>
            <td class="align-top"><span class="opacity-50">-</span></td>
            <td class="align-top"><span class="opacity-50">-</span></td>
            <td class="align-top"><span class="opacity-50">-</span></td>
            <td class="align-top"><span class="opacity-50">-</span></td>
            <td class="align-top"><span class="badge badge-warning badge-xs">no reading</span></td>
          </tr>
HTML
      continue
    fi
    account=$(desk_tel_get "$tel" account)
    pct=$(desk_tel_get "$tel" quota_pct)
    c429=$(desk_tel_get "$tel" count_429)
    last429=$(desk_tel_get "$tel" last_429_ts)
    stuck=$(desk_tel_get "$tel" composer_stuck)
    age=$(desk_tel_age "$tel")
    # Account: a stable human label, or a dash when unknown.
    if [ -n "$account" ]; then
      acct_cell=$(desk_text "$account")
    else
      acct_cell='<span class="opacity-50">-</span>'
    fi
    # Runway: a bar ONLY for a numeric reading; absent stays a dash, never a
    # zero-value bar (the confident-zero failure mode this panel exists to avoid).
    case "$pct" in
      ''|*[!0-9]*) run_cell='<span class="opacity-50">-</span>' ;;
      *) run_cell="<div class=\"flex items-center gap-2\"><progress class=\"progress $(desk_bar_class "$pct") w-24\" value=\"${pct}\" max=\"100\"></progress><span class=\"text-sm\">${pct}% left</span></div>" ;;
    esac
    # Throttling: a 429 count over zero is the signal; an epoch last_429_ts adds
    # a clock. No 429s recorded is a muted dash, not an alarm.
    case "$c429" in
      ''|*[!0-9]*) throttle_cell='<span class="opacity-50">-</span>' ;;
      0) throttle_cell='<span class="opacity-50">-</span>' ;;
      *)
        local clk=''
        case "$last429" in
          ''|*[!0-9]*) : ;;
          *) clk=$(date -d "@$last429" '+%H:%M' 2>/dev/null || date -r "$last429" '+%H:%M' 2>/dev/null || printf '') ;;
        esac
        if [ -n "$clk" ]; then
          throttle_cell="<span class=\"badge badge-warning badge-sm\">${c429} &times; (last ${clk})</span>"
        else
          throttle_cell="<span class=\"badge badge-warning badge-sm\">${c429} &times;</span>"
        fi
        ;;
    esac
    # Composer-stuck: forward-compatible with the not-yet-built producer. true is
    # a warning, false is a muted ok, anything else (including absent) is a dash.
    case "$stuck" in
      true|True|TRUE|1) composer_cell='<span class="badge badge-warning badge-sm">stuck</span>' ;;
      false|False|FALSE|0) composer_cell='<span class="opacity-60 text-sm">ok</span>' ;;
      *) composer_cell='<span class="opacity-50">-</span>' ;;
    esac
    # Reading freshness: a record older than the bound is marked stale so it is
    # never mistaken for current; a fresh record shows its age; no age is a dash.
    if [ -n "$age" ]; then
      if [ "$age" -gt "$TELEMETRY_MAX_AGE" ]; then
        read_cell="<span class=\"badge badge-warning badge-xs\">stale (${age}s ago)</span>"
      else
        read_cell="<span class=\"opacity-60\">${age}s ago</span>"
      fi
    else
      read_cell='<span class="opacity-50">-</span>'
    fi
    cat <<HTML
          <tr>
            <td class="font-medium align-top">$(desk_title "$id")</td>
            <td class="align-top text-sm">${acct_cell}</td>
            <td class="align-top">${run_cell}</td>
            <td class="align-top">${throttle_cell}</td>
            <td class="align-top">${composer_cell}</td>
            <td class="align-top">${read_cell}</td>
          </tr>
HTML
  done
  echo '        </tbody>'
  echo '      </table>'
  echo '    </div>'
}

render_accounts() {
  local rows st runway win projected reset status label bar_cls
  echo '  <section id="sec-accounts" class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">Accounts and quota</h2>'
  if [ "$QUOTA_PRESENT" -ne 1 ]; then
    desk_section_gap "The account quota report could not be read, so runway figures are unknown right now."
  else
    rows=$(printf '%s' "$QUOTA" | jq -r "$DESK_JQ_PRELUDE"'
      .providers[] | . as $p |
        (if ($p.windows | length) > 0 then ($p.windows | min_by(.percentRemaining // 101)) else null end) as $bind |
        [
          ($p.label | z),
          (if $bind and ($bind.percentRemaining != null) then ($bind.percentRemaining | tostring) else "-" end),
          (if $bind then ($bind.label | z) else "-" end),
          (if $bind then (($bind.resetsAt // "-") | tostring) else "-" end),
          (if $bind then (((($bind.pace // {}) | .projectedExhaustedAt) // "-") | tostring) else "-" end),
          (((($p.state.status // "") | z)) | if . == "" then "-" else . end)
        ] | @tsv'); st=$?
    if [ "$st" -ne 0 ]; then
      desk_section_gap "The account quota report could not be read, so runway figures are unknown right now."
    elif [ -z "$rows" ]; then
      echo '    <p class="text-sm opacity-60">No account readings are available right now.</p>'
    else
      echo '    <p class="text-sm opacity-70 mb-3">Runway is the lowest percent left across the quota windows of an account; the window shown is the binding one. A throttling account cuts off work on this machine early, so the lowest runway is the headline above.</p>'
      echo '    <div class="overflow-x-auto">'
      echo '      <table class="table table-sm">'
      echo '        <thead><tr class="text-xs uppercase tracking-wide opacity-60">'
      echo '          <th class="w-48">Account</th><th class="w-48">Runway</th><th class="w-20">Window</th><th class="w-36">Runs dry</th><th class="w-36">Resets</th><th class="w-32">Reading</th>'
      echo '        </tr></thead>'
      echo '        <tbody>'
      printf '%s\n' "$rows" | while IFS=$'\t' read -r label runway win reset projected status; do
        [ -n "$label" ] || continue
        if [ -n "$runway" ] && [ "$runway" != "-" ]; then
          bar_cls=$(desk_bar_class "$runway")
          runway="<div class=\"flex items-center gap-2\"><progress class=\"progress ${bar_cls} w-24\" value=\"${runway}\" max=\"100\"></progress><span class=\"text-sm font-medium\">${runway}% left</span></div>"
        else
          runway='<span class="opacity-50">-</span>'
        fi
        if [ -n "$projected" ] && [ "$projected" != "-" ]; then
          projected="$(desk_iso_time "$projected")"
        else
          projected='<span class="opacity-50">-</span>'
        fi
        if [ -n "$reset" ] && [ "$reset" != "-" ]; then
          reset="$(desk_iso_time "$reset")"
        else
          reset='<span class="opacity-50">-</span>'
        fi
        [ -n "$win" ] && [ "$win" != "-" ] || win='-'
        if [ -n "$status" ] && [ "$status" != "-" ]; then
          status="$(desk_quota_status "$status")"
        else
          status='no reading'
        fi
        cat <<HTML
          <tr>
            <td class="font-medium align-top">$(desk_text "$label")</td>
            <td class="align-top">${runway}</td>
            <td class="text-sm opacity-70 align-top">$(desk_text "$win")</td>
            <td class="text-sm align-top">${projected}</td>
            <td class="text-sm align-top">${reset}</td>
            <td class="text-sm align-top">$(desk_text "$status")</td>
          </tr>
HTML
      done
      echo '        </tbody>'
      echo '      </table>'
      echo '    </div>'
    fi
  fi
  # The per-pane attribution half (PR3): now a real table read from each live
  # pane's state/<id>.telemetry, composed UNDER the per-account table rather than
  # duplicating it. render_pane_telemetry owns that half and fails closed.
  render_pane_telemetry
  echo '  </section>'
}

# --- section 8: captain-held tickets (full list) ----------------------------
# The complete captain-held list - every captain hold, a superset of the
# urgent decisions in section 1 and the captain's call panel. Read straight from
# the backlog through tasks-axi so it is durable, never scraped from prose.
# Degrades to a gap when tasks-axi cannot be read.
render_captain_held() {
  local rows
  echo '  <section id="sec-held" class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">8. Captain-held tickets</h2>'
  if ! command -v tasks-axi >/dev/null 2>&1; then
    desk_section_gap "The backlog could not be read, so the full captain-hold list is unknown right now."
    echo '  </section>'
    return 0
  fi
  # Held rows whose hold_kind is captain, id first and hold_kind last (positional
  # take is comma-safe as in collect_tickets).
  rows=$(tasks_rows list --state held --limit 100000 --fields hold_kind \
    | awk '$3 == "captain" {print $1}')
  if [ -z "$rows" ]; then
    echo '    <p class="text-sm opacity-60">You are holding nothing right now.</p>'
    echo '  </section>'
    return 0
  fi
  echo '    <div class="grid gap-2 md:grid-cols-2">'
  printf '%s\n' "$rows" | while IFS= read -r id; do
    [ -n "$id" ] || continue
    local money=''
    desk_is_money "$id" && money='<span class="badge badge-error badge-xs shrink-0">money</span>'
    cat <<HTML
      <div class="card bg-base-200/60">
        <div class="card-body py-3 gap-1">
          <div class="flex items-start justify-between gap-2">
            <h3 class="font-medium text-sm">$(desk_title "$id")</h3>
            ${money}
          </div>
          <p class="text-sm opacity-70">$(desk_full_title "$id" "$id")</p>
          <p class="text-xs opacity-50">$(desk_full_reason "$id" "-")</p>
        </div>
      </div>
HTML
  done
  echo '    </div>'
  echo '  </section>'
}

# --- section 3: ready to merge ----------------------------------------------
# Full compare URLs grouped BY REPO, each with green/red CI state and a money
# flag. The merge-queue rows carry an id, project path, branch, head, base, and
# compare URL. CI state is derived from a cheap gh-axi check, but only when a
# forge tool is present AND the whole section stays inside the wall-clock bound:
# a network probe on the hot path would break the "costs milliseconds" contract,
# so it is guarded hard and the branch renders without a CI badge (noted) when
# the check is unavailable or times out.
DESK_CI_BUDGET=${FM_DESK_CI_BUDGET:-20}
case "$DESK_CI_BUDGET" in ''|*[!0-9]*) DESK_CI_BUDGET=20 ;; esac

# desk_ci_state: print green/red/unknown for one compare URL's head branch. Uses
# gh-axi only when present and only within a tight per-call bound. Any failure
# yields "unknown" so the section never blocks on the network.
desk_ci_state() {  # <repo-slug-url> <head>
  local url="$1" head="$2" slug out
  command -v gh-axi >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  [ -n "$head" ] || { printf 'unknown'; return 0; }
  # Extract owner/repo from a github compare URL; anything else is unknown.
  slug=$(printf '%s' "$url" | sed -n -E 's#https?://github.com/([^/]+/[^/]+)/compare/.*#\1#p')
  [ -n "$slug" ] || { printf 'unknown'; return 0; }
  out=$("$DESK_TIMEOUT_BIN" "${DESK_TIMEOUT_BIN:+$DESK_CI_BUDGET}" gh-axi api \
    "repos/$slug/commits/$head/status" --jq '.state' 2>/dev/null) || { printf 'unknown'; return 0; }
  case "$out" in
    success) printf 'green' ;;
    failure|error) printf 'red' ;;
    *) printf 'unknown' ;;
  esac
}

render_ready_merge() {
  local count start_epoch elapsed do_ci
  count=0
  [ -n "$MERGEQ" ] && count=$(printf '%s\n' "$MERGEQ" | grep -c .)
  echo '  <section id="sec-merge" class="mb-10">'
  if [ "${count:-0}" -eq 0 ]; then
    echo '    <h2 class="text-lg font-semibold mb-3">3. Ready to merge</h2>'
    echo '    <p class="text-sm opacity-60">Nothing is waiting to merge.</p>'
    echo '  </section>'
    return 0
  fi
  cat <<HTML
    <h2 class="text-lg font-semibold mb-3 flex items-center gap-2">
      3. Ready to merge
      <span class="badge badge-neutral badge-sm">${count}</span>
    </h2>
    <p class="text-sm opacity-70 mb-3">All pushed and safe, grouped by repository. Review whenever you want them.</p>
HTML
  # Derive a repo label from the project path's basename and group rows under it.
  # CI state is checked only while the section-wide budget holds.
  start_epoch=$(date +%s)
  do_ci=1
  [ -n "$DESK_TIMEOUT_BIN" ] || do_ci=0
  printf '%s\n' "$MERGEQ" \
    | while IFS=$'\t' read -r id project branch head base url; do
        [ -n "$id" ] || continue
        : "$base"
        repo=$(basename "$project" 2>/dev/null); [ -n "$repo" ] || repo="(unknown repo)"
        printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$id" "$head" "$url" "$branch"
      done \
    | sort -t"$(printf '\t')" -k1,1 \
    | {
        cur=""
        while IFS=$'\t' read -r repo id head url branch; do
          [ -n "$repo" ] || continue
          if [ "$repo" != "$cur" ]; then
            [ -n "$cur" ] && echo '    </div>'
            cur="$repo"
            printf '    <h3 class="font-medium text-sm mt-4 mb-2 opacity-80">%s</h3>\n' "$(desk_esc <<<"$repo")"
            echo '    <div class="grid gap-2 sm:grid-cols-2">'
          fi
          # CI state, guarded by the elapsed budget.
          ci="unknown"
          if [ "$do_ci" -eq 1 ]; then
            elapsed=$(( $(date +%s) - start_epoch ))
            if [ "$elapsed" -lt "$DESK_CI_BUDGET" ]; then
              ci=$(desk_ci_state "$url" "$head")
            fi
          fi
          case "$ci" in
            green) badge='<span class="badge badge-success badge-xs">CI green</span>' ;;
            red) badge='<span class="badge badge-error badge-xs">CI red</span>' ;;
            *) badge='<span class="badge badge-ghost badge-xs">CI unknown</span>' ;;
          esac
          money=''
          desk_is_money "$id $branch" && money='<span class="badge badge-error badge-xs">money</span>'
          if [ -n "$url" ]; then
            printf '      <div class="flex items-center gap-2 flex-wrap"><a class="link link-hover text-sm" href="%s">%s</a>%s%s</div>\n' \
              "$(desk_esc <<<"$url")" "$(desk_title "$id")" "$badge" "$money"
          else
            printf '      <div class="flex items-center gap-2 flex-wrap"><span class="text-sm opacity-70">%s</span>%s%s</div>\n' \
              "$(desk_title "$id")" "$badge" "$money"
          fi
        done
        [ -n "$cur" ] && echo '    </div>'
      }
  echo '  </section>'
}

# render_machine_card: the host reading as a bare card (no section wrapper), so
# section 4 can place it under its own heading alongside the per-slot list.
render_machine_card() {
  local avail total swap agents ceiling level tone prose
  avail=$(printf '%s' "$RES_LINE" | sed -n -E 's/.*avail ([0-9]+) MB of ([0-9]+) GB.*/\1/p')
  total=$(printf '%s' "$RES_LINE" | sed -n -E 's/.*avail ([0-9]+) MB of ([0-9]+) GB.*/\2/p')
  swap=$(printf '%s' "$RES_LINE" | sed -n -E 's/.*swap ([0-9]+)%.*/\1/p')
  agents=$(printf '%s' "$RES_LINE" | sed -n -E 's/.*live agents ([0-9]+).*/\1/p')
  ceiling=$(printf '%s' "$RES_LINE" | sed -n -E 's/.*recommended ceiling ([0-9]+).*/\1/p')
  level=${RES_LEVEL:-$(printf '%s' "$RES_LINE" | sed -n -E 's/^resources: ([a-z]+).*/\1/p')}
  case "$level" in
    critical) tone="text-error"; prose="More is running than this machine comfortably carries; everything feels slow because of it." ;;
    degraded) tone="text-warning"; prose="This machine is getting tight. Nothing has misbehaved; it is simply carrying a lot." ;;
    healthy) tone="text-success"; prose="This machine has room to spare." ;;
    *) tone=""; prose="No clear reading of this machine was available." ;;
  esac

  echo '    <div class="card bg-base-200"><div class="card-body gap-3">'
  echo '      <div class="grid gap-4 sm:grid-cols-3">'
  if [ -n "$avail" ]; then
    printf '        <div><div class="text-xs uppercase tracking-wide opacity-60">Memory free</div><div class="text-2xl font-semibold">%s <span class="text-base opacity-60">MB of %s GB</span></div></div>\n' \
      "$(desk_esc <<<"$avail")" "$(desk_esc <<<"$total")"
  fi
  if [ -n "$swap" ]; then
    printf '        <div><div class="text-xs uppercase tracking-wide opacity-60">Swap in use</div><div class="text-2xl font-semibold %s">%s<span class="text-base opacity-60">%%</span></div></div>\n' \
      "$tone" "$(desk_esc <<<"$swap")"
  fi
  if [ -n "$agents" ]; then
    printf '        <div><div class="text-xs uppercase tracking-wide opacity-60">Workers</div><div class="text-2xl font-semibold">%s <span class="text-base opacity-60">/ %s comfortable</span></div></div>\n' \
      "$(desk_esc <<<"$agents")" "$(desk_esc <<<"${ceiling:-?}")"
  fi
  echo '      </div>'
  printf '      <p class="text-sm opacity-70">%s</p>\n' "$(desk_text "$prose")"
  echo '    </div></div>'
}

# --- sections 5 and 6: progress windows -------------------------------------
# The completion ledger records a completion DATE, not an hour, so an hour-scale
# window is honestly reported by the calendar days it spans and the page says so
# rather than implying a precision the source does not carry. Each window counts
# completions whose date falls on or after the window's start day and summarizes
# throughput by repo. Degrades to a gap when the ledger is unreadable.
#
# desk_progress_window <label> <days-back> : render one progress card. days-back
# is 0 for "today" (the 3h window's calendar day) and 1 for "today and
# yesterday" (the 12h window may span a day boundary).
desk_progress_window() {  # <heading> <intro> <start-yyyy-mm-dd>
  local heading="$1" intro="$2" start="$3" rows total by_repo
  printf '    <h2 class="text-lg font-semibold mb-1">%s</h2>\n' "$(desk_esc <<<"$heading")"
  printf '    <p class="text-sm opacity-60 mb-3">%s</p>\n' "$(desk_esc <<<"$intro")"
  if [ ! -f "$COMPLETIONS" ]; then
    desk_section_gap "The completion record could not be read, so this progress window is unknown right now."
    return 0
  fi
  # Data lines: <id>\t<date>\t<kind>\t<repo>\t<sha>. Filter date >= start.
  rows=$(awk -F'\t' -v s="$start" '/^#/ {next} NF>=4 && $2 >= s {print}' "$COMPLETIONS" 2>/dev/null)
  total=$(printf '%s\n' "$rows" | awk 'NF{n++} END{print n+0}')
  if [ "$total" -eq 0 ]; then
    echo '    <p class="text-sm opacity-60">Nothing has landed in this window.</p>'
    return 0
  fi
  by_repo=$(printf '%s\n' "$rows" | awk -F'\t' 'NF>=4{c[$4]++} END{for(r in c) printf "%s\t%d\n", r, c[r]}' | sort -t"$(printf '\t')" -k2,2 -rn -k1,1)
  printf '    <p class="text-sm opacity-80 mb-2"><strong>%s</strong> landed.</p>\n' "$total"
  echo '    <ul class="text-sm space-y-1">'
  printf '%s\n' "$by_repo" | while IFS=$'\t' read -r repo n; do
    [ -n "$repo" ] || continue
    printf '      <li class="flex justify-between gap-3"><span>%s</span><span class="opacity-60">%s</span></li>\n' \
      "$(desk_esc <<<"$repo")" "$n"
  done
  echo '    </ul>'
}

render_progress_3h() {
  local start
  start=$(date -d "@$NOW_EPOCH" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
  echo '  <section id="sec-progress-3h" class="mb-10">'
  desk_progress_window "5. Progress - last 3 hours" \
    "The completion record is dated by day, so this counts what landed today (the last-3-hours calendar day)." \
    "$start"
  echo '  </section>'
}

render_progress_12h() {
  local start
  start=$(date -d "@$(( NOW_EPOCH - 86400 ))" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
  echo '  <section id="sec-progress-12h" class="mb-10">'
  desk_progress_window "6. Progress - last 12 hours" \
    "Wider window: what landed today and yesterday, since the record is dated by day and 12 hours can span a day boundary." \
    "$start"
  echo '  </section>'
}

# --- section 7: most important upcoming progress ----------------------------
# Forward look: what is about to land (branches waiting to merge), what firstmate
# is watching (recorded PRs), and the next dispatch intentions (the top of the
# ready queue). All read from projections already collected, so it adds no cost.
render_upcoming() {
  local about landing watching next
  echo '  <section id="sec-upcoming" class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">7. Most important upcoming progress</h2>'
  echo '    <div class="grid gap-4 md:grid-cols-3">'
  # About to land: the merge queue count.
  about=0
  [ -n "$MERGEQ" ] && about=$(printf '%s\n' "$MERGEQ" | grep -c .)
  landing="Nothing is queued to merge."
  [ "${about:-0}" -gt 0 ] && landing="${about} finished branch(es) are ready to land."
  printf '      <div class="card bg-base-200/60"><div class="card-body py-4 gap-1"><h3 class="font-medium text-sm">About to land</h3><p class="text-sm opacity-70">%s</p></div></div>\n' \
    "$(desk_text "$landing")"
  # Watching: recorded PRs from the snapshot.
  watching=$(desk_json '.recorded_prs | length' 2>/dev/null)
  case "${watching:-0}" in
    ''|0) watching="No open pull requests are being watched." ;;
    1) watching="One pull request is being watched for its checks." ;;
    *) watching="${watching} pull requests are being watched for their checks." ;;
  esac
  printf '      <div class="card bg-base-200/60"><div class="card-body py-4 gap-1"><h3 class="font-medium text-sm">Watching</h3><p class="text-sm opacity-70">%s</p></div></div>\n' \
    "$(desk_text "$watching")"
  # Next dispatch: top ready-to-start queued item, if the backlog can be read.
  next="No further ready work is queued to start."
  if command -v tasks-axi >/dev/null 2>&1; then
    local top
    top=$(tasks_rows list --state queued --limit 100000 | awk '{print $1; exit}')
    [ -n "$top" ] && next="Next up to dispatch: $(printf '%s' "$top" | tr '_-' '  ')."
  fi
  printf '      <div class="card bg-base-200/60"><div class="card-body py-4 gap-1"><h3 class="font-medium text-sm">Next dispatch</h3><p class="text-sm opacity-70">%s</p></div></div>\n' \
    "$(desk_text "$next")"
  echo '    </div>'
  echo '  </section>'
}

# --- section 9: four categorized top-10 queue lists -------------------------
# Four separate ranked cards drawn from the LIVE backlog: product ship, product
# scout, tooling, and quick/cheap wins. Held or blocked tickets are excluded.
# Ranking uses tasks-axi priority (lower number is higher value). Each entry:
# id, repo, kind tag, one-line why. Degrades to a gap when the backlog is
# unreadable.
DESK_PRODUCT_REPOS='hyfin hyfin-server integration-server'
DESK_TOOLING_REPOS='firstmate no-mistakes herdr jcode claude-swap tasks-axi'

# desk_queue_rows: dispatchable queued rows as "<pri>\t<id>\t<repo>\t<kind>",
# excluding held and dependency-blocked items, sorted by priority ascending.
desk_queue_rows() {
  # tasks-axi list default fields are id,state,kind,repo,priority,title. Take the
  # first five comma-safe leading fields (title is last and may hold commas).
  (cd "$FM_HOME" 2>/dev/null && desk_bound tasks-axi list --state queued --limit 100000 --fields priority 2>/dev/null) \
    | awk -F, '
        /^  [^ ]/ {
          id=$1; sub(/^ +/,"",id);
          kind=$3; repo=$4; pri=$5;
          gsub(/^ +| +$/,"",pri); gsub(/"/,"",repo);
          if (pri=="" || pri !~ /^[0-9]+$/) pri=5;
          print pri "\t" id "\t" repo "\t" kind
        }'
}

# desk_top10_card: render one ranked card. <title> <intro> then rows on stdin.
desk_top10_card() {  # <title> <intro>
  local title="$1" intro="$2" any=0 line pri id repo kind
  printf '      <div class="card bg-base-200"><div class="card-body gap-2">\n'
  printf '        <h3 class="font-semibold text-sm">%s</h3>\n' "$(desk_esc <<<"$title")"
  printf '        <p class="text-xs opacity-50">%s</p>\n' "$(desk_esc <<<"$intro")"
  echo '        <ul class="text-sm space-y-1">'
  while IFS=$'\t' read -r pri id repo kind; do
    [ -n "$id" ] || continue
    : "$pri"
    any=1
    [ "$repo" = "-" ] || [ -z "$repo" ] && repo="?"
    line=$(desk_show_field "$id" title)
    [ -n "$line" ] || line="$id"
    printf '          <li><span class="font-medium">%s</span> <span class="badge badge-ghost badge-xs">%s</span> <span class="opacity-50 text-xs">%s</span><br><span class="opacity-70 text-xs">%s</span></li>\n' \
      "$(desk_title "$id")" "$(desk_esc <<<"$kind")" "$(desk_esc <<<"$repo")" "$(printf '%s' "$line" | desk_plain | desk_esc)"
  done
  [ "$any" -eq 0 ] && echo '          <li class="opacity-50">Nothing queued in this category.</li>'
  echo '        </ul>'
  echo '      </div></div>'
}

render_queue_lists() {
  echo '  <section id="sec-queue" class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">9. Next queue tickets</h2>'
  if ! command -v tasks-axi >/dev/null 2>&1; then
    desk_section_gap "The backlog could not be read, so the ranked queue lists are unknown right now."
    echo '  </section>'
    return 0
  fi
  local rows
  rows=$(desk_queue_rows | sort -t"$(printf '\t')" -k1,1n)
  echo '    <div class="grid gap-4 md:grid-cols-2">'
  # Product ship: product repos, kind ship.
  printf '%s\n' "$rows" | awk -F'\t' -v R=" $DESK_PRODUCT_REPOS " '{if (index(R," "$3" ")>0 && $4=="ship") print}' | head -10 \
    | desk_top10_card "Top product ship" "Product changes, highest value first."
  # Product scout.
  printf '%s\n' "$rows" | awk -F'\t' -v R=" $DESK_PRODUCT_REPOS " '{if (index(R," "$3" ")>0 && $4=="scout") print}' | head -10 \
    | desk_top10_card "Top product scout" "Product investigation and audit, most-unblocking first."
  # Tooling.
  printf '%s\n' "$rows" | awk -F'\t' -v R=" $DESK_TOOLING_REPOS " '{if (index(R," "$3" ")>0) print}' | head -10 \
    | desk_top10_card "Top tooling" "Fleet-tooling work, highest leverage first."
  # Quick wins: highest priority across all repos regardless of category.
  printf '%s\n' "$rows" | head -10 \
    | desk_top10_card "Quick and cheap wins" "Highest value-to-effort across every repo."
  echo '    </div>'
  echo '  </section>'
}

# --- section 10: stats ------------------------------------------------------
# Ambient closing stats from durable local records: worker efficiency (landed vs
# spawned this window), oldest-unmerged-branch presence, and a per-repo landed
# breakdown from the completion ledger. Token burn is not recorded locally to
# this read-only builder, so it is named as a courtesy gap rather than invented.
render_stats() {
  echo '  <section id="sec-stats" class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">10. Stats</h2>'
  echo '    <div class="grid gap-4 sm:grid-cols-2">'
  # Landed today by repo (reuses the ledger).
  if [ -f "$COMPLETIONS" ]; then
    local today total per
    today=$(date -d "@$NOW_EPOCH" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
    total=$(awk -F'\t' -v s="$today" '/^#/ {next} NF>=4 && $2 >= s {n++} END{print n+0}' "$COMPLETIONS")
    per=$(awk -F'\t' -v s="$today" '/^#/ {next} NF>=4 && $2 >= s {c[$4]++} END{for(r in c) print r" ("c[r]")"}' "$COMPLETIONS" | sort | tr '\n' ' ')
    printf '      <div class="card bg-base-200/60"><div class="card-body py-4 gap-1"><h3 class="font-medium text-sm">Landed today</h3><p class="text-2xl font-semibold">%s</p><p class="text-xs opacity-60">%s</p></div></div>\n' \
      "$total" "$(desk_esc <<<"${per:-none}")"
  else
    desk_section_gap "The completion record could not be read, so the landed-work stats are unknown."
  fi
  # Waiting to merge + oldest.
  local wait
  wait=0
  [ -n "$MERGEQ" ] && wait=$(printf '%s\n' "$MERGEQ" | grep -c .)
  printf '      <div class="card bg-base-200/60"><div class="card-body py-4 gap-1"><h3 class="font-medium text-sm">Waiting to merge</h3><p class="text-2xl font-semibold">%s</p><p class="text-xs opacity-60">finished branches not yet landed</p></div></div>\n' \
    "$wait"
  echo '    </div>'
  echo '    <p class="text-xs opacity-50 mt-3">Token burn this window is not recorded locally to this page, so it is not shown; ask for it in chat if you want a courtesy figure.</p>'
  echo '  </section>'
}

# --- sections 11 and 12: reference catch-up panels --------------------------
# Both are transcript-sourced by design (the sole deliberate exception to the
# never-scraped-chat rule). Their PRIMARY source is the durable transcript feed
# (state/desk-transcript.jsonl, owned by bin/fm-desk-transcript.sh) the running
# session publishes; the judgment file's questions/transcript arrays are the
# FALLBACK when the feed is empty. This read-only builder only renders them.
# When neither source supplies a panel - both absent, empty, stale, or every
# line unparseable - each panel degrades to EXACTLY today's gap note and the
# catch-up note below explains why, so there is no regression.

# desk_has_1112: 0/1 whether ANY source (the durable feed OR a fresh judgment)
# supplied section 11 or 12 content. Drives suppression of the explanatory note,
# which is only meaningful while NO source has published a panel yet. The durable
# feed (bin/fm-desk-transcript.sh) is now the primary source, so once it or the
# judgment file yields a panel the note no longer applies.
desk_has_1112() {
  if [ "$FEED_PRESENT" -eq 1 ]; then printf '1'; return 0; fi
  [ "$JUDGMENT_PRESENT" -eq 1 ] || { printf '0'; return 0; }
  local q t
  q=$(desk_judgment_field '.questions | length'); [ -n "$q" ] || q=0
  t=$(desk_judgment_field '.transcript | length'); [ -n "$t" ] || t=0
  if [ "${q:-0}" -gt 0 ] || [ "${t:-0}" -gt 0 ]; then printf '1'; else printf '0'; fi
}

render_recent_questions() {
  local rows
  echo '  <section id="sec-questions" class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">11. Recent questions</h2>'
  # Source precedence (owned by the durable-transcript-feed block above): the
  # durable feed is primary, the judgment file is the fallback. Never both, so a
  # question is never double-rendered.
  rows=""
  if [ "$FEED_PRESENT" -eq 1 ] && [ -n "$FEED_QUESTIONS" ]; then
    rows="$FEED_QUESTIONS"
  elif [ "$JUDGMENT_PRESENT" -eq 1 ]; then
    rows=$(printf '%s' "$JUDGMENT" | jq -r "$DESK_JQ_PRELUDE"'.questions[]? | [((.q // "")|z), ((.a // "")|z)] | @tsv' 2>/dev/null)
  fi
  if [ -z "$rows" ]; then
    desk_section_gap "Your recent questions and their short answers are not available: this page has no local transcript source to read them from. See the note below on wiring one."
    echo '  </section>'
    return 0
  fi
  echo '    <ul class="space-y-3">'
  printf '%s\n' "$rows" | while IFS=$'\t' read -r q a; do
    [ -n "$q" ] || continue
    printf '      <li class="card bg-base-200"><div class="card-body py-3 gap-1">\n'
    printf '        <p class="text-sm font-medium">%s</p>\n' "$(desk_text "$q")"
    if [ -n "$a" ]; then
      printf '        <p class="text-sm opacity-70">%s</p>\n' "$(desk_text "$a")"
    else
      printf '        <p class="text-xs opacity-40">Not answered yet.</p>\n'
    fi
    printf '      </div></li>\n'
  done
  echo '    </ul>'
  echo '  </section>'
}

render_recent_conversation() {
  local rows
  echo '  <section id="sec-conversation" class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">12. Recent conversation</h2>'
  # Source precedence (owned by the durable-transcript-feed block above): the
  # durable feed is primary, the judgment file is the fallback. Never both, so a
  # turn is never double-rendered. Both sources present rows newest-FIRST here.
  rows=""
  if [ "$FEED_PRESENT" -eq 1 ] && [ -n "$FEED_TRANSCRIPT" ]; then
    # The feed loader already reversed the stored oldest-first turns to
    # newest-first, matching the judgment path's on-page order.
    rows="$FEED_TRANSCRIPT"
  elif [ "$JUDGMENT_PRESENT" -eq 1 ]; then
    # Newest LAST in the array, newest FIRST on the page: reverse, then emit
    # who / unread / text per turn.
    rows=$(printf '%s' "$JUDGMENT" | jq -r "$DESK_JQ_PRELUDE"'.transcript | reverse[]? | [((.who // "")|z), (if .unread == true then "1" else "0" end), ((.text // "")|z)] | @tsv' 2>/dev/null)
  fi
  if [ -z "$rows" ]; then
    desk_section_gap "The last ten exchanges are not available: this page has no local transcript source to read the live session from. This panel is transcript-sourced by design, so it needs a source hook the builder does not yet have. See the note below."
    echo '  </section>'
    return 0
  fi
  echo '    <div class="space-y-2">'
  printf '%s\n' "$rows" | while IFS=$'\t' read -r who unread text; do
    [ -n "$who" ] || [ -n "$text" ] || continue
    local who_label rail
    case "$who" in
      captain) who_label="You" ;;
      firstmate) who_label="Firstmate" ;;
      *) who_label="$who" ;;
    esac
    # An unread turn carries the spec's orange left-border (#eb760f).
    if [ "$unread" = "1" ]; then
      rail=' rail" style="--rail: #eb760f'
    else
      rail=''
    fi
    # ~3-line collapse: a <details> so a long turn expands with no JavaScript,
    # which works over the LAN. The summary shows the speaker and a lead-in.
    local lead
    lead=$(printf '%s' "$text" | cut -c1-140)
    cat <<HTML
      <details class="card bg-base-200${rail}">
        <summary class="card-body py-2 cursor-pointer list-none">
          <span class="text-xs uppercase tracking-wide opacity-50">$(desk_esc <<<"$who_label")</span>
          <span class="text-sm opacity-80">$(desk_text "$lead")</span>
        </summary>
        <div class="px-4 pb-3 text-sm opacity-80">$(desk_text "$text")</div>
      </details>
HTML
  done
  echo '    </div>'
  echo '  </section>'
}

# render_transcript_note: the single visible note explaining WHY sections 11 and
# 12 are currently empty. The source hook now EXISTS - bin/fm-desk-transcript.sh
# is the durable feed the running session publishes to, and the judgment file is
# the fallback - so the note no longer claims the source is unwired. It explains
# that no turns have been published yet, and is SUPPRESSED the moment either
# source supplies a panel. There is no terminal needs-decision line anymore: an
# empty catch-up panel is a "nothing published yet" state, not a human decision.
TRANSCRIPT_HOOK_NOTE='These two catch-up panels read from a durable transcript feed the running session publishes (state/desk-transcript.jsonl, written by bin/fm-desk-transcript.sh), with the /desk analysis pass as a fallback. They are empty here because no recent turns or questions have been published to either source yet, not because the source is missing. They fill in as the session records captain-facing turns.'
render_transcript_note() {
  [ "$(desk_has_1112)" = "1" ] && return 0
  printf '  <div class="alert alert-info mb-8 text-sm block"><div><strong>About the two catch-up panels.</strong> %s</div></div>\n' \
    "$(desk_esc <<<"$TRANSCRIPT_HOOK_NOTE")"
}

# --- sticky KPI strip -------------------------------------------------------
# Pinned to the top on scroll (position: sticky) so the headline counts survive
# on a phone over the LAN. Carries the KPI counts and jump links to every
# section, calling out sections 11 and 12 as the spec requires. A count the
# projection could not supply is shown as a dash, never a confident zero.
render_sticky_strip() {
  local decisions decisions_st unmerged blockers held quota_cls quota_headline
  decisions=$(desk_json '.decisions_open | length'); decisions_st=$?
  blockers=$(desk_json '[.in_flight[] | select(.state == "blocked" or .state == "failed")] | length')
  unmerged=0; [ -n "$MERGEQ" ] && unmerged=$(printf '%s\n' "$MERGEQ" | grep -c .)
  if [ "$TICKETS_OK" -eq 1 ]; then held=$TK_CAPTAIN; else held='&mdash;'; fi
  [ "$decisions_st" -eq 0 ] || decisions='&mdash;'
  # Active workers / free slots / ceiling from the host reading.
  local agents ceiling free
  agents=$(printf '%s' "$RES_LINE" | sed -n -E 's/.*live agents ([0-9]+).*/\1/p')
  ceiling=$(printf '%s' "$RES_LINE" | sed -n -E 's/.*recommended ceiling ([0-9]+).*/\1/p')
  if [ -n "$agents" ] && [ -n "$ceiling" ]; then
    free=$(( ceiling - agents )); [ "$free" -lt 0 ] && free=0
  else
    free='&mdash;'
  fi
  [ -n "$agents" ] || agents='&mdash;'
  [ -n "$ceiling" ] || ceiling='&mdash;'
  # The lowest-runway headline: the account whose binding window is closest to
  # exhausting is the account that throttles this machine first. Unknown (absent
  # report or no account with a reading) renders "unknown", never a confident
  # zero runway.
  quota_cls='opacity-60'
  quota_headline='unknown'
  if [ "$QUOTA_PRESENT" -eq 1 ]; then
    local qh qlabel qrun
    qh=$(printf '%s' "$QUOTA" | jq -r "$DESK_JQ_PRELUDE"'
      [ .providers[] | . as $p | [ .windows[] | select(.percentRemaining != null) ] | select(length > 0) | [ ($p.label | z), (min_by(.percentRemaining) | .percentRemaining) ] ]
      | min_by(.[1]) | @tsv' 2>/dev/null)
    qlabel=$(printf '%s' "$qh" | cut -f1)
    qrun=$(printf '%s' "$qh" | cut -f2)
    if [ -n "$qlabel" ] && [ -n "$qrun" ] && printf '%s' "$qrun" | grep -q '^[0-9][0-9]*$'; then
      if [ "$qrun" -ge 50 ]; then quota_cls='text-success'
      elif [ "$qrun" -ge 20 ]; then quota_cls='text-warning'
      else quota_cls='text-error'; fi
      quota_headline="${qlabel} ${qrun}%"
    fi
  fi
  cat <<HTML
  <div class="sticky top-0 z-30 -mx-5 px-5 py-3 mb-8 bg-base-100/95 backdrop-blur border-b border-base-300">
    <div class="flex flex-wrap items-center gap-x-5 gap-y-1 text-sm">
      <span><strong class="text-warning">${decisions}</strong> need your word</span>
      <span><strong>${unmerged}</strong> ready to merge</span>
      <span><strong>${agents}</strong> working &middot; <strong>${free}</strong> free &middot; ceiling ${ceiling}</span>
      <span><strong class="text-error">${blockers}</strong> blocked or failed</span>
      <span><strong>${held}</strong> on hold by you</span>
      <span>lowest runway: <strong class="${quota_cls}">${quota_headline}</strong></span>
    </div>
    <nav class="flex flex-wrap gap-x-3 gap-y-1 text-xs mt-2 opacity-70">
      <a class="link link-hover font-medium text-warning" href="#sec-captains-call">Captain's call</a>
      <a class="link link-hover" href="#sec-decisions">1 Decisions</a>
      <a class="link link-hover" href="#sec-blockers">2 Blockers</a>
      <a class="link link-hover" href="#sec-merge">3 Merge</a>
      <a class="link link-hover" href="#sec-slots">4 Slots</a>
      <a class="link link-hover" href="#sec-secondmates">Second mates</a>
      <a class="link link-hover" href="#sec-accounts">Accounts</a>
      <a class="link link-hover" href="#sec-progress-3h">5 Last 3h</a>
      <a class="link link-hover" href="#sec-progress-12h">6 Last 12h</a>
      <a class="link link-hover" href="#sec-upcoming">7 Upcoming</a>
      <a class="link link-hover" href="#sec-held">8 Held</a>
      <a class="link link-hover" href="#sec-queue">9 Queue</a>
      <a class="link link-hover" href="#sec-stats">10 Stats</a>
      <a class="link link-hover font-medium text-warning" href="#sec-questions">11 Questions</a>
      <a class="link link-hover font-medium text-warning" href="#sec-conversation">12 Conversation</a>
    </nav>
  </div>
HTML
}

render_page() {
  cat <<'HTML'
<!DOCTYPE html>
<html lang="en" data-theme="luxury">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Captain's desk</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/daisyui@5.5.19/daisyui.css">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/daisyui@5.5.19/themes.css">
<script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4.2.4/dist/index.global.js"></script>
<style>
  *, *::before, *::after { box-sizing: border-box; }
  :where(.grid, .flex) > * { min-width: 0; }
  :where(p, h1, h2, h3, h4, h5, h6, li, dd, blockquote, td, th, .badge, .label) { overflow-wrap: anywhere; }
  :where(img, svg, video, canvas, iframe) { max-width: 100%; height: auto; }
  .card { border: 1px solid color-mix(in oklab, currentColor 12%, transparent); }
  .rail { border-left: 3px solid var(--rail, transparent); }
  .sticky { position: sticky; }
</style>
</head>
<body class="bg-base-100 text-base-content">
<div class="max-w-6xl mx-auto px-5 py-8">
HTML
  render_sticky_strip
  render_header
  render_generated_stamp
  render_gaps
  render_tickets
  render_captains_call
  render_decisions
  render_blockers
  render_ready_merge
  render_slots
  render_secondmates
  render_accounts
  render_progress_3h
  render_progress_12h
  render_upcoming
  render_captain_held
  render_queue_lists
  render_stats
  render_transcript_note
  render_recent_questions
  render_recent_conversation
  cat <<'HTML'
  <footer class="text-xs opacity-50 pt-4 border-t border-base-300">
    This page shows the picture at the time above. Ask for a refresh to see the current one.
    Nothing is stopped automatically on a capacity reading.
  </footer>
</div>
</body>
</html>
HTML
}

# --- entry point ------------------------------------------------------------

case "${1:-}" in
  --path) printf '%s\n' "$OUT"; exit 0 ;;
  -h|--help) usage; exit 0 ;;
  '') ;;
  *) printf 'fm-desk-refresh: unknown argument: %s\n' "$1" >&2; usage >&2; exit 64 ;;
esac

OUT_DIR=$(dirname "$OUT")
if ! mkdir -p "$OUT_DIR" 2>/dev/null; then
  printf 'fm-desk-refresh: cannot create %s\n' "$OUT_DIR" >&2
  exit 1
fi

# Write to a temp path in the SAME directory, then move it into place, so a
# reload never catches a half-written page and the move stays on one filesystem.
TMP="$OUT_DIR/.$(basename "$OUT").tmp.$$"
if ! render_page > "$TMP" 2>/dev/null; then
  rm -f "$TMP"
  printf 'fm-desk-refresh: render failed\n' >&2
  exit 1
fi
if ! mv -f "$TMP" "$OUT" 2>/dev/null; then
  rm -f "$TMP"
  printf 'fm-desk-refresh: cannot write %s\n' "$OUT" >&2
  exit 1
fi

# Sections 11 and 12 now have a real local transcript source: the durable feed
# (bin/fm-desk-transcript.sh) the running session publishes to, with the /desk
# judgment file as a fallback. The old terminal needs-decision line asked
# firstmate to WIRE that hook; the hook exists now, so that decision is resolved
# and the line is gone. An empty catch-up panel is a "nothing published yet"
# state, surfaced by the in-page note only, never a wake or a human decision -
# the NEVER WAKES invariant is unaffected.
exit 0
