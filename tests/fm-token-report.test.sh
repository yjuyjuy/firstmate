#!/usr/bin/env bash
# Tests for the token usage + cost reporting CLI (bin/fm-token-report.sh) -
# PR-T2 of the token-usage-visibility design of record.
#
# Design of record: data/design-token-usage-visibility/report.md, section
# "PR-T2" and its test list (line 188); captain decisions D1/D2/D5 in
# data/design-token-usage-visibility/decisions-d1-d2-d5.md.
#
# The CLI is JOIN-FREE (no per-ticket rollup; that is PR-T4). It is a READER: it
# reads the jcode session store ($JCODE_SESSIONS_DIR) and the owned price
# snapshot ($FM_TOKEN_PRICES) and derives every dollar figure through the ONE
# coster lib bin/fm-token-lib.sh. These tests therefore point both env seams at
# committed-shaped fixtures written into the suite's temp store (never the real
# ~/.jcode/sessions), and assert:
#   - --session on a fixture matches the PR-T1 lib numbers EXACTLY (the coster is
#     the single owner, so the CLI must not drift from it);
#   - --period sums a date range correctly, and its window is inclusive by day;
#   - --by day places sessions in the right day buckets, and a >1h session lands
#     WHOLE in its start bucket by default (D5 option a) but SPLITS per message
#     under --precise (D5 option b), with the same grand total both ways;
#   - --json output shape is stable (documented keys present, cost a number or
#     null, estimate=false);
#   - the unknown-model row WITHHOLDS dollars (never a fabricated $0) and carries
#     its tokens in a separate unknown bucket;
#   - --by-model / --by-provider group correctly and compose with --by <unit>.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

CLI="$ROOT/bin/fm-token-report.sh"
# shellcheck source=bin/fm-token-lib.sh disable=SC1091
. "$ROOT/bin/fm-token-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-token-report-tests)
STORE="$TMP_ROOT/sessions"
PRICE="$TMP_ROOT/prices.json"
mkdir -p "$STORE"

# Owned-snapshot-shaped price fixture: real anthropic USD-per-Mtok values, the
# same header shape bin/fm-token-prices.sh writes. claude-opus-4-8 is priced;
# 'mock' is deliberately ABSENT so the unknown-model path is exercised.
cat > "$PRICE" <<'JSON'
{
  "price_source": "jcode-models-dev-cache",
  "cached_at": "2026-08-17T00:03:10Z",
  "prices": {
    "claude-opus-4-8": {"input_usd_per_mtok": 5, "output_usd_per_mtok": 25, "cache_read_usd_per_mtok": 0.5, "cache_write_usd_per_mtok": 6.25},
    "claude-sonnet-5": {"input_usd_per_mtok": 2, "output_usd_per_mtok": 10, "cache_read_usd_per_mtok": 0.2, "cache_write_usd_per_mtok": 2.5}
  }
}
JSON

# Write one jcode-shaped session file into the fixture store.
# Args: name model provider route created_at messages_json
write_session() {
  local name=$1 model=$2 provider=$3 route=$4 created=$5 messages=$6
  cat > "$STORE/session_$name.json" <<JSON
{"id":"session_$name","model":"$model","provider_key":"$provider","route_api_method":$route,"created_at":"$created","updated_at":"$created","messages":$messages}
JSON
}

run() { # invoke the CLI against the fixture store + price fixture
  JCODE_SESSIONS_DIR="$STORE" FM_TOKEN_PRICES="$PRICE" "$CLI" "$@"
}

# --- --session matches PR-T1 lib numbers exactly ------------------------------

test_session_matches_lib_exactly() {
  # An opus session split across two assistant messages plus one message with no
  # token_usage (must contribute nothing), provider claude = API-metered.
  write_session s_one "claude-opus-4-8" "claude" "null" "2026-08-13T10:00:00.000Z" '[
    {"role":"user","content":"x"},
    {"role":"assistant","timestamp":"2026-08-13T10:00:01.000Z","token_usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":200000,"cache_creation_input_tokens":4000}},
    {"role":"assistant","timestamp":"2026-08-13T10:05:00.000Z","token_usage":{"input_tokens":3000,"output_tokens":1500,"cache_read_input_tokens":800000,"cache_creation_input_tokens":6000}},
    {"role":"assistant","content":"no usage here"}
  ]'
  # The lib is the single owner of the number; the CLI must equal it exactly.
  local lib_cost cli_json cli_cost
  lib_cost=$(fm_token_cost 4000 2000 1000000 10000 "claude-opus-4-8" "$PRICE")
  cli_json=$(run --session session_s_one --json)
  # token sums exact
  case "$cli_json" in
    *'"token_input": 4000'*) : ;; *) fail "session token_input wrong: $cli_json" ;;
  esac
  case "$cli_json" in
    *'"token_output": 2000'*) : ;; *) fail "session token_output wrong: $cli_json" ;;
  esac
  case "$cli_json" in
    *'"token_cache_read": 1000000'*) : ;; *) fail "session token_cache_read wrong: $cli_json" ;;
  esac
  case "$cli_json" in
    *'"token_cache_write": 10000'*) : ;; *) fail "session token_cache_write wrong: $cli_json" ;;
  esac
  # cost equals the lib's, rounded to the JSON's 6 places
  cli_cost=$(printf '%s\n' "$cli_json" | sed -n 's/.*"cost_if_api": \([0-9.]*\).*/\1/p')
  local want
  want=$(python3 -c "print(round(float('$lib_cost'),6))")
  [ "$cli_cost" = "$want" ] || fail "CLI cost $cli_cost != lib cost $want (single-owner drift)"
  # PR-T1 math is exact, never labeled ESTIMATE, and the covered flag is honest.
  case "$cli_json" in
    *'"cost_if_api_estimate": false'*) : ;; *) fail "session must not be labeled estimate: $cli_json" ;;
  esac
  case "$cli_json" in
    *'"subscription_covered": false'*) : ;; *) fail "plain claude must not be covered: $cli_json" ;;
  esac
  pass "--session matches the PR-T1 coster lib exactly (token sums + cost, not estimate)"
}

# --- --period sums a date range correctly, inclusive by day -------------------

