#!/usr/bin/env bash
# fm-ticket-cost-rollup.sh - real dollar cost per LANDED ticket, one line each.
#
# The completions-anchored per-ticket cost join the work-report skill needs.
# bin/fm-token-report.sh already reports per-session, per-period, and a single
# <task-id> rollup, but none of its paths answers "for every ticket that landed
# in this window, what did it cost": its bare <task-id> rollup is one ticket at a
# time and its --period --by-ticket buckets the SESSION STORE (with an
# "unattributed" bucket for sessions with no ticket), not the completion ledger.
# This tool inverts that: it walks data/completions.tsv (the durable, never-pruned
# record of every task that reached teardown), keeps the tickets whose close date
# falls in the window, joins each to its data/token-sessions.tsv ledger rows,
# resolves those sessions in the jcode store, and prints ONE line per ticket with
# its exact cost-if-API. So /work-report can tabulate cost against the same
# landed-ticket population it already reports.
#
# Read-only. Reads the jcode session store ($JCODE_SESSIONS_DIR, default
# ~/.jcode/sessions), the completion + token-session ledgers under the data dir
# (data/completions.tsv + data/token-sessions.tsv, resolved through their owning
# libs), derives cost through bin/fm-token-lib.sh, and writes nothing and changes
# nothing any producer records.
#
# ONE-OWNER-PER-CONTRACT (the same architecture bin/fm-token-report.sh uses, and
# the reason the number here is byte-identical to it): every dollar figure is
# produced by bin/fm-token-lib.sh, never by a formula in this file. Cost is
# linear in token counts for a fixed model+provider, so this script:
#   1. aggregates RAW token sums per (ticket, model, provider, route) in ONE bulk
#      python pass over only the ledger sessions in scope (never a per-session
#      shell fork, never a scan of the whole store when the filename convention
#      resolves the id),
#   2. costs each aggregated group through the lib's fm_token_cost (the count of
#      lib calls is bounded by tickets x models, not by session count), with the
#      session provider_key resolved to its models.dev provider table
#      (fm_token_resolve_provider) so a model billed by several providers costs at
#      the table that actually billed it, and
#   3. SUMS those lib-produced costs per ticket (pure addition, not costing).
#
# Standing captain constraints honored here (identical to fm-token-report.sh):
#   - a real token count with no price is UNKNOWN (dollars withheld), never a
#     fabricated $0: those tokens are carried in a per-ticket unknown-model bucket
#     and never folded into a dollar total;
#   - the forward-captured ledger rollup is EXACT, so cost_if_api_estimate is
#     always false here; this tool has no estimate path (the coarse date-window
#     ESTIMATE lives in fm-token-report.sh --retro, deliberately not duplicated);
#   - a landed ticket that predates the spawn session-id capture has a completion
#     row but NO ledger rows: it is shown with sessions=0 and cost n/a labeled
#     "pre-capture, no ledger", never $0 and never guessed (fm-token-report.sh
#     <task-id> --retro is the labeled estimate path for such a ticket);
#   - a ledger session missing from the store is counted unresolved with its
#     tokens withheld, never guessed.
#
# Window: --since / --until bound the ticket close date, since INCLUSIVE and
# until EXCLUSIVE, both whole ISO-8601 dates (YYYY-MM-DD). completions.tsv's
# close field is either a bare UTC date (legacy rows) or a full UTC timestamp
# (rows from 2026-09 on); both begin with the 10-char date, so the comparison
# normalizes the field to its calendar day first (close_day) - a pure ISO
# date-string compare, no timezone reinterpretation of a day the ledger already
# fixed. Omit both for all
# landed tickets. When a ticket has several completion rows (a re-ship), the LAST
# row wins for both the window test and the displayed close date, matching the
# rest of the completion machinery (fm-token-report.sh --retro, the dispatch
# guard). The work-report skill resolves ONE window and passes the identical
# --since/--until it feeds every other counter, so all its numbers share bounds.
#
# Usage:
#   fm-ticket-cost-rollup.sh                      every landed ticket, costliest first
#   fm-ticket-cost-rollup.sh --since D --until D  tickets whose close date is in [D, D)
#   fm-ticket-cost-rollup.sh --repo <name>        only tickets landed in that repo
#   fm-ticket-cost-rollup.sh --json               stable machine output
#   fm-ticket-cost-rollup.sh --help               print this header
#
# The data dir for the ledgers is $FM_DATA_OVERRIDE, else $FM_HOME/data, else
# <repo-root>/data (the standard firstmate override chain), and the price
# snapshot is $FM_TOKEN_PRICES else <repo-root>/config/token-prices.json, so
# tests and the dashboard point them at fixtures, never the real ones.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# FM_ROOT/FM_HOME/DATA and die (exit 2 default) come from the shared preamble.
FM_PROG=fm-ticket-cost-rollup FM_DIE_CODE=2
# shellcheck source=bin/fm-preamble-lib.sh
. "$SCRIPT_DIR/fm-preamble-lib.sh"

