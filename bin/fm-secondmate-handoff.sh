#!/usr/bin/env bash
# Hand a persistent secondmate's work off to a FRESH agent instead of running
# /compact on the context-full one. Orchestrates, idempotently and failing
# closed, the full stow + continuation-doc + respawn sequence:
#
#   1. Resolve home/window/harness from state/<id>.meta; refuse unless kind=secondmate.
#   2. Refuse unless context is over the threshold (--force / FM_SM_HANDOFF_FORCE=1
#      bypasses this gate for a captain-directed proactive handoff). An unknown
#      context read refuses without --force - the read fails closed.
#   3. Steer the secondmate: trigger /handoff (a literal slash command - its skill
#      is disable-model-invocation, and it always writes to the OS temp dir), then
#      instruct it to move that doc to the DURABLE in-home path
#      (data/handoff-latest.md, never OS temp), invoke stow, and signal completion.
#      Refuse to steer unless the agent is idle.
#   4. Wait, bounded (FM_SM_HANDOFF_TIMEOUT, default 900s), for the doc and signal.
#   5. Exit the old agent with the harness-correct exit form.
#   6. Respawn a fresh secondmate (bin/fm-spawn.sh <id> --secondmate) and point it
#      at the durable doc plus its charter.
#
# Idempotent: a completed capture is detected and not repeated; a re-run after a
# successful handoff no-ops because the fresh agent is under the threshold. Never
# tears down or discards unlanded work - the respawn preserves the home's backlog,
# projects, and in-flight crew exactly as secondmate-provisioning recovery does.
#
# Usage: fm-secondmate-handoff.sh <id> [--force]
# Env: FM_SM_HANDOFF_DRY_RUN=1 prints each mutating action instead of running it
#      (writes no files, steers/exits/respawns nothing) for inspection and tests.
#      FM_SM_HANDOFF_TIMEOUT (doc wait, default 900), FM_SM_HANDOFF_EXIT_TIMEOUT
#      (agent-death wait, default 60), FM_SM_HANDOFF_POLL (default 5).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# Resolve THIS home and export it so the internal fm-send calls inherit it. A
# caller's explicit FM_HOME always wins; a bare invocation resolves it from this
# home-scoped script's own root. Without the export, a bare invocation left
# FM_HOME unset in the child fm-send, which fails closed (bin/fm-send.sh) and
# aborted the handoff mid-sequence.
export FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-secondmate-context-lib.sh
. "$SCRIPT_DIR/fm-secondmate-context-lib.sh"

DRY_RUN=${FM_SM_HANDOFF_DRY_RUN:-}
TIMEOUT=${FM_SM_HANDOFF_TIMEOUT:-900}
EXIT_TIMEOUT=${FM_SM_HANDOFF_EXIT_TIMEOUT:-60}
POLL=${FM_SM_HANDOFF_POLL:-5}
BUSY_REGEX=${FM_BUSY_REGEX:-'esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'}

usage() {
  cat <<'EOF'
Usage: fm-secondmate-handoff.sh <id> [--force]

Hand a persistent secondmate off to a fresh agent instead of running /compact:
stow + write a continuation doc to <home>/data/handoff-latest.md via /handoff +
respawn (bin/fm-spawn.sh <id> --secondmate). Idempotent and fail-closed; never
discards unlanded work.

  --force   hand off regardless of the threshold / an unreadable read (captain-directed).

Env: FM_SM_HANDOFF_DRY_RUN=1 (preview actions, no side effects),
     FM_SM_HANDOFF_TIMEOUT (doc wait, default 900), FM_SM_HANDOFF_EXIT_TIMEOUT
     (agent-death wait, default 60), FM_SM_HANDOFF_POLL (default 5).
See docs/secondmate-context-handoff.md and the secondmate-provisioning skill.
EOF
}

FORCE=${FM_SM_HANDOFF_FORCE:-}
ID=
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --force) FORCE=1 ;;
    -*) echo "error: unknown option: $arg" >&2; exit 2 ;;
    *) [ -z "$ID" ] || { echo "error: extra argument: $arg" >&2; exit 2; }; ID=$arg ;;
  esac
