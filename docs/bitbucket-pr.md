# Bitbucket Cloud pull request open, watch, and merge

Design and verification record for the Bitbucket Cloud pull request path, the counterpart to the GitHub `gh-axi` PR path and the GitLab merge watch (`docs/gitlab-merge-watch.md`).
It lets a validated `fm/<id>` branch on a Bitbucket product repository open a real pull request, have its merge watched, and be merged, which is what a project needs to move from `direct-push` delivery to full PR-based delivery.

## Why this exists

Firstmate can push a validated branch to a Bitbucket product repository over SSH, but it had no forge CLI that opens or merges a Bitbucket pull request object the way `gh-axi` does for GitHub.
That gap is the entire reason `hyfin` and `hyfin-server` shipped as `direct-push` (push-only, no PR object, captain merges from a compare link).
This path closes the gap by calling the Bitbucket Cloud REST 2.0 API directly.

## Credentials

Authentication reuses the exact environment variables the `no-mistakes` binary already reads for its own Bitbucket integration, so the fleet configures one credential in one place rather than inventing a second store:

- `NO_MISTAKES_BITBUCKET_EMAIL` - the Atlassian account email, used as the HTTP Basic-auth username.
- `NO_MISTAKES_BITBUCKET_API_TOKEN` - the Atlassian API token (or app password), used as the Basic-auth password.
- `NO_MISTAKES_BITBUCKET_API_BASE_URL` - optional REST base, defaulting to `https://api.bitbucket.org`.

The `no-mistakes` binary carrying these exact variable names was confirmed by inspecting its strings on 2026-08-12 (`NO_MISTAKES_BITBUCKET_EMAIL`, `NO_MISTAKES_BITBUCKET_API_TOKEN`, `NO_MISTAKES_BITBUCKET_API_BASE_URL`, and the API base `https://api.bitbucket.org`).

The token is passed to `curl` only through a `--config` file (`user = "email:token"`) on a private temporary file that is removed immediately after each call, never on the command line or in any child's environment, so it cannot leak into a process listing or a shared log.

## Why the web host and the API host are separate

A Bitbucket pull request URL lives on the web host `bitbucket.org`:

```
https://bitbucket.org/{workspace}/{repository}/pull-requests/{number}
```

`fm_pr_url_parse` (`bin/fm-pr-lib.sh`) also accepts the browser-copied variants Bitbucket's web UI produces - a trailing branch-title slug, per-PR tabs (`/diff`, `/commits`, ...), a bare trailing slash, or a query/fragment - and canonicalizes them back to this bare form before storing, so every variant of one PR resolves to the same stored record.

The REST API lives on a different host, `api.bitbucket.org` by default.
The provider-tagged PR identity (`provider`, `url`, `host`, `path`, `number`) stores only the web host and the two-segment `workspace/repository` path, exactly like GitHub's `owner/repository`.
The API host is resolved at call time from `NO_MISTAKES_BITBUCKET_API_BASE_URL` and never stored in that identity, so a doctored record cannot redirect a call at another host.
An override that is not a plain `https://` URL, or that contains whitespace, is refused, so a malformed value fails closed rather than targeting an unexpected host.

## REST endpoints used

All relative to the resolved API base (`https://api.bitbucket.org` by default):

- Open: `POST /2.0/repositories/{workspace}/{repo}/pullrequests` with a JSON body `{title, source.branch.name, destination.branch.name, [description]}`.
- State: `GET /2.0/repositories/{workspace}/{repo}/pullrequests/{number}`, reading `.state` (`OPEN`, `MERGED`, `DECLINED`, `SUPERSEDED`).
- Merge: `POST /2.0/repositories/{workspace}/{repo}/pullrequests/{number}/merge` with `{merge_strategy}` (`squash` by default; `merge_commit` and `fast_forward` also supported).

Bitbucket refuses the merge itself (a non-2xx response) on a conflict, an open required check, or a declined pull request, so a red or unmergeable PR fails at the merge call rather than being force-landed.

## Where each piece lives

- `bin/fm-pr-lib.sh` - parses the Bitbucket PR URL into the provider-tagged identity, validates the workspace and repository slugs, and resolves/guards the task clone's own Bitbucket origin (`fm_pr_refuse_unowned_bitbucket_target`, the Bitbucket twin of the GitHub fork-target guard).
- `bin/fm-bitbucket-lib.sh` - the REST helpers: credential and tool guards, API-base resolution, open, state read, and merge.
- `bin/fm-pr-poll.sh` - the byte-static watcher poll gains a `bitbucket` case that reads the PR state through the REST API with `curl` and `jq`.
- `bin/fm-pr-check.sh` - refuses to arm a Bitbucket watch without `curl`, `jq`, and both credentials, and refuses a target that is not the task clone's own Bitbucket origin.
- `bin/fm-pr-merge.sh` - merges a Bitbucket PR by workspace/repository through the REST API, translating explicit merge methods to Bitbucket strategies.
- `bin/fm-bitbucket-pr.sh` - opens a Bitbucket PR from the command line, the counterpart to `gh-axi pr create`.

## The static poll stays silent unless a PR is genuinely merged

The watcher poll is silent on every error by design, so a missing tool, a missing credential, or a URL that does not reconstruct from its stored parts must all be indistinguishable from "not merged" rather than misread as a merge.
Every component is revalidated in the poll rather than trusted from the sidecar, and the stored URL must reconstruct exactly from `host`, `path`, and `number`.

## Verification

Tooling versions on the verification host (2026-08-12):

```
$ bash --version | head -1
GNU bash, version 5.2.15(1)-release (x86_64-pc-linux-gnu)
$ curl --version | head -1
curl 7.88.1 (x86_64-pc-linux-gnu) libcurl/7.88.1 ...
$ jq --version
jq-1.6
```

