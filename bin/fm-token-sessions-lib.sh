# shellcheck shell=bash
# Append-only token-session ledger format owner + crew-session resolver.
# Sourced by bin/fm-spawn.sh (post-launch capture) and bin/fm-session-start.sh
# (firstmate's own-session sentinel). NEVER executed directly.
#
# Sourcing is SIDE-EFFECT FREE on purpose (like bin/fm-pid-lib.sh): it defines
# functions only and creates no directories, so a read-only caller can source it
# and call the resolver without writing anything.
#
# WHY a ledger and not a single meta field: per-ticket token/cost rollup must
# survive teardown (which removes state/<id>.meta) and must sum EVERY session a
# ticket ran, because a crew that compacts/relaunches or a stuck-recovery
# relaunch spawns a NEW harness session for the SAME ticket id. So this is a
# many-rows-per-id ledger: one row per session, rollup sums all rows for the id.
# This mirrors the never-pruned discipline of data/completions.tsv exactly.
#
# Storage: data/token-sessions.tsv, one row per line, tab-separated:
#   <id>\t<session_id>\t<working_dir>\t<spawn_ts>\t<harness>
# where <id> is the task id (or the sentinel __firstmate__ for firstmate's own
# supervision session, so its cross-ticket tokens attribute to the home, not to
# any one ticket), <session_id> is the harness session id, <working_dir> is the
# leased worktree that session ran in, <spawn_ts> is the spawn instant (ISO-8601
# UTC), and <harness> is the harness name. Comment lines start with '#'.
#
# Appends are atomic: a single line is written with one O_APPEND write, never a
# read-modify-write of the whole file, so a crash cannot corrupt earlier rows.
# Dedupe is by the EXACT (id, session_id) pair only, never by id alone: a second
# session for the same ticket has a different session_id and appends a new row
# (the multi-session case the ledger exists for), while re-running the same
# capture for the identical session_id is a no-op. A tab or newline in any field
# is rejected loudly rather than silently corrupting the tab-separated layout.

# True when a value is a safe single-line field (no tab, no newline).
fm_token_sessions_field_safe() {
  local v=$1
  case "$v" in
    *"	"*) return 1 ;;
  esac
  [ "$(printf '%s' "$v" | wc -l | tr -d ' ')" = 0 ] || return 1
  return 0
}

fm_token_sessions_file() {
  local data_dir=$1
  printf '%s\n' "$data_dir/token-sessions.tsv"
}

# Append one ledger row. Args: data_dir id session_id working_dir spawn_ts harness.
# Every field must be non-empty and safe. Returns non-zero without writing on any
# unsafe or empty field, or a write failure. When a row with the same id AND the
# same session_id already exists anywhere in the file, returns 0 without appending
# (idempotent per session), so a re-run never double-records one session while a
# genuinely new session for the same id still appends.
fm_token_sessions_record() {
  local data_dir=$1 id=$2 session_id=$3 working_dir=$4 spawn_ts=$5 harness=$6 file line f
  for f in "$id" "$session_id" "$working_dir" "$spawn_ts" "$harness"; do
    [ -n "$f" ] || { echo "token-sessions: empty required field for '$id'" >&2; return 1; }
    fm_token_sessions_field_safe "$f" || { echo "token-sessions: unsafe field for '$id'" >&2; return 1; }
  done
  mkdir -p "$data_dir" || return 1
  file=$(fm_token_sessions_file "$data_dir")
  if [ -f "$file" ]; then
    # Exact (id, session_id) pair already present: no-op. Match the first two
    # tab-separated fields only, so a value elsewhere on a line is never a hit.
    local rec rec_id rec_sid
    while IFS= read -r rec || [ -n "$rec" ]; do
      case "$rec" in
        ''|'#'*) continue ;;
      esac
      rec_id=${rec%%$'\t'*}
      rec_sid=${rec#*$'\t'}
      rec_sid=${rec_sid%%$'\t'*}
      if [ "$rec_id" = "$id" ] && [ "$rec_sid" = "$session_id" ]; then
        return 0
      fi
    done < "$file"
  else
    printf '%s\n' \
      '# firstmate token-session ledger: append-only, never pruned.' \
      '# Format: <id>\t<session_id>\t<working_dir>\t<spawn_ts>\t<harness>' \
      '# Owned by bin/fm-token-sessions-lib.sh; appended from bin/fm-spawn.sh' \
      '# (crew capture) and bin/fm-session-start.sh (firstmate __firstmate__ sentinel).' \
      >> "$file" || return 1
  fi
  line=$(printf '%s\t%s\t%s\t%s\t%s' "$id" "$session_id" "$working_dir" "$spawn_ts" "$harness")
  printf '%s\n' "$line" >> "$file" || return 1
  return 0
}

