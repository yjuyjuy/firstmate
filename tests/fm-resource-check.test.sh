#!/usr/bin/env bash
# Tests for host-resource monitoring: bin/fm-resource-check.sh's thresholds and
# ceiling, and the watcher wiring that surfaces pressure to firstmate.
#
# Every reading is INJECTED (FM_RESOURCE_* overrides), so no assertion here
# depends on the machine the suite happens to run on. tests/lib.sh switches the
# monitor off for the rest of the suite; this file re-enables it deliberately.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-resource-check.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-resource-check)

# A healthy 10-core / 16 GB host: load 0.5 per core, plenty of memory, idle swap.
# Each test overrides only the readings it is actually about.
HEALTHY_ENV=(
  FM_RESOURCE_INTERVAL=900
  FM_RESOURCE_CORES=10
  FM_RESOURCE_RAM_GB=16
  FM_RESOURCE_LOAD1=5.0
  FM_RESOURCE_AVAIL_MB=8000
  FM_RESOURCE_SWAP_USED_MB=100
  FM_RESOURCE_SWAP_TOTAL_MB=8192
  FM_RESOURCE_LIVE=3
)

# run_check <override>...: run the check with the healthy baseline plus the given
# overrides, setting OUT and RC. It sets globals rather than echoing, because a
# command substitution would run it in a subshell and throw the exit status away.
OUT=
RC=0
run_check() {
  RC=0
  OUT=$(env "${HEALTHY_ENV[@]}" "$@" "$CHECK" 2>&1) || RC=$?
}

# run_raw <env-assignment>...: same, without the healthy baseline, for the probe
# tests that must leave readings unset.
run_raw() {
  RC=0
  OUT=$(env "$@" "$CHECK" 2>&1) || RC=$?
}

# blind_probe_bin <dir>: a fakebin where no kernel-wide probe can answer.
blind_probe_bin() {
  local dir=$1 fakebin
  mkdir -p "$dir/emptyproc"
  fakebin=$(fm_fakebin "$dir")
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/sysctl"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/vm_stat"
  chmod +x "$fakebin/sysctl" "$fakebin/vm_stat"
  printf '%s\n' "$fakebin"
}

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

# enter_daemon_owned_away_mode <home>: put <home> into away mode WITH a daemon
# that owns triage. The heartbeat cases below assert fm-watch.sh's daemon-owned
# heartbeat path (the afk_daemon_owns_triage branch), which queues EVERY
# heartbeat so the annotation and quiet-host behaviour can be observed. That
# branch requires a LIVE away-mode daemon, not merely state/.afk on disk: the
# ownership question moved from "is state/.afk present" to "does a live daemon
# hold this home's lock" (bin/fm-afk-daemon-lib.sh's
# fm_afk_daemon_owns_supervision), so touching state/.afk alone now leaves the
# watcher running its OWN triage, which absorbs the benign heartbeat and never
# wakes - the checkpoint then times out with exit 124. A fresh
# state/.supervise-daemon.starting bring-up marker is the documented "owned"
# state (a daemon on its way up, within FM_AFK_DAEMON_PENDING_TTL seconds), so it
# drives the same daemon-owned path a real daemon would, without spinning a real
# daemon inside a unit test.
enter_daemon_owned_away_mode() {
  : > "$1/state/.afk"
  date '+%s' > "$1/state/.supervise-daemon.starting"
}

test_healthy_reading_reports_every_metric() {
  run_check
  expect_code 0 "$RC" "healthy host exit"
  assert_contains "$OUT" "resources: healthy" "healthy status missing"
  assert_contains "$OUT" "load 5.0 (0.5x over 10 cores)" "load per core missing"
  assert_contains "$OUT" "avail 8000 MB of 16 GB" "available memory missing"
  assert_contains "$OUT" "swap 1% of 8192M" "swap usage missing"
  assert_contains "$OUT" "recommended ceiling" "recommended ceiling missing"
  assert_not_contains "$OUT" "SHED" "healthy host must not advise shedding"
  pass "a healthy host reports load, memory, swap and a ceiling and exits 0"
}

test_load_thresholds() {
  # 2.0x per core is the degraded edge; 4.0x is the critical edge.
  run_check FM_RESOURCE_LOAD1=19.9
  expect_code 0 "$RC" "just under the degraded load edge"
  assert_contains "$OUT" "resources: healthy" \
    "1.99x per core must stay healthy even though it DISPLAYS as 2.0x"

  run_check FM_RESOURCE_LOAD1=20
  expect_code 1 "$RC" "degraded load exit"
  assert_contains "$OUT" "resources: degraded" "2.0x per core must be degraded"

  run_check FM_RESOURCE_LOAD1=39.9
  expect_code 1 "$RC" "just under the critical load edge"
  assert_contains "$OUT" "resources: degraded" "3.99x per core must stay degraded"

  run_check FM_RESOURCE_LOAD1=40
  expect_code 2 "$RC" "critical load exit"
  assert_contains "$OUT" "resources: critical" "4.0x per core must be critical"
  pass "load per core classifies healthy, degraded and critical at its edges"
}

test_swap_thresholds() {
  # The swap-used PERCENTAGE only classifies the host on non-Darwin platforms
  # (fixed-size swap), so pin the OS to keep this test deterministic on any host.
  run_check FM_RESOURCE_OS=Linux FM_RESOURCE_SWAP_USED_MB=4095   # 49.99% of 8192
  expect_code 0 "$RC" "just under the degraded swap edge"
  assert_contains "$OUT" "resources: healthy" "just under 50% swap must stay healthy"

  run_check FM_RESOURCE_OS=Linux FM_RESOURCE_SWAP_USED_MB=4096   # exactly 50%
  expect_code 1 "$RC" "degraded swap exit"
  assert_contains "$OUT" "resources: degraded" "50% swap must be degraded"

  run_check FM_RESOURCE_OS=Linux FM_RESOURCE_SWAP_USED_MB=6553   # 79.99%, displays as 80%
  expect_code 1 "$RC" "just under the critical swap edge"
  assert_contains "$OUT" "resources: degraded" \
    "a reading that only ROUNDS to 80% must not be classified critical"

  run_check FM_RESOURCE_OS=Linux FM_RESOURCE_SWAP_USED_MB=6554   # 80.005%
  expect_code 2 "$RC" "critical swap exit"
  assert_contains "$OUT" "resources: critical" "80% swap must be critical"
  pass "on non-Darwin, swap occupancy classifies degraded at 50% and critical at 80%"
}

test_darwin_swap_percentage_is_informational_only() {
  # macOS uses fully dynamic swap, so a high used/total ratio is not a memory
  # pressure signal: it must not classify the host degraded or critical.
  run_check FM_RESOURCE_OS=Darwin FM_RESOURCE_SWAP_USED_MB=7373 FM_RESOURCE_SWAP_TOTAL_MB=8192  # ~90%
  expect_code 0 "$RC" "high swap% on Darwin must stay healthy"
  assert_contains "$OUT" "resources: healthy" \
    "90% dynamic swap on Darwin must not classify the host"
  assert_contains "$OUT" "swap 90% of 8192M" "the swap figure must still be reported informationally"

  # A 90% ratio that would be critical on a fixed-size-swap host, to prove the OS
  # is what makes the difference and the percentage path itself is unchanged.
  run_check FM_RESOURCE_OS=Linux FM_RESOURCE_SWAP_USED_MB=7373 FM_RESOURCE_SWAP_TOTAL_MB=8192
  expect_code 2 "$RC" "the same 90% ratio is still critical on a non-Darwin host"
  assert_contains "$OUT" "resources: critical" "fixed-size swap keeps the percentage signal"

  # AVAIL_MB remains the memory-pressure signal on Darwin: below 1024 MB is still
  # critical even with idle swap.
  run_check FM_RESOURCE_OS=Darwin FM_RESOURCE_AVAIL_MB=1023
  expect_code 2 "$RC" "sub-gigabyte memory on Darwin is still critical"
  assert_contains "$OUT" "resources: critical" \
    "AVAIL_MB stays the binding memory signal on Darwin"
  pass "on Darwin swap% is informational-only while AVAIL_MB still drives memory pressure"
}

test_recommended_ceiling_uses_the_560_mb_divisor() {
  # The memory-bound ceiling is avail_mb / PER_AGENT_MB, floor 1. A low load and a
  # live count high enough that the CPU bound (live+3 here) does not cap below the
  # memory bound, so the memory divisor is what the ceiling reflects.
  run_check FM_RESOURCE_AVAIL_MB=5600 FM_RESOURCE_LOAD1=1.0 FM_RESOURCE_LIVE=8
  expect_code 0 "$RC" "healthy memory-bound exit"
  assert_contains "$OUT" "recommended ceiling 10 active agents" \
    "5600 MB must support ten agents at 560 MB each, not eight at 640"

  run_check FM_RESOURCE_AVAIL_MB=559 FM_RESOURCE_LOAD1=1.0 FM_RESOURCE_LIVE=1
  expect_code 2 "$RC" "sub-560 MB is under the 1024 MB critical floor"
  assert_contains "$OUT" "recommended ceiling 1 active agents" \
    "the memory ceiling never drops below one agent"
  pass "the memory-bound ceiling divides available memory by the trimmed 560 MB"
}

