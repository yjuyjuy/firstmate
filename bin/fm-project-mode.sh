#!/usr/bin/env bash
# Resolve a project's delivery mode, yolo flag, autoland flag, and no-ci posture
# from the data/projects.md registry.
# Prints four words to stdout: "<mode> <yolo> <autoland> <noci>" where mode is one
# of no-mistakes|direct-PR|direct-push|local-only and yolo/autoland/noci are on|off.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                              -> no-mistakes off off off
#   - <name> [<mode>] - <desc> (added <date>)                     -> <mode> off off off
#   - <name> [<mode> +yolo] - <desc> (added <date>)               -> <mode> on off off
#   - <name> [<mode> +autoland] - <desc> (added <date>)           -> <mode> off on off
#   - <name> [<mode> +no-ci] - <desc> (added <date>)              -> <mode> off off on
#   - <name> [<mode> +yolo +autoland] - <desc> (added <date>)     -> <mode> on on off
# The +yolo, +autoland, and +no-ci flags are order-independent inside the brackets.
#
# noci (orthogonal) = the project's forge runs no CI on our branches: a fork with
#   GitHub Actions disabled, or any no-merge-authority repo whose ci step can never
#   report checks. On such a repo the no-mistakes pipeline reaches the pr step clean
#   and then polls "no CI checks reported" forever, so "CI green" is structurally
#   unreachable and the true ready-state is CLEAN+MERGEABLE-awaiting-merge. fm-brief.sh
#   reshapes the no-mistakes Definition of done for a +no-ci repo so the crew appends an
#   explicit `paused: ... awaiting captain merge (no CI on fork)` terminal line and idles
#   instead of chasing an unreachable green, which lets the watcher absorb the idle pane
#   on its long cadence rather than wedge-escalating it as a stopped crew.
#
# mode = how a finished change reaches main:
#   no-mistakes  full pipeline -> PR -> captain merge (default)
#   direct-PR    push + PR via gh-axi, no pipeline -> captain merge
#   direct-push  full pipeline (its PR/CI steps skipped) -> push validated branch to
#                origin -> firstmate opens the PR itself on forges such as Bitbucket
#                (sourcing .env creds) -> configured merge authority lands it.
#   local-only   local branch, no remote/PR -> captain approve -> guarded local merge
# yolo (orthogonal) = when on, firstmate makes approval decisions itself (PR merges,
#   ask-user findings, local-only merge approval) without checking the captain - except
#   anything destructive/irreversible/security-sensitive, which still escalates.
# autoland (orthogonal) = a durable standing captain grant that GREEN work self-lands
#   without waiting for the captain, set ONLY on repos we own (never on a read-only or
#   not-owned clone). Its effect depends on the mode:
#     direct-push  the crew, after the pipeline reports `passed`, merges its own green
#                  `fm/<id>` branch onto the origin default branch as a clean `--no-ff`
#                  merge and pushes; firstmate then records a captain-review hold.
#     local-only   firstmate fires the guarded local merge (bin/fm-merge-local.sh)
#                  automatically once the single review gate is green, instead of waiting.
#   A conflict, or any destructive/irreversible/security-sensitive choice, still escalates.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off off off" and
# warns to stderr, so a typo never silently drops the gate.
#
# --strict turns that fallback into a refusal: nothing is printed to stdout, an
# actionable diagnostic goes to stderr, and the exit status is 3. A caller whose
# output is a delivery CONTRACT (bin/fm-brief.sh, whose whole definition-of-done
# section is shaped by the mode) must use --strict, because a wrong-mode contract
# reaching a crewmate is a defect while a warning on stderr is only a hint that a
# scripted or piped caller never sees. The diagnostic names the likely
# path-versus-name mistake: this script takes a REGISTRY NAME, while
# bin/fm-spawn.sh takes a PATH, so "projects/<name>" is the easy mistake to make.
# When the argument's basename IS registered, the refusal says so explicitly and
# prints the name to use; otherwise it lists the registered names.
# Usage: fm-project-mode.sh [--strict] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
STRICT=0
NAME=""
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    *) NAME=$arg ;;
  esac
done
[ -n "$NAME" ] || { echo "usage: fm-project-mode.sh [--strict] <project-name>" >&2; exit 1; }

# Registered project names, one per line, for the strict refusal's guidance.
registry_names() {
  [ -f "$REG" ] || return 0
  awk '$1=="-" && $2!="" { print $2 }' "$REG"
}

# The strict refusal. It exists to make a path-versus-name typo impossible to
# confuse with a genuinely unregistered project, so it leads with the basename
# hint whenever that basename is itself a registry entry.
refuse() { # <reason>
  local base
  echo "error: cannot resolve a delivery mode for project \"$NAME\": $1" >&2
  base=${NAME##*/}
  if [ "$base" != "$NAME" ] && registry_names | grep -qxF "$base"; then
    echo "       \"$NAME\" looks like a PATH, but this takes a REGISTRY NAME; \"$base\" IS registered - use \"$base\"" >&2
    echo "       (bin/fm-spawn.sh takes the project PATH; bin/fm-brief.sh and this script take the registry NAME)" >&2
  else
    case "$NAME" in
      */*) echo "       \"$NAME\" looks like a PATH, but this takes a REGISTRY NAME (bin/fm-spawn.sh is the one that takes a PATH)" >&2 ;;
    esac
    echo "       registered projects: $(registry_names | paste -sd' ' - 2>/dev/null)" >&2
    echo "       fix: register the project in $REG, or pass --unregistered to bin/fm-brief.sh to accept the no-mistakes default deliberately" >&2
  fi
  exit 3
}

if [ ! -f "$REG" ]; then
  if [ "$STRICT" -eq 1 ]; then refuse "no registry at $REG"; fi
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off off off" >&2
  echo "no-mistakes off off off"
  exit 0
fi

# awk emits "<mode> <yolo> <autoland> <noci>" (one line) or nothing if the project is absent.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; autoland="off"; noci="off";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] != "+yolo" && a[1] != "+autoland" && a[1] != "+no-ci") mode = a[1];
      for (j=1; j<=k; j++) {
        if (a[j]=="+yolo")     yolo="on";
        if (a[j]=="+autoland") autoland="on";
        if (a[j]=="+no-ci")    noci="on";
      }
    }
    print mode, yolo, autoland, noci; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  if [ "$STRICT" -eq 1 ]; then refuse "not in registry $REG"; fi
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off off off" >&2
  echo "no-mistakes off off off"
  exit 0
fi

read -r mode yolo autoland noci _ <<EOF
$parsed
EOF
case "$mode" in
  no-mistakes|direct-PR|direct-push|local-only) ;;
  *)
    if [ "$STRICT" -eq 1 ]; then refuse "unknown mode \"$mode\" in its registry line"; fi
    echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off off off" >&2; mode=no-mistakes; yolo=off; autoland=off; noci=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
case "$autoland" in on|off) ;; *) autoland=off ;; esac
case "$noci" in on|off) ;; *) noci=off ;; esac
echo "$mode $yolo $autoland $noci"