# shellcheck source=bin/fm-token-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-token-lib.sh"
# shellcheck source=bin/fm-token-sessions-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-token-sessions-lib.sh"
# shellcheck source=bin/fm-completions-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-completions-lib.sh"

usage() {
  sed -n '2,72p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- argument parse ----------------------------------------------------------

SINCE=""
UNTIL=""
REPO=""
JSON=0

is_iso_date() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --since)
      [ $# -ge 2 ] || die "--since needs a date (YYYY-MM-DD)"
      SINCE=$2; shift 2 ;;
    --since=*) SINCE=${1#--since=}; shift ;;
    --until)
      [ $# -ge 2 ] || die "--until needs a date (YYYY-MM-DD)"
      UNTIL=$2; shift 2 ;;
    --until=*) UNTIL=${1#--until=}; shift ;;
    --repo)
      [ $# -ge 2 ] || die "--repo needs a project name"
      REPO=$2; shift 2 ;;
    --repo=*) REPO=${1#--repo=}; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) die "unknown option '$1' (try --help)" ;;
    *) die "unexpected argument '$1' (this tool takes options only; try --help)" ;;
  esac
done

[ -z "$SINCE" ] || is_iso_date "$SINCE" || die "--since must be YYYY-MM-DD (got '$SINCE')"
[ -z "$UNTIL" ] || is_iso_date "$UNTIL" || die "--until must be YYYY-MM-DD (got '$UNTIL')"
if [ -n "$SINCE" ] && [ -n "$UNTIL" ] && [ "$SINCE" \> "$UNTIL" ]; then
  die "--since '$SINCE' is after --until '$UNTIL'"
fi

command -v python3 >/dev/null 2>&1 || die "python3 is required to parse the jcode session store" 3

SESSIONS_DIR=${JCODE_SESSIONS_DIR:-$HOME/.jcode/sessions}
PRICE_FILE=$(fm_token_prices_path)
PRICE_SOURCE=$(fm_token_prices_field price_source "$PRICE_FILE" 2>/dev/null || true)
PRICE_CACHED=$(fm_token_prices_field cached_at "$PRICE_FILE" 2>/dev/null || true)
COMPLETIONS_FILE=$(fm_completions_file "$DATA")
TOKEN_SESSIONS_FILE=$(fm_token_sessions_file "$DATA")

[ -f "$COMPLETIONS_FILE" ] || die "no completion ledger at $COMPLETIONS_FILE (no landed ticket to roll up)" 1

# Float addition with full display precision. Used ONLY to sum lib-produced
# costs (pure addition, never a new cost formula), exactly as fm-token-report.sh.
fadd() {
  awk -v a="$1" -v b="$2" 'BEGIN{printf "%.12f", a+b}'
}