test_memory_headroom_threshold_and_ceiling() {
  run_check FM_RESOURCE_AVAIL_MB=1024
  expect_code 0 "$RC" "1024 MB available is still healthy"
  assert_contains "$OUT" "recommended ceiling 1" "1024 MB supports exactly one agent at 560 MB each"

  run_check FM_RESOURCE_AVAIL_MB=1280
  expect_code 0 "$RC" "two-agent headroom is healthy"
  assert_contains "$OUT" "recommended ceiling 2" \
    "the memory bound is one active agent per measured 560 MB, not per 1024 MB"

  run_check FM_RESOURCE_AVAIL_MB=1023
  expect_code 2 "$RC" "sub-gigabyte headroom exit"
  assert_contains "$OUT" "resources: critical" "under 1024 MB available must be critical"
  pass "memory headroom classifies critical under 1 GB and binds the ceiling"
}

test_worst_of_three_decides_the_status() {
  run_check FM_RESOURCE_LOAD1=40 FM_RESOURCE_SWAP_USED_MB=4096
  expect_code 2 "$RC" "worst-of-three exit"
  assert_contains "$OUT" "resources: critical" "degraded swap must not soften a critical load"
  pass "the worst of load, swap and memory decides the status"
}

test_shed_advice_names_the_overage_only_when_over_ceiling() {
  run_check FM_RESOURCE_LOAD1=40 FM_RESOURCE_AVAIL_MB=1500 FM_RESOURCE_LIVE=8
  expect_code 2 "$RC" "over-ceiling critical exit"
  assert_contains "$OUT" "recommended ceiling 2" "ceiling should be the memory bound (1500 MB)"
  assert_contains "$OUT" "SHED 6 crew(s)" "shed advice must name the overage"
  assert_contains "$OUT" "test and browser runs" "shed advice must name the expensive work first"

  # A critically loaded host must read as critical: the CPU bound halves the crew
  # count with a floor of 1, so it can never sit at or above the current fleet.
  run_check FM_RESOURCE_LOAD1=40 FM_RESOURCE_LIVE=1
  expect_code 2 "$RC" "single-crew critical exit"
  assert_contains "$OUT" "recommended ceiling 1" \
    "a critical host must not recommend a ceiling above its one live crew"

  run_check FM_RESOURCE_LOAD1=40 FM_RESOURCE_LIVE=2
  expect_code 2 "$RC" "over-ceiling critical exit with two crews"
  assert_contains "$OUT" "recommended ceiling 1" "4.0x per core halves two crews to one"
  assert_contains "$OUT" "SHED 1 crew(s)" "a critical host over its ceiling must advise shedding"

  run_check FM_RESOURCE_LOAD1=20 FM_RESOURCE_LIVE=1
  expect_code 1 "$RC" "under-ceiling degraded exit"
  assert_contains "$OUT" "recommended ceiling 1" "2.0x per core leaves room for one crew"
  assert_not_contains "$OUT" "SHED" "a fleet already under the ceiling has nothing to shed"
  pass "shed advice appears only when live crews exceed the recommended ceiling"
}

# run_in_home <home> <fakebin> [--sweep] <override>...: the healthy baseline minus
# the injected crew count, so the script's own crew counting is exercised. Pass
# --sweep first to take the watcher's probing path instead of the cached one.
run_in_home() {
  local home=$1 fakebin=$2 sweep=()
  shift 2
  if [ "${1:-}" = --sweep ]; then
    sweep=(--sweep)
    shift
  fi
  RC=0
  OUT=$(env PATH="$fakebin:$PATH" FM_RESOURCE_INTERVAL=900 FM_RESOURCE_CORES=10 \
    FM_RESOURCE_RAM_GB=16 FM_RESOURCE_LOAD1=5.0 FM_RESOURCE_AVAIL_MB=8000 \
    FM_RESOURCE_SWAP_USED_MB=100 FM_RESOURCE_SWAP_TOTAL_MB=8192 \
    FM_HOME="$home" "$@" "$CHECK" "${sweep[@]+"${sweep[@]}"}" 2>&1) || RC=$?
}

# fake_tmux <dir> <alive-window-suffix>: a tmux whose pane_current_command reads
# as a live agent only for the named window, and as a bare shell (the confident
# dead verdict) for every other one. An empty suffix makes every probe fail, so
# no verdict is confident and every recorded crew still counts.
fake_tmux() {
  local dir=$1 alive=${2:-} fakebin
  fakebin=$(fm_fakebin "$dir")
  if [ -z "$alive" ]; then
    printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/tmux"
  else
    cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in *$alive) echo claude; exit 0 ;; esac
done
echo zsh
SH
  fi
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_live_crew_count_comes_from_recorded_work() {
  local home fakebin
  home=$(make_home live-count)
  fakebin=$(fake_tmux "$TMP_ROOT/live-count-bin")
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "harness=echo"
  fm_write_meta "$home/state/beta.meta" "window=firstmate:fm-beta" "harness=echo"
  run_in_home "$home" "$fakebin" --sweep
  expect_code 0 "$RC" "live-count exit"
  assert_contains "$OUT" "live agents 2 = 2 active (2 crew(s))" \
    "a crew whose liveness cannot be read must still count"
  pass "recorded work counts as live unless the backend confidently says otherwise"
}

test_live_crew_count_excludes_agents_that_are_not_running() {
  local home fakebin
  home=$(make_home live-count-dead)
  fakebin=$(fake_tmux "$TMP_ROOT/live-count-dead-bin" fm-alpha)
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "harness=claude"
  fm_write_meta "$home/state/beta.meta" "window=firstmate:fm-beta" "harness=claude"
  fm_write_meta "$home/state/gamma.meta" "window=firstmate:fm-gamma" "harness=claude"
  run_in_home "$home" "$fakebin" --sweep
  expect_code 0 "$RC" "divergent live-count exit"
  assert_contains "$OUT" "live agents 1 = 1 active (1 crew(s))" \
    "recorded work whose agent has exited must not count as a live crew"
  assert_not_contains "$OUT" "liveness unverified" \
    "a probed sweep reports a verified count"
  [ "$(cat "$home/state/.resource-live")" = "1 0 0 0" ] \
    || fail "the sweep must cache its verified count for the synchronous callers"
  pass "the live-crew count follows running agents, not recorded task files"
}

test_synchronous_reading_uses_the_cached_verdict() {
  local home fakebin
  home=$(make_home live-count-cached)
  fakebin=$(fake_tmux "$TMP_ROOT/live-count-cached-bin" fm-alpha)
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "harness=claude"
  fm_write_meta "$home/state/beta.meta" "window=firstmate:fm-beta" "harness=claude"
  fm_write_meta "$home/state/gamma.meta" "window=firstmate:fm-gamma" "harness=claude"
  printf '1 0 0 0\n' > "$home/state/.resource-live"
  run_in_home "$home" "$fakebin"
  expect_code 0 "$RC" "cached live-count exit"
  assert_contains "$OUT" "live agents 1 = 1 active (1 crew(s))" \
    "the synchronous path must use the sweep's cached verdict, not the meta count"
  assert_not_contains "$OUT" "liveness unverified" "a fresh cached verdict is verified"
  pass "a synchronous reading reports the sweep's cached running-crew count"
}

test_synchronous_reading_never_probes_a_wedged_backend() {
  local home fakebin started elapsed
  home=$(make_home live-count-wedged)
  fakebin=$(fm_fakebin "$TMP_ROOT/live-count-wedged-bin")
  printf '#!/usr/bin/env bash\nsleep 4713\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "harness=claude"
  fm_write_meta "$home/state/beta.meta" "window=firstmate:fm-beta" "harness=claude"
  started=$SECONDS
  run_in_home "$home" "$fakebin"
  elapsed=$((SECONDS - started))
  expect_code 0 "$RC" "wedged-backend synchronous exit"
  [ "$elapsed" -lt 10 ] || fail "a synchronous reading waited ${elapsed}s on a wedged backend"
  assert_contains "$OUT" "live agents 2 = 2 active (2 crew(s)) (recorded work, liveness unverified)" \
    "with no cached verdict the count must fall back to recorded work and say so"
  pass "a dispatch-path reading never probes, so a wedged backend cannot delay it"
}

test_stale_cached_verdict_degrades_honestly() {
  local home fakebin
  home=$(make_home live-count-stale)
  fakebin=$(fake_tmux "$TMP_ROOT/live-count-stale-bin" fm-alpha)
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "harness=claude"
  fm_write_meta "$home/state/beta.meta" "window=firstmate:fm-beta" "harness=claude"
  printf '1 0 0 0\n' > "$home/state/.resource-live"
  touch -t 202001010000 "$home/state/.resource-live"
  run_in_home "$home" "$fakebin"
  expect_code 0 "$RC" "stale cached live-count exit"
  assert_contains "$OUT" "live agents 2 = 2 active (2 crew(s)) (recorded work, liveness unverified)" \
    "a verdict older than two sweeps must not pass as a verified count"
  pass "a cached verdict older than two sweep intervals degrades and says so"
}

test_cached_verdict_never_over_reports_a_torn_down_crew() {
  local home fakebin
  home=$(make_home live-count-teardown)
  fakebin=$(fake_tmux "$TMP_ROOT/live-count-teardown-bin" fm-alpha)
  # The sweep verified three live crews and cached that count.
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "harness=claude"
  fm_write_meta "$home/state/beta.meta" "window=firstmate:fm-beta" "harness=claude"
  fm_write_meta "$home/state/gamma.meta" "window=firstmate:fm-gamma" "harness=claude"
  printf '3 0 0 0\n' > "$home/state/.resource-live"
  # Teardown removes one crew's meta before the next sweep runs.
  rm -f "$home/state/gamma.meta"
  run_in_home "$home" "$fakebin"
  expect_code 0 "$RC" "post-teardown cached live-count exit"
  assert_contains "$OUT" "live agents 2 = 2 active (2 crew(s))" \
    "a crew torn down since the sweep must not still be counted from the cache"
  assert_not_contains "$OUT" "liveness unverified" \
    "clamping a verified cache to the current metas stays a cheap, verified reading"
  pass "the cached count is clamped to the current metas immediately after a teardown"
}

