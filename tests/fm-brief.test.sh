#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issue
# #166): each ship-mode branch builds its Definition-of-done text with
# `VAR=$(cat <<EOF ... EOF)`. Bash's lexer tracks quote state through the
# heredoc body while it scans for the matching `)` of the command
# substitution, so a single unescaped apostrophe anywhere in that body breaks
# parsing of the *entire rest of the script* - `bash -n` fails, not just the
# generated brief. A plain `cat > file <<EOF ... EOF` (not wrapped in `$(...)`)
# is unaffected, so the secondmate charter block does not need this guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# The script itself must always parse. This is the direct regression test for
# issue #166: a stray apostrophe in any of the three DOD heredoc bodies
# (no-mistakes/direct-PR/local-only) breaks `bash -n` on the whole file.
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-brief.sh emitted unexpected output: $out"
  pass "fm-brief.sh: bash -n succeeds"
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode, so each ship-mode DOD branch is
# exercised. A project absent from the registry defaults to no-mistakes.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- push-proj [direct-push] - fixture for direct-push mode (added 2026-07-24)
- push-autoland-proj [direct-push +autoland] - fixture for direct-push self-land (added 2026-07-26)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
- hyfin [no-mistakes] - fixture for hyfin live-stack repro block (added 2026-08-02)
- hyfin-server [direct-push] - fixture for hyfin-server live-stack repro block (added 2026-08-02)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_proj in "brief-nomistakes-a1:no-registry-proj" "brief-directpr-a2:direct-proj" "brief-directpush-a2b:push-proj" "brief-autoland-a2c:push-autoland-proj" "brief-localonly-a3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id $proj should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/setup-complete gate protection"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
    # Pipeline-driving modes must force --intent on every no-mistakes run so the
    # pipeline never spends an extra model call deriving intent. direct-PR and
    # local-only do not drive the pipeline, so they carry no such line.
    case $id in
      brief-nomistakes-*|brief-directpush-*|brief-autoland-*)
        assert_grep 'ALWAYS pass `--intent' "$brief" \
          "$id: brief must require --intent on every no-mistakes axi run" ;;
      *)
        assert_no_grep 'ALWAYS pass `--intent' "$brief" \
          "$id: non-pipeline brief should not mention --intent" ;;
    esac
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/direct-push/local-only briefs generate cleanly"
}

# The direct-push DOD must: run the FULL no-mistakes pipeline (so it carries the
# doctor setup step and the wrong-branch-attach preflight guard), treat skipped
# PR/CI and a missing NO_MISTAKES_BITBUCKET_EMAIL as expected rather than a
# blocker, then require an explicit push to origin fm/<id> with no PR-url or
# checks-green wait. Landing stays with the configured merge authority.
test_direct_push_dod_semantics() {
  local home id brief
  home="$TMP_ROOT/direct-push-home"
  write_registry "$home"
  id="brief-directpush-b3"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" push-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "direct-push brief was not scaffolded"
  assert_grep "ships **direct-push**" "$brief" \
    "direct-push brief did not declare its delivery mode"
  # Full pipeline, including the doctor setup step and the preflight guard.
  assert_grep "no-mistakes doctor" "$brief" \
    "direct-push brief lost the no-mistakes doctor setup step"
  assert_grep "$ROOT/bin/fm-nm-preflight.sh" "$brief" \
    "direct-push brief lost the wrong-branch-attach preflight guard"
  assert_grep "a run ending \`passed\` with those steps skipped is COMPLETE" "$brief" \
    "direct-push brief did not state skipped PR/CI is complete"
  assert_grep "missing NO_MISTAKES_BITBUCKET_EMAIL" "$brief" \
    "direct-push brief did not bake in the NO_MISTAKES_BITBUCKET_EMAIL note"
  assert_grep "is NOT a blocker" "$brief" \
    "direct-push brief did not say the bitbucket-email report is not a blocker"
  # Explicit push to origin and report the head, no PR wait.
  assert_grep "git push origin HEAD:fm/$id" "$brief" \
    "direct-push brief did not require the explicit origin push of its branch"
  assert_grep "Do NOT wait for a PR url or checks-green" "$brief" \
    "direct-push brief did not forbid waiting on a PR url or CI"
  assert_grep "The configured merge authority lands the branch on the forge" "$brief" \
    "direct-push brief lost configured merge authority"
  # The worker owns the whole finish itself; committing or pushing is never "done".
  assert_grep "Committing locally is NEVER done" "$brief" \
    "direct-push brief did not state committing locally is never done"
  assert_grep "run the FULL /no-mistakes pipeline yourself" "$brief" \
    "direct-push brief did not tell the worker to run the pipeline itself"
  assert_no_grep "Firstmate will then instruct you to run /no-mistakes" "$brief" \
    "direct-push brief must not defer pipeline start to a firstmate steer"
  assert_no_grep "open a PR" "$brief" \
    "direct-push brief must not tell the worker to open a PR"
  pass "fm-brief.sh: direct-push DOD runs the full pipeline then pushes to origin without a PR wait"
}

