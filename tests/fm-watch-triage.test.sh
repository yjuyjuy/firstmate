#!/usr/bin/env bash
# tests/fm-watch-triage.test.sh - the always-on wake triage built into
# bin/fm-watch.sh and the shared classifier (bin/fm-classify-lib.sh). The watcher
# now absorbs the benign majority of wakes in bash and exits ONLY on an actionable
# wake, so firstmate's LLM re-arms once per actionable event instead of once per
# wake. These tests cover the classifier predicates as pure functions, then drive
# a real fm-watch.sh subprocess to assert the behavioral contract:
# provably-working no-verb wakes absorbed (no exit, no queue entry, suppressor
# advanced, beacon fresh), stopped-crew no-verb wakes surfaced (queue + exit),
# provably-working stale panes absorbed-then-escalated past the threshold,
# terminal-looking stale status lines overridden by an active run, the heartbeat
# backstop fail-safe, and afk coherence (no double-triage while the away-mode
# daemon owns supervision).
#
# Daemon-side classification/injection lives in fm-daemon.test.sh; watcher/lock
# liveness in fm-watcher-lock.test.sh; the durable-queue safety matrix in
# fm-wake-queue.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

# Timing convention (mirrors tests/fm-watch-checkpoint.test.sh's header): these
# cases race a real fm-watch.sh process that must boot (library sourcing, the
# PR-check migration scan, lock acquisition) and then run at least one full poll
# cycle - sleep POLL plus the signal-coalescing linger plus the scan - before it
# surfaces or advances a marker. That first cycle is a few seconds even idle and
# stretches under host load (measured ~4.4s on a load-15 shared host). So every
# wait here is a bounded HANG GUARD, never a timing assumption: the wait breaks
# the instant its condition holds, so a fast host spends only a few ticks and a
# slow host just takes longer instead of failing. Ceilings are deliberately
# generous (wait_for_exit "$pid" 200 = 20s, marker polls 200 ticks = 20s) for
# that reason. A previous 40-tick (4s) budget flaked on a loaded CI host with no
# watcher defect, because the first cycle landed one tick past the ceiling. Only
# the tick-off "must stay quiet" cases keep a short window, because the short
# bound is the thing under test there.
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-triage-tests)

# Common watcher knobs: tight poll/grace, no check or heartbeat cadence unless a
# test overrides them, so a test only exercises the path it targets. FM_CREW_STATE_BIN
# points at the case's hermetic fake fm-crew-state.sh (installed by make_case) so the
# absorb-only-when-provably-working triage reads a canned verdict; a test fixes that
# verdict via FM_FAKE_CREW_STATE in its environment before calling watch_bg.
watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" &
}

# Wait up to <limit> 0.1s ticks while <pid> stays alive; 0 if still alive, 1 if it died.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

# Wait up to <limit> 0.1s ticks for <pid> to leave the process table; 0 once it
# is gone, 1 if it is still there. Bounded like every other wait here, so a pid
# that never gets reaped fails the case instead of spinning the suite.
wait_gone() {
  local pid=$1 limit=${2:-40} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_numeric_file() {
  local file=$1 limit=${2:-30} i=0 value
  while [ "$i" -lt "$limit" ]; do
    value=$(cat "$file" 2>/dev/null || true)
    case "$value" in
      ''|*[!0-9]*) ;;
      *) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Portable mtime in epoch seconds. Platform-detected, never the `stat -f || stat -c`
# fallback (which writes a partial filesystem dump on Linux; see fm-watch.sh).
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# Signature a primed .seen-* marker must hold so the per-poll signal scan does not
# fire on a pre-existing status (mirrors fm-watch.sh's stat_sig exactly).
seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# --- pure classifier predicates (fm-classify-lib.sh) ------------------------

test_signal_reason_is_actionable_classifier() {
  local dir state
  dir=$(make_case classify-signal); state="$dir/state"
  printf 'working: step 1\nworking: step 2\n' > "$state/a.status"
  signal_reason_is_actionable "$state/a.status" && fail "benign working: signal classified actionable"
  printf 'working: x\nneeds-decision: pick A or B\n' > "$state/b.status"
  signal_reason_is_actionable "$state/b.status" || fail "captain-relevant signal classified benign"
  : > "$state/c.turn-ended"
  signal_reason_is_actionable "$state/c.turn-ended" && fail "a bare turn-ended marker classified actionable"
  # Coalesced batch: one benign + one captain-relevant -> actionable.
  signal_reason_is_actionable "$state/a.status" "$state/b.status" || fail "coalesced benign+actionable not actionable"
  pass "signal_reason_is_actionable: benign absorbed, captain verbs and coalesced batches surfaced"
}

