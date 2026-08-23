# shellcheck shell=bash
# One owner of the token-sum, cost-if-API, and subscription-coverage math for
# jcode sessions. Sourced (NEVER executed directly) by the price owner
# (bin/fm-token-prices.sh), the report CLI (PR-T2), and every downstream
# dashboard consumer, so there is exactly one parser and one coster.
#
# Sourcing is SIDE-EFFECT FREE on purpose (like bin/fm-pid-lib.sh): it defines
# functions only, so a read-only reporting command can source it and cost
# sessions without writing anything.
#
# Cost model (captain-resolved, design PR-T1): every jcode assistant message
# carries real billed token_usage fields, and cost_if_api is always computed
# from token_usage x the owned price snapshot regardless of provider, while
# subscription_covered is a SEPARATE boolean off provider_key/route_api_method.
# cached-output = N/A: no output-cache field exists in the transcript, so no
# cached-output metric is ever emitted and no zero is fabricated.
# cache_creation_input_tokens is the cache-WRITE signal and IS counted; that is
# the only cache-write signal.
#
# UNKNOWN rule (hard requirement): a real token count with no price must never
# render as $0. A model absent from the price snapshot costs UNKNOWN (empty
# output, non-zero exit), never zero. Lookup is exact model id first, then the
# -YYYYMMDD-stripped family, then UNKNOWN.
#
# MULTI-PROVIDER lookup rule: the snapshot (owned by bin/fm-token-prices.sh,
# config/token-prices.json) carries a `providers` map with EVERY provider
# table from jcode's models.dev feed plus a flat `prices` map that holds only
# model ids present in exactly ONE provider table. A model id in two or more
# tables is ambiguous - the same name bills differently per provider - and the
# flat map EXCLUDES it by construction, so an unqualified lookup fails loudly
# (UNKNOWN) instead of guessing. Callers that know the session's provider pass
# it in: the resolved provider's table wins, and only when that table lacks the
# model does the lookup fall back to the unambiguous flat map. fm_token_sum_session
# resolves the session provider_key for the caller.
#
# Price snapshot header (owned by bin/fm-token-prices.sh): config/
# token-prices.json, with a header carrying price_source, cached_at (the source
# feed's own cache timestamp), and written_at (this snapshot's own). Every cost
# is annotated with price_source + price_cached_at so staleness is visible from
# the file.
#
# Staleness/estimate labeling contract: PR-T1's per-session math is exact, so
# fm_token_sum_session always emits cost_if_api_estimate=false. The key exists
# so downstream callers (the per-ticket estimate paths, PR-T4) can label any
# estimate-derived value ESTIMATE through the same contract.
#
# The price snapshot path is $FM_TOKEN_PRICES when set (the test seam and
# downcallers' override), else <repo-root>/config/token-prices.json resolved
# from this file's own location.

# Resolve the owned price snapshot path.
fm_token_prices_path() {
  local root
  if [ -n "${FM_TOKEN_PRICES:-}" ]; then
    printf '%s\n' "$FM_TOKEN_PRICES"
    return 0
  fi
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  printf '%s\n' "$root/config/token-prices.json"
}

# Print one header field from the price snapshot, or nothing (exit 1) when the
# snapshot is missing or unreadable. Keys: price_source, cached_at, written_at,
# cached_at_unix_secs, written_at_unix_secs. Missing snapshot never guesses.
fm_token_prices_field() {
  local key=$1 price_file=${2:-}
  [ -n "$key" ] || return 1
  [ -n "$price_file" ] || price_file=$(fm_token_prices_path)
  [ -f "$price_file" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  FM_TOK_KEY="$key" FM_TOK_PRICE_FILE="$price_file" python3 - <<'PY'
import json, os, sys

try:
    with open(os.environ["FM_TOK_PRICE_FILE"]) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)
sys.stdout.write(str(data.get(os.environ["FM_TOK_KEY"], "") or ""))
PY
}