# The direct-push +autoland DOD keeps the full-pipeline body but replaces the
# push-and-stop tail with a guarded self-land: after the pipeline is green the crew
# merges its OWN fm/<id> branch onto the origin default branch as a clean --no-ff
# merge (through a private landing ref, since the default branch is checked out in
# the shared primary), reports the merge evidence, and never opens a PR. The
# guardrails - green only, own branch only, conflict escalates, never delete a
# branch - must be baked into the generated contract.
test_direct_push_autoland_dod_semantics() {
  local home id brief
  home="$TMP_ROOT/autoland-home"
  write_registry "$home"
  id="brief-autoland-b4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" push-autoland-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "direct-push +autoland brief was not scaffolded"
  assert_grep "ships **direct-push +autoland**" "$brief" \
    "autoland brief did not declare the self-land delivery mode"
  # Still the full pipeline body: doctor setup, preflight guard, skipped-PR/CI note.
  assert_grep "no-mistakes doctor" "$brief" \
    "autoland brief lost the no-mistakes doctor setup step"
  assert_grep "$ROOT/bin/fm-nm-preflight.sh" "$brief" \
    "autoland brief lost the wrong-branch-attach preflight guard"
  assert_grep "a run ending \`passed\` with those steps skipped is COMPLETE" "$brief" \
    "autoland brief did not carry the full pipeline body"
  # Self-land mechanics and guardrails.
  assert_grep "ONLY after the pipeline reports \`passed\`" "$brief" \
    "autoland brief did not gate self-land on a green pipeline"
  assert_grep "ONLY as a clean \`--no-ff\` merge" "$brief" \
    "autoland brief did not require a --no-ff merge"
  assert_grep "git merge --no-ff \"fm/$id\"" "$brief" \
    "autoland brief did not spell out the --no-ff merge of its own branch"
  assert_grep "fm-landing:" "$brief" \
    "autoland brief did not land through a private landing ref"
  assert_grep "git merge --abort" "$brief" \
    "autoland brief did not tell the worker to abort on conflict"
  assert_grep "needs authoring-lane resolve" "$brief" \
    "autoland brief did not escalate a conflict to the authoring lane"
  assert_grep "Never delete any branch" "$brief" \
    "autoland brief did not forbid deleting a branch"
  assert_grep "done: landed fm/$id" "$brief" \
    "autoland brief did not require the merge-evidence done line"
  # The worker owns the whole finish itself; committing or pushing is never "done".
  assert_grep "Committing locally is NEVER done" "$brief" \
    "autoland brief did not state committing locally is never done"
  assert_no_grep "Firstmate will then instruct you to run /no-mistakes" "$brief" \
    "autoland brief must not defer pipeline start to a firstmate steer"
  # It self-lands, so it must NOT keep the push-and-stop tail or open a PR.
  assert_no_grep "git push origin HEAD:fm/$id" "$brief" \
    "autoland brief must not keep the plain push-and-stop tail"
  assert_no_grep "open a PR" "$brief" \
    "autoland brief must not tell the worker to open a PR"
  pass "fm-brief.sh: direct-push +autoland DOD self-lands the green branch with the baked-in guardrails"
}