# Drift guard: the poll cadence is an operating value the tracked default owns.
# A cadence that lives only in a local settings file drifts silently, so assert
# the tracked default here, and assert the POLL < grace invariant holds for the
# grace the captain pairs with it.
test_tracked_poll_default() {
  local resolved poll grace
  # shellcheck disable=SC2016  # the bash -c body must expand in the child, not here
  resolved=$(env -u FM_POLL -u FM_WATCHER_STALE_GRACE -u FM_GUARD_GRACE \
    FM_STATE_OVERRIDE="$TMP_ROOT/poll-default-state" bash -c \
    '. "$1" >/dev/null 2>&1; printf "%s %s" "$POLL" "$WATCHER_STALE_GRACE"' _ "$WATCH")
  poll=${resolved% *}; grace=${resolved#* }
  [ "$poll" = 300 ] || fail "tracked FM_POLL default is '$poll', expected 300"
  [ "$grace" = 900 ] || fail "tracked beacon grace default is '$grace', expected 900"
  [ "$poll" -lt "$grace" ] || fail "tracked defaults violate POLL < grace: POLL $poll, grace $grace"
  pass "tracked FM_POLL default is 300 and stays below the tracked 900s beacon grace"
}

test_stale_is_terminal_classifier() {
  local dir state
  dir=$(make_case classify-stale); state="$dir/state"
  printf 'done: ready in branch fm/x\n' > "$state/term.status"
  stale_is_terminal "sess:fm-term" "$state" || fail "terminal stale status not classified terminal"
  fm_write_meta "$state/herdr-term.meta" "window=default:w1:p2" "backend=herdr"
  printf 'done: ready in branch fm/herdr\n' > "$state/herdr-term.status"
  stale_is_terminal "default:w1:p2" "$state" || fail "terminal herdr stale status not resolved through metadata"
  printf 'working: compiling\n' > "$state/nonterm.status"
  stale_is_terminal "sess:fm-nonterm" "$state" && fail "non-terminal stale classified terminal"
  stale_is_terminal "sess:fm-missing" "$state" && fail "stale with no status classified terminal"
  pass "stale_is_terminal: terminal status surfaces, non-terminal and no-status are benign"
}

test_scan_captain_relevant_statuses_classifier() {
  local dir state out
  dir=$(make_case classify-scan); state="$dir/state"
  printf 'working: a\n' > "$state/one.status"
  printf 'blocked: no perms\n' > "$state/two.status"
  printf 'done: PR https://x/y/pull/1\n' > "$state/three.status"
  out=$(scan_captain_relevant_statuses "$state")
  printf '%s' "$out" | grep -F "two.status" >/dev/null || fail "scan missed a blocked: status"
  printf '%s' "$out" | grep -F "three.status" >/dev/null || fail "scan missed a done: status"
  printf '%s' "$out" | grep -F "one.status" >/dev/null && fail "scan surfaced a benign working: status"
  pass "scan_captain_relevant_statuses lists only captain-relevant statuses"
}

test_classifier_primitives() {
  local dir state open activity
  dir=$(make_case classify-primitives); state="$dir/state"
  printf 'working: a\n\ndone: b\n\n' > "$state/x.status"
  [ "$(last_status_line "$state/x.status")" = "done: b" ] || fail "last_status_line did not return the last non-blank line"
  status_is_captain_relevant "done: b" || fail "done: not recognized as captain-relevant"
  status_is_captain_relevant "needs-decision [key=q1]: b" || fail "keyed needs-decision not recognized as captain-relevant"
  status_is_captain_relevant "working: b" && fail "working: wrongly recognized as captain-relevant"
  # Incident regression: free-text "merged" inside a nonterminal working: line must
  # not become captain-relevant (AFK false-terminal path).
  status_is_captain_relevant \
    "working: stage 2 setup complete on PR #74 exact source branch rebased onto merged #76; task dates preserved" \
    && fail "working: ... merged #N wrongly recognized as captain-relevant"
  status_is_captain_relevant "working: rebased onto predecessor #76" \
    && fail "working: predecessor prose wrongly recognized as captain-relevant"
  status_is_captain_relevant "working: PR ready checks green merged ready in branch" \
    && fail "working: free-text tokens wrongly recognized as captain-relevant"
  status_is_captain_relevant "done: PR https://x/pull/76 checks green" \
    || fail "genuine done: checks green not captain-relevant"
  status_is_terminal_verb "done: PR https://x/pull/76 checks green" \
    || fail "done: not a terminal verb"
  status_is_terminal_verb "working: rebased onto merged #76" \
    && fail "working: wrongly classed as terminal verb"
  status_is_captain_relevant "merged" || fail "legacy bare merged free-text not captain-relevant"
  status_is_captain_relevant "PR ready https://x/pull/2" \
    || fail "legacy bare PR ready free-text not captain-relevant"
  [ "$(window_to_task "sess:fm-fix-login-k3")" = "fix-login-k3" ] || fail "window_to_task did not strip session+fm- prefix"
  fm_write_meta "$state/herdr-task.meta" "window=default:w1:p2" "backend=herdr"
  [ "$(window_to_task "default:w1:p2" "$state")" = "herdr-task" ] || fail "window_to_task did not resolve opaque backend target through metadata"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "custom-verb: x" || fail "FM_CAPTAIN_RE override not honored"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "done: x" && fail "FM_CAPTAIN_RE override did not replace the default verb set"
  FM_CAPTAIN_RE='merged|custom-verb:' status_is_captain_relevant "working: rebased onto merged #76" \
    && fail "FM_CAPTAIN_RE override bypassed working: suppression"
  FM_CAPTAIN_RE='checks green|custom-verb:' status_is_captain_relevant "paused: checks green pending approval" \
    && fail "FM_CAPTAIN_RE override bypassed paused: suppression"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "custom-verb: x" \
    || fail "nonterminal suppression weakened custom bare-line behavior"
  printf 'needs-decision: should docs mention [key=prose]?\nneeds-decision [key=q1]: real choice\nresolved: docs still mention [key=q1]\nneeds-decision [key=bad key]: malformed\n' > "$state/keys.status"
  open=$(status_open_decisions "$state/keys.status")
  printf '%s' "$open" | grep -F $'q1\t' >/dev/null \
    || fail "a key token in resolved note prose closed the keyed decision"
  printf '%s' "$open" | grep -F $'prose\t' >/dev/null \
    && fail "a key token in note prose changed the decision key"
  printf '%s' "$open" | grep -F $'bad key\t' >/dev/null \
    && fail "an invalid key slug entered the open-decision set"
  cat > "$state/activity.status" <<'EOF'
working [key=phase7]: Phase 7 started
working [key=phase6]: Phase 6 started
working [key=legal]: reviewing legal dependency
done [key=phase6]: Phase 6 completed
resolved [key=phase7]: Phase 7 completed and moved to Done
paused [key=legal]: awaiting external counsel
resolved [key=legal]: legal item returned to the queue
working [key=phase8]: Phase 8 started
EOF
  activity=$(status_open_activities "$state/activity.status")
  printf '%s' "$activity" | grep -F $'phase8\tworking\tPhase 8 started' >/dev/null \
    || fail "the current keyed working phase was not retained"
  printf '%s' "$activity" | grep -F $'phase7\t' >/dev/null \
    && fail "a keyed resolved event did not close the older working phase"
  printf '%s' "$activity" | grep -F $'phase6\t' >/dev/null \
    && fail "a same-key terminal event did not supersede the older working phase"
  printf '%s' "$activity" | grep -F $'legal\t' >/dev/null \
    && fail "a keyed resolved event did not close the declared pause"
  printf 'working: legacy start\ndone: legacy completion\n' > "$state/legacy-activity.status"
  [ -z "$(status_open_activities "$state/legacy-activity.status")" ] \
    || fail "a legacy terminal event did not supersede the default working phase"
  pass "classifier primitives: keyed decisions and activity phases, captain relevance, window-to-task, and overrides"
}

# crew_is_provably_working: the absorb-only-when-provably-working predicate. It is
# benign (absorb) ONLY when fm-crew-state.sh reports the crew as working from an
# actively-running pipeline step (source run-step) or a busy pane (source pane);
# everything else - a stale working: status-log line, a finished/parked/failed run,
# an unknown/torn-down crew, or an empty id - is NOT provable, so it surfaces. The
# fake fm-crew-state.sh (FM_CREW_STATE_BIN) returns a canned verdict per case.
test_crew_is_provably_working_classifier() {
  local dir fakebin
  dir=$(make_case provably-working); fakebin="$dir/fakebin"
  # Point the predicate at this case's hermetic fake and drive its verdict per case.
  # export marks the var for the fake subprocess; it is unset again at the end so it
  # cannot leak into a later test (every behavioral test sets its own verdict anyway).
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  crew_is_provably_working a || fail "active run-step not treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  crew_is_provably_working a || fail "busy pane not treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling'
  ! crew_is_provably_working a || fail "stale status-log working: treated as provably working"
  FM_FAKE_CREW_STATE='state: done · source: run-step · checks green'
  ! crew_is_provably_working a || fail "finished run treated as provably working"
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review'
  ! crew_is_provably_working a || fail "parked run treated as provably working"
  FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed'
  ! crew_is_provably_working a || fail "failed run treated as provably working"
  FM_FAKE_CREW_STATE='state: unknown · source: none · worktree gone'
  ! crew_is_provably_working a || fail "unknown crew treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: run-step · x'
  ! crew_is_provably_working "" || fail "empty id treated as provably working"
  unset FM_FAKE_CREW_STATE
  pass "crew_is_provably_working: only working+run-step/pane is provable; idle/finished/parked/failed/unknown surface"
}

# status_is_paused: the shared pause verb test both consumers read (so neither
# hardcodes the literal). Matches only the verb before the first colon, so a reason
# that merely mentions "paused" does not false-match, and a genuine blocker stays a
# blocker.
test_status_is_paused_classifier() {
  status_is_paused 'paused: holding for the upstream release' || fail "paused verb not recognized"
  status_is_paused '  paused:   waiting on a rate-limit reset' || fail "leading-space paused verb not recognized"
  status_is_paused 'blocked: the build is paused upstream' && fail "a blocked line mentioning paused false-matched"
  status_is_paused 'working: paused the animation loop' && fail "a working line mentioning paused false-matched"
  status_is_paused 'done: shipped' && fail "done classified as paused"
  status_is_paused '' && fail "empty line classified as paused"
  # A pause is deliberately NOT captain-relevant: it is a stop-nagging signal, not
  # work to keep surfacing.
  status_is_captain_relevant 'paused: holding for the upstream release' && fail "paused is captain-relevant (should not be)"
  status_is_paused_or_captain_held 'paused: holding for the upstream release' \
    || fail "declared pause not recognized by the bounded-idle classifier"
  status_is_paused_or_captain_held 'captain-held [key=route]: tracked by task-decision-route' \
    || fail "captain-held transfer not recognized by the bounded-idle classifier"
  status_is_paused_or_captain_held 'resolved [key=route]: captain answered' \
    && fail "resolved decision remained classed as captain-held"
  # Auth/quota/token exhaustion is captain-fixable, not a benign wait: a paused:
  # line carrying that vocabulary must NOT class as paused, and MUST surface as
  # captain-relevant, so the 2026 shared-account usage-window stall cannot idle for
  # hours on the benign pause cadence.
  status_is_auth_exhaustion_pause 'paused: hit the Claude usage limit, resets 18:00' \
    || fail "usage-limit pause not recognized as auth exhaustion"
  status_is_paused 'paused: hit the Claude usage limit, resets 18:00' \
    && fail "usage-limit pause still classed as a benign paused wait"
  status_is_captain_relevant 'paused: hit the Claude usage limit, resets 18:00' \
    || fail "usage-limit pause not surfaced as captain-relevant"
  status_is_auth_exhaustion_pause 'paused: shared account usage-window exhausted' \
    || fail "usage-window exhaustion not recognized"
  status_is_auth_exhaustion_pause 'paused: session limit reached, waiting for reset' \
    || fail "session-limit pause not recognized"
  status_is_auth_exhaustion_pause 'paused: token revoked, need to relogin' \
    || fail "revoked-token pause not recognized"
  status_is_auth_exhaustion_pause 'paused: auth token expired, switch account' \
    || fail "expired-token pause not recognized"
  status_is_auth_exhaustion_pause 'paused: over quota on the shared key' \
    || fail "quota pause not recognized"
  # Regression guard: an ordinary bounded external wait stays paused, including a
  # bare vendor rate-limit reset (the canonical benign pause), and non-paused verbs
  # never match the exhaustion predicate even when their prose mentions a token.
  status_is_auth_exhaustion_pause 'paused: holding for the upstream release' \
    && fail "an ordinary external-wait pause false-matched auth exhaustion"
  status_is_paused 'paused: holding for the upstream release' \
    || fail "ordinary external-wait pause regressed off the paused cadence"
  status_is_auth_exhaustion_pause 'paused: waiting on a vendor rate-limit reset' \
    && fail "a vendor rate-limit reset pause false-matched auth exhaustion"
  status_is_paused 'paused: waiting on a vendor rate-limit reset' \
    || fail "vendor rate-limit reset pause regressed off the paused cadence"
  status_is_auth_exhaustion_pause 'working: wiring the token refresh path' \
    && fail "a working line about auth code false-matched auth exhaustion"
  status_is_auth_exhaustion_pause 'blocked: usage limit hit' \
    && fail "a blocked line matched the paused-only auth-exhaustion predicate"
  pass "status_is_paused: only the leading paused verb matches, and paused is not captain-relevant"
}

# crew_absorb_class: the single fm-crew-state.sh read that returns BOTH absorb
# reasons - working (active run/busy pane), paused (declared external wait), or none
# (surface it) - so the watcher's stale path gets both for one bounded call.
# crew_is_paused delegates to it exactly as crew_is_provably_working does.
test_crew_absorb_class_classifier() {
  local dir fakebin
  dir=$(make_case absorb-class); fakebin="$dir/fakebin"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  [ "$(crew_absorb_class a)" = working ] || fail "active run-step not classed working"
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  [ "$(crew_absorb_class a)" = working ] || fail "busy pane not classed working"
  FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting upstream'
  [ "$(crew_absorb_class a)" = paused ] || fail "declared pause not classed paused"
  crew_is_paused a || fail "crew_is_paused did not recognize a paused verdict"
  ! crew_is_provably_working a || fail "a paused crew was treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling'
  [ "$(crew_absorb_class a)" = none ] || fail "stale working: status-log classed absorbable"
  FM_FAKE_CREW_STATE='state: unknown · source: none · worktree gone'
  [ "$(crew_absorb_class a)" = none ] || fail "unknown crew classed absorbable"
  ! crew_is_paused a || fail "unknown crew classed paused"
  [ "$(crew_absorb_class "")" = none ] || fail "empty id not classed none"
  unset FM_FAKE_CREW_STATE
  pass "crew_absorb_class: working/paused/none from one read; crew_is_paused and crew_is_provably_working agree"
}

# signal_crew_provably_working: a no-verb "signal:" wake is benign ONLY when EVERY
# task it references is provably working; if any crew has stopped, or no task can be
# resolved, it surfaces. Files map to ids by stripping .status / .turn-ended.
test_signal_crew_provably_working_classifier() {
  local dir fakebin state
  dir=$(make_case signal-provably-working); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE_a='state: working · source: run-step · running'
  export FM_FAKE_CREW_STATE_b='state: done · source: run-step · run passed'
  signal_crew_provably_working "$state/a.status" "$state/a.turn-ended" \
    || fail "a single provably-working crew (status+turn-end) was not benign"
  ! signal_crew_provably_working "$state/a.status" "$state/b.turn-ended" \
    || fail "a coalesced batch including a stopped crew was treated as benign"
  ! signal_crew_provably_working "$state/b.turn-ended" \
    || fail "a stopped crew's bare turn-end was treated as benign"
  ! signal_crew_provably_working "$state/a.meta" \
    || fail "a non-signal file resolved to a benign verdict"
  ! signal_crew_provably_working \
    || fail "an empty signal file list was treated as benign"
  unset FM_FAKE_CREW_STATE_a FM_FAKE_CREW_STATE_b
  pass "signal_crew_provably_working: benign only when every referenced crew is provably working"
}

# --- benign wakes are absorbed ONLY when the crew is provably working ---------

test_provably_working_signal_absorbed() {
  local dir state fakebin out status_file pid
  dir=$(make_case provably-working-signal); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # The crew's pipeline is in an actively-running step: positive evidence it is
  # still working, so a no-verb working: signal is absorbed (the original low-churn
  # case during a long validation).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  # Poll until the watcher has actually processed the signal scan (its .seen-*
  # suppressor advances) rather than checking after a fixed wait, which raced the
  # watcher's startup. It must stay alive and never queue a wake while absorbing.
  # The 200-tick (20s) ceiling is a generous hang guard, not a timing assumption:
  # the loop breaks the instant the suppressor appears, so a fast host spends only
  # a few ticks. It replaces an earlier 40-tick (4s) budget that flaked on a loaded
  # host - the watcher's first cycle (sleep POLL + signal-coalesce linger + the
  # scan) takes ~4.4s under heavy load, just past 4s, so the suppressor landed one
  # tick late and the case failed with no watcher defect. Every "wait for a marker
  # file to appear" poll in this suite uses the same 200-tick ceiling for the same
  # reason; each still asserts the exact resulting state after the wait.
  i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "watcher exited for a working: signal whose crew is provably working (should absorb): $(cat "$out")"; }
    [ -s "$state/.seen-task_status" ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ -s "$state/.seen-task_status" ] || { reap "$pid"; fail "provably-working signal did not advance its .seen-* suppressor"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "provably-working signal printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "provably-working signal enqueued a durable wake record"; }
  [ -e "$state/.last-watcher-beat" ] || { reap "$pid"; fail "watcher beacon was not touched while absorbing"; }
  reap "$pid"
  pass "a no-verb signal whose crew is provably working is absorbed (no exit, no queue, suppressor advanced, beacon present)"
}

test_turn_ended_provably_working_absorbed() {
  local dir state fakebin out pid
  dir=$(make_case turn-ended-working); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  : > "$state/task.turn-ended"
  # A busy pane is the second form of positive evidence (covers a queued
  # continuation right after the turn-end).
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a turn-end whose crew is provably working (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "provably-working turn-end printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "provably-working turn-end enqueued a durable wake record"
  reap "$pid"
  pass "a bare turn-end whose crew is provably working (busy pane) is absorbed"
}

# --- a no-verb signal whose crew is NOT provably working SURFACES -------------
# This is the swallowed-finish fix: a crew that finished (or stopped and waits)
# reports its final turn-end with no captain-relevant status and no running
# pipeline, so the wake must surface instead of being absorbed.

test_turn_ended_not_working_surfaced() {
  local dir state fakebin out drain_out pid
  dir=$(make_case turn-ended-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  : > "$state/task.turn-ended"
  # No running pipeline, no busy pane: the crew has stopped (e.g. it finished via
  # an interactive menu and wrote no done: status). Default unknown verdict.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 200 || fail "watcher did not surface a turn-end whose crew is not provably working"
  grep -F "signal: $state/task.turn-ended" "$out" >/dev/null || fail "watcher did not print the surfaced turn-end signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/task.turn-ended" >/dev/null || fail "surfaced turn-end was not queued"
  pass "a bare turn-end whose crew is not provably working is surfaced (the swallowed-finish fix)"
}

test_working_note_not_working_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case working-note-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # A non-no-mistakes crew (no run) whose pane went idle: fm-crew-state falls back
  # to the stale working: status-log line. That is NOT positive evidence, so the
  # wake must surface - these users must never be left hanging.
  export FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling step 2'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 200 || fail "watcher did not surface a working: note whose crew has no running pipeline and an idle pane"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the surfaced working: signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced working: note failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "surfaced working: note was not queued"
  [ -s "$state/.seen-task_status" ] || fail "surfaced working: note did not advance its .seen-* suppressor"
  pass "a no-verb working: note whose crew is idle with no running pipeline is surfaced"
}

# --- actionable wakes are surfaced (queue + exit) ---------------------------

test_actionable_signal_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case actionable-signal); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: setup\nneeds-decision: pick A or B\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 200 || fail "watcher did not exit for an actionable needs-decision signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the actionable signal reason"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the actionable signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "actionable signal was not queued"
  [ -s "$state/.hb-surfaced-task" ] || fail "actionable signal did not record the surfaced marker"
  pass "captain-relevant signal is surfaced (queue + exit) and marked surfaced"
}

