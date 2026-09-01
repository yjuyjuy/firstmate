#!/usr/bin/env bash
# Tests for the completions-anchored per-ticket cost rollup CLI
# (bin/fm-ticket-cost-rollup.sh).
#
# This CLI is the JOIN the work-report skill needs: it walks the completion
# ledger (data/completions.tsv), keeps the tickets whose close date is in the
# requested window, joins each to its token-session ledger rows
# (data/token-sessions.tsv), resolves those sessions in the jcode store, and
# prints ONE line per landed ticket with its exact cost-if-API - derived through
# the ONE coster lib (bin/fm-token-lib.sh), never a formula in the CLI.
#
# It is a READER: it changes nothing any producer records. So these tests point
# the env seams at committed fixtures under tests/fixtures/ticket-cost-rollup
# (its own price snapshot, completion + token-session ledgers, and a jcode store)
# via $JCODE_SESSIONS_DIR (the store), $FM_TOKEN_PRICES (the price snapshot), and
# $FM_DATA_OVERRIDE (the ledger dir), never the real home's files, and assert:
#   - a multi-session ticket sums every ledger session EXACTLY, including a
#     session whose store filename does not match its id (the scan fallback);
#   - the window bounds the ticket CLOSE date (since inclusive, until exclusive),
#     excluding an out-of-window ticket even though its session exists;
#   - a re-shipped ticket uses its LAST completion row for the window + display;
#   - a subscription-covered session lands in covered, an API session in billed;
#   - an unpriced model WITHHOLDS dollars (never a fabricated $0) and carries its
#     tokens in the ticket's unknown bucket;
#   - a landed ticket with a completion row but NO ledger rows is pre-capture:
#     sessions=0, cost n/a, never $0, and pointed at the labeled --retro path;
#   - a ledger session missing from the store is unresolved (tokens withheld);
#   - --repo filters to one project, --json shape is stable, and the number is
#     byte-identical to bin/fm-token-report.sh for the same ticket (single owner);
#   - invalid arguments and an absent completion ledger fail closed (non-zero).
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLI="$ROOT/bin/fm-ticket-cost-rollup.sh"
REPORT_CLI="$ROOT/bin/fm-token-report.sh"
FIX="$ROOT/tests/fixtures/ticket-cost-rollup"
STORE="$FIX/sessions"
PRICE="$FIX/prices.json"

run() { # invoke the CLI against the committed fixtures
  JCODE_SESSIONS_DIR="$STORE" FM_TOKEN_PRICES="$PRICE" FM_DATA_OVERRIDE="$FIX" "$CLI" "$@"
}

# The default window used by most cases: only the six 2026-08-13 tickets are in
# scope; ticket-outside (closed 2026-08-20) and the earlier ticket-reship row
# (2026-08-01) are excluded.
W="--since 2026-08-13 --until 2026-08-14"

# --- multi-session exact sum, including the store-scan fallback --------------

test_multi_session_sums_exactly() {
  # ticket-multi has two ledger sessions: sess-m1 (filename == id, 1M input =
  # $5.00) and sess-m2 (stored under session_odd_m2.json, a MISMATCHED filename,
  # 2M input = $10.00). The rollup must resolve BOTH - the second only via the
  # store scan that verifies the inner id - and sum to $15.00, never ESTIMATE.
  local out
  # shellcheck disable=SC2086
  out=$(run $W)
  assert_contains "$out" "ticket ticket-multi" "ticket-multi line missing: $out"
  assert_contains "$out" "ticket ticket-multi  repo=alpha  kind=ship  closed=2026-08-13  sessions=2" \
    "ticket-multi must count both ledger sessions: $out"
  assert_contains "$out" "cost_if_api \$15.00" "ticket-multi must sum 1M+2M -> \$15.00: $out"
  assert_not_contains "$out" "ESTIMATE" "the exact ledger rollup must never be labeled ESTIMATE: $out"
  pass "a multi-session ticket sums every ledger session exactly (\$15.00), incl. the filename-mismatch scan fallback"
}