# hyfin and hyfin-server ship briefs carry a "Live stack repro" block with the
# exact own-local-stack commands so a live merchant repro is never falsely declared
# impossible. Any other repo, and the scout variant, must NOT carry it. The block
# carries the non-blocking browser announce.
test_hyfin_live_stack_repro_block() {
  local home id brief
  home="$TMP_ROOT/hyfin-repro-home"
  write_registry "$home"
  # hyfin ship brief carries the block.
  id="brief-hyfin-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" hyfin >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "hyfin ship brief was not scaffolded"
  assert_grep "Live stack repro (hyfin / hyfin-server only)" "$brief" \
    "hyfin ship brief lost the live-stack repro heading"
  assert_grep "stand up your OWN local stack" "$brief" \
    "hyfin ship brief did not tell the worker to stand up its own stack"
  assert_grep "Recaptcha auto-bypasses locally" "$brief" \
    "hyfin ship brief did not state recaptcha auto-bypasses locally"
  assert_grep "HYFIN_LANE=<N>" "$brief" \
    "hyfin ship brief lost the Playwright lane pointer"
  assert_grep "docs/e2e-lanes.md" "$brief" \
    "hyfin ship brief lost the e2e-lanes doc reference"
  assert_grep 'working: BROWSER START' "$brief" \
    "hyfin ship brief dropped the non-blocking browser announce"
  # hyfin-server ship brief carries it too.
  id="brief-hyfinserver-c2"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" hyfin-server >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "Live stack repro (hyfin / hyfin-server only)" "$brief" \
    "hyfin-server ship brief lost the live-stack repro block"
  # A non-hyfin repo must NOT carry it.
  id="brief-nonhyfin-c3"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" push-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_no_grep "Live stack repro" "$brief" \
    "a non-hyfin ship brief wrongly carried the live-stack repro block"
  # The scout variant of hyfin must NOT carry it (repro block is ship-only).
  id="brief-hyfin-scout-c4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" hyfin --scout >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_no_grep "Live stack repro" "$brief" \
    "the hyfin scout brief wrongly carried the ship-only live-stack repro block"
  pass "fm-brief.sh: hyfin/hyfin-server ship briefs carry the live-stack repro block, others and scouts do not"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`no-mistakes axi run --help`' "$brief" \
    "no-mistakes DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "no-mistakes DOD must render literal backticks around help"
  assert_no_grep "no-mistakes' own guidance" "$brief" \
    "no-mistakes DOD regressed to the apostrophe form that breaks bash -n"
  pass "fm-brief.sh: no-mistakes DOD wording avoids the apostrophe regression"
}

# A no-mistakes brief must send the crewmate through the pre-run guard before it
# invokes the pipeline, with an absolute path it can run from its own worktree,
# and must say what to do when the guard refuses. It must also carry the
# drive-by-id instruction: `axi status`/`axi logs` resolve repo-wide when the
# lane's branch has no run of its own, so a lane that reads them bare can be
# handed a concurrent lane's run and answer findings that are not its own
# (bin/fm-nm-preflight.sh; data/learnings.md `no-mistakes-wrong-repo-attach`).
test_no_mistakes_dod_requires_preflight() {
  local home id brief
  home="$TMP_ROOT/preflight-home"
  mkdir -p "$home/data"
  id="brief-preflight-b2"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "$ROOT/bin/fm-nm-preflight.sh" "$brief" \
    "no-mistakes DOD lost the pre-run guard step, or stopped giving it an absolute path"
  assert_grep "If it refuses, do NOT invoke /no-mistakes" "$brief" \
    "no-mistakes DOD does not say to stop when the guard refuses"
  # A concurrent lane's run must never be driven from here.
  assert_grep "never respond to or abort that run" "$brief" \
    "no-mistakes DOD does not warn against driving the other lane's run"
  # Driving by explicit id is what makes the repo-wide display fallback harmless.
  assert_grep "axi status --run" "$brief" \
    "no-mistakes DOD does not tell the lane to read its run by explicit id"
  assert_grep "axi logs --run" "$brief" \
    "no-mistakes DOD does not tell the lane to read its logs by explicit id"
  pass "fm-brief.sh: no-mistakes DOD requires the pre-run guard and drive-by-id reads"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'or a blocker clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the unresolved-decision policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`decision-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared decision policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# Scout and secondmate paths still scaffold well-formed briefs.
test_scout_and_secondmate_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"

  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-sm-q6 --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "secondmate charter must declare its role"
  pass "fm-brief: scout and secondmate code paths still scaffold well-formed briefs"
}

