# Slice 3 handoff — read this first, then build

You are picking up `bench` — a talk-driven agent workbench on tmux + git (no hooks,
no MCP, no daemons) — to implement **slice 3, the final slice**. Slices 1–2 are done,
committed, and validated. This doc is your complete onboarding; trust it over
re-deriving state.

## Read in this order

1. This doc.
2. `docs/bench_spec.md` — the product spec. Slice 3 scope: §2 (tmux experience),
   §3.1 rows for `peek`/`doctor`/`clean`, §3.2 (the skill), §5 (needs-input
   detection, esp. items 2/2.5/3), §6 acceptance tests 3, 9, 10, 11, Appendix B.
3. `docs/slice1_contract.md` + `docs/slice2_contract.md` — binding interface
   contracts (schemas, env vars, tmux naming, helper inventory). Slice 3 extends,
   never breaks, these.
4. Project memory (auto-loaded): priorities + gotchas. Key one: **user decision —
   useful > elegant > simple > extremely user/agent-friendly; line count is NOT a
   constraint** (spec §0 rev). Actionable error messages and receipt-style output
   are the house style; read `lib/review.sh` to absorb it.

## Current state (all committed on main, pushed to origin)

- 12 verbs live: init, up, task new/set, spawn, status(--json/--tree/--tmux/--stale),
  watch, review, done, abandon, nudge, resume. `bin/bench` + `lib/{common,state,tmuxops,review}.sh`, ~700 lines.
- `tests/run.sh`: 124 assertions (t1–t25), fully isolated (private tmux socket via
  `BENCH_TMUX_SOCKET`, scratch `BENCH_HOME`, `BENCH_CLAUDE` → `tests/mock-claude`),
  ~9s, non-flaky. Extend it (t26+); never add a second harness.
- Two adversarial validation passes done; all 12 findings fixed + regression-tested.
- Tools in `~/.local/bin`: shellcheck, jq, lazygit v0.63.0, diffpane v0.4.0
  (verified working in tmux). `watch` auto-detects diffpane.
- Delivery artifact (update it when done, same URL):
  https://claude.ai/code/artifact/00a43488-7d44-4974-8241-647b16cd42f8
  — pass that as the `url` param to the Artifact tool; keep favicon ⚒️.

## Slice 3 scope

### A. `bench.tmux.conf` + status-bar wiring (spec §2 — the UX centerpiece)
Ship a conf the user sources from their tmux.conf (and print how in `init`/`doctor`):
mouse on; `Alt+1/2` deck/crew; `Alt+←→↑↓` pane focus; `Alt+z` zoom; `Alt+r` refresh;
`Alt+Space` → `command-prompt -p "bench>" "run-shell 'bench %1'"`. Status-bar right
segment: `#(bench status --tmux)` at 5s interval. Click-to-watch on task chips via
status-format click ranges (tmux ≥3.4; degrade to no-op gracefully — local tmux IS
3.4). Rounded/dim borders, pane border titles on, nerd-glyphs with `BENCH_ASCII=1`
fallback. That is the COMPLETE hotkey surface — do not add more (spec A.9/A.10).

### B. Bells + titles + needs-input (spec §2, §5; acceptance tests 3, 11)
- `status --refresh-titles`: retitle worker panes `T-### · <status>`.
- Bell on blocked/review transitions so the crew window name highlights: compare
  against a small cached last-seen-status file in the state dir (`.git/` or a
  dotfile — not a task file) during `status --tmux` runs; on transition, send BEL
  to the crew window (`btmux display-message`/`send-keys -t crew` C-g — pick the
  mechanism that works detached; prove it in tests).
- Needs-input detection, three layers, ALL advisory (color/chip only, never state):
  1. `setw monitor-silence 60` on worker sessions at spawn.
  2. `status` marks `needs-input?` when silent ≥60s AND status=working AND no fresh
     commit (silence flag via `#{window_silence_flag}`).
  3. Feature-flagged extras: `BENCH_TRANSCRIPT_HINTS=1` (parse Claude Code's local
     JSONL transcript tail for an unresolved tool-use; MUST fail silent on
     unrecognized shapes; `doctor` reports when enabled-but-unfamiliar) and
     capture-pane prompt-signature sniffing ("Do you want to", `❯`, numbered
     options). Spec §5 caveats are binding: hints color chips, NEVER drive state.
  - Acceptance test 11: worker parked at a permission prompt is flagged orange
    within 90s (test with a mock that prints a prompt and blocks on read).

### C. Verbs: `peek <id> [-n 30]`, `doctor`, `clean`
- peek: `capture-pane -p` tail of the worker pane. Human convenience only.
- doctor: check tmux/git/lazygit/diffpane/claude present, tmux ≥3.4, mouse on,
  state dir healthy (git repo, no half-written .fm.* temps), orphaned worktrees
  (`git worktree list` vs task files), conf sourced or not, transcript-hints
  familiarity. Actionable one-line fix per finding (test 10: missing diffpane →
  clear message, everything else still works).
