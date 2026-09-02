#!/usr/bin/env bash
# Behavior tests for bin/fm-skills-manifest.sh, the single owner of the fleet
# skills manifest (config/skills-manifest) and its additive, idempotent install.
#
# The properties pinned here are the ones a defect would silently break:
#   - the tracked manifest parses, and every seeded source is well-formed
#   - `check` is detect-only: it never writes, never installs, prints exactly one
#     SKILLS_MANIFEST line when skills are missing, and is silent when they are
#     all present (bin/fm-bootstrap.sh consumes that line verbatim)
#   - `install` is idempotent: a run against a converged root performs no work
#     and touches no file, so a second run is a genuine no-op
#   - `install` is ADDITIVE-ONLY: a skill the manifest does not name is never
#     removed, overwritten, or otherwise touched, because the install root is
#     shared, live, captain-visible state
#   - a malformed manifest line is refused loudly rather than silently skipped
#   - the detect-only check is wired into bin/fm-bootstrap.sh in BOTH modes
#
# The real network install path is exercised in exactly one opt-in case
# (FM_TEST_SKILLS_NETWORK=1) against a throwaway install root; every other case
# uses a fake `npx` so the suite never reaches GitHub and never touches the real
# ~/.agents/skills.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILLS="$ROOT/bin/fm-skills-manifest.sh"
MANIFEST="$ROOT/config/skills-manifest"
BOOT="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-skills-manifest)

[ -x "$SKILLS" ] || fail "bin/fm-skills-manifest.sh is missing or not executable"
[ -f "$MANIFEST" ] || fail "config/skills-manifest is missing"

trap fm_test_cleanup EXIT

