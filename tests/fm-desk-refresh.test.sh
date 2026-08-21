#!/usr/bin/env bash
# Behavior tests for the captain's-desk renderer.
#
# The regression these guard: an unreadable or unusual data source must never
# render as a confident empty section ("Nothing is running") - it must render as
# a VISIBLE GAP. Two independent failure modes caused the confident-empty bug:
#   1. desk_json swallowed a jq failure (one object/array-valued field makes
#      @tsv reject the WHOLE stream) via `2>/dev/null || printf ''`, so a
#      populated section rendered empty with no gap.
#   2. The desk resolved FM_HOME but never exported it, so a child source could
#      resolve a different (empty) home than the ticket band, which cd's into
#      FM_HOME. The tests assert the resolved home reaches the child.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DESK="$ROOT/bin/fm-desk-refresh.sh"
TMP_ROOT=$(fm_test_tmproot fm-desk)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A populated projection: two open decisions, three in-flight rows (one with an
# OBJECT-valued .doing to exercise the scalarize hardening, one blocked to drive
# section 2), one landed row, one recorded PR, two second mates (one idle).
POPULATED=$(cat <<'JSON'
{
  "decisions_open": [
    {"id":"decide-alpha","summary":"pick a data store","owner":"scout","blocking":true},
    {"id":"decide-pay-rename","summary":"confirm the pricing rename","owner":"scout"},
    {"id":"decide-long","summary":"weigh a long tradeoff between two competing approaches that each carry real cos","summary_full":"weigh a long tradeoff between two competing approaches that each carry real cost, real risk, and a materially different long-term maintenance burden the captain must judge","owner":"scout"}
  ],
  "in_flight": [
    {"id":"ship-one","kind":"ship","state":"working","doing":"editing the parser"},
    {"id":"ship-two","kind":"ship","state":"working","doing":{"weird":"object"}},
    {"id":"ship-stuck","kind":"ship","state":"blocked","doing":"waiting on a credential"}
  ],
  "gates": [],
  "landed": [
    {"id":"ship-old","what":"landed the migration"}
  ],
  "recorded_prs": [
    {"id":"pr-one","url":"https://github.com/acme/repo/pull/9"}
  ],
  "secondmates": [
    {"id":"decision-desk","state":"working","doing":"ruling on a schema question"},
    {"id":"mirror-desk","state":"no_active_work","doing":"No active child work"},
    {"id":"empty-desk","state":"no_active_work","doing":"No active child work"}
  ]
}
JSON
)

# A fixture quota-axi report (schemaVersion 3, matching the live tool). Claude
# carries two windows whose binding (lowest-percent) window is the 30% session
# window, OpenCode one high-runway week window, and Grok NO windows (the
# auth-required path). The projected-exhausted and reset times come from Claude's
# session window; the lowest runway across all accounts is Claude 30%.
QUOTA_FIXTURE=$(cat <<'JSON'
{
  "generatedAt": "2026-08-20T00:00:00Z",
  "schemaVersion": 3,
  "providers": [
    {
      "provider": "claude",
      "label": "Claude",
      "source": "oauth",
      "plan": "team",
      "state": {"status": "fresh", "stale": false},
      "windows": [
        {"id": "five_hour", "kind": "session", "label": "session", "percentUsed": 70, "percentRemaining": 30, "resetsAt": "2026-08-20T18:00:00Z", "pace": {"status": "behind", "projectedExhaustedAt": "2026-08-20T16:00:00Z"}},
        {"id": "seven_day", "kind": "weekly", "label": "week", "percentUsed": 20, "percentRemaining": 80, "resetsAt": "2026-08-24T13:00:00Z", "pace": {"status": "ahead", "projectedExhaustedAt": "2026-08-23T05:00:00Z"}}
      ]
    },
    {
      "provider": "opencode",
      "label": "OpenCode",
      "source": "unavailable",
      "state": {"status": "fresh", "stale": false},
      "windows": [
        {"id": "seven_day", "kind": "weekly", "label": "week", "percentUsed": 5, "percentRemaining": 95, "resetsAt": "2026-08-24T13:00:00Z", "pace": {"status": "ahead", "projectedExhaustedAt": "2026-08-23T09:00:00Z"}}
      ]
    },
    {
      "provider": "grok",
      "label": "Grok",
      "source": "unavailable",
      "state": {"status": "auth_required", "stale": false},
      "windows": []
    }
  ]
}
JSON
)

# make_snapshot <dir> writes a fake fm-bearings-snapshot.sh that records the
# FM_HOME it was invoked with to <dir>/seen-home, then behaves per FAKE_MODE:
#   json     print $FAKE_JSON verbatim (default)
#   broken   print valid JSON whose .in_flight is a NUMBER, so a section's jq
#            query fails even though `jq -e .` accepts the document
#   empty    print nothing and exit 0
#   fail     exit 1
make_snapshot() {  # <dir>
  local f="$1/fake-snapshot.sh"
  cat > "$f" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_HOME:-UNSET}" > "$SEEN_HOME"
printf '%s\n' "${FM_BEARINGS_SKIP_AFK_GUARD:-0}" > "${SEEN_SKIP:-/dev/null}"
# Simulate the real fm-bearings-snapshot.sh away-return guard: while away mode is
# active (FAKE_AFK=1) an ordinary read is refused with exit 3, unless the
# read-only bypass FM_BEARINGS_SKIP_AFK_GUARD=1 is set.
if [ "${FAKE_AFK:-0}" = 1 ] && [ "${FM_BEARINGS_SKIP_AFK_GUARD:-0}" != 1 ]; then
  exit 3
fi
case "${FAKE_MODE:-json}" in
  json)   printf '%s' "$FAKE_JSON" ;;
  broken) printf '{"decisions_open":[],"in_flight":42,"gates":[],"landed":[]}' ;;
  empty)  : ;;
  fail)   exit 1 ;;
esac
exit 0
SH
  chmod +x "$f"
  printf '%s\n' "$f"
}