test_period_sums_range() {
  # Two opus sessions on adjacent days, plus one OUTSIDE the requested range that
  # must be excluded. Use a store isolated from the other tests' sessions.
  local store2="$TMP_ROOT/range-store"
  mkdir -p "$store2"
  cat > "$store2/session_in1.json" <<'JSON'
{"id":"session_in1","model":"claude-opus-4-8","provider_key":"claude","route_api_method":null,"created_at":"2026-08-13T09:00:00.000Z","updated_at":"2026-08-13T09:10:00.000Z","messages":[{"role":"assistant","timestamp":"2026-08-13T09:00:00.000Z","token_usage":{"input_tokens":1000000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}]}
JSON
  cat > "$store2/session_in2.json" <<'JSON'
{"id":"session_in2","model":"claude-opus-4-8","provider_key":"claude","route_api_method":null,"created_at":"2026-08-14T23:59:00.000Z","updated_at":"2026-08-15T00:05:00.000Z","messages":[{"role":"assistant","timestamp":"2026-08-14T23:59:00.000Z","token_usage":{"input_tokens":2000000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}]}
JSON
  cat > "$store2/session_out.json" <<'JSON'
{"id":"session_out","model":"claude-opus-4-8","provider_key":"claude","route_api_method":null,"created_at":"2026-08-16T09:00:00.000Z","updated_at":"2026-08-16T09:10:00.000Z","messages":[{"role":"assistant","timestamp":"2026-08-16T09:00:00.000Z","token_usage":{"input_tokens":9000000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}]}
JSON
  # 3,000,000 input tokens in-range at $5/Mtok = $15.00 exactly; the out-of-range
  # session (would add $45) must be excluded.
  local out
  out=$(JCODE_SESSIONS_DIR="$store2" FM_TOKEN_PRICES="$PRICE" "$CLI" --period 2026-08-13..2026-08-14)
  assert_contains "$out" "sessions=2" "range must include exactly the two in-window sessions: $out"
  assert_contains "$out" "\$15.00" "range cost must be exactly \$15.00 (3M input @ \$5/Mtok): $out"
  assert_not_contains "$out" "session_out" "out-of-range session leaked into the total: $out"
  # The 15th (one day past the inclusive end) is excluded; a range through the
  # 16th includes the $45 session for $60.00 total.
  out=$(JCODE_SESSIONS_DIR="$store2" FM_TOKEN_PRICES="$PRICE" "$CLI" --period 2026-08-13..2026-08-16)
  assert_contains "$out" "\$60.00" "widening the range to the 16th must add the \$45 session: $out"
  pass "--period sums a date range correctly and is inclusive by whole day"
}

# --- --period costs a non-anthropic provider session in dollars ---------------

test_period_prices_non_anthropic_provider() {
  local store5b="$TMP_ROOT/nonanthropic-store"
  mkdir -p "$store5b"
  # Real fleet shape: deepseek-v4-flash dispatched through opencode-go. The
  # models.dev name exists in many provider tables, so pre-change it landed in
  # the UNKNOWN bucket; with the session provider resolved it must cost dollars.
  cat > "$store5b/session_deepseek.json" <<'JSON'
{"id":"session_deepseek","model":"deepseek-v4-flash","provider_key":"openai-compatible:opencode-go","route_api_method":null,"created_at":"2026-08-13T09:00:00.000Z","updated_at":"2026-08-13T09:10:00.000Z","messages":[{"role":"assistant","timestamp":"2026-08-13T09:00:00.000Z","token_usage":{"input_tokens":1000000,"output_tokens":500000,"cache_read_input_tokens":2000000,"cache_creation_input_tokens":0}}]}
JSON
  local price2="$TMP_ROOT/prices-multi.json"
  cat > "$price2" <<'JSON'
{
  "price_source": "jcode-models-dev-cache",
  "cached_at": "2026-08-22T00:00:00Z",
  "providers": {
    "anthropic": {"claude-opus-4-8": {"input_usd_per_mtok": 5, "output_usd_per_mtok": 25, "cache_read_usd_per_mtok": 0.5, "cache_write_usd_per_mtok": 6.25}},
    "opencode-go": {"deepseek-v4-flash": {"input_usd_per_mtok": 0.22, "output_usd_per_mtok": 0.66, "cache_read_usd_per_mtok": 0.007}}
  },
  "prices": {"claude-opus-4-8": {"input_usd_per_mtok": 5, "output_usd_per_mtok": 25, "cache_read_usd_per_mtok": 0.5, "cache_write_usd_per_mtok": 6.25}}
}
JSON
  # 1M in @ 0.22 + 0.5M out @ 0.66 + 2M cache-read @ 0.007 = $0.564 -> $0.56.
  local out
  out=$(JCODE_SESSIONS_DIR="$store5b" FM_TOKEN_PRICES="$price2" "$CLI" --period 2026-08-13..2026-08-13)
  assert_contains "$out" "sessions=1" "deepseek session missing from period: $out"
  assert_contains "$out" "\$0.56" "deepseek cost must be a dollar figure: $out"
  assert_not_contains "$out" "UNKNOWN" "deepseek tokens must not be UNKNOWN: $out"
  # The same session against an anthropic-only flat fixture (no providers map):
  # the ambiguous name must fail loudly, never cost at a guessed provider price.
  out=$(JCODE_SESSIONS_DIR="$store5b" FM_TOKEN_PRICES="$PRICE" "$CLI" --period 2026-08-13..2026-08-13)
  assert_contains "$out" "UNKNOWN" "ambiguity must fail loudly, not guess: $out"
  pass "--period costs a non-anthropic provider session in dollars and stays UNKNOWN on ambiguity"
}

# --- --by day bucketing: whole-session default vs --precise split -------------

test_by_day_and_precise_bucketing() {
  # One session that SPANS three hours across two assistant messages, plus a
  # short same-day session. Store isolated.
  local store3="$TMP_ROOT/bucket-store"
  mkdir -p "$store3"
  # Span session: created 10:30, messages at 10:30 (h10) and 12:15 (h12).
  cat > "$store3/session_span.json" <<'JSON'
{"id":"session_span","model":"claude-opus-4-8","provider_key":"claude","route_api_method":null,"created_at":"2026-08-13T10:30:00.000Z","updated_at":"2026-08-13T12:30:00.000Z","messages":[
  {"role":"assistant","timestamp":"2026-08-13T10:30:00.000Z","token_usage":{"input_tokens":1000000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},
  {"role":"assistant","timestamp":"2026-08-13T12:15:00.000Z","token_usage":{"input_tokens":3000000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
]}
JSON
  # A second session on the NEXT day so --by day yields two day buckets.
  cat > "$store3/session_day2.json" <<'JSON'
{"id":"session_day2","model":"claude-opus-4-8","provider_key":"claude","route_api_method":null,"created_at":"2026-08-14T08:00:00.000Z","updated_at":"2026-08-14T08:05:00.000Z","messages":[
  {"role":"assistant","timestamp":"2026-08-14T08:00:00.000Z","token_usage":{"input_tokens":2000000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
]}
JSON
  # --by day: the span session's 4M input all lands on the 13th ($20), the day2
  # session's 2M on the 14th ($10). Day buckets are identical default vs precise.
  local out
  out=$(JCODE_SESSIONS_DIR="$store3" FM_TOKEN_PRICES="$PRICE" "$CLI" --period 2026-08-13..2026-08-14 --by day)
  assert_contains "$out" "2026-08-13" "day bucket for the 13th missing: $out"
  assert_contains "$out" "2026-08-14" "day bucket for the 14th missing: $out"
  # 13th = $20.00 (4M @ $5), 14th = $10.00 (2M @ $5).
  printf '%s\n' "$out" | grep -F '2026-08-13' | grep -qF "\$20.00" \
    || fail "the 13th day bucket must be \$20.00 (whole span session): $out"
  printf '%s\n' "$out" | grep -F '2026-08-14' | grep -qF "\$10.00" \
    || fail "the 14th day bucket must be \$10.00: $out"

  # --by hour DEFAULT: the span session lands WHOLE in its START hour (10), so
  # hour 10 carries all 4M ($20) and there is NO hour-12 bucket.
  out=$(JCODE_SESSIONS_DIR="$store3" FM_TOKEN_PRICES="$PRICE" "$CLI" --period 2026-08-13 --by hour)
  assert_contains "$out" "2026-08-13T10" "default hour bucketing must key on created_at hour 10: $out"
  printf '%s\n' "$out" | grep -F '2026-08-13T10' | grep -qF "\$20.00" \
    || fail "default: whole span session (4M, \$20) must land in start hour 10: $out"
  assert_not_contains "$out" "2026-08-13T12" "default bucketing must NOT split the span into hour 12: $out"

  # --precise --by hour: the two messages SPLIT - hour 10 gets 1M ($5), hour 12
  # gets 3M ($15) - and the grand total still equals the whole-session $20.
  out=$(JCODE_SESSIONS_DIR="$store3" FM_TOKEN_PRICES="$PRICE" "$CLI" --period 2026-08-13 --by hour --precise)
  assert_contains "$out" "2026-08-13T10" "precise: hour 10 bucket missing: $out"
  assert_contains "$out" "2026-08-13T12" "precise: hour 12 bucket missing (message must split out): $out"
  printf '%s\n' "$out" | grep -F '2026-08-13T10' | grep -qF "\$5.00" \
    || fail "precise: hour 10 must carry only the first message (1M, \$5): $out"
  printf '%s\n' "$out" | grep -F '2026-08-13T12' | grep -qF "\$15.00" \
    || fail "precise: hour 12 must carry the second message (3M, \$15): $out"
  printf '%s\n' "$out" | grep -F 'total' | grep -qF "\$20.00" \
    || fail "precise split total must still equal the whole-session \$20.00: $out"
  pass "--by day buckets correctly; a >1h session lands WHOLE in its start bucket by default but SPLITS under --precise (D5)"
}

# --- --json shape is stable ---------------------------------------------------

test_json_shape_stable() {
  local store4="$TMP_ROOT/json-store"
  mkdir -p "$store4"
  cat > "$store4/session_j.json" <<'JSON'
{"id":"session_j","model":"claude-opus-4-8","provider_key":"claude-oauth","route_api_method":"claude-oauth","created_at":"2026-08-13T10:00:00.000Z","updated_at":"2026-08-13T10:10:00.000Z","messages":[{"role":"assistant","timestamp":"2026-08-13T10:00:00.000Z","token_usage":{"input_tokens":1000000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}]}
JSON
  local out
  out=$(JCODE_SESSIONS_DIR="$store4" FM_TOKEN_PRICES="$PRICE" "$CLI" --period all --json)
  # Valid JSON with the documented top-level and row keys.
  printf '%s\n' "$out" | python3 -c '
import json, sys
o = json.load(sys.stdin)
for k in ("mode", "period", "by_time", "by_dimension", "precise", "price_source", "price_cached_at", "rows", "totals"):
    assert k in o, "missing top-level key %s" % k
assert o["mode"] == "period", o["mode"]
assert o["price_source"] == "jcode-models-dev-cache", o["price_source"]
assert isinstance(o["rows"], list) and o["rows"], "rows must be a non-empty list"
r = o["rows"][0]
for k in ("bucket", "dimension", "sessions", "token_input", "token_output", "token_cache_read", "token_cache_write", "cost_if_api", "cost_if_api_covered", "cost_if_api_billed", "cost_if_api_estimate", "unknown_model_tokens", "unknown_models"):
    assert k in r, "missing row key %s" % k
assert r["cost_if_api_estimate"] is False, "exact math must not be labeled estimate"
# a priced opus-oauth session: cost is a number, covered==cost, billed==0
assert isinstance(r["cost_if_api"], (int, float)), r["cost_if_api"]
assert abs(r["cost_if_api"] - 5.0) < 1e-9, r["cost_if_api"]
assert abs(o["totals"]["cost_if_api_covered"] - 5.0) < 1e-9, o["totals"]
assert abs(o["totals"]["cost_if_api_billed"] - 0.0) < 1e-9, o["totals"]
print("ok")
' >/dev/null || fail "--json shape unstable or values wrong: $out"
  pass "--json output shape is stable (documented keys, cost a number, estimate=false)"
}

# --- unknown-model row withholds dollars (never a fabricated $0) --------------

test_unknown_model_withholds_dollars() {
  local store5="$TMP_ROOT/unknown-store"
  mkdir -p "$store5"
  # A priced opus session and an UNPRICED 'mock' session in the same period.
  cat > "$store5/session_priced.json" <<'JSON'
{"id":"session_priced","model":"claude-opus-4-8","provider_key":"claude","route_api_method":null,"created_at":"2026-08-13T10:00:00.000Z","updated_at":"2026-08-13T10:10:00.000Z","messages":[{"role":"assistant","timestamp":"2026-08-13T10:00:00.000Z","token_usage":{"input_tokens":1000000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}]}
JSON
  cat > "$store5/session_mock.json" <<'JSON'
{"id":"session_mock","model":"mock","provider_key":"claude","route_api_method":null,"created_at":"2026-08-13T11:00:00.000Z","updated_at":"2026-08-13T11:10:00.000Z","messages":[{"role":"assistant","timestamp":"2026-08-13T11:00:00.000Z","token_usage":{"input_tokens":7000000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}]}
JSON
  # Human --by-model: the mock row must say UNKNOWN and never $0.00, and carry its
  # 7,000,000 tokens; the opus row prices normally.
  local out
  out=$(JCODE_SESSIONS_DIR="$store5" FM_TOKEN_PRICES="$PRICE" "$CLI" --period all --by-model)
  printf '%s\n' "$out" | grep -F 'model=mock' | grep -qF 'UNKNOWN' \
    || fail "mock (unpriced) row must be UNKNOWN: $out"
  printf '%s\n' "$out" | grep -F 'model=mock' | grep -qF '7,000,000' \
    || fail "mock row must still report its tokens: $out"
  printf '%s\n' "$out" | grep -F 'model=mock' | grep -qF "\$0.00" \
    && fail "mock row must NEVER show a fabricated \$0.00: $out"
  printf '%s\n' "$out" | grep -F 'model=claude-opus-4-8' | grep -qF "\$5.00" \
    || fail "priced opus row must cost \$5.00: $out"
  # JSON: the mock row's cost_if_api is null (not 0), tokens carried in
  # unknown_model_tokens, and the period total's cost excludes the mock dollars.
  out=$(JCODE_SESSIONS_DIR="$store5" FM_TOKEN_PRICES="$PRICE" "$CLI" --period all --by-model --json)
  printf '%s\n' "$out" | python3 -c '
import json, sys
o = json.load(sys.stdin)
rows = {r["dimension"]: r for r in o["rows"]}
assert rows["mock"]["cost_if_api"] is None, "unknown model cost must be null, got %r" % rows["mock"]["cost_if_api"]
assert rows["mock"]["unknown_model_tokens"] == 7000000, rows["mock"]["unknown_model_tokens"]
assert "mock" in rows["mock"]["unknown_models"], rows["mock"]["unknown_models"]
assert abs(rows["claude-opus-4-8"]["cost_if_api"] - 5.0) < 1e-9, rows["claude-opus-4-8"]["cost_if_api"]
# The grand total counts only priced dollars, and reports the unknown tokens
# separately - never folds a fake zero into the dollar total.
assert abs(o["totals"]["cost_if_api"] - 5.0) < 1e-9, o["totals"]["cost_if_api"]
assert o["totals"]["unknown_model_tokens"] == 7000000, o["totals"]
print("ok")
' >/dev/null || fail "--json unknown-model handling wrong: $out"
  pass "unknown-model row withholds dollars (null cost, no fake \$0), tokens carried separately"
}

# --- --by-provider grouping and subscription split ----------------------------

test_by_provider_grouping() {
  local store6="$TMP_ROOT/provider-store"
  mkdir -p "$store6"
  # One subscription-covered (claude-oauth) and one API-metered (claude) opus
  # session, same model, so only the provider dimension separates them.
  cat > "$store6/session_covered.json" <<'JSON'
{"id":"session_covered","model":"claude-opus-4-8","provider_key":"claude-oauth","route_api_method":"claude-oauth","created_at":"2026-08-13T10:00:00.000Z","updated_at":"2026-08-13T10:10:00.000Z","messages":[{"role":"assistant","timestamp":"2026-08-13T10:00:00.000Z","token_usage":{"input_tokens":1000000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}]}
JSON
  cat > "$store6/session_api.json" <<'JSON'
{"id":"session_api","model":"claude-opus-4-8","provider_key":"claude","route_api_method":null,"created_at":"2026-08-13T11:00:00.000Z","updated_at":"2026-08-13T11:10:00.000Z","messages":[{"role":"assistant","timestamp":"2026-08-13T11:00:00.000Z","token_usage":{"input_tokens":2000000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}]}
JSON
  local out
  out=$(JCODE_SESSIONS_DIR="$store6" FM_TOKEN_PRICES="$PRICE" "$CLI" --period all --by-provider)
  # covered provider: $5 all covered; api provider: $10 all billed.
  printf '%s\n' "$out" | grep -F 'provider=claude-oauth' | grep -qF "covered \$5.00 / api \$0.00" \
    || fail "claude-oauth provider must be fully subscription-covered: $out"
  printf '%s\n' "$out" | grep -F 'provider=claude' | grep -v 'oauth' | grep -qF "covered \$0.00 / api \$10.00" \
    || fail "plain claude provider must be fully API-billed: $out"
  pass "--by-provider groups by provider and splits subscription-covered vs API-billed cost"
}

# --- guardrail: bad args fail closed ------------------------------------------

test_bad_args_rejected() {
  local status
  JCODE_SESSIONS_DIR="$STORE" FM_TOKEN_PRICES="$PRICE" "$CLI" >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "no mode should exit non-zero"
  JCODE_SESSIONS_DIR="$STORE" FM_TOKEN_PRICES="$PRICE" "$CLI" --period all --by fortnight >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "an unknown --by unit must be rejected"
  JCODE_SESSIONS_DIR="$STORE" FM_TOKEN_PRICES="$PRICE" "$CLI" --session x --period all >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "--session and --period together must be rejected"
  JCODE_SESSIONS_DIR="$STORE" FM_TOKEN_PRICES="$PRICE" "$CLI" --session does-not-exist >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "a missing session id must exit non-zero"
  pass "invalid arguments and a missing session id fail closed (non-zero)"
}

# --- PR-T4: per-ticket rollup rides the session ledger -----------------------
#
# These tests use the COMMITTED fixture set under tests/fixtures/token-t4: a
# token-sessions.tsv ledger, a completions.tsv, and two jcode store dirs
# (sessions/ for the exact rollup + --by-ticket, retro-sessions/ for --retro).
# Every test points the env seams at the fixtures via $JCODE_SESSIONS_DIR (the
# store) and $FM_DATA_OVERRIDE (the ledger + completions), never the real
# home's files, per the brief's test contract.

FIXDATA="$ROOT/tests/fixtures/token-t4"
FIXSESS="$FIXDATA/sessions"
FIXRETRO="$FIXDATA/retro-sessions"

run_fix() { # <sessions_dir> <args...>
  local sdir=$1; shift
  JCODE_SESSIONS_DIR="$sdir" FM_TOKEN_PRICES="$PRICE" FM_DATA_OVERRIDE="$FIXDATA" "$CLI" "$@"
}

test_ticket_rollup_sums_every_ledger_session() {
  # ticket-a has TWO ledger rows (session_a1 + session_a2): the rollup must sum
  # BOTH. 1M + 2M input = 3M tokens = $15.00 at $5/Mtok, and the per-session
  # numbers come from the one coster lib (fm_token_sum_session), so the total is
  # exact - never an ESTIMATE.
  local out json
  out=$(run_fix "$FIXSESS" ticket-a)
  assert_contains "$out" "ticket ticket-a" "ticket line missing: $out"
  assert_contains "$out" "sessions=2" "multi-session rollup must count both sessions: $out"
  assert_contains "$out" "\$15.00" "ticket-a must sum to \$15.00: $out"
  assert_contains "$out" "3,000,000" "ticket-a must sum 3,000,000 input tokens: $out"
  assert_not_contains "$out" "ESTIMATE" "the exact ledger rollup must not carry the ESTIMATE label: $out"
  json=$(run_fix "$FIXSESS" ticket-a --json)
  printf '%s\n' "$json" | python3 -c '
import json, sys
o = json.load(sys.stdin)
assert o["mode"] == "ticket", o["mode"]
assert o["ticket"] == "ticket-a", o["ticket"]
assert o["sessions"] == 2, o["sessions"]
assert o["ledger_sessions"] == 2, o["ledger_sessions"]
assert o["unresolved_sessions"] == 0, o["unresolved_sessions"]
assert o["cost_if_api_estimate"] is False, o["cost_if_api_estimate"]
assert abs(o["cost_if_api"] - 15.0) < 1e-9, o["cost_if_api"]
assert o["token_input"] == 3000000, o["token_input"]
print("ok")
' >/dev/null || fail "exact ticket-a JSON wrong: $json"
  pass "a multi-session ticket sums every ledger session exactly (1M+2M -> \$15.00), never ESTIMATE"
}

test_ticket_missing_ledger_prompts_retro() {
  # ticket-retro has NO ledger row (pre-capture): the bare rollup must fail
  # closed (non-zero) and point the captain at the labeled --retro path instead
  # of guessing a number.
  local status out
  out=$(run_fix "$FIXSESS" ticket-retro 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a ticket with no ledger rows must exit non-zero"
  assert_contains "$out" "--retro" "the no-ledger error must point at --retro: $out"
  pass "a pre-capture ticket with no ledger rows fails closed and points at --retro"
}

test_by_ticket_buckets_unattributed() {
  # --period all --by-ticket: ledger sessions land under their ticket; the store
  # session with NO ledger row (session_unattr) lands in the labeled
  # "unattributed" bucket - never force-fit to a ticket.
  local out json
  out=$(run_fix "$FIXSESS" --period all --by-ticket)
  assert_contains "$out" "ticket=ticket-a  sessions=2  cost_if_api \$15.00" "ticket-a row wrong: $out"
  assert_contains "$out" "ticket=ticket-b  sessions=1  cost_if_api \$15.00" "ticket-b row wrong: $out"
  assert_contains "$out" "ticket=unattributed  sessions=1  cost_if_api \$20.00" "unattributed bucket wrong: $out"
  assert_contains "$out" "total  sessions=4  cost_if_api \$50.00" "grand total wrong: $out"
  json=$(run_fix "$FIXSESS" --period all --by-ticket --json)
  printf '%s\n' "$json" | python3 -c '
import json, sys
o = json.load(sys.stdin)
rows = {r["dimension"]: r for r in o["rows"]}
assert "ticket-a" in rows and "ticket-b" in rows and "unattributed" in rows, list(rows)
assert rows["ticket-a"]["sessions"] == 2, rows["ticket-a"]
assert rows["ticket-a"]["ticket"] == "ticket-a", rows["ticket-a"]
assert rows["unattributed"]["ticket"] == "unattributed", rows["unattributed"]
assert rows["unattributed"]["sessions"] == 1, rows["unattributed"]
assert abs(rows["ticket-a"]["cost_if_api"] - 15.0) < 1e-9, rows["ticket-a"]
assert abs(rows["unattributed"]["cost_if_api"] - 20.0) < 1e-9, rows["unattributed"]
print("ok")
' >/dev/null || fail "--by-ticket JSON bucketing wrong: $json"
  pass "a store session with no ledger row lands in the labeled unattributed bucket, never force-fit"
}

test_retro_labeled_estimate() {
  # --retro on a pre-capture ticket: the completions close date (2026-08-13)
  # bounds a coarse 7-day window 2026-08-07..2026-08-13. Only session_retro_in
  # (created 08-12, 500K input = $2.50) falls in the window; session_retro_out
  # (created 08-01, 9M input = $45) is EXCLUDED. The output MUST carry the
  # ESTIMATE label and refuse exactness (D4).
  local out json
  out=$(run_fix "$FIXRETRO" ticket-retro --retro)
  assert_contains "$out" "ticket ticket-retro" "retro ticket line missing: $out"
  assert_contains "$out" "sessions=1" "retro must count the in-window session: $out"
  assert_contains "$out" "\$2.50" "retro must sum the in-window \$2.50: $out"
  assert_contains "$out" "2026-08-07..2026-08-13" "retro window bound wrong: $out"
  assert_contains "$out" "ESTIMATE" "retro output must carry the ESTIMATE label: $out"
  assert_contains "$out" "NOT an exact per-ticket cost" "retro output must refuse exactness: $out"
  assert_not_contains "$out" "\$45.00" "out-of-window session leaked into the estimate: $out"
  json=$(run_fix "$FIXRETRO" ticket-retro --retro --json)
  printf '%s\n' "$json" | python3 -c '
import json, sys
o = json.load(sys.stdin)
assert o["estimate"] is True, o["estimate"]
assert o["cost_if_api_estimate"] is True, o["cost_if_api_estimate"]
assert o["retro_window"] == {"close_date": "2026-08-13", "start": "2026-08-07", "end": "2026-08-13"}, o["retro_window"]
assert o["sessions"] == 1, o["sessions"]
assert abs(o["cost_if_api"] - 2.5) < 1e-9, o["cost_if_api"]
print("ok")
' >/dev/null || fail "retro JSON wrong: $json"
  pass "--retro produces a coarse date-window estimate, always labeled ESTIMATE, never claiming exactness"
}

test_retro_dual_format_close_field() {
  # BACKWARD COMPATIBILITY: --retro reads the completions close field to bound its
  # 7-day window. A new-format row carries a full timestamp; --retro must window
  # on its calendar DAY, producing the same bound a bare date would. Reuse the
  # retro session store; only the close field format changes vs test above.
  local data out
  data=$(fm_test_tmproot fm-token-report-retro-ts)
  mkdir -p "$data"
  cp "$FIXDATA/token-sessions.tsv" "$data/token-sessions.tsv"
  {
    printf '# ledger\n'
    printf 'ticket-retro\t2026-08-13T14:22:00Z\tship\tfirstmate\tabc123\n'
  } > "$data/completions.tsv"
  out=$(JCODE_SESSIONS_DIR="$FIXRETRO" FM_TOKEN_PRICES="$PRICE" FM_DATA_OVERRIDE="$data" \
    "$CLI" ticket-retro --retro 2>&1) || fail "retro failed on a timestamped close field: $out"
  # Window bound must be the DAY, not the full timestamp: 2026-08-07..2026-08-13.
  assert_contains "$out" "2026-08-07..2026-08-13" "timestamped close must window on its day: $out"
  assert_contains "$out" "sessions=1" "retro must count the in-window session: $out"
  assert_contains "$out" "\$2.50" "retro must sum the in-window \$2.50: $out"
  assert_not_contains "$out" "\$45.00" "out-of-window session leaked: $out"
  pass "--retro windows a full-timestamp close field on its calendar day (dual-format)"
}

test_retro_refuses_exact_ledger_ticket() {
  # A ticket that HAS exact ledger data must not be run through the coarse
  # estimate path: --retro fails closed and says to drop it.
  local status out
  out=$(run_fix "$FIXSESS" ticket-a --retro 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "--retro on an exact-ledger ticket must exit non-zero"
  assert_contains "$out" "drop --retro" "the refusal must name the exact path: $out"
  pass "--retro refuses to run on a ticket that has exact ledger data"
}

test_ticket_arg_guards() {
  local status
  run_fix "$FIXSESS" ticket-a --by-ticket >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "--by-ticket on a task-id must be rejected"
  run_fix "$FIXSESS" --period all --by-ticket --by-model >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "two --by-<dimension> flags must be rejected"
  run_fix "$FIXSESS" --period all --retro >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "--retro without a task-id must be rejected"
  pass "--by-ticket and --retro reject their invalid combinations fail-closed"
}

# --- --by-tier: spend + ticket count grouped by data-driven model tier --------
#
# The fleet routes cheap tooling work to the deepseek-flash lane and expensive
# product work to the opus lane; --by-tier makes that split visible. This case
# builds its own store + price fixture with a product-tier session (opus, priced
# $15.00), a tooling-tier session (deepseek-v4-flash, priced $0.44), and an
# UNPRICED model (mystery-x) that must land in the labeled "other"/UNKNOWN bucket
# with its tokens carried, never a fabricated $0. It asserts:
#   - the tier of each model is derived data-driven from config/model-tiers.json
#     (opus -> product, deepseek flash -> tooling, unknown -> the default other);
#   - each tier line reports its distinct attributed-ticket count (tickets=N);
#   - the unpriced tier withholds dollars (UNKNOWN / null cost), never $0;
#   - --by week composes, and the --json shape carries tier + ticket_count.
test_by_tier_groups_spend_and_tickets() {
  local tstore="$TMP_ROOT/tier-store" tprice="$TMP_ROOT/tier-prices.json"
  local tdata="$TMP_ROOT/tier-data"
  mkdir -p "$tstore" "$tdata"
  cat > "$tprice" <<'JSON'
{
  "price_source": "jcode-models-dev-cache",
  "cached_at": "2026-08-20T00:00:00Z",
  "prices": {
    "claude-opus-4-8": {"input_usd_per_mtok": 5, "output_usd_per_mtok": 25},
    "@cf/deepseek-ai/deepseek-v4-flash-0731": {"input_usd_per_mtok": 0.44, "output_usd_per_mtok": 1.32}
  }
}
JSON
  # product-tier opus, 3M input over two sessions -> $15.00 (two tickets).
  cat > "$tstore/session_p1.json" <<'JSON'
{"id":"session_p1","model":"claude-opus-4-8","provider_key":"claude","route_api_method":null,"created_at":"2026-08-20T10:00:00.000Z","messages":[{"role":"assistant","timestamp":"2026-08-20T10:00:00.000Z","token_usage":{"input_tokens":1000000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}]}
JSON
  cat > "$tstore/session_p2.json" <<'JSON'
{"id":"session_p2","model":"claude-opus-4-8","provider_key":"claude","route_api_method":null,"created_at":"2026-08-20T11:00:00.000Z","messages":[{"role":"assistant","timestamp":"2026-08-20T11:00:00.000Z","token_usage":{"input_tokens":2000000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}]}
JSON
  # tooling-tier deepseek flash, 1M input -> $0.44 (one ticket).
  cat > "$tstore/session_t1.json" <<'JSON'
{"id":"session_t1","model":"@cf/deepseek-ai/deepseek-v4-flash-0731","provider_key":"None","route_api_method":null,"created_at":"2026-08-20T12:00:00.000Z","messages":[{"role":"assistant","timestamp":"2026-08-20T12:00:00.000Z","token_usage":{"input_tokens":1000000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}]}
JSON
  # unpriced model, 500k tokens -> UNKNOWN in the "other" bucket (no ticket row).
  cat > "$tstore/session_o1.json" <<'JSON'
{"id":"session_o1","model":"mystery-x","provider_key":"None","route_api_method":null,"created_at":"2026-08-20T13:00:00.000Z","messages":[{"role":"assistant","timestamp":"2026-08-20T13:00:00.000Z","token_usage":{"input_tokens":500000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}]}
JSON
  # ledger attributes the two opus sessions to two distinct tickets and the flash
  # session to one; the unpriced session has NO ledger row.
  printf 'tk-1\tsession_p1\t/w\t2026-08-20T10:00:00Z\tjcode\ntk-2\tsession_p2\t/w\t2026-08-20T11:00:00Z\tjcode\ntk-3\tsession_t1\t/w\t2026-08-20T12:00:00Z\tjcode\n' \
    > "$tdata/token-sessions.tsv"

  local out
  out=$(JCODE_SESSIONS_DIR="$tstore" FM_TOKEN_PRICES="$tprice" FM_DATA_OVERRIDE="$tdata" "$CLI" --period all --by-tier)
  assert_contains "$out" "tier=product  sessions=2  tickets=2  cost_if_api \$15.00" "product tier line wrong: $out"
  assert_contains "$out" "tier=tooling  sessions=1  tickets=1  cost_if_api \$0.44" "tooling tier line wrong: $out"
  assert_contains "$out" "tier=other  sessions=1  tickets=0  cost_if_api UNKNOWN (no price)  tokens 500,000" "other tier (unpriced) line wrong: $out"
  printf '%s\n' "$out" | grep -F 'tier=other' | grep -qF "\$0.00" \
    && fail "the unpriced tier must NEVER show a fabricated \$0.00: $out"
  assert_contains "$out" "total  sessions=4  tickets=3  cost_if_api \$15.44" "grand total wrong: $out"

  # --by week composes with --by-tier (weekly per-tier spend, the /work-report
  # cheap-lane-savings view).
  out=$(JCODE_SESSIONS_DIR="$tstore" FM_TOKEN_PRICES="$tprice" FM_DATA_OVERRIDE="$tdata" "$CLI" --period all --by week --by-tier)
  assert_contains "$out" "2026-W34  tier=product" "weekly bucket must compose with --by-tier: $out"

  # JSON: rows carry tier + ticket_count; the unpriced tier's cost is null.
  out=$(JCODE_SESSIONS_DIR="$tstore" FM_TOKEN_PRICES="$tprice" FM_DATA_OVERRIDE="$tdata" "$CLI" --period all --by-tier --json)
  printf '%s\n' "$out" | python3 -c '
import json, sys
o = json.load(sys.stdin)
assert o["by_dimension"] == "tier", o["by_dimension"]
rows = {r["tier"]: r for r in o["rows"]}
assert set(rows) == {"product", "tooling", "other"}, list(rows)
assert rows["product"]["ticket_count"] == 2, rows["product"]
assert rows["tooling"]["ticket_count"] == 1, rows["tooling"]
assert abs(rows["product"]["cost_if_api"] - 15.0) < 1e-9, rows["product"]
assert abs(rows["tooling"]["cost_if_api"] - 0.44) < 1e-9, rows["tooling"]
assert rows["other"]["cost_if_api"] is None, rows["other"]
assert rows["other"]["ticket_count"] == 0, rows["other"]
assert rows["other"]["unknown_model_tokens"] == 500000, rows["other"]
assert o["totals"]["ticket_count"] == 3, o["totals"]
print("ok")
' >/dev/null || fail "--by-tier JSON shape/values wrong: $out"
  pass "--by-tier groups spend + distinct ticket counts by data-driven model tier, unpriced tier UNKNOWN never \$0"
}

test_by_tier_applies_only_to_period() {
  local status
  JCODE_SESSIONS_DIR="$STORE" FM_TOKEN_PRICES="$PRICE" "$CLI" --session x --by-tier >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "--by-tier on a session must be rejected"
  run_fix "$FIXSESS" ticket-a --by-tier >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "--by-tier on a task-id must be rejected"
  run_fix "$FIXSESS" --period all --by-tier --by-model >/dev/null 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "--by-tier with another --by-<dimension> must be rejected"
  pass "--by-tier applies only to --period and rejects a second dimension fail-closed"
}

# --- data-driven tier mapping: a new model tiers without a code edit ----------
#
# The tier boundary is data in config/model-tiers.json, matched by the ONE owner
# bin/fm-token-tier-lib.sh. This confirms the mapping is data-driven (a fresh
# model id nobody hardcoded lands in a sensible tier via the shipped patterns)
# and that an override file is honored, so a new model never needs a code edit.
test_tier_lib_is_data_driven() {
  # shellcheck source=bin/fm-token-tier-lib.sh disable=SC1091
  . "$ROOT/bin/fm-token-tier-lib.sh"
  local got
  check_tier() { # <expected> <model> [tiers_file_env]
    local expected=$1 model=$2 tf=${3:-}
    got=$(FM_MODEL_TIERS="$tf" fm_token_tier_of "$model")
    [ "$got" = "$expected" ] || fail "tier of '$model' expected '$expected' got '$got'"
  }
  check_tier tooling '@cf/deepseek-ai/deepseek-v4-flash-0731'
  check_tier tooling 'claude-haiku-4-5'
  check_tier product 'claude-opus-4-8'
  check_tier product 'gpt-5.5'
  check_tier other 'some-brand-new-model'
  check_tier other ''
  # An override tier file relabels a model with no code edit (data-driven).
  local override="$TMP_ROOT/override-tiers.json"
  cat > "$override" <<'JSON'
{"tiers":[{"tier":"experimental","match":["*brand-new*"]}],"default_tier":"unclassified"}
JSON
  check_tier experimental 'some-brand-new-model' "$override"
  check_tier unclassified 'claude-opus-4-8' "$override"
  pass "the model->tier map is data-driven (config-owned patterns + override file), no code edit per model"
}

# --- attribution joins: nm run, secondmate home, spawn window ----------------
#
# Captain-approved join set (data/token-attribution-gap/decision-join-sources.md,
# approved 2026-08-23): producers other than bin/fm-spawn.sh never write a ledger
# row, so their sessions rendered "unattributed" even though a durable record
# elsewhere already names their ticket. These cases build a self-contained world
# per join - a fixture no-mistakes state.sqlite with a runs table, a fixture
# sibling secondmate home carrying its own token-sessions.tsv, and a fixture
# spawn window in the local ledger - and assert:
#   - each join maps its session to the right ticket;
#   - the two KEYED joins (nm run id, secondmate ledger) are labeled exact;
#   - the coarse spawn-window join is ALWAYS labeled ESTIMATE and never exact
#     (captain decision D4), both in the human line and in --json;
#   - a session that no join matches still lands in "unattributed";
#   - the nm state database is opened READ-ONLY (a read-only file works, and the
#     file is byte-identical afterwards).

# Build the shared attribution world. Echoes its root; the caller reads
# $ATTR_STORE, $ATTR_DATA, $ATTR_NM_HOME, $ATTR_SIBLING out of it.
attr_world() {
  local root
  root=$(fm_test_tmproot fm-token-report-attr)
  ATTR_STORE="$root/sessions"
  ATTR_DATA="$root/data"
  ATTR_NM_HOME="$root/nm"
  ATTR_SIBLING="$root/sibling-home"
  mkdir -p "$ATTR_STORE" "$ATTR_DATA" "$ATTR_NM_HOME/worktrees" "$ATTR_SIBLING/data"

  # nm state database, shaped like the real one: runs(id, branch). Two run ids,
  # one branch carrying the "fm/" prefix and one bare (both forms occur), plus a
  # third worktree whose run id is absent so the miss path is exercised.
  python3 - "$ATTR_NM_HOME/state.sqlite" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE runs (id TEXT PRIMARY KEY, branch TEXT)")
c.executemany(
    "INSERT INTO runs (id, branch) VALUES (?, ?)",
    [
        ("01M0JGH5RH9M2JR2WRPF7EYN3K", "fm/nm-ticket"),
        ("01M0JGH5RH9M2JR2WRPF7EYN4L", "fix/bare-branch-ticket"),
    ],
)
c.commit()
c.close()
PY

  # A no-mistakes pipeline child (run id in its worktree path, "fm/" stripped).
  write_attr_session nm1 "$ATTR_NM_HOME/worktrees/324df5ded712/01M0JGH5RH9M2JR2WRPF7EYN3K" \
    "2026-08-22T04:00:00.000Z" 1000000
  # A second nm child on a BARE branch name that itself contains a slash: only a
  # leading "fm/" is stripped, so the ticket keeps its "fix/" prefix.
  write_attr_session nm2 "$ATTR_NM_HOME/worktrees/324df5ded712/01M0JGH5RH9M2JR2WRPF7EYN4L" \
    "2026-08-22T04:10:00.000Z" 1000000
  # An nm worktree whose run id is NOT in the database: the join misses and the
  # session must stay unattributed rather than being force-fit.
  write_attr_session nmmiss "$ATTR_NM_HOME/worktrees/324df5ded712/01MISSINGRUNIDXXXXXXXXXXXX" \
    "2026-08-22T04:20:00.000Z" 1000000
  # A session inside the registered sibling secondmate home, recorded in THAT
  # home's own ledger (not in this home's).
  write_attr_session sib1 "$ATTR_SIBLING/.treehouse/proj/1/proj" \
    "2026-08-22T05:00:00.000Z" 1000000
  # Two orphan swarm workers in a worktree the LOCAL ledger knows: they fall in
  # the first spawn window (window-task), not the second (later-task).
  write_attr_session sw1 "$root/wt/slot3" "2026-08-22T03:16:33.000Z" 1000000
  write_attr_session sw2 "$root/wt/slot3" "2026-08-22T03:27:40.000Z" 1000000
  # An orphan in the SAME worktree but after the next task's spawn: it belongs to
  # that later task's window, proving the window boundary is real.
  write_attr_session sw3 "$root/wt/slot3" "2026-08-22T07:00:00.000Z" 1000000
  # Ad-hoc work in a primary checkout no join knows: stays unattributed.
  write_attr_session adhoc "$root/plain-checkout" "2026-08-22T08:00:00.000Z" 1000000
  # An orphan running from a SUBDIRECTORY of the ledgered worktree (an agent
  # started in a crate dir): the nearest ledgered ancestor owns the lane.
  write_attr_session swsub "$root/wt/slot3/crates/app-core" "2026-08-22T03:20:00.000Z" 1000000

  # Local ledger: the coordinator's own row (exact) plus the two spawn instants
  # that bound the window fallback in /wt/slot3.
  printf '%s\n' \
    '# fixture ledger' \
    "ledger-task	session_sw0	$root/wt/other	2026-08-22T01:00:00Z	jcode" \
    "window-task	session_win_coord	$root/wt/slot3	2026-08-22T03:11:35Z	jcode" \
    "later-task	session_later	$root/wt/slot3	2026-08-22T06:47:02Z	jcode" \
    > "$ATTR_DATA/token-sessions.tsv"
  # The sibling secondmate home's OWN ledger already records its session exactly.
  printf '%s\n' \
    '# sibling fixture ledger' \
    "sibling-task	session_sib1	$ATTR_SIBLING/.treehouse/proj/1/proj	2026-08-22T04:59:00Z	jcode" \
    > "$ATTR_SIBLING/data/token-sessions.tsv"
  # Registry entry in this home's data dir, in the real one-line "(home: ...)"
  # shape bin/fm-ff-lib.sh parses.
  printf -- '- sibling-mate - fixture secondmate. (home: %s; scope: fixture; projects: ; added 2026-08-22)\n' \
    "$ATTR_SIBLING" > "$ATTR_DATA/secondmates.md"
  printf '%s\n' "$root"
}

# One jcode-shaped store session with a working_dir and a single priced message.
# Args: name working_dir created_at input_tokens
write_attr_session() {
  local name=$1 wd=$2 created=$3 tokens=$4
  cat > "$ATTR_STORE/session_$name.json" <<JSON
{"id":"session_$name","model":"claude-opus-4-8","provider_key":"claude","route_api_method":null,"working_dir":"$wd","created_at":"$created","updated_at":"$created","messages":[{"role":"assistant","timestamp":"$created","token_usage":{"input_tokens":$tokens,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}]}
JSON
}

run_attr() { # run the CLI against the attribution world
  JCODE_SESSIONS_DIR="$ATTR_STORE" FM_TOKEN_PRICES="$PRICE" \
    FM_DATA_OVERRIDE="$ATTR_DATA" FM_NM_HOME="$ATTR_NM_HOME" "$CLI" "$@"
}

test_attribution_joins_map_and_label() {
  attr_world >/dev/null
  local out
  out=$(run_attr --period all --by-ticket)
  # 1. nm join: worktree run id -> runs.branch -> ticket, "fm/" stripped, EXACT.
  assert_contains "$out" "ticket=nm-ticket  sessions=1  cost_if_api \$5.00  covered \$0.00 / api \$5.00  [exact]" \
    "nm join must attribute the pipeline child exactly: $out"
  # Only a LEADING fm/ is stripped: a bare "fix/..." branch keeps its prefix.
  assert_contains "$out" "ticket=fix/bare-branch-ticket  sessions=1" \
    "a bare branch name must keep its own prefix: $out"
  # 2. sibling-secondmate join: resolved from THAT home's own ledger, EXACT.
  assert_contains "$out" "ticket=sibling-task  sessions=1  cost_if_api \$5.00  covered \$0.00 / api \$5.00  [exact]" \
    "secondmate join must read the sibling home's ledger exactly: $out"
  # 3. spawn-window fallback: two orphans inside [03:11:35, 06:47:02) attribute
  #    to window-task and MUST be labeled ESTIMATE, never exact (D4).
  # sw1, sw2, and the subdirectory orphan swsub all land on window-task.
  assert_contains "$out" "ticket=window-task  sessions=3  cost_if_api \$15.00  covered \$0.00 / api \$15.00  [ESTIMATE]" \
    "window fallback must attribute every in-window orphan and label ESTIMATE: $out"
  printf '%s\n' "$out" | grep -F 'ticket=window-task' | grep -qF '[exact]' \
    && fail "the coarse window join must NEVER be labeled exact: $out"
  assert_contains "$out" "NOT an exact per-ticket cost (D4)" \
    "an ESTIMATE row must carry the D4 note: $out"
  # The later spawn owns the window after it: sw3 lands on later-task.
  assert_contains "$out" "ticket=later-task  sessions=1" \
    "the next spawn must own the window after it: $out"
  # 4. no join matches the ad-hoc checkout and the unknown nm run: unattributed.
  assert_contains "$out" "ticket=unattributed  sessions=2  cost_if_api \$10.00" \
    "an unmatched session must stay unattributed: $out"
  pass "the approved joins attribute nm, secondmate, and window sessions, exact vs ESTIMATE labeled"
}

test_attribution_json_labels() {
  attr_world >/dev/null
  local out
  out=$(run_attr --period all --by-ticket --json)
  printf '%s\n' "$out" | python3 -c '
import json, sys
o = json.load(sys.stdin)
rows = {r["ticket"]: r for r in o["rows"]}
for t in ("nm-ticket", "sibling-task", "window-task", "unattributed"):
    assert t in rows, list(rows)
# Keyed joins are exact and never flagged as an estimate.
assert rows["nm-ticket"]["attribution"] == "exact", rows["nm-ticket"]
assert rows["nm-ticket"]["attribution_sources"] == ["nm"], rows["nm-ticket"]
assert rows["nm-ticket"]["cost_if_api_estimate"] is False, rows["nm-ticket"]
assert rows["sibling-task"]["attribution"] == "exact", rows["sibling-task"]
assert rows["sibling-task"]["attribution_sources"] == ["secondmate"], rows["sibling-task"]
# The coarse window join is ALWAYS an estimate (D4).
assert rows["window-task"]["attribution"] == "ESTIMATE", rows["window-task"]
assert rows["window-task"]["attribution_sources"] == ["window"], rows["window-task"]
assert rows["window-task"]["cost_if_api_estimate"] is True, rows["window-task"]
assert rows["window-task"]["sessions"] == 3, rows["window-task"]
# The unattributed bucket is a bucket, not a ticket: no attribution label.
assert rows["unattributed"]["attribution"] is None, rows["unattributed"]
print("ok")
' >/dev/null || fail "attribution JSON labels wrong: $out"
  pass "--by-ticket --json labels each row exact or ESTIMATE with its join sources"
}

test_attribution_nm_db_read_only() {
  # The nm state database belongs to the shared no-mistakes daemon: this report
  # must only ever READ it. Proven two ways - the report works with the database
  # file mode set read-only, and its bytes are unchanged afterwards.
  attr_world >/dev/null
  local db="$ATTR_NM_HOME/state.sqlite" before after out
  before=$(sha256sum "$db" | cut -d' ' -f1)
  chmod 444 "$db"
  out=$(run_attr --period all --by-ticket) || fail "report failed on a read-only nm database: $out"
  chmod 644 "$db"
  after=$(sha256sum "$db" | cut -d' ' -f1)
  [ "$before" = "$after" ] || fail "the nm state database was modified (must be opened read-only)"
  assert_contains "$out" "ticket=nm-ticket" "the read-only nm join must still resolve: $out"
  pass "the no-mistakes state database is opened READ-ONLY and never written"
}

test_attribution_absent_sources_are_silent() {
  # Every join source is optional: with no nm database, no registry, and no
  # windows, the report still runs and everything simply stays unattributed.
  attr_world >/dev/null
  rm -f "$ATTR_NM_HOME/state.sqlite" "$ATTR_DATA/secondmates.md" "$ATTR_DATA/token-sessions.tsv"
  local out
  out=$(run_attr --period all --by-ticket) || fail "report must survive absent join sources: $out"
  assert_contains "$out" "ticket=unattributed  sessions=9" \
    "with no join source every session stays unattributed: $out"
  assert_not_contains "$out" "ESTIMATE" "no window data means no ESTIMATE row: $out"
  pass "absent join sources are silent: the report still runs and nothing is force-fit"
}

test_session_matches_lib_exactly
test_period_sums_range
test_period_prices_non_anthropic_provider
test_by_day_and_precise_bucketing
test_json_shape_stable
test_unknown_model_withholds_dollars
test_by_provider_grouping
test_bad_args_rejected
test_ticket_rollup_sums_every_ledger_session
test_ticket_missing_ledger_prompts_retro
test_by_ticket_buckets_unattributed
test_retro_labeled_estimate
test_retro_dual_format_close_field
test_retro_refuses_exact_ledger_ticket
test_ticket_arg_guards
test_by_tier_groups_spend_and_tickets
test_by_tier_applies_only_to_period
test_tier_lib_is_data_driven
test_attribution_joins_map_and_label
test_attribution_json_labels
test_attribution_nm_db_read_only
test_attribution_absent_sources_are_silent