# --- Pass A: bulk join, RAW token aggregation only (no costing here) ----------
#
# One python pass produces two record kinds on stdout, tab-separated:
#   T<TAB>ticket<TAB>close_date<TAB>kind<TAB>repo<TAB>ledger_sessions<TAB>resolved<TAB>unresolved
#     one per in-window landed ticket (last completion row wins);
#   A<TAB>ticket<TAB>model<TAB>provider<TAB>route<TAB>ti<TAB>to<TAB>cr<TAB>cw
#     one per (ticket, model, provider, route) with summed RAW tokens.
# A ticket with a completion row but no ledger sessions still emits its T line
# with ledger_sessions=0 (the pre-capture case). Only the ledger sessions that
# belong to an in-window ticket are opened; the store is scanned in full at most
# once, and only for session ids the filename convention did not resolve.
aggregate_ticket_tokens() {
  FM_TCR_COMPLETIONS="$COMPLETIONS_FILE" FM_TCR_LEDGER="$TOKEN_SESSIONS_FILE" \
    FM_TCR_STORE="$SESSIONS_DIR" FM_TCR_SINCE="$SINCE" FM_TCR_UNTIL="$UNTIL" \
    FM_TCR_REPO="$REPO" python3 - <<'PY'
import glob
import json
import os
import sys

completions_file = os.environ["FM_TCR_COMPLETIONS"]
ledger_file = os.environ["FM_TCR_LEDGER"]
store = os.environ["FM_TCR_STORE"]
since = os.environ.get("FM_TCR_SINCE", "").strip()
until = os.environ.get("FM_TCR_UNTIL", "").strip()
repo_filter = os.environ.get("FM_TCR_REPO", "").strip()


def close_day(value):
    # The completions close field is either a bare date (legacy rows) or a full
    # ISO-8601 timestamp (rows from 2026-09 on); both begin with the 10-char
    # date, so the leading 10 chars are the calendar day in either format.
    return value[:10]


def in_window(close_date):
    # ISO calendar dates compare correctly as strings; since inclusive, until
    # exclusive. An empty bound is open on that side. Normalize to the day first
    # so a full-timestamp close field windows on its calendar day.
    day = close_day(close_date)
    if since and day < since:
        return False
    if until and day >= until:
        return False
    return True


# 1. Completions: LAST row per id wins (re-ship), matching fm_completions_lookup
#    order + the retro tail rule. Keep only in-window (and, if asked, in-repo).
tickets = {}
try:
    with open(completions_file) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 4:
                continue
            tid, close_date, kind, repo = parts[0], parts[1], parts[2], parts[3]
            if not tid or not close_date:
                continue
            # Last row wins: a later row for the same id overwrites the earlier.
            tickets[tid] = {"close_date": close_date, "kind": kind, "repo": repo}
except OSError as exc:
    sys.stderr.write("fm-ticket-cost-rollup: cannot read completions %s: %s\n" % (completions_file, exc))
    sys.exit(1)

scoped = {}
for tid, meta in tickets.items():
    if not in_window(meta["close_date"]):
        continue
    if repo_filter and meta["repo"] != repo_filter:
        continue
    scoped[tid] = meta

# 2. Ledger: ticket -> ordered unique session ids, only for scoped tickets.
ticket_sids = {tid: [] for tid in scoped}
seen = {tid: set() for tid in scoped}
if os.path.isfile(ledger_file):
    try:
        with open(ledger_file) as fh:
            for line in fh:
                line = line.rstrip("\n")
                if not line or line.startswith("#"):
                    continue
                parts = line.split("\t")
                if len(parts) < 2:
                    continue
                tid, sid = parts[0], parts[1]
                if tid not in scoped or not sid:
                    continue
                if sid in seen[tid]:
                    continue
                seen[tid].add(sid)
                ticket_sids[tid].append(sid)
    except OSError:
        pass

# 3. Resolve every needed session id to a store path. Try the filename==id
#    convention first (O(1)); scan the store ONCE only for the remainder, and
#    only when something is still unresolved. A resolved path is verified to
#    carry the wanted inner id so a stale/foreign filename never mis-binds.
needed = set()
for sids in ticket_sids.values():
    needed.update(sids)

sid_to_path = {}


def inner_id(path):
    try:
        with open(path) as fh:
            return json.load(fh).get("id")
    except (OSError, ValueError):
        return None


for sid in needed:
    cand = os.path.join(store, sid + ".json")
    if os.path.isfile(cand) and inner_id(cand) == sid:
        sid_to_path[sid] = cand

missing = [s for s in needed if s not in sid_to_path]
if missing and os.path.isdir(store):
    want = set(missing)
    for path in glob.glob(os.path.join(store, "session_*.json")):
        if not want:
            break
        sid = inner_id(path)
        if sid in want:
            sid_to_path[sid] = path
            want.discard(sid)

# 4. Sum RAW tokens per session, then aggregate per (ticket, model, provider,
#    route). A session id with no resolved path is unresolved (tokens withheld).
session_cache = {}


def sum_session(path):
    cached = session_cache.get(path)
    if cached is not None:
        return cached
    try:
        with open(path) as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        session_cache[path] = None
        return None
    ti = to = cr = cw = 0
    for m in d.get("messages") or []:
        if m.get("role") != "assistant":
            continue
        tu = m.get("token_usage")
        if not isinstance(tu, dict):
            continue
        ti += int(tu.get("input_tokens", 0) or 0)
        to += int(tu.get("output_tokens", 0) or 0)
        cr += int(tu.get("cache_read_input_tokens", 0) or 0)
        cw += int(tu.get("cache_creation_input_tokens", 0) or 0)
    res = (
        str(d.get("model") or "unknown"),
        str(d.get("provider_key") or "None"),
        str(d.get("route_api_method") or "None"),
        ti,
        to,
        cr,
        cw,
    )
    session_cache[path] = res
    return res


out = []
for tid in sorted(scoped):
    meta = scoped[tid]
    sids = ticket_sids[tid]
    ledger_n = len(sids)
    resolved_n = 0
    unresolved_n = 0
    agg = {}
    for sid in sids:
        path = sid_to_path.get(sid)
        if path is None:
            unresolved_n += 1
            continue
        res = sum_session(path)
        if res is None:
            unresolved_n += 1
            continue
        resolved_n += 1
        model, provider, route, ti, to, cr, cw = res
        key = (model, provider, route)
        row = agg.get(key)
        if row is None:
            row = [0, 0, 0, 0]
            agg[key] = row
        row[0] += ti
        row[1] += to
        row[2] += cr
        row[3] += cw
    out.append(
        "T\t%s\t%s\t%s\t%s\t%d\t%d\t%d"
        % (tid, meta["close_date"], meta["kind"], meta["repo"], ledger_n, resolved_n, unresolved_n)
    )
    for (model, provider, route), row in agg.items():
        out.append(
            "A\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d"
            % (tid, model, provider, route, row[0], row[1], row[2], row[3])
        )

sys.stdout.write("\n".join(out))
if out:
    sys.stdout.write("\n")
PY
}

