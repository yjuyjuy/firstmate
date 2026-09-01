#!/usr/bin/env bash
# Opt-in credentialed end-to-end proof that a jcode crewmate spawn works, the
# one thing no faked suite can establish: jcode takes no positional prompt, so
# the whole adapter rests on bin/fm-spawn.sh's post-launch delivery of the launch
# profile and the brief pointer actually landing in a real session.
#
# It spawns a real jcode crewmate in a throwaway firstmate home on a private tmux
# socket, gives it a trivial file-creating task, and asserts:
#   1. the launch profile applied per session (/model and /effort), which is the
#      only way jcode accepts either axis;
#   2. the brief pointer landed and the agent actually did the work;
#   3. the pane reads BUSY mid-turn and its composer reads EMPTY when idle, the
#      two signals jcode supervision depends on (it has no turn-end hook, so
#      stale-pane detection is the whole supervision mechanism);
#   4. /quit exits cleanly and prints the resume command.
# Every fact above is also pinned cheaply in tests/fm-jcode-harness.test.sh
# against captured fixtures; this suite is what proves those fixtures are real.
#
# It consumes real model quota, so it is opt-in and never runs in CI.
set -u

if [ "${FM_JCODE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_JCODE_LIVE_E2E=1 to run the interactive jcode crewmate spawn regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ID=jcode-live-probe
MODEL=${FM_JCODE_LIVE_MODEL:-claude-opus-4-8}
EFFORT=${FM_JCODE_LIVE_EFFORT:-low}

TMP_ROOT=
SHIM_DIR=
REAL_TMUX=
SOCKET="fm-jcode-live-$$"

cleanup_all() {
  if [ -n "$REAL_TMUX" ]; then
    "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fi
  [ -z "${TMP_ROOT:-}" ] || rm -rf "$TMP_ROOT"
  [ -z "${SHIM_DIR:-}" ] || rm -rf "$SHIM_DIR"
}
trap cleanup_all EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

for tool in jcode tmux treehouse git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done
REAL_TMUX=$(command -v tmux)

# Every tmux call - this suite's own and bin/backends/tmux.sh's bare `tmux ...` -
# is redirected to a private socket so the host's real sessions are untouched.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-jcode-live-shim.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-jcode-live.XXXXXX")
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/$ID" "$HOME_DIR/config" "$HOME_DIR/projects"
# tmux is the reference backend and the one this suite drives.
printf 'tmux\n' > "$HOME_DIR/config/backend"

PROJECT="$HOME_DIR/projects/jcodeprobe"
mkdir -p "$PROJECT"
git -C "$PROJECT" init -q
git -C "$PROJECT" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
printf '%s\n' "- jcodeprobe (local-only)" > "$HOME_DIR/data/projects.md"

MARKER="$TMP_ROOT/agent-did-the-work"
cat > "$HOME_DIR/data/$ID/brief.md" <<BRIEF
# Task
Run exactly this one shell command and then stop:

    printf 'jcode-live-e2e-ok\n' > $MARKER

Do not change any file in the repository. Do not commit anything.
BRIEF

tmux new-session -d -s "$SOCKET" -c "$PROJECT" -x 200 -y 50 \
  || fail "could not create the private tmux session"

out=$(FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" \
  "$ID" "projects/jcodeprobe" jcode --model "$MODEL" --effort "$EFFORT" 2>&1) \
  || fail "fm-spawn.sh refused a jcode crewmate spawn: $out"
case "$out" in
  *"harness=jcode"*) : ;;
  *) fail "the spawn did not report harness=jcode: $out" ;;
esac
META="$HOME_DIR/state/$ID.meta"
grep -qx "harness=jcode" "$META" || fail "meta did not record harness=jcode"
grep -qx "model=$MODEL" "$META" || fail "meta did not record model=$MODEL"
grep -qx "effort=$EFFORT" "$META" || fail "meta did not record effort=$EFFORT"
[ -e "$HOME_DIR/state/$ID.turn-ended" ] \
  && fail "no turn-end signal may exist for jcode (it has no reachable turn-end hook)"
pass "fm-spawn.sh: a jcode crewmate spawns and records its harness, model, and effort"

TARGET=$(sed -n 's/^window=//p' "$META")
[ -n "$TARGET" ] || fail "meta recorded no window target"

# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

