#!/usr/bin/env bash
# tests/fm-switch-account.test.sh - contract tests for bin/fm-switch-account.sh,
# the helper that broadcasts jcode's per-session `/account claude switch <label>`
# into every live worker pane.
#
# Two reasons these tests exist:
#
# 1. The no-args pane auto-discovery path. That path used to fail SILENTLY:
#    under `set -euo pipefail`, a state/*.meta with no target (for example a
#    service sidecar such as state/.lavish-lan.meta, which records only
#    port=/bind=/target=) made the discovery grep exit non-zero, that status
#    propagated through the command substitution, and set -e killed the whole
#    script with exit 1 before it reached a real target.
#
# 2. The composer pending-text guard (captain-reported bug): the script used to
#    type `/account claude switch <label>` + Enter into every pane blindly. If a
#    pane held a half-typed prompt the switch command was appended onto it and
#    the whole thing got garbled. The fix checks each pane's composer state and
#    clears pending text with one Escape before sending, skipping panes that
#    stay pending (real human typing) or read unknown (dead/non-agent pane).
#
# 3. The herdr target must be passed VERBATIM (task
#    fix-jcode-composer-probe-unknown-blocks-account-switch): a herdr meta records
#    window= as the full "<session>:<workspace>:<pane>" id (e.g.
#    "default:w1J:p3"), and the herdr adapter's parse_target splits on the FIRST
#    colon only - the leading field is the herdr --session, the remainder is the
#    whole pane id. An earlier version stripped the "default:" prefix, leaving
#    "w1J:p3", which herdr then read as session=w1J pane=p3 and rejected as
#    pane_not_found, so EVERY live jcode composer probe returned `unknown` and the
#    script skipped the whole fleet. The fake fm-backend.sh below emulates that
#    same first-colon split in its composer/send/capture stubs, so a target that
#    is not passed verbatim reads `unknown` here exactly as real herdr would -
#    that is what makes case 1 a genuine regression guard, not a string check.
#
# Everything is injected: a fake repo layout (bin/ + state/) plus a fake
# fm-backend.sh whose composer states are scripted per target, so no assertion
# depends on any real pane, task, backend, or account.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SRC="$ROOT/bin/fm-switch-account.sh"
assert_present "$SRC" "bin/fm-switch-account.sh is missing"
[ -x "$SRC" ] || fail "bin/fm-switch-account.sh must be executable"

TMPROOT=$(fm_test_tmproot fm-switch-account)

# Build a fake repo layout the script cds into: bin/<script> + bin/fm-backend.sh
# + state/*.meta. The script resolves its root as dirname/.. of its own path and
# sources fm-backend.sh from its own bin dir, so a fake fm-backend.sh next to it
# controls every backend primitive.
REPO="$TMPROOT/repo"
mkdir -p "$REPO/bin" "$REPO/state" "$REPO/data"
cp "$SRC" "$REPO/bin/fm-switch-account.sh"
chmod +x "$REPO/bin/fm-switch-account.sh"
# The script now sources bin/fm-ff-lib.sh (for the registered-secondmate-home
# walk); copy the real library so the walk and its validate_secondmate_home guard
# run exactly as in production.
cp "$ROOT/bin/fm-ff-lib.sh" "$REPO/bin/fm-ff-lib.sh"

# Per-target scripted composer states. COMPOSER_DIR holds one file per target
# (":"/"/" -> "_"); each line is one state, consumed one per composer_state call,
# so a pane can read pending then empty (Escape cleared it) or pending twice
# (stubborn). A missing file defaults to empty.
COMPOSER_DIR="$TMPROOT/composer"
BACKEND_LOG="$TMPROOT/backend.log"
# SENTLABEL_DIR records, per target, the label the switch was last sent with, so
# the capture stub can emit jcode's real "Switched to Anthropic account <label>"
# acknowledgement for the verification pass. NOCONFIRM_DIR lists targets whose
# switch is DROPPED after send (the delivery-miss case) so their capture never
# confirms.
SENTLABEL_DIR="$TMPROOT/sentlabel"
NOCONFIRM_DIR="$TMPROOT/noconfirm"

sanitize() { printf '%s' "$1" | tr ':/' '__'; }