# --- Pass B: cost every aggregated (ticket, model, provider) group via the lib -
#
# The single insertion point of every dollar figure: fm_token_cost is the ONLY
# place a cost is computed, memoized per (provider,model) so an unpriced model
# never spawns a repeat cost call. Reads the Pass A stream from $1 and writes one
# costed record per ticket to $2, tab-separated:
#   ticket close_date kind repo ledger resolved unresolved sessions
#   has_priced cost covered billed unk_tokens unk_models ti to cr cw
# where sessions == resolved (sessions that actually contributed tokens), cost /
# covered / billed are full-precision decimals, and unk_models is comma-joined.
cost_ticket_rows() {
  local agg_file=$1 costed_file=$2
  local -A COVERED_CACHE=()
  local -A PRICED_CACHE=()
  local -A RESOLVED_CACHE=()

  # Per-ticket accumulators, flushed on the next T line and at EOF.
  local cur="" c_close="" c_kind="" c_repo="" c_ledger=0 c_resolved=0 c_unresolved=0
  local c_haspriced=0 c_cost=0 c_covered=0 c_billed=0 c_unk=0 c_unkmodels=""
  local c_ti=0 c_to=0 c_cr=0 c_cw=0

  flush() {
    [ -n "$cur" ] || return 0
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$cur" "$c_close" "$c_kind" "$c_repo" "$c_ledger" "$c_resolved" "$c_unresolved" \
      "$c_resolved" "$c_haspriced" "$c_cost" "$c_covered" "$c_billed" \
      "$c_unk" "$c_unkmodels" "$c_ti" "$c_to" "$c_cr" "$c_cw" >> "$costed_file"
  }

  : > "$costed_file"
  local rectype f2 f3 f4 f5 f6 f7 f8 f9
  while IFS=$'\t' read -r rectype f2 f3 f4 f5 f6 f7 f8 f9; do
    case "$rectype" in
      T)
        flush
        cur=$f2; c_close=$f3; c_kind=$f4; c_repo=$f5
        c_ledger=$f6; c_resolved=$f7; c_unresolved=$f8
        c_haspriced=0; c_cost=0; c_covered=0; c_billed=0; c_unk=0; c_unkmodels=""
        c_ti=0; c_to=0; c_cr=0; c_cw=0
        ;;
      A)
        # f2=ticket f3=model f4=provider f5=route f6=ti f7=to f8=cr f9=cw
        local model=$f3 provider=$f4 route=$f5 ti=$f6 to=$f7 cr=$f8 cw=$f9
        local pkey ckey rkey resolved cov cost
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

        c_ti=$((c_ti+ti)); c_to=$((c_to+to)); c_cr=$((c_cr+cr)); c_cw=$((c_cw+cw))

        cost=""
        if [ "${PRICED_CACHE[$ckey]}" = 1 ]; then
          cost=$(fm_token_cost "$ti" "$to" "$cr" "$cw" "$model" "$PRICE_FILE" "$resolved") || cost=""
        fi
        if [ -n "$cost" ]; then
          c_haspriced=1
          c_cost=$(fadd "$c_cost" "$cost")
          if [ "$cov" = true ]; then
            c_covered=$(fadd "$c_covered" "$cost")
          else
            c_billed=$(fadd "$c_billed" "$cost")
          fi
        else
          c_unk=$((c_unk+ti+to+cr+cw))
          if [ -z "$c_unkmodels" ]; then
            c_unkmodels=$model
          else
            case ",$c_unkmodels," in
              *",$model,"*) : ;;
              *) c_unkmodels="$c_unkmodels,$model" ;;
            esac
          fi
        fi
        ;;
    esac
  done < "$agg_file"
  flush
}