test_terminal_stale_surfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-done"
  printf 'finished, awaiting review' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/done.meta"
  printf 'done: PR https://example.test/pr/3\n' > "$state/done.status"
  sig=$(seen_sig "$state/done.status"); printf '%s' "$sig" > "$state/.seen-done_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "finished, awaiting review")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 200 || fail "watcher did not exit for a stale pane on a terminal status"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the terminal stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the terminal stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "terminal stale was not queued"
  pass "a stale pane sitting on a terminal status is surfaced (queue + exit)"
}

# --- stale pane, STALE terminal status overridden by an active run: absorbed ---
# Regression for the 2026-07 herdr false-surface incidents: a crew's own status
# log gets no new entry once firstmate hands it to a no-mistakes validation
# (AGENTS.md's sparse status-reporting contract), so the log keeps showing its
# pre-validation "done:" line as the LAST line for the run's entire (possibly
# many-minutes) duration. stale_is_terminal alone has no run-step awareness and
# would treat that leftover as still-current every time the pane goes quiet,
# immediately surfacing a crew that is actively validating. crew_is_provably_working
# must get a chance to override a captain-relevant-but-stale status line, exactly
# as it already does for a plain non-terminal one.
test_stale_terminal_status_overridden_by_active_run() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale-overridden); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-validating"
  printf 'no-mistakes axi run: validating...' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/validating.meta"
  # The crew reported done BEFORE firstmate triggered no-mistakes validation;
  # this line never gets superseded by a newer status-log entry while the
  # pipeline itself runs.
  printf 'done: implementation complete, ready to validate\n' > "$state/validating.status"
  sig=$(seen_sig "$state/validating.status"); printf '%s' "$sig" > "$state/.seen-validating_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "no-mistakes axi run: validating...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Phase A: a high escalation threshold means the first sighting is absorbed,
  # not surfaced, despite the captain-relevant "done:" status-log line.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  # Poll until the watcher processes the stale scan (suppressor advances) rather
  # than checking after a fixed wait, which raced startup. It must stay alive and
  # never surface while absorbing.
  i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "watcher exited for a stale terminal-looking status the run-step overrides (should absorb): $(cat "$out")"; }
    [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || { reap "$pid"; fail "stale suppressor not advanced on absorb"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "the overridden stale terminal status printed a wake reason during absorb"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "the overridden stale terminal status enqueued a wake during absorb"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "stale-since escalation timer was not recorded on absorb"; }
  [ ! -e "$state/.hb-surfaced-validating" ] || { reap "$pid"; fail "an absorbed wake must not mark the status line as surfaced"; }
  reap "$pid"

  # Phase B: backdate the idle timer past the threshold; the run genuinely
  # wedges and the next poll escalates exactly like the non-terminal case.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 200 || fail "watcher did not escalate an overridden stale terminal status past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  unset FM_FAKE_CREW_STATE
  pass "a stale terminal-looking status is overridden and absorbed while a run is actively working, then wedge-escalated"
}

# --- terminal stale, verdict unchanged across a pane redraw: absorbed ----------
# Churn regression: the harness footer carries a live "Churned for Xm Ys" timer
# and a running "Total:" counter, so every pane redraw advances the 40-line hash
# even when the crew's reconciled state has not moved. Keying terminal
# suppression on the pane hash re-surfaced an already-handled done crew on every
# redraw. The suppressor is now keyed on the reconciled fm-crew-state verdict, so
# a redraw that leaves the verdict unchanged is absorbed, and only a real verdict
# change re-surfaces.
test_terminal_stale_verdict_unchanged_absorbs_pane_redraw() {
  local dir state fakebin out capture_file window key old_hash new_hash sig pid i
  dir=$(make_case terminal-verdict-churn); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-done"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/done.meta"
  printf 'done: PR https://example.test/pr/9 checks green\n' > "$state/done.status"
  sig=$(seen_sig "$state/done.status"); printf '%s' "$sig" > "$state/.seen-done_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  # Already surfaced on a prior poll: the done verdict is recorded and the stale
  # suppressor holds the pane hash from that surface.
  old_hash=$(hash_text "Ready for /no-mistakes. Churned for 9m 28s")
  printf '%s' "$old_hash" > "$state/.stale-$key"
  printf 'done' > "$state/.stale-verdict-$key"
  # The footer timer ticked: the pane hash changes, the reconciled state does not.
  printf 'Ready for /no-mistakes. Churned for 9m 31s' > "$capture_file"
  new_hash=$(hash_text "Ready for /no-mistakes. Churned for 9m 31s")
  printf '%s' "$new_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  # Wait until the watcher has actually processed the stale scan (the suppressor
  # advances to the new hash) while it stays alive and never queues a wake.
  # 200-tick (20s) ceiling like the suite's other absorb-path waits: under heavy
  # host load the watcher's first cycle (sleep POLL + signal-coalesce linger +
  # scan) takes ~4.4s, past the earlier 60-tick (6s) budget, so a tighter bound
  # raced the watcher and flaked with no watcher defect.
  i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "watcher exited on a footer-timer redraw of an already-surfaced done crew (should absorb): $(cat "$out")"; }
    [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$new_hash" ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$new_hash" ] || { reap "$pid"; fail "stale suppressor was not advanced to the new pane hash on absorb"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "a footer-timer redraw of a done crew printed a wake reason"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "a footer-timer redraw of a done crew enqueued a stale wake"; }
  reap "$pid"

  # The reconciled state genuinely changes (done -> failed): it must re-surface,
  # even though this is just another pane redraw.
  export FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed'
  : > "$out"
  printf 'Ready for /no-mistakes. Churned for 9m 34s' > "$capture_file"
  printf '%s' "$(hash_text "Ready for /no-mistakes. Churned for 9m 34s")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 200 || fail "watcher did not re-surface when the reconciled verdict changed"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "a changed reconciled verdict did not print a stale wake"
  [ "$(cat "$state/.stale-verdict-$key" 2>/dev/null || true)" = failed ] || fail "the stored verdict was not updated to the new reconciled state"
  unset FM_FAKE_CREW_STATE
  pass "a terminal crew is absorbed across pane redraws while its reconciled verdict holds, and re-surfaces only when the verdict changes"
}

# --- the liveness beacon stays fresh through a full terminal sleep -------------
# Wedge regression: the beacon was touched only at the loop top, so a poll longer
# than the grace left a healthy sleeping watcher reading as dead for the back of
# every cycle. beacon_sleep slices the terminal wait into pieces no longer than
# BEACON_SLICE=min(POLL, grace/2) and re-touches the beacon each slice, so its age
# never crosses the grace mid-sleep.
#
# This is asserted as a DETERMINISTIC unit test of beacon_sleep itself rather than
# a wall-clock race against a running watcher. The earlier version launched a real
# watcher with POLL=4 > grace=2 and asserted the beacon's observed age never
# exceeded 2s. That age is not a property of the watcher alone: on a loaded host
# the test's own sampler is scheduled out for >2s between the watcher's touch and
# the reading, so a perfectly healthy watcher read as stale purely because THIS
# process did not run in time (the "beacon aged 3s past the 2s grace" flake, which
# reproduced on unmodified main under load). Worse, under enough load the healthy
# watcher's own 1s slices stretch too, so counting mtime advances over a fixed
# wall-clock window cannot reliably tell a healthy-but-throttled watcher from the
# single-touch-per-cycle regression either.
#
# So source the watcher (its guard returns before the lock/loop), stub `sleep` to
# return instantly, count how many times beacon_sleep touches the beacon, and
# assert it slices: beacon_sleep <total> with BEACON_SLICE=<slice> must touch
# ceil(total/slice) times, NOT once. A single loop-top touch (the regression)
# would count exactly 1. No wall clock, no host-load sensitivity.
test_beacon_stays_fresh_through_terminal_sleep() {
  local dir state count
  dir=$(make_case beacon-sleep-slice); state="$dir/state"
  mkdir -p "$state"
  # Drive beacon_sleep in a clean child process (env + bash -c) rather than a
  # command-substitution subshell that re-exports FM_* (which trips SC2030/SC2031).
  # The child sources the watcher (its guard returns before the lock/loop), stubs
  # `sleep` to return instantly and `touch` to count each beacon refresh, then runs
  # beacon_sleep and prints the touch count. beacon_count <total> <slice> -> count.
  beacon_count() {  # <total-seconds> <beacon-slice>
    FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" \
      bash -c '
        set -u
        total=$1; slice=$2
        # shellcheck source=bin/fm-watch.sh
        . "$FM_ROOT_OVERRIDE/bin/fm-watch.sh"
        n=0
        sleep() { :; }
        touch() { command touch "$@"; n=$((n + 1)); }
        BEACON_SLICE=$slice
        beacon_sleep "$total"
        printf "%s" "$n"
      ' _ "$1" "$2"
  }
  # A 5s terminal wait sliced at 1s must re-touch the beacon 5 times (one per
  # slice). A single loop-top touch (the wedge regression) would count exactly 1.
  count=$(beacon_count 5 1)
  [ "$count" = 5 ] \
    || fail "beacon_sleep 5 with BEACON_SLICE=1 touched the beacon $count time(s), expected 5 (one per slice); a single loop-top touch is the wedge regression"
  # A total that is not a multiple of the slice rounds up: 5 sliced at 2 is 2+2+1.
  count=$(beacon_count 5 2)
  [ "$count" = 3 ] \
    || fail "beacon_sleep 5 with BEACON_SLICE=2 touched $count time(s), expected 3 (2+2+1 slices, rounding up)"
  # A slice at least as large as the total still touches exactly once.
  count=$(beacon_count 3 3)
  [ "$count" = 1 ] \
    || fail "beacon_sleep 3 with BEACON_SLICE=3 touched $count time(s), expected 1 (single slice)"
  pass "beacon_sleep slices the terminal wait and re-touches the beacon every slice (never a single loop-top touch)"
}

# --- non-terminal stale, crew provably working: absorbed, then wedge-escalated ---
# A provably-working crew (an actively-running pipeline) legitimately sits on a
# static pane (e.g. waiting on CI), so a non-terminal stale is absorbed and only
# the wedge timer eventually escalates it - the low-churn behavior preserved.

