#!/usr/bin/env bash
# fm-token-report.sh - token usage and cost reporting for jcode sessions.
#
# PR-T2 + PR-T4 of the token-usage-visibility design of record
# (data/design-token-usage-visibility/report.md, sections "CLI design:
# bin/fm-token-report.sh", "PR-T2", and "PR-T4"). PR-T2 ships usable
# per-session, per-period, and time-bucketed cost visibility JOIN-FREE.
# PR-T4 adds the per-ticket dimension on top: an exact <task-id> rollup that
# rides the durable spawn session ledger (data/token-sessions.tsv), a
# --period --by-ticket grouping, and a --retro coarse date-window ESTIMATE
# path for tickets that predate the spawn session-id capture. Captain decision
# D4 (data/design-token-usage-visibility/decision-d4.md) binds the retro path:
# the forward-captured rollup is exact, the retro path is coarse and MUST
# always carry the ESTIMATE label and never be presented as exact.
#
# Read-only. Reads the jcode session store ($JCODE_SESSIONS_DIR, default
# ~/.jcode/sessions), the token-session ledger and completion ledger under the
# data dir (data/token-sessions.tsv + data/completions.tsv, resolved through
# their owning libs), derives cost through bin/fm-token-lib.sh, and writes
# nothing and changes nothing any producer records.
#
# ONE-OWNER-PER-CONTRACT (the reason for the architecture below): every dollar
# figure is produced by bin/fm-token-lib.sh, never by a formula in this file.
# Cost is linear in token counts for a fixed model, so this script:
#   1. aggregates RAW token sums per (time-bucket, model, provider, route) in
#      ONE bulk python pass over the store (fast: sub-second per thousand
#      sessions, versus a per-session shell call that spawns five subprocesses),
#   2. costs each aggregated group through the lib's fm_token_cost (the count of
#      lib calls is bounded by buckets x models, not by session count), and
#   3. SUMS those lib-produced costs per display group (pure addition, not
#      costing) to render.
# So the number is identical to what fm_token_sum_session/fm_token_cost render
# anywhere else, and --session routes straight through fm_token_sum_session for
# exact PR-T1 parity.
# Each aggregated group is costed through the lib with the session provider_key
# resolved to its models.dev provider (fm_token_resolve_provider), so a model
# name that exists in several provider tables costs at the table that actually
# billed it; an unresolved or ambiguous model stays UNKNOWN, never guessed.
#
# Captain decisions bound into this tool (data/design-token-usage-visibility/
# decisions-d1-d2-d5.md, resolved 2026-08-17):
#   D1 cached-output = N/A: no cached-output field exists, none is emitted, no
#      fabricated zero. cache_creation_input_tokens is the cache-WRITE signal and
#      is counted (handled in the lib).
#   D2 price source = jcode's cached models.dev feed, authoritative for billing;
#      every output annotates price_source + price_cached_at (from the lib).
#   D5 time-bucket default = whole session by created_at, so a long session's
#      tokens land WHOLE in its START bucket; --precise buckets per assistant
#      message by messages[].timestamp for exact hourly. Day/week/month buckets
#      barely differ between the two; the difference only bites at --by hour.
#
# Standing captain constraints honored here:
#   - a real token count with no price is UNKNOWN (dollars withheld), never a
#     fake $0 (the lib returns an empty cost; this script carries those tokens in
#     a SEPARATE unknown-model bucket and never folds them into a dollar total);
#   - un-priced / ad-hoc / mock / test model sessions land in that same labeled
#     unknown bucket, never force-fit to a price;
#   - PR-T1 per-session math is exact, so the per-session/period/ledger paths
#     emit cost_if_api_estimate=false; the --retro path (and ONLY that path)
#     emits estimate=true and always carries the ESTIMATE label, never exactness.
#   - sessions in the ledger for a ticket roll up to that ticket exact;
#     sessions in the store with NO ledger row (ad-hoc, unticketed, mock) land
#     in a labeled "unattributed" bucket, never force-fit to a ticket.
#   - this tool only READS the store, the price snapshot, the ledger, and the
#     completions; it changes nothing any producer records.
#
# All bucketing and the --period window are UTC, because the store's timestamps
# are UTC (ISO-8601 with a trailing Z). "sessions=" counts sessions with billed
# token activity in the bucket; a zero-token session contributes no cost and is
# not counted. Under --precise a session whose messages span buckets is counted
# once per bucket it actually contributed tokens to.
#
# Usage:
#   fm-token-report.sh --session <session_id>            one session: token
#                                                        totals + cost-if-API +
#                                                        subscription-covered flag
#   fm-token-report.sh <task-id>                         per-ticket rollup (EXACT:
#                                                        sums every session the
#                                                        ledger records for id)
#   fm-token-report.sh <task-id> --retro                 coarse date-window
#                                                        ESTIMATE for a ticket
#                                                        that predates the spawn
#                                                        session-id capture (no
#                                                        ledger rows; always
#                                                        labeled ESTIMATE, never
#                                                        presented as exact)
#   fm-token-report.sh --period <range>                  fleet rollup over a range
#   fm-token-report.sh --period <range> --by <unit>      time-bucketed trend,
#                                                        unit = hour|day|week|month
#   fm-token-report.sh --period <range> --by-model       group by model
#   fm-token-report.sh --period <range> --by-provider    group by provider
#   fm-token-report.sh --period <range> --by-ticket      group by ticket id
#                                                        (a session with no
#                                                        direct ledger row is
#                                                        joined through the
#                                                        attribution sources
#                                                        below; anything still
#                                                        unmatched lands in
#                                                        "unattributed")
#   fm-token-report.sh --period <range> --by-tier        group by SPEND TIER of
#                                                        the recorded model
#                                                        (tooling vs product vs
#                                                        other), so the cheap
#                                                        deepseek-flash lane's
#                                                        savings versus the opus
#                                                        product lane are visible;
#                                                        each tier line also
#                                                        reports its distinct
#                                                        attributed-ticket count.
#                                                        The model->tier map is
#                                                        data-driven from
#                                                        config/model-tiers.json
#                                                        (bin/fm-token-tier-lib.sh
#                                                        is its single owner), so
#                                                        a new model lands in a
#                                                        sensible tier without a
#                                                        code edit; an unpriced
#                                                        model still surfaces its
#                                                        tokens in the labeled
#                                                        UNKNOWN bucket, never a
#                                                        fabricated $0.
#   fm-token-report.sh ... --json                        stable machine output
#   fm-token-report.sh ... --precise                     per-message time
#                                                        bucketing (D5 option b)
#   fm-token-report.sh --help                            print this header
#
# --period <range> forms: all | today | Nd (e.g. 7d) | YYYY-MM-DD |
#   YYYY-MM-DD..YYYY-MM-DD (both ends inclusive by whole day).
# --by <time-unit> composes with --by-model / --by-provider / --by-ticket /
#   --by-tier (e.g. --period 7d --by week --by-tier = weekly cost per spend tier).
#
# --retro details (D4): the ticket must have NO ledger rows (pre-capture) and a
#   completion record in data/completions.tsv. The completion's close field (a
#   bare date on legacy rows, a full UTC timestamp on rows from 2026-09 on; its
#   leading 10 chars are the calendar day either way) ends a coarse 7-day window
#   (close day and the six days before it, whole days UTC); every session whose
#   created_at falls in that window is attributed to the ticket HEURISTICALLY.
#   The number is an estimate: the label ESTIMATE is
#   always printed and --json carries estimate=true. --retro refuses to run on a
#   ticket that has exact ledger data, because the exact path already covers it.
#
# The data dir for the ledger + completions is $FM_DATA_OVERRIDE, else
# $FM_HOME/data, else <repo-root>/data (the standard firstmate override
# chain) so tests and the dashboard point them at fixtures, never the real ones.
#
# ATTRIBUTION SOURCES for --period --by-ticket (captain-approved join set,
# data/token-attribution-gap/decision-join-sources.md, approved 2026-08-23).
# Producers other than bin/fm-spawn.sh never write a ledger row, so their
# sessions used to render "unattributed" even though a durable record elsewhere
# names their ticket. These joins are READ-SIDE ONLY: nothing is appended to any
# ledger and every join recomputes on each run, so the tool's read-only contract
# is unchanged. In precedence order:
#   1. ledger    (exact)    the home's own data/token-sessions.tsv row.
#   2. nm        (exact)    a no-mistakes pipeline child, whose worktree path
#                           <nm-home>/worktrees/<repo_id>/<run_id> carries the
#                           run id; the run's branch in <nm-home>/state.sqlite
#                           (opened READ-ONLY) names the task, with an optional
#                           leading "fm/" stripped. A miss falls through.
#   3. secondmate (exact)   a session running inside a registered secondmate
#                           home (data/secondmates.md "home:"), resolved against
#                           THAT home's own data/token-sessions.tsv with the
#                           same first-match-wins semantics as the local ledger.
#   4. window    (ESTIMATE) an orphan session whose working_dir is a ledgered
#                           task worktree is attributed to the task whose
#                           [spawn_ts, next-spawn_ts) window covers its
#                           created_at (consecutive spawns of the same task are
#                           one window; with no next spawn the window is bounded
#                           by that task's completions close date). Captain
#                           decision D4 binds this path: it is coarse, so it
#                           ALWAYS carries the ESTIMATE label and is never
#                           presented as exact.
# Sources 1-3 are keyed 1:1 joins against firstmate's own durable records and are
# exact. Anything still unmatched (ad-hoc work, unticketed sessions) stays in the
# labeled "unattributed" bucket, never force-fit to a ticket.
# $FM_NM_HOME (else $NM_HOME, else ~/.no-mistakes) locates the no-mistakes state
# database, so a relocated no-mistakes home and the tests both resolve correctly.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# FM_ROOT/FM_HOME/DATA and die (exit 2 default) come from the shared preamble.
FM_PROG=fm-token-report FM_DIE_CODE=2
# shellcheck source=bin/fm-preamble-lib.sh
. "$SCRIPT_DIR/fm-preamble-lib.sh"