# Look up every recorded ledger row for an exact task id. Args: data_dir id.
# Prints one matching ledger line per session (verbatim, tab-separated), in file
# order, and returns 0 when at least one match exists. Returns 1 without
# printing when the id has no ledger rows or the ledger is absent. The id is
# matched against the first tab-separated field only, so a substring of another
# id or a field value elsewhere on the line is never a false hit. Comment lines
# are skipped. This is the single read path for the per-ticket rollup
# (bin/fm-token-report.sh), so report callers never hand-parse columns. The
# unknown-model "unattributed" notion never lives here: this returns exactly
# what the ledger records for one id.
fm_token_sessions_rows_for() {
  local data_dir=$1 id=$2 file found=1 rec_id line
  [ -n "$id" ] || return 1
  file=$(fm_token_sessions_file "$data_dir")
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    rec_id=${line%%$'\t'*}
    if [ "$rec_id" = "$id" ]; then
      printf '%s\n' "$line"
      found=0
    fi
  done < "$file"
  return "$found"
}

# Resolve the harness session id for a just-launched agent. Args:
#   working_dir spawn_ts [sessions_dir]
# Prints the id of the newest-created_at session whose working_dir matches and
# whose created_at is at or after spawn_ts, or NOTHING (empty) when none match.
# FAIL-CLOSED: no match prints nothing and returns 1, so a caller records an
# unattributed session rather than force-fitting a wrong id. This is the exact
# forward anchor from the design: a crew session's working_dir == the leased
# worktree and its created_at >= the spawn instant, and the NEWEST such session
# wins so pooled-slot reuse (an older session sharing the worktree) never wins.
#
# sessions_dir defaults to $JCODE_SESSIONS_DIR then ~/.jcode/sessions - the jcode
# session store. Only jcode's store is readable today; an unsupported harness has
# no readable store, so its caller never calls this and the session resolves
# empty (skipped, not guessed). Paths are realpath-normalized on both sides so a
# symlinked worktree still matches. spawn_ts may be epoch seconds or ISO-8601.
fm_resolve_crew_session_id() {
  local working_dir=$1 spawn_ts=$2 sessions_dir=${3:-${JCODE_SESSIONS_DIR:-$HOME/.jcode/sessions}}
  [ -n "$working_dir" ] || return 1
  [ -d "$sessions_dir" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  local out
  out=$(FM_TOK_WD="$working_dir" FM_TOK_TS="$spawn_ts" FM_TOK_DIR="$sessions_dir" python3 - <<'PY'
import glob, json, os, re, sys

want_wd = os.path.realpath(os.environ["FM_TOK_WD"])
raw_ts = os.environ.get("FM_TOK_TS", "").strip()
sess_dir = os.environ["FM_TOK_DIR"]


def to_epoch(s):
    if s is None:
        return None
    s = str(s).strip()
    if not s:
        return None
    # Bare epoch seconds (integer or float).
    if re.fullmatch(r"\d+(\.\d+)?", s):
        return float(s)
    # ISO-8601, tolerate a trailing Z and sub-second precision beyond microseconds.
    m = re.fullmatch(
        r"(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?Z?",
        s,
    )
    if not m:
        return None
    import calendar

    y, mo, d, h, mi, se = (int(m.group(i)) for i in range(1, 7))
    frac = m.group(7) or "0"
    frac = (frac + "000000")[:6]
    epoch = calendar.timegm((y, mo, d, h, mi, se, 0, 0, 0))
    return epoch + int(frac) / 1_000_000.0


floor = to_epoch(raw_ts)
best_id = None
best_epoch = None
for path in glob.glob(os.path.join(sess_dir, "session_*.json")):
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        continue
    sid = data.get("id")
    wd = data.get("working_dir")
    created = to_epoch(data.get("created_at"))
    if not sid or not wd or created is None:
        continue
    try:
        if os.path.realpath(wd) != want_wd:
            continue
    except OSError:
        continue
    if floor is not None and created < floor:
        continue
    if best_epoch is None or created > best_epoch:
        best_epoch = created
        best_id = sid

if best_id:
    sys.stdout.write(best_id)
PY
) || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
  return 0
}

# True when a harness's session store is readable by fm_resolve_crew_session_id,
# so per-ticket attribution can be captured for it. Args: harness.
#
# WHY this predicate exists as its own function: the attribution leak this file
# guards against had TWO causes, and this is the fix for the second. The capture
# in bin/fm-spawn.sh was gated on a bare `[ "$HARNESS" = jcode ]` literal at the
# CALL SITE, so every non-jcode backend was silently exempt from attribution -
# its sessions landed "unattributed" by construction, not by a failed lookup.
# Naming the readable-store set ONCE, here, means the capture path asks a single
# question ("can I read this harness's store?") instead of hard-coding jcode, and
# a future harness whose store becomes readable is added in exactly one place.
#
# Only jcode's store is readable today: fm_resolve_crew_session_id reads the
# jcode session store (session_*.json), and no other harness exposes an
# equivalent store this fleet can parse. A harness NOT in this set resolves no
# session and is skipped (not guessed) - the same fail-closed limitation the
# resolver already has - but now that skip is a deliberate, named decision rather
# than a silent literal, and the capture path can log a clear reason for it.
fm_harness_session_store_readable() {
  case "$1" in
    jcode) return 0 ;;
    *) return 1 ;;
  esac
}

