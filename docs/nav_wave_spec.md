# Navigation wave spec (2026-07-05)

Goal: bench becomes mouse-first and self-arranging. Everything a hand on the
mouse can reach: jump into a worker, watch its diff, peek, nudge, review, pop —
without memorizing a hotkey. The crew wall redraws itself as worker status
changes. Review stops squatting on deck real estate. Workers launch with zero
interactive prompts.

Decisions already made with the user (do not relitigate):

- Deck right side is EMPTY by default. Watch/lazygit open on demand only.
- No agent ever answers a worker's trust or permission prompt. Prompts must not
  appear at all — pre-granted via config the user approves once (see §5).
- tmux 3.7b is the floor (installed). Use `control|N` click ranges freely.
- Keyboard fallback for every mouse action (mouse support varies by terminal;
  Windows Terminal Shift+click bypasses tmux mouse mode — document it).

Wave shape: three parallel opus workers with disjoint files. Shared surfaces
(bin/bench dispatch, tests/run.sh) are pre-wired on main before spawn; workers
edit only their own lib file(s), conf (T-A only), and their reserved test block.

| Task | Files | Test block |
|---|---|---|
| T-A mouse layer | `bench.tmux.conf`, `lib/menus.sh` | t38 |
| T-B board primitives | `lib/board.sh` | t39 |
| T-C review + chip trust | `lib/review.sh`, `lib/tools.sh` | t40 |

Shared read-only contracts all three rely on (never redefine, only consume):
`@bench_view` pane tag (crew tile → worker session name), `bench status --json`
fields, `worker_session`/`tmux_safe` naming, `btmux` for every tmux call.

## 1. T-A — mouse navigation layer (`lib/menus.sh` + `bench.tmux.conf`)

### 1.1 `bench menu <id>` — one menu implementation, many entry points

`cmd_menu` (lib/menus.sh) builds and shows a tmux `display-menu -M` for a task:

- Jump into worker (switch-client to its session)
- Watch diff (bench watch <id>)
- Peek (display-popup -E running `bench peek <id> -n 40`; any-key dismiss)
- Nudge… (display-popup with a prompt line that feeds `bench nudge <id>`)
- Review (bench review <id> — diffstat receipt; T-C owns what review prints)
- Pop tile / Embed tile (whichever applies given current crew state)

Rules: menu opens at the mouse when invoked from a mouse binding (`-x M -y M`),
centered when invoked from the keyboard. Every entry shows its keyboard
equivalent in the right column of the menu. Resolve the task FROM the clicked
pane's `@bench_view` when invoked with `--from-pane <pane_id>`; plain
`bench menu <id>` takes an explicit id (keyboard path, panel integration).
All tmux interaction via `btmux`; route format expansion through `run-shell`
(targets do not expand `#{}` — see docs/handoff-2026-07-05.md gotchas).

### 1.2 Conf bindings (`bench.tmux.conf`)

- `MouseDown3Pane` in the crew window → `bench menu --from-pane` for that tile.
  Guard: only when the pane has `@bench_view`; otherwise fall through to
  tmux's default context menu.
- `DoubleClick1Pane` in crew → `resize-pane -Z` (zoom tile; double-click again
  restores). Same guard.
- Per-tile `[≡]` glyph in `pane-border-format` wrapped in
  `#[range=control|9]…#[norange]` → `MouseDown1Control9` opens the tile's menu.
- Status-bar chips: keep left-click = jump (existing run-shell mechanism);
  `MouseDown3StatusDefault`/chip range right-click → `bench menu` for that task.
  Budget control ranges deliberately: 9=tile menu, 8=chip menu; leave 0–7 free.
- Keyboard fallbacks: a prefix binding that opens `bench menu` for the active
  crew tile; existing Alt+g panel stays the keyboard palette.
- Conf comments: note Shift+click (Windows Terminal native selection) and that
  ranges need tmux ≥3.7.

### 1.3 Acceptance (t38)

- `bench menu T-0xx` on a live fixture exits 0 and is testable headless (a
  `--print` mode that emits the menu entries instead of displaying is fine and
  makes assertions honest).
- Menu on a never-spawned task dies naming `bench spawn`.
- `--from-pane` resolves the task from `@bench_view`; a pane without the tag
  dies with a one-line explanation.
- Conf parses: `tmux -f bench.tmux.conf -L smoke start-server \; kill-server`
  style smoke check.

## 2. T-B — board primitives (`lib/board.sh`)

`bench board` = ONE relayout pass over the crew window. `bench board --watch`
= loop with debounce. No LLM anywhere in this layer — rules are code. A later
navigator agent CALLS these verbs; it never issues raw tmux layout commands.

### 2.1 The pass