# --- covered vs billed split --------------------------------------------------

test_covered_vs_billed_split() {
  # ticket-covered ran on claude-oauth (subscription-covered): its $5.00 must
  # land in covered, not api. ticket-multi ran on plain claude: api.
  local out json
  # shellcheck disable=SC2086
  out=$(run $W)
  assert_contains "$out" "ticket ticket-covered  repo=alpha  kind=ship  closed=2026-08-13  sessions=1  cost_if_api \$5.00  covered \$5.00 / api \$0.00" \
    "covered ticket must attribute its cost to covered, not api: $out"
  # shellcheck disable=SC2086
  json=$(run $W --json)
  printf '%s\n' "$json" | python3 -c '
import json, sys
o = json.load(sys.stdin)
byid = {t["ticket"]: t for t in o["tickets"]}
cov = byid["ticket-covered"]
assert abs(cov["cost_if_api_covered"] - 5.0) < 1e-9, cov
assert abs(cov["cost_if_api_billed"] - 0.0) < 1e-9, cov
multi = byid["ticket-multi"]
assert abs(multi["cost_if_api_billed"] - 15.0) < 1e-9, multi
assert abs(multi["cost_if_api_covered"] - 0.0) < 1e-9, multi
print("ok")
' >/dev/null || fail "covered/billed JSON split wrong: $json"
  pass "a subscription-covered session lands in covered, an API session in billed"
}

# --- window bounds the CLOSE date, excluding out-of-window sessions -----------

test_window_bounds_close_date() {
  # ticket-outside closed 2026-08-20 with a $45 session that EXISTS in the store;
  # the 08-13..08-14 window must exclude it entirely (never leak the $45), and a
  # broad window must include it.
  local out broad
  # shellcheck disable=SC2086
  out=$(run $W)
  assert_not_contains "$out" "ticket-outside" "out-of-window ticket must be excluded: $out"
  assert_not_contains "$out" "\$45.00" "an out-of-window session must not leak into scope: $out"
  broad=$(run --since 2026-08-01 --until 2026-08-21)
  assert_contains "$broad" "ticket ticket-outside" "a broad window must include the later ticket: $broad"
  assert_contains "$broad" "\$45.00" "the later ticket's \$45.00 must appear in a broad window: $broad"
  pass "the window bounds the ticket close date (since inclusive, until exclusive); out-of-window sessions never leak"
}

# --- re-ship: last completion row wins ---------------------------------------

test_reship_last_row_wins() {
  # ticket-reship has two completion rows: 2026-08-01 (scout) then 2026-08-13
  # (ship). The LAST row wins, so it appears (as ship, closed 2026-08-13) in the
  # 08-13 window and NOT in an 08-01 window.
  local inwin early
  # shellcheck disable=SC2086
  inwin=$(run $W)
  assert_contains "$inwin" "ticket ticket-reship  repo=alpha  kind=ship  closed=2026-08-13" \
    "re-ship must use its last completion row (ship, 2026-08-13): $inwin"
  early=$(run --since 2026-08-01 --until 2026-08-02)
  assert_not_contains "$early" "ticket-reship" "the superseded early completion row must not place the ticket in an 08-01 window: $early"
  pass "a re-shipped ticket uses its LAST completion row for the window and the displayed close date"
}

# --- unpriced model withholds dollars ----------------------------------------