test_cached_clamp_never_raises_a_count_above_the_cache() {
  local home fakebin
  home=$(make_home live-count-clamp-floor)
  fakebin=$(fake_tmux "$TMP_ROOT/live-count-clamp-floor-bin" fm-alpha)
  # A crew spawned after the last sweep has a meta the cache does not yet count.
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "harness=claude"
  fm_write_meta "$home/state/beta.meta" "window=firstmate:fm-beta" "harness=claude"
  printf '1 0 0 0\n' > "$home/state/.resource-live"
  run_in_home "$home" "$fakebin"
  expect_code 0 "$RC" "under-cache cached live-count exit"
  assert_contains "$OUT" "live agents 1 = 1 active (1 crew(s))" \
    "clamping only lowers a count; a not-yet-swept spawn must not be counted early"
  pass "the clamp never raises a cached count above the sweep's verified verdict"
}

test_cached_partial_verdict_stays_labelled_partial() {
  local home fakebin i started elapsed
  home=$(make_home live-count-cached-partial)
  fakebin=$(fm_fakebin "$TMP_ROOT/live-count-cached-partial-bin")
  printf '#!/usr/bin/env bash\nsleep 4715\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  for i in 1 2 3; do
    fm_write_meta "$home/state/task$i.meta" "window=firstmate:fm-task$i" "harness=claude"
  done
  run_in_home "$home" "$fakebin" --sweep FM_RESOURCE_PROBE_TIMEOUT=1 FM_RESOURCE_SWEEP_BUDGET=1
  expect_code 0 "$RC" "partial sweep exit"
  assert_contains "$OUT" "live agents 3 = 3 active (3 crew(s)) (liveness partly unverified, probe budget spent)" \
    "the sweep itself must label a budget-truncated count"
  started=$SECONDS
  run_in_home "$home" "$fakebin"
  elapsed=$((SECONDS - started))
  expect_code 0 "$RC" "cached partial exit"
  [ "$elapsed" -lt 10 ] || fail "the cached path waited ${elapsed}s on a wedged backend"
  assert_contains "$OUT" "live agents 3 = 3 active (3 crew(s)) (liveness partly unverified, probe budget spent)" \
    "a cached partly probed count must not be replayed as a verified one"
  pkill -f 'sleep 4715' >/dev/null 2>&1 || true
  pass "a partly probed count keeps its label on every later cached reading"
}

test_persistent_secondmates_are_counted_but_never_shed() {
  local home fakebin
  home=$(make_home live-count-secondmate)
  fakebin=$(fake_tmux "$TMP_ROOT/live-count-secondmate-bin")
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "harness=claude"
  fm_write_meta "$home/state/beta.meta" "window=firstmate:fm-beta" "harness=claude"
  fm_write_meta "$home/state/sm1.meta" "window=firstmate:fm-sm1" "harness=claude" \
    "kind=secondmate"
  run_in_home "$home" "$fakebin" --sweep FM_RESOURCE_LOAD1=40 FM_RESOURCE_AVAIL_MB=3000
  expect_code 2 "$RC" "critical exit with a secondmate present"
  assert_contains "$OUT" "live agents 3 = 3 active (2 crew(s) + 1 persistent secondmate(s))" \
    "the reading must report crews and persistent secondmates separately"
  assert_contains "$OUT" "SHED 2 crew(s)" \
    "the overage must be measured on all running agents against the same ceiling"
  pass "a persistent secondmate is reported in the reading but never in the overage"
}

test_the_ceiling_and_the_overage_share_one_basis() {
  local home fakebin i
  home=$(make_home live-count-basis)
  fakebin=$(fake_tmux "$TMP_ROOT/live-count-basis-bin")
  for i in 1 2 3 4; do
    fm_write_meta "$home/state/crew$i.meta" "window=firstmate:fm-crew$i" "harness=claude"
    fm_write_meta "$home/state/sm$i.meta" "window=firstmate:fm-sm$i" "harness=claude" \
      "kind=secondmate"
  done
  # 4 crews + 4 secondmates at 4.0 per core with ample memory: 8 running agents,
  # a CPU-derived ceiling of 4, an overage of 4, capped at the 4 ordinary crews.
  run_in_home "$home" "$fakebin" --sweep FM_RESOURCE_LOAD1=40
  expect_code 2 "$RC" "critical exit with crews and secondmates together"
  assert_contains "$OUT" "live agents 8 = 8 active (4 crew(s) + 4 persistent secondmate(s))" \
    "both kinds of running agent must stay visible"
  assert_contains "$OUT" "recommended ceiling 4 active agents" \
    "the ceiling must be derived from all running agents"
  assert_contains "$OUT" "SHED 4 crew(s)" \
    "secondmates must not suppress shed advice for ordinary crews"

  # The same host with no secondmates: 4 running agents, ceiling 2, overage 2.
  run_check FM_RESOURCE_LOAD1=40 FM_RESOURCE_LIVE=4
  expect_code 2 "$RC" "critical exit with four crews and no secondmates"
  assert_contains "$OUT" "recommended ceiling 2 active agents" "4.0x per core halves four crews to two"
  assert_contains "$OUT" "SHED 2 crew(s)" "the crew-only host must advise shedding two"
  pass "the ceiling and the overage are computed on the same all-agents basis"
}

test_a_home_of_only_secondmates_never_advises_shedding() {
  local home fakebin
  home=$(make_home live-count-secondmate-only)
  fakebin=$(fake_tmux "$TMP_ROOT/live-count-secondmate-only-bin")
  fm_write_meta "$home/state/sm1.meta" "window=firstmate:fm-sm1" "harness=claude" \
    "kind=secondmate"
  fm_write_meta "$home/state/sm2.meta" "window=firstmate:fm-sm2" "harness=claude" \
    "kind=secondmate"
  run_in_home "$home" "$fakebin" --sweep FM_RESOURCE_LOAD1=40 FM_RESOURCE_AVAIL_MB=3000
  expect_code 2 "$RC" "critical exit with only secondmates recorded"
  assert_contains "$OUT" "live agents 2 = 2 active (0 crew(s) + 2 persistent secondmate(s))" \
    "persistent secondmates must still be visible in the reading"
  assert_not_contains "$OUT" "SHED" \
    "a home whose only running agents are secondmates has nothing to shed"

  run_in_home "$home" "$fakebin" --sweep FM_RESOURCE_LOAD1=40
  expect_code 2 "$RC" "critical exit with only secondmates and ample memory"
  assert_not_contains "$OUT" "SHED" \
    "a CPU-bound overage must still name no shed candidate when no crew is running"
  pass "persistent secondmates alone never produce shed advice, however loaded the host"
}

# The captain's 2026-07-24 ruling: an idle persistent secondmate is reported but
# charged nothing. Idle means its OWN home holds no routed work, so these tests
# give each secondmate meta a real home directory and vary only what is recorded
# inside it.
test_an_idle_secondmate_is_reported_but_never_charged() {
  local home fakebin sm1 sm2
  home=$(make_home live-count-idle-secondmate)
  sm1=$(make_home live-count-idle-secondmate-sm1)
  sm2=$(make_home live-count-idle-secondmate-sm2)
  fakebin=$(fake_tmux "$TMP_ROOT/live-count-idle-secondmate-bin")
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "harness=claude"
  fm_write_meta "$home/state/beta.meta" "window=firstmate:fm-beta" "harness=claude"
  fm_write_secondmate_meta "$home/state/sm1.meta" "$sm1" "firstmate:fm-sm1"
  fm_write_secondmate_meta "$home/state/sm2.meta" "$sm2" "firstmate:fm-sm2"
  # 2 crews charged, 2 idle secondmates not. At 4.0 per core the CPU bound halves
  # the ACTIVE 2 to a ceiling of 1, so the overage is 1. Charging all four would
  # have given a ceiling of 2 and an overage of 2.
  run_in_home "$home" "$fakebin" --sweep FM_RESOURCE_LOAD1=40
  expect_code 2 "$RC" "critical exit with idle secondmates present"
  assert_contains "$OUT" "live agents 4 = 2 active (2 crew(s)) + 2 idle secondmate(s)" \
    "an idle secondmate must stay visible in the total even though it is not charged"
  assert_contains "$OUT" "recommended ceiling 1 active agents" \
    "an idle secondmate must not enter the processor component of the ceiling"
  assert_contains "$OUT" "SHED 1 crew(s)" \
    "an idle secondmate must not inflate the overage"
  [ "$(cat "$home/state/.resource-live")" = "2 0 2 0" ] \
    || fail "the sweep must cache the idle secondmates separately from the charged ones"
  pass "an idle persistent secondmate is reported in the total but charged nothing"
}

test_a_working_secondmate_is_charged_like_a_crew() {
  local home fakebin sm
  home=$(make_home live-count-busy-secondmate)
  sm=$(make_home live-count-busy-secondmate-sm)
  fakebin=$(fake_tmux "$TMP_ROOT/live-count-busy-secondmate-bin")
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "harness=claude"
  fm_write_secondmate_meta "$home/state/sm.meta" "$sm" "firstmate:fm-sm"
  # One routed task recorded in the secondmate's OWN home is what makes it busy.
  fm_write_meta "$sm/state/routed.meta" "window=domain:fm-routed" "harness=claude"
  run_in_home "$home" "$fakebin" --sweep FM_RESOURCE_LOAD1=40
  expect_code 2 "$RC" "critical exit with a working secondmate"
  assert_contains "$OUT" "live agents 2 = 2 active (1 crew(s) + 1 persistent secondmate(s))" \
    "a secondmate with routed work in flight must count as active"
  assert_not_contains "$OUT" "idle secondmate" \
    "a working secondmate must not be reported as idle"
  assert_contains "$OUT" "SHED 1 crew(s)" \
    "a working secondmate counts toward the overage the shed advice is measured from"
  pass "a persistent secondmate with routed work in flight is charged like a crew"
}