# The heavy-run serialization point only helps if crewmates actually route
# through it, so the generated ship and scout briefs must carry the instruction.
test_briefs_route_heavy_runs_through_the_runner() {
  local home brief
  home="$TMP_ROOT/heavy-run-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-heavy-ship some-proj >/dev/null 2>&1 \
    || fail "fm-brief.sh ship scaffold exited non-zero"
  brief="$home/data/brief-heavy-ship/brief.md"
  assert_grep "bin/fm-heavy-run.sh --task brief-heavy-ship --" "$brief" \
    "ship brief must route heavy runs through fm-heavy-run.sh with its own task id"
  assert_grep "queued notice while you wait; that is normal, not a hang" "$brief" \
    "ship brief must tell the crewmate a queued run is not a hang"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-heavy-scout some-proj --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$home/data/brief-heavy-scout/brief.md"
  assert_grep "bin/fm-heavy-run.sh --task brief-heavy-scout --" "$brief" \
    "scout brief must route heavy runs through fm-heavy-run.sh too"
  pass "fm-brief.sh: ship and scout briefs route heavy runs through the serialization point"
}

# The Token-efficiency section is rtk-aware and detected at scaffold time. When rtk is
# present (FM_BRIEF_RTK=1) the ship and scout briefs must tell the worker to prefer
# rtk-wrapped runs and must keep it subordinate to Rule 8 (rtk goes INSIDE fm-heavy-run,
# which still owns the real exit status). When rtk is absent (FM_BRIEF_RTK=0) the same
# section must reassure the worker that plain commands are fine, and must NOT push rtk, so
# a host without rtk is never told to run a tool it lacks. The secondmate charter never
# carries the section - it supervises rather than runs suites.
test_briefs_carry_rtk_token_efficiency_section() {
  local home brief kind
  home="$TMP_ROOT/rtk-token-home"
  mkdir -p "$home/data"

  # rtk PRESENT: ship and scout both prefer rtk and keep it under fm-heavy-run.
  for kind in ship scout; do
    if [ "$kind" = ship ]; then
      FM_HOME="$home" FM_BRIEF_RTK=1 "$ROOT/bin/fm-brief.sh" brief-rtk-on-ship some-proj >/dev/null 2>&1 \
        || fail "fm-brief.sh ship scaffold (rtk on) exited non-zero"
      brief="$home/data/brief-rtk-on-ship/brief.md"
    else
      FM_HOME="$home" FM_BRIEF_RTK=1 "$ROOT/bin/fm-brief.sh" brief-rtk-on-scout some-proj --scout >/dev/null 2>&1 \
        || fail "fm-brief.sh scout scaffold (rtk on) exited non-zero"
      brief="$home/data/brief-rtk-on-scout/brief.md"
    fi
    assert_grep "# Token efficiency" "$brief" \
      "$kind brief (rtk on) must carry the Token efficiency section"
    assert_grep 'token-optimizing CLI proxy' "$brief" \
      "$kind brief (rtk on) must name rtk as the token-optimizing proxy"
    # shellcheck disable=SC2016 # Literal backticks and the command name must stay unexpanded.
    assert_grep '`rtk test <runner>`' "$brief" \
      "$kind brief (rtk on) must recommend rtk test for failures-only output"
    assert_grep "is installed here" "$brief" \
      "$kind brief (rtk on) must state rtk is installed on this host"
    # rtk must not undermine the heavy-run serialization point or its real exit status.
    assert_grep "Heavy runs still go THROUGH" "$brief" \
      "$kind brief (rtk on) must keep rtk subordinate to the fm-heavy-run serialization point"
    assert_grep "real exit status" "$brief" \
      "$kind brief (rtk on) must remind the worker fm-heavy-run still owns the real exit status"
    assert_no_grep "plain commands are completely fine" "$brief" \
      "$kind brief (rtk on) must not carry the rtk-absent wording"
  done

  # rtk ABSENT: ship and scout both say plain commands are fine and do NOT push rtk.
  for kind in ship scout; do
    if [ "$kind" = ship ]; then
      FM_HOME="$home" FM_BRIEF_RTK=0 "$ROOT/bin/fm-brief.sh" brief-rtk-off-ship some-proj >/dev/null 2>&1 \
        || fail "fm-brief.sh ship scaffold (rtk off) exited non-zero"
      brief="$home/data/brief-rtk-off-ship/brief.md"
    else
      FM_HOME="$home" FM_BRIEF_RTK=0 "$ROOT/bin/fm-brief.sh" brief-rtk-off-scout some-proj --scout >/dev/null 2>&1 \
        || fail "fm-brief.sh scout scaffold (rtk off) exited non-zero"
      brief="$home/data/brief-rtk-off-scout/brief.md"
    fi
    assert_grep "# Token efficiency" "$brief" \
      "$kind brief (rtk off) must still carry the Token efficiency section"
    assert_grep "plain commands are completely fine" "$brief" \
      "$kind brief (rtk off) must reassure the worker that plain commands are fine"
    assert_no_grep "is installed here" "$brief" \
      "$kind brief (rtk off) must not claim rtk is installed"
    # shellcheck disable=SC2016 # Literal backticks and the command name must stay unexpanded.
    assert_no_grep '`rtk test <runner>`' "$brief" \
      "$kind brief (rtk off) must not tell a worker to run rtk it lacks"
  done

  # The secondmate charter never carries the section.
  FM_HOME="$home" FM_BRIEF_RTK=1 FM_SECONDMATE_CHARTER='Supervise alpha.' \
    "$ROOT/bin/fm-brief.sh" brief-rtk-sm --secondmate --no-projects >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  assert_no_grep "# Token efficiency" "$home/data/brief-rtk-sm/brief.md" \
    "secondmate charter must not carry the crew Token efficiency section"
  pass "fm-brief.sh: ship and scout briefs carry the rtk-aware Token efficiency section, secondmate does not"
}

