# bench

A talk-driven agent workbench: spawn, monitor, and land work from parallel
Claude Code worker sessions, with live diff visibility and mouse/arrow-key
navigation. `bench` is a thin convention layer over **tmux + git** — a small
bash CLI plus an orchestrator skill that teaches the verbs.

**No hooks, no MCP, no daemons.** Everything the orchestrator does goes through
`bench <verb>` (plain, auditable, allowlist-friendly). Work state lives in plain
files; code truth lives in git. It runs identically in a standalone terminal and
the VS Code integrated terminal — it's just tmux; attach from either.

## The two layers (never mixed)

| Layer | Truth for | Lives at | Browsed with |
|---|---|---|---|
| **Work state** | tasks, status, assignments, feedback | `~/.bench/<project>/` (outside the repo) | `bench status`, `cat`/`glow` |
| **Code** | what the code is | repo + one git worktree per task | diffpane (live), lazygit (review/merge) |

State outside the repo keeps it from forking across worker branches and
polluting feature diffs. The state dir is itself a git repo (`git init` at
`bench init`); the CLI auto-commits on every state change, so you get a full
audit trail for free. One task = one file (`tasks/T-042.md`) with flat
`key: value` frontmatter — greppable, no yq/jq. Nobody hand-edits it: all writes
go through `bench task set`, which is atomic (temp file + `mv`).

## Quickstart

```sh
bench init                       # create + git-init the state dir, write allowlist
bench up                         # create-or-repair the tmux session (idempotent)
bench task new "Add drain handler" --files 'src/drain/**'
bench spawn T-001                # worktree + branch + claude worker; status → working
bench status                     # read all task files + git log; see who's where
bench watch T-001                # point the deck diff pane at that worktree (live)
bench review T-001               # diffstat + expected-files check + lazygit pane
bench done T-001                 # squash-merge into base, archive, remove worktree
```

The orchestrator (a Claude Code skill, `bench-orchestrator`) drives this loop:
spec with the human → decompose into tasks with disjoint expected files → spawn
(≤3 concurrent by default) → poll `bench status --json` between turns → on
`blocked`, read the question and answer via Feedback + `bench nudge` → on
`review`, summarize the diffstat for the human. **Merges are serial and never
happen without human approval.**

## Verbs

| Verb | Does |
|---|---|
| `init` | Create + git-init the project state dir; write `.claude/` allowlist suggestions |
| `up` | Create-or-repair the tmux session (idempotent; safe after reboot/crash) |
| `task new "title" [--files g]` | Create the next `T-###.md` (status pending) |
| `task set <id> <key> <value>` | Atomic frontmatter write + state commit |
| `spawn <id>` | Worktree + branch from base, launch a claude worker session, flip to working |
| `status [--tmux\|--json\|--tree\|--stale\|--refresh-titles]` | Read-only state report |
| `watch <id>` | Point the deck diff pane at that task's worktree |
| `peek <id> [-n 30]` | Tail of the worker's pane (human eyes only; never used for state) |
| `nudge <id> "text"` | Send a line + Enter to the worker's pane |
| `review <id>` | Diffstat + expected-files check, open lazygit in the review pane |
| `done <id> [--yes]` | Squash-merge into base, archive the task, remove worktree |
| `abandon <id>` | Archive as abandoned, remove worktree, keep the branch |
| `resume <id>` | Relaunch a dead worker session in its worktree (task file *is* the context) |
| `doctor` | Check tools, tmux, state dir; print actionable fixes |
| `clean` | Prune stale worktrees/branches/sessions (prints a receipt) |

## Status & needs-input surfacing

`bench status` reads only files and `git log` — status is **never** screen-scraped.
The tmux status bar colors each task from those files (green=working,
yellow=blocked, blue=review, grey=pending) on a cheap interval; blocked/review
also ring the crew-window bell, so "needs you" is visible from the deck with no
daemon.

Because a worker frozen at an interactive permission prompt can't self-report,
bench detects needs-input passively, in layers: a repo `.claude/settings.json`
allowlist *prevents* most prompts; tmux `monitor-silence` marks a working task
with no fresh commit as `needs-input?` (orange chip + bell); optional pane-tail
sniffing (advisory only) raises confidence. Advisory hints color chips and
invite a `peek` — they never drive state. Answer with: click the chip → `peek` →
`nudge` the reply.

## Navigating

Three commands do the driving; the mouse does the rest:

- `bench up` — bring up (or repair) the tmux session.
- `bench status` — see who's where, colored by state.
- **the mouse** — click a chip to jump into a worker, right-click a tile for its
  menu, double-click to zoom. Full gesture list and troubleshooting:
  [docs/nav_cheatsheet.md](docs/nav_cheatsheet.md).

## tmux styling

The look (pane-border titles, dim inactive borders, accent active pane, nerd-font
glyphs with a `BENCH_ASCII=1` fallback) and the complete hotkey set live in
`bench.tmux.conf`. Source it from your `~/.tmux.conf`:

```sh
echo 'source-file /path/to/benchwork/bench.tmux.conf' >> ~/.tmux.conf
```

Navigation is mouse-first with a tiny hotkey set: `Alt+1`/`Alt+2` jump to
deck/crew, `Alt+←→↑↓` move between panes, `Alt+z` zooms, `Alt+Space` opens a
bench prompt for any verb. Deterministic navigation never routes through the LLM.

## Tests

```sh
tests/run.sh                                    # TAP-ish; exits 0 iff all pass
shellcheck -s bash bin/bench lib/*.sh           # run from the repo root
```

Both must be green before any commit.