test_a_secondmate_whose_agent_has_exited_is_not_counted_at_all() {
  local home fakebin sm
  home=$(make_home live-count-dead-secondmate)
  sm=$(make_home live-count-dead-secondmate-sm)
  fakebin=$(fake_tmux "$TMP_ROOT/live-count-dead-secondmate-bin" fm-alpha)
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "harness=claude"
  fm_write_secondmate_meta "$home/state/sm.meta" "$sm" "firstmate:fm-sm"
  fm_write_meta "$sm/state/routed.meta" "window=domain:fm-routed" "harness=claude"
  # The secondmate would be charged as active on its recorded work alone, but its
  # agent has exited, so it must not appear anywhere in the reading.
  run_in_home "$home" "$fakebin" --sweep
  expect_code 0 "$RC" "exited-secondmate sweep exit"
  assert_contains "$OUT" "live agents 1 = 1 active (1 crew(s))" \
    "a recorded secondmate whose agent has exited must not be counted"
  assert_not_contains "$OUT" "secondmate(s)" \
    "an exited secondmate must not be reported as either active or idle"
  [ "$(cat "$home/state/.resource-live")" = "1 0 0 0" ] \
    || fail "the cached verdict must also exclude the exited secondmate"

  # And the synchronous path replays that cached verdict rather than re-probing.
  run_in_home "$home" "$fakebin"
  expect_code 0 "$RC" "exited-secondmate cached exit"
  assert_contains "$OUT" "live agents 1 = 1 active (1 crew(s))" \
    "the synchronous path must reuse the sweep's cached liveness, not the meta count"
  assert_not_contains "$OUT" "liveness unverified" "a fresh cached verdict is verified"
  pass "a recorded agent whose process is gone is charged nothing on either path"
}

test_a_pre_split_cached_record_degrades_rather_than_being_misread() {
  local home fakebin sm
  home=$(make_home live-count-old-cache)
  sm=$(make_home live-count-old-cache-sm)
  fakebin=$(fake_tmux "$TMP_ROOT/live-count-old-cache-bin")
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "harness=claude"
  fm_write_secondmate_meta "$home/state/sm.meta" "$sm" "firstmate:fm-sm"
  # The three-field record written before the idle split. Its third field is the
  # partial marker, which must never be read as an idle-secondmate count.
  printf '5 5 0\n' > "$home/state/.resource-live"
  run_in_home "$home" "$fakebin"
  expect_code 0 "$RC" "pre-split cache exit"
  assert_contains "$OUT" "live agents 2 = 1 active (1 crew(s)) + 1 idle secondmate(s) (recorded work, liveness unverified)" \
    "a cache written before the idle split must degrade to an honest recorded-work count"
  pass "a pre-split cached record is discarded instead of being misread"
}

test_sweep_without_the_backend_library_labels_its_count() {
  local home fakebin
  home=$(make_home live-count-nolib)
  fakebin=$(fake_tmux "$TMP_ROOT/live-count-nolib-bin" fm-alpha)
  mkdir -p "$TMP_ROOT/norootbin/bin"
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "harness=claude"
  run_in_home "$home" "$fakebin" --sweep FM_ROOT_OVERRIDE="$TMP_ROOT/norootbin"
  expect_code 0 "$RC" "backend-less sweep exit"
  assert_contains "$OUT" "live agents 1 = 1 active (1 crew(s)) (recorded work, liveness unverified)" \
    "a sweep that cannot read liveness must not present recorded work as verified"
  pass "a sweep with no backend library labels its recorded-work count honestly"
}

test_probe_timeout_leaves_no_stuck_backend_process() {
  local home fakebin started elapsed
  home=$(make_home probe-wedged)
  fakebin=$(fm_fakebin "$TMP_ROOT/probe-wedged-bin")
  # A distinctive duration so the survivor check cannot match unrelated sleeps.
  printf '#!/usr/bin/env bash\nsleep 4711\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "harness=claude"
  started=$SECONDS
  run_in_home "$home" "$fakebin" --sweep FM_RESOURCE_PROBE_TIMEOUT=1
  elapsed=$((SECONDS - started))
  expect_code 0 "$RC" "wedged-probe sweep exit"
  [ "$elapsed" -lt 15 ] || fail "a wedged probe hung the sweep for ${elapsed}s"
  assert_contains "$OUT" "live agents 1 = 1 active (1 crew(s))" "an unanswered probe must still count its crew"
  sleep 1
  if pgrep -f 'sleep 4711' >/dev/null 2>&1; then
    pkill -f 'sleep 4711' >/dev/null 2>&1 || true
    fail "the wedged backend command outlived its probe timeout"
  fi
  pass "a probe timeout terminates the wedged backend command, not just the waiter"
}

test_sweep_probing_is_bounded_as_a_whole() {
  local home fakebin i started elapsed_small elapsed_big
  home=$(make_home sweep-budget)
  fakebin=$(fm_fakebin "$TMP_ROOT/sweep-budget-bin")
  printf '#!/usr/bin/env bash\nsleep 4713\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  for i in 1 2; do
    fm_write_meta "$home/state/task$i.meta" "window=firstmate:fm-task$i" "harness=claude"
  done
  started=$SECONDS
  run_in_home "$home" "$fakebin" --sweep FM_RESOURCE_PROBE_TIMEOUT=1 FM_RESOURCE_SWEEP_BUDGET=1
  elapsed_small=$((SECONDS - started))
  expect_code 0 "$RC" "budgeted sweep exit with two crews"
  assert_contains "$OUT" "live agents 2 = 2 active (2 crew(s)) (liveness partly unverified, probe budget spent)" \
    "a partly probed sweep must count unprobed crews and say the count is partly unverified"

  # Eight recorded crews, same budget: the sweep must not cost four times as much.
  for i in 3 4 5 6 7 8; do
    fm_write_meta "$home/state/task$i.meta" "window=firstmate:fm-task$i" "harness=claude"
  done
  started=$SECONDS
  run_in_home "$home" "$fakebin" --sweep FM_RESOURCE_PROBE_TIMEOUT=1 FM_RESOURCE_SWEEP_BUDGET=1
  elapsed_big=$((SECONDS - started))
  expect_code 0 "$RC" "budgeted sweep exit with eight crews"
  assert_contains "$OUT" "live agents 8 = 8 active (8 crew(s)) (liveness partly unverified, probe budget spent)" \
    "every crew left unprobed must still count toward the live total"
  [ "$elapsed_big" -lt $(( elapsed_small + 4 )) ] \
    || fail "sweep probing scaled with the crew count: ${elapsed_small}s then ${elapsed_big}s"
  [ "$elapsed_big" -lt 10 ] || fail "a wedged backend held the sweep for ${elapsed_big}s"
  pass "total sweep probing stays inside its budget however many crews are recorded"
}

test_malformed_sweep_budget_never_disables_the_budget() {
  local home fakebin
  home=$(make_home sweep-budget-malformed)
  fakebin=$(fake_tmux "$TMP_ROOT/sweep-budget-malformed-bin" fm-alpha)
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "harness=claude"
  fm_write_meta "$home/state/beta.meta" "window=firstmate:fm-beta" "harness=claude"
  run_in_home "$home" "$fakebin" --sweep FM_RESOURCE_SWEEP_BUDGET=30s
  expect_code 0 "$RC" "malformed sweep-budget exit"
  assert_contains "$OUT" "resources: healthy" \
    "a malformed sweep budget must fall back, not degrade the whole reading"
  assert_contains "$OUT" "live agents 1 = 1 active (1 crew(s))" "the sweep must still probe with the fallback budget"
  assert_not_contains "$OUT" "partly unverified" \
    "a fallback budget must leave a fully probed sweep verified"
  pass "a malformed sweep budget falls back to the default instead of disabling it"
}

test_malformed_probe_timeout_never_takes_monitoring_dark() {
  local home fakebin
  home=$(make_home probe-timeout)
  fakebin=$(fake_tmux "$TMP_ROOT/probe-timeout-bin" fm-alpha)
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "harness=claude"
  fm_write_meta "$home/state/beta.meta" "window=firstmate:fm-beta" "harness=claude"
  run_in_home "$home" "$fakebin" --sweep FM_RESOURCE_PROBE_TIMEOUT=5s
  expect_code 0 "$RC" "malformed probe-timeout exit"
  assert_contains "$OUT" "resources: healthy" \
    "a malformed probe timeout must fall back, not degrade the whole reading"
  assert_contains "$OUT" "live agents 1 = 1 active (1 crew(s))" "the sweep must still probe with the fallback timeout"
  pass "a malformed probe timeout falls back instead of taking the monitor dark"
}

test_injected_live_count_still_wins() {
  local home fakebin
  home=$(make_home live-count-injected)
  fakebin=$(fake_tmux "$TMP_ROOT/live-count-injected-bin" fm-alpha)
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "harness=claude"
  run_in_home "$home" "$fakebin" --sweep FM_RESOURCE_LIVE=6
  expect_code 0 "$RC" "injected live-count exit"
  assert_contains "$OUT" "live agents 6 = 6 active (6 crew(s))" "an injected crew count must be used verbatim"
  run_in_home "$home" "$fakebin" FM_RESOURCE_LIVE=6
  expect_code 0 "$RC" "injected live-count exit on the synchronous path"
  assert_contains "$OUT" "live agents 6 = 6 active (6 crew(s))" "injection must win on the cached path too"
  pass "the FM_RESOURCE_LIVE injection seam still overrides both crew-count paths"
}