Inputs: `bench status --json` + crew tile inventory (`@bench_view` tags).
Actions, in order:

1. Embed any `working|blocked|review` task that has a live session but no tile.
2. Pop tiles whose task is merged/abandoned or whose session is dead.
3. Promote: if any task is `review` or signature-confirmed needs-input (`!`),
   arrange crew as `main-vertical` with the highest-priority tile as the main
   pane (priority: `!` > review > blocked > working; ties → lowest id).
4. Otherwise settle to `tiled` layout.

Every action prints a one-line receipt (`board: promoted T-042 (!)`); a pass
that changes nothing prints nothing and exits 0.

### 2.2 Safety rules (acceptance criteria, not suggestions)

- **Transition-gated**: persist the last-seen state snapshot under
  `$(state_dir)/.board-state`; a pass acts only on CHANGES since the snapshot.
  Same input twice = second pass is a no-op (this is t39's core assertion).
- **Never fight the user**: skip the entire pass if the crew window is zoomed
  (`#{window_zoomed_flag}`), and never move/resize/kill the currently active
  pane of an attached client. Skipped pass says why (`board: skipped (zoomed)`).
- **Debounce**: `--watch` sleeps ≥2s between passes and coalesces bursts.
- Board never answers prompts, never nudges, never touches task state — layout
  only.

### 2.3 Acceptance (t39)

Fixture-driven (mock workers as in t37): embed-missing, pop-dead,
promote-on-review, idempotent second pass, zoom-skip.

## 3. T-C — review on demand + chip trust (`lib/review.sh`, `lib/tools.sh`)

### 3.1 review

- `bench review <id>`: diffstat vs base + expected-files surface check +
  receipt. NO lazygit, NO pane spawning. Receipt ends with the exact next
  commands: `bench review <id> --tui` (lazygit) and `bench watch <id>` (diff).
- `bench review <id> --tui`: opens lazygit on the task's branch in the deck's
  right side ON DEMAND; pane closes when lazygit quits. This is the only thing
  that ever occupies the deck's right side, and only when asked.

### 3.2 chips (`status --tmux` rendering in lib/tools.sh)

- Orange is reserved for signature-confirmed prompts (`!`).
- Bare silence (`?`) renders DIM (default-ish fg, no orange) — visible if you
  look, never shouting. The `!`/`?` detection logic itself doesn't change.
- Chip click behavior unchanged (left jump; T-A adds right-click menu).

### 3.3 Acceptance (t40)

Review prints diffstat + check without spawning panes (assert no new pane in
deck); `--tui` path exercised headless as far as testable (lazygit presence
already gated by doctor); chip line renders `!` orange and `?` without orange
(assert on the emitted format string).

## 4. Pre-wired on main before spawn (orchestrator, this commit)

- `bin/bench`: dispatch + usage entries for `menu` and `board`, calling
  `cmd_menu`/`cmd_board` in the stub libs (stubs die with "not implemented —
  see docs/nav_wave_spec.md §N" until their task lands).
- `tests/run.sh`: three delimited reserved blocks (t38/t39/t40) before the
  summary; each worker edits ONLY its own block. tests/run.sh is otherwise a
  shared surface: merges are serial, and after each merge remaining workers
  rebase before continuing.
- `lib/state.sh` init template: allowlist gains `Read(./**)`, `Edit(./**)`,
  `Write(./**)`, `Read(~/.bench/**)` so future projects start prompt-free.
- SKILL.md (repo + ~/.claude copy): bare-Enter trust advice REMOVED — replaced
  with the §5 pre-trust mechanism. No agent answers prompts, ever.

## 5. Prompt-free workers (mechanism, user-granted)

- Folder trust: `~/.claude.json` → `projects."<git repo root>".hasTrustDialogAccepted:
  true`. Worktrees share the repo root, so one entry covers all of them
  (verified empirically on this wave's first spawn; if a worktree still
  prompts, `bench spawn` grows a pre-seed step keyed to the worktree path).
- Tool prompts: committed `.claude/settings.json` allow rules (Read/Edit/Write
  in-tree + `Read(~/.bench/**)` for task files). Worktree checkouts inherit
  the committed file.
- Both changes are approved and applied BY THE USER (`!` commands handed over
  by the orchestrator). Widening never ships in an agent commit.

## 6. Explicitly out of scope this wave

- Sonnet navigator: built AFTER T-B merges, as a skill + session that calls
  `bench board` — not part of any worker's task.
- Typing into a nested tile from the wall (F12 passthrough mode) — revisit
  only if jumping proves insufficient.
- tmux <3.7 compatibility shims. 3.7b is the floor on this machine.
- Spec §3.1 leftovers (`core new`, `focus`, `tab`, `open`, `review --annotate`).