# --- Pass C: render one line per ticket (human or --json) --------------------

render() {
  local costed_file=$1
  FM_TCR_COSTED="$costed_file" FM_TCR_JSON="$JSON" FM_TCR_SINCE="$SINCE" \
    FM_TCR_UNTIL="$UNTIL" FM_TCR_REPO="$REPO" FM_TCR_PS="$PRICE_SOURCE" \
    FM_TCR_PC="$PRICE_CACHED" python3 - <<'PY'
import json
import os
import sys

costed = os.environ["FM_TCR_COSTED"]
as_json = os.environ.get("FM_TCR_JSON", "") == "1"
since = os.environ.get("FM_TCR_SINCE", "")
until = os.environ.get("FM_TCR_UNTIL", "")
repo_filter = os.environ.get("FM_TCR_REPO", "")
price_source = os.environ.get("FM_TCR_PS", "")
price_cached = os.environ.get("FM_TCR_PC", "")

rows = []
with open(costed) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) != 18:
            continue
        (
            ticket, close_date, kind, repo, ledger, resolved, unresolved,
            sessions, has_priced, cost, covered, billed, unk, unk_models,
            ti, to, cr, cw,
        ) = parts
        rows.append(
            {
                "ticket": ticket,
                "close_date": close_date,
                "kind": kind,
                "repo": repo,
                "ledger_sessions": int(ledger),
                "resolved_sessions": int(resolved),
                "unresolved_sessions": int(unresolved),
                "sessions": int(sessions),
                "has_priced": has_priced == "1",
                # Pass B always writes a numeric cost (0 when nothing priced).
                "cost": float(cost) if cost else 0.0,
                "covered": float(covered),
                "billed": float(billed),
                "unknown_model_tokens": int(unk),
                "unknown_models": [m for m in unk_models.split(",") if m],
                "token_input": int(ti),
                "token_output": int(to),
                "token_cache_read": int(cr),
                "token_cache_write": int(cw),
                "pre_capture": int(ledger) == 0,
            }
        )