test_nonterminal_stale_provably_working_absorbed_then_escalated() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-working); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-quiet"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/quiet.meta"
  # Non-terminal status, and prime .seen-* so the signal scan does not pre-empt
  # the stale path.
  printf 'working: still compiling\n' > "$state/quiet.status"
  sig=$(seen_sig "$state/quiet.status"); printf '%s' "$sig" > "$state/.seen-quiet_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The crew's pipeline is actively running: a static pane is normal (waiting on CI).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'

  # Phase A: a high escalation threshold means the first sighting is absorbed.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  # Poll until the watcher processes the stale scan (suppressor advances) rather
  # than checking after a fixed wait, which raced startup. It must stay alive and
  # never surface while absorbing.
  i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "watcher exited for a fresh provably-working non-terminal stale (should absorb): $(cat "$out")"; }
    [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || { reap "$pid"; fail "stale suppressor not advanced on absorb"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "fresh provably-working stale printed a wake reason during absorb"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "fresh provably-working stale enqueued a wake during absorb"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "stale-since escalation timer was not recorded on absorb"; }
  reap "$pid"

  # Phase B: backdate the idle timer past the threshold; the next run escalates.
  # (The subsequent-sight timer path does not re-read the crew state.) The
  # re-prompt sender FAILS, so the first expiry escalates exactly as before.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_STALE_NUDGE_BIN="$fakebin/fm-send.sh" FM_NUDGE_LOG="$dir/nudge.log" \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 200 || fail "watcher did not escalate a provably-working non-terminal stale past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer was not cleared after escalation"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the wedge escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "wedge escalation was not queued"
  pass "provably-working non-terminal stale is absorbed on first sight, then wedge-escalated past the threshold"
}

# --- non-terminal stale, crew NOT provably working: surfaced immediately ------
# The key requirement: a crew with no running pipeline that has gone quiet (and is
# not busy) has stopped - it may be done via interactive menus, waiting, or wedged.
# It must surface at once, never wait out the wedge timer, so these users (a
# non-no-mistakes crew, or any crew with no running pipeline) are never left hanging.

test_nonterminal_stale_not_working_surfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-stopped"
  printf 'idle prompt, finished' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stopped.meta"
  # Non-terminal status (the crew never wrote a captain-relevant verb), .seen-*
  # primed so the signal scan does not pre-empt the stale path.
  printf 'working: implementing\n' > "$state/stopped.status"
  sig=$(seen_sig "$state/stopped.status"); printf '%s' "$sig" > "$state/.seen-stopped_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt, finished")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # No running pipeline; the pane is idle. NOT provably working.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  # The re-prompt sender FAILS (default stub): an undeliverable nudge must fall
  # back to the immediate surface, never swallow the stopped crew.
  nudge_log="$dir/nudge.log"

  # Even with a high wedge threshold, a not-provably-working stale surfaces at once
  # when the first-line nudge cannot be delivered.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_STALE_NUDGE_BIN="$fakebin/fm-send.sh" FM_NUDGE_LOG="$nudge_log" \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 200 || fail "watcher did not surface a not-provably-working non-terminal stale at once"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the immediate stale wake"
  grep -F "possible wedge" "$out" >/dev/null && fail "an immediate stopped-crew stale was mislabeled a wedge"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not advanced on surface"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer should not be set when surfacing immediately"
  [ ! -e "$state/.stale-nudged-$key" ] || fail "a failed nudge must not be recorded as sent"
  grep -F "data/stopped/brief.md" "$nudge_log" >/dev/null || fail "the failed nudge did not attempt delivery to the task brief"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the immediate stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "immediate stale wake was not queued"
  pass "an undeliverable first-line nudge falls back to the immediate stopped-crew surface"
}

# --- first-line stale nudge -------------------------------------------------
# On a stale wake for an ordinary crew task, the watcher sends ONE re-prompt
# via fm-send pointing the worker back at its brief and asking for a status
# append, records it in state/.stale-nudged-<key> so it never repeats for the
# same stall episode, and only escalates the wake to firstmate when the worker
# stays silent past the next grace window (one more STALE_ESCALATE_SECS).
test_nonterminal_stale_not_working_nudged_once_then_escalated() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid nudge_log i
  dir=$(make_case nonterminal-stale-nudge); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"; nudge_log="$dir/nudge.log"
  window="test:fm-nudged"
  printf 'idle prompt, finished' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/nudged.meta"
  # Non-terminal status (the crew never wrote a captain-relevant verb), .seen-*
  # primed so the signal scan does not pre-empt the stale path.
  printf 'working: implementing\n' > "$state/nudged.status"
  sig=$(seen_sig "$state/nudged.status"); printf '%s' "$sig" > "$state/.seen-nudged_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt, finished")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # No running pipeline; the pane is idle. NOT provably working.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  # Phase A: the first sighting of the stopped crew sends ONE re-prompt and
  # absorbs - no wake, no exit, and the next-grace timer is armed.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_STALE_NUDGE_BIN="$fakebin/fm-send.sh" FM_FAKE_NUDGE_OK=1 FM_NUDGE_LOG="$nudge_log" \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "watcher exited for a first-sight stopped crew (should nudge and absorb): $(cat "$out")"; }
    # Wait on the LAST-written marker: nudge_stale_worker records
    # .stale-nudged-$key first, then surface_nonterminal_stale arms the
    # .stale-since-$key timer. Break on .stale-nudged alone races the timer
    # write, so poll until the timer is armed (which implies the nudge marker).
    [ -s "$state/.stale-since-$key" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$state/.stale-nudged-$key" ] || { reap "$pid"; fail "stopped crew was not recorded as nudged"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "stopped crew printed a wake while nudged (absorbed)"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "stopped crew enqueued a wake while nudged (absorbed)"; }
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || { reap "$pid"; fail "stale suppressor not advanced on nudge absorb"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "next-grace timer was not armed on nudge absorb"; }
  [ "$(wc -l < "$nudge_log" 2>/dev/null || echo 0)" = 1 ] || { reap "$pid"; fail "stopped crew was not nudged exactly once"; }
  grep -F "data/nudged/brief.md" "$nudge_log" >/dev/null || { reap "$pid"; fail "nudge did not point back at the task brief"; }
  grep -F "status line" "$nudge_log" >/dev/null || { reap "$pid"; fail "nudge did not ask for a status append"; }
  reap "$pid"

  # Phase B: still silent past the next grace window - escalate once, send no
  # second nudge for the same stall episode.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_STALE_NUDGE_BIN="$fakebin/fm-send.sh" FM_FAKE_NUDGE_OK=1 FM_NUDGE_LOG="$nudge_log" \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 200 || fail "silent stopped crew did not escalate past the next grace window"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  [ -e "$state/.stale-nudged-$key" ] || fail "nudge marker was lost after escalation (still one episode)"
  [ "$(wc -l < "$nudge_log" 2>/dev/null || echo 0)" = 1 ] || fail "a second nudge was sent for the same stall episode"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the nudge escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "nudge escalation was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a stopped ordinary crew is nudged once, then escalates only when it stays silent past the next grace window"
}

