#!/usr/bin/env bash
# Turn-end guard for any firstmate PRIMARY session: the main home OR a
# secondmate's own home. A secondmate runs its own primary firstmate session and
# is guarded exactly like the main primary; only child crew/scout worktrees are
# exempt (see the scoping block below and docs/turnend-guard.md).
#
# fm-guard.sh (bin/fm-guard.sh) is pull-based: it only warns when some other
# supervision script happens to run. A primary session that ends a turn without
# resuming its harness supervision protocol, and then never runs another
# fleet-touching command itself, can sit blind for hours.
# This script is push-based: verified harness turn-end hooks invoke it every time
# the primary is about to end a turn.
# Claude and codex can block directly by preserving exit status 2 and stderr.
# OpenCode, pi, and grok adapters use the same predicate and force one bounded
# follow-up because their turn-end events are passive.
# See docs/turnend-guard.md for the per-harness mechanics, validation evidence,
# and fail-open tradeoffs.
#
# Ships with TRACKED harness hook files at the repo root, so this file is
# checked out into every worktree of this repo: the primary checkout, every
# secondmate home (treehouse-leased or git-cloned), and any crewmate/scout task
# worktree spawned to work on firstmate itself (the recursive "firstmate
# improving itself" case). A secondmate home runs its OWN primary firstmate
# session, so it must be guarded like the main primary; only child crew/scout
# worktrees are exempt. It must therefore scope itself at runtime to a real
# primary checkout - the main home or a genuinely marked secondmate home - and
# stay a silent, fast no-op inside child task worktrees.
#
# Loop-guard: never block twice in the same turn. Claude Code and codex Stop
# payloads carry stop_hook_active=true when the CURRENT stop attempt was itself
# already forced by an earlier block this turn; on that signal we always allow
# the stop, whether or not watcher supervision actually got resumed. Passive
# harness adapters provide their own one-follow-up guard before calling this
# script.
# That bounds this to at most one forced continuation per turn - never a wedged,
# un-endable session - while still nagging again on a later turn if the problem
# persists.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-900}
WATCH="$SCRIPT_DIR/fm-watch.sh"

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

# Read the whole turn-end hook payload once; never block on unreadable/absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# jq is the repo's established JSON dependency (bin/fm-x-poll.sh uses the same
# "missing jq -> silent no-op" degrade). Without it we cannot safely read the
# loop-guard field, so we must never block - fail open, not noisy.
command -v jq >/dev/null 2>&1 || exit 0

STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null) || exit 0
[ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

# --- scope precisely to a PRIMARY checkout ----------------------------------
# A genuinely-marked secondmate home runs its OWN primary firstmate session, so
# force-INCLUDE it as a guarded primary whether treehouse leased it as a linked
# worktree (git-dir != git-common-dir) or it is a git-cloned plain checkout. This
# mirrors the cd-guard's intent that a secondmate's own session is a guarded
# primary. Only an UNMARKED checkout (or one with an invalid marker) falls
# through to the linked-worktree exemption: firstmate hands out crewmate/scout
# task worktrees as genuine linked `git worktree`s (bin/fm-spawn.sh aborts
# otherwise), whose git-dir lives under the parent repo's .git/worktrees/<name>
# and differs from the common (shared) git-dir, while a main, non-worktree
# checkout has the two equal. Child worktrees never carry the gitignored marker,
# so this exempts them while guarding every real secondmate home.
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- the actual predicate ----------------------------------------------------
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# shellcheck source=bin/fm-afk-daemon-lib.sh
. "$SCRIPT_DIR/fm-afk-daemon-lib.sh"

fm_supervision_status "$STATE" "$GRACE"
[ "$FM_SUP_IN_FLIGHT" -gt 0 ] || exit 0
if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
  # A live, identity-matched, fresh-beacon watcher is necessary but NOT sufficient
  # to be non-blind: the incident had exactly that and still went deaf because
  # nothing owned a path that would COMPLETE to wake the idle model. So verify
  # wake-path ownership too. If a wakeable owner exists (present daemon, away
  # daemon, or a live this-home arm), the turn can end. If the watcher is alive
  # but NO owner exists, fall through to the blind banner with a wake-path-specific
  # detail. fm_wake_path_owned errs toward owned on any probe uncertainty, so this
  # never nags on a transient handoff; a genuinely dead watcher is still caught by
  # the beacon check above and below.
  if fm_wake_path_owned "$STATE" "$SCRIPT_DIR"; then
    exit 0
  fi
  wake_path_blind=1
fi

# Away mode alone does NOT mean a daemon owns supervision. A home whose captain
# session runs outside any injectable supervisor pane deliberately runs away mode
# WITHOUT a daemon: the away posture is on, while this home's own watcher stays
# the real supervision mechanism. Only a live daemon for THIS home transfers
# watcher ownership away (bin/fm-afk-daemon-lib.sh; this home's own lock path
# keeps another home's daemon out, while strict matching rejects a non-daemon
# process), so the repair line points at re-arming the watcher unless a daemon
# really owns it here.
afk=0
fm_afk_daemon_owns_supervision "$STATE" "$SCRIPT_DIR" && afk=1

# The live-watcher test above already ran and failed, so a fresh beacon means the
# watcher that produced it is gone rather than that no watcher ever beat; saying
# "no live watcher" while printing a fresh beacon age would contradict itself.
# The wake-path-blind case is different: the watcher IS alive and holding the
# lock, but nothing will complete to wake this session, so its detail must say
# that instead of claiming the watcher is gone.
if [ "${wake_path_blind:-0}" -eq 1 ]; then
  detail='a watcher is alive but nothing will complete to wake this session (no live present daemon, away daemon, or arm task owns the wake path)'
elif [ "$FM_SUP_WATCHER_FRESH" = true ]; then
  detail=$(printf 'the watcher that last beat %s is no longer holding this home lock' "$FM_SUP_BEACON_DESC")
else
  detail=$(printf 'no live watcher holds this home lock (last beat: %s)' "$FM_SUP_BEACON_DESC")
fi
situation=$(fm_afk_posture_situation "$STATE" "$afk" "$FM_SUP_IN_FLIGHT" "$detail")

x_mode=0
[ -f "$CONFIG/x-mode.env" ] && x_mode=1
REASON=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --afk "$afk" --x-mode "$x_mode" --repair-line 2>/dev/null \
  || printf '%s\n' 'tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn')
rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
{
  printf '●%s\n' "$rule"
  printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n'
  printf '●  %s.\n' "$situation"
  printf '●  %s\n' "$REASON"
  printf '●%s\n' "$rule"
} >&2
exit 2
