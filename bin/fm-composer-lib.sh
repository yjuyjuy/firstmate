#!/usr/bin/env bash
# bin/fm-composer-lib.sh - the ONE fleet-wide owner of composer-content
# classification, shared by every session-provider adapter: the tmux path
# through bin/fm-tmux-lib.sh, and bin/backends/{herdr,orca,cmux}.sh directly.
#
# WHY THIS EXISTS (task fm-composer-shellglyph-safety): the four adapters each
# carried their own copy of the "is this composer row empty / pending / not an
# agent composer" decision, and the copies drifted. The dangerous drift: a BARE
# shell prompt glyph (`>`, `$`, `%`, `#`) - what a pane shows once its agent has
# exited to a plain login shell - was treated as an empty, ready-to-inject
# AGENT composer. The away-mode escalation injector (bin/fm-supervise-daemon.sh)
# reads composer-emptiness to decide whether a pane is a safe injection target,
# so a dead-shell pane misread as "empty" meant an escalation could be typed
# into (and, worst case, executed by) that shell. Consolidating the one decision
# here means the safety rule cannot silently drift across adapters again.
#
# THE SAFETY RULE this owner enforces: a bare shell prompt glyph is a genuine
# empty agent composer ONLY when it appears INSIDE a real agent-composer
# container - a bordered composer box, where the harness draws its own prompt
# glyph (e.g. claude's older `| > ... |`). On a bare, unstructured row it is a
# dead-shell prompt and is NEVER "empty"; it classifies as `unknown` (not a safe
# injection target). The AGENT prompt glyphs `❯` (claude) and `›` (codex) are a
# genuine empty agent composer either way, bordered or bare, and so is jcode's
# numbered prompt row (`3> `, `4… `), recognized by fm_composer_jcode_prompt_text
# below: a leading digit run before the prompt glyph is not a shell-prompt shape,
# so recognizing it does not weaken the rule.
#
# GHOST/PLACEHOLDER TEXT is the other half of this owner (task
# afk-herdr-false-pending): a harness fills an otherwise-empty composer with
# de-emphasized ghost text - claude's rotating prompt suggestion, codex's idle
# suggestion, grok's placeholder - which a plain capture cannot tell apart from
# text a human typed, so the away-mode injector reads the idle pane as "pending
# input" and defers every escalation (the overnight wedge that motivated this
# consolidation). fm_composer_strip_ghost is the ONE ANSI-aware extractor of
# "real typed content": it drops every de-emphasized run - dim/faint (SGR 2, how
# claude and codex render ghost text) AND a dark/muted TRUECOLOR foreground (how
# grok renders placeholder/hint text) - and keeps only normal-intensity,
# normally-coloured text. Consolidating it here means the two ANSI-capable
# adapters (tmux via bin/fm-tmux-lib.sh, herdr via bin/backends/herdr.sh) cannot
# drift into per-harness one-off strips again; the previous herdr-only faint
# byte-pattern check missed claude's own dim ghost (its prompt glyph is not
# bold-wrapped) and no adapter covered grok's truecolor placeholder at all.
#
# Each adapter still owns its own CAPTURE and structural row-finding, because
# those use genuinely different primitives (tmux's cursor-row read, herdr's ANSI
# tail scan, orca/cmux's plain read-screen). Once an adapter has a candidate
# composer row it hands the RAW styled row to fm_composer_strip_ghost for the
# real-typed-content extraction, strips the box borders, trims, and hands the
# result plus a <bordered> flag to fm_composer_classify_content for the shared
# empty|pending|unknown verdict. orca/cmux read a plain (unstyled) screen so
# they have no ghost styling to strip and rely on the idle-placeholder match
# below. Re-sourcing is a cheap idempotent redefinition, so this file needs no
# include guard (matching bin/fm-tmux-lib.sh).

# fm_composer_strip_ansi: drop every CSI escape sequence, leaving plain text.
# Used for STRUCTURAL row/shape detection, where ghost text must be KEPT so the
# composer box border or bare prompt glyph is still visible; content extraction
# uses fm_composer_strip_ghost instead. Reads the styled text on stdin and prints
# plain text (stdin-only, matching fm_composer_strip_ghost). The character class
# includes ':' so an ITU colon-form SGR (38:2::r:g:b) is stripped whole, not left
# with a dangling tail.
fm_composer_strip_ansi() {
  local esc; esc=$(printf '\033')
  LC_ALL=C sed "s/${esc}\\[[0-9;:?]*[[:alpha:]]//g"
}

