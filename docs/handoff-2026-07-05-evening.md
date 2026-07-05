# bench handoff — nav wave + navigator trial (2026-07-05 evening)

**READ THIS FIRST: the project's continuation is an open question, not a given.**
After a full day of dogfooding, the user said: *"I think I expected too much
from this project as a whole. I feel like claude agent teams and just learning
tmux shortcuts would have been easier."* They were tired and battered by a day
of real friction (below). The next session MUST start by asking whether to
continue, simplify, or shelve bench — do not open with new bench work. Sunk
costs are explicitly off the table.

## State (main @ 105e689 or later, all pushed)

- Nav wave MERGED: `bench menu` (context menus: tile/chip right-click, [≡],
  prefix+m), `bench board` (deterministic status-driven crew relayout),
  review-on-demand (no auto-lazygit; `--tui` flag), chip trust (`!` orange only,
  `?` dim), `bench focus` (jump = zoomed crew tile, never switch-client).
- Post-wave hardening MERGED: signature-first `!` detection (self-clears; no
  silence prerequisite), harness env shed (BENCH_* unset at top of run.sh),
  t26 conf-lint via source-file. 236/236 → 246/246 on T-005's branch.
- Workers prompt-free end-to-end: repo pre-trusted (`hasTrustDialogAccepted`
  covers worktrees — verified live), settings.json allows Read/Edit/Write
  in-tree + Read(~/.bench/**) + shellcheck + tests/run.sh.
- `bench-navigator` skill exists (repo + ~/.claude): sonnet caretaker calling
  `bench board` + one-line callouts. Trialed briefly; the session got reset by
  accident mid-trial — no verdict on whether it earns its tokens.

## Parked, validated, NOT merged (human never said merge)

- **T-005** doctor nav-layer checks — rebased onto main, 246/246, shellcheck
  green, scope exact. `bench done T-005 --yes` when/if approved.
- **T-006** mouse cheatsheet + README nav section — content approved after one
  accuracy bounce (commit 65ac7a3). `bench done T-006 --yes` when/if approved.
- Worker sessions may be parked in review; killable or `bench resume`-able.

## What bit the user today (why they're doubting the project)

1. Chip left-click was dead since slice 3 (bound `StatusRight`; clicks fire
   plain `Status` on WSL2/WT — found via debug taps, fixed b94a463). The front
   door of the UX, broken, while the handoff said "unverified" — verify-first
   next time.
2. Jump-into-worker stranded them: worker sessions are bar-less (embed keeps
   tiles clean) → no chips/keys/mouse way home. Fixed by `bench focus`
   (105e689) — jump now zooms the tile inside the workbench session.
3. Windows Terminal apparently clips tmux's bottom row on their setup: the
   status bar was invisible to them ALL DAY (flashes too). `status-position
   top` was set live as a test and seemed to fix it — NOT yet in the conf.
   First action if continuing: confirm and commit `set -g status-position top`.
4. Prompt fatigue: dozens of permission clicks before the allowlist caught up
   (shellcheck/tests added only late, c142107). Fresh spawns are now near-silent.
5. The `!` chip stayed green while three workers sat parked (silence-gated
   detection vs always-viewed crew tiles) — fixed (55f58d0), verified live once.

## Open threads if the project continues

- Commit `status-position top` (see #3 — user-verified visible, uncommitted).
- SKILL.md verb table lacks `focus`; sync repo + ~/.claude copies.
- Review-flip-without-commit hole: a worker can `task set status review` with
  no new commit (T-006 did it — claimed a fix it hadn't made). Guard idea:
  warn/refuse in task set when branch has no new commit since last bounce.
- Navigator verdict never reached. The deterministic board alone may be enough.
- nav_cheatsheet.md references `bench focus` nowhere (written before it
  existed) — needs a line if merged.

## If the project is shelved

Salvage list (transfers to agent-teams-on-tmux or any setup): the pre-trust
mechanism (~/.claude.json hasTrustDialogAccepted at repo root covers all
worktrees), the committed-settings allowlist pattern (Read/Edit/Write in-tree,
tool binaries by name), the no-agent-answers-prompts discipline, and the tmux
gotchas lists here + in docs/handoff-2026-07-05.md.
