# Replace the HTML captain's desk with the captain-run dashboard TUI (fm-dashboard.sh)

The captain's desk was an event-refreshed HTML page (`fm-desk-refresh.sh` + `fm-desk-event.sh`), chosen originally over a standing agent so fleet status cost no resident process.
We decided (2026-08-31) to replace it with `bin/fm-dashboard.sh`, a terminal TUI the captain runs on demand: an fzf-driven, fleet-wide view of the backlog and of captain decisions, with snapshot-at-launch freshness and a manual refresh key.
The captain accepts losing browser/LAN glanceability once retirement lands, but retirement is STAGED: the HTML desk stays alive and event-refreshed until the captain has used the dashboard and explicitly confirms it works better, and only then are the desk renderers retired (in one change with the transcript rename).

## Constraints carried forward

- Read-only over fleet state, and reads flow ONLY through existing owners (`tasks-axi`, `fm-bearings-snapshot.sh`, ledger scripts) - never by parsing `backlog.md` or other owned formats directly (the single-parser rule).
- Fleet-wide reads resolve secondmate homes from `data/secondmates.md` and stay read-only over other homes.
- No standing process, no polling: snapshot at launch plus a refresh keybind, mirroring the original no-poll decision.
- "Captain decision" is the glossary term (see CONTEXT.md): the panel merges captain-kind holds, decision-desk requests, and unanswered transcript questions, each row tagged with home and source.
- Captain messages about an item route to the PRIMARY firstmate only (phase 1: OSC 52 clipboard handoff of `re <item-key> [<home>]: <text>`, captain pastes manually - OSC 52 passthrough verified working through herdr + the captain's terminal on 2026-08-31; phase 2: durable wake-queue append, selected by `config/dashboard-send-mode` = `clipboard` | `wake-queue`). Non-backlog rows compose keys too: `re desk/<subject> [<home>]: ...` for decision-desk requests, `re question "<question head>" [<home>]: ...` for transcript questions. The TUI never writes into a secondmate home's state.
- The captain runs herdr, not tmux, so there is no tmux-buffer fallback; OSC 52 through herdr to the captain's terminal was tested and works.
- "Dashboard" supersedes "desk" as the captain-facing term; a single status footer line (rendered in every panel's fzf header) carries merge-queue depth and watcher-liveness/resource level.
- Panels are fzf modes cycled by keybind, one list at a time; message composition is an inline `read -e` prompt (single line, matching the clipboard payload); recent completions shows the last 20 ledger entries; the transcript feed and its producer survive the desk retirement (renamed transcript, contract unchanged) as the dashboard's question source and phase-2 echo target; launch is manual `bin/fm-dashboard.sh` in any shell pane, no herdr registration, no firstmate skill.

## Considered options

- Keep both renders permanently (TUI sibling + HTML page): rejected to avoid two drifting "truths" and dead-code rot. The overlap window is deliberate and bounded: it ends when the captain confirms the dashboard is the better tool.
- fzf as the TUI engine over pure bash/tput or gum: one static binary buys list + fuzzy filter + preview-pane expand, which is exactly the collapsed-row/expandable-description requirement.