# fm_composer_strip_ghost: the ONE fleet-wide ANSI-aware extractor of "real typed
# content" from a captured, styled composer row. Reads the styled line on stdin
# (from `tmux capture-pane -e` or `herdr pane read --format ansi`) and prints the
# plain, non-ghost text on stdout, dropping:
#   - dim/faint runs (SGR 2): how claude and codex render ghost/suggestion text.
#     A reset (SGR 0) or normal-intensity (SGR 22) ends a dim run.
#   - dark/muted TRUECOLOR foreground runs (SGR 38;2;r;g;b or the colon form
#     38:2::r:g:b) whose perceived luminance (0.299R + 0.587G + 0.114B) is below
#     FM_COMPOSER_GHOST_LUMA_MAX (default 128): how grok renders its placeholder
#     and hint text. A reset (SGR 0), a default-foreground (SGR 39), any base
#     foreground colour (30-37 / 90-97), or a lighter 38;2 foreground ends the
#     dark-foreground run. This assumes a DARK terminal theme, the firstmate
#     fleet reality, where real typed input is bright and only de-emphasised UI
#     is dark; the SGR-2 signal above stays theme-independent. A 256-colour
#     foreground (38;5;n) is NOT luminance-tested - it is palette-dependent and
#     no fleet harness uses it for ghost text, so it is kept (real text wins:
#     under-stripping merely defers, which the max-defer alarm surfaces, while
#     over-stripping would inject over real input).
# The dim/faint and dark-foreground states are tracked together as "de-emphasis";
# codes are processed left to right within a sequence, so "ESC[0;2m" reads as dim.
# LC_ALL=C makes awk walk bytes, so multibyte glyphs (e.g. ❯) and de-emphasised
# runs alike pass through or drop intact without locale-dependent classes.
fm_composer_strip_ghost() {
  LC_ALL=C awk -v lumamax="${FM_COMPOSER_GHOST_LUMA_MAX:-128}" '
    function sgr_code(v, b) {
      b = v
      sub(/:.*/, "", b)
      if (b == "") b = "0"
      return b
    }
    function skip_color_payload(a, p, k, mode, code) {
      if (index(a[p], ":") > 0) return p
      if (p >= k) return p
      mode = a[p + 1]
      code = sgr_code(mode)
      if (index(mode, ":") > 0) return p + 1
      if (code == "5") return p + 2
      if (code == "2") return p + 4
      return p + 1
    }
    # fg38_is_dark: 1 when the SGR 38 foreground starting at param p is a
    # TRUECOLOR (38;2 / 38:2) whose luminance is below lumamax; 0 otherwise
    # (a 38;5 palette colour, a bright truecolor, or a malformed run).
    function fg38_is_dark(a, p, k, lumamax,   spec, nf, f, r, g, b) {
      spec = a[p]
      if (index(spec, ":") > 0) {           # colon form: whole colour in a[p]
        nf = split(spec, f, ":")
        if (f[2] != "2" || nf < 5) return 0
        r = f[nf - 2] + 0; g = f[nf - 1] + 0; b = f[nf] + 0
        return ((299*r + 587*g + 114*b) / 1000 < lumamax) ? 1 : 0
      }
      if (p + 1 > k || a[p + 1] != "2" || p + 4 > k) return 0
      r = a[p + 2] + 0; g = a[p + 3] + 0; b = a[p + 4] + 0
      return ((299*r + 587*g + 114*b) / 1000 < lumamax) ? 1 : 0
    }
    {
      line = $0; out = ""; dim = 0; darkfg = 0; n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (c == "\033") {            # ESC: consume a CSI ... final-byte sequence
          j = i + 1
          if (substr(line, j, 1) == "[") {
            j++; params = ""
            while (j <= n) {
              cc = substr(line, j, 1)
              if (cc ~ /[@-~]/) break
              params = params cc; j++
            }
            if (j <= n && substr(line, j, 1) == "m") {   # SGR: update de-emphasis
              if (params == "") params = "0"
              k = split(params, a, ";")
              for (p = 1; p <= k; p++) {
                v = a[p]; code = sgr_code(v)
                if (code == "38") {
                  darkfg = fg38_is_dark(a, p, k, lumamax)
                  p = skip_color_payload(a, p, k)
                } else if (code == "48" || code == "58") {
                  p = skip_color_payload(a, p, k)
                } else if (code == "2") dim = 1
                else if (code == "0") { dim = 0; darkfg = 0 }
                else if (code == "22") dim = 0
                else if (code == "39") darkfg = 0
                else if (code + 0 >= 30 && code + 0 <= 37) darkfg = 0
                else if (code + 0 >= 90 && code + 0 <= 97) darkfg = 0
              }
            }
            if (j <= n) { i = j + 1; continue }
          }
          i = i + 1; continue          # lone/other ESC: drop the ESC byte only
        }
        if (dim == 0 && darkfg == 0) out = out c   # keep only non-de-emphasised bytes
        i++
      }
      print out
    }
  '
}