# These four standing captain rules used to exist only as hand-typed steers, so a
# freshly spawned crewmate never saw them. They must be structural in the scaffold.
test_briefs_bind_the_shared_machine_rules() {
  local home brief kind
  home="$TMP_ROOT/shared-machine-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    if [ "$kind" = ship ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-rules-ship some-proj >/dev/null 2>&1 \
        || fail "fm-brief.sh ship scaffold exited non-zero"
      brief="$home/data/brief-rules-ship/brief.md"
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-rules-scout some-proj --scout >/dev/null 2>&1 \
        || fail "fm-brief.sh scout scaffold exited non-zero"
      brief="$home/data/brief-rules-scout/brief.md"
    fi
    assert_grep 'VITEST_MAX_WORKERS=2' "$brief" \
      "$kind brief must cap test parallelism at 2 workers"
    assert_no_grep 'VITEST_MAX_WORKERS=4' "$brief" \
      "$kind brief must never emit the 4-worker cap"
    assert_grep 'working: TEST START' "$brief" \
      "$kind brief must require a TEST START announcement"
    assert_grep 'working: TEST END' "$brief" \
      "$kind brief must require a TEST END announcement"
    assert_grep 'working: BROWSER START' "$brief" \
      "$kind brief must require a BROWSER START announcement"
    assert_grep 'working: BROWSER END' "$brief" \
      "$kind brief must require a BROWSER END announcement"
    assert_grep 'never wait on firstmate for a slot' "$brief" \
      "$kind brief must keep the browser announce non-blocking"
    assert_no_grep 'working: BROWSER WAIT' "$brief" \
      "$kind brief must not make the crewmate wait for a browser slot"
  done

  brief="$home/data/brief-rules-ship/brief.md"
  assert_grep '# Test coverage declaration' "$brief" \
    "ship brief must carry the coverage declaration section"
  assert_grep 'built this change test-first' "$brief" \
    "ship brief must require a test-first statement in the final report"
  assert_grep 'end-to-end coverage' "$brief" \
    "ship brief must require an end-to-end coverage statement"
  assert_grep 'does not block the merge' "$brief" \
    "a declared coverage gap must be stated, not treated as a merge blocker"

  # The coverage declaration is rule 4 of the four standing test-safety rules, so
  # it must reach a freshly spawned scout too, not only a ship worker.
  brief="$home/data/brief-rules-scout/brief.md"
  assert_grep '# Test coverage declaration' "$brief" \
    "scout brief must carry the coverage declaration section"
  assert_grep 'built test-first' "$brief" \
    "scout brief must require a test-first statement in the final report"
  assert_grep 'end-to-end coverage' "$brief" \
    "scout brief must require an end-to-end coverage statement"
  pass "fm-brief.sh: ship and scout briefs bind the shared-machine and coverage rules"
}