test_provably_working_wedge_nudged_once_then_escalated() {
  local dir state fakebin out capture_file window key pane_hash sig pid nudge_log i
  dir=$(make_case wedge-stale-nudge); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; nudge_log="$dir/nudge.log"
  window="test:fm-quiet-nudge"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/quiet-nudge.meta"
  printf 'working: still monitoring ci\n' > "$state/quiet-nudge.status"
  sig=$(seen_sig "$state/quiet-nudge.status"); printf '%s' "$sig" > "$state/.seen-quiet-nudge_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The crew's pipeline is actively running: a static pane is normal (waiting on CI).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Phase A: first sighting absorbs (establishing .stale and the wedge timer)
  # and sends no nudge yet.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_STALE_NUDGE_BIN="$fakebin/fm-send.sh" FM_FAKE_NUDGE_OK=1 FM_NUDGE_LOG="$nudge_log" \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "watcher exited on the wedge priming round (should absorb): $(cat "$out")"; }
    [ -s "$state/.stale-since-$key" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "wedge timer was not armed on the priming round"; }
  [ ! -e "$state/.stale-nudged-$key" ] || { reap "$pid"; fail "priming round sent a nudge before the grace window"; }
  [ ! -s "$nudge_log" ] || { reap "$pid"; fail "priming round sent a nudge before the grace window"; }
  reap "$pid"

  # Phase B: the first wedge-timer expiry sends the one nudge and restarts the
  # timer instead of escalating.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_STALE_NUDGE_BIN="$fakebin/fm-send.sh" FM_FAKE_NUDGE_OK=1 FM_NUDGE_LOG="$nudge_log" \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "watcher exited on the first wedge expiry (should nudge and absorb): $(cat "$out")"; }
    [ -e "$state/.stale-nudged-$key" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$state/.stale-nudged-$key" ] || { reap "$pid"; fail "wedge expiry was not recorded as nudged"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "first wedge expiry printed a wake while nudged (absorbed)"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "first wedge expiry enqueued a wake while nudged (absorbed)"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "wedge nudge did not restart the grace timer"; }
  [ "$(wc -l < "$nudge_log" 2>/dev/null || echo 0)" = 1 ] || { reap "$pid"; fail "wedge expiry was not nudged exactly once"; }
  reap "$pid"

  # Phase C: still silent past the restarted grace window - escalate with the
  # ordinary escalation count, never a second nudge.
  # Reset the escalation counter to the state Phase B is meant to leave behind
  # (a nudge sent, nothing yet escalated). On an overloaded runner the Phase B
  # watcher can outlive its reap and keep polling past the 240s window, letting
  # its own straggler poll escalate and pre-increment .wedge-escalations before
  # Phase C ever starts; clearing it here anchors the first post-nudge escalation
  # at count 1 deterministically without weakening the assertion.
  rm -f "$state/.wedge-escalations-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_STALE_NUDGE_BIN="$fakebin/fm-send.sh" FM_FAKE_NUDGE_OK=1 FM_NUDGE_LOG="$nudge_log" \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 200 || fail "silent provably-working crew did not escalate after the nudge grace window"
  grep -F "escalation 1" "$out" >/dev/null || fail "post-nudge escalation did not carry escalation count 1"
  [ -e "$state/.stale-nudged-$key" ] || fail "nudge marker was lost after the wedge escalation (still one episode)"
  [ "$(wc -l < "$nudge_log" 2>/dev/null || echo 0)" = 1 ] || fail "a second nudge was sent for the same wedge episode"
  unset FM_FAKE_CREW_STATE
  pass "a provably-working wedge is nudged once at the first expiry, then escalates past the restarted grace window"
}

test_stale_nudge_never_sent_to_secondmate_or_unsupervised() {
  local dir state fakebin out log rc sm_key unsup_key ctl_key
  dir=$(make_case stale-nudge-guards); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/helper.out"; log="$dir/nudge.log"
  printf 'window=second:fm-sm\nkind=secondmate\n' > "$state/sm.meta"
  printf 'window=test:fm-unsup\nkind=ship\nsupervise=off\n' > "$state/unsup.meta"
  printf 'window=test:fm-control\nkind=ship\n' > "$state/control.meta"
  sm_key=$(printf '%s' "second:fm-sm" | tr ':/.' '___')
  unsup_key=$(printf '%s' "test:fm-unsup" | tr ':/.' '___')
  ctl_key=$(printf '%s' "test:fm-control" | tr ':/.' '___')

  # A secondmate endpoint is never nudged: its idle pane is healthy by contract.
  rc=$(FM_STATE_OVERRIDE="$state" FM_STALE_NUDGE_BIN="$fakebin/fm-send.sh" \
    FM_FAKE_NUDGE_OK=1 FM_NUDGE_LOG="$log" bash -c \
    '. "$1" >/dev/null 2>&1; nudge_stale_worker "$2"; echo "rc=$?"' _ "$WATCH" "second:fm-sm" 2>/dev/null)
  [ "$rc" = "rc=1" ] || fail "secondmate nudge was not refused (rc=$rc)"
  [ ! -e "$state/.stale-nudged-$sm_key" ] || fail "secondmate nudge marker was written"
  [ ! -s "$log" ] || fail "secondmate nudge was sent"

  # An unsupervised pane (supervise=off) is never nudged.
  rc=$(FM_STATE_OVERRIDE="$state" FM_STALE_NUDGE_BIN="$fakebin/fm-send.sh" \
    FM_FAKE_NUDGE_OK=1 FM_NUDGE_LOG="$log" bash -c \
    '. "$1" >/dev/null 2>&1; nudge_stale_worker "$2"; echo "rc=$?"' _ "$WATCH" "test:fm-unsup" 2>/dev/null)
  [ "$rc" = "rc=1" ] || fail "unsupervised-pane nudge was not refused (rc=$rc)"
  [ ! -e "$state/.stale-nudged-$unsup_key" ] || fail "unsupervised-pane nudge marker was written"
  [ ! -s "$log" ] || fail "unsupervised-pane nudge was sent"

  # Control: an ordinary ship crew IS nudged once, and the marker prevents a
  # repeat for the same stall episode.
  rc=$(FM_STATE_OVERRIDE="$state" FM_STALE_NUDGE_BIN="$fakebin/fm-send.sh" \
    FM_FAKE_NUDGE_OK=1 FM_NUDGE_LOG="$log" bash -c \
    '. "$1" >/dev/null 2>&1; nudge_stale_worker "$2"; echo "rc=$?"' _ "$WATCH" "test:fm-control" 2>/dev/null)
  [ "$rc" = "rc=0" ] || fail "ordinary crew nudge was refused (rc=$rc)"
  [ -e "$state/.stale-nudged-$ctl_key" ] || fail "ordinary crew nudge marker was not written"
  [ "$(wc -l < "$log" 2>/dev/null || echo 0)" = 1 ] || fail "ordinary crew was not nudged exactly once"
  grep -F "control" "$log" >/dev/null || fail "nudge did not target the control task"
  rc=$(FM_STATE_OVERRIDE="$state" FM_STALE_NUDGE_BIN="$fakebin/fm-send.sh" \
    FM_FAKE_NUDGE_OK=1 FM_NUDGE_LOG="$log" bash -c \
    '. "$1" >/dev/null 2>&1; nudge_stale_worker "$2"; echo "rc=$?"' _ "$WATCH" "test:fm-control" 2>/dev/null)
  [ "$rc" = "rc=1" ] || fail "repeat nudge for the same stall episode was not refused (rc=$rc)"
  [ "$(wc -l < "$log" 2>/dev/null || echo 0)" = 1 ] || fail "repeat nudge was sent for the same stall episode"
  pass "secondmates and unsupervised panes are never nudged; an ordinary crew is nudged once per stall episode"
}

# --- non-terminal stale, crew DECLARED a pause: absorbed, re-surfaced on a long
#     cadence, never wedge-escalated ------------------------------------------
# The live 2026-07-09/10 case: a crew intentionally held awaiting an upstream tool
# release (paused: ...) whose idle pane tripped repeated possible-wedge escalations
# all day. With the paused verb, its stale is absorbed like a working crew but never
# uses the wedge timer; it re-surfaces once past PAUSE_RESURFACE_SECS (anchored on
# the pause's own status-file age, so a churny idle pane cannot reset the cadence)
# for a recheck, so a forgotten pause cannot rot invisibly.
test_nonterminal_stale_paused_absorbed_then_resurfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid back statusf
  dir=$(make_case nonterminal-stale-paused); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-held"
  printf 'idle, holding for upstream' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/held.meta"
  statusf="$state/held.status"
  # A DECLARED pause (not captain-relevant), .seen-* primed so the signal scan does
  # not pre-empt the stale path.
  printf 'paused: holding for the upstream tool release\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle, holding for upstream")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # crew_absorb_class reads the declared pause from fm-crew-state.sh.
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · holding for the upstream tool release'

  # Phase A: a fresh pause (status file just written) under a high re-surface
  # threshold is absorbed - no wake, no wedge timer.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  # Poll until the paused absorb has recorded its state (.paused-$key set and the
  # stale suppressor advanced to this hash), rather than asserting after a fixed
  # liveness window that can return before the watcher's first stale-scan finishes
  # under load. The watcher must stay alive throughout (absorb path).
  i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "watcher exited for a fresh declared pause (should absorb): $(cat "$out")"; }
    [ -e "$state/.paused-$key" ] && [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ ! -s "$out" ] || fail "fresh paused stale printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "fresh paused stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on paused absorb"
  [ -e "$state/.paused-$key" ] || fail "paused flag not recorded on absorb"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused absorb must not start the wedge timer"
  reap "$pid"

  # Phase B: age the pause past the (now normal) threshold by backdating its
  # status file, re-prime .seen-* to the new signature so the signal scan stays
  # quiet, and confirm it re-surfaces as a paused recheck - never a wedge.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  : > "$out"
  printf 'idle, holding for upstream (token 2)' > "$capture_file"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 200 || fail "watcher did not re-surface a declared pause past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "re-surface did not print a stale wake"
  grep -F "awaiting external" "$out" >/dev/null || fail "re-surface was not labeled a paused/awaiting-external recheck"
  grep -F "possible wedge" "$out" >/dev/null && fail "a declared pause was mislabeled a possible wedge"
  [ -e "$state/.paused-resurfaced-$key" ] || fail "the paused re-surface throttle marker was not recorded"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused re-surface must not use the wedge timer"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the paused re-surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "paused re-surface was not queued"
  pass "a declared pause is absorbed on first sight, then re-surfaced as a recheck past the threshold, never wedge-escalated"
}

# A captain-held crew can leave a stable backend endpoint after its agent exits.
# fm-crew-state then authoritatively reports stopped rather than paused, but the
# confirmed-dead agent plus the declared wait or captain-held transfer must retain
# bounded pause handling.
# A still-live agent at an external-decision gate is the disconfirming case: it
# must surface once, while the unchanged hash must not append the same wake on
# every watcher re-arm.
test_exited_declared_pause_is_bounded_but_live_gate_surfaces() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back round wakes bare
  dir=$(make_case exited-declared-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window="test:fm-held"
  printf 'idle bare shell after agent exit\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'paused: held per captain while an external decision is pending\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle bare shell after agent exit")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  # Round 1 is the ONE bounded pause recheck: the pane's declared-pause status is
  # already older than PAUSE_RESURFACE_SECS, so the first poll surfaces exactly
  # once and exits. Wait for that exit with a generous ceiling rather than a short
  # reap window. The earlier version reaped every round at a 1.5s ceiling, which
  # under host load killed this first watcher mid-poll BEFORE it wrote the wake -
  # then no round ever created state/.wake-queue, and the awk count below opened a
  # missing file and yielded an empty string, so `[ "" -le 1 ]` failed with
  # "integer expression expected" (surfacing as the blank "flooded  stale wakes").
  # wait_for_exit makes the surface deterministic instead of a race.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  wait_for_exit "$pid" 200 || { reap "$pid"; fail "dead-agent declared pause did not surface its one bounded recheck"; }
  # Rounds 2-6: with the resurface marker now set, every further poll of the same
  # unchanged pane must ABSORB (stay alive, append no new wake) until the long
  # PAUSE_RESURFACE_SECS cadence elapses. The re-surface throttle is anchored on
  # the marker mtime written in round 1, which is WALL-CLOCK: with the round-1
  # window (240s) these rounds would falsely re-surface on a slow host whose
  # rounds 2-6 happen to span more than 240s of real time (the CI flood seen as
  # "flooded 2 stale wakes"). Use a window far larger than any plausible host load
  # here so the absorb decision is deterministic; round 1 already fired with its
  # own 240s window against a 500s-old status, so this only governs re-surface.
  # A watcher that DIES here surfaced a second wake and is a real flood regression.
  round=2
  while [ "$round" -le 6 ]; do
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=86400 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
    pid=$!
    wait_live "$pid" 15 || { wait "$pid" 2>/dev/null; fail "dead-agent declared pause re-surfaced on poll $round (should absorb on the bounded cadence, not flood)"; }
    reap "$pid"
    round=$((round + 1))
  done
  # Defensive: treat a missing queue as zero rather than letting awk error on an
  # absent file leave an empty (non-integer) count. Round 1's asserted exit means
  # the queue exists on the happy path, so this only clarifies a genuine failure.
  [ -e "$state/.wake-queue" ] || fail "dead-agent declared pause wrote no wake at all (expected exactly one bounded recheck)"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue")
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.wake-queue")
  [ "$wakes" -le 1 ] || fail "dead-agent declared pause flooded $wakes stale wakes across six unchanged polls"
  [ "$bare" -eq 0 ] || fail "dead-agent declared pause surfaced as $bare bare stopped-crew wakes"
  grep -F "awaiting external" "$state/.wake-queue" >/dev/null \
    || fail "dead-agent declared pause did not use the bounded paused recheck"

  dir=$(make_case exited-captain-held); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window="test:fm-held"
  printf 'idle bare shell after captain-held transfer\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'captain-held [key=route]: tracked by held-decision-route\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle bare shell after captain-held transfer")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 200 || fail "captain-held dead-agent pane did not re-surface on the bounded cadence"
  grep -F "awaiting external" "$state/.wake-queue" >/dev/null \
    || fail "captain-held dead-agent pane surfaced as a stopped crew"

  dir=$(make_case alive-decision-gate); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/gate.status"
  window="test:fm-gate"
  printf 'idle external-decision gate\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/gate.meta"
  printf 'paused: waiting at an active external-decision gate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-gate_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle external-decision gate")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  # First sight must surface promptly so a live external-decision gate is not
  # hidden behind the pause cadence. The sender WOULD succeed here; a declared
  # pause must still never be nudged.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting at an active external-decision gate' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_STALE_NUDGE_BIN="$fakebin/fm-send.sh" FM_FAKE_NUDGE_OK=1 FM_NUDGE_LOG="$dir/nudge.log" \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  wait_for_exit "$pid" 200 || fail "live external-decision gate did not surface immediately"

  # Re-arm with the stale timer already beyond the wedge threshold. This is the
  # exact unchanged-hash fallback after the immediate surface: it must retain
  # the pause cadence and discard any residual wedge timer instead of emitting
  # a second possible-wedge wake.
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting at an active external-decision gate' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_STALE_NUDGE_BIN="$fakebin/fm-send.sh" FM_FAKE_NUDGE_OK=1 FM_NUDGE_LOG="$dir/nudge.log" \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  # Poll until the re-armed watcher reconciles the live external-decision gate back
  # onto the pause cadence (pause marker retained, residual wedge timer discarded),
  # instead of asserting immediately after a fixed wait_live window that can return
  # before the first poll cycle completes under load. The watcher must stay alive
  # throughout: a death here means it wrongly wedge-escalated, the real regression.
  i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "live external-decision gate escalated on the wedge timer after its immediate surface: $(cat "$out")"; }
    [ -e "$state/.paused-$key" ] && [ ! -e "$state/.stale-since-$key" ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "live external-decision gate lost its pause cadence marker"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "live external-decision gate retained the wedge timer"; }
  reap "$pid"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue")
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.wake-queue")
  [ "$wakes" -eq 1 ] || fail "live external-decision gate should surface once, got $wakes wakes"
  [ "$bare" -eq 1 ] || fail "live external-decision gate lost its immediate bare stale surface"
  [ ! -s "$dir/nudge.log" ] || fail "live external-decision gate was nudged despite its declared pause"
  pass "exited declared-pause and captain-held panes use bounded pause cadence while a live decision gate still surfaces once, never nudged"
}

test_secondmate_paused_resurfaces_in_normal_mode() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back
  dir=$(make_case secondmate-paused-resurface); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-held.status"
  window="test:fm-secondmate-held"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-held.meta"
  printf 'paused: awaiting the upstream release\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-held_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream release'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 200 || fail "watcher did not re-surface a paused secondmate"
  grep -F "stale: $window" "$out" >/dev/null || fail "paused secondmate did not emit a stale recheck"
  grep -F "awaiting external" "$out" >/dev/null || fail "paused secondmate recheck omitted its external-wait reason"
  grep -F "possible wedge" "$out" >/dev/null && fail "paused secondmate was mislabeled a wedge"
  unset FM_FAKE_CREW_STATE
  pass "a declared paused secondmate re-surfaces on the bounded normal-mode cadence"
}