# fm_composer_jcode_prompt_text: recognize jcode's NUMBERED composer prompt row
# and print the real typed text it holds.
#
# jcode (verified 2026-07-30, jcode server 0.64.2) draws neither a composer box
# nor one of the agent prompt glyphs the cases below already know. Its composer
# row is a turn counter followed by a state glyph, then the typed text, then a
# right-aligned status glyph at the far edge of the pane:
#
#   idle, nothing typed:  "3>                                        ⏳"
#   idle, text typed:     "3> hello world                            ⏳"
#   mid-turn (busy):      "4…                                        ⏳"
#   idle, skill active:   "22»                                       ⏳"
#
# The state glyph is chosen by jcode's own app state, NOT by pane focus - the
# single source of truth is jcode-tui's input_prompt() (crates/jcode-tui/src/tui/
# ui_input.rs), which returns one of exactly four prompt prefixes:
#   "$ " shell mode; "… " while processing (busy); "» " (U+00BB) when a SKILL is
#   active and idle; "> " otherwise (plain idle). The away-mode supervisor pane
#   (firstmate itself) runs with a skill active, so its EMPTY, idle composer draws
#   "NN» " rather than "NN> ". Both ">" and "»" are genuine idle agent-composer
#   prompts, so both must reduce to the same "empty when nothing is typed"
#   verdict. Verified 2026-08-05 (jcode server 0d5cd9f-dirty, herdr 0.7.x): an
#   idle skill-active supervisor pane rendered "22»  ⏳" and read `pending`, the
#   false-pending shape that wedged away-mode injection for 3+ hours (three missed
#   wakes on 2026-08-04/05, see data/learnings.md).
#
# Every run is bright truecolor, so nothing is de-emphasised and the shared ghost
# stripper keeps the whole row: without this recognizer an IDLE jcode pane reads
# as `pending` (verified: fm_tmux_composer_state printed `pending` on an idle
# probe pane), which is the false-pending shape that wedges away-mode injection
# and turns every delivered submit into a false "Enter swallowed".
#
# The row is accepted as a genuine agent composer because a leading DIGIT run
# before the prompt glyph is not a shell-prompt shape, so this cannot relax the
# bare-shell-glyph safety rule above. The right-aligned status glyph is dropped
# structurally rather than by matching ⏳ itself: the indicator is separated from
# any typed text by the run of padding spaces that right-aligns it, so the text
# is whatever precedes the first run of two or more spaces. That keeps the
# recognizer working whatever indicator jcode right-aligns next, and it keeps
# real typed text `pending` because typed text always starts immediately after
# the prompt glyph.
#
# Returns 0 and prints the trimmed typed text (empty when nothing is typed) for
# a jcode composer row; returns 1 for any other row, leaving the caller's
# existing classification untouched. Bash 3.2 safe: literal prefix/suffix
# substitution only, no multibyte character classes.
#
# GLYPH-AGNOSTIC EMPTY BACKSTOP (fix 2, task fix-daemon-composer-defer-wedge):
# the known-glyph list above (> … ») tracks jcode's current input_prompt()
# states, but a FUTURE jcode build could add or rename a prompt glyph, and the
# wedge this task fixes was precisely a new glyph ("»") the list did not know.
# So the `*)` default no longer refuses every unknown glyph outright: an EMPTY
# composer of jcode's shape must read empty regardless of its specific glyph, or
# the same 3-hour silent-swallow wedge returns the next time the glyph changes.
# The backstop reads empty ONLY when the row carries jcode's right-aligned status
# indicator (U+23F3 ⏳) - which proves it is a composer row, not a transcript or
# footer row (those end in "•", a rate string, "https", a percent) - AND the
# content before the right-aligned padding is a lone glyph (no letters, digits,
# or spaces = nothing was typed). A row with real typed text fails the lone-glyph
# test and stays unmatched, the safe direction: the daemon defers and the
# max-defer alarm still fires rather than an escalation being typed into an
# unrecognized target. A digit-PREFIXED glyph is always jcode's own numbered
# agent composer (never a bare dead shell), so this cannot relax the
# bare-shell-glyph safety rule above.
fm_composer_jcode_prompt_text() {  # <trimmed-row-content> -> typed text on stdout
  local s=$1 digits rest ind head
  digits=${s%%[!0-9]*}
  [ -n "$digits" ] || return 1
  rest=${s#"$digits"}
  case "$rest" in
    '>'*) rest=${rest#>} ;;
    '…'*) rest=${rest#…} ;;
    '»'*) rest=${rest#»} ;;
    *)
      # Unknown/future prompt glyph: accept ONLY the empty-composer shape.
      ind=$(printf '\342\217\263')  # U+23F3 HOURGLASS WITH FLOWING SAND
      case "$s" in
        *"$ind") ;;
        *) return 1 ;;               # no jcode composer indicator -> not a composer
      esac
      head=${rest%%"  "*}            # content before the right-aligned padding
      head="${head#"${head%%[![:space:]]*}"}"
      head="${head%"${head##*[![:space:]]}"}"
      # A lone glyph (one codepoint, 1-4 bytes) with no typed content is an empty
      # composer; anything with letters, digits, spaces, or more than one glyph is
      # real content and must NOT read empty here.
      case "$head" in
        ''|*[A-Za-z0-9]*|*' '*) return 1 ;;
      esac
      [ "${#head}" -le 4 ] || return 1
      printf ''
      return 0
      ;;
  esac
  # Drop the right-aligned status indicator: everything from the first run of
  # two or more spaces onward.
  rest=${rest%%"  "*}
  rest="${rest#"${rest%%[![:space:]]*}"}"
  rest="${rest%"${rest##*[![:space:]]}"}"
  printf '%s' "$rest"
}