# --- blocked/parked crews excluded from the active count --------------------
# A crew waiting on a captain decision or another lane's unlanded work (blocked:)
# or idling on a long declared external wait (paused:) holds a worktree but needs
# no active watching, so like an idle secondmate it must count toward neither the
# ceiling nor the overage. The state comes from the durable status-event
# classifier (the crew's own state/<id>.status), NEVER a pane probe. These tests
# stage real status logs and a cached liveness verdict, so no probe runs and the
# split is what is under test. write_crew_status <home> <id> <line...>: stage a
# crew meta plus its status log with the given event lines.
write_crew_status() {
  local home=$1 id=$2 line
  shift 2
  fm_write_meta "$home/state/$id.meta" "window=firstmate:fm-$id" "harness=claude"
  : > "$home/state/$id.status"
  for line in "$@"; do
    printf '%s\n' "$line" >> "$home/state/$id.status"
  done
}

# run_blocked <home> <override>...: a healthy-baseline synchronous reading in
# <home> (no --sweep), so the staged cached verdict and the fresh status read are
# what produce the split. FM_RESOURCE_LOAD1=40 makes the host critical so the
# ceiling and shed advice are observable.
run_blocked() {
  local home=$1
  shift
  RC=0
  OUT=$(env FM_RESOURCE_INTERVAL=900 FM_RESOURCE_CORES=10 FM_RESOURCE_RAM_GB=16 \
    FM_RESOURCE_LOAD1=40 FM_RESOURCE_AVAIL_MB=8000 FM_RESOURCE_SWAP_USED_MB=100 \
    FM_RESOURCE_SWAP_TOTAL_MB=8192 FM_HOME="$home" "$@" "$CHECK" 2>&1) || RC=$?
}

test_blocked_and_parked_crews_are_excluded_from_the_active_count() {
  local home
  home=$(make_home blocked-excluded)
  # alpha actively working, beta blocked, gamma parked, delta needs-decision.
  write_crew_status "$home" alpha "working: building"
  write_crew_status "$home" beta "working: setup" "blocked: waiting on captain decision"
  write_crew_status "$home" gamma "paused: upstream release"
  write_crew_status "$home" delta "needs-decision: option a or b"
  # A cached verdict pins liveness so no probe runs; four live crews.
  printf '4 0 0 0\n' > "$home/state/.resource-live"
  run_blocked "$home"
  expect_code 2 "$RC" "critical exit with blocked and parked crews present"
  assert_contains "$OUT" "live agents 4 = 1 active (1 crew(s)) + 3 blocked/parked crew(s)" \
    "blocked, parked, and needs-decision crews must leave the active count and be named in the split"
  assert_contains "$OUT" "recommended ceiling 1 active agents" \
    "the ceiling must be derived from the one active crew, not all four"
  assert_not_contains "$OUT" "SHED" \
    "with only one active crew at a ceiling of one there is no overage; blocked/parked crews are never shed"
  pass "blocked, parked and needs-decision crews are excluded from the charged active count"
}

test_a_briefly_waiting_crew_still_counts_as_active() {
  local home
  home=$(make_home briefly-waiting)
  # alpha queued on the heavy-run queue, beta mid-CI: both report working:, so
  # both must STILL count - they wake fast and dropping them over-dispatches.
  write_crew_status "$home" alpha "working: TEST START - unit suite, queued on heavy-run"
  write_crew_status "$home" beta "working: PR opened, waiting on CI"
  printf '2 0 0 0\n' > "$home/state/.resource-live"
  run_blocked "$home"
  expect_code 2 "$RC" "critical exit with two briefly-waiting crews"
  assert_contains "$OUT" "live agents 2 = 2 active (2 crew(s))" \
    "a crew on the heavy-run queue or waiting on CI reports working: and must still count"
  assert_not_contains "$OUT" "blocked/parked" \
    "a briefly-waiting crew must not be reported as blocked/parked"
  pass "a briefly-waiting crew (heavy-run queue, CI) still counts as active"
}

test_unknown_crew_state_is_charged_as_active() {
  local home
  home=$(make_home unknown-charged)
  # alpha has no status log at all; beta's log is empty. Neither resolves to a
  # blocked/parked verb, so both must be charged as active (the conservative
  # default), exactly as an unreadable secondmate home is charged.
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "harness=claude"
  fm_write_meta "$home/state/beta.meta" "window=firstmate:fm-beta" "harness=claude"
  : > "$home/state/beta.status"
  printf '2 0 0 0\n' > "$home/state/.resource-live"
  run_blocked "$home"
  expect_code 2 "$RC" "critical exit with unknown-state crews"
  assert_contains "$OUT" "live agents 2 = 2 active (2 crew(s))" \
    "a crew with no or empty status log is charged as active, the conservative default"
  assert_not_contains "$OUT" "blocked/parked" \
    "unknown state must never be read as blocked/parked"
  pass "a crew whose state cannot be resolved is charged as active"
}

test_a_resumed_crew_is_recounted_immediately() {
  local home
  home=$(make_home resumed-recount)
  write_crew_status "$home" alpha "working: building"
  write_crew_status "$home" beta "blocked: waiting on captain decision"
  printf '2 0 0 0\n' > "$home/state/.resource-live"
  run_blocked "$home"
  expect_code 2 "$RC" "critical exit before beta resumes"
  assert_contains "$OUT" "live agents 2 = 1 active (1 crew(s)) + 1 blocked/parked crew(s)" \
    "beta must be excluded while its last event is blocked:"
  # beta resumes: it appends a resolved:/working: line, and the very next reading
  # must re-count it with no probe and no cache refresh.
  printf 'resolved: captain chose option a\nworking: implementing\n' >> "$home/state/beta.status"
  run_blocked "$home"
  expect_code 2 "$RC" "critical exit after beta resumes"
  assert_contains "$OUT" "live agents 2 = 2 active (2 crew(s))" \
    "a resumed crew must be re-counted on the very next reading, no cache lag"
  assert_not_contains "$OUT" "blocked/parked" "the resumed crew must leave the blocked/parked split"
  pass "a crew that resumes is re-counted as active immediately"
}

test_a_blocked_secondmate_meta_never_enters_the_crew_split() {
  local home sm
  home=$(make_home blocked-secondmate)
  sm=$(make_home blocked-secondmate-sm)
  # A blocked ordinary crew AND an idle secondmate: the secondmate must stay in
  # its own idle bucket, never counted as a blocked/parked crew.
  write_crew_status "$home" alpha "blocked: waiting on decision"
  fm_write_secondmate_meta "$home/state/sm.meta" "$sm" "firstmate:fm-sm"
  printf '1 0 1 0\n' > "$home/state/.resource-live"
  run_blocked "$home"
  expect_code 2 "$RC" "critical exit with a blocked crew and an idle secondmate"
  assert_contains "$OUT" "live agents 2 = 0 active (0 crew(s)) + 1 blocked/parked crew(s) + 1 idle secondmate(s)" \
    "a blocked crew and an idle secondmate occupy separate buckets and the split sums to the total"
  assert_not_contains "$OUT" "SHED" \
    "a home with no active crew has nothing to shed"
  pass "a secondmate is never miscounted as a blocked/parked crew"
}

test_the_shed_count_is_capped_at_active_crews_not_all_crews() {
  local home
  home=$(make_home shed-active-only)
  # Three active crews and two blocked: at 4.0 per core ACTIVE=3 halves to a
  # ceiling of 1, an overage of 2, which must cap at the three ACTIVE crews (2),
  # never rise toward all five live crews.
  write_crew_status "$home" a1 "working: building"
  write_crew_status "$home" a2 "working: building"
  write_crew_status "$home" a3 "working: building"
  write_crew_status "$home" b1 "blocked: waiting on decision"
  write_crew_status "$home" b2 "paused: upstream release"
  printf '5 0 0 0\n' > "$home/state/.resource-live"
  run_blocked "$home"
  expect_code 2 "$RC" "critical exit with three active and two blocked crews"
  assert_contains "$OUT" "live agents 5 = 3 active (3 crew(s)) + 2 blocked/parked crew(s)" \
    "only the three working crews are active; the two waiting ones are split out"
  assert_contains "$OUT" "recommended ceiling 1 active agents" \
    "the ceiling halves the three active crews to one"
  assert_contains "$OUT" "SHED 2 crew(s)" \
    "the overage is measured and capped on the active crews, not all five live crews"
  pass "the shed count is measured on active crews and never counts blocked/parked ones"
}

# --- herdr backend live-agent count ----------------------------------------
# The regression under test (2026-08-01): the sweep excluded a lane the moment
# its backend probe read `dead`, and it probed with fm_backend_agent_alive. On
# herdr a working jcode-hosted lane runs its agent turn in jcode's shared
# background server, so herdr registers NO agent for the pane (`agent get` ->
# agent_not_found), and agent_alive read every live herdr lane as `dead` -
# reporting `live agents 0` with lanes actually running. The fix probes with
# fm_backend_endpoint_live, which on herdr reads pane PRESENCE (the same signal
# session-start and the wake-brief endpoint sweep trust), so a present pane
# counts even with no registered herdr agent, while a truly-gone pane still
# excludes.

