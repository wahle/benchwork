---
name: bench-orchestrator
description: Use this skill whenever the user asks to parallelize work, spawn workers/agents, check on tasks, review or merge agent work, or says anything like 'crew', 'workers', 'spin up', 'what's the status', even if they don't say 'bench'.
---

# bench-orchestrator

`bench` is a talk-driven agent workbench on tmux + git. You (the orchestrator)
decompose work, spawn Claude Code workers as tmux sessions, and land their
branches. Every action goes through a `bench <verb>` — plain, auditable Bash.
State lives in task files under `~/.bench/<project>/`; code truth lives in git.

**All state changes go through bench verbs. Never hand-edit task frontmatter.
Never scrape panes to decide state** — files and `git log` are the only truth.
`bench peek` shows a pane for your eyes only, never for state.

## Verbs

Run these; do not reimplement them. Task ids accept `42`, `T-42`, or `T-042`.

| Verb | Reach for it when |
|---|---|
| `bench init` | First-time setup: create + git-init the state dir, write `.claude/` allowlist. |
| `bench up` | Create-or-repair the tmux session. Idempotent — safe after reboot/crash. |
| `bench task new "title" [--files g..]` | Start a task. Prints the task-file path; fill it in before spawning. |
| `bench task set <id> <key> <value>` | Atomic frontmatter write (+ state commit). The only way to edit a task file. |
| `bench spawn <id>` | Create worktree+branch, launch the worker, flip status to working. |
| `bench status` | Human table of all tasks + per-branch last commit. |
| `bench status --tmux` | Status-bar chip line (drives the bar; also bells). Add `--refresh-titles` to retitle panes. |
| `bench status --json` | Machine state — poll this between turns. Includes advisory `needs_input`. |
| `bench status --tree` | Session tree (workbench → cores → workers); the contract UIs render. |
| `bench status --stale` | Flag workers idle 20 min (no commit AND no file update). |
| `bench status --refresh-titles` | Retitle live worker panes `T-0xx · <status>`. |
| `bench watch <id>` | Point the deck diff pane at a task's worktree (live diff). |
| `bench peek <id> [-n 30]` | Tail a worker's pane — human eyes only, never state. |
| `bench review <id>` | Diffstat + expected-files check + open lazygit on the branch. |
| `bench done <id> [--yes]` | Squash-merge into base, archive, remove worktree. **Human-approved only.** |
| `bench abandon <id>` | Archive as abandoned, remove worktree, keep the branch (salvage). |
| `bench nudge <id> "text"` | Type a line into the worker's pane (answer a prompt, tell it to rebase). |
| `bench resume <id>` | Relaunch a dead worker in its worktree from the durable task file. |
| `bench doctor` | Diagnose tools/tmux/state health; each line names the exact fix. |
| `bench clean` | Prune orphaned worktrees/branches/sessions; prints a receipt. |

## Operating loop

1. Spec the work with the human, then **commit the spec to the base branch
   before any spawn.**
2. Decompose into tasks with **disjoint expected files** (`bench task new`).
   This is a planning check: overlap found here means serialize or re-cut those
   tasks; a `**` (repo-wide) surface runs alone. Name any shared
   interfaces/types the tasks must agree on in each Goal. **Only ONE task per
   wave may own `package.json`/lockfiles.**
3. `bench spawn` each — **default ≤3 concurrent; ask the human before more.**
4. Poll `bench status --json` between turns. On `blocked`, read the `question:`
   field, answer by appending to the task's `## Feedback` and `bench nudge`, or
   escalate to the human. On `--stale`, nudge once, then report.
5. On `review`: tell the human, `bench watch` it, summarize the diffstat.
   **Never merge without human approval.** Human approves → `bench done`.
6. Merge **serially**. After each merge, nudge remaining workers to rebase:
   `bench nudge T-0xx "base updated; rebase onto <base> and re-run tests"`.
7. All state through `bench` verbs. Never edit task frontmatter by hand; never
   scrape panes for state.

## Single-writer rules

One writer per transition — this prevents frontmatter races. Respect it.

| Who | Owns |
|---|---|
| **You (orchestrator)** | Creating tasks; `status: pending`; assignment fields (branch, worktree, model, port). |
| **Worker** | `status` transitions `working → blocked → working → review`; the `question:` field; `updated:`. |
| **Human (via you)** | `review → done` or `review → working` (+ append Feedback); `done → merged`. |

You never set a worker's `working`/`blocked`/`review`; the worker never sets
`pending`/`done`/`merged`. To redirect a worker, append to its `## Feedback`
then `bench nudge` — Feedback is the only channel workers re-read on resume.

## Reading needs-input

`needs_input` in `status --json` (and the orange `?`/`!` chips) is a **silence
heuristic, purely advisory — never a state.** A worker can be frozen at a
permission prompt with the model mid-turn, unable to self-report. When a task is
flagged: `bench peek <id>` to see the pane, then `bench nudge <id> "…"` to
answer (or click into the pane). Do not branch automation on it or treat it as a
status transition; if the signal is wrong, the worst case is a missing hint.

Two behaviors to expect (observed live): a FRESH worker always parks on Claude
Code's folder-trust prompt first — watch for the orange chip after spawn and
`bench nudge <id> ""` (a bare Enter) to accept. And once flagged, orange clears
on the worker's next **commit**, not on mere output — a worker that resumed but
hasn't committed yet may stay orange a while; peek before assuming it's stuck.

## Practical notes

- `bench task new` prints the task-file path. Fill in **Goal**, **Expected
  files**, and **Acceptance criteria** before you spawn — the worker reads the
  file as its durable context.
- Human feedback goes in the task's `## Feedback` section, then `bench nudge`.
- See `references/task-schema.md` for the frontmatter contract and Expected-files
  semantics; `references/spawn-prompt.md` for the rules workers operate under.