# fm_composer_jcode_wrapped_tail: recognize the BOTTOM row of a jcode composer
# whose typed text has grown tall enough that the leading "NNN>"/"NNN…" prompt
# row has scrolled OFF the top of the visible pane, and print the real typed
# text that bottom row still carries.
#
# WHY THIS EXISTS (task fix-afk-daemon-jcode-submit-verification, verified
# 2026-08-01, jcode server 0.64.2): jcode renders its composer INLINE and grows
# it downward one wrapped row at a time - it does not cap the composer height or
# scroll only the composer. So a long single-line message (the away-mode
# daemon's batched escalation digest is ~13k characters on one line, ~330
# wrapped rows in jcode's ~40-column composer) pushes the "NNN>" prompt row far
# above the visible viewport. The tmux adapter reads the exact cursor row
# (#{cursor_y}) so it is immune, but the herdr adapter has no cursor primitive
# and scans a bounded tail window (FM_BACKEND_HERDR_COMPOSER_LINES): when only
# wrapped CONTINUATION rows are in that window, fm_composer_jcode_prompt_text
# matches nothing and the composer reads `unknown`. The away daemon then aborts
# its submit-confirm on that `unknown` (verdict=unknown, "submit unconfirmed"),
# never clears state/.subsuper-escalations, writes .subsuper-inject-wedged, and
# re-fires the identical batch every tick even though the captain DID receive it
# - a large recurring token drain.
#
# The reliable structural anchor is jcode's right-aligned STATUS INDICATOR
# (U+23F3 ⏳): jcode draws it at the far edge of the composer's LAST visible row
# ONLY (idle "NNN>  ⏳", busy "NNN…  ⏳", and the wrapped tail "<text tail>  ⏳"),
# never on a transcript or footer row (those end in "•", a rate string, "https",
# a percent, etc.). A wrapped tail is therefore a row that (a) ends with that
# indicator, right-aligned behind at least one padding space, (b) is NOT itself a
# "NNN>"/"NNN…" prompt row (those are the idle/empty case, owned by
# fm_composer_jcode_prompt_text), and (c) carries real content before the
# padding. Such a row can only exist when unsubmitted text has wrapped, so it is
# genuine pending input - reading it as pending (not unknown) lets the daemon's
# submit-confirm retry its Enter until the composer clears back to the idle
# "NNN>" row, which fm_composer_jcode_prompt_text already reads as empty. It
# never reads as empty here (the recognizer requires content), so a wrapped
# composer with real text can never be mistaken for a delivered/cleared submit.
#
# The indicator is matched by its exact bytes here (unlike
# fm_composer_jcode_prompt_text, which drops it structurally by the padding run):
# the byte match is what makes a wrapped continuation row distinguishable from an
# arbitrary transcript row at all. A future indicator-glyph change degrades this
# to the pre-fix behaviour (unknown, the safe direction: the daemon retries and
# never falsely confirms), never to a false injection target.
#
# Returns 0 and prints the trimmed typed text for a jcode wrapped-composer tail
# row; returns 1 for any other row (including a bare "NNN>"/"NNN…" prompt row and
# an indicator-only row with no content). Bash 3.2 safe: literal byte
# prefix/suffix substitution only, no multibyte character classes.
fm_composer_jcode_wrapped_tail() {  # <trimmed-row-content> -> typed text on stdout
  local s=$1 ind
  # A bare "NNN>"/"NNN…" prompt row is the idle/empty case owned above, never a
  # wrapped tail, so reject it here even though it also ends with the indicator.
  fm_composer_jcode_prompt_text "$s" >/dev/null 2>&1 && return 1
  ind=$(printf '\342\217\263')  # U+23F3 HOURGLASS WITH FLOWING SAND
  s="${s%"${s##*[![:space:]]}"}"   # trim trailing whitespace
  case "$s" in
    *"$ind") ;;
    *) return 1 ;;
  esac
  s=${s%"$ind"}                    # drop the trailing indicator glyph
  # The indicator is RIGHT-ALIGNED: it must sit behind padding, not glued to the
  # text, so a transcript row that merely happens to end in the glyph is rejected.
  case "$s" in
    *' ') ;;
    *) return 1 ;;
  esac
  s="${s%"${s##*[![:space:]]}"}"   # trim the right-align padding
  s="${s#"${s%%[![:space:]]*}"}"   # trim leading whitespace
  [ -n "$s" ] || return 1
  printf '%s' "$s"
}

