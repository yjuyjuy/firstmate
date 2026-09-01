#!/usr/bin/env bash
# tests/fm-session-start.test.sh - behavior tests for bin/fm-session-start.sh,
# the single command that collapses AGENTS.md sections 3 (bootstrap) and 5
# (recovery) into one ordered digest.
#
# Coverage:
#   - absent-file markers vs empty-but-present files in the context digest
#   - the cross-session stall banner: a prior session's still-open paused/blocked
#     workers surfaced prominently (via fm-crew-state.sh) above the status tails,
#     with the paused case age-gated by FM_SESSION_START_STALL_THRESHOLD
#   - the lock-refusal read-only path: banner leads, every mutating step is
#     skipped (including bootstrap's six mutating sweeps, verified by their
#     ABSENCE), the digest still completes
#   - output section ordering: diagnostics/banners lead, bulk file dumps follow
#   - context-aware next-step guidance for read-only, AFK, X mode, and normal
#     watcher ownership
#   - status-tail bounding, default and FM_SESSION_START_STATUS_TAIL override
#   - orphan status logs whose task meta has already disappeared
#   - per-task endpoint-liveness lines for a live and a dead recorded target,
#     tmux and herdr both
#   - composition: the script invokes the real fm-lock.sh/fm-bootstrap.sh/
#     fm-wake-drain.sh (their real, distinctive output appears verbatim), it
#     does not reimplement their logic
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

SESSION_START="$ROOT/bin/fm-session-start.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-session-start-tests)
fm_git_identity fmtest fmtest@example.invalid

# --- world builders ----------------------------------------------------------

# new_world <name>: a real, throwaway git repo on `main` (so the worktree-tangle
# and default-branch checks behave exactly as they do against the real
# firstmate repo) to use as FM_ROOT_OVERRIDE, plus an empty FM_HOME with
# state/, data/, config/, and a fakebin. Echoes "<root-dir>|<home-dir>|<fakebin>".
new_world() {
  local name=$1 w root home fakebin
  w="$TMP_ROOT/$name"
  root="$w/root"
  home="$w/home"
  fakebin="$w/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  printf '%s|%s|%s\n' "$root" "$home" "$fakebin"
}

# make_fake_toolchain <fakebin>: every tool fm-bootstrap.sh detects, present
# and compatible, so its own detect-only section stays quiet except where a
# test deliberately breaks one. Mirrors fm-bootstrap.test.sh's fixture.
make_fake_toolchain() {
  local fakebin=$1
  fm_fake_exit0 "$fakebin" tmux node gh-axi chrome-devtools-axi lavish-axi
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake) 2026-06-27T00:02:18Z'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' manual > "${fakebin%/*}/home-placeholder" 2>/dev/null || true
}

make_fake_tasks_axi_compact() {
  local fakebin=$1
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_TASKS_AXI_LOG:-}
[ -n "$log" ] && printf '%s\n' "$*" >> "$log"
case "${1:-}" in
  --version|-v|-V)
    printf '%s\n' '0.2.3'
    exit 0
    ;;
  update)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' 'usage: tasks-axi update <id> [--archive-body]'
      exit 0
    fi
    ;;
  mv)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' 'usage: tasks-axi mv <dest> [<id>...]'
      exit 0
    fi
    ;;
  list)
    case "$*" in
      *'--fields '*'body'*|*'--fields='*'body'*)
        printf '%s\n' 'unexpected body field requested' >&2
        exit 9
        ;;
    esac
    case "$*" in *'--limit 80'*) : ;; *) printf '%s\n' 'missing compact limit' >&2; exit 9 ;; esac
    case "$*" in *'--file '*) : ;; *) printf '%s\n' 'missing explicit backlog file' >&2; exit 9 ;; esac
    cat <<'OUT'
count: 2
tasks[2]{id,state,kind,repo,title,blocked_by,hold_kind,hold_reason}:
  compact-startup,in_flight,ship,firstmate,Compact startup digest,none,captain,captain choice pending
  blocked-followup,queued,scout,firstmate,Follow compact startup,compact-startup,"-","-"
help[2]:
  - Run `tasks-axi show <id> --full` for full notes on a task
  - Run `tasks-axi ready` to see unblocked queued work
OUT
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tasks-axi"
}

# make_fake_ps_claude <fakebin>: harness_pid()/holder_alive() (fm-lock.sh) walk
# `ps` output looking for a harness command name; this fake reports EVERY
# queried pid as a live `claude` harness, so the very first ancestry check
# (this test process's own pid) matches and lock acquisition succeeds
# deterministically. Mirrors fm-grok-harness.test.sh's fake ps.
make_fake_ps_claude() {
  local fakebin=$1
  make_fake_ps_harness "$fakebin" claude
}

# real_ps_path <fakebin>: the first ps on PATH that is not the fake itself, so a
# narrow passthrough never hardcodes a location.
real_ps_path() {
  local fakebin=$1 dir
  local IFS=:
  for dir in $PATH; do
    [ "$dir" = "$fakebin" ] && continue
    [ -x "$dir/ps" ] && { printf '%s\n' "$dir/ps"; return 0; }
  done
  return 1
}

make_fake_ps_harness() {
  local fakebin=$1 harness=$2 real_ps
  real_ps=$(real_ps_path "$fakebin") || real_ps=""
  # The harness-ancestry queries are faked, and ONLY fm_pid_identity's
  # `-o lstart= -o command=` query passes through to the real ps, so a test that
  # records a genuine live-process identity still reads back a match. Every other
  # query keeps failing as before, so no other test becomes host-dependent.
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
harness=\${FM_FAKE_HARNESS:-claude}
real_ps=$(printf '%q' "$real_ps")
case "\$*" in
  *"comm="*) printf '/usr/local/bin/%s\n' "\$harness"; exit 0 ;;
  *"args="*) printf '%s\n' "\$harness"; exit 0 ;;
  *"-o lstart="*) [ -n "\$real_ps" ] || exit 1; exec "\$real_ps" "\$@" ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$harness" > "$fakebin/.harness-name"
}

make_fake_ps_pi_holder() {
  local fakebin=$1 holder_pid=$2
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
pid=""
prev=""
for arg in "\$@"; do
  [ "\$prev" = "-p" ] && pid="\$arg"
  prev="\$arg"
done
case "\$*" in
  *"comm="*)
    if [ "\$pid" = "$holder_pid" ]; then
      printf '/usr/local/bin/pi\n'
    else
      printf '/bin/zsh\n'
    fi
    exit 0
    ;;
  *"args="*)
    if [ "\$pid" = "$holder_pid" ]; then
      printf 'pi\n'
    else
      printf 'zsh\n'
    fi
    exit 0
    ;;
  *"ppid="*) printf '%s\n' "$holder_pid"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

# make_fake_tmux <fakebin> <live-target>: display-message succeeds only for
# the given "session:window" target - the exact primitive
# fm_backend_target_exists uses for a tmux endpoint liveness read.
make_fake_tmux() {
  local fakebin=$1 live=$2
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  display-message)
    target=""
    prev=""
    for a in "\$@"; do
      [ "\$prev" = "-t" ] && target="\$a"
      prev="\$a"
    done
    [ "\$target" = "$live" ] && { printf '%%1\n'; exit 0; }
    exit 1
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
}

# make_fake_herdr <fakebin> <live-pane>: `herdr pane get <pane>` succeeds only
# for the given pane id - the exact primitive fm_backend_target_exists uses
# for a herdr endpoint liveness read. No version/server-start calls: a
# liveness check must never auto-start a server (fm-backend.sh's contract).
make_fake_herdr() {
  local fakebin=$1 live=$2
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = pane ] && [ "\${2:-}" = get ]; then
  [ "\${3:-}" = "$live" ] && exit 0
  exit 1
fi
exit 1
SH
  chmod +x "$fakebin/herdr"
}