set_composer() {  # <target> <state...>
  local t=$1; shift
  mkdir -p "$COMPOSER_DIR"
  local f
  f="$COMPOSER_DIR/$(sanitize "$t")"
  : > "$f"
  local s
  for s in "$@"; do printf '%s\n' "$s" >> "$f"; done
}

# Fake fm-backend.sh: meta helpers plus scripted composer/send/capture. It reads
# COMPOSER_DIR and appends every send to BACKEND_LOG.
cat > "$REPO/bin/fm-backend.sh" <<'SH'
#!/usr/bin/env bash
fm_meta_get() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
fm_backend_of_meta() { local v; v=$(fm_meta_get "$1" backend); printf '%s' "${v:-tmux}"; }
fm_backend_target_of_meta() {
  local meta=$1 backend terminal window
  backend=$(fm_backend_of_meta "$meta")
  if [ "$backend" = orca ]; then
    terminal=$(fm_meta_get "$meta" terminal)
    [ -n "$terminal" ] && { printf '%s' "$terminal"; return 0; }
  fi
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] && printf '%s' "$window"
}
_fst_san() { printf '%s' "$1" | tr ':/' '__'; }
# Emulate the herdr adapter's fm_backend_herdr_parse_target: a herdr target is
# "<session>:<workspace>:<pane>" and it splits on the FIRST colon only, using
# the leading field as the herdr --session. Our fake live panes all live under
# the "default" session, so a herdr target whose first field is not "default"
# is a target that was NOT passed verbatim (e.g. a "default:"-stripped id) and
# reads unknown, exactly as real herdr would return pane_not_found. tmux targets
# are opaque here and always resolve.
_fst_herdr_bad_target() {  # <backend> <target> -> 0 when herdr and NOT default:*
  [ "$1" = herdr ] || return 1
  case "$2" in default:*) return 1 ;; *) return 0 ;; esac
}
fm_backend_composer_state() {  # <backend> <target>
  local target=$2 f line
  _fst_herdr_bad_target "$1" "$target" && { printf 'unknown'; return 0; }
  f="$COMPOSER_DIR/$(_fst_san "$target")"
  [ -f "$f" ] || { printf 'empty'; return 0; }
  line=$(head -1 "$f")
  # consume the first line so the next call sees the following state
  sed -i '1d' "$f" 2>/dev/null || tail -n +2 "$f" > "$f.n" && mv "$f.n" "$f" 2>/dev/null || true
  printf '%s' "${line:-empty}"
}
fm_backend_send_key() {  # <backend> <target> <key>
  printf 'send_key %s %s %s\n' "$1" "$2" "$3" >> "$BACKEND_LOG"
}
fm_backend_send_text_submit() {  # <backend> <target> <text> ...
  printf 'send_text %s %s %s\n' "$1" "$2" "$3" >> "$BACKEND_LOG"
  # Record the label this pane was switched to, so the capture stub below can
  # emit jcode's real acknowledgement line ("Switched to Anthropic account
  # <label>") for the verification pass. A target listed in NOCONFIRM_DIR never
  # gets a recorded label, so its capture stays unconfirmed (the delivery-miss
  # case). Text is "/account claude switch <label>".
  local tgt=$2 text=$3 lbl san
  lbl=${text##* }
  san=$(_fst_san "$tgt")
  mkdir -p "$SENTLABEL_DIR"
  if [ ! -f "$NOCONFIRM_DIR/$san" ]; then
    printf '%s' "$lbl" > "$SENTLABEL_DIR/$san"
  fi
  printf 'empty'
}
fm_backend_capture() {  # <backend> <target> <lines>
  printf 'capture %s %s\n' "$1" "$2" >> "$BACKEND_LOG"
  local san lbl
  san=$(_fst_san "$2")
  if [ -f "$SENTLABEL_DIR/$san" ]; then
    lbl=$(cat "$SENTLABEL_DIR/$san")
    echo "Switched to Anthropic account $lbl"
  else
    echo "stub pane content"
  fi
}
SH

export COMPOSER_DIR BACKEND_LOG SENTLABEL_DIR NOCONFIRM_DIR
# Skip real waits.
export FM_SWITCH_SEND_SETTLE=0 FM_SWITCH_CONFIRM_WAIT=0 FM_SWITCH_CLEAR_SETTLE=0

# Fake auth.json so label validation is deterministic and never depends on the
# host's real jcode account file. The known labels here (claude-2, claude-4) are
# exactly the ones the cases below switch to.
AUTH_JSON="$TMPROOT/auth.json"
cat > "$AUTH_JSON" <<'JSON'
{"anthropic_accounts":[{"label":"claude-2","email":"a@example.com"},{"label":"claude-4","email":"b@example.com"}],"active_anthropic_account":"claude-2"}
JSON
export FM_SWITCH_AUTH_JSON="$AUTH_JSON"

run_switch() {  # <args...> -> sets OUT / RC
  : > "$BACKEND_LOG"
  rm -rf "$SENTLABEL_DIR"; mkdir -p "$SENTLABEL_DIR"
  OUT=$(cd "$REPO" && ./bin/fm-switch-account.sh "$@" 2>&1)
  RC=$?
}

# assert_empty_file <file> <msg>: file must exist and be empty (no pane sends).
assert_empty_file() {
  [ -f "$1" ] && [ ! -s "$1" ] || fail "$2 (file not empty: $1)"
}

# --- case 1: no-args discovery lists the recorded targets verbatim ------------
# herdr-backed metas keep their full "default:<ws>:<pane>" id (the adapter needs
# it verbatim). bravo omits backend= so it resolves to tmux (P1 compat).
fm_write_meta "$REPO/state/alpha.meta" "backend=herdr" "window=default:w1:p2" "project=alpha"
fm_write_meta "$REPO/state/bravo.meta" "window=w2:p3" "project=bravo"
fm_write_meta "$REPO/state/.lavish-lan.meta" "port=4388" "bind=0.0.0.0" "target=4387"

run_switch claude-2
expect_code 0 "$RC" "no-args discovery must exit 0 with a windowless meta present"
assert_contains "$OUT" "in 2 pane(s)" "discovery must find exactly the two windowed panes"
assert_contains "$OUT" "default:w1:p2" "discovery must keep the herdr target verbatim (adapter splits on the first colon)"
assert_contains "$OUT" "w2:p3" "discovery must include the second windowed pane"
assert_not_contains "$OUT" "no target panes" "discovery must not report an empty target set"
pass "no-args discovery lists windowed panes verbatim and skips a windowless meta"

# --- case 2: each discovered target is sent on its recorded backend -----------
# alpha resolves to herdr with its FULL id (default:w1:p2), bravo has no
# backend= so it resolves to tmux (P1 compat) and keeps its full id.
run_switch claude-2
assert_grep "send_text herdr default:w1:p2 /account claude switch claude-2" "$BACKEND_LOG" "herdr meta must be sent on herdr with its verbatim id"
assert_grep "send_text tmux w2:p3 /account claude switch claude-2" "$BACKEND_LOG" "backendless meta must be sent on tmux"
pass "each discovered target is sent on its recorded backend"

# --- case 3: an empty composer is sent the switch command normally ------------
set_composer "default:w1:p2" empty
set_composer "w2:p3" empty
run_switch claude-2
expect_code 0 "$RC" "empty composers must exit 0"
assert_grep "send_text herdr default:w1:p2 /account claude switch claude-2" "$BACKEND_LOG" "empty composer must receive the switch"
assert_no_grep "send_key" "$BACKEND_LOG" "an empty composer must never get an Escape"
pass "an empty composer is sent the switch command with no Escape"

# --- case 3b: REGRESSION - a live herdr composer must NOT read unknown ---------
# The bug this task fixes: the script stripped "default:" from the herdr target,
# leaving "w1:p2", which the adapter read as session=w1 pane=p2 and rejected,
# so every live jcode composer probed `unknown` and the whole fleet was skipped
# with zero switched. The fake backend above emulates that same first-colon
# split, so a stripped target would read unknown here too. Assert the live
# herdr pane is actually switched (verbatim target reaches the send path) and
# is never reported skipped-as-unknown.
set_composer "default:w1:p2" empty
set_composer "w2:p3" empty
run_switch claude-2
assert_grep "send_text herdr default:w1:p2 /account claude switch claude-2" "$BACKEND_LOG" "a live herdr composer must actually be switched, not skipped as unknown"
assert_not_contains "$OUT" "default:w1:p2: SKIPPED" "a live herdr composer must never be skipped as unknown (the stripped-target regression)"
pass "a live herdr composer is switched, never skipped unknown from a mangled target"

# --- case 4: a pending composer gets Escape-cleared then sent -----------------
# First read pending, Escape, second read empty -> proceed.
set_composer "default:w1:p2" pending empty
set_composer "w2:p3" empty
run_switch claude-2
expect_code 0 "$RC" "an Escape-clearable pending composer must exit 0"
assert_grep "send_key herdr default:w1:p2 Escape" "$BACKEND_LOG" "a pending composer must get one Escape"
assert_grep "send_text herdr default:w1:p2 /account claude switch claude-2" "$BACKEND_LOG" "a cleared composer must then be sent the switch"
pass "a pending composer is Escape-cleared before the switch is sent"

# --- case 5: a stubbornly-pending composer is SKIPPED, never garbled ----------
# pending on both reads (Escape did not clear) -> skip, no send.
set_composer "default:w1:p2" pending pending
set_composer "w2:p3" empty
run_switch claude-2
expect_code 0 "$RC" "a stubborn pending pane must not fail the run"
assert_grep "send_key herdr default:w1:p2 Escape" "$BACKEND_LOG" "the stubborn pane must still have been Escape-tried once"
assert_contains "$OUT" "SKIPPED" "a stubborn pending pane must be reported skipped"
assert_no_grep "send_text herdr default:w1:p2 " "$BACKEND_LOG" "a stubborn pending pane must never be sent the switch"
assert_grep "send_text tmux w2:p3 /account claude switch claude-2" "$BACKEND_LOG" "the other pane must still be switched"
pass "a stubbornly-pending composer is skipped, never garbled"

# --- case 6: an unknown composer state is SKIPPED, never blind-injected -------
set_composer "default:w1:p2" unknown
set_composer "w2:p3" empty
run_switch claude-2
expect_code 0 "$RC" "an unknown pane must not fail the run"
assert_contains "$OUT" "SKIPPED" "an unknown composer must be reported skipped"
assert_no_grep "send_text herdr default:w1:p2 " "$BACKEND_LOG" "an unknown composer must never be injected into"
assert_grep "send_text tmux w2:p3 /account claude switch claude-2" "$BACKEND_LOG" "the healthy pane must still be switched"
pass "an unknown composer state is skipped, never blind-injected"

# --- case 7: explicit pane-id args bypass discovery and use herdr -------------
# Explicit ids have no meta, so they keep the historical herdr assumption and
# are used verbatim. Per the fixed contract they must be the full
# "<session>:<workspace>:<pane>" form the adapter needs (the same value meta
# records in window=), so the fake backend's first-colon split resolves them.
set_composer "default:wX:p9" empty
set_composer "default:wY:p1" empty
run_switch claude-4 default:wX:p9 default:wY:p1
expect_code 0 "$RC" "explicit pane args must exit 0"
assert_contains "$OUT" "in 2 pane(s)" "explicit args must target exactly the given panes"
assert_grep "send_text herdr default:wX:p9 /account claude switch claude-4" "$BACKEND_LOG" "explicit pane default:wX:p9 must be targeted on herdr"
assert_grep "send_text herdr default:wY:p1 /account claude switch claude-4" "$BACKEND_LOG" "explicit pane default:wY:p1 must be targeted on herdr"
assert_no_grep "default:w1:p2" "$BACKEND_LOG" "explicit args must not fall back to discovered panes"
pass "explicit pane-id args bypass discovery and use herdr"

# --- case 8: a state/ with zero windowed metas reports no targets and exits 1 -
EMPTY="$TMPROOT/empty"
mkdir -p "$EMPTY/bin" "$EMPTY/state"
cp "$SRC" "$EMPTY/bin/fm-switch-account.sh"
chmod +x "$EMPTY/bin/fm-switch-account.sh"
cp "$REPO/bin/fm-backend.sh" "$EMPTY/bin/fm-backend.sh"
cp "$ROOT/bin/fm-ff-lib.sh" "$EMPTY/bin/fm-ff-lib.sh"
fm_write_meta "$EMPTY/state/.lavish-lan.meta" "port=4388" "bind=0.0.0.0"
OUT=$(cd "$EMPTY" && ./bin/fm-switch-account.sh claude-2 2>&1); RC=$?
expect_code 1 "$RC" "a state dir with no windowed metas must exit 1"
assert_contains "$OUT" "no target panes found" "empty discovery must report no target panes"
pass "no windowed metas reports no targets and exits 1"

# --- case 9: a missing label exits 2 with usage -------------------------------
OUT=$(cd "$REPO" && ./bin/fm-switch-account.sh 2>&1); RC=$?
expect_code 2 "$RC" "a missing label must exit 2"
assert_contains "$OUT" "usage:" "a missing label must print usage"
pass "a missing label argument exits 2 with usage"

# --- case 9a: --help prints usage, exits 0, broadcasts nothing -----------------
# REPEAT-OFFENSE guard: `fm-switch-account.sh --help` used to be broadcast into
# every live worker pane. It must now print usage and never touch a pane.
run_switch --help
expect_code 0 "$RC" "--help must exit 0"
assert_contains "$OUT" "usage:" "--help must print usage"
assert_empty_file "$BACKEND_LOG" "--help must never send anything to a pane"
pass "--help prints usage and broadcasts nothing"

# --- case 9b: --status shows active + known labels, broadcasts nothing ---------
run_switch --status
expect_code 0 "$RC" "--status must exit 0"
assert_contains "$OUT" "active account: claude-2" "--status must report the active account"
assert_contains "$OUT" "claude-4" "--status must list the known labels"
assert_empty_file "$BACKEND_LOG" "--status must never send anything to a pane"
pass "--status shows active and known labels, broadcasts nothing"

# --- case 9c: an unrecognized dashed first arg is rejected, broadcasts nothing -
# The core repeat-offense fix: a leading-dash arg that is not a known flag (a
# typo like --stat, or -x) must be rejected with usage BEFORE any pane send.
run_switch --nope
expect_code 2 "$RC" "an unrecognized dashed arg must exit non-zero"
assert_contains "$OUT" "unrecognized option" "an unrecognized dashed arg must be rejected"
assert_empty_file "$BACKEND_LOG" "an unrecognized dashed arg must never be broadcast"
pass "an unrecognized dashed first arg is rejected and broadcasts nothing"

# --- case 9d: an unknown (non-dashed) label is rejected before broadcasting ----
run_switch claude-99
expect_code 2 "$RC" "an unknown label must exit non-zero"
assert_contains "$OUT" "unknown account label" "an unknown label must be rejected"
assert_empty_file "$BACKEND_LOG" "an unknown label must never be broadcast"
pass "an unknown account label is rejected before any pane send"

# --- case 9e: an unreadable auth set skips validation (legit switch survives) --
# When auth.json cannot be read the known set is empty; validation is skipped so
# a legitimate switch is never blocked by a missing account file.
OUT=$(cd "$REPO" && FM_SWITCH_AUTH_JSON="$TMPROOT/nope.json" ./bin/fm-switch-account.sh claude-2 2>&1); RC=$?
expect_code 0 "$RC" "a missing auth file must not block a switch"
assert_contains "$OUT" "in 2 pane(s)" "a missing auth file skips validation and still switches"
pass "a missing auth file skips validation rather than blocking the switch"

# --- case 11: no-args discovery ALSO walks registered secondmate homes ---------
# The scout-switch-misses-secondmate-crews incident: a secondmate's crews are
# recorded only in that secondmate home's OWN state/*.meta, never in the main
# home, so a main-home-only enumeration left a live secondmate crew on the old
# account SILENTLY through a fleet switch. Seed a valid secondmate home with a
# live crew meta and a registry entry, and assert the switch reaches that crew's
# pane too.
seed_secondmate_home() {  # <home-dir> <id>
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s' "$id" > "$home/.fm-secondmate-home"
  : > "$home/AGENTS.md"
  : > "$home/bin/.keep"
}
SM1="$TMPROOT/sm1-home"
seed_secondmate_home "$SM1" "sm-alpha"
# A live crew of the secondmate, recorded ONLY under the secondmate home.
fm_write_meta "$SM1/state/crew-x.meta" "backend=herdr" "window=default:w9:pC" "project=sm-alpha"
# Registry entry the walk reads (home= is what secondmate_registry_entries pulls).
cat > "$REPO/data/secondmates.md" <<EOF
- sm-alpha - a test secondmate (home: $SM1; scope: test; projects: ; added 2026-08-25)
EOF

run_switch claude-2
expect_code 0 "$RC" "a fleet switch across a live secondmate crew must exit 0"
assert_contains "$OUT" "default:w9:pC" "the secondmate crew pane must be enumerated (the enumeration-miss fix)"
assert_grep "send_text herdr default:w9:pC /account claude switch claude-2" "$BACKEND_LOG" "the secondmate crew must actually receive the switch"
assert_contains "$OUT" "[secondmate:sm-alpha] default:w9:pC: CONFIRMED" "the secondmate crew must report a home-labeled CONFIRMED verdict"
pass "no-args discovery walks registered secondmate homes and switches their crews"

# --- case 12: an unseeded/invalid secondmate home is skipped read-only ---------
# A registry entry whose home is not a seeded secondmate home (no marker) must be
# skipped with a note, never crash the switch and never touch that dir.
cat > "$REPO/data/secondmates.md" <<EOF
- sm-alpha - live (home: $SM1; scope: test; projects: ; added 2026-08-25)
- sm-bogus - broken (home: $TMPROOT/does-not-exist; scope: test; projects: ; added 2026-08-25)
EOF
run_switch claude-2
expect_code 0 "$RC" "a bogus secondmate home must not fail the switch"
assert_contains "$OUT" "skipping secondmate 'sm-bogus'" "a bogus secondmate home must be reported skipped"
assert_grep "send_text herdr default:w9:pC /account claude switch claude-2" "$BACKEND_LOG" "the valid secondmate crew must still be switched"
pass "an invalid secondmate home is skipped read-only, valid crews still switch"

# --- case 13: a delivery-miss pane is reported UNCONFIRMED and exits 3 ---------
# The OTHER failure shape: a pane is enumerated and sent the switch, but the
# queued switch never lands (dropped on turn end / wedge), so its capture never
# shows the acknowledgement. The verification pass must catch this - retry once,
# then report UNCONFIRMED and exit non-zero rather than assume success.
rm -f "$REPO/data/secondmates.md"
mkdir -p "$NOCONFIRM_DIR"
: > "$NOCONFIRM_DIR/$(sanitize default:w1:p2)"   # alpha's switch is dropped
run_switch claude-2
expect_code 3 "$RC" "an unconfirmed pane must make the run exit 3"
assert_contains "$OUT" "default:w1:p2: UNCONFIRMED" "a dropped switch must be reported UNCONFIRMED"
assert_contains "$OUT" "w2:p3: CONFIRMED" "the landed pane must still be CONFIRMED"
rm -f "$NOCONFIRM_DIR"/*
pass "a delivery-miss pane is caught as UNCONFIRMED and exits 3"

# --- case 14: an unconfirmed pane is retried exactly once ----------------------
# The verification retry re-sends the switch once. Count the send_text lines for
# a persistently-dropped pane: one first-pass send plus one retry send = 2.
mkdir -p "$NOCONFIRM_DIR"
: > "$NOCONFIRM_DIR/$(sanitize default:w1:p2)"
run_switch claude-2
n=$(grep -c "send_text herdr default:w1:p2 /account claude switch claude-2" "$BACKEND_LOG" || true)
[ "$n" -eq 2 ] || fail "an unconfirmed pane must be retried exactly once (saw $n send(s), expected 2)"
rm -f "$NOCONFIRM_DIR"/*
pass "an unconfirmed pane is retried exactly once before the UNCONFIRMED verdict"

# --- case 10: no stray e_* files left in the repo root ------------------------
strays=""
for f in "$REPO"/e_*; do
  [ -e "$f" ] && strays="$strays $(basename "$f")"
done
[ -z "$strays" ] || fail "run left stray stderr files in repo root:$strays"
pass "no stray e_* stderr files are created"

# --- case 11: --resume chains into fm-resume-fleet AFTER the switch -------------
# The paced re-warm (bin/fm-resume-fleet.sh) is chained only after the switch
# confirmations, so a bulk account switch never fires every lane's cold-cache
# turn at once (incident 2026-08-25). FM_SWITCH_RESUME_BIN is the seam: a stub
# records that it was called and with what FM_HOME, so the chain is asserted
# without driving the real staggered resume.
RESUME_STUB="$TMPROOT/resume-stub.sh"
RESUME_CALLED="$TMPROOT/resume-called"
cat > "$RESUME_STUB" <<SH
#!/usr/bin/env bash
printf 'resume-called home=%s args=[%s]\n' "\${FM_HOME:-}" "\$*" >> "$RESUME_CALLED"
exit 0
SH
chmod +x "$RESUME_STUB"

: > "$RESUME_CALLED"
OUT=$(cd "$REPO" && FM_HOME="$REPO" FM_SWITCH_RESUME_BIN="$RESUME_STUB" ./bin/fm-switch-account.sh claude-2 --resume 2>&1); RC=$?
expect_code 0 "$RC" "a switch --resume must exit 0"
assert_contains "$OUT" "re-warming the fleet" "--resume must announce the paced re-warm"
assert_grep "send_text herdr default:w1:p2 /account claude switch claude-2" "$BACKEND_LOG" "--resume must still perform the switch before chaining"
assert_grep "resume-called" "$RESUME_CALLED" "--resume must chain into fm-resume-fleet after the switch"
assert_grep "home=$REPO" "$RESUME_CALLED" "the chained re-warm must inherit FM_HOME"
pass "--resume performs the switch, then chains into the paced re-warm"

# --- case 11a: --resume anywhere in the args is honored ------------------------
: > "$RESUME_CALLED"
: > "$BACKEND_LOG"
OUT=$(cd "$REPO" && FM_HOME="$REPO" FM_SWITCH_RESUME_BIN="$RESUME_STUB" ./bin/fm-switch-account.sh --resume claude-2 2>&1); RC=$?
expect_code 0 "$RC" "--resume before the label must still exit 0"
assert_grep "send_text herdr default:w1:p2 /account claude switch claude-2" "$BACKEND_LOG" "--resume before the label must not corrupt the switch"
assert_grep "resume-called" "$RESUME_CALLED" "--resume before the label must still chain the re-warm"
pass "--resume is positional-agnostic in the argument list"

# --- case 11b: WITHOUT --resume nothing chains (byte-unchanged default) ---------
: > "$RESUME_CALLED"
OUT=$(cd "$REPO" && FM_HOME="$REPO" FM_SWITCH_RESUME_BIN="$RESUME_STUB" ./bin/fm-switch-account.sh claude-2 2>&1); RC=$?
expect_code 0 "$RC" "a plain switch must exit 0"
assert_not_contains "$OUT" "re-warming the fleet" "a plain switch must never announce a re-warm"
[ -s "$RESUME_CALLED" ] && fail "a plain switch must not chain the re-warm" || true
pass "the default (no --resume) chains nothing"

# --- case 11c: a failed re-warm never fails the switch itself -------------------
# fm-resume-fleet exits 3 when a lane needs attention; the switch already
# succeeded and must not be marked failed by the re-warm's advisory exit.
RESUME_FAIL_STUB="$TMPROOT/resume-fail.sh"
cat > "$RESUME_FAIL_STUB" <<'SH'
#!/usr/bin/env bash
echo "some lane needs attention"
exit 3
SH
chmod +x "$RESUME_FAIL_STUB"
OUT=$(cd "$REPO" && FM_HOME="$REPO" FM_SWITCH_RESUME_BIN="$RESUME_FAIL_STUB" ./bin/fm-switch-account.sh claude-2 --resume 2>&1); RC=$?
expect_code 0 "$RC" "a re-warm that reports a needy lane must not fail the switch"
assert_contains "$OUT" "needing attention" "a needy-lane re-warm must be reported without failing the switch"
pass "a re-warm reporting a needy lane never fails the account switch"

# --- case 11d: --resume with a missing label still exits 2 (no switch, no chain) -
: > "$RESUME_CALLED"
OUT=$(cd "$REPO" && FM_SWITCH_RESUME_BIN="$RESUME_STUB" ./bin/fm-switch-account.sh --resume 2>&1); RC=$?
expect_code 2 "$RC" "a bare --resume with no label must exit 2"
assert_contains "$OUT" "usage:" "a bare --resume must print usage"
[ -s "$RESUME_CALLED" ] && fail "a bare --resume must never chain the re-warm" || true
pass "--resume with no label exits 2 and chains nothing"

pass "fm-switch-account.sh: all checks passed"
