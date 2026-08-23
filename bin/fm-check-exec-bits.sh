#!/usr/bin/env bash
# fm-check-exec-bits.sh - guard that every shell script under bin/ stays executable.
#
# Regression origin: two silent spawn failures in one week were caused by bin/
# scripts missing the executable bit. ShellCheck does not inspect file modes, so
# the lint gate could not catch it; a script that loses +x still lints clean and
# only fails at spawn time, as a silent no-such-command or permission error.
#
# The rule is deliberately one uniform line with no per-file judgment: every
# shell script under bin/ (including the backend adapters under bin/backends/,
# which fm-backend.sh sources and the smoke tests invoke directly) must carry
# +x. A sourced-only library is harmless with +x, and the uniform rule keeps
# the check trivial and unambiguous for contributors and reviewers.
#
# Usage:
#   fm-check-exec-bits.sh   check the tree; exit 0 when every bin shell script
#                           has +x, non-zero listing each offender otherwise.
#
# Wired into the CI lint job (.github/workflows/ci.yml) next to bin/fm-lint.sh;
# both gates stay on the one owner for their own concerns, and this script is
# the single owner of the exec-bit rule so it can run anywhere bin/fm-lint.sh
# can. It is cheap (no ShellCheck needed) and safe to run locally or in gates.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

status=0
count=0
for f in bin/*.sh bin/backends/*.sh; do
  [ -f "$f" ] || continue
  if [ ! -x "$f" ]; then
    printf 'fm-check-exec-bits.sh: %s is missing the executable bit (chmod +x %s)\n' "$f" "$f"
    count=$((count + 1))
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  printf 'fm-check-exec-bits.sh: %s bin script(s) lack +x\n' "$count" >&2
fi
exit "$status"