def cost_key(r):
    # Priced tickets first, costliest first, then ticket id for determinism.
    return (0 if r["has_priced"] else 1, -(r["cost"] if r["has_priced"] else 0.0), r["ticket"])


rows.sort(key=cost_key)

# Grand totals across every ticket in scope.
tot = {
    "tickets": len(rows),
    "sessions": 0,
    "cost": 0.0,
    "covered": 0.0,
    "billed": 0.0,
    "unk_tokens": 0,
    "ti": 0,
    "to": 0,
    "cr": 0,
    "cw": 0,
    "has_priced": False,
    "unk_models": set(),
    "pre_capture": 0,
    "unresolved": 0,
}
for r in rows:
    tot["sessions"] += r["sessions"]
    tot["ti"] += r["token_input"]
    tot["to"] += r["token_output"]
    tot["cr"] += r["token_cache_read"]
    tot["cw"] += r["token_cache_write"]
    tot["unk_tokens"] += r["unknown_model_tokens"]
    tot["unk_models"] |= set(r["unknown_models"])
    tot["unresolved"] += r["unresolved_sessions"]
    if r["pre_capture"]:
        tot["pre_capture"] += 1
    if r["has_priced"]:
        tot["cost"] += r["cost"]
        tot["covered"] += r["covered"]
        tot["billed"] += r["billed"]
        tot["has_priced"] = True


def commafy(n):
    return "{:,}".format(int(n))


def money(x):
    return "{:.2f}".format(x)