test_secondmate_nonpaused_stale_remains_suppressed() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid
  dir=$(make_case secondmate-stale-suppressed); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-working.status"
  window="test:fm-secondmate-working"
  printf 'idle while the parent supervises\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-working.meta"
  printf 'working: the parent supervises this secondmate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-working_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle while the parent supervises")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher surfaced an ordinary secondmate stale pane: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "ordinary secondmate stale pane printed a wake reason: $(cat "$out")"; }
  reap "$pid"
  pass "a non-paused secondmate retains normal stale suppression"
}

test_secondmate_unpause_clears_pause_tracking() {
  local dir state fakebin out statusf window key pid
  dir=$(make_case secondmate-unpause-clears); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; statusf="$state/secondmate-resumed.status"; window="test:fm-secondmate-resumed"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-resumed.meta"
  printf 'working: upstream landed\n' > "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-secondmate-resumed_status"
  key=${window//:/_}
  key=${key//\//_}
  key=${key//./_}
  : > "$state/.paused-$key"
  : > "$state/.paused-rechecked-$key"
  : > "$state/.paused-resurfaced-$key"
  : > "$state/.stale-$key"
  : > "$state/.stale-since-$key"
  : > "$state/.wedge-escalations-$key"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  # Poll until the resumed secondmate's pause tracking is reconciled away, rather
  # than asserting it immediately after a fixed wait_live window: the clearing
  # happens on the watcher's first poll cycle, which under heavy host load takes
  # longer than a couple of seconds, so a fixed 2s window raced the reconcile and
  # flaked with no watcher defect. The watcher must STAY alive throughout (this is
  # an absorb path); a death is the real regression and fails immediately.
  i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "watcher exited while reconciling a resumed secondmate: $(cat "$out")"; }
    [ ! -e "$state/.paused-$key" ] && [ ! -e "$state/.stale-$key" ] && [ ! -e "$state/.wedge-escalations-$key" ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "resumed secondmate retained the pause marker"; }
  [ ! -e "$state/.stale-$key" ] || { reap "$pid"; fail "resumed secondmate retained stale tracking"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "resumed secondmate retained wedge tracking"; }
  reap "$pid"
  pass "a resumed secondmate clears pause and stale tracking before stale exemption"
}

test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash() {
  local dir state fakebin out capture_file window key pane_hash sig pid i
  dir=$(make_case nonterminal-stale-pause-transition); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-transition"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/transition.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/transition.status"
  sig=$(seen_sig "$state/transition.status"); printf '%s' "$sig" > "$state/.seen-transition_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream release'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    [ -e "$state/.paused-$key" ] && [ ! -e "$state/.stale-since-$key" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "a stale hash that entered pause was wedge-escalated: $(cat "$out")"; }
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "unchanged stale hash did not enter paused mode"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "pause transition retained its wedge timer"; }
  wait_live "$pid" 30 || { reap "$pid"; fail "a stale hash that entered pause was wedge-escalated: $(cat "$out")"; }
  reap "$pid"

  printf 'working: upstream landed, resuming\n' > "$state/transition.status"
  sig=$(seen_sig "$state/transition.status"); printf '%s' "$sig" > "$state/.seen-transition_status"
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    [ ! -e "$state/.paused-$key" ] && [ -s "$state/.stale-since-$key" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "a stale hash that left pause did not resume wedge tracking: $(cat "$out")"; }
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "unchanged stale hash retained paused mode after resume"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "unchanged stale hash did not restart wedge tracking after resume"; }
  wait_live "$pid" 30 || { reap "$pid"; fail "a stale hash that left pause did not resume wedge tracking: $(cat "$out")"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "unchanged stale hashes reclassify when a crew enters or leaves pause"
}

test_nonterminal_paused_rechecks_authoritative_state() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-paused-recheck); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-pause-recheck"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/pause-recheck.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/pause-recheck.status"
  sig=$(seen_sig "$state/pause-recheck.status"); printf '%s' "$sig" > "$state/.seen-pause-recheck_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  # Poll until the declared pause is reconciled against the authoritative active
  # run (pause cleared, wedge timer resumed), rather than asserting immediately
  # after a fixed wait_live window that can return before the watcher's first poll
  # cycle finishes under load. The watcher must stay alive throughout (absorb path).
  i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "an active run behind a declared pause surfaced instead of resuming wedge tracking: $(cat "$out")"; }
    [ ! -e "$state/.paused-$key" ] && [ -s "$state/.stale-since-$key" ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "authoritative active run retained paused mode"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "authoritative active run did not resume wedge tracking"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a declared pause is periodically rechecked against authoritative active-run state"
}

test_paused_authoritative_working_preserves_wedge_timer() {
  local dir state fakebin out capture_file window key pane_hash sig pid since
  dir=$(make_case paused-working-preserves-wedge-timer); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-paused-working"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/paused-working.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/paused-working.status"
  sig=$(seen_sig "$state/paused-working.status"); printf '%s' "$sig" > "$state/.seen-paused-working_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 200 || { reap "$pid"; fail "authoritative working state did not start wedge tracking"; }
  since=$(cat "$state/.stale-since-$key")
  sleep 2
  [ "$(cat "$state/.stale-since-$key" 2>/dev/null || true)" = "$since" ] \
    || { reap "$pid"; fail "repeat authoritative working recheck reset the wedge timer"; }
  reap "$pid"

  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_STALE_NUDGE_BIN="$fakebin/fm-send.sh" FM_NUDGE_LOG="$dir/nudge.log" \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 200 || fail "authoritative working state did not wedge-escalate past the threshold"
  grep -F "possible wedge" "$out" >/dev/null || fail "authoritative working wedge escalation omitted its reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "wedge timer remained after authoritative working escalation"
  unset FM_FAKE_CREW_STATE
  pass "a paused status overridden by authoritative working preserves its wedge timer and escalates"
}

# --- consecutive wedge escalations on the same pane demand deep inspection ----
# Root cause of the PR #252 incident's ~20 minutes of unnoticed green: each
# wedge escalation fires, gets classified as "still validating" one poll later
# (the timer restarts, see wedge_timer_check), and repeats forever on a pane
# that never changes. A single escalation reason looks identical every round,
# so nothing in the payload itself signals "this has now happened N times in a
# row" - that judgment call was left entirely to the supervisor noticing the
# repetition on its own. This is the safety-net fix: past
# FM_WEDGE_DEMAND_INSPECT_COUNT consecutive escalations on the SAME pane, the
# wake reason itself carries a "demand-deep-inspection" marker.

test_wedge_escalation_marks_demand_deep_inspection_after_threshold() {
  local dir state fakebin out capture_file window key pane_hash sig pid n
  dir=$(make_case wedge-escalation); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedged"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedged.meta"
  printf 'working: still monitoring ci\n' > "$state/wedged.status"
  sig=$(seen_sig "$state/wedged.status"); printf '%s' "$sig" > "$state/.seen-wedged_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The crew's pipeline is actively running: a static pane is normal (waiting on CI).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Priming round: first sighting of this stale hash classifies and absorbs it
  # (establishing .stale-$key and starting the wedge timer) without going
  # through wedge_timer_check at all - mirrors the existing wedge tests' Phase A.
  # Poll until the wedge timer (.stale-since-$key) is actually established rather
  # than reaping after a fixed liveness window: establishing it needs the watcher
  # to see the same stale hash across two polls, which under load takes longer than
  # a couple of seconds. Reaping too early left the timer unset, so round 1 below
  # had nothing to escalate.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "watcher exited on the priming round (should absorb): $(cat "$out")"; }
    [ -s "$state/.stale-since-$key" ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "priming round did not establish the wedge timer: $(cat "$out")"; }
  reap "$pid"
  n=1
  # The re-prompt sender FAILS on every round, so each expiry escalates exactly
  # as before and the consecutive-escalation counting is unchanged.
  while [ "$n" -le 3 ]; do
    # Backdate the wedge timer past the threshold before each round, mirroring
    # the existing wedge-escalation tests' Phase B (the subsequent-sight timer
    # path does not re-read the crew state).
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_STALE_NUDGE_BIN="$fakebin/fm-send.sh" FM_NUDGE_LOG="$dir/nudge.log" \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 200 || fail "watcher did not escalate on consecutive wedge round $n: $(cat "$out")"
    grep -F "escalation $n" "$out" >/dev/null || fail "round $n did not report escalation count $n: $(cat "$out")"
    if [ "$n" -lt 3 ]; then
      grep -F "demand-deep-inspection" "$out" >/dev/null && fail "round $n escalated to demand-deep-inspection before the threshold: $(cat "$out")"
    else
      grep -F "demand-deep-inspection" "$out" >/dev/null || fail "round $n (threshold) did not demand deep inspection: $(cat "$out")"
    fi
    n=$((n + 1))
  done
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 3 ] || fail "escalation counter did not persist across consecutive rounds"
  unset FM_FAKE_CREW_STATE
  pass "consecutive wedge escalations on the same pane accumulate and demand deep inspection at the threshold"
}

test_wedge_escalation_resets_when_pane_becomes_active() {
  local dir state fakebin out capture_file window key pane_hash sig pid i
  dir=$(make_case wedge-escalation-reset); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedged-reset"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedged-reset.meta"
  printf 'working: still monitoring ci\n' > "$state/wedged-reset.status"
  sig=$(seen_sig "$state/wedged-reset.status"); printf '%s' "$sig" > "$state/.seen-wedged-reset_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Pre-seed one escalation as if a prior wedge round already fired, plus the
  # stale-nudge marker of the same episode.
  printf '1\n' > "$state/.wedge-escalations-$key"
  : > "$state/.stale-nudged-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # The pane content changes (the crew is active again): the hash no longer
  # matches, so the watcher resets escalation bookkeeping instead of escalating.
  printf 'new output, crew active again' > "$capture_file"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  # Poll until the watcher's first cycle reconciles the changed pane hash
  # (escalation counter and nudge marker cleared), rather than asserting after a
  # fixed 3s wait_live window: under heavy host load the first cycle (sleep POLL
  # + signal-coalesce linger + scan) can outlast 3s, so a fixed wait raced the
  # reconcile and flaked with no watcher defect. The watcher must stay alive
  # throughout (this is an absorb path); a death is the real regression.
  i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "watcher exited on a fresh (changed) pane hash: $(cat "$out")"; }
    [ ! -e "$state/.wedge-escalations-$key" ] && [ ! -e "$state/.stale-nudged-$key" ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a changed pane hash did not reset the wedge-escalation counter"
  [ ! -e "$state/.stale-nudged-$key" ] || fail "a changed pane hash did not reset the stale-nudge marker"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a pane becoming active again resets the consecutive wedge-escalation counter and the nudge marker"
}

test_nonterminal_stale_repairs_missing_or_corrupt_timer() {
  local dir state fakebin out capture_file window key pane_hash sig pid since
  dir=$(make_case nonterminal-stale-timer-repair); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-quiet-timer"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/quiet-timer.meta"
  printf 'working: still compiling\n' > "$state/quiet-timer.status"
  sig=$(seen_sig "$state/quiet-timer.status"); printf '%s' "$sig" > "$state/.seen-quiet-timer_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 200 || { reap "$pid"; fail "matching stale suppressor with missing timer did not initialize stale-since"; }
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    fail "watcher exited while repairing a missing stale-since timer: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "missing stale-since repair enqueued a wake"; }
  reap "$pid"

  printf 'corrupt\n' > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 200 || { reap "$pid"; fail "matching stale suppressor with corrupt timer did not repair stale-since"; }
  since=$(cat "$state/.stale-since-$key" 2>/dev/null || true)
  [ "$since" != "corrupt" ] || { reap "$pid"; fail "corrupt stale-since value was left in place"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "corrupt stale-since repair enqueued a wake"; }
  reap "$pid"
  pass "matching non-terminal stale suppressors repair missing or corrupt stale-since timers"
}