# make_quota <dir> writes a fake quota-axi that behaves per FAKE_QUOTA_MODE:
#   json     print $FAKE_QUOTA_JSON verbatim (default)
#   fail     exit 1, as if the tool is absent/unreadable
#   broken   print non-JSON, so the fail-closed parse also degrades to a gap
#   noacc    print valid JSON with an empty providers array (a true empty)
# The file itself is the fixture "state" the read-only test hashes.
make_quota() {  # <dir>
  local f="$1/fake-quota.sh"
  cat > "$f" <<'SH'
#!/usr/bin/env bash
case "${FAKE_QUOTA_MODE:-json}" in
  json)   printf '%s' "${FAKE_QUOTA_JSON:-}" ;;
  fail)   exit 1 ;;
  broken) printf 'this is not json\n' ;;
  noacc)  printf '{"schemaVersion":3,"providers":[]}' ;;
esac
exit 0
SH
  chmod +x "$f"
  printf '%s\n' "$f"
}

# run_desk <home> <out> : render the desk with the fake snapshot and a minimal
# tasks-axi/gh stub set, echoing nothing (assertions read <out>). The quota
# source is always injected via FM_DESK_QUOTA_BIN so every render is hermetic;
# FAKE_QUOTA_MODE/FAKE_QUOTA_JSON select the fixture behavior.
run_desk() {  # <home> <out>
  local home="$1" out="$2" fakebin
  fakebin=$(fm_fakebin "$home")
  # tasks-axi stub: the ticket-band probe must exit 0. It also answers the desk's
  # backlog reads for sections 8 (captain-held) and 9 (four ranked queue lists),
  # emitting tasks-axi's two-space-indented, comma-separated row shape. show --full
  # returns nothing so cards fall back to the id-derived title.
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
# Args carry the query; branch on the flags the desk uses.
args="$*"
case "$args" in
  *"show "*) exit 0 ;;  # full-record read: fall back to snapshot/id
esac
case "$args" in
  *"--state done"*"--limit 1"*) exit 0 ;;  # the collect_tickets probe