# Capture and DURABLY RECORD one token-session ledger row for a just-launched
# crew session, retrying while the harness store settles and verifying the write,
# so a spawn ALWAYS lands a row (or logs exactly why it could not) instead of
# silently dropping attribution. Args:
#   data_dir id working_dir spawn_ts harness [sessions_dir]
# On success prints the resolved session_id to stdout and returns 0 (the caller
# stamps session_id= into meta from it). On a give-up prints NOTHING to stdout,
# writes ONE clear diagnostic to stderr, and returns non-zero. NEVER a spawn
# blocker: the caller ignores the return for spawn success and only uses the
# stdout id.
#
# WHY retry: capture is post-launch and best-effort, but the harness writes its
# session_*.json ASYNCHRONOUSLY - at the instant fm-spawn fires the launch and
# immediately resolves, the store file often does not exist yet, so a single-shot
# resolve returns empty and the row is dropped SILENTLY. That silent drop is the
# live attribution leak this task fixes (13 sessions / 275M tokens unattributed
# in-window). Retrying a bounded number of times with a short sleep lets the
# store settle so the newest-at/after-spawn session resolves, and a give-up after
# the bound logs a diagnostic naming the id and worktree rather than vanishing.
#
# FAIL-CLOSED still holds: a harness whose store is not readable
# (fm_harness_session_store_readable false) is skipped WITHOUT retrying or logging
# a false alarm, because no amount of retry makes an unreadable store resolve.
# A resolvable-but-unwritable ledger (record fails) is logged and returns
# non-zero. The write is verified by re-reading the exact (id, session_id) pair
# back from the ledger, so a partial or lost append is caught, not assumed.
#
# The retry bound and per-try sleep are overridable via FM_TOKEN_CAPTURE_RETRIES
# (default 8) and FM_TOKEN_CAPTURE_SLEEP (default 0.25s) so a test can drive the
# retry path fast and deterministically; production uses the defaults.
fm_token_sessions_capture() {
  local data_dir=$1 id=$2 working_dir=$3 spawn_ts=$4 harness=$5
  local sessions_dir=${6:-${JCODE_SESSIONS_DIR:-$HOME/.jcode/sessions}}
  local retries=${FM_TOKEN_CAPTURE_RETRIES:-8}
  local sleep_s=${FM_TOKEN_CAPTURE_SLEEP:-0.25}
  # Skip a harness with no readable store: it can never resolve, so retrying and
  # logging would be pure noise. This is a deliberate, named skip, not a silent
  # exemption at the call site.
  if ! fm_harness_session_store_readable "$harness"; then
    return 1
  fi
  local sid attempt=0 file
  while :; do
    sid=$(fm_resolve_crew_session_id "$working_dir" "$spawn_ts" "$sessions_dir" 2>/dev/null || true)
    if [ -n "$sid" ]; then
      break
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -gt "$retries" ]; then
      echo "token-sessions: capture MISS for id='$id' harness='$harness' worktree='$working_dir': no session resolved after $retries retries; row DROPPED (attribution leak)" >&2
      return 1
    fi
    sleep "$sleep_s" 2>/dev/null || true
  done
  if ! fm_token_sessions_record "$data_dir" "$id" "$sid" "$working_dir" "$spawn_ts" "$harness" 2>/dev/null; then
    echo "token-sessions: capture RECORD FAILED for id='$id' session='$sid' worktree='$working_dir': ledger append refused; row DROPPED" >&2
    return 1
  fi
  # Verify the write actually landed by reading the exact (id, session_id) pair
  # back, so a lost or partial append is caught rather than assumed successful.
  file=$(fm_token_sessions_file "$data_dir")
  if ! fm_token_sessions_rows_for "$data_dir" "$id" 2>/dev/null | grep -q "^$id"$'\t'"$sid"$'\t'; then
    echo "token-sessions: capture VERIFY FAILED for id='$id' session='$sid' (ledger '$file' has no matching row after append); row DROPPED" >&2
    return 1
  fi
  printf '%s' "$sid"
  return 0
}