The `NO_MISTAKES_BITBUCKET_EMAIL` and `NO_MISTAKES_BITBUCKET_API_TOKEN` credentials are now configured in firstmate's `.env` (`NO_MISTAKES_BITBUCKET_API_BASE_URL` stays unset and defaults to `https://api.bitbucket.org`).
The mock evidence below was captured on 2026-08-12 before the credentials were configured, driving the code against a mock `curl` that returns canned Bitbucket JSON, so it verifies request construction, endpoint selection, credential handling, and the poll's merge-detection and silence contract without a network call.
The live proof against a real Bitbucket repository followed on 2026-08-13 (see "Proven live" below).

The static poll emits exactly one `merged` line for a `MERGED` pull request and stays silent for an open one (mock `curl` returning the canned state):

```
$ fm-pr-poll.sh --validated bitbucket https://bitbucket.org/dashnow/hyfin/pull-requests/7 bitbucket.org dashnow/hyfin 7
merged
$ fm-pr-poll.sh --validated bitbucket https://bitbucket.org/dashnow/hyfin/pull-requests/123 bitbucket.org dashnow/hyfin 123
(no output; no wake)
```

Opening a pull request returns the canonical PR URL, reconstructed from the workspace, repository, and the returned id rather than trusting the response's own links:

```
$ fm-bitbucket-pr.sh open --workspace dashnow --repo hyfin --source fm/demo --dest dev --title "Demo"
https://bitbucket.org/dashnow/hyfin/pull-requests/123
```

Arming and opening both refuse loudly when a credential is absent, rather than silently doing nothing:

```
$ fm-bitbucket-pr.sh open --workspace dashnow --repo hyfin --source fm/x --dest dev   # with credentials unset
error: Bitbucket pull request support requires NO_MISTAKES_BITBUCKET_EMAIL and NO_MISTAKES_BITBUCKET_API_TOKEN
$ echo $?
1
```

The automated coverage lives in `tests/fm-bitbucket-lib.test.sh` (library open/state/merge and the credential, API-base, and target guards), the Bitbucket cases in `tests/fm-pr-merge.test.sh` (the merge path records `pr=` and hits the merge endpoint, and refuses without credentials), and the Bitbucket cases in `tests/fm-pr-check-security.test.sh` (URL parse matrix and the static-poll merged-only-and-silent contract).

## Proven live

The open-PR path was exercised against a real Bitbucket repository on 2026-08-13.
With the credentials sourced from firstmate's `.env`, firstmate opened a real pull request on `dashnow/hyfin`:

```
$ set -a && . ./.env && set +a && bin/fm-bitbucket-pr.sh open --source fix/dual-pricing-paid-invoice-reconcile --dest dev -C <worktree>
https://bitbucket.org/dashnow/hyfin/pull-requests/3613
```

`bin/fm-pr-check.sh` then armed the merge watch with the same credentials.
So firstmate opening a Bitbucket pull request itself is proven, not theoretical.

In `direct-push` delivery the no-mistakes pipeline's own PR and CI steps do not apply on this forge, so the pipeline never reaches the Bitbucket PR step regardless of whether the crew now carries the credentials (see the crew-forwarding section below).
Firstmate opens the pull request itself after the crew's validated branch is pushed, sourcing the `.env` credentials, so this is not a captain-side-only step.

## Crew credential forwarding for Bitbucket-origin lanes

Before this change the crew's pane shell never carried the `NO_MISTAKES_BITBUCKET_*` credentials, so a crew running the no-mistakes pipeline on a Bitbucket product repository passed every local gate and then skipped the PR and CI steps, and every Bitbucket pull request fell to firstmate to open by hand.
`bin/fm-spawn.sh` now forwards the credentials into the crew pane shell, but only for a lane whose project origin resolves to a `bitbucket.org` repository, so a crew on a Bitbucket repo can complete its own PR path end to end.

The forwarding is deliberately narrow and owned by `bin/fm-crew-bitbucket-env-lib.sh`:

- Only the allowlisted `NO_MISTAKES_BITBUCKET_EMAIL`, `NO_MISTAKES_BITBUCKET_API_TOKEN`, and `NO_MISTAKES_BITBUCKET_API_BASE_URL` are forwarded, never the whole `.env`.
- Forwarding happens only when `fm_pr_bitbucket_origin_slug` (`bin/fm-pr-lib.sh`) resolves the project origin to a `bitbucket.org` repository. A GitHub-origin lane, a lane with no resolvable `bitbucket.org` origin, and a secondmate home receive nothing, so a token never reaches a crew with no Bitbucket work.
- No secret value is hardcoded. Values are read at spawn time from the process environment first, then from the home's private `.env` as a fallback (the same precedence `bin/fm-merge-queue-poll.sh`'s `ensure_credentials` uses).
- A Bitbucket-origin lane with no credentials available forwards nothing and does not fail the spawn, so the crew reports the same expected `missing NO_MISTAKES_BITBUCKET_EMAIL` it did before rather than hard-failing.

Behavior is proven by `tests/fm-crew-bitbucket-env.test.sh`, which asserts a Bitbucket-origin lane forwards the allowlisted credentials (including from `.env`), a GitHub-origin lane forwards nothing, and no non-allowlisted variable is ever forwarded.

## Registry flip is a separate captain decision

The live open-PR path is now proven, which removes the technical precondition that kept `hyfin` and `hyfin-server` on `direct-push`.
Whether to flip either project's registry mode (`direct-push` to `no-mistakes` or `direct-PR`) is a separate captain decision and is not made by proving the path live, because it changes the delivery contract for live product work.