# Resolve a jcode session provider_key to the models.dev provider id whose
# price table bills that route, or print NOTHING when no table maps to it.
#   claude | claude-oauth | remote | remote-catalog -> anthropic
#       (jcode's claude routes all bill against models.dev's anthropic table,
#        the same basis the snapshot used when it was anthropic-only)
#   openrouter -> openrouter
#   openai-compatible:<name> -> <name>  (e.g. openai-compatible:opencode-go)
#   anything else -> nothing (lookup then falls back to the flat map only)
fm_token_resolve_provider() {
  local provider_key=$1 name
  case "$provider_key" in
    claude|claude-oauth|remote|remote-catalog)
      printf 'anthropic\n'
      ;;
    openrouter)
      printf 'openrouter\n'
      ;;
    openai-compatible:*)
      name="${provider_key#openai-compatible:}"
      [ -n "$name" ] && printf '%s\n' "$name"
      ;;
  esac
  return 0
}

# Print the price row for a model as one compact JSON object carrying the four
# per-Mtok USD fields, or print NOTHING and return 1 when the model is unpriced.
# Args: model [price_file] [provider]. With a provider, the provider's table is
# tried first (exact id, then the trailing -YYYYMMDD-stripped family) and only
# then the flat unambiguous map; without a provider only the flat map is read,
# so an ambiguous id is UNKNOWN (fail loudly, never a guessed provider). A
# missing price snapshot is UNKNOWN (return 1), never a guessed price.
fm_token_model_price() {
  local model=$1 price_file=${2:-} provider=${3:-}
  [ -n "$model" ] || return 1
  [ -n "$price_file" ] || price_file=$(fm_token_prices_path)
  [ -f "$price_file" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  FM_TOK_MODEL="$model" FM_TOK_PRICE_FILE="$price_file" FM_TOK_PROVIDER="$provider" python3 - <<'PY'
import json, os, re, sys

model = os.environ["FM_TOK_MODEL"]
provider = os.environ.get("FM_TOK_PROVIDER", "")
try:
    with open(os.environ["FM_TOK_PRICE_FILE"]) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)
comp = {}
providers = data.get("providers") or {}
if provider and isinstance(providers.get(provider), dict):
    comp = providers[provider]
if not comp:
    comp = data.get("prices") or {}
row = comp.get(model)
if row is None:
    base = re.sub(r"-[0-9]{8}$", "", model)
    if base != model:
        row = comp.get(base)
if row is None and provider and isinstance(providers.get(provider), dict):
    # The provider table lacks the model: fall back to the unambiguous flat map.
    flat = data.get("prices") or {}
    row = flat.get(model)
    if row is None:
        base = re.sub(r"-[0-9]{8}$", "", model)
        if base != model:
            row = flat.get(base)
if row is None:
    sys.exit(1)
sys.stdout.write(json.dumps(row, separators=(",", ":")))
PY
}

