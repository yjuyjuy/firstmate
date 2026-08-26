#!/usr/bin/env bash
# Scaffold a crewmate brief or persistent secondmate charter at
# data/<task-id>/brief.md under the active firstmate home.
# For ordinary tasks, the standard Setup/Rules/Definition-of-done contract is
# filled in. Firstmate then replaces the {TASK} placeholder with the task
# description, acceptance criteria, and context, and may adjust other sections
# when the task genuinely deviates (e.g. working an existing external PR instead
# of shipping a new one).
# Usage: fm-brief.sh <task-id> <repo-name> [--scout] [--herdr-lab]
#        fm-brief.sh <task-id> --secondmate {<project>...|--no-projects}
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   The scout report must open with a mandatory TL;DR header block (<=5 lines:
#   verdict, key numbers, recommendation, risk, pointer to detail) so the supervisor
#   relays the verdict without deep-reading; bin/fm-teardown.sh warns (never refuses)
#   when the report lacks that block.
#   --secondmate writes a persistent secondmate charter. The project list
#   is cloned into the secondmate home, while the natural-language scope
#   tells the main firstmate when to route work there; routine churn stays in its own home;
#   captain-relevant escalations and marked from-firstmate replies append to this
#   home's status file.
#   --no-projects writes a project-less charter for a domain whose subject is the
#   firstmate repo itself (its home is a firstmate worktree, its crews take pooled
#   worktrees of the same repo). It is mutually exclusive with a project list, and
#   omitting both still fails loudly so an accidental omission is never silent.
#   Set FM_SECONDMATE_CHARTER='<charter>' to fill the charter text.
#   Set FM_SECONDMATE_SCOPE='<scope>' to write a routing scope distinct from the charter text.
#   --herdr-lab is mandatory when the task will issue Herdr lifecycle commands.
#   It adds the hard isolation contract backed by bin/fm-herdr-lab.sh.
#   The flag must be explicit because {TASK} is filled after scaffolding and the
#   caller-supplied repo string cannot reliably identify this repo. Briefs made
#   without it carry a loud declaration so an omitted contract cannot be silent.
# For ship tasks, the definition of done is shaped by the project's delivery mode
# (data/projects.md via fm-project-mode.sh; see the project-management skill
# and AGENTS.md task lifecycle):
#   no-mistakes  implement -> /no-mistakes pipeline -> PR -> captain merge (default)
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> captain merge
#   direct-push  implement -> full /no-mistakes pipeline (its PR/CI steps skip; a run
#                ending "passed" with them skipped is complete) -> push validated branch
#                to origin fm/<id> and report its head. No PR, no CI wait; a run reporting
#                "missing NO_MISTAKES_BITBUCKET_EMAIL" is expected, not a blocker. The
#                configured merge authority lands the branch on the forge (e.g. Bitbucket).
#   local-only   implement on branch, stop and report "ready in branch" (no push/PR);
#                captain approves, firstmate merges to local main
# The +autoland registry flag (owned repos only) reshapes the direct-push definition
# of done: after the pipeline is green the crew self-lands its OWN fm/<id> branch onto
# the origin default branch as a clean --no-ff merge and reports the merge evidence,
# instead of pushing and waiting for the merge authority. local-only +autoland is not a
# brief change - firstmate fires the guarded local merge itself once the review gate is
# green (bin/fm-merge-local.sh). Guardrails baked into the generated contract: green
# only, own branch only, --no-ff only, conflict escalates, never delete a branch.
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# hyfin and hyfin-server ship briefs additionally carry a "Live stack repro" block
# with the exact commands to stand up an own local stack (recaptcha auto-bypasses
# locally, no AWS creds needed), so a live merchant repro is never falsely declared
# impossible.
# Scout tasks ignore mode - their deliverable is a report, not a merge.
# Every scaffold's status protocol distinguishes the configured
# declared-external-wait verb (FM_CLASSIFY_PAUSED_VERB, default "paused") from
# "blocked:": pause for a known external wait expected to clear on its own,
# blocked when firstmate must act.
# Ship tasks include a project-memory section so durable project-intrinsic
# learnings can be committed to AGENTS.md through the project's delivery path;
# it carries the AGENTS.md authoring bar (widely useful knowledge only, pointers
# over copied detail) and has the crewmate add the fm-ensure-agents-md.sh
# self-governance section when a touched project AGENTS.md lacks it.
# Every ship and scout scaffold also carries the fleet's shared-machine rules, so a
# freshly spawned crewmate obeys them without being steered: heavy commands go through
# bin/fm-heavy-run.sh, test parallelism is capped at VITEST_MAX_WORKERS=2, every test run
# is announced with TEST START / TEST END status lines, and a live browser reproduction
# is announced with BROWSER START / BROWSER END status lines as a non-blocking
# coordination announce.
# Every ship and scout scaffold additionally requires the final report to declare whether
# the work was built test-first and whether it has end-to-end coverage.
# Every ship and scout scaffold carries a short "Token efficiency" section. When rtk (the
# token-optimizing CLI proxy, ~/RTK.md) is present at scaffold time, it tells the worker to
# prefer rtk-wrapped runs (rtk test / rtk err for suites, rtk grep / rtk rg / rtk log for
# search and logs) so filtered output reaches its context instead of a raw dump - the
# largest win on lanes with huge test output such as hyfin-server. When rtk is absent it
# says plain commands are fine, so
# a worker on a host without rtk is never told to run a tool it lacks. Detection is a
# scaffold-time `command -v rtk`; FM_BRIEF_RTK={1,0} overrides it as a test seam. The
# heavy-command serialization rule (Rule 8) is unchanged and still owns the real exit
# status: rtk wraps the command INSIDE fm-heavy-run, it does not replace it.
# Every ship and scout scaffold also carries the standing captain rules that bind every
# worker, so they are structural instead of hand-pasted per dispatch: never force anything
# (push to a NEW branch when blocked, never force-push, never force-release, never decide on
# your own to delete a branch, though the guarded teardown and fleet-sync paths removing
# their own refs are exempt), understand the reason behind an instruction before acting and ask firstmate for a
# grilling session when it is unclear, plan with the wayfinder skill before changing code,
# write prose in caveman ultra style - reports included, with their identifiers, paths,
# commands, and error strings kept verbatim as evidence - while keeping code and tool-parsed
# text normal, and bind
# no server to port 443 or 3000. The Mattermost-sourced rule is written as a self-guarding
# conditional on the same section rather than behind a flag, because a rule firstmate can
# forget to pass is worth nothing. The secondmate charter carries the subset that applies to a
# supervising home: never force, understand the reason, and caveman ultra prose. The rules are
# labelled C1-C6 so a steer referencing a rule number cannot collide with the brief's own
# numbered Rules list.
# Refuses to overwrite an existing brief.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
KIND=ship
HERDR_LAB=0
NO_PROJECTS=0
POS=()
for a in "$@"; do
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --herdr-lab) HERDR_LAB=1 ;;
    --no-projects) NO_PROJECTS=1 ;;
    *) POS+=("$a") ;;
  esac