if as_json:
    out_rows = []
    for r in rows:
        out_rows.append(
            {
                "ticket": r["ticket"],
                "close_date": r["close_date"],
                "kind": r["kind"],
                "repo": r["repo"],
                "sessions": r["sessions"],
                "ledger_sessions": r["ledger_sessions"],
                "unresolved_sessions": r["unresolved_sessions"],
                "pre_capture": r["pre_capture"],
                "token_input": r["token_input"],
                "token_output": r["token_output"],
                "token_cache_read": r["token_cache_read"],
                "token_cache_write": r["token_cache_write"],
                "cost_if_api": round(r["cost"], 6) if r["has_priced"] else None,
                "cost_if_api_covered": round(r["covered"], 6),
                "cost_if_api_billed": round(r["billed"], 6),
                "cost_if_api_estimate": False,
                "unknown_model_tokens": r["unknown_model_tokens"],
                "unknown_models": sorted(r["unknown_models"]),
            }
        )
    obj = {
        "mode": "ticket-rollup",
        "window": {"since": since or None, "until": until or None},
        "repo": repo_filter or None,
        "price_source": price_source or None,
        "price_cached_at": price_cached or None,
        "tickets": out_rows,
        "totals": {
            "tickets": tot["tickets"],
            "sessions": tot["sessions"],
            "pre_capture_tickets": tot["pre_capture"],
            "unresolved_sessions": tot["unresolved"],
            "token_input": tot["ti"],
            "token_output": tot["to"],
            "token_cache_read": tot["cr"],
            "token_cache_write": tot["cw"],
            "cost_if_api": round(tot["cost"], 6) if tot["has_priced"] else None,
            "cost_if_api_covered": round(tot["covered"], 6),
            "cost_if_api_billed": round(tot["billed"], 6),
            "cost_if_api_estimate": False,
            "unknown_model_tokens": tot["unk_tokens"],
            "unknown_models": sorted(tot["unk_models"]),
        },
    }
    json.dump(obj, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    sys.exit(0)

# Human (caveman, aligned): one line per ticket.
win = "%s..%s" % (since or "-", until or "-") if (since or until) else "all"
src = ("%s @%s" % (price_source, price_cached)) if price_source else "UNKNOWN (no snapshot)"
scope = "  repo=%s" % repo_filter if repo_filter else ""
sys.stdout.write("landed tickets %s%s  price %s\n" % (win, scope, src))

if not rows:
    sys.stdout.write("no landed ticket in scope\n")
    sys.exit(0)

for r in rows:
    tail = ""
    notes = []
    if r["unknown_model_tokens"] > 0:
        notes.append("unknown-model tokens %s | %s" % (commafy(r["unknown_model_tokens"]), ",".join(sorted(r["unknown_models"]))))
    if r["unresolved_sessions"] > 0:
        notes.append("%d session(s) unavailable" % r["unresolved_sessions"])
    if notes:
        tail = "  [%s]" % " ; ".join(notes)
    head = "ticket %s  repo=%s  kind=%s  closed=%s  sessions=%d" % (
        r["ticket"], r["repo"], r["kind"], r["close_date"], r["sessions"],
    )
    if r["pre_capture"]:
        sys.stdout.write("%s  cost n/a (pre-capture, no ledger)%s\n" % (head, tail))
    elif r["has_priced"]:
        sys.stdout.write(
            "%s  cost_if_api $%s  covered $%s / api $%s%s\n"
            % (head, money(r["cost"]), money(r["covered"]), money(r["billed"]), tail)
        )
    elif r["sessions"] > 0:
        toks = r["token_input"] + r["token_output"] + r["token_cache_read"] + r["token_cache_write"]
        sys.stdout.write("%s  cost_if_api UNKNOWN (no price)  tokens %s%s\n" % (head, commafy(toks), tail))
    else:
        # Ledger rows exist but none resolved in the store: tokens unavailable.
        sys.stdout.write("%s  cost n/a (sessions unavailable)%s\n" % (head, tail))

# Grand total line.
if tot["has_priced"]:
    sys.stdout.write(
        "total  tickets=%d  sessions=%d  cost_if_api $%s  covered $%s / api $%s\n"
        % (tot["tickets"], tot["sessions"], money(tot["cost"]), money(tot["covered"]), money(tot["billed"]))
    )
else:
    sys.stdout.write("total  tickets=%d  sessions=%d  cost_if_api UNKNOWN (no priced tokens)\n" % (tot["tickets"], tot["sessions"]))
if tot["pre_capture"] > 0:
    sys.stdout.write("  %d ticket(s) pre-capture (no ledger; see fm-token-report.sh <id> --retro for a labeled estimate)\n" % tot["pre_capture"])
PY
}

# --- dispatch ----------------------------------------------------------------

main() {
  local agg_tmp costed_tmp
  agg_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-ticket-cost-rollup.aggXXXXXX")
  costed_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-ticket-cost-rollup.costXXXXXX")
  trap 'rm -f "$agg_tmp" "$costed_tmp"' RETURN

  aggregate_ticket_tokens > "$agg_tmp"
  cost_ticket_rows "$agg_tmp" "$costed_tmp"
  render "$costed_tmp"
}

main
