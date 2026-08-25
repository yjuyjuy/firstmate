---
name: jcode-switch-account
description: Rebroadcast a Claude sub-account switch into every live jcode worker session by wrapping bin/fm-switch-account.sh. Use when the captain invokes /jcode-switch-account, says "switch the fleet account", "switch to claude-1"/"switch to claude-2", "rotate the claude account", "change which claude account the workers use", or names an account by email (e.g. "switch to cyuan" / "dev1").
user-invocable: true
metadata:
  internal: true
---

# jcode-switch-account

Wrap `bin/fm-switch-account.sh`; never reimplement its mechanics.
jcode's `/account claude switch <label>` is a PER-SESSION slash command.
There is no single fleet-wide active account: each live worker session carries its own account, so a switch must be rebroadcast into every live pane individually.
The script owns everything: it sends the per-session command into every live worker pane, validates the label against `auth.json`, and refuses to garble a half-typed composer.
This skill only drives that script and reports the outcome.

## Procedure

1. Run `bin/fm-switch-account.sh --status` first to show the known labels.
   `--status` reads one best-effort probe field from `auth.json`; it is NOT fleet-wide truth about what each live worker is on, so never treat its label as proof any pane is already switched.
2. Resolve the requested label.
   - A bare label like `claude-1` or `claude-2` is used directly.
   - A captain phrasing by person or email (e.g. "cyuan", "dev1") maps to its label via the email shown in the `--status` output.
   - Ask one concise question only if the target is genuinely ambiguous.
3. Run `bin/fm-switch-account.sh <label>` to broadcast the switch to every live worker.
   ALWAYS run this broadcast, even when the `--status` probe already reports the target label.
   Never short-circuit or skip the broadcast as an "already on X, no switch needed" no-op: a probe label does not mean every live pane is on it.
   The only panes the script itself skips are ones with genuine pending human input or a dead/unknown composer; that is not a no-op and is correct.
4. Confirm the switch landed by reading the per-pane tails the script prints for the live workers.
5. Report to the captain in plain outcome language which account the workers are now on.

## Re-warming the fleet after a switch

After a switch the workers' prompt caches are cold, so each lane's first turn re-sends its full context.
Starting every lane at once sends that whole cold burst in one minute and can trip the new account's per-minute rate limit (this happened on 2026-08-25: 147 HTTP 429s in about two minutes).
When the captain wants the fleet actively re-warmed on the new account rather than left to resume on its own, add `--resume` to the broadcast (`bin/fm-switch-account.sh <label> --resume`).
That chains into `bin/fm-resume-fleet.sh` after the switch confirmations, which resumes the lanes one at a time with a paced 60 to 90 second gap between starts and verifies each turn before advancing, so the re-warm never bursts the per-minute budget.
The re-warm never fails the switch: the account move has already succeeded by the time it runs, and a lane that needs attention is reported without undoing the switch.

## Safety

See the `bin/fm-switch-account.sh` header for the full contract.
It rotates a reversible account label only: no `auth.json` edit, no server restart, no project-code change.
It skips any pane with genuine pending human input or a dead/unknown composer.
