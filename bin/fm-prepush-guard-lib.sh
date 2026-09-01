#!/usr/bin/env bash
# fm-prepush-guard-lib.sh - install a worktree-scoped pre-push hook that refuses
# an out-of-band push to the repository default branch.
#
# The hole this closes (HIGH severity, observed live 2026-08-20): the ONLY
# firstmate-side thing stopping an out-of-band default-branch push used to be
# brief text. When a lane's no-mistakes push step refused (e.g. review skipped),
# a worker could run `no-mistakes axi sync --recover` to take custody back, then
# `git push origin HEAD:<default>` - no pre-push hook, no watcher check, and no
# branch protection stopped it. no-mistakes' own push refusal fired first and
# correctly, and was simply bypassed. This library is the enforceable capability
# half of the fix (the brief stop-rule in bin/fm-brief.sh is the instruction
# half): an executable hook the confused worker cannot talk its way past.
#
# WHY a worktree-scoped core.hooksPath and not a plain .git/hooks/pre-push:
# a linked worktree's hooks resolve to the SHARED common .git/hooks, so a plain
# hook installed for one lane would fire for the primary checkout and every other
# lane too (verified live). A per-worktree core.hooksPath (via
# extensions.worktreeConfig) is the only mechanism that isolates the hook to this
# one worktree - the same mechanism no-mistakes itself uses to pin hooks on its
# gate-mirror worktrees, so the pattern is already load-bearing in this fleet.
#
# WHAT the generated hook refuses: a push whose target ref is the repository
# default branch (detected origin default, plus the common names main/master/dev
# as a belt-and-braces fallback so an unset origin/HEAD cannot silently disarm
# the guard). It refuses on ANY real remote. It does NOT refuse:
#   - pushes to the no-mistakes gate mirror (URL under .no-mistakes/repos/*.git):
#     the pipeline pushes the WORK branch there, never an out-of-band land, so a
#     gate push is always allowed - a hook that blocked legit pipeline pushes
#     would be worse than the hole it closes.
#   - pushes carrying FM_ALLOW_DEFAULT_PUSH=1 in the environment: the firstmate-
#     authored, pipeline-green autoland self-land (bin/fm-brief.sh direct-push
#     +autoland Definition of done) is the one legitimate default-branch push a
#     worker performs, and it sets that sentinel inline on exactly that command.
#   - pushes to any non-default branch (fm/<id>, landing refs, etc.).
#
# Fail-loud, non-zero: the refusal prints a clear banner to stderr and exits 1,
# so git aborts the push. It CANNOT stop an adversary who adds `--no-verify` or
# unsets core.hooksPath - that is out of scope. The threat model here is the
# CONFUSED-not-adversarial worker following stale brief wording, whose plain
# `git push origin HEAD:<default>` this hook stops cold; the brief stop-rule is
# the layered instruction defense for the same worker.
#
# Sourced by bin/fm-spawn.sh. No side effects on source. set -u / set -e safe.