# shellcheck source=bin/fm-token-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-token-lib.sh"
# shellcheck source=bin/fm-token-sessions-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-token-sessions-lib.sh"
# shellcheck source=bin/fm-completions-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-completions-lib.sh"
# shellcheck source=bin/fm-token-tier-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-token-tier-lib.sh"

usage() {
  sed -n '2,176p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- argument parse ----------------------------------------------------------

MODE=""
SESSION_ID=""
TASK_ID=""
PERIOD=""
BY_TIME=""
BY_DIM=""
JSON=0
PRECISE=0
RETRO=0

while [ $# -gt 0 ]; do
  case "$1" in
    --session)
      [ $# -ge 2 ] || die "--session needs a session id"
      [ -z "$MODE" ] || die "choose one of --session, --period, or a task-id, not both"
      MODE=session; SESSION_ID=$2; shift 2 ;;
    --session=*)
      [ -z "$MODE" ] || die "choose one of --session, --period, or a task-id, not both"
      MODE=session; SESSION_ID=${1#--session=}; shift ;;
    --period)
      [ $# -ge 2 ] || die "--period needs a range (all, today, Nd, a date, or date..date)"
      [ -z "$MODE" ] || die "choose one of --session, --period, or a task-id, not both"
      MODE=period; PERIOD=$2; shift 2 ;;
    --period=*)
      [ -z "$MODE" ] || die "choose one of --session, --period, or a task-id, not both"
      MODE=period; PERIOD=${1#--period=}; shift ;;
    --by)
      [ $# -ge 2 ] || die "--by needs a time unit (hour, day, week, or month)"
      BY_TIME=$2; shift 2 ;;
    --by=*)
      BY_TIME=${1#--by=}; shift ;;
    --by-model)
      [ -z "$BY_DIM" ] || die "choose one of --by-model, --by-provider, or --by-ticket, not two"
      BY_DIM=model; shift ;;
    --by-provider)
      [ -z "$BY_DIM" ] || die "choose one of --by-model, --by-provider, or --by-ticket, not two"
      BY_DIM=provider; shift ;;
    --by-ticket)
      [ -z "$BY_DIM" ] || die "choose one of --by-model, --by-provider, --by-ticket, or --by-tier, not two"
      BY_DIM=ticket; shift ;;
    --by-tier)
      [ -z "$BY_DIM" ] || die "choose one of --by-model, --by-provider, --by-ticket, or --by-tier, not two"
      BY_DIM=tier; shift ;;
    --json) JSON=1; shift ;;
    --precise) PRECISE=1; shift ;;
    --retro) RETRO=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) die "unknown option '$1' (try --help)" ;;
    *)
      # A bare positional argument is the <task-id> per-ticket rollup.
      [ -z "$MODE" ] || die "unexpected extra argument '$1' (try --help)"
      MODE=ticket; TASK_ID=$1; shift ;;
  esac
done

[ -n "$MODE" ] || die "nothing to report: pass --session <id>, --period <range>, or a <task-id> (try --help)"

case "$BY_TIME" in
  ""|hour|day|week|month) : ;;
  *) die "--by time unit must be hour, day, week, or month (got '$BY_TIME')" ;;
esac

if [ "$MODE" = session ] || [ "$MODE" = ticket ]; then
  [ -z "$BY_TIME" ] && [ -z "$BY_DIM" ] && [ "$PRECISE" -eq 0 ] \
    || die "--by, --by-model, --by-provider, --by-ticket, --by-tier, and --precise apply to --period, not a session or task-id"
fi

if [ "$BY_DIM" = ticket ]; then
  [ "$MODE" = period ] || die "--by-ticket applies only to --period"
fi

if [ "$BY_DIM" = tier ]; then
  [ "$MODE" = period ] || die "--by-tier applies only to --period"
fi

if [ "$RETRO" -eq 1 ]; then
  [ "$MODE" = ticket ] || die "--retro applies only to a <task-id> rollup (the pre-capture estimate path)"
fi

SESSIONS_DIR=${JCODE_SESSIONS_DIR:-$HOME/.jcode/sessions}
PRICE_FILE=$(fm_token_prices_path)
PRICE_SOURCE=$(fm_token_prices_field price_source "$PRICE_FILE" 2>/dev/null || true)
PRICE_CACHED=$(fm_token_prices_field cached_at "$PRICE_FILE" 2>/dev/null || true)
TOKEN_SESSIONS_FILE=$(fm_token_sessions_file "$DATA")
COMPLETIONS_FILE=$(fm_completions_file "$DATA")
SECONDMATES_FILE="$DATA/secondmates.md"
NM_STATE_DB="${FM_NM_HOME:-${NM_HOME:-$HOME/.no-mistakes}}/state.sqlite"

command -v python3 >/dev/null 2>&1 || die "python3 is required to parse the jcode session store" 3

# --- session mode ------------------------------------------------------------

resolve_session_path() {
  local want=$1 dir=$2
  FM_TR_SID="$want" FM_TR_DIR="$dir" python3 - <<'PY'
import glob, json, os, sys

want = os.environ["FM_TR_SID"]
sdir = os.environ["FM_TR_DIR"]
# A direct file path is accepted as-is so a caller can point at one file.
if os.path.isfile(want):
    sys.stdout.write(want)
    sys.exit(0)
for path in sorted(glob.glob(os.path.join(sdir, "session_*.json"))):
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        continue
    if data.get("id") == want:
        sys.stdout.write(path)
        sys.exit(0)
sys.exit(1)
PY
}