test_unpriced_model_withholds_dollars() {
  # ticket-unpriced ran on 'mockmodel', absent from the price fixture: its
  # 500,000 tokens must be shown with dollars WITHHELD (UNKNOWN), never a $0, and
  # carried in the ticket's unknown-model bucket.
  local out json
  # shellcheck disable=SC2086
  out=$(run $W)
  assert_contains "$out" "ticket ticket-unpriced" "unpriced ticket line missing: $out"
  assert_contains "$out" "cost_if_api UNKNOWN (no price)  tokens 500,000" \
    "unpriced ticket must withhold dollars and show its tokens: $out"
  assert_contains "$out" "unknown-model tokens 500,000 | mockmodel" "unpriced ticket must name the unknown model: $out"
  assert_not_contains "$out" "ticket ticket-unpriced  repo=beta  kind=scout  closed=2026-08-13  sessions=1  cost_if_api \$0.00" \
    "an unpriced model must never render as \$0.00: $out"
  # shellcheck disable=SC2086
  json=$(run $W --json)
  printf '%s\n' "$json" | python3 -c '
import json, sys
o = json.load(sys.stdin)
byid = {t["ticket"]: t for t in o["tickets"]}
unp = byid["ticket-unpriced"]
assert unp["cost_if_api"] is None, unp
assert unp["unknown_model_tokens"] == 500000, unp
assert unp["unknown_models"] == ["mockmodel"], unp
print("ok")
' >/dev/null || fail "unpriced JSON must carry null cost + the unknown bucket: $json"
  pass "an unpriced model withholds dollars (never a fabricated \$0) and carries its tokens in the unknown bucket"
}

# --- pre-capture ticket: completion row, no ledger rows ----------------------

test_pre_capture_ticket_no_ledger() {
  # ticket-precapture has a completion row but NO token-session ledger row: it
  # must show sessions=0 and cost n/a (pre-capture), never $0, and the footer
  # must point at the labeled --retro estimate path.
  local out json
  # shellcheck disable=SC2086
  out=$(run $W)
  assert_contains "$out" "ticket ticket-precapture  repo=alpha  kind=ship  closed=2026-08-13  sessions=0  cost n/a (pre-capture, no ledger)" \
    "pre-capture ticket must show sessions=0 + cost n/a: $out"
  assert_contains "$out" "pre-capture (no ledger; see fm-token-report.sh <id> --retro" \
    "the footer must point a pre-capture ticket at the labeled --retro path: $out"
  # shellcheck disable=SC2086
  json=$(run $W --json)
  printf '%s\n' "$json" | python3 -c '
import json, sys
o = json.load(sys.stdin)
byid = {t["ticket"]: t for t in o["tickets"]}
pc = byid["ticket-precapture"]
assert pc["pre_capture"] is True, pc
assert pc["sessions"] == 0, pc
assert pc["ledger_sessions"] == 0, pc
assert pc["cost_if_api"] is None, pc
assert o["totals"]["pre_capture_tickets"] == 1, o["totals"]
print("ok")
' >/dev/null || fail "pre-capture JSON wrong: $json"
  pass "a landed ticket with no ledger rows is pre-capture (sessions=0, cost n/a, never \$0), pointed at --retro"
}

# --- unresolved ledger session: tokens withheld ------------------------------

test_unresolved_session_withheld() {
  # ticket-unresolved's only ledger session (sess-gone) is absent from the store:
  # it must be counted unresolved with its tokens withheld, sessions=0, cost n/a.
  local out json
  # shellcheck disable=SC2086
  out=$(run $W)
  assert_contains "$out" "ticket ticket-unresolved  repo=beta  kind=ship  closed=2026-08-13  sessions=0  cost n/a (sessions unavailable)" \
    "a ticket whose ledger session is missing from the store must show sessions=0 + cost n/a: $out"
  assert_contains "$out" "1 session(s) unavailable" "the unresolved session must be surfaced: $out"
  # shellcheck disable=SC2086
  json=$(run $W --json)
  printf '%s\n' "$json" | python3 -c '
import json, sys
o = json.load(sys.stdin)
byid = {t["ticket"]: t for t in o["tickets"]}
u = byid["ticket-unresolved"]
assert u["ledger_sessions"] == 1, u
assert u["unresolved_sessions"] == 1, u
assert u["sessions"] == 0, u
assert u["cost_if_api"] is None, u
print("ok")
' >/dev/null || fail "unresolved JSON wrong: $json"
  pass "a ledger session missing from the store is unresolved with its tokens withheld, never guessed"
}