# run_session_start <home> <root> <path>
# Drop every harness env marker from bin/fm-harness.sh detect_own so the
# surrounding interactive shell cannot leak past the suite's fake ps harness.
# Markers today: CLAUDECODE (claude), PI_CODING_AGENT (pi), GROK_AGENT (grok),
# JCODE_ACTIVE_PROVIDER / JCODE_RUNTIME_PROVIDER (jcode).
# codex and opencode have no env markers (ancestry only). Without this, a local
# claude/pi/grok/jcode session fails cases that pin a different fake harness while CI
# (no ambient markers) still passes.
run_session_start() {
  local home=$1 root=$2 path=$3
  env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    -u JCODE_ACTIVE_PROVIDER -u JCODE_RUNTIME_PROVIDER \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$path" \
    "$SESSION_START"
}

hash_file_for_test() {
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print "sha256:" $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print "sha256:" $1}'
  else
    cksum "$file" | awk '{print "cksum:" $1 ":" $2}'
  fi
}

install_pi_turnend_extension_fixture() {
  local root=$1
  mkdir -p "$root/.pi/extensions"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$root/.pi/extensions/fm-primary-turnend-guard.ts"
}

install_pi_watch_extension_fixture() {
  local root=$1
  mkdir -p "$root/.pi/extensions"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$root/.pi/extensions/fm-primary-pi-watch.ts"
}

write_pi_watch_loaded_marker() {
  local home=$1 root=$2 pid=$3 version
  version=$(hash_file_for_test "$root/.pi/extensions/fm-primary-pi-watch.ts")
  printf '%s\n%s\n' "$version" "$pid" > "$home/state/.pi-watch-extension-loaded"
}

write_pi_turnend_loaded_marker() {
  local home=$1 root=$2 pid=$3 version
  version=$(hash_file_for_test "$root/.pi/extensions/fm-primary-turnend-guard.ts")
  printf '%s\n%s\n' "$version" "$pid" > "$home/state/.pi-turnend-extension-loaded"
}

write_pi_loaded_markers() {
  local home=$1 root=$2 pid=$3
  write_pi_watch_loaded_marker "$home" "$root" "$pid"
  write_pi_turnend_loaded_marker "$home" "$root" "$pid"
}

# --- cross-session stall surfacing -------------------------------------------

# A scout task with a live tmux window and no no-mistakes run resolves its
# current state from the status log's last verb (fm-crew-state.sh), so a
# blocked:/paused: last line makes fm-crew-state.sh report blocked/paused - the
# exact input print_cross_session_stalls scans. make_fake_tmux has no
# capture-pane, so the pane reads not-busy and the log mapping wins.
seed_stall_scout() {
  local home=$1 id=$2 window=$3 last=$4 wt="$1/wt-$2"
  git init -q -b main "$wt"
  git -C "$wt" commit -q --allow-empty -m init
  printf 'window=%s\nworktree=%s\nkind=scout\nbackend=tmux\n' "$window" "$wt" > "$home/state/$id.meta"
  printf 'working: started\n%s\n' "$last" > "$home/state/$id.status"
}

test_cross_session_stall_blocked_surfaces_any_age() {
  local rec root home fakebin out stall_section banner_line work_line
  rec=$(new_world stall-blocked)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_tmux "$fakebin" "fm-sess:blk"
  seed_stall_scout "$home" task-blk "fm-sess:blk" "blocked: shared Claude account usage-window limit"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "STALLED WORKERS FROM A PRIOR SESSION (act on these first)" \
    "blocked worker did not surface the prominent cross-session stall banner"
  stall_section=$(printf '%s\n' "$out" | awk '/STALLED WORKERS FROM A PRIOR SESSION/{flag=1}/Work under way/{flag=0}flag')
  assert_contains "$stall_section" "BLOCKED" "blocked worker not labeled BLOCKED in the stall banner"
  assert_contains "$stall_section" "task-blk" "blocked worker id missing from the stall banner"
  assert_contains "$stall_section" "needs firstmate action" "blocked worker not marked as needing firstmate action"

  # The banner precedes the per-task status tails, not buried inside them.
  banner_line=$(printf '%s\n' "$out" | grep -n 'STALLED WORKERS FROM A PRIOR SESSION' | head -1 | cut -d: -f1)
  work_line=$(printf '%s\n' "$out" | grep -n '^Work under way' | head -1 | cut -d: -f1)
  [ -n "$banner_line" ] && [ -n "$work_line" ] && [ "$banner_line" -lt "$work_line" ] \
    || fail "stall banner did not precede the per-task status tails: $out"

  pass "a blocked worker from a prior session surfaces prominently, regardless of age"
}