esac
case "$args" in
  *"--state held"*)
    # id,state,kind,repo,priority,title,hold_kind
    printf '  held-money-thing,queued,ship,hyfin,1,"rotate a pricing key",captain\n'
    printf '  held-other,queued,task,firstmate,2,"tooling note",captain\n'
    exit 0 ;;
  *"--state queued"*)
    # id,state,kind,repo,priority,title
    printf '  ship-hyfin-a,queued,ship,hyfin,1,"add a pricing column"\n'
    printf '  scout-hyfin-b,queued,scout,hyfin-server,2,"investigate a charge bug"\n'
    printf '  tool-fm-c,queued,ship,firstmate,1,"speed up the watcher"\n'
    printf '  ship-hyfin-d,queued,ship,hyfin,3,"tweak a label"\n'
    exit 0 ;;
  *"--state in_flight"*) exit 0 ;;
  *"--blocked"*) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  # A completion ledger for the progress windows (5, 6) and stats (10). Dates are
  # relative to the injected epoch's calendar day so the windows are deterministic.
  local today yesterday
  today=$(date -d "@${FAKE_EPOCH:-1785225600}" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
  yesterday=$(date -d "@$(( ${FAKE_EPOCH:-1785225600} - 86400 ))" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
  if [ "${FAKE_NO_COMPLETIONS:-0}" != 1 ]; then
    mkdir -p "$home/data"
    {
      printf '# ledger\n'
      printf 'done-a\t%s\tship\thyfin\tabc123\n' "$today"
      printf 'done-b\t%s\tship\tfirstmate\tdef456\n' "$today"
      printf 'done-c\t%s\tscout\thyfin-server\t\n' "$yesterday"
    } > "$home/data/completions.tsv"
  fi
  # A merge-queue row for the ready-to-merge section and the Captain's Call
  # panel's count, only when FAKE_MERGEQ requests it. The desk invokes the real
  # bin/fm-merge-queue.sh by absolute path, so the fixture is the durable queue
  # file itself (data/merge-queue.tsv) rather than a PATH stub.
  if [ "${FAKE_MERGEQ:-0}" = 1 ]; then
    mkdir -p "$home/data"
    printf 'ship-done-a\t%s\tfm/ship-done-a\tabc123def\tmain\thttps://github.com/acme/hyfin/compare/main...fm/ship-done-a\n' "$home" > "$home/data/merge-queue.tsv"
  fi
  # The second-mate registry the per-secondmate panel parses for home + scope,
  # and a real second-mate home with its own two-item open backlog so the panel's
  # queue-depth read has a file to count. FAKE_NO_SECONDMATE_REG=1 omits the
  # registry entirely (registry-absent path); FAKE_SM_REG_UNREADABLE=1 writes it
  # unreadable (registry-unreadable gap path).
  if [ "${FAKE_NO_SECONDMATE_REG:-0}" != 1 ]; then
    mkdir -p "$home/data"
    local ddhome mmhome mthome
    ddhome="$home/sm-decision-desk"
    mmhome="$home/sm-mirror-desk"
    mthome="$home/sm-empty-desk"
    mkdir -p "$ddhome/data" "$mmhome/data" "$mthome/data"
    # decision-desk: two open items + one done, so the open count is exactly 2.
    {
      printf '## Queued\n'
      printf -- '- [ ] q-one - first open item (repo: alpha)\n'
      printf -- '- [ ] q-two - second open item (repo: beta)\n'
      printf '## Done\n'
      printf -- '- [x] d-one - already landed (repo: alpha)\n'
    } > "$ddhome/data/backlog.md"
    # mirror-desk: no backlog file, so its queue depth reads as a gap ("-").
    # empty-desk: a readable backlog with zero open items, so its queue depth is
    # a confident "0" (a read file with no open work), not a gap.
    {
      printf '## Done\n'
      printf -- '- [x] d-only - already landed (repo: alpha)\n'
    } > "$mthome/data/backlog.md"
    {
      printf -- '- decision-desk - rules on schema questions (home: %s; scope: schema rulings; projects: hyfin; added 2026-07-01)\n' "$ddhome"
      printf -- '- mirror-desk - audits the mirror (home: %s; scope: mirror audits; projects: hyfin; added 2026-07-02)\n' "$mmhome"
      printf -- '- empty-desk - drains a quiet queue (home: %s; scope: quiet queue; projects: hyfin; added 2026-07-03)\n' "$mthome"
    } > "$home/data/secondmates.md"
    if [ "${FAKE_SM_REG_UNREADABLE:-0}" = 1 ]; then
      chmod 000 "$home/data/secondmates.md"
    fi
  fi
  local quotabin
  if [ "${FAKE_QUOTA_EXISTING:-0}" = 1 ]; then
    quotabin="$home/fake-quota.sh"
  else
    quotabin=$(make_quota "$home")
  fi
  # Per-pane telemetry fixtures (PR3). FAKE_TELEMETRY, when set, is a set of
  # records separated by ';;', each "id|key=value,key=value,...". The record is
  # written to $home/state/<id>.telemetry as key=value lines - the SAME shape the
  # producer (bin/fm-telemetry-lib.sh) writes, so the desk reads the real format.
  # A record "id|@unparseable" writes a file with a line carrying no key= so the
  # unparseable-record path is exercised; a live pane with NO record here leaves
  # the file absent (the absent-telemetry gap path). The desk resolves STATE as
  # $home/state, so the fixtures land exactly where the builder reads them.
  if [ -n "${FAKE_TELEMETRY:-}" ]; then
    mkdir -p "$home/state"
    local rec rid rbody
    printf '%s\n' "$FAKE_TELEMETRY" | tr ';;' '\n' | while IFS= read -r rec; do
      [ -n "$rec" ] || continue
      rid="${rec%%|*}"
      rbody="${rec#*|}"
      [ -n "$rid" ] || continue
      if [ "$rbody" = "@unparseable" ]; then
        printf 'this line has no key equals sign\n' > "$home/state/$rid.telemetry"
      else
        printf '%s\n' "$rbody" | tr ',' '\n' > "$home/state/$rid.telemetry"
      fi
    done
  fi
  PATH="$fakebin:$PATH" \
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_DESK_SNAPSHOT_BIN="$SNAP" SEEN_HOME="$home/seen-home" \
  SEEN_SKIP="$home/seen-skip" \
  FM_DESK_CI_BUDGET=0 \
  FM_DESK_NOW_EPOCH="${FAKE_EPOCH:-1785225600}" \
  FM_DESK_OUT="$out" FM_DESK_NOW='2026-07-28 09:00' \
  FM_DESK_QUOTA_BIN="$quotabin" \
  FM_DESK_TELEMETRY_MAX_AGE="${FAKE_TELEMETRY_MAX_AGE:-}" \
  FAKE_QUOTA_MODE="${FAKE_QUOTA_MODE:-json}" FAKE_QUOTA_JSON="${FAKE_QUOTA_JSON:-$QUOTA_FIXTURE}" \
    bash "$DESK"
}

# --- populated: real data renders, and the object-valued field does not blank
#     the section ---------------------------------------------------------------
HOME1="$TMP_ROOT/home1"; mkdir -p "$HOME1"
SNAP=$(make_snapshot "$HOME1")
OUT1="$HOME1/desk.html"
FAKE_MODE=json FAKE_JSON="$POPULATED" run_desk "$HOME1" "$OUT1"

# Record ids are rendered as human titles: "decide-alpha" -> "Decide alpha".
assert_grep 'Decide alpha' "$OUT1" 'populated: first open decision reaches the page'
assert_grep 'Decide pay rename' "$OUT1" 'populated: second open decision reaches the page'
assert_grep 'Ship one' "$OUT1" 'populated: an in-flight row reaches the page'
assert_grep 'Ship two' "$OUT1" 'populated: the object-valued row still renders (scalarize)'
assert_no_grep 'No slots are occupied' "$OUT1" 'populated: slots section is not confident-empty'
assert_no_grep 'Nothing is waiting on you' "$OUT1" 'populated: decisions section is not confident-empty'

# The sticky KPI strip and its jump links to sections 11 and 12 exist.
assert_grep 'sticky top-0' "$OUT1" 'sticky strip: the pinned KPI strip is present'
assert_grep 'href="#sec-questions"' "$OUT1" 'sticky strip: jump link to section 11'
assert_grep 'href="#sec-conversation"' "$OUT1" 'sticky strip: jump link to section 12'

# All twelve spec sections render in order.
for n in \
  '1. Decisions needed' '2. Blockers and failures' '3. Ready to merge' \
  '4. Slots and host' '5. Progress - last 3 hours' '6. Progress - last 12 hours' \
  '7. Most important upcoming progress' '8. Captain-held tickets' \
  '9. Next queue tickets' '10. Stats' '11. Recent questions' '12. Recent conversation'; do
  assert_grep "$n" "$OUT1" "section present: $n"
done

# Section 2 draws the blocked in-flight row and a fleet-health line.
assert_grep 'Ship stuck' "$OUT1" 'blockers: the blocked in-flight row reaches section 2'
assert_grep 'Monitoring' "$OUT1" 'blockers: a fleet-health line is shown'

# Section 4 lists crew only now (second mates have their own panel).
assert_grep 'Ship one' "$OUT1" 'slots: an in-flight crew row reaches section 4'

# The dedicated per-secondmate panel lists BOTH second mates, marks the idle one
# idle, and carries the registry-derived scope + this-home queue depth.
assert_grep 'id="sec-secondmates"' "$OUT1" 'secondmates: the dedicated panel renders'
assert_grep 'Decision desk' "$OUT1" 'secondmates: a working second mate is listed'
assert_grep 'Mirror desk' "$OUT1" 'secondmates: an idle second mate is listed'
assert_grep 'second mate' "$OUT1" 'secondmates: second mates are labeled'
# Idle is marked idle (state no_active_work -> "idle").
assert_grep 'idle' "$OUT1" 'secondmates: an idle second mate is marked idle'
# Scope one-liner parsed out of the fixture registry reaches the panel.
assert_grep 'schema rulings' "$OUT1" 'secondmates: registry scope reaches the panel'
assert_grep 'mirror audits' "$OUT1" 'secondmates: second registry scope reaches the panel'
# Queue depth: the fixture decision-desk home has a two-item open backlog.
assert_grep '<td class="text-sm align-top">2</td>' "$OUT1" 'secondmates: queue depth from the home backlog reaches the panel'
# A readable backlog with zero open items is a confident "0", not a gap "-".
assert_grep '<td class="text-sm align-top">0</td>' "$OUT1" 'secondmates: a readable empty backlog renders a confident 0'
# The panel must not fold back into the slots section.
assert_no_grep 'No second mates are standing' "$OUT1" 'secondmates: panel is not confident-empty when populated'

# Sections 5 and 6 render throughput from the completion ledger.
assert_grep '5. Progress - last 3 hours' "$OUT1" 'progress: 3h heading present'
assert_grep 'landed.' "$OUT1" 'progress: a landed count is shown'

# Section 8 shows the captain-held list, money item flagged.
assert_grep 'Held money thing' "$OUT1" 'captain-held: a captain hold is listed'

# Section 9 renders the four ranked cards.
assert_grep 'Top product ship' "$OUT1" 'queue: product-ship card present'
assert_grep 'Top product scout' "$OUT1" 'queue: product-scout card present'
assert_grep 'Top tooling' "$OUT1" 'queue: tooling card present'
assert_grep 'Quick and cheap wins' "$OUT1" 'queue: quick-wins card present'

# Sections 11 and 12 render as marked gaps naming the missing transcript source.
assert_grep 'no local transcript source' "$OUT1" '11/12: the transcript gap note is shown'

# NEVER WAKES holds: the builder must not reference any wake/steer/status-write path.
assert_no_grep 'fm_wake_append' "$OUT1" 'never wakes: no wake call leaked into output'

# Both open decisions must appear (acceptance: captain holds reach the page).
# The count is scoped to section 1 because the Captain's Call panel earlier on
# the page also carries a "your call" badge per decision; a page-wide count
# would double-count the badges, not the cards.
n_dec=$(awk 'BEGIN{ins=0;n=0} /id="sec-decisions"/{ins=1} ins && /your call/{n++} ins && /<\/section>/{print n; exit}' "$OUT1")
if [ "$n_dec" -eq 3 ]; then
  pass 'populated: all open decisions rendered in section 1'
else
  fail "populated: expected 3 decision cards in section 1, got $n_dec"
fi

# --- Captain's Call panel ----------------------------------------------------
# The bearings-vocabulary panel renders the open decisions in the projection's
# blocking-first order (decide-alpha is the blocking one in the fixture) plus the
# merge-queue count, and joins the sticky nav.
assert_grep 'id="sec-captains-call"' "$OUT1" 'captains-call: the panel renders'
assert_grep "Captain's Call" "$OUT1" 'captains-call: the panel uses the bearings heading'
assert_grep 'href="#sec-captains-call"' "$OUT1" 'captains-call: the sticky nav carries the jump link'
assert_grep 'badge-error badge-xs">blocking' "$OUT1" 'captains-call: the blocking decision is flagged'
# Only the blocking decision carries the blocking badge.
n_block=$(grep -c 'badge-error badge-xs">blocking' "$OUT1")
if [ "$n_block" -eq 1 ]; then
  pass 'captains-call: exactly one decision is flagged blocking'
else
  fail "captains-call: expected 1 blocking badge, got $n_block"
fi
# Blocking-first order is preserved: the blocking decide-alpha row appears ahead
# of the non-blocking decide-pay-rename row (first occurrences are in the panel,
# which precedes section 1).
pos_a=$(grep -n 'Decide alpha' "$OUT1" | head -1 | cut -d: -f1)
pos_b=$(grep -n 'Decide pay rename' "$OUT1" | head -1 | cut -d: -f1)
if [ -n "$pos_a" ] && [ -n "$pos_b" ] && [ "$pos_a" -lt "$pos_b" ]; then
  pass 'captains-call: blocking decision renders ahead of the non-blocking one'
else
  fail "captains-call: ordering wrong (alpha at $pos_a, pay at $pos_b)"
fi
# The panel summary text reaches the page, so a read-only captain sees the same
# one-line framing from the report.
assert_grep 'What needs your word right now' "$OUT1" 'captains-call: the intro line renders'

# Decision descriptions render as expandable <details>, and the reason span must
# NOT carry a line-clamp: a Tailwind line-clamp caps the visible text at two
# lines and vertically CLIPS the rest, hiding part of the reason from the
# captain. The full untruncated reason (summary_full) must reach the page, and
# the clamp plus its "more" expand hint must be gone so nothing is cut off.
assert_grep '<details class="text-sm opacity-80 group">' "$OUT1" 'decisions: descriptions render as expandable <details>'
assert_no_grep 'line-clamp' "$OUT1" 'decisions: reason span carries no line-clamp (would clip the text)'
assert_no_grep 'group-open:hidden' "$OUT1" 'decisions: no "more" expand-hint span (clamp affordance removed)'
assert_grep 'a materially different long-term maintenance burden the captain must judge' "$OUT1" 'decisions: the full untruncated reason reaches the page'

# The desk's resolved home must reach the child snapshot.
seen=$(cat "$HOME1/seen-home" 2>/dev/null || printf '')
if [ "$seen" = "$HOME1" ]; then
  pass 'home export: child snapshot saw the desk FM_HOME'
else
  fail "home export: child saw '$seen', expected '$HOME1'"
fi

# --- broken projection: a failing section query renders a VISIBLE GAP, not a
#     confident empty ------------------------------------------------------------
HOME2="$TMP_ROOT/home2"; mkdir -p "$HOME2"
SNAP=$(make_snapshot "$HOME2")
OUT2="$HOME2/desk.html"
FAKE_MODE=broken run_desk "$HOME2" "$OUT2"

assert_no_grep 'No slots are occupied' "$OUT2" 'broken: slots section must not claim empty'
assert_grep 'could not be read' "$OUT2" 'broken: a visible section gap is shown instead'

# --- absent projection: the global gap banner shows and no dependent section
#     confidently claims empty -----------------------------------------------------
HOME3="$TMP_ROOT/home3"; mkdir -p "$HOME3"
SNAP=$(make_snapshot "$HOME3")
OUT3="$HOME3/desk.html"
FAKE_MODE=fail run_desk "$HOME3" "$OUT3"

assert_grep 'Some of this page is missing' "$OUT3" 'absent: the global gap banner is shown'
assert_no_grep 'No slots are occupied' "$OUT3" 'absent: slots section must not claim empty'
assert_no_grep 'Nothing is waiting on you' "$OUT3" 'absent: decisions section must not claim empty'

# Even with the projection gone, the twelve section headings still render (each
# degrades to a gap independently) and the sticky strip is still present.
assert_grep 'sticky top-0' "$OUT3" 'absent: the sticky strip still renders'
for n in '1. Decisions needed' '4. Slots and host' '9. Next queue tickets' '12. Recent conversation'; do
  assert_grep "$n" "$OUT3" "absent: section heading still present: $n"
done

# The count band is always present, even with the projection gone.
assert_grep 'Ticket count' "$OUT3" 'absent: the required count band is still rendered'

# --- away mode: the read-only desk still renders a FULL fleet, because it passes
#     the read-only away-guard bypass to the snapshot ---------------------------
# Regression: the desk previously rendered an empty "could not be read"/"missing"
# page whenever state/.afk was set, because the bearings away-return guard refused
# the read. The desk is strictly read-only (it displays away status), so it opts
# out of ONLY that refusal.
HOME4="$TMP_ROOT/home4"; mkdir -p "$HOME4"
SNAP=$(make_snapshot "$HOME4")
OUT4="$HOME4/desk.html"
FAKE_MODE=json FAKE_JSON="$POPULATED" FAKE_AFK=1 run_desk "$HOME4" "$OUT4"

assert_grep 'Ship one' "$OUT4" 'away: an in-flight row still reaches the page'
assert_grep 'Decide alpha' "$OUT4" 'away: an open decision still reaches the page'
assert_grep 'Decision desk' "$OUT4" 'away: a second-mate slot still reaches the page'
assert_no_grep 'could not be read' "$OUT4" 'away: no fleet-state gap banner while away'
assert_no_grep 'Some of this page is missing' "$OUT4" 'away: no global gap banner while away'
assert_no_grep 'No slots are occupied' "$OUT4" 'away: slots section is not confident-empty'

# The desk must have passed the read-only bypass to the snapshot.
seen_skip=$(cat "$HOME4/seen-skip" 2>/dev/null || printf '')
if [ "$seen_skip" = "1" ]; then
  pass 'away: desk passed FM_BEARINGS_SKIP_AFK_GUARD=1 to the snapshot'
else
  fail "away: desk did not pass the read-only bypass, snapshot saw '$seen_skip'"
fi

# --- non-away render is byte-unchanged whether or not the bypass would matter --
# The bypass only skips the guard; with away mode off, the output must match a
# render that never set FAKE_AFK at all.
HOME5="$TMP_ROOT/home5"; mkdir -p "$HOME5"
SNAP=$(make_snapshot "$HOME5")
OUT5A="$HOME5/desk-a.html"; OUT5B="$HOME5/desk-b.html"
FAKE_MODE=json FAKE_JSON="$POPULATED" run_desk "$HOME5" "$OUT5A"
FAKE_MODE=json FAKE_JSON="$POPULATED" FAKE_AFK=0 run_desk "$HOME5" "$OUT5B"
if diff -q "$OUT5A" "$OUT5B" >/dev/null 2>&1; then
  pass 'non-away: desk render is byte-unchanged with the bypass in play'
else
  fail 'non-away: desk render differs when the bypass path is exercised'
fi

# --- per-secondmate panel: registry UNREADABLE renders a GAP, not a confident
#     empty, and the rows still render from the snapshot -------------------------
HOME6="$TMP_ROOT/home6"; mkdir -p "$HOME6"
SNAP=$(make_snapshot "$HOME6")
OUT6="$HOME6/desk.html"
FAKE_MODE=json FAKE_JSON="$POPULATED" FAKE_SM_REG_UNREADABLE=1 run_desk "$HOME6" "$OUT6"

assert_grep 'id="sec-secondmates"' "$OUT6" 'sm-unreadable: the panel still renders'
assert_grep 'Decision desk' "$OUT6" 'sm-unreadable: snapshot rows still reach the panel'
assert_grep 'registry could not be read' "$OUT6" 'sm-unreadable: a visible registry gap is shown, not a confident empty'
assert_no_grep 'No second mates are standing' "$OUT6" 'sm-unreadable: panel is not confident-empty'

# --- per-secondmate panel: registry ABSENT still renders rows from the snapshot,
#     with scope shown as "-" and no confident-empty claim ----------------------
HOME7="$TMP_ROOT/home7"; mkdir -p "$HOME7"
SNAP=$(make_snapshot "$HOME7")
OUT7="$HOME7/desk.html"
FAKE_MODE=json FAKE_JSON="$POPULATED" FAKE_NO_SECONDMATE_REG=1 run_desk "$HOME7" "$OUT7"

assert_grep 'Decision desk' "$OUT7" 'sm-absent: snapshot rows still reach the panel'
assert_no_grep 'No second mates are standing' "$OUT7" 'sm-absent: panel is not confident-empty'
# An absent registry is not an unreadable registry: no unreadable-gap line.
assert_no_grep 'registry could not be read' "$OUT7" 'sm-absent: absence is not reported as an unreadable registry'

# --- per-secondmate panel: NO second mates in the snapshot is a confident empty,
#     not a gap ---------------------------------------------------------------
NO_SM=$(printf '%s' "$POPULATED" | jq -c '.secondmates = []')
HOME8="$TMP_ROOT/home8"; mkdir -p "$HOME8"
SNAP=$(make_snapshot "$HOME8")
OUT8="$HOME8/desk.html"
FAKE_MODE=json FAKE_JSON="$NO_SM" run_desk "$HOME8" "$OUT8"
assert_grep 'No second mates are standing' "$OUT8" 'sm-empty: an empty second-mate list is a confident empty'

# --- read-only invariant: building the desk must not mutate the fixture
#     second-mate registry, the second mate's own backlog, or the quota fixture
#     (all byte-unchanged) ----------------------------------------------------
HOME9="$TMP_ROOT/home9"; mkdir -p "$HOME9"
SNAP=$(make_snapshot "$HOME9")
make_quota "$HOME9" >/dev/null   # write the quota fixture ONCE; builds reuse it below
OUT9="$HOME9/desk.html"
FAKE_MODE=json FAKE_JSON="$POPULATED" FAKE_QUOTA_EXISTING=1 run_desk "$HOME9" "$OUT9"
reg_before=$(md5sum "$HOME9/data/secondmates.md" | awk '{print $1}')
bl_before=$(md5sum "$HOME9/sm-decision-desk/data/backlog.md" | awk '{print $1}')
q_before=$(md5sum "$HOME9/fake-quota.sh" | awk '{print $1}')
FAKE_MODE=json FAKE_JSON="$POPULATED" FAKE_QUOTA_EXISTING=1 run_desk "$HOME9" "$OUT9"
reg_after=$(md5sum "$HOME9/data/secondmates.md" | awk '{print $1}')
bl_after=$(md5sum "$HOME9/sm-decision-desk/data/backlog.md" | awk '{print $1}')
q_after=$(md5sum "$HOME9/fake-quota.sh" | awk '{print $1}')
if [ "$reg_before" = "$reg_after" ] && [ "$bl_before" = "$bl_after" ] && [ "$q_before" = "$q_after" ]; then
  pass 'read-only: registry, second-mate backlog, and quota fixture are byte-unchanged after a build'
else
  fail 'read-only: the desk mutated the registry, a second-mate backlog, or the quota fixture'
fi

# --- accounts/quota panel: a populated quota-axi report renders per-account
#     runway bars, the binding-window label, and projected/reset times ---------
HOME11="$TMP_ROOT/home11"; mkdir -p "$HOME11"
SNAP=$(make_snapshot "$HOME11")
OUT11="$HOME11/desk.html"
FAKE_MODE=json FAKE_JSON="$POPULATED" run_desk "$HOME11" "$OUT11"

assert_grep 'id="sec-accounts"' "$OUT11" 'accounts: the panel renders'
assert_grep 'Accounts and quota' "$OUT11" 'accounts: panel heading present'
# Claude's binding window is the session window at 30% runway; the bar and text
# reach the page, and the binding window label is shown.
assert_grep '30% left' "$OUT11" 'accounts: the binding-window runway renders'
assert_grep 'session' "$OUT11" 'accounts: the binding-window label renders'
# A high-runway account renders too.
assert_grep '95% left' "$OUT11" 'accounts: a high-runway account also renders'
# An auth-required account with NO windows renders a dash, never a zero bar.
assert_grep 'needs sign-in' "$OUT11" 'accounts: a no-window account is named needs sign-in'
assert_no_grep 'value="0" max="100"' "$OUT11" 'accounts: no confident-zero runway bar renders anywhere'
# The binding-window projected-exhausted and reset times reach the page in the
# same local conversion the builder uses (fixture Claude session window).
exp_dry=$(date -d '2026-08-20T16:00:00Z' '+%m-%d %H:%M' 2>/dev/null || true)
exp_reset=$(date -d '2026-08-20T18:00:00Z' '+%m-%d %H:%M' 2>/dev/null || true)
if [ -n "$exp_dry" ]; then
  assert_grep "$exp_dry" "$OUT11" 'accounts: projected-exhausted time reaches the panel'
fi
if [ -n "$exp_reset" ]; then
  assert_grep "$exp_reset" "$OUT11" 'accounts: reset time reaches the panel'
fi
# The sticky strip headline shows the lowest runway across accounts: Claude 30%.
assert_grep 'lowest runway:' "$OUT11" 'accounts: the sticky strip carries a runway headline'
assert_grep 'Claude 30%' "$OUT11" 'accounts: the headline names the lowest-runway account'
# The sticky nav carries the jump link to the new panel.
assert_grep 'href="#sec-accounts"' "$OUT11" 'accounts: sticky-nav jump link present'
# The per-pane attribution half is now a real table (PR3), composed under the
# per-account table. With live panes but NO telemetry files here, every pane is a
# visible "no reading" gap row - never a confident zero, never silently missing.
assert_grep 'Per-pane attribution' "$OUT11" 'accounts: the per-pane table renders'
assert_no_grep 'pending the visibility layer' "$OUT11" 'accounts: the old pending-gap placeholder is gone'
assert_grep 'badge badge-warning badge-xs">no reading' "$OUT11" 'accounts: a live pane with no telemetry is a visible gap row'
# The numbered spine stays stable: no existing section heading is renumbered.
assert_grep '1. Decisions needed' "$OUT11" 'accounts: section 1 number unchanged'
assert_grep '4. Slots and host' "$OUT11" 'accounts: section 4 number unchanged'
assert_grep '5. Progress - last 3 hours' "$OUT11" 'accounts: section 5 number unchanged'

# --- accounts/quota panel: an ABSENT or unreadable tool renders a GAP, never a
#     confident-zero runway ---------------------------------------------------
HOME12="$TMP_ROOT/home12"; mkdir -p "$HOME12"
SNAP=$(make_snapshot "$HOME12")
OUT12="$HOME12/desk.html"
FAKE_MODE=json FAKE_JSON="$POPULATED" FAKE_QUOTA_MODE=fail run_desk "$HOME12" "$OUT12"

assert_grep 'id="sec-accounts"' "$OUT12" 'quota-absent: the panel still renders'
assert_grep 'could not be read' "$OUT12" 'quota-absent: a visible gap is shown'
assert_no_grep 'value="0" max="100"' "$OUT12" 'quota-absent: no zero runway bar renders when the tool is absent'
assert_no_grep '% left' "$OUT12" 'quota-absent: no runway percent at all when the tool is absent'
assert_grep 'lowest runway:' "$OUT12" 'quota-absent: the sticky headline is still present'
assert_grep '<strong class="opacity-60">unknown</strong>' "$OUT12" 'quota-absent: the headline is unknown, never a zero'
# The per-pane table is INDEPENDENT of quota-axi (it reads state/<id>.telemetry),
# so it still renders even when the per-account tool is absent.
assert_grep 'Per-pane attribution' "$OUT12" 'quota-absent: the per-pane table is independent of quota-axi'

# --- accounts/quota panel: UNPARSEABLE output also degrades to a gap, not a
#     confident empty ----------------------------------------------------------
HOME13="$TMP_ROOT/home13"; mkdir -p "$HOME13"
SNAP=$(make_snapshot "$HOME13")
OUT13="$HOME13/desk.html"
FAKE_MODE=json FAKE_JSON="$POPULATED" FAKE_QUOTA_MODE=broken run_desk "$HOME13" "$OUT13"

assert_grep 'id="sec-accounts"' "$OUT13" 'quota-broken: the panel still renders'
assert_grep 'could not be read' "$OUT13" 'quota-broken: an unparseable report degrades to a visible gap'
assert_no_grep '% left' "$OUT13" 'quota-broken: no runway percent from an unparseable report'
assert_no_grep 'No account readings' "$OUT13" 'quota-broken: an unparseable report is never a confident empty'

# --- accounts/quota panel: a present tool returning a genuinely EMPTY report is
#     a confident empty, not a gap ---------------------------------------------
HOME14="$TMP_ROOT/home14"; mkdir -p "$HOME14"
SNAP=$(make_snapshot "$HOME14")
OUT14="$HOME14/desk.html"
FAKE_MODE=json FAKE_JSON="$POPULATED" FAKE_QUOTA_MODE=noacc run_desk "$HOME14" "$OUT14"

assert_grep 'id="sec-accounts"' "$OUT14" 'quota-empty: the panel still renders'
assert_grep 'No account readings are available' "$OUT14" 'quota-empty: a real empty report is a confident empty'
assert_no_grep 'could not be read' "$OUT14" 'quota-empty: no gap for a genuine empty report'

# --- Captain's Call panel: the merge-queue count reaches the panel from the
#     durable merge queue, and links to the ready-to-merge section ------------
HOME15="$TMP_ROOT/home15"; mkdir -p "$HOME15"
SNAP=$(make_snapshot "$HOME15")
OUT15="$HOME15/desk.html"
FAKE_MODE=json FAKE_JSON="$POPULATED" FAKE_MERGEQ=1 run_desk "$HOME15" "$OUT15"

assert_grep 'id="sec-captains-call"' "$OUT15" 'captains-call-merge: the panel renders'
assert_grep '1 finished branch is ready to merge' "$OUT15" 'captains-call-merge: the merge-queue count reaches the panel'
assert_grep 'href="#sec-merge"' "$OUT15" 'captains-call-merge: the panel links to the ready-to-merge section'
assert_grep 'Ship done a' "$OUT15" 'captains-call-merge: the ready-to-merge section still lists the branch'

# --- Captain's Call panel: a genuinely EMPTY call list (no decisions, no merge
#     queue) is a confident empty, matching the bearings empty-state prose -----
HOME16="$TMP_ROOT/home16"; mkdir -p "$HOME16"
SNAP=$(make_snapshot "$HOME16")
OUT16="$HOME16/desk.html"
NO_CALLS=$(printf '%s' "$POPULATED" | jq -c '.decisions_open = []')
FAKE_MODE=json FAKE_JSON="$NO_CALLS" run_desk "$HOME16" "$OUT16"

assert_grep 'id="sec-captains-call"' "$OUT16" 'captains-call-empty: the panel renders'
assert_grep 'Nothing needs your action right now' "$OUT16" 'captains-call-empty: an empty call list is a confident empty'
assert_no_grep 'could not be read' "$OUT16" 'captains-call-empty: no gap for a genuine empty call list'

# --- per-pane telemetry (PR3): a POPULATED telemetry record renders a per-pane
#     row with account, runway bar, 429 flag, and a fresh reading -------------
# The three POPULATED in-flight panes are ship-one, ship-two, ship-stuck. Give
# ship-one a full fresh record (account + 72% runway + no 429s), ship-two a
# throttled record (account + 3 x 429 + a composer-stuck flag + low runway), and
# leave ship-stuck with NO telemetry file so its row is a "no reading" gap. The
# read_ts on both records is the injected epoch so they read as fresh.
HOME17="$TMP_ROOT/home17"; mkdir -p "$HOME17"
SNAP=$(make_snapshot "$HOME17")
OUT17="$HOME17/desk.html"
NOWTS=1785225600
TEL17="ship-one|account=team-blue,quota_pct=72,read_ts=${NOWTS};;ship-two|account=team-red,quota_pct=8,count_429=3,last_429_ts=${NOWTS},composer_stuck=true,read_ts=${NOWTS}"
FAKE_MODE=json FAKE_JSON="$POPULATED" FAKE_EPOCH="$NOWTS" FAKE_TELEMETRY="$TEL17" run_desk "$HOME17" "$OUT17"

assert_grep 'Per-pane attribution' "$OUT17" 'telemetry: the per-pane table renders'
assert_grep 'team-blue' "$OUT17" 'telemetry: a fresh record account label reaches the row'
assert_grep 'team-red' "$OUT17" 'telemetry: the second record account label reaches the row'
assert_grep '72% left' "$OUT17" 'telemetry: a numeric runway renders a percent'
assert_grep '8% left' "$OUT17" 'telemetry: the low runway renders too'
# ship-two carries 3 x 429 and a composer-stuck flag; both surface.
assert_grep '3 &times;' "$OUT17" 'telemetry: a 429 count over zero is flagged'
assert_grep 'stuck' "$OUT17" 'telemetry: the composer-stuck flag surfaces'
# A fresh record is NOT marked stale.
assert_no_grep 'stale (' "$OUT17" 'telemetry: a fresh record is not marked stale'
# ship-stuck has NO telemetry file, so its row is a visible no-reading gap.
assert_grep 'badge badge-warning badge-xs">no reading' "$OUT17" 'telemetry: a pane with no telemetry file is a visible gap row'
# No confident-zero runway bar anywhere.
assert_no_grep 'value="0" max="100"' "$OUT17" 'telemetry: no confident-zero runway bar renders'

# --- per-pane telemetry: an ABSENT telemetry file for every live pane is a GAP
#     row per pane, never a confident zero and never silently missing ---------
HOME18="$TMP_ROOT/home18"; mkdir -p "$HOME18"
SNAP=$(make_snapshot "$HOME18")
OUT18="$HOME18/desk.html"
FAKE_MODE=json FAKE_JSON="$POPULATED" run_desk "$HOME18" "$OUT18"
assert_grep 'Per-pane attribution' "$OUT18" 'telemetry-absent: the table still renders'
assert_grep 'badge badge-warning badge-xs">no reading' "$OUT18" 'telemetry-absent: every pane with no file is a visible gap row'
assert_no_grep 'value="0" max="100"' "$OUT18" 'telemetry-absent: no confident-zero runway bar when no telemetry exists'
assert_no_grep 'No worker panes are running' "$OUT18" 'telemetry-absent: live panes are not a confident empty'

# --- per-pane telemetry: an UNPARSEABLE record (a file with no key= line) is a
#     gap row, not a confident zero -------------------------------------------
HOME19="$TMP_ROOT/home19"; mkdir -p "$HOME19"
SNAP=$(make_snapshot "$HOME19")
OUT19="$HOME19/desk.html"
FAKE_MODE=json FAKE_JSON="$POPULATED" FAKE_TELEMETRY="ship-one|@unparseable" run_desk "$HOME19" "$OUT19"
assert_grep 'Per-pane attribution' "$OUT19" 'telemetry-unparseable: the table still renders'
assert_grep 'badge badge-warning badge-xs">no reading' "$OUT19" 'telemetry-unparseable: an unparseable record is a visible gap row'
assert_no_grep 'value="0" max="100"' "$OUT19" 'telemetry-unparseable: no confident-zero runway bar from an unparseable record'

# --- per-pane telemetry: NO live pane at all is a CONFIDENT empty, not a gap --
NO_INFLIGHT=$(printf '%s' "$POPULATED" | jq -c '.in_flight = []')
HOME20="$TMP_ROOT/home20"; mkdir -p "$HOME20"
SNAP=$(make_snapshot "$HOME20")
OUT20="$HOME20/desk.html"
FAKE_MODE=json FAKE_JSON="$NO_INFLIGHT" run_desk "$HOME20" "$OUT20"
assert_grep 'Per-pane attribution' "$OUT20" 'telemetry-nopanes: the table heading still renders'
assert_grep 'No worker panes are running' "$OUT20" 'telemetry-nopanes: no live pane is a confident empty'
assert_no_grep 'badge badge-warning badge-xs">no reading' "$OUT20" 'telemetry-nopanes: a confident empty is not a gap row'

# --- per-pane telemetry: a STALE read_ts is MARKED stale, never shown current -
# The record's read_ts is 2 hours before the injected now; the default staleness
# bound is 1800s, so the row must be flagged stale.
HOME21="$TMP_ROOT/home21"; mkdir -p "$HOME21"
SNAP=$(make_snapshot "$HOME21")
OUT21="$HOME21/desk.html"
STALE_TS=$(( 1785225600 - 7200 ))
FAKE_MODE=json FAKE_JSON="$POPULATED" FAKE_EPOCH=1785225600 \
  FAKE_TELEMETRY="ship-one|account=team-blue,quota_pct=50,read_ts=${STALE_TS}" \
  run_desk "$HOME21" "$OUT21"
assert_grep 'stale (' "$OUT21" 'telemetry-stale: an out-of-date read_ts is marked stale'
assert_grep 'team-blue' "$OUT21" 'telemetry-stale: the stale record still shows its data'

# --- per-pane telemetry: a widened staleness bound makes the SAME record fresh
#     (the seam is honored) -----------------------------------------------------
HOME22="$TMP_ROOT/home22"; mkdir -p "$HOME22"
SNAP=$(make_snapshot "$HOME22")
OUT22="$HOME22/desk.html"
FAKE_MODE=json FAKE_JSON="$POPULATED" FAKE_EPOCH=1785225600 FAKE_TELEMETRY_MAX_AGE=99999 \
  FAKE_TELEMETRY="ship-one|account=team-blue,quota_pct=50,read_ts=${STALE_TS}" \
  run_desk "$HOME22" "$OUT22"
assert_no_grep 'stale (' "$OUT22" 'telemetry-freshbound: a widened bound reads the same record as fresh'

# --- read-only invariant: building the desk must NOT mutate a telemetry file --
# The desk is a strict consumer of state/<id>.telemetry; a build leaves the
# fixture byte-unchanged.
HOME23="$TMP_ROOT/home23"; mkdir -p "$HOME23"
SNAP=$(make_snapshot "$HOME23")
OUT23="$HOME23/desk.html"
FAKE_MODE=json FAKE_JSON="$POPULATED" FAKE_EPOCH=1785225600 \
  FAKE_TELEMETRY="ship-one|account=team-blue,quota_pct=72,read_ts=1785225600" \
  run_desk "$HOME23" "$OUT23"
tel_before=$(md5sum "$HOME23/state/ship-one.telemetry" | awk '{print $1}')
FAKE_MODE=json FAKE_JSON="$POPULATED" FAKE_EPOCH=1785225600 \
  FAKE_TELEMETRY="ship-one|account=team-blue,quota_pct=72,read_ts=1785225600" \
  run_desk "$HOME23" "$OUT23"
tel_after=$(md5sum "$HOME23/state/ship-one.telemetry" | awk '{print $1}')
if [ "$tel_before" = "$tel_after" ]; then
  pass 'read-only: the telemetry fixture is byte-unchanged after a build'
else
  fail 'read-only: the desk mutated a telemetry file'
fi

# --- spine stable: the per-pane table lives INSIDE sec-accounts and adds NO new
#     numbered section, so the twelve-section spine is unchanged ---------------
for n in \
  '1. Decisions needed' '2. Blockers and failures' '3. Ready to merge' \
  '4. Slots and host' '5. Progress - last 3 hours' '6. Progress - last 12 hours' \
  '7. Most important upcoming progress' '8. Captain-held tickets' \
  '9. Next queue tickets' '10. Stats' '11. Recent questions' '12. Recent conversation'; do
  assert_grep "$n" "$OUT17" "spine stable with the per-pane table: $n"
done

echo "all fm-desk-refresh tests passed"