# fm_composer_classify_content: the single shared composer-content verdict.
#   <bordered> 1 when <content> came from a genuine agent-composer container (a
#              bordered composer box, or a structurally-identified bare AGENT
#              prompt row); 0 for a bare, unstructured row (e.g. tmux's raw
#              cursor line that carried no box border).
#   <content>  the candidate composer content, already border-stripped and
#              whitespace-trimmed by the caller.
#   [idle_re]  optional per-harness idle-placeholder regex (e.g. grok's
#              "Type a message...") that reads as empty; matched both before and
#              after a leading prompt glyph is stripped, so a pattern written
#              with or without the glyph both land.
# fm_composer_normalize_ws: fold the non-breaking-space class that a harness uses
# as prompt padding into a regular ASCII space, so the shared [:space:] trimming
# and the bare-glyph empty-composer cases below match. claude 2.1.220 draws its
# empty composer prompt as "❯" followed by a U+00A0 NO-BREAK SPACE, not an ASCII
# space, and every adapter trims with an ASCII-only [:space:] class that leaves
# the NBSP attached; the stripped content is then "❯ ", which misses the
# bare "❯" empty case and classifies an EMPTY claude composer as `pending`. On an
# idle pane that turned the just-delivered submit's cleared-composer check into a
# false "Enter swallowed" report (evidence: docs/tmux-backend.md). U+202F NARROW
# NO-BREAK SPACE is folded too, the other non-breaking pad a TUI is likely to
# use. Byte-literal substitution keeps it bash 3.2 and locale independent.
fm_composer_normalize_ws() {  # <string> -> string with the NBSP class folded to ' '
  local s=$1 nbsp nnbsp
  nbsp=$(printf '\302\240')
  nnbsp=$(printf '\342\200\257')
  s=${s//"$nbsp"/ }
  s=${s//"$nnbsp"/ }
  printf '%s' "$s"
}

fm_composer_idle_matches() {
  local content=$1 idle_re=$2 idle_case=$3
  [ -n "$idle_re" ] || return 1
  case "$idle_case" in
    insensitive) printf '%s' "$content" | grep -qiE "$idle_re" ;;
    *) printf '%s' "$content" | grep -qE "$idle_re" ;;
  esac
}

