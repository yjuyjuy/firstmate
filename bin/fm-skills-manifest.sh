#!/usr/bin/env bash
# fm-skills-manifest.sh - the single owner of the fleet skills manifest: the one
# tracked list of first-party tool skills every fleet home should carry, and the
# additive, idempotent way to install them.
#
# The manifest is config/skills-manifest in the firstmate code root (TRACKED,
# unlike the gitignored local config files beside it). One source per line, in
# the form "<owner>/<repo>@<skill>", with blank lines and lines starting with #
# ignored. A malformed line is refused loudly rather than skipped, so a typo
# cannot silently drop a skill out of the fleet. Adding a skill to the fleet is
# one appended line; nothing else needs to change.
#
# Usage:
#   fm-skills-manifest.sh [check]
#       Detect only. Never installs, never writes. Prints exactly one line when
#       manifest skills are missing from the install root:
#         "SKILLS_MANIFEST: <n> manifest skill(s) missing: <names> (install: bin/fm-skills-manifest.sh install)"
#       and prints nothing when every manifest skill is present. Exit status is 0
#       either way, matching bin/fm-bootstrap.sh's detect-first convention: a
#       session start reports the gap, it does not mutate a shared skills tree
#       behind the captain's back.
#   fm-skills-manifest.sh install [<skill>...]
#       Install the missing manifest skills through "npx skills add", one at a
#       time, printing one line per installed skill. With no arguments it
#       installs every missing manifest skill; with skill names it installs only
#       those (each must be named by the manifest). Exits non-zero if any install
#       fails, after attempting the rest.
#   fm-skills-manifest.sh list
#       Print the resolved manifest, one "<source> <skill>" pair per line.
#
# Idempotence and the additive-only rule:
#   A skill is "present" when <install-root>/<skill>/SKILL.md exists. Install
#   SKIPS every present skill, so a second run performs no download and touches
#   no file - a genuine no-op, not a re-copy that churns mtimes. That skip is
#   also the safety property: the install root is shared, live, captain-visible
#   state holding skills this manifest does not own, so this script never
#   deletes, prunes, overwrites, or reconciles anything. It only ever adds a
#   skill that is absent. There is deliberately no sync-to-match mode and no
#   --force: refreshing an installed skill is "npx skills update <skill>", which
#   is the skills CLI's job, not this script's.
#
# Install root:
#   ~/.agents/skills, the box-global agent skills tree (~/.claude/skills is a
#   symlink to it). "npx skills add ... --agent universal -g" is what writes
#   there, so the root follows HOME. FM_SKILLS_HOME overrides that HOME for
#   tests, which is how the install path is exercised against a throwaway
#   directory instead of the real tree; when it is set, GIT_CONFIG_GLOBAL is
#   pointed at the real HOME's .gitconfig unless already set, so the GitHub
#   credential helper still resolves private manifest sources from a scratch root.
#   FM_SKILLS_MANIFEST overrides the manifest path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
MANIFEST="${FM_SKILLS_MANIFEST:-$FM_ROOT/config/skills-manifest}"
REAL_HOME="$HOME"
SKILLS_HOME="${FM_SKILLS_HOME:-$HOME}"
SKILLS_DIR="$SKILLS_HOME/.agents/skills"

usage() {
  # Explicit help goes to stdout; a usage error routes it to stderr.
  local out=${1:-2}
  {
    echo "usage: fm-skills-manifest.sh [check]"
    echo "       fm-skills-manifest.sh install [<skill>...]"
    echo "       fm-skills-manifest.sh list"
  } >&"$out"
}