done
ID=${POS[0]}

if [ "$KIND" = secondmate ] && [ "$HERDR_LAB" -eq 1 ]; then
  echo "error: --herdr-lab applies only to crewmate ship or scout briefs" >&2
  exit 1
fi

if [ "$NO_PROJECTS" -eq 1 ] && [ "$KIND" != secondmate ]; then
  echo "error: --no-projects applies only to --secondmate charters" >&2
  exit 1
fi

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
mkdir -p "$DATA/$ID"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")

# Standing captain rules. These bind every worker, so they are generated here
# rather than pasted onto each brief by hand: a rule that lives only in
# firstmate memory never reaches a worker whose brief predates it.
# Both blocks use quoted heredocs, so their text is literal and apostrophes in it
# are safe: the issue #166 regression class came from UNQUOTED heredoc bodies
# inside a command substitution, which this is not.
# Rule labels are stable across both blocks so a steer that names a rule always
# means the same rule: the secondmate subset carries C1, C2, and C4, keeping the
# gap rather than renumbering.
# Rule C3's planning mandate is unconditional on every harness. Its `wayfinder`
# skill is installed at the user level (~/.claude/skills/wayfinder), not tracked
# in this repo, so a repo-presence check is the wrong test; only claude resolves
# that path, while firstmate also dispatches to codex, opencode, pi, and grok.
# C3 therefore names wayfinder as the way to plan where the runtime provides it
# and still requires a worker on any other runtime to plan first by its own means.
CAPTAIN_RULES=$(cat <<'EOF'
# Standing captain rules

Bind the whole task; not optional; outrank convenience.

- **C1. Never force anything.** No force-push, no forced release, never delete a branch on your own (captain's call). If a push is rejected, push to a NEW branch and report its name. Guarded tooling removing its own worktrees or landed/pruned refs (`bin/fm-teardown.sh`, `bin/fm-fleet-sync.sh`) is exempt.
- **C2. Understand the WHY before acting.** If the reason for an instruction is unclear, STOP and ask firstmate for a grilling session. Asking is never a failure.
- **C3. Plan before you change code.** MANDATORY: use `wayfinder` if your runtime provides it, else plan by your own means.
- **C4. Write prose in caveman ultra style.** Drop articles/filler/hedging; fragments fine; state each fact once; keep every technical fact. Binds status lines, replies to firstmate, and reports; in reports, identifiers/paths/commands/status lines/error strings stay VERBATIM. Use normal prose for anything a tool/forge/CI parses (code, commit messages, PR bodies, `AGENTS.md`, ADRs, `docs/`), for security warnings and irreversible-action confirmations, and where dropping conjunctions makes order ambiguous. Never abbreviate identifiers/APIs/CLI commands/error strings. Full rule: section 9 of firstmate `AGENTS.md`.
- **C5. Never bind port 443 or 3000** (captain's servers). Use a non-default port.
- **C6. If this task came from a Mattermost thread**, FIRST re-read the full thread; never trust the queue-time summary. If already fixed, verify and ADD the missing end-to-end coverage rather than closing.
EOF
)

# The supervising subset for a persistent secondmate home. A secondmate delegates
# implementation to its own crewmates, whose briefs carry the full set, so the
# planning, port, and Mattermost rules do not apply to the charter itself.
# The labels match the ship and scout block exactly - C1, C2, C4 - because
# firstmate steers by label; the missing C3 is deliberate, not a renumbering.
CAPTAIN_RULES_SECONDMATE=$(cat <<'EOF'
# Standing captain rules

These bind you and every crewmate you dispatch.

- **C1. Never force anything.** Never force-push, never force a release, never decide on your own to delete a branch (the captain's decision alone). When a push is blocked, push to a NEW branch and report it so nothing existing is lost. Guarded machinery removing its own worktrees or already-landed/pruned refs through its own checks (`bin/fm-teardown.sh`, `bin/fm-fleet-sync.sh`) is ordinary tooling, not what this prohibits.
- **C2. Understand the WHY before acting.** Never work routed instructions mechanically. If the reason is unclear, STOP and ask the main firstmate for a grilling session via the escalation path below - append a `needs-decision` line to the main status file, carrying the same `corr=<id>` token when the questioned request arrived marked. Never ask only in this chat: the main firstmate does not read it. Asking is never a failure.
- **C4. Write prose in caveman ultra style.** Drop articles, filler, hedging, pleasantries; fragments fine; state each fact once; keep every technical fact. Binds your status lines, replies to the main firstmate, and every report you or your crewmates produce (including `data/<id>/report.md`). In a report, exact identifiers, paths, commands, status lines, and error strings stay VERBATIM as evidence. Use normal prose for anything a tool/forge/CI parses (code, code comments, commit messages, PR titles/bodies, project `AGENTS.md`/`CLAUDE.md`, ADRs, `docs/`), for security warnings and irreversible-action confirmations, and for any multi-step sequence where dropping conjunctions makes order ambiguous. Never invent abbreviations; never abbreviate identifiers, API names, CLI commands, or error strings. Full rule: section 9 of the firstmate repo `AGENTS.md`.
EOF
)

if [ "$KIND" = secondmate ]; then
SECONDMATE_PROJECTS=""
idx=1
while [ "$idx" -lt "${#POS[@]}" ]; do
  SECONDMATE_PROJECTS="${SECONDMATE_PROJECTS}${SECONDMATE_PROJECTS:+ }${POS[$idx]}"
  idx=$((idx + 1))
done
if [ "$NO_PROJECTS" -eq 1 ]; then
  [ -z "$SECONDMATE_PROJECTS" ] || { echo "error: --no-projects cannot be combined with a project list" >&2; exit 1; }
else
  [ -n "$SECONDMATE_PROJECTS" ] || { echo "error: --secondmate requires at least one project, or --no-projects for a project-less home" >&2; exit 1; }
fi
SECONDMATE_CHARTER=${FM_SECONDMATE_CHARTER:-"{TASK}"}
SECONDMATE_SCOPE=${FM_SECONDMATE_SCOPE:-${FM_SECONDMATE_CHARTER:-"{TASK}"}}
if [ "$NO_PROJECTS" -eq 1 ]; then
  PROJECT_CLONES_BODY="None. This is a project-less domain: its subject is the firstmate repo this home lives in, so it needs no separate clones under \`projects/\`; its crews take pooled worktrees of that firstmate repo."
  PROJECT_CLONES_NOTE="This domain has no separate project clones: its subject is the firstmate repo this home lives in, and its crews take pooled worktrees of that repo."
else
  PROJECT_CLONES_BODY=$(printf '%s\n' "$SECONDMATE_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
  PROJECT_CLONES_NOTE="The projects above are local clones for work you supervise; they are not an exclusive ownership claim."
fi
cat > "$BRIEF" <<EOF
You are a persistent second mate managed by the main firstmate. Work on your own; do not wait for a human.

# Charter
$SECONDMATE_CHARTER

# Routing scope
$SECONDMATE_SCOPE

# Project clones
$PROJECT_CLONES_BODY

# Operating model
You are in an isolated firstmate home. The local \`AGENTS.md\` is your job description, and your local \`data/\`, \`state/\`, \`config/\`, and \`projects/\` dirs are yours to operate.
$PROJECT_CLONES_NOTE
Delegate project work to your own crewmates with the normal firstmate lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work.
Act only on tasks the main firstmate routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.

# Requests from the main firstmate
You are a firstmate in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main firstmate is tagged with a leading \`$FM_FROMFIRST_LABEL\` marker followed by an invisible system separator; this marker is untypable, so a human never produces it.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main firstmate does not read your chat, so a chat-only reply is lost.
Marked requests also carry a privacy-safe \`corr=<id>\` token after the marker; include that exact token in your parent status reply (or in the status pointer to a detailed doc) so the parent can correlate the answer.
Optional helper: \`bin/fm-secondmate-report.sh\` can append a correlated status line for you, but a plain \`echo\` that includes the same \`corr=<id>\` is equally valid - do not depend on the helper being present.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's \`data/\` and append a status line that points to that doc - the scout-report pattern - so the main firstmate is woken and can read it.
Before treating an investigation or visual review as complete, load \`decision-hold-lifecycle\` from this home's \`.agents/skills/\` and pass its shared completion gate.
A message with NO marker is the captain typing directly into your pane: treat it as authoritative captain intervention and stay conversational exactly as you would for any captain message; do not force it onto the status path.

$CAPTAIN_RULES_SECONDMATE

# Escalation to main firstmate
Handle routine work yourself.
Report only true captain-relevant outcomes or a declared external wait by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
Use \`$PAUSED_VERB: {why}\` (distinct from \`blocked:\`) only when your domain is deliberately idling on a known external wait you expect to clear on its own; use \`blocked:\` when you are stuck and need firstmate to act. A Claude/auth session-limit, a usage-window or quota exhaustion, or a revoked/expired token is captain-fixable (switch account or relog in), so report it \`blocked:\`, never \`$PAUSED_VERB:\`.
Use this only for material phase changes, a captain decision, a real blocker, a failure, or work ready for review.
This is also how you return the answer to a marked from-firstmate request above.
Give every routed-work phase a stable key: open it with \`working [key=<work-slug>]: {material phase}\`, and use the same key on its later \`$PAUSED_VERB\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event so the earlier working phase is superseded.
When a keyed phase ends without another reportable state, append \`resolved [key=<work-slug>]: {why it is no longer active}\`.
When a decision you escalated is answered or a blocker clears and your domain resumes, append \`resolved: {how it was decided or unblocked}\` (keyed with \`[key=<slug>]\` if you opened it with one) so it is durably closed instead of resurfacing behind later unrelated events.
Routine internal supervision, heartbeats, retries, and crewmate churn stay inside your own home and must not touch that status file.

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal firstmate bootstrap and recovery through \`bin/fm-session-start.sh\` for your own home, but only to RECONCILE work that is already yours: in-flight crewmates, tracked backlog items, and durable watches recorded in this home.
When you have no assigned or in-flight work after that reconciliation, go idle and wait silently for the main firstmate to route you a task.
An empty queue is a healthy resting state, not a cue to invent work: never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
If this charter cannot be carried out, append \`blocked: {why}\` or \`failed: {why}\` to the main status file and stop.
EOF
if [ "$SECONDMATE_CHARTER" = "{TASK}" ]; then
  echo "scaffolded: $BRIEF (secondmate charter; replace {TASK})"
else
  echo "scaffolded: $BRIEF (secondmate charter)"
fi
exit 0
fi

REPO=${POS[1]}

# Project-conditional live-stack repro block. hyfin and hyfin-server workers kept
# declaring a live merchant repro impossible because nothing told them they can stand
# up their OWN local stack, where recaptcha auto-bypasses and no AWS creds are needed.
# This block gives them the exact commands so "live stack unavailable" stops being an
# accepted ceiling for a payment or receipt bug.
case "$REPO" in
  hyfin|hyfin-server)
    HYFIN_REPRO=$(cat <<'EOF'
# Live stack repro (hyfin / hyfin-server only)
You CAN and SHOULD stand up your OWN local stack for a live merchant repro. "Live stack unavailable" is no longer an acceptable ceiling for a payment or receipt bug.
Recaptcha auto-bypasses locally, so you need no AWS credentials: `hyfin-server services/access/RecaptchaService.js` skips validation when `global.isLocal && !ENABLE_RECAPTCHA`, and `config/localTestDb.js` sets the recaptcha threshold to 0, turns rate limiting off, and uses a test-only `tokenSecret`.

- Backend: run `hyfin-server` `./start.sh` -> `api.local.hyfin.app:3000` (shared, first-come).
- Frontend lane: run `hyfin` `./start.sh lane <your-lane-index>` -> `https://lane<N>.local.hyfin.app`, and point Playwright at it with `HYFIN_LANE=<N>`.
- Seed throwaway sites ONLY via `tests/v8/e2e/7. pricing/lib/seed.js`, NEVER a real site.
- Reference: `hyfin/docs/e2e-lanes.md`.

Announce the browser use (Rule 10): append the `working: BROWSER START` line before you drive a browser and `working: BROWSER END` when it finishes, so the shared-machine log shows browser activity - a non-blocking announce, never a wait.
EOF
)
    ;;
  *)
    HYFIN_REPRO=""
    ;;
esac

if [ "$HERDR_LAB" -eq 1 ]; then
HERDR_LAB_HELPER=$(shell_quote "$FM_ROOT/bin/fm-herdr-lab.sh")
# shellcheck disable=SC2016  # single quotes are deliberate: these lines are literal brief text whose backtick-wrapped $(...) and "$HERDR_LAB_SESSION" snippets must reach the reading agent verbatim, not expand at scaffold time; only the '"$VAR"' break-outs interpolate.
HERDR_SECTION=$(printf '%s\n' \
'# Herdr isolation - HARD SAFETY CONTRACT' \
'This brief was explicitly scaffolded with `--herdr-lab` because the task will drive Herdr lifecycle behavior.' \
'On Herdr 0.7.3 the API socket is not relocatable by `HERDR_CONFIG_PATH`, `XDG_CONFIG_HOME`, or `HOME`.' \
'A named non-`default` session plus a trailing `--session <name>` on every call is the only viable local isolation.' \
'' \
'1. Set `HERDR_LAB_HELPER='"$HERDR_LAB_HELPER"'` and generate the session name with `HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name '"$ID"')`.' \
'   Install `trap '\''"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"'\'' EXIT` before provisioning, then provision only with `"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"`.' \
'2. Run every task-specific non-lifecycle Herdr command through `"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" <arguments...>`.' \
'   The helper appends the required trailing `--session "$HERDR_LAB_SESSION"`; `HERDR_SESSION` alone is never accepted as isolation.' \
'3. Teardown only through `"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"`.' \
'   It re-checks refuse-default immediately before stop and again immediately before delete, and fails closed on ambiguity.' \
'4. If an experiment requires a deliberate mid-run session stop, use only `"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION"`; it performs the same immediate refuse-default check.' \
'5. Forbidden commands: direct `herdr server stop`, every other server-global operation such as `herdr server live-handoff` or reload/update operations, direct `herdr session stop`, direct `herdr session delete`, and any Herdr call scoped only by ambient or inline `HERDR_SESSION`.' \
'6. The helper records the live default session before provisioning and verifies the identical fleet state after teardown.' \
'   A missing, stopped, or changed default session is a hard tripwire failure, never a cleanup warning to ignore.' \
'' \
'Never bypass the helper, even for a read-only lifecycle probe or cleanup after failure.' \
'The captain fleet uses the running `default` session.')
else
HERDR_SECTION=$(cat <<'EOF'
# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text that replaces `{TASK}` later.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.
EOF
)
fi

# rtk token-efficiency section. rtk (the token-optimizing CLI proxy, ~/RTK.md) filters
# large or noisy command output down to a summary before it reaches a worker's context,
# so a huge test suite does not bury the lane in passing-test noise. When rtk is present
# we tell the worker to prefer it; when it is absent we say plain commands are fine, so a
# worker on a host without rtk is never told to reach for a tool it lacks. Detection is a
# scaffold-time probe of THIS host, which is the crew host too; FM_BRIEF_RTK={1,0}
# overrides it as a test seam. Both bodies are quoted heredocs, so their backtick-wrapped
# commands and apostrophes stay literal and the issue #166 parse class does not apply.
if [ -n "${FM_BRIEF_RTK:-}" ]; then
  RTK_PRESENT=$FM_BRIEF_RTK
elif command -v rtk >/dev/null 2>&1; then
  RTK_PRESENT=1
else
  RTK_PRESENT=0
fi
if [ "$RTK_PRESENT" = 1 ]; then
RTK_SECTION=$(cat <<'EOF'
# Token efficiency
`rtk` (token-optimizing CLI proxy, see `~/RTK.md`) is installed here. Prefer it for commands whose output is large or noisy, so a filtered summary reaches your context instead of a raw dump. The biggest win is a large test suite such as hyfin-server, where a raw run can bury your context in passing-test noise.
- Tests: `rtk test <runner>` shows only failures; `rtk err <cmd>` shows only errors and warnings.
- Search, logs, and VCS: `rtk grep`, `rtk rg`, `rtk log`, `rtk git`, and `rtk gh` give compact output.
- Heavy runs still go THROUGH `fm-heavy-run.sh` (Rule 8); put `rtk` inside it by making the `-- <command>` an rtk-wrapped run, for example `-- rtk test <runner>`. fm-heavy-run still returns the command's real exit status, so act on that, not only the filtered text.
- Do not wrap interactive commands, output you need verbatim, or short commands where filtering saves nothing; `rtk proxy <cmd>` runs a command raw when you need the full output.
EOF
)
else
RTK_SECTION=$(cat <<'EOF'
# Token efficiency
`rtk`, the token-optimizing CLI proxy some lanes use to filter noisy output, is not installed here, so plain commands are completely fine - run them directly. Still keep output lean where you can: prefer targeted greps and scoped test runs over dumping whole files or full suites into your context.
EOF
)
fi

if [ "$KIND" = scout ]; then
cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
3. Use gh-axi for GitHub and chrome-devtools-axi for browser operations.
4. Report status by appending one line: \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed. Each append wakes firstmate, so report only
   supervisor-actionable phase changes plus the needs-decision/blocked/$PAUSED_VERB/done/failed states; no FYI lines.
   \`$PAUSED_VERB: {why}\` (vs \`blocked:\`) is ONLY for deliberately idling on a known external wait that self-clears;
   use \`blocked:\` when stuck. An auth session-limit, usage-window/quota exhaustion, or revoked/expired token is
   captain-fixable, so report it \`blocked:\`, NEVER \`$PAUSED_VERB:\`.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop.
6. If a decision belongs to a human (product choices, destructive actions), append \`needs-decision: {options}\`
   and stop. On reply or when a blocker clears, append \`resolved: {how}\` (same \`[key=<slug>]\` if you opened with one).
7. Never stop, restart, or update the shared \`no-mistakes\` daemon. On ANY daemon error, append
   \`blocked: {the daemon error}\` and stop.
8. Run heavy commands (unit/e2e suites, lint, builds) through
   \`$FM_ROOT/bin/fm-heavy-run.sh --task $ID -- <command>\` (a queued notice is normal). Cap \`VITEST_MAX_WORKERS=2\` (never 4).
9. Announce test runs: \`working: TEST START - {what, rough scale}\` before, \`working: TEST END - {outcome}\` after.
10. Announce live browser use: \`working: BROWSER START - {what}\` before, \`working: BROWSER END - {outcome}\` after.

$RTK_SECTION

$CAPTAIN_RULES

# Test coverage declaration
If your investigation ran or added any test, or recommends a change, your report must state plainly whether that work was built test-first and whether it has end-to-end coverage.
A gap does not block anything, but name the gap and its reason; the captain reviews every untested product change.

# Definition of done
Write your findings to \`$DATA/$ID/report.md\`.

The report MUST open with a mandatory TL;DR header block, at most 5 lines, so the
supervisor can relay your verdict without reading the whole report. The first line
must be a \`TL;DR\` heading (\`# TL;DR\` or \`## TL;DR\`). The block states, tersely:
verdict, key numbers, recommendation, risk, and a pointer to the detail sections
below. Everything else - what you did, evidence, file:line references - follows
that block. Teardown warns (it does not refuse) if the TL;DR block is missing, but
a scout report without it is a defect: write it.

The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
Before reporting done, read and follow \`$FM_ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md\` and pass its shared completion gate for the report and any visual review.
When the report is complete, append \`done: {one-line conclusion}\` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; firstmate may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
echo "scaffolded: $BRIEF (scout; replace {TASK})"
exit 0
fi

# Ship task: shape Setup / Rule 1 / Definition of done by the project's delivery mode.
# yolo does not affect the brief (it governs firstmate's approval behaviour), so discard it.
# autoland DOES affect the brief: a direct-push +autoland lane self-lands its own green
# branch onto the default branch, so the generated Rule 1 and Definition of done change.
read -r MODE _YOLO AUTOLAND _ <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$REPO")
EOF
: "${AUTOLAND:=off}"

case "$MODE" in
  direct-PR)
    SETUP2=""
    RULE1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch). Never merge a PR.'
    DOD=$(cat <<EOF
# Definition of done
This project ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
)
    ;;
  direct-push)
    SETUP2="
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
    # Shared direct-push pipeline body: identical whether or not the lane self-lands.
    DP_BODY=$(cat <<EOF
YOU own the entire finish on a direct-push lane: committing and pushing are NOT done. Drive it in one flow: implement, commit, run the FULL /no-mistakes pipeline, then complete the closing steps - do not stop for firstmate.
The pipeline's \`pr\`/\`ci\` steps not applying is expected; a run ending \`passed\` with them skipped is COMPLETE. A run reporting \`missing NO_MISTAKES_BITBUCKET_EMAIL\` is expected and NOT a blocker.

Follow /no-mistakes' own version-matched guidance for mechanics (\`no-mistakes axi run --help\`, each \`axi\` response's \`help\`). Firstmate-specific rules on top:
- Before invoking, run \`$FM_ROOT/bin/fm-nm-preflight.sh\`; if it refuses, do NOT invoke - append \`blocked: {the refusal}\` and stop. It refuses when a run is in flight on a different branch; never respond to or abort that run.
- ALWAYS pass \`--intent "{one-line description}"\` on EVERY \`axi run\`.
- Respond to gates; never hand-edit/commit/fix findings while a run is active.
- ask-user findings are NOT yours: escalate via rule 6, then feed the decision with \`no-mistakes axi respond\`. Avoid \`--yes\`.
EOF
)
    if [ "$AUTOLAND" = on ]; then
      RULE1='1. Push only your `fm/'"$ID"'` branch to origin while you work, and NEVER force-push. After the pipeline is green you self-land that branch onto the default branch through the guarded steps in the Definition of done - land only your own branch, never any other lane, and never merge a PR.'
      DOD=$(cat <<EOF
# Definition of done
This project ships **direct-push +autoland**: an owned Bitbucket repo, and green work SELF-LANDS - after the pipeline is green you merge your own branch onto the shared default branch yourself, without waiting for the captain.

$DP_BODY

## Self-land (ONLY after the pipeline reports \`passed\`)
Land your OWN \`fm/$ID\` branch, ONLY when the pipeline is green, ONLY as a clean \`--no-ff\` merge.
Never land red or unvalidated work. Never land another lane's branch. Never delete any branch. Never force anything.
A merge conflict is a STOP-and-escalate - never resolve another lane's code yourself, because a clean cross-lane resolve needs the authoring lane's intent.

Your worktree shares its checkout with firstmate's, which already has the default branch checked out, so a plain \`git checkout <default>\` fails here. Land through a private landing ref instead:
  DEFAULT=\$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##'); : "\${DEFAULT:=dev}"
  git fetch origin "\$DEFAULT"
  git branch -f fm-landing "origin/\$DEFAULT"
  git checkout fm-landing
  git merge --no-ff "fm/$ID" -m "Merge fm/$ID into \$DEFAULT"
  # On CONFLICT: run \`git merge --abort\`, then append
  #   \`blocked: [key=autoland-conflict] fm/$ID conflicts with \$DEFAULT, needs authoring-lane resolve\`
  #   to the status file and STOP. Do not resolve it yourself.
  git push origin "fm-landing:\$DEFAULT"
  git checkout "fm/$ID"

After the push succeeds, append the merge evidence and stop:
  \`done: landed fm/$ID -> \$DEFAULT @ {before-sha}..{after-sha} (merge {merge-sha})\`
Firstmate reads that line, records a captain-review hold for the landed change, and refreshes the local copy. Do NOT wait for a PR url or checks-green - none will arrive.
EOF
)
    else
      RULE1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch to origin). Never merge a PR.'
      DOD=$(cat <<EOF
# Definition of done
This project ships **direct-push**: your pipeline's own PR and CI steps do not apply on the forge (e.g. Bitbucket), so YOU open no PR and wait on no CI - firstmate opens the Bitbucket PR itself after your validated branch is pushed.
$DP_BODY

After the pipeline reports \`passed\`, push your validated branch explicitly - a pipeline "push" only reaches the local internal gate:
  \`git push origin HEAD:fm/$ID\`
Then append \`done: pushed origin fm/$ID @ {short-sha}\` (the branch head commit) to the status file and stop. You are finished.
Do NOT wait for a PR url or checks-green - none will arrive. The configured merge authority lands the branch on the forge; firstmate verifies it on origin.
EOF
)
    fi
    ;;
  local-only)
    SETUP2=""
    RULE1="1. Never push to any remote and never open a PR. Work only on your \`fm/$ID\` branch; firstmate handles the merge into local \`main\`."
    DOD=$(cat <<EOF
# Definition of done
This project ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$ID\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch fm/$ID\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
)
    ;;
  *)  # no-mistakes (default)
    SETUP2="
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
    RULE1='1. Never push to the default branch. Never merge a PR.'
    DOD=$(cat <<EOF
# Definition of done
Complete only when committed on your branch. Append \`done: {summary}\` and stop; firstmate then tells you to run /no-mistakes to validate and ship a PR.

Follow /no-mistakes' own version-matched guidance for mechanics (\`no-mistakes axi run --help\`, each \`axi\` response's \`help\`). Firstmate-specific rules on top:
- Before invoking, run \`$FM_ROOT/bin/fm-nm-preflight.sh\`; if it refuses, do NOT invoke - append \`blocked: {the refusal}\` and stop. A run on a DIFFERENT branch is not a refusal; never respond to or abort it.
- Drive YOUR run by its id (a bare \`axi status\` can resolve to another lane's run).
- ALWAYS pass \`--intent "{one-line description}"\` on EVERY \`axi run\`.
- Respond to gates; never hand-edit/commit/fix findings while a run is active.
- ask-user findings are NOT yours: escalate via rule 6, then feed the decision with \`no-mistakes axi respond\`. Avoid \`--yes\`.

When /no-mistakes reports CI green (do not keep monitoring to merge), append \`done: PR {url} checks green\` and stop.
EOF
)
    ;;
esac

cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

$HERDR_SECTION
${HYFIN_REPRO:+
$HYFIN_REPRO
}
# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in (a treehouse pool path or Orca-managed worktree), NOT the primary checkout firstmate operates from (the path check is authoritative; \`--git-dir\`/\`--git-common-dir\` do not prove isolation). If either is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit - append \`blocked: launched in primary checkout, not an isolated worktree\` to the status file and stop.

1. First action: create your branch: \`git checkout -b fm/$ID\`$SETUP2

# Rules
$RULE1
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub and chrome-devtools-axi for browser operations.
4. Report status by appending one line: \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed. Each append wakes firstmate, so report only
   supervisor-actionable phase changes plus the needs-decision/blocked/$PAUSED_VERB/done/failed states; no FYI lines.
   A mid-task \`working:\` line is nonterminal: continue until a defined \`done:\` gate.
   \`$PAUSED_VERB: {why}\` (vs \`blocked:\`) is ONLY for deliberately idling on a known external wait that self-clears;
   use \`blocked:\` when stuck. An auth session-limit, usage-window/quota exhaustion, or revoked/expired token is
   captain-fixable, so report it \`blocked:\`, NEVER \`$PAUSED_VERB:\`.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop.
6. If a decision belongs to a human (product choices, destructive actions, ask-user findings), append
   \`needs-decision: {options}\` and stop. On reply or when a blocker clears, append \`resolved: {how}\`
   (same \`[key=<slug>]\` if you opened with one).
7. Never stop, restart, or update the shared \`no-mistakes\` daemon. On ANY daemon error, append
   \`blocked: {the daemon error}\` and stop.
8. Run heavy commands (unit/e2e suites, lint, builds) through
   \`$FM_ROOT/bin/fm-heavy-run.sh --task $ID -- <command>\` (a queued notice is normal). Cap \`VITEST_MAX_WORKERS=2\` (never 4).
9. Announce test runs: \`working: TEST START - {what, rough scale}\` before, \`working: TEST END - {outcome}\` after.
10. Announce live browser use: \`working: BROWSER START - {what}\` before, \`working: BROWSER END - {outcome}\` after.

$RTK_SECTION

$CAPTAIN_RULES

# Project memory
If \`AGENTS.md\`/\`CLAUDE.md\` exists, or this task produced durable project knowledge useful to almost every future session, run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree (prefer pointers over copied detail; add its \`## Maintaining this file\` section if missing). Skip for trivial tasks.

# Test coverage declaration
Your final report must state plainly whether this change was built test-first and whether it has end-to-end coverage. A gap does not block the merge, but name it and its reason.

$DOD
EOF
echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {TASK})"
