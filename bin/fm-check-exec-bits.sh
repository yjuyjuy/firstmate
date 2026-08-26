#!/usr/bin/env bash
# fm-check-exec-bits.sh - guard that every directly-invoked entrypoint under
# bin/ stays executable.
#
# Regression origin: two silent spawn failures in one week were caused by bin/
# scripts missing the executable bit. ShellCheck does not inspect file modes, so
# the lint gate could not catch it; a script that loses +x still lints clean and
# only fails at spawn time, as a silent no-such-command or permission error.
#
# Coverage contract (two rules, one guard):
#   1. Every shell script under bin/ (bin/*.sh and bin/backends/*.sh, including
#      the backend adapters fm-backend.sh sources and the smoke tests invoke
#      directly, and sourced-only *-lib.sh libraries) must carry +x. This is one
#      deliberately uniform line with no per-file judgment: a sourced-only
#      library is harmless with +x, and the uniform rule keeps the check trivial
#      and unambiguous for contributors and reviewers.
#   2. Every non-.sh entrypoint under bin/ must carry +x too, so a bare
#      interpreter script (jira-axi) or an extensioned one (herdr-workspace-move.py,
#      *.mjs, *.js) cannot silently lose +x the way a .sh file could. A file's
#      shebang is the entrypoint signal: a non-.sh file that starts with '#!' is
#      run directly and must be executable, while a non-.sh file with no shebang
#      is data or a sourced-only module and is exempt.
#
# Usage:
#   fm-check-exec-bits.sh [root]  check the tree rooted at [root] (default: the
#                                 repo this script lives in); exit 0 when every
#                                 covered entrypoint has +x, non-zero listing
#                                 each offender otherwise.
#
# Wired into the CI lint job (.github/workflows/ci.yml) next to bin/fm-lint.sh;
# both gates stay on the one owner for their own concerns, and this script is
# the single owner of the exec-bit rule so it can run anywhere bin/fm-lint.sh
# can. It is cheap (no ShellCheck needed) and safe to run locally or in gates.
set -eu

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"

status=0
count=0

# report <path>: record one offender missing +x.
report() {
  printf 'fm-check-exec-bits.sh: %s is missing the executable bit (chmod +x %s)\n' "$1" "$1"
  count=$((count + 1))
  status=1
}

# Rule 1: the uniform shell-script rule (every bin/*.sh and bin/backends/*.sh).
for f in bin/*.sh bin/backends/*.sh; do
  [ -f "$f" ] || continue
  [ -x "$f" ] || report "$f"
done

# Rule 2: shebang-bearing non-.sh entrypoints. bin/* lists bin/backends as a
# directory, skipped by the -f test, so files are never double-counted with the
# bin/backends/* pass below.
for f in bin/* bin/backends/*; do
  [ -f "$f" ] || continue
  case "$f" in
    *.sh) continue ;; # already covered by rule 1
  esac
  # A shebang (first two bytes '#!') marks a directly-invoked entrypoint; a
  # non-.sh file without one is data or a sourced-only module and is exempt.
  [ "$(head -c 2 "$f" 2>/dev/null)" = '#!' ] || continue
  [ -x "$f" ] || report "$f"
done

if [ "$status" -ne 0 ]; then
  printf 'fm-check-exec-bits.sh: %s bin entrypoint(s) lack +x\n' "$count" >&2
fi
exit "$status"