done
[ -n "$ID" ] || { echo "error: usage: fm-secondmate-handoff.sh <id> [--force]" >&2; exit 2; }

act() {  # echo an action in dry-run, else run it
  if [ -n "$DRY_RUN" ]; then
    printf 'DRY-RUN: %s\n' "$*"
    return 0
  fi
  "$@"
}

fail() { echo "error: $*" >&2; exit 1; }

# --- 1. resolve ------------------------------------------------------------
META="$STATE/$ID.meta"
[ -f "$META" ] || fail "no metadata for '$ID' in $STATE"
[ "$(fm_meta_get "$META" kind)" = secondmate ] || fail "'$ID' is not a secondmate; handoff is secondmate-only"

HARNESS=$(fm_meta_get "$META" harness); [ -n "$HARNESS" ] || HARNESS=$(fm_backend_of_meta "$META")
BACKEND=$(fm_backend_of_meta "$META")
WINDOW=$(fm_backend_target_of_meta "$META" || true)
HOME_DIR=$(fm_meta_get "$META" home); [ -n "$HOME_DIR" ] || HOME_DIR=$(fm_meta_get "$META" worktree)
LABEL=fm-$ID

[ -n "$WINDOW" ] || fail "no window recorded for '$ID'; this is a recovery case, not a handoff"
[ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ] || fail "secondmate home for '$ID' is missing"
[ -d "$HOME_DIR/data" ] || fail "secondmate home for '$ID' has no data/ directory"

DOC="$HOME_DIR/data/handoff-latest.md"
REQ="$HOME_DIR/data/.handoff-request"
DONE="$HOME_DIR/data/.handoff-done"

# The step-2 follow-up steer is a single self-contained line (fm-send delivers
# one literal line): it names every action inline, so no transient instruction
# file is written or referenced. A file pointer here would name a path that is
# deleted at cleanup, and because a secondmate steer opens a parent-owned
# pending-reply expectation the about-to-be-exited agent can never answer, it
# escalated a phantom "blocked: pending-reply-missed" on every handoff.
STEP2_INSTR="Finish the handoff now: copy the continuation document you just wrote from the OS temp dir to data/handoff-latest.md in this home (overwrite any existing copy), then invoke the stow skill, then run: touch data/.handoff-done. Do NOT run /compact. Do not stop until both data/handoff-latest.md and data/.handoff-done exist."

agent_alive() { [ "$(fm_backend_agent_alive "$BACKEND" "$WINDOW" 2>/dev/null || echo unknown)" = alive ]; }
agent_dead()  { [ "$(fm_backend_agent_alive "$BACKEND" "$WINDOW" 2>/dev/null || echo unknown)" = dead ]; }
agent_busy() {
  local tail
  tail=$(fm_backend_capture "$BACKEND" "$WINDOW" 40 "$LABEL" 2>/dev/null || true)
  printf '%s' "$tail" | grep -v '^[[:space:]]*$' | tail -6 | grep -qiE "$BUSY_REGEX"
}

# --- 2. threshold gate -----------------------------------------------------
THRESHOLD=$(fm_sm_context_threshold "$CONFIG")
TOKENS=$(fm_sm_context_tokens "$HOME_DIR" "$HARNESS" || true)
if [ -z "$FORCE" ]; then
  if [ -z "$TOKENS" ]; then
    fail "context usage for '$ID' is unreadable ($HARNESS); refusing without --force"
  elif [ "$TOKENS" -lt "$THRESHOLD" ]; then
    echo "no handoff needed for '$ID': context ${TOKENS} tokens is under threshold ${THRESHOLD}"
    exit 0
  fi
  echo "handoff for '$ID': context ${TOKENS} tokens >= threshold ${THRESHOLD}"
else
  echo "handoff for '$ID': forced (context ${TOKENS:-unknown} tokens, threshold ${THRESHOLD})"
fi

# --- 3/4. capture the continuation doc -------------------------------------
capture_complete() { [ -f "$DOC" ] && [ -f "$DONE" ] && [ ! "$REQ" -nt "$DONE" ]; }

if capture_complete; then
  echo "continuation doc already captured for '$ID'; resuming at agent exit"