# fm_install_prepush_guard <worktree>
# Enable per-worktree config, point core.hooksPath at a gitignored hooks dir
# inside the worktree, and write the pre-push guard there. Idempotent: a second
# call overwrites the hook with the current text and leaves config as-is.
# Best-effort: on any failure it prints a warning to stderr and returns 0, so a
# guard-install hiccup never aborts an otherwise-good spawn (the brief stop-rule
# still covers the worker). Returns non-zero only on a usage error.
fm_install_prepush_guard() {
  local wt=${1:?usage: fm_install_prepush_guard <worktree>}
  [ -d "$wt" ] || { echo "warning: fm_install_prepush_guard: worktree '$wt' is not a directory; skipping push guard" >&2; return 0; }

  # Record any pre-existing pre-push so the guard chains to it rather than
  # silently replacing it. The current effective hooks dir is core.hooksPath if
  # set (worktree scope wins over local), else the repo's default hooks dir.
  local prior_dir prior_hook=""
  prior_dir=$(git -C "$wt" config --get core.hooksPath 2>/dev/null || true)
  if [ -z "$prior_dir" ]; then
    prior_dir=$(git -C "$wt" rev-parse --git-path hooks 2>/dev/null || true)
    # rev-parse may print a path relative to the worktree; anchor it.
    case "$prior_dir" in
      ""|/*) ;;
      *) prior_dir="$wt/$prior_dir" ;;
    esac
  fi
  if [ -n "$prior_dir" ] && [ -x "$prior_dir/pre-push" ]; then
    prior_hook=$(cd "$prior_dir" 2>/dev/null && pwd -P)/pre-push || prior_hook=""
  fi

  local hooks_dir="$wt/.fm-hooks"
  local own_hook=""
  if [ -e "$hooks_dir/pre-push" ]; then
    own_hook=$(cd "$hooks_dir" 2>/dev/null && pwd -P)/pre-push || own_hook=""
  else
    own_hook=$(cd "$wt" 2>/dev/null && pwd -P)/.fm-hooks/pre-push || own_hook=""
  fi
  if [ -n "$prior_hook" ] && [ -n "$own_hook" ] && [ "$prior_hook" = "$own_hook" ]; then
    prior_hook=""
  fi

  if ! mkdir -p "$hooks_dir" 2>/dev/null; then
    echo "warning: fm_install_prepush_guard: cannot create '$hooks_dir'; skipping push guard" >&2
    return 0
  fi

  # Keep the hooks dir out of git's view exactly like the turn-end hooks, so it
  # never blocks teardown's dirty check or leaks into a commit.
  local excl
  excl=$(git -C "$wt" rev-parse --git-path info/exclude 2>/dev/null || true)
  if [ -n "$excl" ]; then
    mkdir -p "$(dirname "$excl")" 2>/dev/null || true
    grep -qxF '.fm-hooks/' "$excl" 2>/dev/null || echo '.fm-hooks/' >> "$excl" 2>/dev/null || true
  fi

  fm_prepush_guard_hook_text "$prior_hook" > "$hooks_dir/pre-push" || {
    echo "warning: fm_install_prepush_guard: could not write the pre-push guard; skipping" >&2
    return 0
  }
  chmod +x "$hooks_dir/pre-push" 2>/dev/null || true

  # Per-worktree hooksPath needs the worktreeConfig extension. Enable it (repo
  # scope) then set the path in worktree scope so it binds ONLY this worktree.
  git -C "$wt" config extensions.worktreeConfig true 2>/dev/null || {
    echo "warning: fm_install_prepush_guard: cannot enable extensions.worktreeConfig; skipping push guard" >&2
    return 0
  }
  local hooks_dir_real
  hooks_dir_real=$(cd "$hooks_dir" 2>/dev/null && pwd -P) || hooks_dir_real="$hooks_dir"
  git -C "$wt" config --worktree core.hooksPath "$hooks_dir_real" 2>/dev/null || {
    echo "warning: fm_install_prepush_guard: cannot pin per-worktree core.hooksPath; skipping push guard" >&2
    return 0
  }
  return 0
}

# fm_prepush_guard_hook_text [<prior-hook-abs-path>]
# Emit the self-contained pre-push hook to stdout. The hook takes no firstmate
# dependencies: it runs in the worker's bare git context at push time.
fm_prepush_guard_hook_text() {
  local prior_hook=${1:-}
  cat <<EOF
#!/usr/bin/env bash
# firstmate pre-push guard - installed by bin/fm-prepush-guard-lib.sh.
# Refuses an out-of-band push to the repository default branch. See that library
# for the full rationale. Do not edit by hand: fm-spawn rewrites it per spawn.
set -u

remote_name=\${1:-}
remote_url=\${2:-}
prior_hook=$(fm__prepush_sq "$prior_hook")

# Capture the ref list once so we can inspect it AND replay it to a chained hook.
refs_in=\$(cat)

chain_then() {  # <exit-code-if-no-prior>
  if [ -n "\$prior_hook" ] && [ -x "\$prior_hook" ]; then
    printf '%s' "\$refs_in" | "\$prior_hook" "\$remote_name" "\$remote_url"
    exit \$?
  fi
  exit "\${1:-0}"
}

# The no-mistakes gate mirror only ever receives the work branch; always allow.
case "\$remote_url" in
  */.no-mistakes/repos/*.git|*/.no-mistakes/repos/*.git/) chain_then 0 ;;
esac

# The one firstmate-authorized default-branch push (autoland self-land) carries
# this sentinel inline on exactly that command.
if [ "\${FM_ALLOW_DEFAULT_PUSH:-}" = 1 ]; then
  chain_then 0
fi

# Detected origin default, plus the common names as a fail-closed fallback so an
# unset origin/HEAD cannot silently disarm the guard. fm/<id> and landing refs
# never match any of these, so a legitimate ship push is never blocked.
default=\$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##') || default=
is_default() {
  local b=\$1
  [ -n "\$default" ] && [ "\$b" = "\$default" ] && return 0
  case "\$b" in main|master|dev) return 0 ;; esac
  return 1
}

refused=
while read -r _local_ref _local_sha remote_ref _remote_sha; do
  [ -n "\$remote_ref" ] || continue
  case "\$remote_ref" in refs/heads/*) : ;; *) continue ;; esac
  branch=\${remote_ref#refs/heads/}
  if is_default "\$branch"; then refused=\$branch; break; fi
done <<REFS
\$refs_in
REFS

if [ -n "\$refused" ]; then
  cat >&2 <<'BANNER'
=====================================================================
 firstmate: REFUSING a direct push to the default branch.
=====================================================================
A worker must never push to the repository default branch out of band.
If the pipeline refused to push, STOP and report it - do NOT run
'no-mistakes axi sync --recover' to bypass the refusal, and do NOT
hand-push to the default branch. Push your fm/<id> branch instead and
let the configured merge authority land it.
BANNER
  echo "firstmate: blocked push of '\$refused' to \$remote_name (\$remote_url)" >&2
  exit 1
fi

chain_then 0
EOF
}

# fm__prepush_sq - shell-quote a string for safe embedding in the generated hook.
fm__prepush_sq() {
  local s=${1:-}
  printf "'%s'" "${s//\'/\'\\\'\'}"
}