test_cross_session_stall_paused_threshold() {
  local rec root home fakebin out banner
  rec=$(new_world stall-paused)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_tmux "$fakebin" "fm-sess:old"

  # An OLD pause (status mtime far in the past) must surface.
  seed_stall_scout "$home" task-old "fm-sess:old" "paused: rate-limit reset window until 18:00"
  touch -t 202601010000 "$home/state/task-old.status"

  out=$(FM_SESSION_START_STALL_THRESHOLD=1800 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "STALLED WORKERS FROM A PRIOR SESSION" "old pause did not surface the stall banner"
  banner=$(printf '%s\n' "$out" | awk '/STALLED WORKERS FROM A PRIOR SESSION/{flag=1}/Work under way/{flag=0}flag')
  assert_contains "$banner" "PAUSED" "old pause not labeled PAUSED"
  assert_contains "$banner" "task-old" "old paused worker id missing from banner"
  assert_contains "$banner" "external wait" "old pause not described as an external wait"

  pass "a paused worker older than the threshold surfaces in the stall banner"
}

test_cross_session_stall_fresh_pause_suppressed() {
  local rec root home fakebin out
  rec=$(new_world stall-fresh)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_tmux "$fakebin" "fm-sess:fresh"

  # A pause THIS session just created (fresh mtime) with a high threshold must
  # NOT nag - it is below the age gate.
  seed_stall_scout "$home" task-fresh "fm-sess:fresh" "paused: waiting on a scheduled window"

  out=$(FM_SESSION_START_STALL_THRESHOLD=99999 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_not_contains "$out" "STALLED WORKERS FROM A PRIOR SESSION" \
    "a fresh pause below the age threshold wrongly surfaced the stall banner"

  pass "a fresh pause below the age threshold stays out of the stall banner"
}

test_cross_session_stall_none_when_all_working() {
  local rec root home fakebin out
  rec=$(new_world stall-none)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_tmux "$fakebin" "fm-sess:ok"
  seed_stall_scout "$home" task-ok "fm-sess:ok" "working: still going"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_not_contains "$out" "STALLED WORKERS FROM A PRIOR SESSION" \
    "a fleet with no stalled workers wrongly emitted the stall banner"

  pass "a fleet with no paused/blocked workers emits no stall banner"
}

# --- context digest: absent vs empty vs present -----------------------------

test_context_digest_absent_empty_present() {
  local rec root home fakebin out
  rec=$(new_world context-digest)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  printf '%s\n' '- demo [no-mistakes] - a demo project (added 2026-07-01)' > "$home/data/projects.md"
  : > "$home/data/captain.md"
  # secondmates.md, captain-shared.md, and learnings.md deliberately absent

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "data/projects.md" "digest did not label the projects.md section"
  assert_contains "$out" "- demo [no-mistakes] - a demo project (added 2026-07-01)" "digest did not print projects.md content"

  assert_contains "$out" "data/captain.md" "digest did not label the captain.md section"
  assert_contains "$out" "data/captain-shared.md (shared, main-authoritative, read-only in secondmate homes)" \
    "digest did not label the shared captain section"

  assert_contains "$out" "data/secondmates.md" "digest did not label the secondmates.md section"
  assert_contains "$out" "data/learnings.md" "digest did not label the learnings.md section"

  # Exactly four context ABSENT markers (secondmates.md, captain-shared.md,
  # learnings.md; backlog.md is covered by its own test) - and the
  # present-but-empty captain.md must NOT print ABSENT.
  absent_count=$(printf '%s\n' "$out" | grep -c '^ABSENT$')
  [ "$absent_count" -eq 4 ] || fail "expected 4 ABSENT markers (secondmates.md, captain-shared.md, learnings.md, backlog.md), got $absent_count: $out"

  cap_section=$(printf '%s\n' "$out" | awk '/^data\/captain\.md$/{flag=1;next}/^data\//{flag=0}flag')
  assert_contains "$cap_section" "(present, empty)" "empty-but-present captain.md was not distinguished from ABSENT"

  pass "context digest distinguishes ABSENT, empty-but-present, and populated files"
}

# --- context digest: shape-2 trim of the two big consolidated files ----------

# Build a captain.md-shaped file: curated top, a "# Detailed standing rules
# (inlined from former topic files ...)" seam, a bulk archive middle, then
# newest dated rulings at the very end.
write_big_captain_fixture() {
  local path=$1 i
  {
    printf '# Captain\n'
    printf 'CURATED-TOP-FACT alpha\n'
    printf 'CURATED-TOP-FACT beta\n'
    printf '# Detailed standing rules (inlined from former topic files, consolidated 2026-07-26)\n'
    for i in $(seq 1 200); do printf 'ARCHIVE-MIDDLE-LINE %d\n' "$i"; done
    printf 'NEWEST-RULING autoland grant 2026-08-10\n'
    printf 'NEWEST-RULING account rotation 2026-08-11\n'
  } > "$path"
}

test_context_digest_shape2_seam_split() {
  local rec root home fakebin out cap_section
  rec=$(new_world context-shape2)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  write_big_captain_fixture "$home/data/captain.md"

  out=$(FM_SESSION_START_CONTEXT_TAIL=3 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  # Curated top above the seam is still emitted.
  assert_contains "$out" "CURATED-TOP-FACT alpha" "curated top was dropped"
  assert_contains "$out" "CURATED-TOP-FACT beta" "curated top was dropped"
  # Newest dated rulings (tail window) survive even though they are below seam.
  assert_contains "$out" "NEWEST-RULING autoland grant 2026-08-10" "newest ruling in tail window was dropped"
  assert_contains "$out" "NEWEST-RULING account rotation 2026-08-11" "newest ruling in tail window was dropped"
  # Elision notice for the omitted middle.
  assert_contains "$out" "detail omitted:" "no elision notice emitted"
  # Trimmed label with the on-demand pointer.
  assert_contains "$out" "data/captain.md (curated recent top" "trimmed label/pointer missing"
  # The bulk archive middle is elided (a middle line must not appear).
  cap_section=$(printf '%s\n' "$out" | awk '/^data\/captain\.md/{flag=1;next}/^data\/captain-shared/{flag=0}flag')
  printf '%s\n' "$cap_section" | grep -q 'ARCHIVE-MIDDLE-LINE 100' \
    && fail "middle archive line 100 was not elided: $cap_section"

  pass "context digest emits shape-2 seam split with head+tail window and elision"
}

test_context_digest_shape2_missing_seam_full_cat() {
  local rec root home fakebin out i
  rec=$(new_world context-noseam)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  # No "# Detailed learnings (inlined ...)" seam -> must fall back to full cat.
  {
    printf '# Fleet learnings\n'
    for i in $(seq 1 120); do printf 'NOSEAM-LINE %d\n' "$i"; done
  } > "$home/data/learnings.md"

  out=$(FM_SESSION_START_CONTEXT_TAIL=3 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  # Every line present (full cat), no elision notice, plain label.
  assert_contains "$out" "NOSEAM-LINE 1" "missing-seam file was truncated at head"
  assert_contains "$out" "NOSEAM-LINE 60" "missing-seam file elided the middle instead of full cat"
  assert_contains "$out" "NOSEAM-LINE 120" "missing-seam file dropped the tail"
  printf '%s\n' "$out" | awk '/^data\/learnings\.md/{flag=1;next}/^====/{flag=0}flag' \
    | grep -q 'detail omitted:' && fail "missing-seam file wrongly emitted an elision notice"

  pass "context digest falls back to full cat when the consolidation seam is absent"
}

test_context_digest_shape2_absent_and_full_escape_hatch() {
  local rec root home fakebin out
  rec=$(new_world context-shape2-absent)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  # captain.md deliberately ABSENT; learnings.md present with a seam.
  write_big_captain_fixture "$home/data/learnings-src"
  sed 's/# Detailed standing rules/# Detailed learnings/' "$home/data/learnings-src" > "$home/data/learnings.md"
  rm -f "$home/data/learnings-src"

  # Escape hatch forces a FULL cat of learnings.md (middle line reappears).
  out=$(FM_SESSION_START_LEARNINGS_FULL=1 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  # ABSENT captain.md still prints the explicit marker under its plain label.
  cap_section=$(printf '%s\n' "$out" | awk '/^data\/captain\.md$/{flag=1;next}/^data\//{flag=0}flag')
  assert_contains "$cap_section" "ABSENT" "absent captain.md did not print ABSENT under the trimmed helper"
  # Forced-full learnings.md shows the archive middle and no elision notice.
  assert_contains "$out" "ARCHIVE-MIDDLE-LINE 100" "FM_SESSION_START_LEARNINGS_FULL did not force a full cat"
  printf '%s\n' "$out" | awk '/^data\/learnings\.md/{flag=1;next}/^====/{flag=0}flag' \
    | grep -q 'detail omitted:' && fail "forced-full learnings.md wrongly emitted an elision notice"

  pass "context digest keeps ABSENT semantics and honors the force-full escape hatch"
}

# --- lock refusal: read-only path --------------------------------------------

test_lock_refusal_read_only_path() {
  local rec root home fakebin holder_pid out status
  rec=$(new_world lock-refusal)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  # A live secondmate meta with a window pointed at nothing real - if the
  # bootstrap sweep's secondmate_sync ran (a MUTATING step), it would try to
  # fast-forward this "home" and/or report a SECONDMATE_SYNC/NUDGE_SECONDMATES
  # line. Absence of any such line is this test's proof that
  # FM_BOOTSTRAP_DETECT_ONLY=1 actually suppressed the mutating sweep.
  mkdir -p "$home/other-secondmate/state"
  fm_write_secondmate_meta "$home/state/sm-x.meta" "$home/other-secondmate" "firstmate:fm-sm-x" alpha
  append_wake "$home/state" signal sm-x "done: surfaced before refusal" || fail "seed wake failed"
  git -C "$root" checkout -q -B fm/read-only-tangle

  sleep 300 &
  holder_pid=$!
  printf '%s\n' "$holder_pid" > "$home/state/.lock"

  status=0
  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH") || status=$?
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  expect_code 0 "$status" "fm-session-start.sh must exit 0 even on a lock refusal"
  assert_contains "$out" "READ-ONLY SESSION" "read-only banner missing on lock refusal"
  assert_contains "$out" "another live firstmate session holds the lock" "read-only banner did not surface fm-lock.sh's own error text"
  assert_contains "$out" "Skipping every mutating step" "read-only banner did not explain what was skipped"
  assert_contains "$out" "skipped (read-only session)" "wake-queue section did not report itself skipped"
  assert_contains "$out" "WATCHER DOWN - SUPERVISION IS OFF" "read-only guard did not surface watcher-liveness alarm"
  assert_contains "$out" "queued wakes pending - left untouched for the session holding the fleet lock" "read-only guard did not leave queued wakes to the lock holder"
  assert_contains "$out" "TANGLE: primary checkout on feature branch 'fm/read-only-tangle'" "read-only bootstrap did not surface the tangle diagnostic"
  assert_contains "$out" "read-only session must leave restore work" "read-only tangle diagnostic did not explain restore ownership"
  assert_contains "$out" "Stay read-only: do not arm" "read-only next step did not block direct watcher repair"
  assert_not_contains "$out" "drain them with bin/fm-wake-drain.sh" "read-only guard printed a mutating drain instruction"
  assert_not_contains "$out" "After draining queued wakes" "read-only guard printed a drain-then-rearm instruction"
  assert_not_contains "$out" "run bin/fm-watch-arm.sh" "read-only guard printed a mutating watcher-arm instruction"
  assert_not_contains "$out" "git -C $root checkout main" "read-only bootstrap printed a state-changing checkout remediation"

  # Detect-only bootstrap diagnostics still ran (the fakebin's PATH excludes
  # tasks-axi, so bootstrap's own read-only tool-detection line fires
  # deterministically regardless of what is installed on the test host).
  assert_contains "$out" "MISSING: tasks-axi (install:" "detect-only bootstrap diagnostics did not run on the read-only path"

  # The mutating secondmate sweep must NOT have run: no SECONDMATE_SYNC/
  # NUDGE_SECONDMATES line, and the sowed secondmate meta's target dir is
  # untouched (fm-ff-lib would have tried to fast-forward it otherwise).
  assert_not_contains "$out" "SECONDMATE_SYNC" "mutating secondmate sweep ran during a lock refusal"
  assert_not_contains "$out" "NUDGE_SECONDMATES" "mutating secondmate sweep ran during a lock refusal"

  # The rest of the digest (read-only-safe) still completed.
  assert_contains "$out" "FLEET STATE" "fleet-state digest section missing on the read-only path"
  assert_contains "$out" "NEXT STEP" "closing reminder missing on the read-only path"

  pass "a lock refusal prints a loud read-only banner, skips every mutating step, and still completes the digest"
}

# --- output ordering ----------------------------------------------------------

test_output_ordering_diagnostics_lead() {
  local rec root home fakebin out lock_line boot_line wake_line context_line fleet_line next_line
  rec=$(new_world ordering)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  # Force a MISSING diagnostic line so the bootstrap section is non-trivial.
  rm -f "$fakebin/node"

  printf 'window=fm-sess:w1\nkind=ship\n' > "$home/state/task-a.meta"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  lock_line=$(printf '%s\n' "$out" | grep -n '^LOCK$' | head -1 | cut -d: -f1)
  boot_line=$(printf '%s\n' "$out" | grep -n '^BOOTSTRAP$' | head -1 | cut -d: -f1)
  wake_line=$(printf '%s\n' "$out" | grep -n '^WAKE QUEUE$' | head -1 | cut -d: -f1)
  context_line=$(printf '%s\n' "$out" | grep -n '^CONTEXT$' | head -1 | cut -d: -f1)
  fleet_line=$(printf '%s\n' "$out" | grep -n '^FLEET STATE$' | head -1 | cut -d: -f1)
  next_line=$(printf '%s\n' "$out" | grep -n '^NEXT STEP$' | head -1 | cut -d: -f1)

  if [ -z "$lock_line" ] || [ -z "$boot_line" ] || [ -z "$wake_line" ] || [ -z "$context_line" ] || [ -z "$fleet_line" ] || [ -z "$next_line" ]; then
    fail "one or more section headers missing from digest: $out"
  fi

  [ "$lock_line" -lt "$boot_line" ] || fail "LOCK did not precede BOOTSTRAP"
  [ "$boot_line" -lt "$wake_line" ] || fail "BOOTSTRAP did not precede WAKE QUEUE"
  [ "$wake_line" -lt "$context_line" ] || fail "WAKE QUEUE did not precede CONTEXT"
  [ "$context_line" -lt "$fleet_line" ] || fail "CONTEXT did not precede FLEET STATE"
  [ "$fleet_line" -lt "$next_line" ] || fail "FLEET STATE did not precede NEXT STEP"

  missing_line=$(printf '%s\n' "$out" | grep -n 'MISSING: node' | head -1 | cut -d: -f1)
  [ -n "$missing_line" ] || fail "MISSING diagnostic did not appear at all"
  [ "$missing_line" -lt "$fleet_line" ] || fail "actionable MISSING diagnostic was buried after the bulk fleet-state digest"

  pass "digest sections are ordered diagnostics-first, bulk-context-last"
}

test_herdr_backend_diagnostics_follow_real_session_start() {
  local mode rec root home fakebin mask out
  for mode in configured autodetected; do
    rec=$(new_world "herdr-$mode")
    IFS='|' read -r root home fakebin <<EOF
$rec
EOF
    make_fake_toolchain "$fakebin"
    make_fake_ps_claude "$fakebin"
    rm -f "$fakebin/tmux"
    fm_fake_exit0 "$fakebin" herdr jq
    printf '%s\n' manual > "$home/config/backlog-backend"
    mask="$home/mask-tmux.bash"
    cat > "$mask" <<'SH'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = tmux ]; then
    return 1
  fi
  builtin command "$@"
}
SH
    if [ "$mode" = configured ]; then
      printf '%s\n' herdr > "$home/config/backend"
      out=$(TMUX='' HERDR_ENV='' BASH_ENV="$mask" run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
      assert_not_contains "$out" "NOTICE: auto-detected herdr runtime" \
        "an explicit Herdr home should not be reported as auto-detected"
    else
      out=$(TMUX='' HERDR_ENV=1 BASH_ENV="$mask" run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
      assert_contains "$out" "NOTICE: auto-detected herdr runtime (HERDR_ENV=1)" \
        "session start did not preserve the Herdr runtime auto-detection fallback"
    fi
    assert_contains "$out" "SESSION START - $home" "the real session-start path did not run in the throwaway home"
    assert_not_contains "$out" "MISSING: tmux" "Herdr session start falsely required masked tmux"
    assert_not_contains "$out" "MISSING: herdr" "Herdr session start missed its available session CLI"
    assert_not_contains "$out" "MISSING: jq" "Herdr session start missed its available JSON dependency"
    assert_not_contains "$out" "MISSING: treehouse" "Herdr session start missed its available worktree provider"
  done
  pass "session start: configured and auto-detected Herdr homes never require tmux"
}

# --- Gap 3: paired current-state + event with freshness ----------------------

# A scout with an idle pane and a blocked status line: current state falls to the
# status-log source (no run, no busy pane), the event is paired with the current
# state and its freshness age, and it is NOT marked OLD because there is no
# fresher authoritative source than the status log itself.
test_gap3_pairs_current_state_and_event_no_old_for_status_log_source() {
  local rec root home fakebin out
  rec=$(new_world gap3-paired)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_tmux "$fakebin" "fm-sess:g3"
  seed_stall_scout "$home" task-g3 "fm-sess:g3" "blocked: waiting on captain access"
  # Age the status file well past the OLD threshold; source stays status-log so
  # OLD must NOT fire (nothing fresher than the event to trust).
  touch -t 202601010000 "$home/state/task-g3.status"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "current: blocked" "digest did not pair a reconciled current state with the task"
  assert_contains "$out" "current: blocked · source: status-log · event(" \
    "digest did not render the paired current-state + event shape with a freshness age"
  # OLD marker must not appear for a status-log-sourced current state.
  printf '%s\n' "$out" | grep -F 'current: blocked' | grep -q '(OLD)' \
    && fail "OLD marker fired for a status-log-sourced current state: $out"

  pass "Gap 3: session-start pairs current state with the event and suppresses OLD when no fresher source exists"
}

# The disagree case in the digest: a running run-step over a real worktree while
# the event still says needs-decision, aged past the threshold. The paired line
# must carry SUPERSEDED and OLD (current state has a fresher run-step source).
test_gap3_digest_marks_superseded_and_old_on_disagree() {
  local rec root home fakebin out wt head
  rec=$(new_world gap3-superseded)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_tmux "$fakebin" "fm-sess:g3s"
  # A real worktree on the crew branch so run-step attribution binds.
  wt="$home/wt-task-g3s"
  git init -q -b main "$wt"
  git -C "$wt" commit -q --allow-empty -m init
  git -C "$wt" checkout -q -b fm/task-g3s
  head=$(git -C "$wt" rev-parse HEAD)
  printf 'window=fm-sess:g3s\nworktree=%s\nkind=ship\nbackend=tmux\n' "$wt" > "$home/state/task-g3s.meta"
  printf 'needs-decision: choose an API shape\n' > "$home/state/task-g3s.status"
  touch -t 202601010000 "$home/state/task-g3s.status"
  # Fake no-mistakes returning a running run whose head matches the worktree.
  cat > "$fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  axi)
    shift
    case "\${1:-}" in
      status)
        cat <<'RUN'
run:
  id: "01RUN"
  branch: fm/task-g3s
  status: running
  head: "$head"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
RUN
        ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/no-mistakes"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "current: working · source: run-step · SUPERSEDED" \
    "digest did not surface SUPERSEDED when the run-step moved past the event"
  printf '%s\n' "$out" | grep -F 'current: working · source: run-step' | grep -q '(OLD)' \
    || fail "digest did not mark the stale event OLD on a disagree with a fresher source: $out"

  pass "Gap 3: session-start marks SUPERSEDED and OLD when the current state disagrees with a stale event"
}

# --- status tail bounding -----------------------------------------------------

test_status_tail_bounding() {
  local rec root home fakebin out
  rec=$(new_world status-tail)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_tmux "$fakebin" "fm-sess:live"

  printf 'window=fm-sess:live\nkind=ship\n' > "$home/state/task-a.meta"
  printf 'working: step 1\nworking: step 2\nworking: step 3\nworking: step 4\nworking: step 5\nworking: step 6\nworking: step 7\n' \
    > "$home/state/task-a.status"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "working: step 7" "default status tail missing the most recent line"
  assert_contains "$out" "working: step 3" "default status tail (5 lines) missing an expected recent line"
  assert_not_contains "$out" "working: step 1" "default status tail (5 lines) leaked an older line"
  assert_contains "$out" "$home/state/task-a.status" "digest did not print the full status log path for a deeper read"
  assert_contains "$out" "Do NOT bulk-read state/*.status now either: their bounded tails were just" "closing reminder does not distinguish bounded status tails"
  assert_not_contains "$out" "state/*.status now - they were just" "closing reminder still describes status logs as fully printed"

  out=$(FM_SESSION_START_STATUS_TAIL=2 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "working: step 7" "FM_SESSION_START_STATUS_TAIL=2 tail missing the most recent line"
  assert_not_contains "$out" "working: step 5" "FM_SESSION_START_STATUS_TAIL=2 did not bound the tail to 2 lines"

  pass "status tail is bounded to the configured line count, with the full log path always printed"
}

test_orphan_status_logs_are_printed() {
  local rec root home fakebin out matched_count orphan_count
  rec=$(new_world orphan-status)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  printf 'kind=ship\n' > "$home/state/task-a.meta"
  printf 'matched: surfaced once\n' > "$home/state/task-a.status"
  printf 'orphan: step 1\norphan: step 2\norphan: step 3\norphan: step 4\norphan: step 5\norphan: step 6\n' \
    > "$home/state/task-orphan.status"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "Orphan status logs (state/*.status without matching .meta)" "digest did not label orphan status logs"
  assert_contains "$out" "--- task-orphan ---" "digest did not print the orphan status id"
  assert_contains "$out" "orphan: step 6" "orphan status tail missing the newest line"
  assert_not_contains "$out" "orphan: step 1" "orphan status tail was not bounded"
  assert_contains "$out" "$home/state/task-orphan.status" "orphan status tail did not print the full log path"

  matched_count=$(printf '%s\n' "$out" | grep -F -c 'matched: surfaced once')
  orphan_count=$(printf '%s\n' "$out" | grep -F -c 'orphan: step 6')
  # A task WITH meta gets the Gap-3 paired current-state+event header line in
  # addition to its raw status tail, so its newest event text appears exactly
  # twice (paired header + tail), never more. An orphan status log (no meta, no
  # current state to reconcile) is not paired, so its newest line appears once.
  [ "$matched_count" -eq 2 ] || fail "matched status log expected twice (paired header + tail), got $matched_count: $out"
  [ "$orphan_count" -eq 1 ] || fail "orphan status log was printed $orphan_count times: $out"

  pass "orphan status logs are printed once with bounded tails"
}

# --- endpoint liveness: tmux and herdr, live and dead ------------------------

test_endpoint_liveness_tmux() {
  local rec root home fakebin out
  rec=$(new_world liveness-tmux)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_tmux "$fakebin" "fm-sess:live-window"

  printf 'window=fm-sess:live-window\nkind=ship\n' > "$home/state/task-live.meta"
  printf 'window=fm-sess:dead-window\nkind=ship\n' > "$home/state/task-dead.meta"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "endpoint: alive (backend=tmux window=fm-sess:live-window)" "live tmux endpoint not reported alive"
  assert_contains "$out" "endpoint: dead (backend=tmux window=fm-sess:dead-window)" "dead tmux endpoint not reported dead"

  pass "tmux endpoint liveness is reported per task: alive for a live window, dead for a gone one"
}

test_endpoint_liveness_herdr() {
  local rec root home fakebin out
  rec=$(new_world liveness-herdr)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_herdr "$fakebin" "p-live"

  printf 'window=sess:p-live\nkind=ship\nbackend=herdr\n' > "$home/state/task-live.meta"
  printf 'window=sess:p-dead\nkind=ship\nbackend=herdr\n' > "$home/state/task-dead.meta"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "endpoint: alive (backend=herdr window=sess:p-live)" "live herdr endpoint not reported alive"
  assert_contains "$out" "endpoint: dead (backend=herdr window=sess:p-dead)" "dead herdr endpoint not reported dead"

  pass "herdr endpoint liveness is reported per task: alive for a live pane, dead for a gone one"
}

# --- composition: real scripts run, not reimplemented ------------------------

test_composition_invokes_real_scripts() {
  local rec root home fakebin out
  rec=$(new_world composition)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  rm -f "$fakebin/node"

  printf 'needs-decision: pick a library\n' > "$home/state/task-z.status"
  append_wake "$home/state" signal task-z.status "needs-decision: pick a library"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  # fm-lock.sh's own exact success text.
  assert_contains "$out" "lock acquired: harness pid" "fm-lock.sh's real output did not appear (composition, not reimplementation)"
  # fm-bootstrap.sh's own exact MISSING-tool line format.
  assert_contains "$out" "MISSING: node (install:" "fm-bootstrap.sh's real detect line did not appear verbatim"
  # fm-wake-drain.sh's real drained record (raw tab-separated queue line).
  assert_contains "$out" "$(printf 'signal\ttask-z.status\tneeds-decision: pick a library')" "fm-wake-drain.sh's real drained record did not appear"
  assert_contains "$out" "wake annotation: latest wake-EVENT observed at drain, not current state: task-z.status: needs-decision: pick a library" "fm-session-start.sh did not preserve the drain's separate annotation line"

  pass "fm-session-start.sh composes the real fm-lock.sh, fm-bootstrap.sh, and fm-wake-drain.sh output verbatim"
}

# --- fleet-state digest: compact backlog rendering --------------------------

write_long_body_backlog() {
  local path=$1
  cat > "$path" <<'EOF'
# Backlog

## In flight
- [ ] compact-startup - Compact startup digest (repo: firstmate) (kind: ship) (since 2026-07-15) (hold: captain choice pending) (hold-kind: captain)
  OVERSIZED-BODY-LINE current startup leaks task note bodies into the session digest.
  Another long body line that should not be printed after the fix.

## Queued
- [ ] blocked-followup - Follow compact startup blocked-by: compact-startup - waits for implementation (repo: firstmate) (kind: scout) (since 2026-07-15)
  QUEUED-BODY-LINE this is another long multiline note.

## Done
EOF
}

test_backlog_compact_tasks_axi_omits_bodies_and_keeps_metadata() {
  local rec root home fakebin out log
  rec=$(new_world backlog-compact-tasks-axi)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_tasks_axi_compact "$fakebin"
  make_fake_ps_claude "$fakebin"
  write_long_body_backlog "$home/data/backlog.md"
  mkdir -p "$home/projects/firstmate"
  printf 'window=fm-sess:compact\nworktree=%s\nproject=firstmate\nkind=ship\n' "$home/projects/firstmate" \
    > "$home/state/compact-startup.meta"
  log="$home/tasks-axi.log"

  out=$(FM_FAKE_TASKS_AXI_LOG="$log" run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "compact backlog listing (tasks-axi; max 80 item(s); task bodies omitted)" \
    "compatible tasks-axi backend did not render the compact backlog listing"
  assert_contains "$out" "tasks[2]{id,state,kind,repo,title,blocked_by,hold_kind,hold_reason}:" \
    "tasks-axi compact listing omitted the expected structured field header"
  assert_contains "$out" "compact-startup,in_flight,ship,firstmate,Compact startup digest,none,captain,captain choice pending" \
    "tasks-axi compact listing omitted in-flight identity, state, or hold metadata"
  assert_contains "$out" 'blocked-followup,queued,scout,firstmate,Follow compact startup,compact-startup,"-","-"' \
    "tasks-axi compact listing omitted blocked-by metadata"
  assert_not_contains "$out" "OVERSIZED-BODY-LINE" "tasks-axi compact digest leaked an in-flight task body"
  assert_not_contains "$out" "QUEUED-BODY-LINE" "tasks-axi compact digest leaked a queued task body"
  assert_contains "$out" "--- compact-startup ---" "in-flight meta identity disappeared from startup recovery digest"
  assert_contains "$out" "worktree=$home/projects/firstmate" "in-flight recovery worktree identity disappeared from startup digest"
  assert_contains "$out" "Full task bodies remain available on demand: tasks-axi show <id> --full" \
    "compact digest omitted the full-body lookup pointer"
  assert_grep "list --file $home/data/backlog.md --limit 80 --fields blocked_by,hold_kind,hold_reason" "$log" \
    "session start did not ask tasks-axi for the bounded compact field set"

  pass "compatible tasks-axi backlog rendering is compact, bounded, and preserves recovery metadata"
}

test_backlog_compact_manual_backend_skips_indented_bodies() {
  local rec root home fakebin out
  rec=$(new_world backlog-compact-manual)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  printf '%s\n' manual > "$home/config/backlog-backend"
  write_long_body_backlog "$home/data/backlog.md"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "compact backlog listing (manual backend; max 80 item(s); indented task bodies omitted)" \
    "manual backend did not use compact title-line rendering"
  assert_contains "$out" "## In flight" "manual compact rendering omitted the in-flight section heading"
  assert_contains "$out" "- [ ] compact-startup - Compact startup digest" \
    "manual compact rendering omitted the in-flight title line"
  assert_contains "$out" "(hold: captain choice pending) (hold-kind: captain)" \
    "manual compact rendering omitted hold metadata"
  assert_contains "$out" "blocked-by: compact-startup - waits for implementation" \
    "manual compact rendering omitted blocker metadata"
  assert_not_contains "$out" "OVERSIZED-BODY-LINE" "manual compact digest leaked an in-flight task body"
  assert_not_contains "$out" "QUEUED-BODY-LINE" "manual compact digest leaked a queued task body"
  assert_contains "$out" "(shown 2 of 2 backlog item title line(s))" \
    "manual compact rendering did not report its bound accounting"
  assert_contains "$out" "or data/backlog.md" "manual compact digest omitted the data/backlog.md full-body pointer"

  pass "manual backlog rendering prints only title lines with hold and blocker metadata"
}

test_backlog_compact_tasks_axi_unavailable_uses_manual_fallback() {
  local rec root home fakebin out
  rec=$(new_world backlog-compact-unavailable)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  write_long_body_backlog "$home/data/backlog.md"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "compact backlog listing (tasks-axi unavailable or incompatible; max 80 item(s); indented task bodies omitted)" \
    "unavailable tasks-axi did not fall back to compact title-line rendering"
  assert_contains "$out" "- [ ] compact-startup - Compact startup digest" \
    "unavailable tasks-axi fallback omitted a backlog title line"
  assert_not_contains "$out" "OVERSIZED-BODY-LINE" "unavailable tasks-axi fallback leaked an in-flight task body"

  pass "unavailable or incompatible tasks-axi falls back to compact manual backlog rendering"
}

# --- fleet-state digest: no in-flight tasks ----------------------------------

test_fleet_digest_empty_fleet() {
  local rec root home fakebin out
  rec=$(new_world empty-fleet)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "(none)" "empty fleet did not report (none) for in-flight tasks"
  assert_contains "$out" "absent" "empty fleet's AFK section did not report absent"

  assert_not_contains "$out" "Finished work still waiting to merge" \
    "an empty merge queue must stay silent in the fleet digest"

  pass "an empty fleet reports (none) for in-flight tasks and an absent AFK flag"
}

# The release-on-pushed safety guard must be structural: a non-empty merge queue is
# surfaced by the digest itself, not only by remembering to run the CLI.
test_fleet_digest_surfaces_merge_queue() {
  local rec root home fakebin out
  rec=$(new_world merge-queue-line)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' task-q /proj fm/q c1 main url-q > "$home/data/merge-queue.tsv"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "Finished work still waiting to merge" \
    "a non-empty merge queue was not surfaced in the fleet digest"
  assert_contains "$out" "1 finished branch(es) are pushed but not merged yet" \
    "the merge-queue digest line did not report the queued count"

  pass "a non-empty merge queue is surfaced as one bounded fleet-digest line"
}

# Problem-B drift flag: an id that is BOTH in the merge queue AND still has a
# live state/<id>.meta is surfaced, so a stale queued head against a newer live
# pr_head is caught rather than sticking forever.
test_fleet_digest_flags_merge_queue_drift() {
  local rec root home fakebin out
  rec=$(new_world merge-queue-drift)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' task-drift /proj fm/drift c1 main url-drift > "$home/data/merge-queue.tsv"
  # A live meta for the SAME id: this is the drift the digest must flag.
  fm_write_meta "$home/state/task-drift.meta" "window=fm:0" "worktree=/wt" "pr_head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "task-drift" \
    "a queued id with a live task record was not flagged as drift"
  assert_contains "$out" "still have a live task record" \
    "the drift line's reconcile guidance was missing"

  pass "a queued id that still has a live task record is flagged as merge-queue drift"
}

# An entry with no live meta must NOT trip the drift flag.
test_fleet_digest_no_drift_when_meta_absent() {
  local rec root home fakebin out
  rec=$(new_world merge-queue-no-drift)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' task-clean /proj fm/clean c1 main url-clean > "$home/data/merge-queue.tsv"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "Finished work still waiting to merge" \
    "the merge-queue line itself must still show"
  assert_not_contains "$out" "still have a live task record" \
    "a queued id with no live task record must not be flagged as drift"

  pass "a queued id with no live task record is not flagged as drift"
}

# --- backlog drift: In flight with no live worker ----------------------------

# Drift is the deliberate INVERSE of orphan status: orphan = status-without-meta;
# drift = backlog In flight id with no live meta OR a dead endpoint. Detection
# only - one advisory line, never a backlog mutation.
write_in_flight_backlog() {
  local path=$1 id=$2
  cat > "$path" <<EOF
# Backlog

## In flight
- [ ] $id - Some in-flight task (repo: firstmate) (kind: ship) (since 2026-08-20)
  BODY line that should not affect drift parsing.

## Queued
- [ ] queued-thing - A queued task (repo: firstmate) (kind: ship) (since 2026-08-20)

## Done
EOF
}

test_backlog_drift_no_meta() {
  local rec root home fakebin out
  rec=$(new_world backlog-drift-no-meta)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  # In-flight id with NO state/<id>.meta at all: the worker vanished.
  write_in_flight_backlog "$home/data/backlog.md" "ghost-task"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "Backlog drift (In flight with no live worker)" \
    "digest did not label the backlog-drift section"
  assert_contains "$out" "BACKLOG_DRIFT: ghost-task in-flight but no live worker" \
    "an in-flight id with no meta was not flagged as drift"
  # A queued id must never trip drift, even with no meta.
  assert_not_contains "$out" "BACKLOG_DRIFT: queued-thing" \
    "a queued id must not be flagged as backlog drift"

  pass "an in-flight backlog id with no live worker is flagged BACKLOG_DRIFT"
}

test_backlog_drift_dead_endpoint() {
  local rec root home fakebin out
  rec=$(new_world backlog-drift-dead)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_tmux "$fakebin" "fm-sess:live-window"
  write_in_flight_backlog "$home/data/backlog.md" "dead-task"
  # Meta EXISTS but its recorded window is not the live one, so the endpoint reads
  # dead: still drift.
  printf 'window=fm-sess:gone-window\nkind=ship\n' > "$home/state/dead-task.meta"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "endpoint: dead (backend=tmux window=fm-sess:gone-window)" \
    "the dead endpoint precondition did not hold"
  assert_contains "$out" "BACKLOG_DRIFT: dead-task in-flight but no live worker" \
    "an in-flight id with a dead endpoint was not flagged as drift"

  pass "an in-flight backlog id whose recorded endpoint is dead is flagged BACKLOG_DRIFT"
}

test_backlog_drift_none_when_live_worker() {
  local rec root home fakebin out
  rec=$(new_world backlog-drift-live)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_tmux "$fakebin" "fm-sess:live-window"
  write_in_flight_backlog "$home/data/backlog.md" "live-task"
  # Meta with a LIVE endpoint: no drift.
  printf 'window=fm-sess:live-window\nkind=ship\n' > "$home/state/live-task.meta"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "endpoint: alive (backend=tmux window=fm-sess:live-window)" \
    "the live endpoint precondition did not hold"
  assert_contains "$out" "Backlog drift (In flight with no live worker)" \
    "digest did not label the backlog-drift section"
  assert_not_contains "$out" "BACKLOG_DRIFT: live-task" \
    "an in-flight id with a live worker was wrongly flagged as drift"

  pass "an in-flight backlog id with a live worker produces no drift line"
}

test_next_step_sources_x_mode_cadence() {
  local rec root home fakebin out
  rec=$(new_world next-step-x)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  fm_fake_exit0 "$fakebin" curl jq
  printf 'FMX_PAIRING_TOKEN=tok-next-step\n' > "$home/.env"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "FMX: X mode on" "bootstrap did not activate X mode"
  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: claude" "supervision block missing"
  assert_contains "$out" "- X mode: active" "supervision block did not mention X cadence"
  assert_contains "$out" "Follow the supervision operating instructions block above" "next step did not point back to the emitted supervision block"

  pass "session start emits X-mode cadence guidance in the harness supervision block"
}

# hold_afk_daemon_lock <home>: hold this home's away-mode daemon lock with a real
# live process and print its pid, so the digest sees a daemon that actually owns
# supervision. The identity file is what fm_afk_daemon_alive matches.
hold_afk_daemon_lock() {
  local home=$1 pid identity
  sleep 120 >/dev/null 2>&1 &
  pid=$!
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-pid-lib.sh" "$pid") || {
    kill "$pid" 2>/dev/null || true
    return 1
  }
  mkdir -p "$home/state/.supervise-daemon.lock"
  printf '%s\n' "$pid" > "$home/state/.supervise-daemon.lock/pid"
  printf '%s\n' "$identity" > "$home/state/.supervise-daemon.lock/pid-identity"
  printf '%s\n' "$pid"
}

test_next_step_afk_delegates_to_daemon() {
  local rec root home fakebin out daemon_pid
  rec=$(new_world next-step-afk)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  : > "$home/state/.afk"
  daemon_pid=$(hold_afk_daemon_lock "$home") || fail "could not hold the away-mode daemon lock"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  kill "$daemon_pid" 2>/dev/null || true

  assert_contains "$out" "away-mode supervision is active" "AFK digest did not report away mode"
  assert_contains "$out" "Away mode is active" "next step did not switch to AFK guidance"
  assert_contains "$out" "daemon owns the watcher" "next step did not delegate watcher ownership to the daemon"
  assert_contains "$out" "- Away mode: active" "supervision block did not include active AFK state"
  assert_not_contains "$out" "  bin/fm-watch-arm.sh" "AFK next step still told the agent to arm the watcher directly"

  pass "next step delegates watcher ownership to the AFK daemon"
}

# Away mode with no daemon is the away POSTURE only, so the digest must keep the
# ordinary supervision guidance instead of telling the agent to defer to a daemon
# that is not running here.
test_next_step_afk_without_daemon_keeps_own_watcher() {
  local rec root home fakebin out
  rec=$(new_world next-step-afk-no-daemon)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  : > "$home/state/.afk"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "away posture only" "AFK digest did not report the daemon-free away posture"
  assert_not_contains "$out" "daemon owns the watcher" "daemon-free away mode still handed watcher ownership to a daemon"
  assert_contains "$out" "- Away mode: active posture only" "supervision block did not report the daemon-free away posture"
  assert_contains "$out" "- Supervision ownership: this session owns it" "supervision block did not hand ownership to this session"
  assert_not_contains "$out" "- Away mode: inactive" "supervision block contradicted the away posture reported alongside it"
  assert_not_contains "$out" "keep normal harness supervision paused" "daemon-free away mode emitted the daemon-owned supervision block"
  assert_contains "$out" "Follow the supervision operating instructions block above" "daemon-free away mode lost the ordinary next step"
  assert_contains "$out" "Away posture is active" "next step dropped the away-posture cue for a daemon-free home"
  assert_contains "$out" "load /afk" "next step dropped the /afk cue for a daemon-free home"
  assert_contains "$out" "own watcher-arm loop is the supervision mechanism" "next step did not name this session's own watcher cycle"

  pass "away mode without a live daemon keeps this home arming its own watcher"
}

test_supervision_block_exactly_one_and_pi_diagnostic() {
  local rec root home fakebin out block_count wake_line sup_line context_line
  rec=$(new_world pi-supervision-block)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_harness "$fakebin" pi

  out=$(FM_FAKE_HARNESS=pi run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  block_count=$(printf '%s\n' "$out" | grep -c '^SUPERVISION OPERATING INSTRUCTIONS - primary harness:')
  [ "$block_count" -eq 1 ] || fail "expected exactly one supervision block, got $block_count"
  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: pi" "pi supervision block missing"
  assert_contains "$out" "Mode: Pi extension background wake." "pi snippet missing from session start"
  assert_contains "$out" "PI_WATCH_EXTENSION: not loaded" "pi extension load diagnostic missing"
  assert_contains "$out" "restart plain pi so $root/.pi/extensions/fm-primary-turnend-guard.ts and $root/.pi/extensions/fm-primary-pi-watch.ts auto-load" "pi extension load diagnostic omits the turn-end guard extension"

  wake_line=$(printf '%s\n' "$out" | grep -n '^WAKE QUEUE$' | head -1 | cut -d: -f1)
  sup_line=$(printf '%s\n' "$out" | grep -n '^SUPERVISION OPERATING INSTRUCTIONS' | head -1 | cut -d: -f1)
  context_line=$(printf '%s\n' "$out" | grep -n '^CONTEXT$' | head -1 | cut -d: -f1)
  [ "$wake_line" -lt "$sup_line" ] || fail "supervision block did not follow wake queue"
  [ "$sup_line" -lt "$context_line" ] || fail "supervision block did not precede context"

  pass "session start emits exactly one detected harness block and reports Pi extension load state"
}

test_pi_diagnostic_rejects_stale_loaded_marker() {
  local rec root home fakebin out marker holder_pid
  rec=$(new_world pi-stale-loaded-marker)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"

  sleep 300 &
  holder_pid=$!
  make_fake_ps_pi_holder "$fakebin" "$holder_pid"
  install_pi_turnend_extension_fixture "$root"
  install_pi_watch_extension_fixture "$root"
  marker="$home/state/.pi-watch-extension-loaded"
  printf 'stale-extension-version\n%s\n' "$holder_pid" > "$marker"
  write_pi_turnend_loaded_marker "$home" "$root" "$holder_pid"
  touch -t 203001010000 "$marker" 2>/dev/null || touch "$marker"

  out=$(FM_FAKE_HARNESS=pi run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  assert_contains "$out" "PI_WATCH_EXTENSION: not loaded" "pi diagnostic trusted a stale loaded marker"

  pass "session start rejects stale Pi loaded markers"
}

test_pi_diagnostic_accepts_prelock_loaded_marker() {
  local rec root home fakebin out holder_pid
  rec=$(new_world pi-prelock-loaded-marker)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"

  sleep 300 &
  holder_pid=$!
  make_fake_ps_pi_holder "$fakebin" "$holder_pid"
  install_pi_turnend_extension_fixture "$root"
  install_pi_watch_extension_fixture "$root"

  write_pi_loaded_markers "$home" "$root" "$holder_pid"

  out=$(FM_FAKE_HARNESS=pi run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  assert_not_contains "$out" "PI_WATCH_EXTENSION: not loaded" "pi diagnostic rejected a current pre-lock loaded marker"

  pass "session start accepts current Pi markers written before lock acquisition"
}

test_pi_diagnostic_rejects_missing_turnend_guard_marker() {
  local rec root home fakebin out holder_pid
  rec=$(new_world pi-missing-turnend-marker)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"

  sleep 300 &
  holder_pid=$!
  make_fake_ps_pi_holder "$fakebin" "$holder_pid"
  install_pi_turnend_extension_fixture "$root"
  install_pi_watch_extension_fixture "$root"

  write_pi_watch_loaded_marker "$home" "$root" "$holder_pid"

  out=$(FM_FAKE_HARNESS=pi run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  assert_contains "$out" "PI_WATCH_EXTENSION: not loaded" "pi diagnostic trusted a session without the turn-end guard extension"

  pass "session start rejects Pi sessions missing the turn-end guard marker"
}

test_pi_diagnostic_rejects_previous_session_loaded_marker() {
  local rec root home fakebin out marker version holder_pid
  rec=$(new_world pi-previous-session-loaded-marker)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"

  sleep 300 &
  holder_pid=$!
  make_fake_ps_pi_holder "$fakebin" "$holder_pid"
  install_pi_turnend_extension_fixture "$root"
  install_pi_watch_extension_fixture "$root"
  marker="$home/state/.pi-watch-extension-loaded"
  version=$(hash_file_for_test "$root/.pi/extensions/fm-primary-pi-watch.ts")
  printf '%s\n999999\n' "$version" > "$marker"
  write_pi_turnend_loaded_marker "$home" "$root" "$holder_pid"

  out=$(FM_FAKE_HARNESS=pi run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  assert_contains "$out" "PI_WATCH_EXTENSION: not loaded" "pi diagnostic trusted a marker from a previous Pi process"

  pass "session start rejects Pi loaded markers from previous sessions"
}

# Gap 1: the fleet-state digest carries one per-account quota line rolled up
# from the task telemetry files (state/<id>.telemetry), lowest runway first, so
# the session-start headline is the account nearest exhaustion. Same account on
# multiple panes rolls to its min quota_pct, an absent window/reset stays
# absent, and a fleet with no quota data says unavailable (never a zero).
test_account_quota_digest_line() {
  local rec root home fakebin out reset1 reset2
  rec=$(new_world account-quota)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  printf 'kind=ship\n' > "$home/state/t1.meta"
  printf 'kind=ship\n' > "$home/state/t2.meta"
  printf 'kind=ship\n' > "$home/state/t3.meta"
  # claude-1: one pane at 62% on the five_hour window with a known reset.
  # claude-2: two panes, 8% (seven_day) and 40% - the rollup must use the min 8%.
  reset1=1800000000
  reset2=1800864000
  printf 'account=claude-1\nquota_pct=62\nquota_window=five_hour\nquota_reset_ts=%s\n' "$reset1" \
    > "$home/state/t1.telemetry"
  printf 'account=claude-2\nquota_pct=8\nquota_window=seven_day\nquota_reset_ts=%s\n' "$reset2" \
    > "$home/state/t2.telemetry"
  printf 'account=claude-2\nquota_pct=40\nquota_window=five_hour\n' > "$home/state/t3.telemetry"

  out=$(TZ=UTC run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "Account quotas" "digest must label the per-account quota rollup"
  r1=$(date -d "@$reset1" +%H:%M 2>/dev/null || date -r "$reset1" +%H:%M 2>/dev/null)
  r2=$(date -d "@$reset2" +%H:%M 2>/dev/null || date -r "$reset2" +%H:%M 2>/dev/null)
  [ -n "$r1" ] && [ -n "$r2" ] || fail "could not compute expected reset clocks in the test"
  assert_contains "$out" "claude-2 8% (seven_day resets $r2)" \
    "rollup must lead with the lowest-runway account (claude-2 at 8% from the seven_day pane)"
  assert_contains "$out" "claude-1 62% (five_hour resets $r1)" \
    "the higher-runway account must follow, rendered after the lowest-runway account"
  # claude-2's 40% pane must not leak: the rollup is the min pct per account.
  assert_not_contains "$out" "claude-2 40%" "per-account rollup must surface the min quota_pct, not every pane"
  pass "fleet-state digest rolls quota up per account, lowest runway first, with the driving window and reset"

  # A fleet with telemetry but no quota data says unavailable, never a zero.
  rec=$(new_world account-quota-empty)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  printf 'kind=ship\n' > "$home/state/t1.meta"
  printf 'account=claude-1\n' > "$home/state/t1.telemetry"
  out=$(TZ=UTC run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  # The digest renders every subsection (Account quotas included) with the
  # standard divider line under the heading, so the unavailable value sits on
  # the line AFTER the divider: grep -A2.
  printf '%s\n' "$out" | grep -A2 -F 'Account quotas' | grep -qF 'unavailable' \
    || fail "missing quota data must render unavailable under the Account quotas subsection: $out"
  pass "fleet-state digest renders unavailable when no quota data exists"
}

test_context_digest_absent_empty_present
test_cross_session_stall_blocked_surfaces_any_age
test_cross_session_stall_paused_threshold
test_cross_session_stall_fresh_pause_suppressed
test_cross_session_stall_none_when_all_working
test_context_digest_shape2_seam_split
test_context_digest_shape2_missing_seam_full_cat
test_context_digest_shape2_absent_and_full_escape_hatch
test_lock_refusal_read_only_path
test_output_ordering_diagnostics_lead
test_herdr_backend_diagnostics_follow_real_session_start
test_status_tail_bounding
test_gap3_pairs_current_state_and_event_no_old_for_status_log_source
test_gap3_digest_marks_superseded_and_old_on_disagree
test_orphan_status_logs_are_printed
test_endpoint_liveness_tmux
test_endpoint_liveness_herdr
test_composition_invokes_real_scripts
test_backlog_compact_tasks_axi_omits_bodies_and_keeps_metadata
test_backlog_compact_manual_backend_skips_indented_bodies
test_backlog_compact_tasks_axi_unavailable_uses_manual_fallback
test_fleet_digest_empty_fleet
test_fleet_digest_surfaces_merge_queue
test_fleet_digest_flags_merge_queue_drift
test_fleet_digest_no_drift_when_meta_absent
test_backlog_drift_no_meta
test_backlog_drift_dead_endpoint
test_backlog_drift_none_when_live_worker
test_next_step_sources_x_mode_cadence
test_next_step_afk_delegates_to_daemon
test_next_step_afk_without_daemon_keeps_own_watcher
test_supervision_block_exactly_one_and_pi_diagnostic
test_pi_diagnostic_rejects_stale_loaded_marker
test_pi_diagnostic_accepts_prelock_loaded_marker
test_pi_diagnostic_rejects_missing_turnend_guard_marker
test_pi_diagnostic_rejects_previous_session_loaded_marker
test_account_quota_digest_line
