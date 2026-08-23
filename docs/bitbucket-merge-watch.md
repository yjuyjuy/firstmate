# Bitbucket merge-queue watch verification

Design and verification record for `bin/fm-merge-queue-poll.sh`, the registered custom check that watches the merge queue (`docs/merge-queue.md`) against real Bitbucket pull request state.
Product repositories on Bitbucket are merged by the captain from pull requests, while the queue holds the released-but-unmerged branches, so this watch closes the gap between "branch released" and "PR merged or declined".

## The problem

The merge queue records a ship branch the moment its disposable worktree is released, and the sweep clears entries only when the branch's content is confirmed in its base branch.
That leaves two captain-facing outcomes invisible: a PR the captain merged (the queue should clear, and firstmate should notice and confirm) and a PR the captain declined (the queue entry is stuck, and firstmate should relay it).
There was no watcher program for either, so both waited on the next manual session review.

## What the poll does

For every queue entry whose compare link is a `https://bitbucket.org/{workspace}/{repo}/branch/{branch}` URL, it queries that branch's pull requests through the Bitbucket Cloud REST 2.0 API and prints one wake line per finding:

- `merged: <id> <branch> -> <base> <pr-url>` when any PR is `MERGED`.
- `declined: <id> <branch> -> <base> <pr-url>` when no PR is open or merged and a PR is `DECLINED`.
- `superseded: <id> <branch> -> <base> <pr-url>` when no PR is open or merged and a PR is `SUPERSEDED`.

State ordering is deliberate: `MERGED` outranks everything (the work landed), an `OPEN` PR outranks the closed states (the branch is still pending), and `DECLINED`/`SUPERSEDED` both mean closed without landing.
A branch with no pull requests at all stays silent, because that is the direct-push world where a merge worker lands content into the base branch and the ordinary content-in-base sweep covers it.

GitHub entries are skipped: their compare links are `github.com` URLs, and the GitHub path already has its own watch and sweep loop.
The poll is read-only: it only reads Bitbucket and never merges, comments, or changes the queue.
The queue itself is cleared by `bin/fm-merge-queue.sh sweep` after a merged wake; a declined or superseded wake needs firstmate to remove the entry or the captain to delete the branch (which the sweep's branch-gone check then clears).

## Wake and sweep contract

The poll prints one line per finding and nothing otherwise.
The watcher runs the registered check on its slow-poll cadence and turns any output into a `check:` wake.
A merged entry clears on the next sweep, so it wakes once.
A declined or superseded entry has no automatic clearing path, so it re-wakes each cycle until firstmate resolves it; that is the same re-surface behavior as a stuck decision, not a defect.

## How it is armed

```
$ bin/fm-merge-queue-poll.sh arm merge-queue-poller
registered: state/merge-queue-poller.check.sh
armed: state/merge-queue-poller.check.sh
```

`arm` writes `state/<id>.check.sh` as a 0700 single-link shim that exports `FM_HOME` and execs the tracked poll script, then binds those bytes with `bin/fm-check-register.sh`, exactly like the X-mode connector shim (`bin/fm-x-lib.sh`).
The watcher's slow-poll loop runs the hash-validated snapshot of the shim, which dispatches the trusted repository script.
`disarm <id>` removes the shim and its trust binding.

## Credentials and safety

The poll authenticates with the same `NO_MISTAKES_BITBUCKET_EMAIL` and `NO_MISTAKES_BITBUCKET_API_TOKEN` Basic-auth credentials the rest of the Bitbucket path reads (`docs/bitbucket-pr.md`), sourcing `$FM_HOME/.env` when the environment does not carry them.
The token reaches curl only through a private `--config` file that is removed immediately, never through an argument vector or a child's environment.
Every entry is validated before any request: the workspace and repository through the shared Bitbucket slug rules, the branch through the same per-segment rules plus a rejection of double quotes and whitespace (a double quote would break out of the embedded `q` string; a backslash cannot, so it needs no special case).
A missing tool, missing credential, non-2xx response, or unparsable body all stay silent in poll mode, so a failed lookup can never be misread as a merge or decline.
Arming is the one point where that silence would hide a broken watch, so `arm` refuses loudly without `curl`, `jq`, or the credentials.

## Live verification

All evidence below was captured on 2026-08-23 against the real queue and the real `dashnow` workspace, read-only.

The queued branches in `data/merge-queue.tsv` at capture time, with their real Bitbucket pull request states:

```
$ q='q=source.branch.name="..."; curl --get --data-urlencode "$q" --data-urlencode "state=ALL" --data-urlencode "pagelen=50" \
    https://api.bitbucket.org/2.0/repositories/dashnow/hyfin-server/pullrequests
fm/sec-9-public-charge-routes-unprotected  -> PR 2293 OPEN
fm/globalrecordids-payment-ingest          -> PR 2420 MERGED
fm/strip-backfill-from-pr2420              -> no pull requests
fm/ignore27-subscriptions-and-speed        -> PRs 2410 and 2393 DECLINED
fm/takeover-hydrate-stats                  -> PR 2406 OPEN
fm/sec-7-webhook-sig-dead-code             -> PR 2296 OPEN
```

Running the poll against the real queue, with the credentials sourced from firstmate's `.env`:

```
$ FM_HOME=/work/firstmate-work bin/fm-merge-queue-poll.sh
declined: ignore27-subscriptions-and-speed fm/ignore27-subscriptions-and-speed -> dev https://bitbucket.org/dashnow/hyfin-server/pull-requests/2410
merged: globalrecordids-payment-ingest fm/globalrecordids-payment-ingest -> dev https://bitbucket.org/dashnow/hyfin-server/pull-requests/2420
```

The open branches, the no-PR branch, and the GitHub entries produced no output, exactly as designed.
The merged entry is then cleared by `fm-merge-queue.sh sweep` (content-in-base), and the declined entry stays queued for captain resolution.

## Automated coverage

`tests/fm-merge-queue-poll.test.sh` drives the poll and the arm/disarm lifecycle against a mock `curl` with canned Bitbucket responses.
It covers the merged/declined/superseded wake lines with canonical PR URLs, the open-outranks-declined and merged-outranks-everything ordering, silence for no-PR, absent-queue, missing credentials and tools, API errors and unparsable bodies, the `.env` credential fallback, GitHub and malformed-entry skipping, the token-via-config-file guarantee, and the full arm/register/disarm cycle against the real `bin/fm-check-register.sh`.