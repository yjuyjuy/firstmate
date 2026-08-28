#!/usr/bin/env bash
# tests/fm-steer-templates.test.sh - the cache-warm steer-phrasing emitter
# (bin/fm-steer-templates.sh).
#
# Contract under test: each of the five named templates emits its FIXED prefix,
# byte-for-byte, and appends a caller-supplied variable tail after it. The fixed
# prefix is the load-bearing property - it is what keeps a worker's prompt cache
# warm across steers - so the test pins the exact prefix bytes, not just that
# some output appeared. Unknown templates and a missing argument fail loudly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EMIT="$ROOT/bin/fm-steer-templates.sh"

# The pinned fixed prefixes. Changing one here MUST mean changing it in the
# emitter too; that is the point - a silent prefix drift busts the prompt cache.
declare -a TEMPLATES=(
  "nudge=Status check:"
  "decision-delivery=Decision:"
  "blocker-query=Blocked on what exactly?"
  "gate-response=Answer the active gate:"
  "wrapup=Wrap up and report done:"
)

test_bare_template_emits_fixed_prefix() {
  local entry name prefix out
  for entry in "${TEMPLATES[@]}"; do
    name=${entry%%=*}
    prefix=${entry#*=}
    out=$("$EMIT" "$name")
    [ "$out" = "$prefix" ] \
      || fail "template '$name' bare output must equal fixed prefix '$prefix', got '$out'"
  done
  pass "fm-steer-templates: each template emits its fixed prefix with no tail"
}

test_template_appends_variable_tail() {
  local entry name prefix out
  for entry in "${TEMPLATES[@]}"; do
    name=${entry%%=*}
    prefix=${entry#*=}
    out=$("$EMIT" "$name" still working on the vitest run)
    [ "$out" = "$prefix still working on the vitest run" ] \
      || fail "template '$name' must append tail after fixed prefix, got '$out'"
  done
  pass "fm-steer-templates: each template appends the variable tail after its fixed prefix"
}

test_list_names_all_five_templates() {
  local out
  out=$("$EMIT" --list)
  [ "$out" = "nudge
decision-delivery
blocker-query
gate-response
wrapup" ] || fail "--list must name all five templates, got '$out'"
  pass "fm-steer-templates: --list names all five templates"
}

test_unknown_template_fails() {
  local rc=0
  "$EMIT" not-a-template >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "unknown template must exit 2, got $rc"
  pass "fm-steer-templates: an unknown template fails loudly (exit 2)"
}

test_missing_argument_fails() {
  local rc=0
  "$EMIT" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "missing template argument must exit 2, got $rc"
  pass "fm-steer-templates: a missing template argument fails loudly (exit 2)"
}

test_bare_template_emits_fixed_prefix
test_template_appends_variable_tail
test_list_names_all_five_templates
test_unknown_template_fails
test_missing_argument_fails