# The standing captain rules used to reach workers only when firstmate remembered to
# paste them onto a brief, so a lane whose brief predated a rule never saw it (one such
# lane force-pushed within an hour of the never-force rule being set). They must be
# structural in every generated scaffold. Rules 5 and 6 ride on every ship and scout
# brief rather than behind a flag: {TASK} is filled after scaffolding, so a flag firstmate
# forgets to pass is worthless, while an always-present rule costs a few lines.
test_ship_and_scout_briefs_bind_the_standing_captain_rules() {
  local home brief kind
  home="$TMP_ROOT/captain-rules-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-captain-ship some-proj >/dev/null 2>&1 \
    || fail "fm-brief.sh ship scaffold exited non-zero"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-captain-scout some-proj --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"

  for kind in ship scout; do
    brief="$home/data/brief-captain-$kind/brief.md"
    assert_grep "# Standing captain rules" "$brief" \
      "$kind brief must carry the standing captain rules section"
    # C1. never force anything
    assert_grep "C1. Never force anything" "$brief" \
      "$kind brief must label the never-force rule C1 so a steer cannot collide with the Rules list"
    assert_grep "Never force-push, never force a release, and never decide on" "$brief" \
      "$kind brief must forbid force-push, force-release, and self-directed branch deletion"
    assert_grep "is ordinary tooling behavior and is not what this" "$brief" \
      "$kind brief must exempt the guarded teardown and fleet-sync paths from the deletion rule"
    assert_grep "push to a NEW branch" "$brief" \
      "$kind brief must give the new-branch escape hatch when a push is blocked"
    # C2. understand the why
    assert_grep "Understand the WHY before acting" "$brief" \
      "$kind brief must forbid working the wording mechanically"
    assert_grep "ask firstmate" "$brief" \
      "$kind brief must send an unclear reason back to firstmate"
    assert_grep "grilling session" "$brief" \
      "$kind brief must name the grilling session as the way to ask"
    # C3. plan first on every harness, with wayfinder where the runtime has it
    # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
    assert_grep '`wayfinder` skill' "$brief" \
      "$kind brief must name the wayfinder skill as the way to plan"
    assert_grep "MANDATORY, whatever runtime you are" "$brief" \
      "$kind brief must keep planning mandatory on every harness, not only where wayfinder resolves"
    assert_grep "plan by your own means" "$brief" \
      "$kind brief must stay satisfiable on a runtime without the wayfinder skill"
    # C4. caveman ultra prose, reports included. The captain widened the scope on
    # 2026-07-25, so a report compresses too and only its evidence stays verbatim.
    assert_grep "C4. Write your prose in caveman ultra style" "$brief" \
      "$kind brief must bind caveman ultra prose without an ephemeral-only escape hatch"
    assert_no_grep "EPHEMERAL prose in caveman ultra style" "$brief" \
      "$kind brief must not scope caveman ultra prose to ephemeral output only"
    assert_no_grep "DURABLE documents stay in normal" "$brief" \
      "$kind brief must not exempt durable documents wholesale"
    assert_grep "AND your reports, including the scout" "$brief" \
      "$kind brief must bind reports to the compression rule"
    # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
    assert_grep 'data/<id>/report.md' "$brief" \
      "$kind brief must name the scout report as a compressed report"
    assert_grep "status lines, and error strings stay VERBATIM" "$brief" \
      "$kind brief must keep report evidence verbatim inside a compressed report"
    # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
    assert_grep '`AGENTS.md`' "$brief" \
      "$kind brief must keep project AGENTS.md in normal English"
    assert_grep "anything a tool, forge, or CI parses" "$brief" \
      "$kind brief must keep code, commits, PR text, and tool-parsed output in normal English"
    assert_grep "Section 9 of the firstmate repo" "$brief" \
      "$kind brief must point at the single tracked owner of the rule"
    assert_grep "irreversible-action confirmations" "$brief" \
      "$kind brief must keep the security and irreversible-action carve-outs"
    assert_grep "abbreviate identifiers, API names, CLI commands, or error strings" "$brief" \
      "$kind brief must forbid abbreviating identifiers and commands"
    # C5. server ports
    assert_grep "Never bind port 443 or 3000" "$brief" \
      "$kind brief must forbid the captain own default server ports"
    assert_grep "non-default port" "$brief" \
      "$kind brief must send a started server to a non-default port"
    # C6. Mattermost-sourced tasks
    assert_grep "If this task came from a Mattermost thread" "$brief" \
      "$kind brief must carry the Mattermost re-read rule as a self-guarding conditional"
    assert_grep "never trust the queue-time summary" "$brief" \
      "$kind brief must distrust the queue-time summary of a Mattermost thread"
    assert_grep "ADD the missing end-to-end coverage" "$brief" \
      "$kind brief must require added coverage when the reported bug is already fixed"
  done
  pass "fm-brief.sh: ship and scout briefs bind the standing captain rules structurally"
}