# --- triage debug log stays size capped -------------------------------------

test_triage_log_size_cap_accepts_spaced_wc_counts() {
  local dir state fakebin out status_file pid lines i
  dir=$(make_case triage-log-spaced-wc); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  i=1
  while [ "$i" -le 3000 ]; do
    printf 'old line %04d\n' "$i" >> "$state/.watch-triage.log"
    i=$((i + 1))
  done
  cat > "$fakebin/wc" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "-c" ]; then
  printf '   999999\n'
  exit 0
fi
exit 127
SH
  chmod +x "$fakebin/wc"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # Provably working so the no-verb signal is absorbed (which is what writes the
  # triage log line under test).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_TRIAGE_LOG_MAX_BYTES=1 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a benign signal while testing log capping: $(cat "$out")"
  fi
  i=0
  while [ "$i" -lt 200 ]; do
    lines=$(awk 'END { print NR + 0 }' "$state/.watch-triage.log")
    [ "$lines" -le 2000 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$lines" -le 2000 ] || { reap "$pid"; fail "triage log was not capped when wc emitted a spaced byte count (lines=$lines)"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "benign signal enqueued a wake while testing log capping"; }
  reap "$pid"
  pass "triage log capping handles wc byte counts with leading spaces"
}

# --- heartbeat: no-change absorbed, backstop surfaces a missed status --------

test_heartbeat_no_change_absorbed() {
  local dir state fakebin out pid
  dir=$(make_case heartbeat-absorb); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  # A truly quiet fleet (no windows, no statuses) with a fast heartbeat cadence.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  # Poll until the heartbeat has been absorbed at least once (its backoff streak
  # advances), rather than asserting after a fixed liveness window that can return
  # before the first heartbeat fires under load. The watcher must stay alive
  # throughout (a no-change heartbeat is absorbed, never surfaced).
  i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "watcher exited for a no-change heartbeat (should absorb): $(cat "$out")"; }
    [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ ! -s "$out" ] || fail "no-change heartbeat printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "no-change heartbeat enqueued a durable wake record"
  [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] || fail "heartbeat backoff streak did not advance while absorbing"
  reap "$pid"
  pass "a heartbeat with no captain-relevant change is absorbed and backs off the cadence"
}

test_heartbeat_backstop_surfaces_unsurfaced_status() {
  local dir state fakebin out drain_out sig pid
  dir=$(make_case heartbeat-backstop); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  # A captain-relevant status whose .seen-* signature ALREADY matches (so the
  # per-poll signal scan stays quiet) but which was never surfaced (no
  # .hb-surfaced-* marker). This stands in for a per-wake-path miss; the heartbeat
  # fleet-scan backstop must catch it and wake firstmate.
  printf 'done: PR https://example.test/pr/5\n' > "$state/miss.status"
  sig=$(seen_sig "$state/miss.status"); printf '%s' "$sig" > "$state/.seen-miss_status"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 200 || fail "heartbeat backstop did not surface an unsurfaced captain-relevant status"
  grep -Fx "heartbeat" "$out" >/dev/null || fail "backstop did not exit with a heartbeat wake"
  [ "$(cat "$state/.hb-surfaced-miss" 2>/dev/null || true)" = "done: PR https://example.test/pr/5" ] \
    || fail "backstop did not record the status as surfaced (would re-fire next heartbeat)"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the backstop heartbeat failed"
  grep "$(printf '\theartbeat\t')" "$drain_out" >/dev/null || fail "backstop heartbeat was not queued"
  pass "heartbeat backstop fail-safe surfaces a captain-relevant status the per-wake path missed"
}

# --- beacon stays fresh while absorbing -------------------------------------

test_beacon_stays_fresh_while_absorbing() {
  local dir state fakebin out status_file pid m1 m2 now
  dir=$(make_case beacon-fresh); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: a\n' > "$status_file"
  # Provably working so the working: notes are absorbed (the path that must keep the
  # beacon fresh).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_live "$pid" 15 || { reap "$pid"; fail "watcher exited while absorbing the first benign signal"; }
  # Wait for the beacon file to actually exist before reading it: under load the
  # watcher may not have completed its first touch within the short liveness window
  # above, and reading too early left m1 empty (a false "beacon missing" failure).
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$state/.last-watcher-beat" ]; do
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "watcher exited while absorbing the first benign signal"; }
    sleep 0.1; i=$((i + 1))
  done
  m1=$(file_mtime "$state/.last-watcher-beat")
  # A second benign signal keeps it absorbing; the beacon must keep advancing.
  printf 'working: b\n' >> "$status_file"
  wait_live "$pid" 20 || { reap "$pid"; fail "watcher exited while absorbing a second benign signal"; }
  m2=$(file_mtime "$state/.last-watcher-beat")
  now=$(date +%s)
  if [ -z "$m1" ] || [ -z "$m2" ]; then
    reap "$pid"
    fail "watcher beacon missing while absorbing"
  fi
  [ "$m2" -ge "$m1" ] || { reap "$pid"; fail "beacon mtime regressed while absorbing"; }
  # The beacon must be fresher than the guard grace. Read the effective grace from
  # the same source the watcher uses rather than a hardcoded 10s: on a heavily
  # loaded host a healthy watcher's slice can legitimately exceed a tight literal
  # bound, and the real liveness contract is "within the grace", not "within 10s".
  fresh_bound=${FM_GUARD_GRACE:-900}
  [ "$(( now - m2 ))" -lt "$fresh_bound" ] || { reap "$pid"; fail "beacon went stale while absorbing (age $(( now - m2 ))s >= grace ${fresh_bound}s)"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "absorbing benign signals enqueued a wake"; }
  reap "$pid"
  pass "the liveness beacon stays fresh while the watcher absorbs benign wakes (fm-guard never false-alarms)"
}

# --- afk coherence: a LIVE daemon owns triage; the watcher does not double-triage ---
#
# Away mode alone is only the away posture. Ownership moves to the daemon exactly
# while one is actually live for this home, so these cases record a real live
# daemon lock; the daemon-free case below asserts the watcher keeps its own triage.

# start_fake_afk_daemon <state>: hold this home's away-mode daemon lock with a
# real live process and print its pid. The identity file is what
# fm_afk_daemon_alive matches, so the holder need not be the daemon script itself.
start_fake_afk_daemon() {
  local state=$1 pid identity
  sleep 120 >/dev/null 2>&1 &
  pid=$!
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-pid-lib.sh" "$pid") || {
    kill "$pid" 2>/dev/null || true
    return 1
  }
  mkdir -p "$state/.supervise-daemon.lock"
  printf '%s\n' "$pid" > "$state/.supervise-daemon.lock/pid"
  printf '%s\n' "$identity" > "$state/.supervise-daemon.lock/pid-identity"
  printf '%s\n' "$pid"
}

test_afk_present_reverts_watcher_to_one_shot() {
  local dir state fakebin out drain_out status_file pid daemon_pid
  dir=$(make_case afk-coherence); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: routine note\n' > "$status_file"
  date '+%s' > "$state/.afk"   # away mode: the supervise-daemon owns triage
  daemon_pid=$(start_fake_afk_daemon "$state") || fail "could not hold the away-mode daemon lock"
  # Set a PROVABLY-WORKING verdict: if afk failed to bypass the provably-working
  # check, this no-verb signal would be absorbed (not surfaced). The test asserting
  # a surface therefore also proves afk reverts to one-shot and skips the costly read.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 200 || { kill "$daemon_pid" 2>/dev/null; fail "with a live daemon the watcher did not exit one-shot for a benign signal"; }
  kill "$daemon_pid" 2>/dev/null || true
  grep -F "signal: $status_file" "$out" >/dev/null || fail "afk-mode watcher did not surface the signal for the daemon"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the afk-mode signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "afk-mode benign signal was not queued for the daemon to classify"
  pass "with a live away-mode daemon the watcher reverts to one-shot so the daemon owns triage (no double-triage)"
}

# The mirror case: away mode on, no daemon anywhere. Nothing would ever pick a
# one-shot wake up, so the watcher must keep its own normal triage and absorb the
# same benign signal the case above hands off.
test_afk_without_daemon_keeps_normal_triage() {
  local dir state fakebin out status_file pid
  dir=$(make_case afk-no-daemon); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: routine note\n' > "$status_file"
  date '+%s' > "$state/.afk"   # away POSTURE only: no daemon lock is recorded
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  # Poll until the benign signal has been absorbed (its .seen-* suppressor
  # advances), rather than asserting after a fixed liveness window that can return
  # before the watcher's first signal-scan finishes under load. The watcher must
  # stay alive throughout (daemon-free away mode keeps its own triage and absorbs).
  i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "away mode without a daemon surfaced a benign signal instead of absorbing it: $(cat "$out")"; }
    [ -s "$state/.seen-task_status" ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ ! -s "$out" ] || fail "daemon-free away mode printed a wake reason for a benign signal: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "daemon-free away mode enqueued a benign signal for a daemon that never runs"
  [ -s "$state/.seen-task_status" ] || fail "daemon-free away mode did not advance its .seen-* suppressor"
  [ -e "$state/.last-watcher-beat" ] || fail "watcher beacon was not touched while absorbing in daemon-free away mode"
  reap "$pid"
  pass "with away mode on and no live daemon the watcher keeps its own triage and absorbs benign wakes"
}

# A dead daemon lock is not ownership either: the same benign signal is absorbed.
test_afk_with_dead_daemon_lock_keeps_normal_triage() {
  local dir state fakebin out status_file pid dead
  dir=$(make_case afk-dead-daemon); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: routine note\n' > "$status_file"
  date '+%s' > "$state/.afk"
  dead=$(start_fake_afk_daemon "$state") || fail "could not hold the away-mode daemon lock"
  kill "$dead" 2>/dev/null || true
  wait_gone "$dead" 40 || fail "the killed away-mode daemon lock holder never left the process table"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "a dead daemon lock surfaced a benign signal instead of absorbing it: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "a dead daemon lock enqueued a benign signal for a daemon that is gone"
  reap "$pid"
  pass "a dead away-mode daemon lock never transfers triage; the watcher keeps absorbing benign wakes"
}

# A paused pane can first appear as a changed hash. In AFK mode that initial path
# must still hand off the plain window identity to the daemon, rather than running
# the normal-mode pause re-surface and decorating the stale identity.
test_afk_paused_changed_pane_hands_off_plain_stale() {
  local dir state fakebin out drain_out capture_file statusf window key sig pid back daemon_pid
  dir=$(make_case afk-paused-changed-pane); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-afk-held"
  printf 'idle, awaiting upstream\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/afk-held.meta"
  statusf="$state/afk-held.status"
  printf 'paused: awaiting the upstream tool release\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-afk-held_status"
  date '+%s' > "$state/.afk"
  daemon_pid=$(start_fake_afk_daemon "$state") || fail "could not hold the away-mode daemon lock"
  key=$(printf '%s' "$window" | tr '.:/' '___')

  # Deliberately do not seed .hash-*: this is the changed-pane path that used to
  # call handle_paused_stale before AFK's one-shot daemon handoff.
  # Integer-only cadence: a fractional FM_POLL falls back to 300s (fm-cadence-lib.sh).
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream tool release' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 300 || { kill "$daemon_pid" 2>/dev/null; fail "AFK paused changed pane did not hand off a stale wake"; }
  kill "$daemon_pid" 2>/dev/null || true
  grep -Fx "stale: $window" "$out" >/dev/null || fail "AFK paused stale did not preserve its plain window identity: $(cat "$out")"
  grep -F "awaiting external" "$out" >/dev/null && fail "AFK watcher decorated a stale identity instead of handing it to the daemon"
  [ ! -e "$state/.paused-$key" ] || fail "AFK watcher recorded normal-mode pause tracking instead of handing off"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after AFK paused stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "stale: $window" >/dev/null \
    || fail "AFK paused stale was not queued with the plain window identity"
  pass "AFK changed paused panes hand off plain stale identities for daemon-owned pause triage"
}

