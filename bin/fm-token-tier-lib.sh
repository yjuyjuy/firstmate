# shellcheck shell=bash
# One owner of the model -> spend-tier mapping for the token/cost rollup
# surfaces. Sourced (NEVER executed directly), side-effect free (defines
# functions only), exactly like bin/fm-token-lib.sh, so a read-only reporting
# command can source it and classify models without writing anything.
#
# WHY this exists: the fleet deliberately routes cheap tooling work to the
# deepseek flash lane and expensive product work to the opus lane. Per-tier
# spend visibility is how the captain confirms the cheap-lane savings are real,
# so bin/fm-token-report.sh --by-tier groups its already-costed per-model rows
# by the tier each model belongs to. This lib is the ONE place a model name
# becomes a tier, so the tier boundary is stated once, never re-derived per
# caller.
#
# DATA-DRIVEN, not a hardcoded two-name list (a hard task constraint): the tier
# table lives in the tracked snapshot config/model-tiers.json (the data), and
# this lib is only the matcher (the mechanism). A model is matched, lowercased,
# against each tier's shell-glob patterns in array order; the FIRST tier with
# any matching pattern wins, and a model matching no tier lands in the config's
# default_tier ("other"). So a NEW model lands in a sensible tier by editing the
# JSON patterns, never this code, and an unrecognized model lands in an explicit
# labeled bucket rather than a fabricated tier or a wrong guess.
#
# The tier snapshot path is $FM_MODEL_TIERS when set (the test seam and
# downcallers' override), else <repo-root>/config/model-tiers.json resolved from
# this file's own location, matching the $FM_TOKEN_PRICES override shape.

# Resolve the owned tier snapshot path.
fm_token_tiers_path() {
  local root
  if [ -n "${FM_MODEL_TIERS:-}" ]; then
    printf '%s\n' "$FM_MODEL_TIERS"
    return 0
  fi
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  printf '%s\n' "$root/config/model-tiers.json"
}

# Classify one model id into its spend tier. Prints the tier name and returns 0.
# Args: model [tiers_file]. An empty or "unknown" model, and any model matching
# no tier, resolves to the config default_tier; a missing or unreadable tiers
# snapshot resolves to the built-in fallback default "other" (never a guessed
# tier, never a fabricated dollar effect - tiering is orthogonal to costing).
fm_token_tier_of() {
  local model=$1 tiers_file=${2:-}
  [ -n "$tiers_file" ] || tiers_file=$(fm_token_tiers_path)
  if [ ! -f "$tiers_file" ] || ! command -v python3 >/dev/null 2>&1; then
    printf 'other\n'
    return 0
  fi
  FM_TIER_MODEL="$model" FM_TIER_FILE="$tiers_file" python3 - <<'PY'
import fnmatch
import json
import os
import sys

model = (os.environ.get("FM_TIER_MODEL", "") or "").strip().lower()
try:
    with open(os.environ["FM_TIER_FILE"]) as fh:
        data = json.load(fh)
except (OSError, ValueError):
    sys.stdout.write("other\n")
    sys.exit(0)

default_tier = str(data.get("default_tier") or "other")
if not model or model == "unknown":
    sys.stdout.write(default_tier + "\n")
    sys.exit(0)

for entry in data.get("tiers") or []:
    if not isinstance(entry, dict):
        continue
    name = str(entry.get("tier") or "").strip()
    if not name:
        continue
    for pat in entry.get("match") or []:
        if fnmatch.fnmatch(model, str(pat).lower()):
            sys.stdout.write(name + "\n")
            sys.exit(0)

sys.stdout.write(default_tier + "\n")
PY
}