# fake_herdr <dir> <gone-pane-id...>: a `herdr` stub for the resource sweep's
# endpoint probe. `pane get <pane_id>` responds pane_not_found (the confident
# dead verdict) for every pane_id named in <gone-pane-id...> and succeeds (a
# live pane, no registered agent - exactly a jcode-hosted lane) for any other;
# `agent get` always answers agent_not_found, mirroring a jcode lane. Every
# other subcommand is a silent success so fm_backend_herdr_server_ensure and
# friends stay quiet. The gone list is the bare pane_id (e.g. "w2:p0"), because
# fm_backend_target_exists passes only the pane portion of the
# "<session>:<pane_id>" target to `pane get`.
fake_herdr() {
  local dir=$1 fakebin
  shift
  fakebin=$(fm_fakebin "$dir")
  {
    printf '#!/usr/bin/env bash\nset -u\n'
    printf 'gone="%s"\n' "$*"
    cat <<'SH'
cmd=${1:-}; sub=${2:-}; pane=${3:-}
case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n' ;;
  "pane get")
    for g in $gone; do
      if [ "$pane" = "$g" ]; then
        printf '{"error":{"code":"pane_not_found","message":"pane %s not found"}}\n' "$pane" >&2
        exit 1
      fi
    done
    printf '{"result":{"pane":{"pane_id":"%s","agent_status":"unknown"}}}\n' "$pane" ;;
  "agent get")
    printf '{"error":{"code":"agent_not_found","message":"agent %s not found"}}\n' "$pane" >&2
    exit 1 ;;
  *) : ;;
esac
exit 0
SH
  } > "$fakebin/herdr"
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$fakebin"
}

# fm_write_herdr_meta <file> <pane-target> [extra-kv...]: a herdr-backend task
# meta whose window= is the "<session>:<pane_id>" target the sweep probes.
fm_write_herdr_meta() {
  local file=$1 target=$2
  shift 2
  fm_write_meta "$file" "window=$target" "harness=jcode" "backend=herdr" "$@"
}

test_herdr_live_lanes_are_counted_from_pane_presence() {
  command -v jq >/dev/null 2>&1 || { pass "herdr live-count (skipped: jq not found)"; return 0; }
  local home fakebin
  home=$(make_home herdr-live-count)
  fakebin=$(fake_herdr "$TMP_ROOT/herdr-live-count-bin")
  fm_write_herdr_meta "$home/state/alpha.meta" "default:w1:p0"
  fm_write_herdr_meta "$home/state/beta.meta" "default:w2:p0"
  fm_write_herdr_meta "$home/state/gamma.meta" "default:w3:p0"
  run_in_home "$home" "$fakebin" --sweep
  expect_code 0 "$RC" "herdr live-count sweep exit"
  assert_contains "$OUT" "live agents 3 = 3 active (3 crew(s))" \
    "every live herdr lane's pane is present, so all three must count (not zero)"
  assert_not_contains "$OUT" "liveness unverified" \
    "a probed herdr sweep reports a verified count"
  [ "$(cat "$home/state/.resource-live")" = "3 0 0 0" ] \
    || fail "the sweep must cache its verified herdr count for the synchronous callers"
  pass "a herdr lane with a present pane counts even though it registers no herdr agent"
}

test_herdr_gone_pane_is_excluded_from_the_count() {
  command -v jq >/dev/null 2>&1 || { pass "herdr gone-pane (skipped: jq not found)"; return 0; }
  local home fakebin
  home=$(make_home herdr-gone-pane)
  # beta's pane is gone (torn down but its meta lingers); alpha and gamma live.
  fakebin=$(fake_herdr "$TMP_ROOT/herdr-gone-pane-bin" "w2:p0")
  fm_write_herdr_meta "$home/state/alpha.meta" "default:w1:p0"
  fm_write_herdr_meta "$home/state/beta.meta" "default:w2:p0"
  fm_write_herdr_meta "$home/state/gamma.meta" "default:w3:p0"
  run_in_home "$home" "$fakebin" --sweep
  expect_code 0 "$RC" "herdr gone-pane sweep exit"
  assert_contains "$OUT" "live agents 2 = 2 active (2 crew(s))" \
    "a herdr lane whose pane is gone must not count, but the present ones still must"
  [ "$(cat "$home/state/.resource-live")" = "2 0 0 0" ] \
    || fail "the cached verdict must exclude the gone herdr pane"
  pass "a confidently-gone herdr pane is excluded while present lanes still count"
}

test_unreadable_host_is_unknown_and_never_alarms() {
  local fakebin dir
  dir="$TMP_ROOT/unreadable"
  fakebin=$(blind_probe_bin "$dir")
  run_raw PATH="$fakebin:$PATH" FM_RESOURCE_INTERVAL=900 FM_RESOURCE_PROC_ROOT="$dir/emptyproc"
  expect_code 3 "$RC" "unreadable host exit"
  assert_contains "$OUT" "resources: unknown" "an unreadable host must report unknown"
  assert_not_contains "$OUT" "critical" "an unreadable host must not alarm"
  pass "a host with no kernel-wide reading is unknown, not a false alarm"
}

test_partial_reading_never_passes_as_healthy() {
  local fakebin dir
  dir="$TMP_ROOT/partial"
  fakebin=$(blind_probe_bin "$dir")
  # Everything but swap is injected; swap has no probe left to answer it.
  run_raw PATH="$fakebin:$PATH" FM_RESOURCE_INTERVAL=900 FM_RESOURCE_PROC_ROOT="$dir/emptyproc" \
    FM_RESOURCE_CORES=10 FM_RESOURCE_RAM_GB=16 FM_RESOURCE_LOAD1=1.0 \
    FM_RESOURCE_AVAIL_MB=8000 FM_RESOURCE_LIVE=0
  expect_code 3 "$RC" "partial reading exit"
  assert_contains "$OUT" "resources: unknown" "a partial reading must report unknown"
  pass "a partially readable host is unknown rather than reported healthy"
}

test_interval_knob_is_resolved_in_one_place() {
  local got
  got=$(FM_RESOURCE_INTERVAL='' "$CHECK" --interval)
  [ "$got" = 900 ] || fail "default interval should be 900, got '$got'"
  got=$(FM_RESOURCE_INTERVAL=120 "$CHECK" --interval)
  [ "$got" = 120 ] || fail "explicit interval should be honored, got '$got'"
  got=$(FM_RESOURCE_INTERVAL=nonsense "$CHECK" --interval)
  [ "$got" = 900 ] || fail "a malformed interval must fall back to the default, got '$got'"
  got=$(FM_RESOURCE_INTERVAL=0 "$CHECK" --interval)
  [ "$got" = 0 ] || fail "0 should resolve as disabled, got '$got'"
  pass "the sweep interval resolves from one place, with a safe malformed fallback"
}

test_interval_is_independent_of_the_watcher_poll_cadence() {
  local got
  got=$(FM_POLL=15 FM_CHECK_INTERVAL=30 FM_RESOURCE_INTERVAL='' "$CHECK" --interval)
  [ "$got" = 900 ] || fail "the resource cadence must not follow FM_POLL/FM_CHECK_INTERVAL, got '$got'"
  pass "the resource cadence is independent of the watcher poll and check cadences"
}

test_disabled_monitor_reports_and_never_classifies() {
  run_check FM_RESOURCE_INTERVAL=0 FM_RESOURCE_LOAD1=40
  expect_code 4 "$RC" "disabled monitor exit"
  assert_contains "$OUT" "monitoring disabled" "disabled monitor must say so"
  assert_not_contains "$OUT" "critical" "a disabled monitor must not classify the host"
  pass "FM_RESOURCE_INTERVAL=0 switches the monitor off with its own exit status"
}

test_usage_error_never_looks_like_a_status() {
  local got rc=0
  got=$("$CHECK" --bogus 2>&1) || rc=$?
  [ "$rc" = 64 ] || fail "a bad argument must not exit with a status code (0-4), got '$rc'"
  assert_contains "$got" "unknown argument" "a bad argument should say so"
  pass "a usage error exits outside the status range, so a typo cannot read as critical"
}

test_help_prints_the_whole_header_contract() {
  local got
  got=$("$CHECK" --help)
  assert_contains "$got" "fm-resource-check.sh - one kernel-wide reading" "help lost its opening line"
  assert_contains "$got" "THRESHOLDS" "help lost the thresholds it owns"
  assert_contains "$got" "CEILING" "help lost the ceiling formula it owns"
  assert_contains "$got" "FM_RESOURCE_PROC_ROOT" "help was truncated before the end of the header"
  assert_not_contains "$got" "set -u" "help ran past the header into the script body"
  pass "--help prints the full header contract, however the header grows"
}

test_spawn_help_reaches_the_end_of_its_header() {
  local got
  got=$("$ROOT/bin/fm-spawn.sh" --help)
  assert_contains "$got" "Spawn a direct report" "spawn help lost its opening line"
  assert_contains "$got" "host-resource reading" \
    "spawn help was truncated before its pre-dispatch resource advisory"
  assert_not_contains "$got" "set -eu" "spawn help ran past the header into the script body"
  pass "fm-spawn.sh --help prints its whole header, however the header grows"
}

# --- watcher wiring ---------------------------------------------------------

# The main loop no longer runs the probe itself: it reads a timestamped reading
# a separate probe cycle published. These two tests pin that the surface path
# reacts to the CACHE alone (no probe runs here - the cadence is far away and the
# stamp is fresh), and that the freshness token in the record gates staleness.
seed_reading() {  # <home> <epoch> <status> <reading-tail>
  printf '%s\t%s\t%s\n' "$2" "$3" "$4" > "$1/state/.resource-reading"
  printf '%s\n' "$3" > "$1/state/.resource-status"
  # A fresh cadence stamp keeps resource_probe_launch from firing a real probe
  # that would overwrite the seeded reading this test is about.
  touch "$1/state/.last-resource"
}

