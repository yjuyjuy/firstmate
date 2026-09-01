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
# Usage: fm-project-mode.sh <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
NAME=${1:?usage: fm-project-mode.sh <project-name>}

if [ ! -f "$REG" ]; then
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
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off off off" >&2
  echo "no-mistakes off off off"
  exit 0
fi

read -r mode yolo autoland noci _ <<EOF
$parsed
EOF
case "$mode" in
  no-mistakes|direct-PR|direct-push|local-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off off off" >&2; mode=no-mistakes; yolo=off; autoland=off; noci=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
case "$autoland" in on|off) ;; *) autoland=off ;; esac
case "$noci" in on|off) ;; *) noci=off ;; esac
echo "$mode $yolo $autoland $noci"