# Read a session's ACTUAL model and reasoning effort from the jcode session
# store - the ground truth for whether /model and /effort actually applied to a
# session (pane echo is not proof; incident 2026-08-23, data/learnings.md
# "MODEL DRIFT INCIDENT": the slash-popup race lost /model|/effort silently).
# The store file is <sessions_dir>/<sid>.json (the session id already carries
# its `session_` prefix, so it is NOT doubled) with fields `model` and
# `reasoning_effort`; a null field reads as empty. Used by fm-spawn.sh's
# spawn-time verify-and-retry and by fm-watch.sh's heartbeat drift sweep, so the
# store format contract lives here, once.
#
# Args: <session-id> [sessions_dir]
# Prints one line per field, `model=<value>` and `effort=<value>`, and returns
# 0. Returns 1 and prints NOTHING when the session id is empty, python3 is
# missing, the file is missing/unreadable, or the JSON does not parse - a caller
# that got nothing must treat verification as impossible, never as passed.
fm_session_store_profile() {
  local sid=$1 sessions_dir=${2:-${JCODE_SESSIONS_DIR:-$HOME/.jcode/sessions}}
  [ -n "$sid" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  local out
  out=$(FM_TOK_SID="$sid" FM_TOK_DIR="$sessions_dir" python3 - <<'PY'
import json, os, sys

sid = os.environ["FM_TOK_SID"]
sess_dir = os.environ["FM_TOK_DIR"]
try:
    with open(os.path.join(sess_dir, "%s.json" % sid)) as fh:
        data = json.load(fh)
except (OSError, ValueError):
    sys.exit(1)
model = data.get("model") or ""
effort = data.get("reasoning_effort") or ""
sys.stdout.write("model=%s\neffort=%s\n" % (model, effort))
PY
) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
  return 0
}