# --- totals reconcile ---------------------------------------------------------

test_totals_reconcile() {
  # The six in-window tickets: multi $15 (api) + covered $5 (covered) + reship $2
  # (api) + precapture n/a + unpriced UNKNOWN + unresolved n/a. Priced total
  # $22.00 = covered $5.00 + api $17.00 across 5 resolved sessions.
  local out
  # shellcheck disable=SC2086
  out=$(run $W)
  assert_contains "$out" "total  tickets=6  sessions=5  cost_if_api \$22.00  covered \$5.00 / api \$17.00" \
    "grand total must reconcile: $out"
  pass "the grand total reconciles priced/covered/billed across the in-window tickets (\$22.00 = \$5.00 + \$17.00)"
}

# --- --repo filter ------------------------------------------------------------

test_repo_filter() {
  # --repo beta keeps only the two beta tickets (unpriced + unresolved), never
  # the alpha ones.
  local out
  # shellcheck disable=SC2086
  out=$(run $W --repo beta)
  assert_contains "$out" "ticket ticket-unpriced" "repo=beta must keep the beta unpriced ticket: $out"
  assert_contains "$out" "ticket ticket-unresolved" "repo=beta must keep the beta unresolved ticket: $out"
  assert_not_contains "$out" "ticket-multi" "repo=beta must drop alpha tickets: $out"
  assert_not_contains "$out" "ticket-covered" "repo=beta must drop alpha tickets: $out"
  pass "--repo filters the rollup to one project"
}

# --- single-owner parity with fm-token-report.sh -----------------------------

