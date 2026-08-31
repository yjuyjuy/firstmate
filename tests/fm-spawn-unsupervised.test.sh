#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh --unsupervised and the watcher's exclusion of a
# supervise=off pane.
#
# Two contracts are asserted:
#   1. Parser: --unsupervised is accepted for a crewmate/scout spawn (it reaches
#      the later missing-brief fast-fail, not a flag error) and is refused in
#      combination with --secondmate. These reach validation before any
#      tmux/treehouse side effect, so they need no mocks (same fast-fail pattern
#      as fm-spawn-env.test.sh).
#   2. Watcher: bin/fm-watch.sh returns early when sourced (before the singleton
#      lock and the blocking loop), so its functions load into this shell.
#      recorded_windows() is the single chokepoint feeding every supervision path
#      (the stale/wedge loop, the event/turn-end fast wake, and the context
#      sweep), so asserting it drops a supervise=off meta while keeping an
#      ordinary meta proves the hands-off-pane exclusion for all of them.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-unsupervised)
export FM_BACKEND=tmux

run_spawn() {
  FM_ROOT_OVERRIDE='' \
    FM_HOME='' \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

# --- parser -----------------------------------------------------------------

test_unsupervised_accepted_for_ship() {
  local out status
  # --unsupervised must not be a flag error: it should fall through to the later
  # missing-brief fast-fail, exactly like a plain ship spawn with no brief.
  out=$(run_spawn nope-unsup-a1 projects/none --unsupervised 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn with no brief should still fail"
  assert_not_contains "$out" "error: --unsupervised" "--unsupervised should be accepted for a ship spawn"
  pass "--unsupervised is accepted for a ship spawn"
}

test_unsupervised_refused_with_secondmate() {
  local out status
  out=$(run_spawn nope-unsup-a2 "$TMP_ROOT/some-home" --unsupervised --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "--unsupervised --secondmate should fail"
  assert_contains "$out" "error: --unsupervised cannot combine with --secondmate" \
    "--unsupervised --secondmate should print the contradiction error"
  pass "--unsupervised is refused with --secondmate"
}

# --- watcher exclusion ------------------------------------------------------

test_recorded_windows_drops_supervise_off() {
  local state out
  state="$TMP_ROOT/watch-state"
  mkdir -p "$state"
  # An ordinary supervised ship meta and a supervise=off (unsupervised) meta.
  fm_write_meta "$state/normal.meta" \
    "window=fm:sup-normal" \
    "worktree=$TMP_ROOT/wt-normal" \
    "project=$TMP_ROOT/proj" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  fm_write_meta "$state/griller.meta" \
    "window=fm:sup-griller" \
    "worktree=$TMP_ROOT/wt-griller" \
    "project=$TMP_ROOT/proj" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "supervise=off"

  # Source the watcher: it returns early (before the lock/loop) when sourced.
  # shellcheck source=bin/fm-watch.sh
  FM_STATE_OVERRIDE="$state" . "$WATCH"
  out=$(STATE="$state" recorded_windows)

  assert_contains "$out" "fm:sup-normal" "recorded_windows should list the supervised pane"
  assert_not_contains "$out" "fm:sup-griller" "recorded_windows must drop the supervise=off pane"
  pass "recorded_windows excludes a supervise=off pane from supervision"
}

test_interactive_implies_unsupervised() {
  local out status
  # --interactive must be accepted (falling through to the later missing-brief
  # fast-fail, not a flag error) and implies the hands-off pane.
  out=$(run_spawn nope-interactive-i1 projects/none --interactive 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn with no brief should still fail"
  assert_not_contains "$out" "error: --interactive" "--interactive should be an accepted flag"
  # If --interactive were NOT a recognized flag it would fall through to the
  # positional bucket and be misread as a harness argument, surfacing as
  # "harness '--interactive'". A recognized flag leaves the harness at its
  # default (which reads 'unknown' in a config-less environment such as clean
  # CI, so a bare "unknown" substring is not a valid signal here).
  assert_not_contains "$out" "harness '--interactive'" "--interactive must not be misread as a positional harness argument"
  pass "--interactive is accepted for a spawn"
}

test_unsupervised_accepted_for_ship
test_unsupervised_refused_with_secondmate
test_interactive_implies_unsupervised
test_recorded_windows_drops_supervise_off

# --- end-to-end spawn -------------------------------------------------------
# Drive a real fm-spawn.sh through a fake tmux + treehouse (same fixture shape
# as fm-spawn-worktree-settle.test.sh) and assert the on-disk consequences of
# --unsupervised: the meta records supervise=off, and NO claude turn-end hook
# is written into the worktree (the hook install is skipped for the hands-off
# pane). The complementary default-spawn case proves the field is absent and
# the hook IS written, so the byte-identical-default claim is exercised too.

make_e2e_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_e2e_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/home/projects/project"
  wt="$case_dir/wt"
  fakebin=$(make_e2e_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_e2e_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$wt" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" "$@" 2>&1
}

test_e2e_unsupervised_meta_and_no_hook() {
  local rec case_dir home proj wt fakebin id out status
  id=e2e-unsup-a3
  rec=$(make_e2e_case e2e-unsup "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF
  out=$(run_e2e_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --unsupervised)
  status=$?
  expect_code 0 "$status" "unsupervised spawn should succeed: $out"
  assert_grep "supervise=off" "$home/state/$id.meta" "meta must record supervise=off"
  assert_absent "$wt/.claude/settings.local.json" \
    "an unsupervised claude pane must NOT get a turn-end hook in its worktree"
  pass "--unsupervised spawn records supervise=off and installs no turn-end hook"
}

test_e2e_default_spawn_has_no_supervise_field_and_installs_hook() {
  local rec case_dir home proj wt fakebin id out status
  id=e2e-default-a4
  rec=$(make_e2e_case e2e-default "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF
  out=$(run_e2e_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  status=$?
  expect_code 0 "$status" "default spawn should succeed: $out"
  assert_no_grep "supervise=" "$home/state/$id.meta" \
    "a default spawn's meta must not carry a supervise= field (byte-identical default)"
  assert_present "$wt/.claude/settings.local.json" \
    "a default claude pane must get its turn-end hook"
  pass "a default spawn omits supervise= and installs the turn-end hook"
}

test_e2e_unsupervised_meta_and_no_hook
test_e2e_default_spawn_has_no_supervise_field_and_installs_hook