test_main_loop_surfaces_from_the_cache_without_probing() {
  local home out status now
  home=$(make_home surface-from-cache)
  now=$(date +%s)
  seed_reading "$home" "$now" critical "critical | load 40 (4.0x over 10 cores)"
  printf 'healthy\n' > "$home/state/.resource-surfaced"
  out="$home/out.txt"
  status=0
  # Interval far larger than the checkpoint window, so no probe runs: any wake
  # can only come from the cheap surface read of the seeded cache.
  env "${HEALTHY_ENV[@]}" FM_RESOURCE_INTERVAL=999999 \
    FM_HOME="$home" FM_RESOURCE_PROBE_LOCK="$home/state/.resource-probe.lock" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 6 >"$out" 2>/dev/null || status=$?
  expect_code 0 "$status" "cache-surface checkpoint exit"
  assert_contains "$(cat "$out")" "check: host-resources" "the cached pressure was not surfaced"
  assert_contains "$(cat "$out")" "load 40" "the surfaced wake lost the cached reading"
  assert_grep critical "$home/state/.resource-surfaced" "the surfaced level was not recorded"
  pass "the main loop surfaces host pressure from the published reading without probing"
}

test_stale_cached_reading_is_never_surfaced() {
  local home out status old
  home=$(make_home stale-reading)
  # Age token two-plus intervals in the past: stale, so the surface path must
  # ignore it however alarming the status word is.
  old=$(( $(date +%s) - 4000000 ))
  seed_reading "$home" "$old" critical "critical | load 40 (4.0x over 10 cores)"
  printf 'healthy\n' > "$home/state/.resource-surfaced"
  out="$home/out.txt"
  status=0
  env "${HEALTHY_ENV[@]}" FM_RESOURCE_INTERVAL=999999 \
    FM_HOME="$home" FM_RESOURCE_PROBE_LOCK="$home/state/.resource-probe.lock" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 4 >"$out" 2>/dev/null || status=$?
  expect_code 124 "$status" "stale-reading checkpoint should stay quiet"
  assert_not_contains "$(cat "$out")" "host-resources" \
    "a reading older than two sweep intervals must never be surfaced"
  pass "the main loop never surfaces a reading older than two sweep intervals"
}

test_main_loop_does_not_run_the_sweep_itself() {
  # Structural guard on the separation: the slow --sweep read lives ONLY in the
  # dedicated probe cycle, never inline in the watcher main loop.
  assert_no_grep "--sweep" "$ROOT/bin/fm-watch.sh" \
    "the slow --sweep read must not appear in the watcher main loop"
  assert_grep "--sweep" "$ROOT/bin/fm-resource-probe.sh" \
    "the probe cycle must own the --sweep read"
  assert_grep "resource_probe_launch" "$ROOT/bin/fm-watch.sh" \
    "the watcher must launch the probe cycle rather than sweep inline"
  pass "the probe's slow --sweep read is off the supervision main loop"
}

test_watcher_surfaces_pressure_once_and_queues_it() {
  local home out status drained
  home=$(make_home watcher-critical)
  out="$home/out.txt"
  status=0
  env "${HEALTHY_ENV[@]}" FM_RESOURCE_INTERVAL=1 FM_RESOURCE_LOAD1=40 \
    FM_HOME="$home" FM_RESOURCE_PROBE_LOCK="$home/state/.resource-probe.lock" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 8 >"$out" 2>/dev/null || status=$?
  expect_code 0 "$status" "resource wake checkpoint exit"
  assert_contains "$(cat "$out")" "check: host-resources" "host pressure was not surfaced"
  assert_contains "$(cat "$out")" "critical" "the surfaced wake lost the status"
  assert_contains "$(cat "$out")" "load 40" "the surfaced wake lost the reading"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tcheck\thost-resources\t' "the resource wake was not queued durably"
  assert_grep critical "$home/state/.resource-status" "the reading was not cached for the heartbeat"
  assert_grep critical "$home/state/.resource-surfaced" "the surfaced level was not recorded"
  pass "the watcher surfaces host pressure as an actionable wake and queues it durably"
}

test_watcher_absorbs_already_reported_pressure() {
  local home out status
  home=$(make_home watcher-repeat)
  printf 'critical\n' > "$home/state/.resource-surfaced"
  out="$home/out.txt"
  status=0
  env "${HEALTHY_ENV[@]}" FM_RESOURCE_INTERVAL=1 FM_RESOURCE_LOAD1=40 \
    FM_HOME="$home" FM_RESOURCE_PROBE_LOCK="$home/state/.resource-probe.lock" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 4 >"$out" 2>/dev/null || status=$?
  expect_code 124 "$status" "repeat-pressure checkpoint should stay quiet"
  assert_not_contains "$(cat "$out")" "host-resources" "already-reported pressure must not re-wake"
  pass "pressure firstmate already knows about is absorbed instead of nagged"
}

test_watcher_stays_quiet_on_a_healthy_host_and_rearms() {
  local home out status now
  home=$(make_home watcher-healthy)
  printf 'critical\n' > "$home/state/.resource-surfaced"
  # Seed a FRESH healthy reading and use a long cadence, so the re-arm comes
  # deterministically from the surface read of the cached reading rather than
  # racing a backgrounded probe that may not publish before the checkpoint ends.
  now=$(date +%s)
  seed_reading "$home" "$now" healthy "healthy | load 5 (0.5x over 10 cores)"
  out="$home/out.txt"
  status=0
  env "${HEALTHY_ENV[@]}" FM_RESOURCE_INTERVAL=999999 \
    FM_HOME="$home" FM_RESOURCE_PROBE_LOCK="$home/state/.resource-probe.lock" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 4 >"$out" 2>/dev/null || status=$?
  expect_code 124 "$status" "healthy-host checkpoint should stay quiet"
  assert_not_contains "$(cat "$out")" "host-resources" "a healthy host must not wake firstmate"
  assert_grep healthy "$home/state/.resource-surfaced" "recovery must re-arm the surfaced level"
  pass "recovery to a healthy host re-arms the monitor silently"
}

test_disabled_monitor_leaves_the_watcher_untouched() {
  local home out status
  home=$(make_home watcher-disabled)
  out="$home/out.txt"
  status=0
  env "${HEALTHY_ENV[@]}" FM_RESOURCE_INTERVAL=0 FM_RESOURCE_LOAD1=40 \
    FM_HOME="$home" FM_RESOURCE_PROBE_LOCK="$home/state/.resource-probe.lock" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 4 >"$out" 2>/dev/null || status=$?
  expect_code 124 "$status" "disabled-monitor checkpoint should stay quiet"
  assert_not_contains "$(cat "$out")" "host-resources" "a disabled monitor must not wake firstmate"
  assert_absent "$home/state/.resource-status" "a disabled monitor must not write state"
  pass "a disabled monitor adds nothing to the watcher"
}

# annotated_heartbeat_reason: run the watcher until it prints an annotated
# heartbeat on a critical host, and return that exact reason line.
annotated_heartbeat_reason() {
  local home out status
  home=$(make_home "$1")
  enter_daemon_owned_away_mode "$home"
  printf 'critical\n' > "$home/state/.resource-surfaced"
  # Seed a FRESH cached reading and use a cadence far longer than the checkpoint
  # window, so the annotation comes deterministically from the cached file rather
  # than racing a backgrounded probe that may not publish .resource-status before
  # the heartbeat fires. touch .last-resource so no probe launches to overwrite it.
  printf 'critical\n' > "$home/state/.resource-status"
  touch "$home/state/.last-resource"
  out="$home/out.txt"
  status=0
  env "${HEALTHY_ENV[@]}" FM_RESOURCE_INTERVAL=999999 \
    FM_HOME="$home" FM_RESOURCE_PROBE_LOCK="$home/state/.resource-probe.lock" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=1 "$CHECKPOINT" --seconds 8 >"$out" 2>/dev/null || status=$?
  [ "$status" = 0 ] || fail "annotated-heartbeat checkpoint exited $status"
  grep -m1 '^heartbeat' "$out" || fail "the watcher printed no heartbeat wake"
}

test_annotated_heartbeat_is_still_an_actionable_wake() {
  local reason arm_pattern
  reason=$(annotated_heartbeat_reason heartbeat-matchers)
  assert_contains "$reason" "host resources critical" \
    "the annotated heartbeat lost its host-resource pressure"
  # Both matchers come from the real sources, so a reason shape that stops being
  # a wake for the arm path or the away-mode daemon fails here instead of
  # silently disabling the heartbeat backstop while the host is under pressure.
  arm_pattern=$(awk -F"'" '/grep -Eq .\^\(signal:/ {print $2; exit}' "$ROOT/bin/fm-watch-arm.sh")
  [ -n "$arm_pattern" ] || fail "could not read fm-watch-arm.sh's actionable-wake pattern"
  printf '%s\n' "$reason" | grep -Eq "$arm_pattern" \
    || fail "fm-watch-arm.sh would not treat '$reason' as an actionable wake"
  eval "$(awk '/^is_wake_reason\(\)/,/^}/' "$ROOT/bin/fm-supervise-daemon.sh")"
  is_wake_reason "$reason" \
    || fail "fm-supervise-daemon.sh would idle on '$reason' instead of handling it"
  pass "an annotated heartbeat is still recognised as a wake by every consumer"
}