test_parity_with_token_report() {
  # The per-ticket cost MUST be byte-identical to bin/fm-token-report.sh's own
  # <task-id> rollup for the same ticket, because both derive every dollar from
  # the one coster lib. ticket-multi is the multi-session case.
  local mine theirs mine_cost theirs_cost mine_ti theirs_ti
  # shellcheck disable=SC2086
  mine=$(run $W --json)
  theirs=$(JCODE_SESSIONS_DIR="$STORE" FM_TOKEN_PRICES="$PRICE" FM_DATA_OVERRIDE="$FIX" "$REPORT_CLI" ticket-multi --json)
  mine_cost=$(printf '%s\n' "$mine" | python3 -c 'import json,sys; o=json.load(sys.stdin); print(round([t for t in o["tickets"] if t["ticket"]=="ticket-multi"][0]["cost_if_api"],6))')
  theirs_cost=$(printf '%s\n' "$theirs" | python3 -c 'import json,sys; print(round(json.load(sys.stdin)["cost_if_api"],6))')
  [ "$mine_cost" = "$theirs_cost" ] || fail "cost drift vs fm-token-report.sh: mine=$mine_cost theirs=$theirs_cost"
  mine_ti=$(printf '%s\n' "$mine" | python3 -c 'import json,sys; o=json.load(sys.stdin); print([t for t in o["tickets"] if t["ticket"]=="ticket-multi"][0]["token_input"])')
  theirs_ti=$(printf '%s\n' "$theirs" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token_input"])')
  [ "$mine_ti" = "$theirs_ti" ] || fail "token_input drift vs fm-token-report.sh: mine=$mine_ti theirs=$theirs_ti"
  pass "the per-ticket cost is byte-identical to fm-token-report.sh (single coster owner, no drift)"
}

# --- --json top-level shape is stable ----------------------------------------

test_json_shape_stable() {
  local json
  # shellcheck disable=SC2086
  json=$(run $W --json)
  printf '%s\n' "$json" | python3 -c '
import json, sys
o = json.load(sys.stdin)
assert o["mode"] == "ticket-rollup", o["mode"]
assert o["window"] == {"since": "2026-08-13", "until": "2026-08-14"}, o["window"]
for k in ("price_source", "price_cached_at", "tickets", "totals"):
    assert k in o, ("missing top-level key", k)
for t in o["tickets"]:
    for k in ("ticket", "close_date", "kind", "repo", "sessions", "cost_if_api",
              "cost_if_api_estimate", "unknown_model_tokens", "pre_capture"):
        assert k in t, ("missing ticket key", k, t)
    assert t["cost_if_api_estimate"] is False, t
tot = o["totals"]
for k in ("tickets", "sessions", "cost_if_api", "cost_if_api_covered",
          "cost_if_api_billed", "pre_capture_tickets", "unresolved_sessions"):
    assert k in tot, ("missing totals key", k)
print("ok")
' >/dev/null || fail "JSON shape unstable: $json"
  pass "--json output shape is stable (documented keys present, estimate always false)"
}

# --- guardrails: invalid args + absent ledger fail closed --------------------

test_fail_closed() {
  local status out
  run --since not-a-date >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "a malformed --since must exit non-zero"
  run --since 2026-08-20 --until 2026-08-10 >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "--since after --until must exit non-zero"
  run --bogus >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "an unknown option must exit non-zero"
  run stray-positional >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "an unexpected positional must exit non-zero"
  # An absent completion ledger (empty data dir) fails closed, never a silent
  # empty success.
  local empty
  empty=$(fm_test_tmproot ticket-cost-rollup-empty)
  out=$(JCODE_SESSIONS_DIR="$STORE" FM_TOKEN_PRICES="$PRICE" FM_DATA_OVERRIDE="$empty" "$CLI" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "an absent completion ledger must exit non-zero"
  assert_contains "$out" "no completion ledger" "the absent-ledger error must name the missing ledger: $out"
  pass "invalid arguments and an absent completion ledger fail closed (non-zero)"
}

# --- dual-format close field: mixed legacy date-only + new timestamped rows ---

test_dual_format_close_field_windows_by_day() {
  # A completions ledger holding BOTH a legacy bare-date row and a new
  # full-timestamp row must window each on its calendar day. Build a temp data
  # dir with an empty token ledger (no session rows needed: the assertion is on
  # window inclusion by close DAY, not on cost).
  local data out
  data=$(fm_test_tmproot ticket-cost-rollup-dual)
  mkdir -p "$data"
  {
    printf '# firstmate completion ledger\n'
    printf 'tk-old\t2026-08-13\tship\talpha\tsha-old\n'
    printf 'tk-new\t2026-08-13T01:35:29Z\tship\talpha\tsha-new\n'
    printf 'tk-out\t2026-08-20T23:59:59Z\tship\talpha\tsha-out\n'
  } > "$data/completions.tsv"
  : > "$data/token-sessions.tsv"
  out=$(JCODE_SESSIONS_DIR="$STORE" FM_TOKEN_PRICES="$PRICE" FM_DATA_OVERRIDE="$data" \
    "$CLI" --since 2026-08-13 --until 2026-08-14 2>&1) \
    || fail "rollup failed on a mixed-format ledger: $out"
  assert_contains "$out" "ticket tk-old" "legacy bare-date row must be in the day window: $out"
  assert_contains "$out" "ticket tk-new" "new timestamped row must window on its day: $out"
  assert_not_contains "$out" "tk-out" "an out-of-window timestamped row must not leak: $out"
  # The new row displays its full timestamp verbatim; the legacy row stays bare.
  assert_contains "$out" "closed=2026-08-13T01:35:29Z" "new row must display its full timestamp: $out"
  assert_contains "$out" "closed=2026-08-13  " "legacy row must display its bare date: $out"
  pass "the rollup windows a mixed legacy-and-timestamped ledger by calendar day"
}

test_multi_session_sums_exactly
test_covered_vs_billed_split
test_window_bounds_close_date
test_dual_format_close_field_windows_by_day
test_reship_last_row_wins
test_unpriced_model_withholds_dollars
test_pre_capture_ticket_no_ledger
test_unresolved_session_withheld
test_totals_reconcile
test_repo_filter
test_parity_with_token_report
test_json_shape_stable
test_fail_closed