# A fake `npx` standing in for `npx -y skills add <owner>/<repo>@<skill> ...`.
# It writes the skill under $HOME/.agents/skills exactly like the real CLI, and
# records every invocation so a case can assert which sources were fetched (and,
# for idempotence, that NONE were).
make_fake_npx() {  # <dir> [fail-for-skill]
  local dir=$1 failfor=${2:-} fakebin
  fakebin="$dir/bin"
  mkdir -p "$fakebin"
  cat > "$fakebin/npx" <<SH
#!/usr/bin/env bash
# Args: -y skills add <source>@<skill> --agent universal -g -y
spec=
for a in "\$@"; do
  case "\$a" in
    */*@*) spec=\$a ;;
  esac
done
printf '%s\n' "\$spec" >> "$dir/npx-calls"
skill=\${spec##*@}
if [ -n "$failfor" ] && [ "\$skill" = "$failfor" ]; then
  exit 1
fi
mkdir -p "\$HOME/.agents/skills/\$skill"
printf 'name: %s\n' "\$skill" > "\$HOME/.agents/skills/\$skill/SKILL.md"
exit 0
SH
  chmod +x "$fakebin/npx"
  printf '%s\n' "$fakebin"
}

# Run the script with a fake npx, an isolated install root, and an optional
# manifest override. Sets FM_OUT/FM_ERR/FM_RC as globals so the exit status
# survives (a command substitution would run in a subshell).
run_skills() {  # <case-dir> <manifest> <args...>
  local dir=$1 manifest=$2
  shift 2
  local fakebin out err
  fakebin="$dir/bin"
  out="$dir/out"; err="$dir/err"
  PATH="$fakebin:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    FM_SKILLS_MANIFEST="$manifest" FM_SKILLS_HOME="$dir/home" \
    "$SKILLS" "$@" > "$out" 2> "$err"
  FM_RC=$?
  FM_OUT=$(cat "$out")
  FM_ERR=$(cat "$err")
}

new_case() {  # <name> [manifest-body]
  local name=$1 body=${2:-} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/.agents/skills"
  make_fake_npx "$dir" >/dev/null
  : > "$dir/npx-calls"
  if [ -n "$body" ]; then
    printf '%s\n' "$body" > "$dir/manifest"
  else
    cp "$MANIFEST" "$dir/manifest"
  fi
  printf '%s\n' "$dir"
}

# --- the tracked manifest itself --------------------------------------------

test_tracked_manifest_parses() {
  local dir lines
  dir=$(new_case tracked-parses)
  run_skills "$dir" "$dir/manifest" list
  [ "$FM_RC" -eq 0 ] || fail "listing the tracked manifest failed: $FM_ERR"
  lines=$(printf '%s\n' "$FM_OUT" | grep -c .)
  [ "$lines" -ge 8 ] || fail "tracked manifest resolved only $lines entries, expected at least 8"
  pass "the tracked config/skills-manifest parses into one source per line"
}

test_tracked_manifest_seeded_sources() {
  local dir want
  dir=$(new_case tracked-seeded)
  run_skills "$dir" "$dir/manifest" list
  for want in tasks-axi gh-axi chrome-devtools-axi quota-axi mongosh-axi lavish no-mistakes axi; do
    printf '%s\n' "$FM_OUT" | awk '{print $2}' | grep -Fxq "$want" \
      || fail "tracked manifest does not name the $want skill"
  done
  pass "the tracked manifest names every seeded first-party tool skill"
}

test_tracked_manifest_one_source_per_line() {
  local bad
  # Every non-comment, non-blank line is exactly one <owner>/<repo>@<skill>.
  bad=$(grep -vE '^[[:space:]]*(#|$)' "$MANIFEST" \
    | grep -vE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$' || true)
  [ -z "$bad" ] || fail "tracked manifest has non-conforming line(s): $bad"
  pass "every tracked manifest line is exactly one source"
}

# --- check is detect-only ----------------------------------------------------

test_check_reports_missing_without_installing() {
  local dir calls
  dir=$(new_case check-missing)
  run_skills "$dir" "$dir/manifest" check
  [ "$FM_RC" -eq 0 ] || fail "check exited $FM_RC on a home with missing skills"
  case "$FM_OUT" in
    "SKILLS_MANIFEST: 8 manifest skill(s) missing: "*"(install: bin/fm-skills-manifest.sh install)") ;;
    *) fail "check printed an unexpected line: $FM_OUT" ;;
  esac
  [ "$(printf '%s\n' "$FM_OUT" | grep -c .)" -eq 1 ] \
    || fail "check printed more than one line: $FM_OUT"
  calls=$(grep -c . "$dir/npx-calls" || true)
  [ "$calls" -eq 0 ] || fail "check invoked the installer $calls time(s); it must be detect-only"
  [ -z "$(ls -A "$dir/home/.agents/skills")" ] || fail "check wrote into the install root"
  pass "check reports missing skills on one line and installs nothing"
}

test_check_is_silent_when_converged() {
  local dir skill skills
  dir=$(new_case check-silent)
  run_skills "$dir" "$dir/manifest" list
  skills=$(printf '%s\n' "$FM_OUT" | awk '{print $2}')
  [ -n "$skills" ] || fail "the manifest listed no skills to converge"
  for skill in $skills; do
    mkdir -p "$dir/home/.agents/skills/$skill"
    printf 'name: %s\n' "$skill" > "$dir/home/.agents/skills/$skill/SKILL.md"
  done
  run_skills "$dir" "$dir/manifest" check
  [ "$FM_RC" -eq 0 ] || fail "check exited $FM_RC on a converged home"
  [ -z "$FM_OUT" ] || fail "check spoke on a converged home: $FM_OUT"
  pass "check is silent when every manifest skill is present"
}

test_check_is_the_default_subcommand() {
  local dir
  dir=$(new_case check-default)
  run_skills "$dir" "$dir/manifest"
  case "$FM_OUT" in
    "SKILLS_MANIFEST: "*) ;;
    *) fail "the bare invocation did not run check: $FM_OUT" ;;
  esac
  pass "the bare invocation runs the detect-only check"
}

# --- install: idempotent and additive-only -----------------------------------

test_install_installs_every_missing_skill() {
  local dir calls
  dir=$(new_case install-all)
  run_skills "$dir" "$dir/manifest" install
  [ "$FM_RC" -eq 0 ] || fail "install exited $FM_RC: $FM_ERR"
  calls=$(grep -c . "$dir/npx-calls")
  [ "$calls" -eq 8 ] || fail "install fetched $calls source(s), expected 8"
  for skill in tasks-axi gh-axi chrome-devtools-axi quota-axi mongosh-axi lavish no-mistakes axi; do
    [ -f "$dir/home/.agents/skills/$skill/SKILL.md" ] \
      || fail "install did not land the $skill skill"
  done
  run_skills "$dir" "$dir/manifest" check
  [ -z "$FM_OUT" ] || fail "check still reports missing skills after install: $FM_OUT"
  pass "install lands every manifest skill in one pass"
}

test_second_install_is_a_genuine_no_op() {
  local dir before after calls
  dir=$(new_case install-idempotent)
  run_skills "$dir" "$dir/manifest" install
  [ "$FM_RC" -eq 0 ] || fail "first install exited $FM_RC: $FM_ERR"
  before=$(find "$dir/home/.agents/skills" -type f -exec stat -c '%n %Y %s' {} \; | sort)
  : > "$dir/npx-calls"
  run_skills "$dir" "$dir/manifest" install
  [ "$FM_RC" -eq 0 ] || fail "second install exited $FM_RC: $FM_ERR"
  calls=$(grep -c . "$dir/npx-calls" || true)
  [ "$calls" -eq 0 ] || fail "the second install re-downloaded $calls source(s); it must be a no-op"
  [ -z "$FM_OUT" ] || fail "the second install reported work it did not do: $FM_OUT"
  after=$(find "$dir/home/.agents/skills" -type f -exec stat -c '%n %Y %s' {} \; | sort)
  [ "$before" = "$after" ] || fail "the second install churned files in the install root"
  pass "a second install is a genuine no-op: no fetch, no file touched"
}

test_install_never_touches_an_unmanaged_skill() {
  local dir before after
  dir=$(new_case install-additive)
  mkdir -p "$dir/home/.agents/skills/captains-own"
  printf 'name: captains-own\nbody: precious\n' > "$dir/home/.agents/skills/captains-own/SKILL.md"
  before=$(stat -c '%Y %s' "$dir/home/.agents/skills/captains-own/SKILL.md")
  run_skills "$dir" "$dir/manifest" install
  [ "$FM_RC" -eq 0 ] || fail "install exited $FM_RC: $FM_ERR"
  [ -f "$dir/home/.agents/skills/captains-own/SKILL.md" ] \
    || fail "install REMOVED a skill the manifest does not name"
  after=$(stat -c '%Y %s' "$dir/home/.agents/skills/captains-own/SKILL.md")
  [ "$before" = "$after" ] || fail "install rewrote a skill the manifest does not name"
  grep -Fq 'precious' "$dir/home/.agents/skills/captains-own/SKILL.md" \
    || fail "install clobbered the contents of an unmanaged skill"
  pass "install is additive-only: an unmanaged skill is never removed or rewritten"
}

test_install_does_not_overwrite_a_managed_skill() {
  local dir
  dir=$(new_case install-no-overwrite)
  mkdir -p "$dir/home/.agents/skills/tasks-axi"
  printf 'name: tasks-axi\nbody: local-edit\n' > "$dir/home/.agents/skills/tasks-axi/SKILL.md"
  run_skills "$dir" "$dir/manifest" install
  [ "$FM_RC" -eq 0 ] || fail "install exited $FM_RC: $FM_ERR"
  grep -Fq 'local-edit' "$dir/home/.agents/skills/tasks-axi/SKILL.md" \
    || fail "install overwrote an already-present manifest skill"
  grep -Fq 'tasks-axi' "$dir/npx-calls" \
    && fail "install re-fetched an already-present manifest skill"
  pass "an already-present manifest skill is left exactly as it is"
}

test_install_can_target_named_skills() {
  local dir calls
  dir=$(new_case install-named)
  run_skills "$dir" "$dir/manifest" install gh-axi
  [ "$FM_RC" -eq 0 ] || fail "targeted install exited $FM_RC: $FM_ERR"
  calls=$(grep -c . "$dir/npx-calls")
  [ "$calls" -eq 1 ] || fail "targeted install fetched $calls source(s), expected 1"
  [ -f "$dir/home/.agents/skills/gh-axi/SKILL.md" ] || fail "targeted install did not land gh-axi"
  [ -e "$dir/home/.agents/skills/axi" ] && fail "targeted install landed an unrequested skill"
  pass "install accepts named skills and installs only those"
}

test_install_refuses_an_unknown_skill_name() {
  local dir
  dir=$(new_case install-unknown)
  run_skills "$dir" "$dir/manifest" install not-a-fleet-skill
  [ "$FM_RC" -ne 0 ] || fail "install accepted a skill the manifest does not name"
  case "$FM_ERR" in
    *"is not named by"*) ;;
    *) fail "install refused an unknown skill without saying why: $FM_ERR" ;;
  esac
  pass "install refuses a skill name the manifest does not carry"
}

test_install_reports_a_failed_source() {
  local dir
  dir="$TMP_ROOT/install-failure"
  mkdir -p "$dir/home/.agents/skills"
  make_fake_npx "$dir" gh-axi >/dev/null
  : > "$dir/npx-calls"
  cp "$MANIFEST" "$dir/manifest"
  run_skills "$dir" "$dir/manifest" install
  [ "$FM_RC" -ne 0 ] || fail "install exited 0 despite a failed source"
  case "$FM_ERR" in
    *"install failed for gh-axi"*) ;;
    *) fail "install did not name the failed skill: $FM_ERR" ;;
  esac
  # The rest of the manifest still lands: one bad source does not abort the pass.
  [ -f "$dir/home/.agents/skills/axi/SKILL.md" ] \
    || fail "a failed source aborted the remaining installs"
  pass "a failed source is reported by name and does not abort the remaining installs"
}

# --- manifest defects are refused loudly -------------------------------------

test_malformed_line_is_refused() {
  local dir body
  body='kunchenguid/tasks-axi@tasks-axi
this-is-not-a-source'
  dir=$(new_case manifest-malformed "$body")
  run_skills "$dir" "$dir/manifest" check
  [ "$FM_RC" -ne 0 ] || fail "a malformed manifest line was silently skipped"
  case "$FM_ERR" in
    *"line 2"*) ;;
    *) fail "the refusal did not point at the offending line: $FM_ERR" ;;
  esac
  pass "a malformed manifest line is refused loudly, never skipped"
}

test_comments_and_blank_lines_are_ignored() {
  local dir
  dir=$(new_case manifest-comments '# a comment

kunchenguid/tasks-axi@tasks-axi')
  run_skills "$dir" "$dir/manifest" list
  [ "$FM_RC" -eq 0 ] || fail "comments or blank lines broke the parse: $FM_ERR"
  [ "$FM_OUT" = "kunchenguid/tasks-axi@tasks-axi tasks-axi" ] \
    || fail "unexpected parse result: $FM_OUT"
  pass "comments and blank lines are ignored"
}

test_missing_manifest_is_refused() {
  local dir
  dir=$(new_case manifest-absent)
  run_skills "$dir" "$dir/no-such-manifest" check
  [ "$FM_RC" -ne 0 ] || fail "an absent manifest was treated as an empty manifest"
  case "$FM_ERR" in
    *"no skills manifest at"*) ;;
    *) fail "an absent manifest was refused without saying why: $FM_ERR" ;;
  esac
  pass "an absent manifest is refused, never read as empty"
}

# --- wiring ------------------------------------------------------------------

test_bootstrap_runs_the_check_in_both_modes() {
  grep -q 'fm-skills-manifest.sh" check' "$BOOT" \
    || fail "bin/fm-bootstrap.sh does not run the skills-manifest check"
  # The call must sit OUTSIDE the FM_BOOTSTRAP_DETECT_ONLY mutating-sweep block,
  # so a read-only session still sees the gap. That block is the final one in the
  # file, so the check must appear before it.
  local check_line sweep_line
  check_line=$(grep -n 'fm-skills-manifest.sh" check' "$BOOT" | head -1 | cut -d: -f1)
  sweep_line=$(grep -n 'FM_BOOTSTRAP_DETECT_ONLY:-0}" != 1 \]; then' "$BOOT" | tail -1 | cut -d: -f1)
  [ -n "$sweep_line" ] || fail "could not locate the mutating-sweep block in bin/fm-bootstrap.sh"
  [ "$check_line" -lt "$sweep_line" ] \
    || fail "the skills-manifest check runs inside the mutating-sweep block; a read-only session would miss it"
  pass "bootstrap runs the detect-only skills check in both modes"
}

test_bootstrap_never_installs_skills() {
  grep -q 'fm-skills-manifest.sh" install' "$BOOT" \
    && fail "bin/fm-bootstrap.sh installs skills; session start must detect first"
  pass "bootstrap never installs skills itself"
}

test_secondmate_seed_applies_the_manifest() {
  local seed="$ROOT/bin/fm-home-seed.sh"
  grep -q 'fm-skills-manifest.sh" install' "$seed" \
    || fail "bin/fm-home-seed.sh does not apply the skills manifest"
  grep -q 'ensure_fleet_skills' "$seed" \
    || fail "bin/fm-home-seed.sh does not call ensure_fleet_skills during a seed"
  pass "secondmate seeding applies the fleet skills manifest with no manual step"
}

# --- opt-in real-network case ------------------------------------------------

test_real_sources_resolve() {
  if [ "${FM_TEST_SKILLS_NETWORK:-0}" != 1 ]; then
    printf 'skip: network install not requested (set FM_TEST_SKILLS_NETWORK=1)\n'
    return 0
  fi
  local dir out rc
  dir="$TMP_ROOT/network"
  mkdir -p "$dir/home"
  out="$dir/out"
  FM_SKILLS_HOME="$dir/home" "$SKILLS" install > "$out" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "real install failed: $(cat "$out")"
  FM_SKILLS_HOME="$dir/home" "$SKILLS" check > "$out" 2>&1
  [ ! -s "$out" ] || fail "real install left skills missing: $(cat "$out")"
  pass "every manifest source resolves and installs against a throwaway root"
}

test_tracked_manifest_parses
test_tracked_manifest_seeded_sources
test_tracked_manifest_one_source_per_line
test_check_reports_missing_without_installing
test_check_is_silent_when_converged
test_check_is_the_default_subcommand
test_install_installs_every_missing_skill
test_second_install_is_a_genuine_no_op
test_install_never_touches_an_unmanaged_skill
test_install_does_not_overwrite_a_managed_skill
test_install_can_target_named_skills
test_install_refuses_an_unknown_skill_name
test_install_reports_a_failed_source
test_malformed_line_is_refused
test_comments_and_blank_lines_are_ignored
test_missing_manifest_is_refused
test_bootstrap_runs_the_check_in_both_modes
test_bootstrap_never_installs_skills
test_secondmate_seed_applies_the_manifest
test_real_sources_resolve