# --- secondmate context-handoff monitor (secondmate_context_sweep) -----------
# The slow-poll context monitor wakes firstmate once with a check: wake when a
# live secondmate's context crosses the threshold, and stays quiet otherwise.

# Write a claude transcript under CLAUDE_CONFIG_DIR for <home> whose last
# main-thread usage sums to <tokens>.
write_sm_transcript() {  # <config-dir> <home> <tokens>
  local config=$1 home=$2 tokens=$3 dir
  dir="$config/projects/$(printf '%s' "$home" | tr '/.' '--')"
  mkdir -p "$dir"
  printf '{"type":"assistant","message":{"usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' \
    "$tokens" > "$dir/s.jsonl"
}

test_secondmate_over_context_threshold_surfaced() {
  local dir state fakebin out drain_out config home pid
  dir=$(make_case sm-context-over); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  config="$dir/claude"; home="$dir/sm-home"; mkdir -p "$home/data"
  fm_write_meta "$state/pricing.meta" "window=test:fm-pricing" "kind=secondmate" "harness=claude" "home=$home"
  write_sm_transcript "$config" "$home" 260000
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 CLAUDE_CONFIG_DIR="$config" "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 200 || fail "watcher did not surface a secondmate over its context threshold: $(cat "$out")"
  grep -F "secondmate-context pricing" "$out" >/dev/null || fail "watcher did not print the context wake reason: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the context wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "secondmate-context-pricing" >/dev/null \
    || fail "context crossing was not queued as a check wake"
  [ -e "$state/.sm-context-surfaced-test_fm-pricing" ] || fail "context crossing did not record its surfaced marker"
  pass "a secondmate over its context threshold is surfaced once as a check wake"
}

test_secondmate_under_context_threshold_absorbed() {
  local dir state fakebin out config home pid
  dir=$(make_case sm-context-under); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  config="$dir/claude"; home="$dir/sm-home"; mkdir -p "$home/data"
  fm_write_meta "$state/pricing.meta" "window=test:fm-pricing" "kind=secondmate" "harness=claude" "home=$home"
  # Pre-arm a surfaced marker; an under-threshold read must clear it (re-arm) and never wake.
  : > "$state/.sm-context-surfaced-test_fm-pricing"
  write_sm_transcript "$config" "$home" 50000
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 CLAUDE_CONFIG_DIR="$config" "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 20; then
    reap "$pid"; fail "watcher exited for a secondmate under its context threshold (should stay quiet): $(cat "$out")"
  fi
  grep -F "secondmate-context" "$out" >/dev/null && { reap "$pid"; fail "under-threshold secondmate printed a context wake"; }
  [ ! -e "$state/.sm-context-surfaced-test_fm-pricing" ] || { reap "$pid"; fail "under-threshold read did not re-arm (clear) the surfaced marker"; }
  reap "$pid"
  pass "a secondmate under its context threshold is not surfaced and its marker re-arms"
}

test_secondmate_unknown_context_fails_closed() {
  local dir state fakebin out config home pid
  dir=$(make_case sm-context-unknown); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  config="$dir/claude"; home="$dir/sm-home"; mkdir -p "$home/data"
  # codex harness: no verified read -> unknown -> must never wake (fail closed),
  # even though a transcript exists at the claude path.
  fm_write_meta "$state/pricing.meta" "window=test:fm-pricing" "kind=secondmate" "harness=codex" "home=$home"
  write_sm_transcript "$config" "$home" 260000
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 CLAUDE_CONFIG_DIR="$config" "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 20; then
    reap "$pid"; fail "watcher exited on an unreadable secondmate context (should fail closed): $(cat "$out")"
  fi
  grep -F "secondmate-context" "$out" >/dev/null && { reap "$pid"; fail "an unreadable context triggered a wake instead of failing closed"; }
  reap "$pid"
  pass "an unreadable (non-claude) secondmate context never wakes (fails closed)"
}

# --- FM_WATCH_ABSORB_TICK proof-of-life tick ---------------------------------
# Default OFF: a benign-absorbed wake stays silent and blocking (byte-identical).
# ON: a benign-absorbed wake ends the cycle with a distinguishable "tick:" line and
# no durable wake record; actionable wakes are unchanged.

test_absorb_tick_off_is_silent() {
  local dir state fakebin out pid
  dir=$(make_case absorb-tick-off); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  printf 'working: compiling step 2\n' > "$state/task.status"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  # Knob unset (default off): the provably-working signal must be absorbed silently -
  # the watcher stays alive, prints nothing, and never emits a tick.
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "watcher exited with the tick knob off (should absorb silently): $(cat "$out")"; }
    [ -s "$state/.seen-task_status" ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ -s "$state/.seen-task_status" ] || { reap "$pid"; fail "knob-off benign signal did not advance its suppressor"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "knob-off benign signal printed output (expected silence): $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "knob-off benign signal enqueued a wake record"; }
  reap "$pid"
  pass "with FM_WATCH_ABSORB_TICK unset a benign-absorbed signal stays silent and blocking (byte-identical)"
}

test_absorb_tick_on_signal_emits_one_tick() {
  local dir state fakebin out drain_out pid
  dir=$(make_case absorb-tick-signal); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  printf 'working: compiling step 2\n' > "$state/task.status"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out" env FM_WATCH_ABSORB_TICK=1
  pid=$!
  wait_for_exit "$pid" 200 || { reap "$pid"; fail "tick-enabled watcher did not end the cycle for a benign signal: $(cat "$out")"; }
  grep -Eq '^tick:' "$out" || fail "tick-enabled benign signal did not print a tick reason: $(cat "$out")"
  grep -Eq '^(signal:|stale:|check:|heartbeat)' "$out" && fail "a tick was misclassified as an actionable wake: $(cat "$out")"
  [ -s "$state/.seen-task_status" ] || fail "tick-enabled benign signal did not advance its suppressor"
  [ ! -s "$state/.wake-queue" ] || fail "a proof-of-life tick enqueued a durable wake record"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after a tick failed"
  [ ! -s "$drain_out" ] || fail "a tick left a record for the wake drain to surface: $(cat "$drain_out")"
  pass "with FM_WATCH_ABSORB_TICK=1 a benign signal ends the cycle with one tick and no wake record"
}

test_absorb_tick_on_heartbeat_emits_tick() {
  local dir state fakebin out pid
  dir=$(make_case absorb-tick-heartbeat); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  # A quiet fleet (no statuses) with work under way, a fast heartbeat cadence, and the
  # knob on. Work under way is required: an idle home never ticks (see the next case).
  printf 'window=task\n' > "$state/task.meta"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_WATCH_ABSORB_TICK=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 200 || { reap "$pid"; fail "tick-enabled watcher did not end the cycle on a no-change heartbeat: $(cat "$out")"; }
  grep -Eq '^tick:' "$out" || fail "tick-enabled no-change heartbeat did not print a tick reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "a heartbeat tick enqueued a durable wake record"
  [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] || fail "heartbeat backoff streak did not advance before ticking"
  pass "with FM_WATCH_ABSORB_TICK=1 a no-change heartbeat ticks once and still backs off its cadence"
}

test_absorb_tick_idle_home_never_ticks() {
  local dir state fakebin out pid i
  dir=$(make_case absorb-tick-idle); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  # Knob on, but NOTHING under way (no state/*.meta). A tick would end the cycle with
  # nothing queued, and with no in-flight work no guard forces a re-arm, so the home
  # would go dark. The heartbeat must stay absorbed silently and the watcher must live.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_WATCH_ABSORB_TICK=1 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "idle tick-enabled watcher exited (should absorb silently): $(cat "$out")"; }
    [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 2 ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 2 ] || { reap "$pid"; fail "idle watcher did not absorb repeated heartbeats within the bound"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "idle tick-enabled home printed output (expected silence): $(cat "$out")"; }
  reap "$pid"
  pass "with FM_WATCH_ABSORB_TICK=1 an idle home never ticks and its watcher keeps absorbing"
}

test_absorb_tick_on_actionable_signal_unchanged() {
  local dir state fakebin out drain_out pid
  dir=$(make_case absorb-tick-actionable); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  : > "$state/task.turn-ended"
  # Stopped crew (no running pipeline, no busy pane): an actionable wake. Even with the
  # tick knob on it must surface as a real signal and queue, never as a tick.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  watch_bg "$state" "$fakebin" "$out" env FM_WATCH_ABSORB_TICK=1
  pid=$!
  wait_for_exit "$pid" 200 || fail "tick-enabled watcher did not surface an actionable turn-end: $(cat "$out")"
  grep -F "signal: $state/task.turn-ended" "$out" >/dev/null || fail "actionable turn-end did not print its signal (tick misfired?): $(cat "$out")"
  grep -Eq '^tick:' "$out" && fail "an actionable wake was emitted as a tick: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the actionable turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/task.turn-ended" >/dev/null || fail "actionable turn-end was not queued with the knob on"
  pass "with FM_WATCH_ABSORB_TICK=1 an actionable wake is unchanged: surfaced and queued, never a tick"
}

test_signal_reason_is_actionable_classifier
test_stale_is_terminal_classifier
test_scan_captain_relevant_statuses_classifier
test_classifier_primitives
test_crew_is_provably_working_classifier
test_status_is_paused_classifier
test_crew_absorb_class_classifier
test_signal_crew_provably_working_classifier
test_provably_working_signal_absorbed
test_turn_ended_provably_working_absorbed
test_turn_ended_not_working_surfaced
test_working_note_not_working_surfaced
test_actionable_signal_surfaced
test_terminal_stale_surfaced
test_stale_terminal_status_overridden_by_active_run
test_terminal_stale_verdict_unchanged_absorbs_pane_redraw
test_beacon_stays_fresh_through_terminal_sleep
test_nonterminal_stale_provably_working_absorbed_then_escalated
test_wedge_escalation_marks_demand_deep_inspection_after_threshold
test_wedge_escalation_resets_when_pane_becomes_active
test_nonterminal_stale_not_working_surfaced
test_nonterminal_stale_not_working_nudged_once_then_escalated
test_provably_working_wedge_nudged_once_then_escalated
test_stale_nudge_never_sent_to_secondmate_or_unsupervised
test_nonterminal_stale_paused_absorbed_then_resurfaced
test_exited_declared_pause_is_bounded_but_live_gate_surfaces
test_secondmate_paused_resurfaces_in_normal_mode
test_secondmate_nonpaused_stale_remains_suppressed
test_secondmate_unpause_clears_pause_tracking
test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash
test_nonterminal_paused_rechecks_authoritative_state
test_paused_authoritative_working_preserves_wedge_timer
test_nonterminal_stale_repairs_missing_or_corrupt_timer
test_triage_log_size_cap_accepts_spaced_wc_counts
test_heartbeat_no_change_absorbed
test_heartbeat_backstop_surfaces_unsurfaced_status
test_beacon_stays_fresh_while_absorbing
test_afk_present_reverts_watcher_to_one_shot
test_afk_without_daemon_keeps_normal_triage
test_afk_with_dead_daemon_lock_keeps_normal_triage
test_afk_paused_changed_pane_hands_off_plain_stale
test_secondmate_over_context_threshold_surfaced
test_secondmate_under_context_threshold_absorbed
test_secondmate_unknown_context_fails_closed
test_absorb_tick_off_is_silent
test_absorb_tick_on_signal_emits_one_tick
test_absorb_tick_on_heartbeat_emits_tick
test_absorb_tick_idle_home_never_ticks
test_absorb_tick_on_actionable_signal_unchanged
test_tracked_poll_default
