#!/usr/bin/env bash
# Shared, sourced-only definitions for the structural safety scaffold every ship
# brief carries: the worktree-isolation verification paragraph and the standing
# captain-rules blocks (C1-C6 for a crewmate, the C1/C2/C4 subset for a
# secondmate charter).
#
# WHY THIS EXISTS: these blocks are a safety contract, not decoration. A brief
# that omits them lets a worker branch/commit in the primary checkout or
# hand-push to a default branch. bin/fm-brief.sh owned them inline, so any other
# generator that emits a ship brief (bin/fm-doclint-batch.sh) had to hand-copy
# the prose, which drifts. Per the one-owner rule (firstmate-coding-guidelines),
# the scaffold text lives here exactly once and every generator sources it.
#
# All bodies use quoted heredocs, so their text is literal: backticks and
# apostrophes in it are safe and need no escaping (the issue #166 regression
# class came from UNQUOTED heredoc bodies inside a command substitution, which
# this is not). Consumers that emit through an UNQUOTED heredoc reference these
# as plain `$FM_BRIEF_*` variables, which the shell interpolates literally.
#
# Rule labels are stable across both blocks so a steer that names a rule always
# means the same rule: the secondmate subset carries C1, C2, and C4, keeping the
# gap rather than renumbering.
# Rule C3's planning mandate is unconditional on every harness. Its `wayfinder`
# skill is installed at the user level (~/.claude/skills/wayfinder), not tracked
# in this repo, so a repo-presence check is the wrong test; only claude resolves
# that path, while firstmate also dispatches to codex, opencode, pi, and grok.
# C3 therefore names wayfinder as the way to plan where the runtime provides it
# and still requires a worker on any other runtime to plan first by its own means.

# The worktree-isolation verification paragraph. A ship Setup section places this
# right after the "you are in a disposable worktree" sentence; step 1's
# "Verify worktree isolation (Setup below)" pointer resolves here.
# shellcheck disable=SC2034 # Consumed by generators that source this lib (fm-brief.sh, fm-doclint-batch.sh), not here.
FM_BRIEF_ISOLATION_BLOCK=$(cat <<'EOF'
**Verify isolation before anything else.** Run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from.
The path check is authoritative: `git rev-parse --git-dir` and `git rev-parse --git-common-dir` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append `blocked: launched in primary checkout, not an isolated worktree` to the status file and stop.
EOF
)

# shellcheck disable=SC2034 # Consumed by generators that source this lib (fm-brief.sh, fm-doclint-batch.sh), not here.
FM_BRIEF_CAPTAIN_RULES=$(cat <<'EOF'
# Standing captain rules

These bind you for the whole task. They are not optional and they outrank convenience.

- **C1. Never force anything.** Never force-push, never force a release, and never decide on
   your own to delete a branch - deleting a branch is the captain decision alone. If a push
   is rejected or a branch is otherwise blocked, push to a NEW branch instead and report the
   new branch name, so nothing that exists can be lost. Running the guarded
   machinery as designed, such as `bin/fm-teardown.sh` or `bin/fm-fleet-sync.sh` removing
   their own worktrees and already-landed or pruned refs through their existing safety
   checks, is ordinary tooling behavior and is not what this rule prohibits.
- **C2. Understand the WHY before acting.** Never work the wording of this brief mechanically.
   If the reason behind an instruction is not clear enough to act on, STOP and ask firstmate
   for a grilling session. Asking is far cheaper than a wrong implementation and is never
   treated as a failure.
- **C3. Plan before you change code.** Planning first is MANDATORY, whatever runtime you are
   running on. If your runtime provides the `wayfinder` skill, invoke it to plan the work.
   If it does not, plan by your own means before touching code; the mandate stands either way.
- **C4. Write your prose in caveman ultra style.** Drop articles, filler, hedging, and
   pleasantries; fragments are fine; state each fact once; keep every technical fact. This
   binds your status lines, your replies to firstmate, AND your reports, including the scout
   report at `data/<id>/report.md`. Inside a report, exact identifiers, paths, commands,
   status lines, and error strings stay VERBATIM - they are evidence, not prose. Written in
   normal correct prose instead: code, code comments, commit messages, PR titles and bodies,
   any project `AGENTS.md` or `CLAUDE.md`, ADRs, files under `docs/`, and
   anything a tool, forge, or CI parses. Normal prose too for security warnings,
   irreversible-action confirmations, and any multi-step sequence where dropping conjunctions would make the
   order ambiguous. Never invent abbreviations and never
   abbreviate identifiers, API names, CLI commands, or error strings.
   Section 9 of the firstmate repo `AGENTS.md` owns this rule in full.
- **C5. Never bind port 443 or 3000.** Those ports are reserved for the servers the captain
   runs personally. Any server you start runs on a non-default port.
- **C6. If this task came from a Mattermost thread**, your FIRST action is to re-read the full
   thread; never trust the queue-time summary in this brief. If the reported bug turns out to
   be already fixed, verify that and ADD the missing end-to-end coverage rather than closing
   the task as done.
EOF
)

# The supervising subset for a persistent secondmate home. A secondmate delegates
# implementation to its own crewmates, whose briefs carry the full set, so the
# planning, port, and Mattermost rules do not apply to the charter itself.
# The labels match the ship and scout block exactly - C1, C2, C4 - because
# firstmate steers by label; the missing C3 is deliberate, not a renumbering.
# shellcheck disable=SC2034 # Consumed by generators that source this lib (fm-brief.sh), not here.
FM_BRIEF_CAPTAIN_RULES_SECONDMATE=$(cat <<'EOF'
# Standing captain rules

These bind you and every crewmate you dispatch.

- **C1. Never force anything.** Never force-push, never force a release, and never decide on
   your own to delete a branch - deleting a branch is the captain decision alone. When a push
   is blocked, push to a NEW branch and report it, so nothing that exists can be lost.
   Running the guarded machinery as designed, such as `bin/fm-teardown.sh` or
   `bin/fm-fleet-sync.sh` removing their own worktrees and already-landed or pruned refs
   through their existing safety checks, is ordinary tooling behavior and is not what this
   rule prohibits.
- **C2. Understand the WHY before acting.** Never work routed instructions mechanically. When
   the reason behind a request is not clear enough to act on, STOP and ask the main firstmate
   for a grilling session through the escalation path below - append a `needs-decision` status
   line to the main status file, carrying the same `corr=<id>` token when the request you are
   questioning arrived marked. Never ask only in this chat: the main firstmate does not read
   it, so a chat-only question is lost. Asking is never treated as a failure.
- **C4. Write your prose in caveman ultra style.** Drop articles, filler, hedging, and
   pleasantries; fragments are fine; state each fact once; keep every technical fact. This
   binds your status lines, your replies to the main firstmate, AND every report you or your
   crewmates produce, including the scout report at `data/<id>/report.md`. Inside a report,
   exact identifiers, paths, commands, status lines, and error strings stay VERBATIM - they
   are evidence, not prose. Written in normal correct prose instead: code, code comments,
   commit messages, PR titles and bodies, any project `AGENTS.md` or `CLAUDE.md`, ADRs, files
   under `docs/`, and anything a tool, forge, or CI parses. Normal prose too for security warnings,
   irreversible-action confirmations, and any multi-step sequence where dropping
   conjunctions would make the order ambiguous. Never invent abbreviations and never
   abbreviate identifiers, API names, CLI commands, or error strings.
   Section 9 of the firstmate repo `AGENTS.md` owns this rule in full.
EOF
)