# Dot-product cost in USD for the given token counts at the model's price:
# (input*in + output*out + cache_read*cr + cache_write*cw) / 1_000_000.
# Prints the full-precision decimal, or NOTHING (exit 1) when UNKNOWN.
# Args: input output cache_read cache_write model [price_file] [provider].
# Row-completeness rule: input and output are the always-billed components, so
# both prices must be present; a missing cache price is only tolerated when the
# session billed ZERO tokens for that component (the feed omits cache prices for
# providers that do not publish them, so a zero-token component costs nothing).
# A billed component with a missing price stays UNKNOWN: never a partial cost
# with a fabricated zero for a component that was actually billed.
fm_token_cost() {
  local input=$1 output=$2 cache_read=$3 cache_write=$4 model=$5 price_file=${6:-} provider=${7:-} row
  [ -n "$model" ] || return 1
  [ -n "$price_file" ] || price_file=$(fm_token_prices_path)
  row=$(fm_token_model_price "$model" "$price_file" "$provider") || return 1
  [ -n "$row" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  FM_TOK_ROW="$row" \
    FM_TOK_INPUT="$input" FM_TOK_OUTPUT="$output" \
    FM_TOK_CACHE_READ="$cache_read" FM_TOK_CACHE_WRITE="$cache_write" \
    python3 - <<'PY'
import json, os, sys


def named(s):
    v = os.environ.get(s, "") or ""
    try:
        return float(v)
    except ValueError:
        return 0.0


inp = named("FM_TOK_INPUT")
out = named("FM_TOK_OUTPUT")
cr = named("FM_TOK_CACHE_READ")
cw = named("FM_TOK_CACHE_WRITE")
row = json.loads(os.environ["FM_TOK_ROW"])
pi = row.get("input_usd_per_mtok")
po = row.get("output_usd_per_mtok")
pcr = row.get("cache_read_usd_per_mtok")
pcw = row.get("cache_write_usd_per_mtok")
if not (isinstance(pi, (int, float)) and isinstance(po, (int, float))):
    sys.exit(1)
if cr > 0 and not isinstance(pcr, (int, float)):
    sys.exit(1)
if cw > 0 and not isinstance(pcw, (int, float)):
    sys.exit(1)
pcr = pcr if isinstance(pcr, (int, float)) else 0.0
pcw = pcw if isinstance(pcw, (int, float)) else 0.0
cost = (inp * pi + out * po + cr * pcr + cw * pcw) / 1000000.0
sys.stdout.write(str(cost))
PY
}

# subscription_covered is evaluated independently of cost and is orthogonal to
# it. Covered when EITHER the provider routed through claude-oauth or the route
# method was claude-oauth: the remote+claude-oauth combo (a subscription-covered
# remote route) needs the OR, not provider_key alone. Everything else (plain
# claude, remote without oauth, openrouter, openai-compatible, ollama, None) is
# API-metered or another provider. Prints true or false.
fm_token_subscription_covered() {
  local provider_key=$1 route_api_method=${2:-}
  if [ "$provider_key" = "claude-oauth" ] || [ "$route_api_method" = "claude-oauth" ]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
  return 0
}

# Summarize one jcode session file as KEY=VALUE: the exact token sums across
# assistant messages, cost_if_api (unchanged from the lib's full-precision
# decimal, or EMPTY when the model is unpriced), the subscription_covered flag,
# and the price_source + price_cached_at annotation. cost_if_api_estimate is
# always false here (PR-T1 per-session math is exact) and exists so downstream
# estimate callers reuse the same labeling key. Returns non-zero only when the
# session file cannot be parsed.
fm_token_sum_session() {
  local session_file=$1 price_file=${2:-} out model provider route resolved
  local input output cache_read cache_write cost covered ps pc
  [ -f "$session_file" ] || { echo "fm-token-lib: session file not found: $session_file" >&2; return 1; }
  command -v python3 >/dev/null 2>&1 || { echo "fm-token-lib: python3 required to parse sessions" >&2; return 1; }
  out=$(FM_TOK_SESSION="$session_file" python3 - <<'PY'
import json, os, sys

path = os.environ["FM_TOK_SESSION"]
try:
    with open(path) as fh:
        d = json.load(fh)
except OSError as exc:
    print("fm-token-lib: cannot read session %s: %s" % (path, exc), file=sys.stderr)
    sys.exit(1)
except ValueError as exc:
    print("fm-token-lib: session %s is not valid JSON: %s" % (path, exc), file=sys.stderr)
    sys.exit(1)

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

# One value per line: an empty provider/route field must survive the handoff to
# bash, and a tab-separated row would collapse onto its neighbors (IFS treats
# consecutive tabs as one separator) and shift every trailing sum.
for v in (str(d.get("model") or ""), str(d.get("provider_key") or ""), str(d.get("route_api_method") or ""), str(ti), str(to), str(cr), str(cw)):
    print(v)
PY
) || return 1
  {
    read -r model
    read -r provider
    read -r route
    read -r input
    read -r output
    read -r cache_read
    read -r cache_write
  } <<< "$out"
  resolved=$(fm_token_resolve_provider "$provider")
  cost=$(fm_token_cost "$input" "$output" "$cache_read" "$cache_write" "$model" "$price_file" "$resolved") || true
  covered=$(fm_token_subscription_covered "$provider" "$route")
  ps=$(fm_token_prices_field price_source "$price_file") || true
  pc=$(fm_token_prices_field cached_at "$price_file") || true
  printf 'model=%s\ntoken_input=%s\ntoken_output=%s\ntoken_cache_read=%s\ntoken_cache_write=%s\ncost_if_api=%s\ncost_if_api_estimate=false\nsubscription_covered=%s\nprice_source=%s\nprice_cached_at=%s\n' \
    "$model" "$input" "$output" "$cache_read" "$cache_write" "$cost" "$covered" "$ps" "$pc"
}