capture() { tmux capture-pane -p -t "$TARGET" -S -400 2>/dev/null || true; }
wait_for_text() {  # <text> <seconds>
  local text=$1 budget=$2 i=0
  while [ "$i" -lt "$budget" ]; do
    case "$(capture)" in *"$text"*) return 0 ;; esac
    sleep 1
    i=$((i + 1))
  done
  return 1
}
# Border/whitespace-stripped matcher for a value that jcode's bordered composer
# may wrap across rows. A long brief pointer is broken mid-token by the composer
# box (a row ends with the path fragment, a padding run, and a `│` border, then
# the next row resumes the token), so a contiguous capture never holds the path.
# Removing every space, newline, and box-border glyph from both the capture and
# the needle rejoins the wrapped token; the needle here is an absolute path with
# no interior whitespace, so stripping it is a no-op and the match stays exact.
wait_for_wrapped_text() {  # <text> <seconds>
  local text=$1 budget=$2 i=0 needle joined
  needle=$(printf '%s' "$text" | tr -d '[:space:]' | sed 's/[│┃|]//g')
  while [ "$i" -lt "$budget" ]; do
    joined=$(capture | tr -d '[:space:]' | sed 's/[│┃|]//g')
    case "$joined" in *"$needle"*) return 0 ;; esac
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# The model/effort pin now runs through the debug socket, which persists to the
# session store rather than echoing into the pane, so verify against the STORE -
# the ground truth for what the session actually runs, and the exact oracle the
# spawn-time gate uses. This is a stronger check than a pane string: it proves the
# live session is really on the requested profile, the whole point of the fix.
# shellcheck source=bin/fm-token-sessions-lib.sh
. "$ROOT/bin/fm-token-sessions-lib.sh"
STORE_WT=$(sed -n 's/^worktree=//p' "$META")
[ -n "$STORE_WT" ] || fail "meta recorded no worktree to resolve the session id"
store_profile_matches() {  # polls the store until it shows the requested profile
  local budget=$1 i=0 sid prof am ae kv
  while [ "$i" -lt "$budget" ]; do
    sid=$(fm_resolve_crew_session_id "$STORE_WT" "" 2>/dev/null || true)
    if [ -n "$sid" ]; then
      prof=$(fm_session_store_profile "$sid" 2>/dev/null || true)
      am='' ae=''
      while IFS= read -r kv; do
        case "$kv" in model=*) am=${kv#model=} ;; effort=*) ae=${kv#effort=} ;; esac
      done <<EOF
$prof
EOF
      [ "$am" = "$MODEL" ] && [ "$ae" = "$EFFORT" ] && return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}
store_profile_matches 60 \
  || fail "the session store never showed the resolved model/effort (wanted $MODEL/$EFFORT)"
pass "jcode_post_launch_delivery: the resolved model and effort apply to the live session store"

wait_for_wrapped_text "$HOME_DIR/data/$ID/brief.md" 60 \
  || fail "the launch-brief pointer never landed in the session: $(capture | tail -20)"
pass "jcode_post_launch_delivery: the launch-brief pointer lands in the composer"

# Mid-turn the pane must read busy: that is the whole supervision signal for a
# harness with no turn-end wake.
saw_busy=0
i=0
while [ "$i" -lt 90 ]; do
  if fm_pane_is_busy "$TARGET"; then saw_busy=1; break; fi
  [ -f "$MARKER" ] && break
  sleep 1
  i=$((i + 1))
done
[ "$saw_busy" = 1 ] || fail "the pane never read busy while the agent worked"
pass "fm_pane_is_busy: a working jcode pane reads busy"

i=0
while [ "$i" -lt 180 ]; do
  [ -f "$MARKER" ] && break
  sleep 1
  i=$((i + 1))
done
[ -f "$MARKER" ] || fail "the agent never carried out the brief: $(capture | tail -20)"
grep -qx 'jcode-live-e2e-ok' "$MARKER" || fail "the marker file holds unexpected content"
pass "a jcode crewmate reads the brief pointer and does the work"

# Idle again: the composer must read empty, not pending, or away-mode injection
# would defer forever and every delivered submit would look swallowed.
i=0
state=
while [ "$i" -lt 60 ]; do
  fm_pane_is_busy "$TARGET" || { state=$(fm_tmux_composer_state "$TARGET"); break; }
  sleep 1
  i=$((i + 1))
done
[ "$state" = empty ] \
  || fail "an idle jcode composer must read empty, got '${state:-<still busy>}'"
pass "fm_tmux_composer_state: an idle jcode composer reads empty on a real pane"

# /quit exits cleanly and prints the resume command. The shared background server
# keeps serving every other session; nothing here stops or reloads it.
#
# The submit verdict is NOT the success signal for /quit: a successful /quit tears
# down the very composer that fm_tmux_submit_core polls to confirm delivery, so
# the confirmation read catches the pane mid-shutdown and returns `pending` (a
# false swallow) even though the command landed (verified 2026-07-31 on jcode
# 0.64.2: one Enter on the /quit popup exits and prints the resume line). So the
# verdict only has to prove the keystrokes were sent, not that the composer
# cleared: `pending` is expected and accepted here, and `send-failed` is the one
# real failure. The authoritative proof is the resume line the next step waits
# for, which only a genuine clean exit prints. Real teardown never depends on
# this verdict anyway - bin/fm-teardown.sh kills the recorded pane endpoint.
verdict=$(fm_tmux_submit_core "$TARGET" '/quit' 3 0.4 1.2)
case "$verdict" in
  empty|unknown|pending) : ;;
  *) fail "/quit keystrokes were not sent (verdict $verdict)" ;;
esac
wait_for_text "jcode --resume" 30 \
  || fail "/quit did not print the resume command: $(capture | tail -20)"
pass "jcode: /quit exits cleanly and prints its resume command"
