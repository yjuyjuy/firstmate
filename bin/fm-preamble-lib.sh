#!/usr/bin/env bash
# fm-preamble-lib.sh - the single owner of the operational-home resolution
# preamble and the canonical die/fail for bin/ entrypoints.
#
# WHY THIS EXISTS
# Roughly 74 bin/*.sh entrypoints copy-paste the same four-line resolution
# chain (FM_ROOT, FM_HOME, STATE, DATA, and often CONFIG), and each one also
# re-declares its own die/fail with a drifting message prefix and a drifting
# exit code. There was no single owner, so a fix or a policy change to the
# chain had to be hand-applied ~74 times, and the exit codes silently diverged.
# This lib is that owner. Sourcing it resolves the home and defines die/fail
# once, so a migrated entrypoint drops its local copy and inherits the canonical
# behavior.
#
# SCOPE OF THIS PHASE
# This is phase 1 of an incremental migration. Only a small bounded pilot set of
# entrypoints source this lib today; the rest still carry their inline preamble
# and are migrated in a later phase to keep each diff reviewable and low-conflict.
#
# HOW TO ADOPT IT (behavior-preserving migration)
# An entrypoint keeps its own inline SCRIPT_DIR line, because SCRIPT_DIR must be
# computed BEFORE this lib can be sourced (and the entrypoint still needs it to
# source its other sibling libs). Then, before any die/fail call:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   FM_PROG=fm-example FM_DIE_CODE=2
#   # shellcheck source=bin/fm-preamble-lib.sh
#   . "$SCRIPT_DIR/fm-preamble-lib.sh"
#
# and delete the entrypoint's own FM_ROOT/FM_HOME/STATE/DATA/CONFIG assignments
# and its own die/fail definition.
#
# CONTRACT
# Resolution chain (identical to the 74 inline copies; overrides are honored the
# same way, so a migrated script resolves exactly as before):
#   FM_ROOT   = $FM_ROOT_OVERRIDE, else this lib's parent directory (the repo
#               root; the lib lives in bin/ alongside the entrypoints, so this
#               is the same value the inline `$SCRIPT_DIR/..` produced).
#   FM_HOME   = $FM_HOME, else $FM_ROOT_OVERRIDE, else $FM_ROOT.
#   STATE     = $FM_STATE_OVERRIDE,  else $FM_HOME/state.
#   DATA      = $FM_DATA_OVERRIDE,   else $FM_HOME/data.
#   CONFIG    = $FM_CONFIG_OVERRIDE, else $FM_HOME/config.
# The lib does NOT export these; a migrated entrypoint that needs a child process
# to inherit FM_HOME passes it explicitly, exactly as before.
#
# Canonical die/fail:
#   die <message> [code]
#   fail <message> [code]
# Both print "<FM_PROG>: <message>" to stderr and exit with <code>. When a call
# omits <code>, the exit code is $FM_DIE_CODE if the entrypoint set one, else the
# canonical default of 1.
#   FM_PROG     - the message prefix. An entrypoint sets it to its own name
#                 (the exact string its old local die printed) before sourcing.
#                 Defaults to the invoked basename without a trailing .sh.
#   FM_DIE_CODE - the default exit code when a die/fail call passes no explicit
#                 code. The CANONICAL fixed default is 1; an entrypoint whose
#                 legacy die defaulted to a different code sets FM_DIE_CODE to
#                 that legacy code so migration is behavior-preserving. This knob
#                 is the seam a later phase uses to converge the drifted defaults
#                 onto a single value; until then it preserves each script's exit
#                 code exactly.
#
# RECONCILIATION WITH fm-wake-lib.sh
# bin/fm-wake-lib.sh carries a deliberately different chain
# (FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_WAKE_DEFAULT_ROOT}}"): it is a
# sourced library, not an entrypoint, so it honors an FM_ROOT an entrypoint
# already resolved rather than recomputing one from a SCRIPT_DIR it does not
# own. That middle `${FM_ROOT:-...}` term is intentional and is why wake-lib does
# NOT source this lib. See the cross-reference comment in fm-wake-lib.sh.

FM_PREAMBLE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_PREAMBLE_LIB_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck disable=SC2034  # Resolved here for the sourcing entrypoint to consume.
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck disable=SC2034  # Resolved here for the sourcing entrypoint to consume.
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck disable=SC2034  # Resolved here for the sourcing entrypoint to consume.
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

FM_PROG="${FM_PROG:-$(basename -- "${0:-fm}" .sh)}"

die() {
  printf '%s: %s\n' "$FM_PROG" "$1" >&2
  exit "${2:-${FM_DIE_CODE:-1}}"
}

fail() {
  printf '%s: %s\n' "$FM_PROG" "$1" >&2
  exit "${2:-${FM_DIE_CODE:-1}}"
}