emit_session_json() {
  # Build the session object in python so the JSON is always valid and the cost
  # is a real number or null (never a fabricated 0 for an unpriced model).
  FM_TR_SID="$1" FM_TR_MODEL="$2" FM_TR_TI="$3" FM_TR_TO="$4" FM_TR_CR="$5" \
    FM_TR_CW="$6" FM_TR_COST="$7" FM_TR_COVERED="$8" FM_TR_PS="$9" \
    FM_TR_PC="${10}" python3 - <<'PY'
import json, os, sys

cost_raw = os.environ.get("FM_TR_COST", "")
cost = None
if cost_raw != "":
    try:
        cost = round(float(cost_raw), 6)
    except ValueError:
        cost = None
obj = {
    "mode": "session",
    "session": os.environ["FM_TR_SID"],
    "model": os.environ["FM_TR_MODEL"],
    "token_input": int(os.environ["FM_TR_TI"]),
    "token_output": int(os.environ["FM_TR_TO"]),
    "token_cache_read": int(os.environ["FM_TR_CR"]),
    "token_cache_write": int(os.environ["FM_TR_CW"]),
    "cost_if_api": cost,
    "cost_if_api_estimate": False,
    "subscription_covered": os.environ["FM_TR_COVERED"] == "true",
    "price_source": os.environ.get("FM_TR_PS", "") or None,
    "price_cached_at": os.environ.get("FM_TR_PC", "") or None,
}
json.dump(obj, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PY
}

summary_val() { # <out> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | tail -n 1
}

do_session() {
  local path out model ti to cr cw cost covered
  path=$(resolve_session_path "$SESSION_ID" "$SESSIONS_DIR") \
    || die "session not found in $SESSIONS_DIR: $SESSION_ID" 1
  # Exact PR-T1 parity: the per-session numbers come straight from the lib.
  out=$(fm_token_sum_session "$path" "$PRICE_FILE") \
    || die "could not read session $SESSION_ID ($path)" 1
  model=$(summary_val "$out" model)
  ti=$(summary_val "$out" token_input)
  to=$(summary_val "$out" token_output)
  cr=$(summary_val "$out" token_cache_read)
  cw=$(summary_val "$out" token_cache_write)
  cost=$(summary_val "$out" cost_if_api)
  covered=$(summary_val "$out" subscription_covered)

  if [ "$JSON" -eq 1 ]; then
    emit_session_json "$SESSION_ID" "$model" "$ti" "$to" "$cr" "$cw" \
      "$cost" "$covered" "$PRICE_SOURCE" "$PRICE_CACHED"
    return 0
  fi

  local covered_label price_note
  if [ "$covered" = true ]; then covered_label="covered=yes(subscription)"; else covered_label="covered=no(API)"; fi
  if [ -n "$PRICE_SOURCE" ]; then price_note="[price $PRICE_SOURCE @$PRICE_CACHED]"; else price_note="[price UNKNOWN (no snapshot)]"; fi
  printf 'session %s  model=%s  %s\n' "$SESSION_ID" "$model" "$covered_label"
  printf '  input %s  output %s  cache_read %s  cache_write %s\n' \
    "$(commafy "$ti")" "$(commafy "$to")" "$(commafy "$cr")" "$(commafy "$cw")"
  if [ -n "$cost" ]; then
    printf '  cost_if_api $%s   %s\n' "$(printf '%.2f' "$cost")" "$price_note"
  else
    printf '  cost_if_api UNKNOWN (no price for model=%s)   %s\n' "$model" "$price_note"
  fi
}

# Thousands separators for a plain integer, portable (no locale dependency).
commafy() {
  printf '%s' "$1" | sed -e ':a' -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta'
}

# --- period mode -------------------------------------------------------------

# Pass A: one bulk parse of the store. Aggregates raw token sums per
# (bucket, model, provider, route) applying the --period window and the D5
# bucketing rule. Emits a leading "@period" line then TSV rows. No costing here.
aggregate_tokens() {
  FM_TR_DIR="$SESSIONS_DIR" FM_TR_PERIOD="$PERIOD" FM_TR_BYTIME="$BY_TIME" \
    FM_TR_PRECISE="$PRECISE" FM_TR_LEDGER_FILE="$TOKEN_SESSIONS_FILE" \
    FM_TR_NM_DB="$NM_STATE_DB" FM_TR_SECONDMATES="$SECONDMATES_FILE" \
    FM_TR_COMPLETIONS="$COMPLETIONS_FILE" python3 - <<'PY'
import calendar
import glob
import json
import os
import re
import sqlite3
import sys
import time
from datetime import datetime, timezone

sess_dir = os.environ["FM_TR_DIR"]
period = (os.environ.get("FM_TR_PERIOD", "all") or "all").strip()
bytime = os.environ.get("FM_TR_BYTIME", "").strip()
precise = os.environ.get("FM_TR_PRECISE", "") == "1"
# The session ledger (data/token-sessions.tsv) maps a session id to its ticket
# id. A store session with no row here is offered to the approved attribution
# joins below (nm run, secondmate home, spawn-window ESTIMATE) and lands in the
# labeled "unattributed" bucket only when every one of them misses - never
# force-fit. The first match in file order wins for a (pathological) duplicate
# session id.
ledger_file = os.environ.get("FM_TR_LEDGER_FILE", "")
sid_to_ticket = {}
# Ledger rows grouped by realpath'd working_dir, each (spawn_epoch, ticket), for
# the spawn-window ESTIMATE fallback.
wd_spawns = {}
if ledger_file:
    try:
        with open(ledger_file) as lfh:
            for line in lfh:
                line = line.rstrip("\n")
                if not line or line.startswith("#"):
                    continue
                parts = line.split("\t")
                if len(parts) >= 2 and parts[1] not in sid_to_ticket:
                    sid_to_ticket[parts[1]] = parts[0]
                if len(parts) >= 4 and parts[2]:
                    wd_spawns.setdefault(os.path.realpath(parts[2]), []).append(
                        (parts[3], parts[0])
                    )
    except OSError:
        pass


def to_epoch(s):
    if s is None:
        return None
    s = str(s).strip()
    if not s:
        return None
    if re.fullmatch(r"\d+(\.\d+)?", s):
        return float(s)
    m = re.fullmatch(
        r"(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?Z?", s
    )
    if not m:
        return None
    y, mo, d, h, mi, se = (int(m.group(i)) for i in range(1, 7))
    frac = ((m.group(7) or "0") + "000000")[:6]
    return calendar.timegm((y, mo, d, h, mi, se, 0, 0, 0)) + int(frac) / 1_000_000.0


# --- attribution joins (captain-approved sources; see the header) -------------
#
# Each join answers "which ticket ran this session" from a DURABLE record that
# already exists, and each returns (ticket, source) or None. Nothing is written
# anywhere: every lookup is a read, memoized only in this process.

nm_db = os.environ.get("FM_TR_NM_DB", "")
nm_worktrees = (
    os.path.realpath(os.path.join(os.path.dirname(nm_db), "worktrees")) if nm_db else ""
)
_nm_conn = None
_nm_conn_tried = False
_nm_cache = {}


def nm_ticket(working_dir):
    """no-mistakes pipeline child -> its run's branch -> the task id (exact).

    The nm daemon launches pipeline agents itself, so they never pass through
    bin/fm-spawn.sh and never get a ledger row; their worktree path carries the
    run id instead. The state database is opened READ-ONLY (sqlite URI
    mode=ro), so this report can never write to the daemon's own state.
    """
    global _nm_conn, _nm_conn_tried
    if not working_dir or not nm_worktrees:
        return None
    rest = None
    if working_dir.startswith(nm_worktrees + os.sep):
        rest = working_dir[len(nm_worktrees) + 1 :]
    if rest is None:
        return None
    bits = rest.split(os.sep)
    if len(bits) < 2 or not bits[1]:
        return None
    run_id = bits[1]
    if run_id in _nm_cache:
        return _nm_cache[run_id]
    if not _nm_conn_tried:
        _nm_conn_tried = True
        try:
            _nm_conn = sqlite3.connect("file:%s?mode=ro" % nm_db, uri=True)
        except sqlite3.Error:
            _nm_conn = None
    if _nm_conn is None:
        return None
    branch = None
    try:
        row = _nm_conn.execute(
            "SELECT branch FROM runs WHERE id = ?", (run_id,)
        ).fetchone()
        if row:
            branch = row[0]
    except sqlite3.Error:
        branch = None
    ticket = None
    if branch:
        # Both branch forms occur in the runs table: "fm/<task>" and a bare
        # "<task>" (which may itself contain a slash, e.g. "fix/orphan-...").
        # Strip only a leading "fm/".
        ticket = branch[3:] if branch.startswith("fm/") else branch
        ticket = ticket or None
    _nm_cache[run_id] = ticket
    return ticket


# Registered secondmate homes (data/secondmates.md "(home: <path>; ..."). Each
# home keeps its OWN token-sessions.tsv, so a session that ran there is already
# recorded exactly - just in a ledger this home does not read by default.
secondmate_homes = []
_sm_file = os.environ.get("FM_TR_SECONDMATES", "")
if _sm_file:
    try:
        with open(_sm_file) as sfh:
            for line in sfh:
                if not line.startswith("- "):
                    continue
                m = re.search(r"\(home:\s*([^;)]+)[;)]", line)
                if not m:
                    continue
                home = m.group(1).strip()
                if home:
                    secondmate_homes.append(os.path.realpath(home))
    except OSError:
        pass
_sm_ledgers = {}


def secondmate_ticket(working_dir, sid):
    """A session inside a registered secondmate home -> that home's own ledger."""
    if not working_dir or not secondmate_homes:
        return None
    for home in secondmate_homes:
        if working_dir != home and not working_dir.startswith(home + os.sep):
            continue
        table = _sm_ledgers.get(home)
        if table is None:
            table = {}
            try:
                with open(os.path.join(home, "data", "token-sessions.tsv")) as fh:
                    for line in fh:
                        line = line.rstrip("\n")
                        if not line or line.startswith("#"):
                            continue
                        parts = line.split("\t")
                        if len(parts) >= 2 and parts[1] not in table:
                            table[parts[1]] = parts[0]
            except OSError:
                pass
            _sm_ledgers[home] = table
        hit = table.get(sid)
        if hit:
            return hit
    return None


# Per-task completion close day, the right-hand bound of a task's LAST spawn
# window when no later spawn reused the same worktree.
close_epoch = {}
_comp_file = os.environ.get("FM_TR_COMPLETIONS", "")
if _comp_file:
    try:
        with open(_comp_file) as cfh:
            for line in cfh:
                line = line.rstrip("\n")
                if not line or line.startswith("#"):
                    continue
                parts = line.split("\t")
                if len(parts) < 2 or not parts[1]:
                    continue
                # The close field is a bare date on legacy rows and a full UTC
                # timestamp on newer ones; its leading 10 chars are the day
                # either way. The window ends at the END of that day.
                day = to_epoch(parts[1][:10] + "T00:00:00Z")
                if day is None:
                    continue
                end = day + 86400
                # A re-shipped task has several rows; the LAST close wins, the
                # same rule the --retro path uses.
                close_epoch[parts[0]] = end
    except OSError:
        pass

# Windows per worktree: consecutive spawns of the SAME task collapse into one
# window, so a relaunch does not split its own lane.
wd_windows = {}
for _wd, _rows in wd_spawns.items():
    _pairs = []
    for _ts, _task in _rows:
        _ep = to_epoch(_ts)
        if _ep is not None:
            _pairs.append((_ep, _task))
    _pairs.sort()
    _collapsed = []
    for _ep, _task in _pairs:
        if _collapsed and _collapsed[-1][1] == _task:
            continue
        _collapsed.append((_ep, _task))
    _out = []
    for _i, (_ep, _task) in enumerate(_collapsed):
        if _i + 1 < len(_collapsed):
            _end = _collapsed[_i + 1][0]
        else:
            _end = close_epoch.get(_task)
        _out.append((_ep, _end, _task))
    wd_windows[_wd] = _out


def window_ticket(working_dir, created):
    """Coarse spawn-window attribution (captain decision D4: always ESTIMATE).

    An orphan session that ran in a worktree the ledger knows belongs to the
    task whose spawn window covers its creation instant. This is positional,
    not keyed, so it is never presented as exact.

    An agent may run from a SUBDIRECTORY of its leased worktree (a crate dir,
    say), so the nearest ledgered ancestor of the session's working_dir owns the
    lane; the nearest one wins, so a nested lease never loses to its parent.
    """
    if not working_dir or created is None:
        return None
    candidate = None
    for wd in wd_windows:
        if working_dir == wd or working_dir.startswith(wd + os.sep):
            if candidate is None or len(wd) > len(candidate):
                candidate = wd
    if candidate is None:
        return None
    for start_ep, end_ep, task in wd_windows[candidate]:
        if created < start_ep:
            continue
        if end_ep is not None and created >= end_ep:
            continue
        return task
    return None


_attr_cache = {}


def attribute(sid, working_dir, created):
    """Resolve (ticket, source) for one store session, in precedence order."""
    hit = _attr_cache.get(sid)
    if hit is not None:
        return hit
    ticket = sid_to_ticket.get(sid)
    source = "ledger"
    if not ticket:
        real_wd = os.path.realpath(working_dir) if working_dir else ""
        ticket = nm_ticket(real_wd)
        source = "nm"
        if not ticket:
            ticket = secondmate_ticket(real_wd, sid)
            source = "secondmate"
        if not ticket:
            ticket = window_ticket(real_wd, created)
            source = "window"
    if not ticket:
        ticket, source = "unattributed", "none"
    _attr_cache[sid] = (ticket, source)
    return ticket, source


def day_floor(ep):
    dt = datetime.fromtimestamp(ep, tz=timezone.utc).replace(
        hour=0, minute=0, second=0, microsecond=0
    )
    return dt.timestamp()


now = time.time()
start = end = None
if period in ("all", ""):
    start = end = None
elif period == "today":
    start = day_floor(now)
    end = now
elif re.fullmatch(r"\d+d", period):
    n = int(period[:-1])
    if n < 1:
        sys.stderr.write("fm-token-report: --period Nd needs N>=1\n")
        sys.exit(2)
    start = day_floor(now) - (n - 1) * 86400
    end = now
elif re.fullmatch(r"\d{4}-\d{2}-\d{2}", period):
    st = to_epoch(period + "T00:00:00Z")
    if st is None:
        sys.stderr.write("fm-token-report: bad --period date: %s\n" % period)
        sys.exit(2)
    start, end = st, st + 86400
elif ".." in period:
    a, b = period.split("..", 1)
    start = to_epoch(a.strip() + "T00:00:00Z")
    e = to_epoch(b.strip() + "T00:00:00Z")
    if start is None or e is None:
        sys.stderr.write("fm-token-report: bad --period range: %s\n" % period)
        sys.exit(2)
    end = e + 86400
else:
    sys.stderr.write("fm-token-report: unrecognized --period '%s'\n" % period)
    sys.exit(2)


def in_range(ep):
    if start is not None and ep < start:
        return False
    if end is not None and ep >= end:
        return False
    return True


def bucket_of(ep):
    if not bytime:
        return "all"
    dt = datetime.fromtimestamp(ep, tz=timezone.utc)
    if bytime == "hour":
        return dt.strftime("%Y-%m-%dT%H")
    if bytime == "day":
        return dt.strftime("%Y-%m-%d")
    if bytime == "week":
        return dt.strftime("%G-W%V")
    if bytime == "month":
        return dt.strftime("%Y-%m")
    sys.stderr.write("fm-token-report: bad --by time unit '%s'\n" % bytime)
    sys.exit(2)


agg = {}


def add(key, ti, to, cr, cw, sid, working_dir, created):
    ticket, source = attribute(sid, working_dir, created)
    full_key = key + (ticket, source)
    row = agg.get(full_key)
    if row is None:
        row = [0, 0, 0, 0, set()]
        agg[full_key] = row
    row[0] += ti
    row[1] += to
    row[2] += cr
    row[3] += cw
    row[4].add(sid)


for path in glob.glob(os.path.join(sess_dir, "session_*.json")):
    try:
        with open(path) as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        continue
    sid = d.get("id") or os.path.basename(path)
    model = str(d.get("model") or "unknown")
    provider = str(d.get("provider_key") or "None")
    route = str(d.get("route_api_method") or "None")
    created = to_epoch(d.get("created_at"))
    working_dir = str(d.get("working_dir") or "")
    msgs = d.get("messages") or []
    if precise:
        # Per-message attribution (D5 option b): each assistant message's tokens
        # land in the bucket of its own timestamp, so a long session SPLITS.
        for m in msgs:
            if m.get("role") != "assistant":
                continue
            tu = m.get("token_usage")
            if not isinstance(tu, dict):
                continue
            ts = to_epoch(m.get("timestamp"))
            if ts is None:
                ts = created
            if ts is None or not in_range(ts):
                continue
            add(
                (bucket_of(ts), model, provider, route),
                int(tu.get("input_tokens", 0) or 0),
                int(tu.get("output_tokens", 0) or 0),
                int(tu.get("cache_read_input_tokens", 0) or 0),
                int(tu.get("cache_creation_input_tokens", 0) or 0),
                sid,
                working_dir,
                created,
            )
    else:
        # Whole-session attribution by created_at (D5 default): every token lands
        # WHOLE in the session's START bucket.
        if created is None or not in_range(created):
            continue
        ti = to = cr = cw = 0
        for m in msgs:
            if m.get("role") != "assistant":
                continue
            tu = m.get("token_usage")
            if not isinstance(tu, dict):
                continue
            ti += int(tu.get("input_tokens", 0) or 0)
            to += int(tu.get("output_tokens", 0) or 0)
            cr += int(tu.get("cache_read_input_tokens", 0) or 0)
            cw += int(tu.get("cache_creation_input_tokens", 0) or 0)
        if ti or to or cr or cw:
            add(
                (bucket_of(created), model, provider, route),
                ti,
                to,
                cr,
                cw,
                sid,
                working_dir,
                created,
            )


def iso(ep):
    if ep is None:
        return ""
    return datetime.fromtimestamp(ep, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


sys.stdout.write("@period\t%s\t%s\t%s\n" % (period, iso(start), iso(end)))
for (b, model, provider, route, ticket, source), row in agg.items():
    sys.stdout.write(
        "\t".join(
            [
                b,
                model,
                provider,
                route,
                str(len(row[4])),
                str(row[0]),
                str(row[1]),
                str(row[2]),
                str(row[3]),
                ticket,
                source,
            ]
        )
        + "\n"
    )
PY
}

# Build a JSON object mapping every distinct model in a costed TSV to its spend
# tier, using the ONE tier owner (fm_token_tier_of over config/model-tiers.json).
# The tier boundary is resolved here, in bash, exactly once per distinct model,
# so the render pass only LOOKS UP a model's tier and never re-implements the
# glob matching. Reads the costed file (model is field 2) from $1.
build_tier_map() {
  local costed_file=$1 model tier first=1
  printf '{'
  while IFS= read -r model; do
    [ -n "$model" ] || continue
    tier=$(fm_token_tier_of "$model")
    if [ "$first" -eq 1 ]; then first=0; else printf ','; fi
    FM_TM_MODEL="$model" FM_TM_TIER="$tier" python3 -c \
      'import json,os,sys; sys.stdout.write(json.dumps(os.environ["FM_TM_MODEL"])+":"+json.dumps(os.environ["FM_TM_TIER"]))'
  done < <(cut -f2 "$costed_file" | sort -u)
  printf '}'
}

# Pass B: render. Reads the COSTED rows from the file named by $FM_TR_COSTED
# (each carrying a lib-produced cost or an empty cost for an unpriced model) and
# only SUMS them per display group. No costing formula lives here. The rows come
# from a file rather than stdin because python's own script is fed on stdin by
# the heredoc below, so stdin is already consumed.
render_period() {
  local costed_file=$1 tiermap="{}"
  [ "$BY_DIM" = tier ] && tiermap=$(build_tier_map "$costed_file")
  FM_TR_COSTED="$costed_file" FM_TR_BYTIME="$BY_TIME" FM_TR_BYDIM="$BY_DIM" \
    FM_TR_TIERMAP="$tiermap" \
    FM_TR_JSON="$JSON" FM_TR_PRECISE="$PRECISE" FM_TR_PERIOD="$PERIOD" \
    FM_TR_START="$PERIOD_START" FM_TR_END="$PERIOD_END" FM_TR_PS="$PRICE_SOURCE" \
    FM_TR_PC="$PRICE_CACHED" python3 - <<'PY'
import json
import os
import sys

bytime = os.environ.get("FM_TR_BYTIME", "")
bydim = os.environ.get("FM_TR_BYDIM", "")
as_json = os.environ.get("FM_TR_JSON", "") == "1"
precise = os.environ.get("FM_TR_PRECISE", "") == "1"
period = os.environ.get("FM_TR_PERIOD", "")
start = os.environ.get("FM_TR_START", "")
end = os.environ.get("FM_TR_END", "")
price_source = os.environ.get("FM_TR_PS", "")
price_cached = os.environ.get("FM_TR_PC", "")
try:
    tier_map = json.loads(os.environ.get("FM_TR_TIERMAP", "{}") or "{}")
except ValueError:
    tier_map = {}


def blank():
    return {
        "sessions": 0,
        "cost": 0.0,
        "covered": 0.0,
        "billed": 0.0,
        "has_priced": False,
        "unk_tokens": 0,
        "unk_models": set(),
        "tickets": set(),
        "sources": set(),
        "ti": 0,
        "to": 0,
        "cr": 0,
        "cw": 0,
    }


groups = {}
with open(os.environ["FM_TR_COSTED"]) as _fh:
    costed_lines = _fh.readlines()
for line in costed_lines:
    line = line.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t")
    if len(parts) != 12:
        continue
    (
        bucket,
        model,
        provider,
        covered,
        ticket,
        sessions,
        cost,
        ti,
        to,
        cr,
        cw,
        source,
    ) = parts
    if bydim == "model":
        dim = model
    elif bydim == "provider":
        dim = provider
    elif bydim == "ticket":
        dim = ticket
    elif bydim == "tier":
        dim = tier_map.get(model, "other")
    else:
        dim = ""
    key = (bucket, dim)
    g = groups.get(key)
    if g is None:
        g = blank()
        groups[key] = g
    g["sessions"] += int(sessions)
    g["ti"] += int(ti)
    g["to"] += int(to)
    g["cr"] += int(cr)
    g["cw"] += int(cw)
    # Distinct attributed tickets per group, so --by-tier can report how many
    # tickets each spend tier served (the fleet's cheap-lane-savings question is
    # "how much spend AND how many tickets on the cheap lane"). "unattributed"
    # is a real bucket, not a ticket, so it never counts.
    if ticket and ticket != "unattributed":
        g["tickets"].add(ticket)
        # How this group's sessions were attributed, so the render can label a
        # ticket line exact or ESTIMATE (captain decision D4: the coarse
        # spawn-window join is NEVER presented as exact).
        g["sources"].add(source)
    if cost != "":
        c = float(cost)
        g["cost"] += c
        g["has_priced"] = True
        if covered == "true":
            g["covered"] += c
        else:
            g["billed"] += c
    else:
        g["unk_tokens"] += int(ti) + int(to) + int(cr) + int(cw)
        g["unk_models"].add(model)

# Grand totals across every row (exact when not --precise; under --precise a
# session active in several buckets is counted once per bucket, so the session
# total is an activity count, noted in the label).
total = blank()
for g in groups.values():
    for k in ("sessions", "cost", "covered", "billed", "unk_tokens", "ti", "to", "cr", "cw"):
        total[k] += g[k]
    total["has_priced"] = total["has_priced"] or g["has_priced"]
    total["unk_models"] |= g["unk_models"]
    total["tickets"] |= g["tickets"]
    total["sources"] |= g["sources"]

# Sort: by bucket ascending (chronological for every time unit), then by cost
# descending within a bucket, then dimension name for determinism.
sorted_keys = sorted(
    groups.keys(), key=lambda k: (k[0], -groups[k]["cost"], k[1])
)


def commafy(n):
    return "{:,}".format(int(n))


def money(x):
    return "{:.2f}".format(x)


# Attribution label for one display group (--by-ticket only). Sources ledger, nm,
# and secondmate are keyed 1:1 joins against firstmate's own durable records, so
# they are exact; the coarse spawn-window join is an ESTIMATE and captain
# decision D4 requires it to say so wherever a number carrying it is shown. A
# group mixing both is labeled partly-ESTIMATE, never exact.
def attribution_label(sources):
    if bydim != "ticket" or not sources:
        return ""
    if "window" not in sources:
        return "exact"
    if sources == {"window"}:
        return "ESTIMATE"
    return "partly-ESTIMATE"


if as_json:
    rows = []
    for (bucket, dim) in sorted_keys:
        g = groups[(bucket, dim)]
        rows.append(
            {
                "bucket": bucket if bytime else None,
                "dimension": dim if bydim else None,
                "ticket": dim if bydim == "ticket" else None,
                "attribution": attribution_label(g["sources"]) or None,
                "attribution_sources": sorted(g["sources"]) if bydim == "ticket" else None,
                "tier": dim if bydim == "tier" else None,
                "ticket_count": len(g["tickets"]) if bydim == "tier" else None,
                "sessions": g["sessions"],
                "token_input": g["ti"],
                "token_output": g["to"],
                "token_cache_read": g["cr"],
                "token_cache_write": g["cw"],
                "cost_if_api": round(g["cost"], 6) if g["has_priced"] else None,
                "cost_if_api_covered": round(g["covered"], 6),
                "cost_if_api_billed": round(g["billed"], 6),
                # Attribution never changes the token math, so only the
                # per-ticket dimension - where a coarse window join can decide
                # WHICH ticket a real cost lands on - can be an estimate.
                "cost_if_api_estimate": bydim == "ticket" and "window" in g["sources"],
                "unknown_model_tokens": g["unk_tokens"],
                "unknown_models": sorted(g["unk_models"]),
            }
        )
    obj = {
        "mode": "period",
        "period": {"spec": period, "start": start or None, "end": end or None},
        "by_time": bytime or None,
        "by_dimension": bydim or None,
        "precise": precise,
        "price_source": price_source or None,
        "price_cached_at": price_cached or None,
        "rows": rows,
        "totals": {
            "sessions": total["sessions"],
            "token_input": total["ti"],
            "token_output": total["to"],
            "token_cache_read": total["cr"],
            "token_cache_write": total["cw"],
            "cost_if_api": round(total["cost"], 6) if total["has_priced"] else None,
            "cost_if_api_covered": round(total["covered"], 6),
            "cost_if_api_billed": round(total["billed"], 6),
            "cost_if_api_estimate": bydim == "ticket" and "window" in total["sources"],
            "attribution": attribution_label(total["sources"]) or None,
            "unknown_model_tokens": total["unk_tokens"],
            "unknown_models": sorted(total["unk_models"]),
            "ticket_count": len(total["tickets"]) if bydim == "tier" else None,
        },
    }
    json.dump(obj, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    sys.exit(0)

# Human (caveman, aligned).
win = period
if start or end:
    win = "%s [%s..%s]" % (period, start or "-", end or "-")
src = ("%s @%s" % (price_source, price_cached)) if price_source else "UNKNOWN (no snapshot)"
sys.stdout.write("period %s  price %s\n" % (win, src))


def render_row(label, g):
    unk_tail = ""
    if g["unk_tokens"] > 0:
        models = ",".join(sorted(g["unk_models"]))
        unk_tail = "  [unknown-model tokens %s | %s]" % (commafy(g["unk_tokens"]), models)
    # For --by-tier, show the distinct attributed-ticket count alongside spend
    # so the cheap-lane-savings question ("how much AND how many tickets") is
    # answered on one line.
    tier_tail = "  tickets=%d" % len(g["tickets"]) if bydim == "tier" else ""
    label_tail = ""
    attribution = attribution_label(g["sources"])
    if attribution:
        label_tail = "  [%s]" % attribution
    if g["has_priced"]:
        return "%s  sessions=%d%s  cost_if_api $%s  covered $%s / api $%s%s%s" % (
            label,
            g["sessions"],
            tier_tail,
            money(g["cost"]),
            money(g["covered"]),
            money(g["billed"]),
            label_tail,
            unk_tail,
        )
    # No priced tokens at all: withhold dollars, show the tokens (never $0).
    return "%s  sessions=%d%s  cost_if_api UNKNOWN (no price)  tokens %s%s%s" % (
        label,
        g["sessions"],
        tier_tail,
        commafy(g["ti"] + g["to"] + g["cr"] + g["cw"]),
        label_tail,
        unk_tail,
    )


for (bucket, dim) in sorted_keys:
    parts = []
    if bytime:
        parts.append(bucket)
    if bydim:
        parts.append("%s=%s" % (bydim, dim))
    label = "  ".join(parts) if parts else ("period %s" % period)
    sys.stdout.write(render_row(label, groups[(bucket, dim)]) + "\n")

if len(sorted_keys) > 1:
    tlabel = "total (session count is per-bucket activity)" if precise else "total"
    sys.stdout.write(render_row(tlabel, total) + "\n")

if bydim == "ticket" and "window" in total["sources"]:
    sys.stdout.write(
        "  [ESTIMATE rows: attributed by spawn window (working_dir + time), not "
        "a keyed join; NOT an exact per-ticket cost (D4)]\n"
    )
PY
}

# Cost an aggregated TSV through the lib and write a costed TSV. This is the
# single insertion point of every dollar figure in the period/retro pipelines:
# fm_token_cost is the ONLY place a cost is computed, and this loop only LOOKS
# UP coverage (fm_token_subscription_covered) and price presence, both memoized
# per pair so an unpriced model never spawns a cost call. Reads agg rows
# (bucket model provider route sessions ti to cr cw ticket source) from $1 and
# writes costed rows
# (bucket model provider covered ticket sessions cost ti to cr cw source) to $2.
cost_aggregate_rows() {
  local agg_file=$1 costed_file=$2
  local -A COVERED_CACHE=()
  local -A PRICED_CACHE=()
  local -A RESOLVED_CACHE=()
  local b model provider route sessions ti to cr cw ticket source cov cost pkey ckey rkey resolved

  while IFS=$'\t' read -r b model provider route sessions ti to cr cw ticket source; do
    [ -n "$b" ] || continue
    pkey="$provider|$route"
    if [ -z "${COVERED_CACHE[$pkey]+x}" ]; then
      COVERED_CACHE[$pkey]=$(fm_token_subscription_covered "$provider" "$route")
    fi
    cov=${COVERED_CACHE[$pkey]}

    rkey="$provider"
    if [ -z "${RESOLVED_CACHE[$rkey]+x}" ]; then
      RESOLVED_CACHE[$rkey]=$(fm_token_resolve_provider "$provider")
    fi
    resolved=${RESOLVED_CACHE[$rkey]}

    ckey="$provider|$model"
    if [ -z "${PRICED_CACHE[$ckey]+x}" ]; then
      if fm_token_model_price "$model" "$PRICE_FILE" "$resolved" >/dev/null 2>&1; then
        PRICED_CACHE[$ckey]=1
      else
        PRICED_CACHE[$ckey]=0
      fi
    fi

    cost=""
    if [ "${PRICED_CACHE[$ckey]}" = 1 ]; then
      cost=$(fm_token_cost "$ti" "$to" "$cr" "$cw" "$model" "$PRICE_FILE" "$resolved") || cost=""
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$b" "$model" "$provider" "$cov" "$ticket" "$sessions" "$cost" "$ti" "$to" "$cr" "$cw" \
      "$source"
  done < <(tail -n +2 "$agg_file") > "$costed_file"
}

do_period() {
  local agg_tmp costed_tmp
  agg_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-token-report.aggXXXXXX")
  costed_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-token-report.costXXXXXX")
  trap 'rm -f "$agg_tmp" "$costed_tmp"' RETURN

  aggregate_tokens > "$agg_tmp"

  # First line is the resolved period window: "@period <spec> <start> <end>".
  # The spec field is re-derived from $PERIOD in render, so it is discarded here.
  local _tag _spec PERIOD_START PERIOD_END
  IFS=$'\t' read -r _tag _spec PERIOD_START PERIOD_END < "$agg_tmp"
  [ "$_tag" = "@period" ] || die "internal: aggregate output missing period header" 3

  cost_aggregate_rows "$agg_tmp" "$costed_tmp"

  render_period "$costed_tmp"
}

# --- per-ticket rollup (PR-T4) ------------------------------------------------

# Float addition with full display precision. Used ONLY to sum lib-produced
# costs (pure addition, never a new cost formula).
fadd() {
  awk -v a="$1" -v b="$2" 'BEGIN{printf "%.12f", a+b}'
}

# Emit the shared per-ticket JSON object (exact and --retro) from env values.
# D4: the estimate flag is truthful - false for the exact ledger rollup, true
# for --retro, which always also carries the coarse date window.
emit_ticket_json() {
  FM_TRE_TICKET="$TASK_ID" \
    FM_TRE_ESTIMATE="$TRE_ESTIMATE" FM_TRE_CLOSE="$TRE_CLOSE" \
    FM_TRE_WSTART="$TRE_WSTART" FM_TRE_WEND="$TRE_WEND" \
    FM_TRE_SESSIONS="$TRE_SESSIONS" FM_TRE_LEDGER="$TRE_LEDGER" \
    FM_TRE_UNRESOLVED="$TRE_UNRESOLVED" FM_TRE_TI="$TRE_TI" \
    FM_TRE_TO="$TRE_TO" FM_TRE_CR="$TRE_CR" FM_TRE_CW="$TRE_CW" \
    FM_TRE_COST="$TRE_COST" FM_TRE_COVERED="$TRE_COVERED" \
    FM_TRE_BILLED="$TRE_BILLED" FM_TRE_UNK="$TRE_UNK" \
    FM_TRE_UNKMODELS="$TRE_UNKMODELS" FM_TRE_PS="$PRICE_SOURCE" \
    FM_TRE_PC="$PRICE_CACHED" python3 - <<'PY'
import json, os, sys


def nint(name):
    v = os.environ.get(name, "") or ""
    try:
        return int(v)
    except ValueError:
        return 0


def fnum(name):
    v = os.environ.get(name, "") or ""
    if not v:
        return None
    try:
        return round(float(v), 6)
    except ValueError:
        return None


estimate = os.environ.get("FM_TRE_ESTIMATE", "") == "true"
models = [m for m in (os.environ.get("FM_TRE_UNKMODELS", "") or "").split(",") if m]
obj = {
    "mode": "ticket",
    "ticket": os.environ.get("FM_TRE_TICKET", ""),
    "estimate": estimate,
    "cost_if_api_estimate": estimate,
    "sessions": nint("FM_TRE_SESSIONS"),
    "token_input": nint("FM_TRE_TI"),
    "token_output": nint("FM_TRE_TO"),
    "token_cache_read": nint("FM_TRE_CR"),
    "token_cache_write": nint("FM_TRE_CW"),
    "cost_if_api": fnum("FM_TRE_COST"),
    "cost_if_api_covered": fnum("FM_TRE_COVERED") or 0.0,
    "cost_if_api_billed": fnum("FM_TRE_BILLED") or 0.0,
    "unknown_model_tokens": nint("FM_TRE_UNK"),
    "unknown_models": sorted(set(models)),
    "price_source": os.environ.get("FM_TRE_PS", "") or None,
    "price_cached_at": os.environ.get("FM_TRE_PC", "") or None,
}
if os.environ.get("FM_TRE_CLOSE", ""):
    obj["retro_window"] = {
        "close_date": os.environ.get("FM_TRE_CLOSE", ""),
        "start": os.environ.get("FM_TRE_WSTART", ""),
        "end": os.environ.get("FM_TRE_WEND", ""),
    }
else:
    obj["ledger_sessions"] = nint("FM_TRE_LEDGER")
    obj["unresolved_sessions"] = nint("FM_TRE_UNRESOLVED")
json.dump(obj, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PY
}

# Print the shared human per-ticket rollup block from the TRE_* values plus the
# estimate note ("" for exact, the ESTIMATE window note for --retro).
print_rollup_human() {
  local estimate_note=$1
  local sessions=${TRE_SESSIONS:-0} ti=${TRE_TI:-0} to=${TRE_TO:-0} cr=${TRE_CR:-0} cw=${TRE_CW:-0}
  if [ "$sessions" -eq 0 ]; then
    printf 'ticket %s  sessions=0%s  [no session in scope]\n' "$TASK_ID" "$estimate_note"
    if [ "${TRE_UNRESOLVED:-0}" -gt 0 ]; then
      printf '  %s ledger session(s) not found in the store (tokens unavailable)\n' "$TRE_UNRESOLVED"
    fi
    return 0
  fi
  if [ "${TRE_HASPRICED:-0}" -eq 1 ]; then
    printf 'ticket %s  sessions=%d  cost_if_api $%s  covered $%s / api $%s%s\n' \
      "$TASK_ID" "$sessions" "$(printf '%.2f' "${TRE_COST:-0}")" \
      "$(printf '%.2f' "${TRE_COVERED:-0}")" "$(printf '%.2f' "${TRE_BILLED:-0}")" "$estimate_note"
  else
    printf 'ticket %s  sessions=%d  cost_if_api UNKNOWN (no price)  tokens %s%s\n' \
      "$TASK_ID" "$sessions" "$(commafy "$((ti+to+cr+cw))")" "$estimate_note"
  fi
  printf '  input %s  output %s  cache_read %s  cache_write %s\n' \
    "$(commafy "$ti")" "$(commafy "$to")" "$(commafy "$cr")" "$(commafy "$cw")"
  if [ "${TRE_UNK:-0}" -gt 0 ]; then
    printf '  [unknown-model tokens %s | %s]\n' "$(commafy "${TRE_UNK:-0}")" "${TRE_UNKMODELS:-}"
  fi
  if [ "${TRE_UNRESOLVED:-0}" -gt 0 ]; then
    printf '  %s ledger session(s) not found in the store (tokens unavailable)\n' "$TRE_UNRESOLVED"
  fi
  if [ -n "$PRICE_SOURCE" ]; then
    printf '  [price %s @%s]\n' "$PRICE_SOURCE" "$PRICE_CACHED"
  else
    printf '  [price UNKNOWN (no snapshot)]\n'
  fi
}

# EXACT forward-captured path (rides the ledger): read every token-sessions.tsv
# row for the ticket id, resolve each session in the store, and sum the
# lib-produced per-session numbers. A ledger session missing from the store is
# counted as unresolved with its tokens withheld - never guessed. This path is
# exact and never labeled ESTIMATE.
do_ticket() {
  local rows _id sid path out
  rows=$(fm_token_sessions_rows_for "$DATA" "$TASK_ID") \
    || die "no session ledger row for ticket '$TASK_ID' (pre-capture?); pass --retro for a labeled date-window estimate" 1
  TRE_SESSIONS=0 TRE_LEDGER=0 TRE_UNRESOLVED=0
  TRE_TI=0 TRE_TO=0 TRE_CR=0 TRE_CW=0
  TRE_COST=0 TRE_COVERED=0 TRE_BILLED=0 TRE_HASPRICED=0
  TRE_UNK=0 TRE_UNKMODELS=""
  TRE_CLOSE=""
  TRE_WSTART=""
  TRE_WEND=""
  local mti mto mcr mcw mcost model covered
  while IFS=$'\t' read -r _id sid _wd _ts _harness; do
    TRE_LEDGER=$((TRE_LEDGER+1))
    path=$(resolve_session_path "$sid" "$SESSIONS_DIR") || { TRE_UNRESOLVED=$((TRE_UNRESOLVED+1)); continue; }
    out=$(fm_token_sum_session "$path" "$PRICE_FILE") || { TRE_UNRESOLVED=$((TRE_UNRESOLVED+1)); continue; }
    TRE_SESSIONS=$((TRE_SESSIONS+1))
    mti=$(summary_val "$out" token_input)
    mto=$(summary_val "$out" token_output)
    mcr=$(summary_val "$out" token_cache_read)
    mcw=$(summary_val "$out" token_cache_write)
    mcost=$(summary_val "$out" cost_if_api)
    model=$(summary_val "$out" model)
    covered=$(summary_val "$out" subscription_covered)
    TRE_TI=$((TRE_TI+mti)); TRE_TO=$((TRE_TO+mto))
    TRE_CR=$((TRE_CR+mcr)); TRE_CW=$((TRE_CW+mcw))
    if [ -n "$mcost" ]; then
      TRE_HASPRICED=1
      TRE_COST=$(fadd "$TRE_COST" "$mcost")
      if [ "$covered" = true ]; then
        TRE_COVERED=$(fadd "$TRE_COVERED" "$mcost")
      else
        TRE_BILLED=$(fadd "$TRE_BILLED" "$mcost")
      fi
    else
      TRE_UNK=$((TRE_UNK+mti+mto+mcr+mcw))
      if [ -z "$TRE_UNKMODELS" ]; then
        TRE_UNKMODELS=$model
      else
        case ",$TRE_UNKMODELS," in
          *",$model,"*) : ;;
          *) TRE_UNKMODELS="$TRE_UNKMODELS,$model" ;;
        esac
      fi
    fi
  done < <(printf '%s\n' "$rows")

  if [ "$JSON" -eq 1 ]; then
    TRE_ESTIMATE=false
    emit_ticket_json
    return 0
  fi
  print_rollup_human ""
}

# --retro (D4): coarse date-window ESTIMATE for a pre-capture ticket with NO
# ledger rows. The completion ledger's close date bounds a coarse 7-day window
# (the close date and the six days before it, whole days UTC); every session
# whose created_at falls in that window is attributed to the ticket
# HEURISTICALLY. The token math still comes from the one coster lib; it is the
# ATTRIBUTION that is coarse, so the output always carries the ESTIMATE label,
# never exactness. Refuses to run on a ticket that has exact ledger data.
do_retro() {
  if fm_token_sessions_rows_for "$DATA" "$TASK_ID" | grep -q .; then
    die "ticket '$TASK_ID' has exact ledger sessions; --retro is only for pre-capture tickets (drop --retro for the exact rollup)" 1
  fi
  local comps close_date start_date period_spec
  comps=$(fm_completions_lookup "$DATA" "$TASK_ID") \
    || die "no completion record for '$TASK_ID'; --retro cannot bound a date window" 1
  close_date=$(printf '%s\n' "$comps" | tail -n 1 | cut -f2)
  [ -n "$close_date" ] || die "completion record for '$TASK_ID' has no close date" 1
  # The close field is a bare date (legacy rows) or a full ISO-8601 timestamp
  # (rows from 2026-09 on); both begin with the 10-char date, so take the leading
  # day for the date-window math below.
  close_date=${close_date:0:10}
  start_date=$(python3 -c "import datetime,sys; d=datetime.date(*[int(x) for x in sys.argv[1].split('-')]) - datetime.timedelta(days=6); print(d.isoformat())" "$close_date")
  period_spec="$start_date..$close_date"

  local agg_tmp costed_tmp
  agg_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-token-report.aggXXXXXX")
  costed_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-token-report.costXXXXXX")
  trap 'rm -f "$agg_tmp" "$costed_tmp"' RETURN

  PERIOD="$period_spec"
  aggregate_tokens > "$agg_tmp"
  cost_aggregate_rows "$agg_tmp" "$costed_tmp"

  TRE_SESSIONS=0 TRE_UNRESOLVED=0 TRE_LEDGER=0
  TRE_TI=0 TRE_TO=0 TRE_CR=0 TRE_CW=0
  TRE_COST=0 TRE_COVERED=0 TRE_BILLED=0 TRE_HASPRICED=0
  TRE_UNK=0 TRE_UNKMODELS=""
  TRE_CLOSE="$close_date"
  local b model covered n cost cti cto ccr ccw
  while IFS=$'\t' read -r b model _provider covered _ticket n cost cti cto ccr ccw _source; do
    [ -n "$b" ] || continue
    TRE_SESSIONS=$((TRE_SESSIONS+n))
    TRE_TI=$((TRE_TI+cti)); TRE_TO=$((TRE_TO+cto))
    TRE_CR=$((TRE_CR+ccr)); TRE_CW=$((TRE_CW+ccw))
    if [ -n "$cost" ]; then
      TRE_HASPRICED=1
      TRE_COST=$(fadd "$TRE_COST" "$cost")
      if [ "$covered" = true ]; then
        TRE_COVERED=$(fadd "$TRE_COVERED" "$cost")
      else
        TRE_BILLED=$(fadd "$TRE_BILLED" "$cost")
      fi
    else
      TRE_UNK=$((TRE_UNK+cti+cto+ccr+ccw))
      if [ -z "$TRE_UNKMODELS" ]; then
        TRE_UNKMODELS=$model
      else
        case ",$TRE_UNKMODELS," in
          *",$model,"*) : ;;
          *) TRE_UNKMODELS="$TRE_UNKMODELS,$model" ;;
        esac
      fi
    fi
  done < "$costed_tmp"

  if [ "$JSON" -eq 1 ]; then
    TRE_ESTIMATE=true
    TRE_WSTART="$start_date"
    TRE_WEND="$close_date"
    emit_ticket_json
    return 0
  fi
  print_rollup_human "  ESTIMATE (coarse, date-window $start_date..$close_date)"
  printf '  [ESTIMATE: every session created in the window is attributed heuristically; this is NOT an exact per-ticket cost (D4)]\n'
}

# --- dispatch ----------------------------------------------------------------

if [ "$MODE" = session ]; then
  do_session
elif [ "$MODE" = ticket ]; then
  if [ "$RETRO" -eq 1 ]; then
    do_retro
  else
    do_ticket
  fi
else
  do_period
fi