- clean: prune merged/abandoned leftovers — stale worktrees, dead branches for
  archived tasks, `git worktree prune`. Print a receipt like `done` does.

### D. The `bench-orchestrator` skill (spec §3.2)
Create `.claude/skills/bench-orchestrator/` in THIS repo: `SKILL.md` (≤150 lines:
verb table, the 7-step operating loop from §3.2, single-writer rules, pushy
trigger description — quote the spec's wording) + `references/spawn-prompt.md`
(§4 template) + `references/task-schema.md` (frontmatter contract + Expected-files
semantics per A.14). This is what lets a Fable session drive bench by conversation.

### E. README.md — the dogfood task (do this one THROUGH bench itself)
Prereq: run `bench init` in this repo (creates `~/.bench/benchwork` + writes
`.claude/settings.json` — commit that file first so the worktree inherits it).
Then: `bench task new "Write README" --files 'README.md'`, fill Goal/acceptance
in the task file, `bench spawn`, and drive the real loop — watch, review
(surface check should stay quiet), done. Docs-only = zero risk to the tool. Note
every UX papercut you feel; fix the cheap ones in this slice. If the worker stalls
at a prompt, that's slice-3's needs-input feature failing its live demo — treat it
as signal, not annoyance.

### F. Tests: extend tests/run.sh (t26+)
Acceptance 3 (bell/status within one refresh), 10 (doctor degrades), 11 (orange
within 90s — use short override envs), peek content, clean receipts, refresh-titles,
conf lints (`tmux -f bench.tmux.conf -L tmp start\; kill-server` parses clean).
Acceptance 9 (VS Code integrated terminal) is manual — document the check in
`docs/test_plan.md` instead of automating.

## Build playbook (what worked twice — reuse it)

1. Write `docs/slice3_contract.md` pinning seams FIRST (file ownership per agent,
   exact env vars, cache-file format for bell transitions, chip colors, skill file
   paths). Parallel agents only integrate cleanly against pinned seams.
2. Spawn parallel **opus** builders via the Agent tool (NOT via bench — bench lacks
   needs-input surfacing until this slice lands, and Agent-tool subagents give
   richer reports with zero permission stalls). Suggested split: (1) tmux-conf +
   status-bar + bells + needs-input; (2) peek/doctor/clean; (3) skill + docs;
   (4) tests. Disjoint files; no worktrees needed.
3. CRITICAL harness quirk: subagents' final-message text often never arrives —
   instruct every agent to deliver its report via `SendMessage` to `"main"`
   BEFORE finishing, and to work only in throwaway dirs (mktemp BENCH_HOME,
   private `BENCH_TMUX_SOCKET`, never the real `~/.bench` or default tmux server).
4. Integrate yourself, run the full suite, then spawn a fresh adversarial
   validator (0-findings bar: BLOCKER/BUG; UX nits count as findings too — fix
   them, don't log them). Feed fixes back as regression tests.
5. Update the artifact (URL above) and give the user a summary + demo.

## Gotchas that cost time (don't rediscover)

- `claude -p` + `--allowedTools` is variadic: it EATS a trailing positional prompt.
  Pipe the prompt via stdin.
- awk `-v` mangles backslashes; pass values via `ENVIRON` (see `fm_set`).
- All tmux session names via `tmux_safe`/`worker_session` (dots/colons/spaces).
- Same-file serialization: flock on `$(state_dir)/.git/bench.lock` (task set,
  watch, review panes all use it — reuse, don't invent a second lock).
- mock-claude mode channel is the per-task `mockmode` frontmatter key
  (`bench task set T-00X mockmode idle|block|listen`) — NOT env vars.
- `require_task` (common.sh) is the archive-aware task lookup — use it in any new
  verb that takes an id.
- Sandbox blocks agent-initiated binary downloads; if something new is needed,
  surface the install command for the user to run with `!`.
- sudo needs the user; static binaries into `~/.local/bin` (on PATH) work without.
- Repo pushes: commit to main, push to origin (user's established flow). End
  commit messages with: Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>

## Definition of done

All §6 acceptance tests either automated (3, 10, 11 + prior 1–8) or documented as
manual (9); suite green and non-flaky at its new total; validator pass clean;
bench.tmux.conf sourced and working in the user's real tmux (walk them through it);
skill installed and demonstrably drives the loop; README merged via the dogfood
worker; artifact updated; everything committed + pushed. Then propose the real
shakedown: a 2–3-worker wave on the user's `talkiery` repo, driven by talking to a
Fable session with the skill loaded.