# A secondmate supervises rather than implements, so it carries the subset that
# genuinely applies to its own conduct; its crewmates get the full set from their
# own generated briefs.
test_secondmate_charter_binds_the_applicable_captain_rules() {
  local home brief
  home="$TMP_ROOT/captain-rules-secondmate-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    "$ROOT/bin/fm-brief.sh" brief-captain-sm --secondmate --no-projects >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$home/data/brief-captain-sm/brief.md"
  assert_grep "# Standing captain rules" "$brief" \
    "secondmate charter must carry the standing captain rules section"
  assert_grep "C1. Never force anything" "$brief" \
    "secondmate charter must label the never-force rule C1"
  assert_grep "Never force-push, never force a release, and never decide on" "$brief" \
    "secondmate charter must forbid forcing and self-directed branch deletion - a supervisor can force-push too"
  assert_grep "is ordinary tooling behavior and is not what this" "$brief" \
    "secondmate charter must exempt the guarded teardown and fleet-sync paths from the deletion rule"
  assert_grep "C2. Understand the WHY before acting" "$brief" \
    "secondmate charter must forbid acting on routed work mechanically, labelled C2"
  assert_grep "grilling session" "$brief" \
    "secondmate charter must route an unclear reason back as a grilling session"
  # The main firstmate never reads a secondmate chat, so C2 must name the status
  # return path or the ask is lost and the domain stalls silently.
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep 'append a `needs-decision` status' "$brief" \
    "secondmate charter C2 must raise the grilling request on the status path, not in chat"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep 'carrying the same `corr=<id>` token' "$brief" \
    "secondmate charter C2 must carry the correlation token of a marked request"
  assert_grep "Never ask only in this chat" "$brief" \
    "secondmate charter C2 must forbid a chat-only question"
  # Labels are stable fleet-wide: the caveman rule is C4 in every block, and the
  # secondmate subset keeps the C3 gap rather than renumbering, so a steer that
  # names a rule always means the same rule to a crewmate and to a secondmate.
  assert_grep "C4. Write your prose in caveman ultra style" "$brief" \
    "secondmate charter must label the caveman rule C4, matching the ship and scout block"
  assert_no_grep "C3." "$brief" \
    "secondmate charter must keep the C3 gap instead of renumbering its rules contiguously"
  assert_no_grep "EPHEMERAL prose in caveman ultra style" "$brief" \
    "secondmate charter must not scope caveman ultra prose to ephemeral reports only"
  assert_no_grep "DURABLE documents stay in normal" "$brief" \
    "secondmate charter must not exempt durable documents wholesale"
  assert_grep "AND every report you or your" "$brief" \
    "secondmate charter must bind every report to the compression rule"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep 'data/<id>/report.md' "$brief" \
    "secondmate charter must name the scout report as a compressed report"
  assert_grep "status lines, and error strings stay VERBATIM" "$brief" \
    "secondmate charter must keep report evidence verbatim"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep '`AGENTS.md`' "$brief" \
    "secondmate charter must keep project AGENTS.md in normal English"
  assert_grep "anything a tool, forge, or CI parses" "$brief" \
    "secondmate charter must keep tool-parsed text in normal English"
  assert_grep "Section 9 of the firstmate repo" "$brief" \
    "secondmate charter must point at the single tracked owner of the rule"
  pass "fm-brief.sh: secondmate charter binds the captain rules that apply to a supervising home"
}

