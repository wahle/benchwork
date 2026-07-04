# bench — a talk-driven agent workbench on tmux

**Spec v1.1** (v1.0 + design-review fixes folded in; review notes in Appendix A)

## 0. One-paragraph summary

`bench` is a thin convention layer over tmux + git that lets a Fable orchestrator session spawn, monitor, and land work from full Claude Code (Opus) worker sessions — with live diff visibility and mouse/arrow-key navigation — using **no hooks, no MCP, no daemons**. It is a small CLI (bash) plus a Claude Code skill that teaches the orchestrator the verbs. State lives in plain files; code truth lives in git. Size discipline (rev. 2026-07-04, user decision): the old ≤400-line ceiling is a bloat *tripwire*, not a requirement — priorities are, in order: useful, elegant, simple, extremely user- and agent-friendly. Growth is fine when it buys clarity, actionable messages, or friendlier verbs; features that add a new *component* (daemon, UI, bridge) remain out of scope by default (§7).

**Hard constraints (enterprise-portable):**
- No Claude Code hooks (managed-hooks-only environments must work).
- No MCP servers (locked down at work).
- Permissive licenses only: tmux (ISC), git, lazygit (MIT), diffpane (MIT), bash. No AGPL.
- Everything the orchestrator does goes through `bench <verb>` (plain Bash) — auditable, allowlist-friendly.
- Must run identically in a standalone terminal and the VS Code integrated terminal (it's just tmux; attach from either).

## 1. The two layers (never mix them)

| Layer | Truth for | Lives at | Browsed with |
|---|---|---|---|
| **Work state** | what the work is: tasks, status, assignments, feedback | `~/.bench/<project>/` (outside the repo) | `bench status`, `cat`/`glow` |
| **Code** | what the code is | repo + one git worktree per task | diffpane (live), lazygit (review/merge) |

Rationale: state files inside the repo would fork across worker branches and pollute feature diffs. The state dir is itself a git repo (`git init` at `bench init`); the CLI auto-commits on every state change, giving a full audit trail for ~5 lines of shell.

### 1.1 State dir schema

```
~/.bench/gamehost/
  project.conf          # repo path, default model, base branch, port base
  tasks/T-042.md        # one file per task (schema below)
  archive/              # merged/abandoned tasks move here
  .git/                 # audit trail
```

### 1.2 Task file schema (`tasks/T-042.md`)

Markdown with a flat `key: value` frontmatter block — greppable with `grep '^status:'`, no yq/jq dependency.

```markdown
---
id: T-042
title: Add spot-interruption drain handler
status: pending        # pending|working|blocked|review|done|merged|abandoned
branch: agent/T-042
worktree: /home/nick/src/gamehost-T-042
model: opus
port: 3042             # 3000 + numeric id; workers use for any dev server/test port
question:              # set by worker only when status=blocked
updated: 2026-07-04T14:03:00Z
---

## Goal
(1–3 sentences, written by orchestrator from the spec)

## Expected files
- src/infra/drain/**        (globs; predicted diff surface — flagged at review if exceeded, never enforced mid-task)

## Acceptance criteria
- [ ] `npm test -- drain` passes
- [ ] CDK synth clean

## Feedback
(appended by human/orchestrator after review; worker re-reads on resume)
```

**Single-writer rule (prevents write races):**
- **Orchestrator** owns: creating tasks, `status: pending`, assignment fields.
- **Worker** owns: `status` transitions `working → blocked → working → review`, the `question:` field, `updated:`.
- **Human (via orchestrator)** owns: `review → done|working(+Feedback)`, `done → merged`.
- All writes are atomic: write temp file, `mv` over. The CLI provides `bench task set <id> <key> <value>` so nobody hand-edits frontmatter, including workers (their spawn prompt tells them to use it).

Status is **never** derived from screen-scraping. Files and `git log` are the only state sources. (`bench peek` scrapes a pane tail for *human* convenience only.)

## 2. The tmux experience (looks & navigation)

One tmux session per project, name = project. Two windows:

```
Window 1 "deck"                        Window 2 "crew"
┌──────────────────┬────────────────┐  ┌─────────┬─────────┐
│                  │  diffpane      │  │ T-042   │ T-043   │
│  Fable           │  (follows the  │  │ opus    │ opus    │
│  orchestrator    │  watched task) │  ├─────────┼─────────┤
│  (you talk here) ├────────────────┤  │ T-044   │ (spare) │
│                  │  lazygit       │  │ opus    │         │
│                  │  (main repo)   │  └─────────┴─────────┘
└──────────────────┴────────────────┘   tiled; grows as spawned
 status bar: ⚒ deck | crew ▸ T-042 ●working T-043 ⛔blocked T-044 ✓review
```

**Navigation — mouse first, tiny hotkey set:**
- `set -g mouse on`: click any pane to focus, drag borders to resize, wheel to scroll, click window names in the status bar to switch.
- `Alt+1` / `Alt+2`: jump to deck / crew (no prefix).
- `Alt+←→↑↓`: move focus between panes (no prefix).
- `Alt+z`: zoom/unzoom focused pane (fullscreen a worker, tap again to restore).
- `Alt+r`: force status-bar refresh.
- `Alt+Space`: **bench prompt** — tmux's built-in `command-prompt` overlaying the status bar (`bind -n M-Space command-prompt -p "bench>" "run-shell 'bench %1'"`). Type any verb (`watch 43`, `peek 42`, `status`), Enter, it vanishes. This is the UI control surface: deterministic navigation never goes through the orchestrator LLM.
- Status-bar task names are click-bound: clicking `T-043` runs `bench watch T-043` (~3 lines via tmux status-format click ranges; degrade gracefully to no-op on tmux < 3.4).
- That is the complete hotkey surface. Interaction tiers: **mouse** for focus/resize/scroll/click-to-watch, **Alt+Space** for any bench verb, **Fable** for intent and judgment only (decompose, spawn, unblock, approve). UI reconfiguration is never routed through Fable.

**Glanceable status:** pane borders show titles (`T-042 · working`, set via `tmux select-pane -T`, updated by `bench status --refresh-titles`). The status bar right segment runs `bench status --tmux` (cheap file grep, 5s interval) and colors tasks: green=working, yellow=blocked (needs you), blue=review (needs you), grey=pending. Blocked/review also trigger a tmux bell on the crew window so the window name highlights — visible from the deck without any daemon.

**Style:** ship a `bench.tmux.conf` sourced from the user's tmux.conf — rounded pane borders where supported, dim inactive borders, accent color for the active pane, nerd-font glyphs with plain-ASCII fallback (`BENCH_ASCII=1`).

## 3. Verbs

### 3.1 CLI (`bench <verb>`) — what Fable (and you) actually run

| Verb | Does |
|---|---|
| `init` | Create state dir, project.conf, git-init it; write `.claude/` allowlist suggestions (see §5) |
| `up` | **Idempotent + minimal**: create-or-repair the session and navigator surface only. All other panes (Fable cores, workers, diffpane, lazygit) materialize lazily via verbs below. Safe after reboot/sleep/crash |
| `core new "name"` | Spawn a new top-level Fable orchestrator session as a tree node (multiple concurrent cores are first-class; workers hang under the core that spawned them) |
| `task new "title" [--files glob..]` | Create next `T-###.md` (status pending) and print its path |
| `spawn T-042` | Create worktree+branch from base, per-worktree setup (§A.3), launch `claude --model <model>` with the spawn prompt (§4) as a **session** (not a pane), flip status to working. It appears in the tree; embed/tab it to view it |
| `status [--tmux\|--json\|--tree\|--stale]` | Read all task files + `git log -1` per branch. `--json --tree` emits the session tree (workbench → cores → workers, with states) — the contract every UI renders from. `--stale`: flag workers with no commit **and** no file update in 20 min |
| `focus <id>` | Jump to the pane currently showing that session (embed it first if none) |
| `embed <id> [--target win]` | Show a session as a pane in the current (or named) window via `join-pane`/`link-window`. Panes are **views**; the session is never owned by its pane |
| `tab <id>` | Show a session in its own window |
| `pop <id>` | Remove the pane view; the session keeps running headless |
| `watch T-042` | Re-point the deck diffpane at that task's worktree (kill+relaunch diffpane in place) |
| `peek T-042 [-n 30]` | `capture-pane -p` tail of that worker's pane (human convenience; never used for state) |
| `nudge T-042 "text"` | `send-keys` the text + Enter to the worker pane (send text and Enter as two sends, 100 ms apart — interactive-TUI paste quirk) |
| `review T-042` | Open lazygit in that task's worktree in the deck review pane; print branch-vs-base diffstat |
| `review T-042 --annotate` | *(Slice 3, optional)* Run lumen on the branch diff for inline annotations; on send, append them to the task's Feedback section, flip status to working, and nudge the worker. Gate on a license check for lumen before enterprise install; feature degrades to plain `review` if absent |
| `open T-042` | Open the task's worktree in the GUI editor (`$BENCH_EDITOR`, default `code`) — full IDE diff via Source Control on that worker's branch |
| `done T-042` | Squash-or-merge branch into base (asks unless `--yes`), remove worktree, archive task, `git worktree prune` |
| `abandon T-042` | Kill pane, remove worktree, archive with status abandoned |
| `resume T-042` | Re-open a pane, `claude --resume` (or fresh `claude` re-pointed at the task file if resume unavailable) — the task file *is* the durable context, so a fresh session recovers from it |
| `doctor` | Check tmux/git/lazygit/diffpane/claude present, mouse on, state dir healthy, orphaned worktrees |
| `clean` | Prune merged worktrees/branches, archive stragglers |

### 3.2 Skill (`bench-orchestrator`)

```
bench-orchestrator/
├── SKILL.md
└── references/
    ├── spawn-prompt.md      # the worker prompt template (§4)
    └── task-schema.md       # frontmatter contract + single-writer rules
```

SKILL.md contents (≤150 lines): the verb table, the operating loop (below), the single-writer rules, and *pushy* triggering description per skill-authoring guidance: "Use this skill whenever the user asks to parallelize work, spawn workers/agents, check on tasks, review or merge agent work, or says anything like 'crew', 'workers', 'spin up', 'what's the status', even if they don't say 'bench'."

**Orchestrator operating loop (in SKILL.md):**
1. Spec session with the human → commit spec to base branch **before** any spawn.
2. Decompose into tasks with **disjoint expected-files** (`bench task new`) — this is a *planning check*: overlap discovered here means serialize or re-cut those tasks, and a `**` surface (repo-wide refactor) runs alone. Name any shared interfaces/types the task must agree on in the Goal. Only ONE task per wave may own `package.json`/lockfiles.
3. `bench spawn` each (default ≤3 concurrent; ask before more).
4. Poll `bench status --json` between turns; on `blocked`, read `question:`, answer by appending Feedback + `bench nudge`, or escalate to the human; on `--stale`, nudge once, then report.
5. On `review`: tell the human, `bench watch` it, and summarize the diffstat. **Never merge without human approval.** Human approves → `bench done`.
6. Merge **serially**; after each merge, nudge remaining workers to rebase (`bench nudge T-0xx "base updated; rebase onto <base> and re-run tests"`).
7. All state via `bench` verbs. Never edit task frontmatter by hand, never scrape panes for state.

## 4. Worker spawn prompt (template, abridged)

> You are worker **{id}** on branch `{branch}` in worktree `{worktree}`. Your task file is `{taskfile}` — read it now; it is your durable context and survives you.
> Rules: (1) Prefer to stay within Expected files; if the task genuinely needs an edit outside them, make the edit and note it when you set status review — do not block to ask. (2) Commit checkpoints early and often — commits are your heartbeat. (3) Update status **only** via `bench task set {id} status <value>`. (4) If blocked, `bench task set {id} question "…"` then status blocked, and wait. (5) Use port {port} for any server/test that needs one. (6) When acceptance criteria pass, make a final commit, set status review, and stop. (7) Re-read the Feedback section whenever you resume or are nudged.

## 5. Permissions (no-hooks reality)

Workers running unattended stall on permission prompts with nobody watching. Mitigations, in order:
1. Repo-level `.claude/settings.json` allowlist pre-approving the project's routine operations (git commit, npm test, tsc, `bench task set`, etc.). `bench init` writes it directly when the repo has none (commit it to base so worker worktrees inherit it); if one already exists without bench's entries, init emits `.claude/settings.json.bench-suggested` to merge by hand instead — never overwrites, since JSON can't be merged safely in bash.
2. Where enterprise-managed settings forbid that: the status bar's yellow/bell surfacing + `bench peek`/`nudge` make answering prompts a two-keystroke affair from the deck.
3. Never grant blanket bypass; owned-files boundaries are prompt-level, not enforced — the allowlist should stay scoped.

**Needs-input detection without hooks (three layers):** a worker frozen at an interactive prompt cannot self-report (the model is mid-turn awaiting a keystroke), so:
1. *Prevent* — the allowlist above removes most prompts.
2. *Detect natively* — `setw monitor-silence 60` on worker panes (built into tmux, no scraping). `bench status` combines: silent ≥60s **and** status `working` **and** no fresh commit → mark the task `needs-input?` (orange chip + bell).
2.5. *Transcript hints (feature-flagged: `BENCH_TRANSCRIPT_HINTS=1`, default off)* — Claude Code writes session transcripts as JSONL on local disk as it runs. A trailing unresolved tool-use entry while the worker process is alive is a strong "awaiting approval" signal. Purely passive local file reads: no hooks, no PTY interposition, no network, nothing forwarded — same posture as task-file polling. **Caveats, binding:** the transcript format is internal and may drift between Claude Code versions, so (a) advisory only — colors chips, never drives state; (b) the parser must fail silent-and-safe on unrecognized shapes; (c) `bench doctor` reports when hints are enabled but the format looks unfamiliar. Enterprise note: reading Claude Code's own local files is expected to be policy-clean (user's data, user's disk, zero interposition/relay), but confirm against local policy before enabling at work.
3. *Confirm (advisory only)* — optional `capture-pane` tail matched against prompt signatures (`Do you want to`, `❯`, numbered options) to upgrade the hint's confidence. Advisory hints color chips and invite a `peek`; they must NEVER drive state transitions or automation — if Claude Code's UI text changes, the failure mode is a missing hint, not corrupted state.
Answering the need: click the orange chip → `peek` → `nudge` the answer (or click into the pane). Add to acceptance tests: a worker parked at a permission prompt is flagged orange within 90 s (test 11).

## 6. Acceptance tests (definition of done for Fable's build)

1. `bench up` twice in a row → second run changes nothing, exits 0.
2. `bench task new` + `spawn` → worktree exists on correct branch, pane titled `T-### · working`, status file flipped, state-dir git log shows the change.
3. Worker sets status blocked with a question → within one status refresh (≤5s manual, ≤bar interval otherwise) the status bar shows yellow and the crew window bell fires.
4. `bench status --stale` flags a worker with no commits/updates for 20 min (test with 10s override env var).
5. `bench watch T-042` → diffpane pane now follows that worktree; live edit there appears without keypresses.
6. `bench review` + `done` → branch merged to base, worktree gone, task in archive/ as merged, `git worktree list` clean.
7. Kill the tmux server mid-run → `bench up` restores layout; `bench resume T-042` reattaches a working session; task file intact.
8. Two rapid `bench task set` calls on different keys → both persist (atomic mv, no lost update).
9. Full run works inside VS Code's integrated terminal (mouse focus + status bar included).
10. `bench doctor` on a machine missing diffpane → clear actionable message, everything else still works.

## 7. Build plan (vertical slices, riskiest first)

- **Slice 1 (riskiest):** spawn pipeline end-to-end — task file → worktree → pane → claude launch → status flip → `status`. Prove the loop with one worker.
- **Slice 2:** review/merge path — `watch`, `review`, `done`, serial-merge + rebase-nudge convention. First step: the expected-files detective control — `review`/`done` match `git diff --name-only <base>...<branch>` against the task's globs and WARN on out-of-surface files (advisory only; ~8 lines). Design rationale in Appendix A.14.
- **Slice 3:** polish — status bar + pane titles + bell, `stale`, `peek/nudge`, `doctor/clean`, `bench.tmux.conf` styling, SKILL.md description tuning.

Out of scope, permanently (bloat guard): web UI, phone bridge, cross-machine sync, screen-scraped state detection, cost tracking, any daemon.

---

## Appendix A — Design review (outside view) and resolutions

Issues found reviewing v1.0; all fixes are already folded into the spec above.

**A.1 Write races on task files.** Two writers (worker + orchestrator) editing one file corrupts frontmatter. → Single-writer field ownership (§1.2) + atomic temp-file `mv` + all writes through `bench task set`.

**A.2 Silent stall.** A worker that crashes or forgets to flip status looks "working" forever; with hooks banned there's no TeammateIdle equivalent. → Commits-as-heartbeat + `status --stale` (20 min) + orchestrator nudge-once-then-escalate. Honest limitation: detection latency is minutes, not seconds — acceptable for this scale.

**A.3 Worktree setup cost & drift (TypeScript reality).** Each worktree needs `node_modules`; three workers = three installs. → `spawn` runs an optional per-project `setup` command from project.conf; recommend **pnpm** so parallel worktrees hard-link one store (near-instant, disk-cheap). Also copy `.env`-style untracked files listed in project.conf.

**A.4 Port collisions.** Parallel dev servers/tests fight over ports. → Deterministic `port: 3000+id` in the task file, injected into the spawn prompt.

**A.5 Merge-order conflicts.** Parallel branches from the same base conflict at landing even with disjoint source files (lockfiles, generated code). → Serial merges + post-merge rebase nudges (§3.2 step 6) + one-lockfile-owner-per-wave rule.

**A.6 Blocked worker deadlock on permissions.** No hooks means permission prompts can freeze a worker invisibly. → §5 allowlist + bell/yellow surfacing + `peek`/`nudge`. This is the design's weakest point in a fully locked-down enterprise; the fallback is genuinely "you answer prompts," just made cheap.

**A.7 Crash/sleep recovery.** tmux sessions die on reboot; sessions are local. → `up` is idempotent by spec (test 1), `resume` re-anchors on the task file (the user's original context-directory idea doing real work), test 7 enforces it.

**A.8 Diffpane is single-directory.** One diffpane can't follow three worktrees. → `watch` verb makes switching one command/utterance ("watch 43"); for simultaneous eyes, `Alt+2` + zoom a worker, or accept that the deck shows one live diff at a time — a deliberate simplicity trade.

**A.9 UX miss in v1.0: everything required typing.** → Mouse mode, clickable status-bar windows, pane-border titles, bell highlighting, and the 5-hotkey ceiling (§2). The talk-first path also got verbs for every review action so Fable can drive lazygit-adjacent steps (`watch`, `review`, diffstat summaries) without you touching the keyboard.

**A.10 UI control routed through the LLM (v1.1 review).** Early drafts sent navigation ("watch 43") through the Fable session — wasteful (latency, tokens, interrupts orchestration context) and fragile. → Three-tier interaction model (§2): mouse / Alt+Space bench prompt (tmux `command-prompt`, zero new code) / Fable for judgment only. Rejected alternative: a dedicated nav pane or session — consumes layout space, adds a component to maintain, and duplicates what tmux ships natively.

**A.11 Scope-creep tripwires.** Status detection heuristics, richer TUI, notification bridges — each is herdr/agent-deck territory and each is a maintenance commitment. → Explicit out-of-scope list (§7) and the ≤400-line budget in §0.

**A.12 Review-comment channel (v1.1 review).** Lazygit has no comment mechanism, so "how do I give feedback on a diff" needed an explicit answer. → Mental model: **lazygit = read and veto** (hunk discard before merge), **task-file Feedback = comment and redirect** (via Fable, or via optional lumen inline annotation with `review --annotate`), **`bench open` / VS Code = deep inspection**. All three operate on the same worktree; the Feedback section is the only channel workers re-read, so all human commentary must land there.

**A.13 Needs-input detection spectrum (v1.1 review).** Relay-style tools prove input-need detection is possible via two mechanisms bench deliberately rejects: hooks (blocked in the target enterprise) and PTY interposition (wrapping Claude Code in an owned pseudo-terminal and parsing its I/O stream — the architecture the enterprise's soft stance targets, and a standing process between the user and their sessions). bench's stack (§5) is strictly passive-local: tmux silence signals, optional transcript hints, optional pane-tail sniffing — all advisory, nothing interposed, nothing collected or forwarded. Accepted trade: ~60–90 s detection latency and hint-level (not guaranteed) fidelity, in exchange for zero policy surface.

**A.14 Owned-files → Expected-files reframe (post-slice-1 design review, 3-angle panel).** v1.1's "worker may not write outside these" boundary was the wrong framing: unenforceable (no hooks), and backwards as a control — workers honor it in easy cases and break it exactly when acceptance criteria demand an out-of-glob edit (barrel exports, shared helpers, tsconfig references), yielding either silent violations found late, throughput-killing self-blocks, or duplicated code written to honor the fence. Prior art agrees text-file write-partitioning isn't the primitive (CODEOWNERS routes review, never blocks writes; locking survives only for unmergeable binaries; the real conflict drivers are branch lifetime and semantic coupling — which disjoint globs never addressed, per A.5's own lockfile/generated-code concession). What IS real: the decompose-time overlap check (planning) and a review-time out-of-surface tripwire (detective control). So: renamed to **Expected files** — a prediction of the diff surface; worker prompt says prefer-don't-block; `review`/`done` warn on out-of-surface paths (slice 2, advisory only). Rejected: sparse-checkout physical enforcement (removes files workers must read; breaks pnpm/tsc), spawn-time glob-intersection warnings (undecidable cheaply, redundant with the planning check), and full deletion (loses the free planning + review value for zero code saved).

**Residual risks accepted:** worker file-boundary enforcement is prompt-level only (git review is the real gate); stale detection latency; lazygit itself isn't scriptable so "review" opens it rather than drives it — the human is intentionally in that loop.

---

## Appendix B — UI evolution paths (engine/presentation neutrality)

The user's target vision is a **persistent navpanel**: an always-visible tree (workbench → core Fable tasks → workers), where selecting a node offers *focus / embed-as-pane / open-as-tab*, a "new core task" button spawns a Fable session, and auxiliary views (lazygit, diff) instantiate lazily on first open. This is the herdr interaction model, rebuilt permissively. It is **not** built in v1 — but nothing in v1 may make it harder.

**Neutrality rules (binding on all slices):**
1. **Engine/presentation split.** All state and actions live in the `bench` CLI. No verb may assume a particular layout, window name, or pane position. Sessions are addressed by ID; panes are looked up, never remembered.
2. **The tree is the contract.** `bench status --json --tree` is the single source every renderer consumes. UIs may be added or deleted without touching the engine.
3. **Panes are views of sessions.** Workers and cores run as tmux sessions; `embed`/`tab`/`pop`/`focus` attach and detach views. Killing a pane never kills work.
4. **Lazy instantiation everywhere.** `up` builds only the navigator surface. Fable cores, lazygit, diffpane, and workers appear on first use. (Consequence: the §2 "deck" layout is just the *default rendering*, reproducible as a recipe of embed calls — not a hardcoded structure.)
5. **Every UI affordance = one verb.** Buttons, clicks, palette entries, and status-bar segments may only invoke `bench` verbs, so all UIs stay trivially swappable and Fable can drive anything a human can click.

**Planned rendering tiers (each a pure client of the same engine):**
- **v1 — status bar + `Alt+g` fzf popup palette:** `display-popup` + fzf over `status --tree`; Enter=focus, Ctrl-E=embed, Ctrl-T=tab. Zero resident UI. Proves the engine.
- **v1.5 — resident fzf navpanel:** the same fzf tree running in a loop in a dedicated left pane with `--bind` actions and periodic reload (~30 lines of shell). This *is* the user's navpanel vision in cheap form: always visible, arrow-key + mouse selectable, per-node embed/tab actions, "new core task" as a pinned top entry invoking `core new`.
- **v2 — real TUI renderer (only if v1.5 ergonomics chafe):** replace the fzf renderer with a small dedicated TUI (Ink/TypeScript fits the user's stack) consuming the same JSON tree and calling the same verbs. Explicitly a renderer swap, not a rewrite.

**Deferred decisions (do not implement, do not preclude):** the `classic|focus` two-layout option (revisit after real use); diff-as-dedicated-tab (already expressible as `tab` + `watch`); v2 TUI framework choice.