# Emit "<source>\t<skill>" per manifest entry. A line that is not
# <owner>/<repo>@<skill> is a manifest defect: refuse the whole run rather than
# skip it, so a typo can never quietly remove a skill from the fleet.
read_manifest() {
  local line source skill lineno=0
  [ -f "$MANIFEST" ] || {
    echo "error: no skills manifest at $MANIFEST" >&2
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%%$'\r'}
    case "$line" in
      ''|'#'*) continue ;;
    esac
    source=${line%@*}
    skill=${line##*@}
    case "$line" in
      *@*) ;;
      *)
        echo "error: $MANIFEST line $lineno: expected <owner>/<repo>@<skill>, got: $line" >&2
        return 1
        ;;
    esac
    case "$source" in
      */*) ;;
      *)
        echo "error: $MANIFEST line $lineno: source must be <owner>/<repo>, got: $source" >&2
        return 1
        ;;
    esac
    if [ -z "$skill" ] || [ -z "${source%%/*}" ] || [ -z "${source#*/}" ]; then
      echo "error: $MANIFEST line $lineno: empty owner, repo, or skill in: $line" >&2
      return 1
    fi
    case "$skill" in
      */*|*' '*)
        echo "error: $MANIFEST line $lineno: skill name must be a bare name, got: $skill" >&2
        return 1
        ;;
    esac
    printf '%s\t%s\n' "$source" "$skill"
  done < "$MANIFEST"
}

skill_present() {
  [ -f "$SKILLS_DIR/$1/SKILL.md" ]
}

# Install one manifest source. The skills CLI writes under HOME, so the install
# root is selected by HOME alone; nothing else here can redirect it. stdin is
# closed because the caller drives this from a loop reading the manifest, and an
# interactive-capable child that inherits that stream eats the remaining entries.
install_one() {
  local source=$1 skill=$2
  HOME="$SKILLS_HOME" \
  GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL:-$REAL_HOME/.gitconfig}" \
    npx -y skills add "$source@$skill" --agent universal -g -y </dev/null >/dev/null 2>&1
}

cmd_list() {
  local source skill entries
  # read_manifest is captured BEFORE the loop, never piped into it: inside a
  # pipeline or process substitution its refusal exit status is discarded, which
  # would turn a manifest defect into a silent skip.
  entries=$(read_manifest) || return 1
  while IFS=$'\t' read -r source skill; do
    [ -n "$skill" ] || continue
    printf '%s %s\n' "$source@$skill" "$skill"
  done <<< "$entries"
}

cmd_check() {
  local source skill missing="" count entries
  entries=$(read_manifest) || return 1
  while IFS=$'\t' read -r source skill; do
    [ -n "$skill" ] || continue
    skill_present "$skill" || missing="${missing}${missing:+, }$skill"
  done <<< "$entries"
  [ -n "$missing" ] || return 0
  count=$(printf '%s' "$missing" | awk -F ', ' '{print NF}')
  echo "SKILLS_MANIFEST: $count manifest skill(s) missing: $missing (install: bin/fm-skills-manifest.sh install)"
}

cmd_install() {
  local source skill failed=0 requested known="" selective=0 entries
  [ $# -gt 0 ] && selective=1
  entries=$(read_manifest) || return 1
  for requested in "$@"; do
    known=$(printf '%s\n' "$entries" | awk -F '\t' -v s="$requested" '$2 == s {print $2}')
    [ -n "$known" ] || {
      echo "error: $requested is not named by $MANIFEST" >&2
      return 1
    }
  done
  while IFS=$'\t' read -r source skill; do
    [ -n "$skill" ] || continue
    if [ "$selective" -eq 1 ]; then
      printf '%s\n' "$@" | grep -Fxq "$skill" || continue
    fi
    # Present means done: never re-download, never overwrite a live skill.
    skill_present "$skill" && continue
    if install_one "$source" "$skill" && skill_present "$skill"; then
      echo "installed $skill (from $source)"
    else
      echo "SKILLS_MANIFEST: install failed for $skill (from $source)" >&2
      failed=1
    fi
  done <<< "$entries"
  [ "$failed" -eq 0 ]
}

case "${1:-check}" in
  -h|--help)
    usage 1
    exit 0
    ;;
  check)
    [ $# -le 1 ] || { usage; exit 1; }
    cmd_check
    ;;
  list)
    [ $# -eq 1 ] || { usage; exit 1; }
    cmd_list
    ;;
  install)
    shift
    cmd_install "$@"
    ;;
  *)
    usage
    exit 1
    ;;
esac