test_heartbeat_carries_the_cached_pressure() {
  local home out status
  home=$(make_home heartbeat-annotation)
  # The daemon owns triage while away mode is on, so every heartbeat is queued -
  # the cheapest way to observe the annotation a fleet review reads. The monitor
  # is ENABLED and the reading is seeded critical, so the annotation comes from
  # the cached file; the already-surfaced level absorbs the resource wake so the
  # heartbeat is what the checkpoint observes.
  enter_daemon_owned_away_mode "$home"
  printf 'critical\n' > "$home/state/.resource-surfaced"
  # Seed a FRESH cached reading and use a long cadence so the annotation comes
  # deterministically from the cached file, not from racing a backgrounded probe
  # that may not publish .resource-status before the heartbeat fires.
  printf 'critical\n' > "$home/state/.resource-status"
  touch "$home/state/.last-resource"
  out="$home/out.txt"
  status=0
  env "${HEALTHY_ENV[@]}" FM_RESOURCE_INTERVAL=999999 \
    FM_HOME="$home" FM_RESOURCE_PROBE_LOCK="$home/state/.resource-probe.lock" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=1 "$CHECKPOINT" --seconds 8 >"$out" 2>/dev/null || status=$?
  expect_code 0 "$status" "heartbeat checkpoint exit"
  assert_contains "$(cat "$out")" "heartbeat: host resources critical" \
    "the heartbeat lost its host-resource annotation"
  pass "every heartbeat carries the host's latest known pressure"
}

test_heartbeat_is_unannotated_on_a_healthy_host() {
  local home out status
  home=$(make_home heartbeat-healthy)
  enter_daemon_owned_away_mode "$home"
  out="$home/out.txt"
  status=0
  env "${HEALTHY_ENV[@]}" FM_RESOURCE_INTERVAL=1 \
    FM_HOME="$home" FM_RESOURCE_PROBE_LOCK="$home/state/.resource-probe.lock" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=1 "$CHECKPOINT" --seconds 8 >"$out" 2>/dev/null || status=$?
  expect_code 0 "$status" "healthy heartbeat checkpoint exit"
  assert_contains "$(cat "$out")" "heartbeat" "the heartbeat itself went missing"
  assert_not_contains "$(cat "$out")" "host resources" \
    "a healthy host must not annotate the heartbeat"
  pass "a healthy host leaves the heartbeat unannotated"
}

test_disabled_monitor_never_annotates_from_a_stale_reading() {
  local home out status
  home=$(make_home heartbeat-disabled-stale)
  enter_daemon_owned_away_mode "$home"
  # Nothing ever clears .resource-status, so a home that switches the monitor off
  # after a bad stretch keeps a critical file on disk forever. It must not leak
  # into the heartbeat.
  printf 'critical\n' > "$home/state/.resource-status"
  out="$home/out.txt"
  status=0
  env "${HEALTHY_ENV[@]}" FM_RESOURCE_INTERVAL=0 \
    FM_HOME="$home" FM_RESOURCE_PROBE_LOCK="$home/state/.resource-probe.lock" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=1 "$CHECKPOINT" --seconds 8 >"$out" 2>/dev/null || status=$?
  expect_code 0 "$status" "disabled-monitor heartbeat checkpoint exit"
  assert_contains "$(cat "$out")" "heartbeat" "the heartbeat itself went missing"
  assert_not_contains "$(cat "$out")" "host resources" \
    "a disabled monitor must annotate nothing, however old the cached reading is"
  pass "a disabled monitor never annotates a heartbeat from a stale reading"
}

test_stale_reading_never_annotates_a_heartbeat() {
  local home out status
  home=$(make_home heartbeat-stale)
  enter_daemon_owned_away_mode "$home"
  printf 'critical\n' > "$home/state/.resource-status"
  touch -t 202001010000 "$home/state/.resource-status"
  # A fresh sweep marker keeps the long cadence from firing one immediately and
  # overwriting the stale reading this test is about.
  touch "$home/state/.last-resource"
  out="$home/out.txt"
  status=0
  # Enabled, but with a cadence long enough that no sweep runs inside the
  # checkpoint, so the annotation can only come from the stale cached file.
  env "${HEALTHY_ENV[@]}" FM_RESOURCE_INTERVAL=999999 \
    FM_HOME="$home" FM_RESOURCE_PROBE_LOCK="$home/state/.resource-probe.lock" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=1 "$CHECKPOINT" --seconds 8 >"$out" 2>/dev/null || status=$?
  expect_code 0 "$status" "stale-reading heartbeat checkpoint exit"
  assert_contains "$(cat "$out")" "heartbeat" "the heartbeat itself went missing"
  assert_not_contains "$(cat "$out")" "host resources" \
    "a reading older than two sweeps must not annotate the heartbeat"
  pass "a heartbeat is never annotated from a reading older than two sweeps"
}

# Run every case in isolation. Each test function calls fail() on the first
# failed assertion, and fail() exits the process (tests/lib.sh); a flat list of
# bare calls therefore aborts the whole file on the first failure and silently
# skips every case after it. Wrapping each call in a subshell contains that exit
# to the one case, so a failing case still reports its "not ok" line (from fail)
# and every later case still runs and reports. Order is preserved. A subshell ( )
# does not fire the parent EXIT trap, so fm_test_cleanup's shared TMP_ROOT
# survives until the real end of the file. rc latches non-zero on any failure, so
# the runner (bin/fm-test-run.sh) still sees this file as failed. The calls stay
# in command position (not names in an array) so ShellCheck's reachability
# analysis still sees every function invoked and fm-lint stays clean.
rc=0
( test_healthy_reading_reports_every_metric ) || rc=1
( test_load_thresholds ) || rc=1
( test_swap_thresholds ) || rc=1
( test_darwin_swap_percentage_is_informational_only ) || rc=1
( test_recommended_ceiling_uses_the_560_mb_divisor ) || rc=1
( test_memory_headroom_threshold_and_ceiling ) || rc=1
( test_worst_of_three_decides_the_status ) || rc=1
( test_shed_advice_names_the_overage_only_when_over_ceiling ) || rc=1
( test_live_crew_count_comes_from_recorded_work ) || rc=1
( test_live_crew_count_excludes_agents_that_are_not_running ) || rc=1
( test_synchronous_reading_uses_the_cached_verdict ) || rc=1
( test_synchronous_reading_never_probes_a_wedged_backend ) || rc=1
( test_stale_cached_verdict_degrades_honestly ) || rc=1
( test_cached_verdict_never_over_reports_a_torn_down_crew ) || rc=1
( test_cached_clamp_never_raises_a_count_above_the_cache ) || rc=1
( test_cached_partial_verdict_stays_labelled_partial ) || rc=1
( test_persistent_secondmates_are_counted_but_never_shed ) || rc=1
( test_a_home_of_only_secondmates_never_advises_shedding ) || rc=1
( test_an_idle_secondmate_is_reported_but_never_charged ) || rc=1
( test_a_working_secondmate_is_charged_like_a_crew ) || rc=1
( test_a_secondmate_whose_agent_has_exited_is_not_counted_at_all ) || rc=1
( test_a_pre_split_cached_record_degrades_rather_than_being_misread ) || rc=1
( test_the_ceiling_and_the_overage_share_one_basis ) || rc=1
( test_sweep_without_the_backend_library_labels_its_count ) || rc=1
( test_probe_timeout_leaves_no_stuck_backend_process ) || rc=1
( test_sweep_probing_is_bounded_as_a_whole ) || rc=1
( test_malformed_sweep_budget_never_disables_the_budget ) || rc=1
( test_malformed_probe_timeout_never_takes_monitoring_dark ) || rc=1
( test_injected_live_count_still_wins ) || rc=1
( test_blocked_and_parked_crews_are_excluded_from_the_active_count ) || rc=1
( test_a_briefly_waiting_crew_still_counts_as_active ) || rc=1
( test_unknown_crew_state_is_charged_as_active ) || rc=1
( test_a_resumed_crew_is_recounted_immediately ) || rc=1
( test_a_blocked_secondmate_meta_never_enters_the_crew_split ) || rc=1
( test_the_shed_count_is_capped_at_active_crews_not_all_crews ) || rc=1
( test_herdr_live_lanes_are_counted_from_pane_presence ) || rc=1
( test_herdr_gone_pane_is_excluded_from_the_count ) || rc=1
( test_unreadable_host_is_unknown_and_never_alarms ) || rc=1
( test_partial_reading_never_passes_as_healthy ) || rc=1
( test_interval_knob_is_resolved_in_one_place ) || rc=1
( test_interval_is_independent_of_the_watcher_poll_cadence ) || rc=1
( test_disabled_monitor_reports_and_never_classifies ) || rc=1
( test_usage_error_never_looks_like_a_status ) || rc=1
( test_help_prints_the_whole_header_contract ) || rc=1
( test_spawn_help_reaches_the_end_of_its_header ) || rc=1
( test_main_loop_surfaces_from_the_cache_without_probing ) || rc=1
( test_stale_cached_reading_is_never_surfaced ) || rc=1
( test_main_loop_does_not_run_the_sweep_itself ) || rc=1
( test_watcher_surfaces_pressure_once_and_queues_it ) || rc=1
( test_watcher_absorbs_already_reported_pressure ) || rc=1
( test_watcher_stays_quiet_on_a_healthy_host_and_rearms ) || rc=1
( test_disabled_monitor_leaves_the_watcher_untouched ) || rc=1
( test_annotated_heartbeat_is_still_an_actionable_wake ) || rc=1
( test_heartbeat_carries_the_cached_pressure ) || rc=1
( test_heartbeat_is_unannotated_on_a_healthy_host ) || rc=1
( test_disabled_monitor_never_annotates_from_a_stale_reading ) || rc=1
( test_stale_reading_never_annotates_a_heartbeat ) || rc=1
exit "$rc"