fm_composer_classify_content() {  # <bordered> <content> [idle_re] [idle_case] [plain_content]
  local bordered=$1 content=$2 idle_re=${3:-} idle_case=${4:-sensitive} plain_content jcode_text
  plain_content=${5:-$content}
  # Fold the NBSP prompt-padding class the callers' ASCII [:space:] trim missed,
  # then re-trim, so a claude "❯ " empty composer reaches the bare-glyph
  # cases as a clean "❯" instead of misclassifying as pending.
  content=$(fm_composer_normalize_ws "$content")
  content="${content#"${content%%[![:space:]]*}"}"
  content="${content%"${content##*[![:space:]]}"}"
  plain_content=$(fm_composer_normalize_ws "$plain_content")
  plain_content="${plain_content#"${plain_content%%[![:space:]]*}"}"
  plain_content="${plain_content%"${plain_content##*[![:space:]]}"}"
  # jcode's numbered prompt row is a genuine agent composer, so reduce it to the
  # text actually typed into it and treat it as a composer container from here on
  # (see fm_composer_jcode_prompt_text). An idle jcode row then reaches the
  # nothing-on-the-row case as empty instead of reading as pending input.
  if jcode_text=$(fm_composer_jcode_prompt_text "$content"); then
    bordered=1
    content=$jcode_text
  fi
  if [ "$bordered" != 1 ] && [ -z "$content" ] && [ -n "$plain_content" ]; then
    case "$plain_content" in
      '❯'|'›') printf 'empty'; return 0 ;;
      *) printf 'unknown'; return 0 ;;
    esac
  fi
  # A bare prompt glyph on its own row.
  case "$content" in
    '❯'|'›')
      # Agent prompt glyph: a genuine empty agent composer, bordered or bare.
      printf 'empty'; return 0 ;;
    '>'|'$'|'%'|'#')
      # Shell prompt glyph: empty ONLY inside a composer box (the harness's own
      # prompt). Bare, it is a dead-shell prompt - never a safe injection target.
      if [ "$bordered" = 1 ]; then printf 'empty'; else printf 'unknown'; fi
      return 0 ;;
  esac
  # Nothing on the row = empty composer.
  [ -n "$content" ] || { printf 'empty'; return 0; }
  # Known idle placeholder (matched before a leading glyph is stripped).
  if fm_composer_idle_matches "$content" "$idle_re" "$idle_case"; then
    printf 'empty'; return 0
  fi
  # Strip a leading prompt glyph, then re-judge the remainder. Remove the exact
  # matched glyph literally rather than with `?`/`??`: `?` matches a single BYTE
  # under a C/POSIX locale, so a `${content#??}` on the 3-byte "❯ " would leave a
  # mangled glyph tail and misread a known idle placeholder ("❯ Type a message...")
  # as pending. Literal removal is locale independent.
  case "$content" in
    '❯ '*) content=${content#'❯ '} ;;
    '› '*) content=${content#'› '} ;;
    '> '*) content=${content#'> '} ;;
    '$ '*) content=${content#'$ '} ;;
    '% '*) content=${content#'% '} ;;
    '# '*) content=${content#'# '} ;;
    '❯'*) content=${content#'❯'} ;;
    '›'*) content=${content#'›'} ;;
    '>'*) content=${content#'>'} ;;
    '$'*) content=${content#'$'} ;;
    '%'*) content=${content#'%'} ;;
    '#'*) content=${content#'#'} ;;
  esac
  content="${content#"${content%%[![:space:]]*}"}"
  content="${content%"${content##*[![:space:]]}"}"
  [ -n "$content" ] || { printf 'empty'; return 0; }
  # Known idle placeholder (matched again after the leading glyph was stripped,
  # e.g. "❯ Type a message...").
  if fm_composer_idle_matches "$content" "$idle_re" "$idle_case"; then
    printf 'empty'; return 0
  fi
  # Real, unsubmitted content remains.
  printf 'pending'; return 0
}