else
  if [ -z "$DRY_RUN" ]; then
    agent_alive || fail "secondmate '$ID' agent is not alive; cannot steer an orderly handoff (recovery, not handoff)"
    ! agent_busy || fail "secondmate '$ID' is mid-turn; retry the handoff once it is idle"
  fi

  # The continuation doc is produced in two steered messages. /handoff MUST be a
  # literal slash command: its skill is disable-model-invocation, so only a slash
  # input triggers it (the model cannot invoke it as a skill). It always writes to
  # the OS temp dir, so the follow-up instruction (a plain text steer the model
  # acts on) moves that doc to the durable in-home path, runs stow, and marks done.
  if [ -n "$DRY_RUN" ]; then
    printf 'DRY-RUN: touch %s\n' "$REQ"
  else
    rm -f "$DONE"
    date +%s > "$REQ"
  fi

  # Step 1: trigger /handoff as a real slash command (not via the instruction file).
  act "$SCRIPT_DIR/fm-send.sh" "$ID" "/handoff Firstmate is replacing you with a fresh agent; write a continuation document so it can resume this home's work."
  # Let the /handoff turn finish before the follow-up so the send is not swallowed mid-turn.
  if [ -z "$DRY_RUN" ]; then
    waited=0
    while agent_busy; do
      [ "$waited" -lt "$TIMEOUT" ] || fail "timed out waiting for '$ID' to finish /handoff"
      sleep "$POLL"
      waited=$(( waited + POLL ))
    done
  fi
  # Step 2: move the temp doc to the durable path, stow, and mark done.
  act "$SCRIPT_DIR/fm-send.sh" "$ID" "$STEP2_INSTR"

  if [ -n "$DRY_RUN" ]; then
    printf 'DRY-RUN: wait up to %ss for %s and %s\n' "$TIMEOUT" "$DOC" "$DONE"
  else
    echo "waiting up to ${TIMEOUT}s for '$ID' to write the continuation doc..."
    waited=0
    while ! capture_complete; do
      [ "$waited" -lt "$TIMEOUT" ] || fail "timed out waiting for '$ID' to write $DOC; no agent was exited"
      sleep "$POLL"
      waited=$(( waited + POLL ))
    done
    echo "continuation doc captured: $DOC"
  fi
fi

# --- 5. exit the old agent -------------------------------------------------
if [ -n "$DRY_RUN" ]; then
  printf 'DRY-RUN: exit agent %s via %s exit form, then respawn\n' "$WINDOW" "$HARNESS"
else
  if agent_alive; then
    echo "exiting the old '$ID' agent..."
    # Harness-correct exit form (harness-adapters): codex and pi quit with
    # /quit; claude, opencode, and grok use /exit.
    case "$HARNESS" in
      codex|pi) EXIT_CMD=/quit ;;
      *) EXIT_CMD=/exit ;;
    esac
    "$SCRIPT_DIR/fm-send.sh" "$ID" "$EXIT_CMD" || true
    waited=0
    while ! agent_dead; do
      if [ "$waited" -ge "$EXIT_TIMEOUT" ]; then
        echo "agent did not exit cleanly; clearing the endpoint"
        fm_backend_kill "$BACKEND" "$WINDOW" || true
        break
      fi
      sleep "$POLL"
      waited=$(( waited + POLL ))
    done
  fi
  # Clear the (now bare-shell or gone) window so respawn recreates a clean endpoint.
  fm_backend_kill "$BACKEND" "$WINDOW" 2>/dev/null || true
fi

# --- 6. respawn a fresh secondmate -----------------------------------------
act "$SCRIPT_DIR/fm-spawn.sh" "$ID" --secondmate

if [ -n "$DRY_RUN" ]; then
  printf 'DRY-RUN: point fresh agent at %s\n' "$DOC"
else
  # Give the fresh agent a beat to boot, then point it at the durable doc. Its
  # charter and AGENTS.md recovery already run on launch; this adds the
  # continuation context so it never relies on compacted memory.
  sleep "$POLL"
  "$SCRIPT_DIR/fm-send.sh" "$ID" "Context handoff recovery: read data/handoff-latest.md for continuation context, then resume per your charter." || true
  rm -f "$REQ" "$DONE"
fi

echo "handoff complete for '$ID': fresh agent respawned from durable state"
