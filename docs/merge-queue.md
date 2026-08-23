# Merge queue

The merge queue is the durable, firstmate-private record of ship branches that were
**pushed to origin but not yet merged** when their disposable worktree was released.
It is the safety guard that makes release-on-pushed teardown acceptable: without it,
releasing a worktree before its branch merges would be a silent leak.

## Why it exists

On this memory-bound host an idle worker occupies a slot that queued work needs.
A finished worker whose branch is fully pushed holds nothing unique - the branch is
durable on the remote - yet it used to idle for hours solely because the branch had
not merged.
`bin/fm-teardown.sh` now releases such a worktree as soon as the branch is fully
pushed to its own origin ref (verified by a fresh fetch), independent of merge state.
The captain accepted one tradeoff: once released, a branch that later needs changes
needs a fresh worker to pick it back up.
The merge queue keeps that pending merge visible rather than silent.

## Format

`data/merge-queue.tsv`, one entry per line, tab-separated, owned by
`bin/fm-merge-queue-lib.sh`:

```
<id>	<project-path>	<branch>	<head>	<base>	<compare-url>
```

- `id` - the task id whose worktree was released.
- `project-path` - the local clone firstmate runs git against when sweeping.
- `branch` - the pushed branch name.
- `head` - the branch tip commit at release time.
- `base` - the intended merge target branch.
- `compare-url` - the captain-facing compare link.

One entry per task id; recording an id again replaces its line.
Comment lines start with `#`.
The library and `bin/fm-merge-queue.sh` own every read and write; nothing else parses
or hand-edits the file.

## Lifecycle

- **Record.** Teardown records an entry for a released ship task (not scout,
  secondmate, or `local-only`) unless the branch is proven landed by commit
  reachability - a merged PR, or HEAD reachable from a surviving default branch.
  Content equivalence (a merge-tree content compare) is never by itself a skip proof:
  a branch verifiably on origin and not proven merged is recorded even if its content
  already appears in the default branch, since its PR may still be open. Content
  equivalence only justifies a skip when the branch is not confirmed on origin at all
  (landed by squash/rebase under no branch of its own). Anything ambiguous or errored
  (fetch/gh failure, unresolved HEAD/base/origin) is reported loudly to stderr and
  still recorded, so a genuinely pushed-but-unmerged branch is never silently dropped.
  A forced teardown records too: recording is read-only, and a forced release of a
  pushed-but-unmerged branch is exactly the case where the branch is most easily lost.
- **Surface automatically.** The session-start fleet digest prints one bounded line
  whenever the queue is non-empty, and nothing at all when it is empty, so the guard
  does not depend on remembering to run the CLI.
- **Surface.** `bin/fm-merge-queue.sh list` prints the batched set as one list of
  compare links, grouped for the captain, rather than a trickle of individual asks.
- **Clear.** `bin/fm-merge-queue.sh sweep` drops every entry whose branch is now
  merged into its base. The merged check is a fresh **content-in-base** test against
  the real base branch on origin - never a PR-state lookup - so it is correct for
  Bitbucket repos (hyfin, hyfin-server) that have no PR automation. Any inconclusive
  result (no origin, fetch failure, merge conflict) keeps the entry rather than
  clearing it on an unverifiable claim.
  One further clearing case exists for the same reason: when the recorded head commit
  is no longer present in the clone at all - the local branch is gone after teardown,
  and a pruning fetch plus garbage collection can drop the last remote-tracking copy
  of a branch the forge deleted on merge - the sweep clears the entry only when
  `origin` provably no longer carries that branch.
  A network or authentication failure during that probe is inconclusive and keeps the
  entry, so the queue can neither clear on an unverifiable claim nor accumulate stale
  entries forever.
  That fallback is reported with its own wording, `branch gone from origin, merge
  unverified`, so it never reads as a confirmed merge.

### Bitbucket merge watch

Product repositories on Bitbucket are now merged by the captain from real pull requests, and
the queue only records the released branch.
`bin/fm-merge-queue-poll.sh` is the registered custom check that closes the loop: it polls
Bitbucket for each queued branch's pull request state and wakes firstmate when a pull request
is `MERGED` or `DECLINED` (or left `SUPERSEDED` with no open replacement).
A merged wake is the trigger to run the sweep, which clears the entry through the ordinary
content-in-base check above.
A declined or superseded entry is not cleared by the sweep (the branch may still exist on
origin), so it keeps waking firstmate until firstmate resolves it with the captain: remove
the entry, or delete the branch so the sweep's branch-gone check clears it.
Arm the watch once per home with `bin/fm-merge-queue-poll.sh arm <id>`, which writes the
registered shim and binds it with `bin/fm-check-register.sh`; `disarm <id>` removes it.
The full contract and live verification record are in `docs/bitbucket-merge-watch.md`.

### Write safety

Recording and removal take a queue-file mutex from `bin/fm-mutex-lib.sh`, a leaf lib
with no top-level side effects, so taking a lock never repoints a caller's home.
A lock that cannot be taken within the bounded wait fails the write instead of
proceeding unlocked, because an unlocked read-modify-write can silently lose another
task's entry.
A removal that cannot produce exactly the source lines minus the removed id is
refused and the queue is left intact, so a short or failed write can never erase the
rest of the queue.

### Project-write boundary

`AGENTS.md` section 1 makes clones under `projects/` read-only to firstmate.
The sweep's verification is an approved, explicitly documented exception to that
boundary: it runs `git fetch` for the base ref, `git ls-remote`, and
`git merge-tree --write-tree` inside the clone.
Those commands touch only remote-tracking refs and the object database.
The sweep never modifies a working tree, never creates, moves, or deletes a branch,
and never changes what the clone has checked out, so it cannot disturb work in that
clone.
It is deliberately not routed through the guarded fleet-sync path, which fast-forwards
checkouts and does far more than this read-only verification needs.

## Merge workers on demand, not standing

No standing merge worker exists: idle workers cost memory, the binding limit on this
host.
When a batch has accumulated for a repo AND merge authority exists (the captain's
explicit word, or a `yolo`-approved routine posture for a green branch), firstmate may
spawn one merge worker per repo per batch to land the queued branches, then tear it
down.
The queue is what makes each batch discoverable; there is no daemon and no poller.
For a repo with no PR automation (Bitbucket), the merge worker lands content into the
base branch directly, and the same content-in-base sweep clears the entries afterward.

## Never against upstream

`origin` is the fork `git@github.com:yjuyjuy/firstmate.git`.
Merge work driven from the queue targets `origin`, never an upstream we do not own.
Nothing in this path force-pushes; a branch that cannot fast-forward is re-pushed
under a new name and reported, never forced.