# The rules must not displace the contracts they sit beside.
test_captain_rules_preserve_existing_brief_contracts() {
  local home brief
  home="$TMP_ROOT/captain-rules-coexist-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-captain-coexist some-proj >/dev/null 2>&1 \
    || fail "fm-brief.sh ship scaffold exited non-zero"
  brief="$home/data/brief-captain-coexist/brief.md"
  assert_no_grep "^1\\. \\*\\*Never force anything" "$brief" \
    "captain rules must not restart plain numbering against the brief Rules list"
  assert_grep "{TASK}" "$brief" "captain rules must not displace the {TASK} placeholder"
  assert_grep "Verify isolation before anything else" "$brief" \
    "captain rules must not displace the worktree-isolation assertion"
  assert_grep "States: working, needs-decision, blocked, paused, done, failed." "$brief" \
    "captain rules must not displace the status protocol"
  assert_grep "# Definition of done" "$brief" \
    "captain rules must not displace the Definition of done"
  assert_no_grep "EOF" "$brief" \
    "captain rules section leaked a heredoc EOF marker"
  pass "fm-brief.sh: captain rules coexist with the placeholder, isolation, and status contracts"
}

test_script_parses
test_help_includes_entire_header
test_ship_and_scout_briefs_bind_the_standing_captain_rules
test_secondmate_charter_binds_the_applicable_captain_rules
test_captain_rules_preserve_existing_brief_contracts
test_ship_modes_generate_clean_briefs
test_direct_push_dod_semantics
test_direct_push_autoland_dod_semantics
test_hyfin_live_stack_repro_block
test_faster_paths_use_configured_authority_without_stacked_review
test_no_mistakes_dod_wording
test_no_mistakes_dod_requires_preflight
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_pause_verb_override_renders_all_brief_scaffolds
test_scout_and_secondmate_load_decision_hold_policy
test_scout_and_secondmate_scaffold
test_briefs_route_heavy_runs_through_the_runner
test_briefs_carry_rtk_token_efficiency_section
test_briefs_bind_the_shared_machine_rules
