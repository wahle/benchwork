# bench — mouse navigation cheatsheet

bench is mouse-first: a hand on the mouse reaches every worker without
memorizing a hotkey. This is what each gesture does. Nothing here routes
through the LLM — navigation is deterministic tmux. Requires
`bench.tmux.conf` sourced (see the repo README's "tmux styling"), tmux ≥3.7,
and at least one worker running.

## Gestures

| Gesture | What happens |
|---|---|
| **Left-click a status-bar chip** | Focuses that worker (`bench focus`): its crew tile zooms full-window, fully interactive — answer prompts right there. The status bar stays visible; double-click the tile (or `Alt+z`) to shrink back to the wall. |
| **Right-click a status-bar chip** | Opens that task's context menu (`bench menu`) — the same menu the tiles use. |
| **Right-click a crew tile** | Opens the tile's context menu: Jump into worker · Watch diff · Peek · Nudge… · Review · Pop/Embed tile. |
| **Click the `[≡]` on a tile's border** | Same tile menu — the glyph is just a clickable target for it. |
| **Double-click a crew tile** | Zooms the tile full-window; double-click again restores. |
| **`prefix + m`** | Keyboard equivalent of the tile menu, for the *focused* crew tile. Focus one first: `Alt+2`, then arrow keys. |
| **`Alt+g`** | Task palette (fzf over all tasks): Enter jumps into the worker, `Ctrl-w` watches its diff, `Ctrl-o` peeks. |
| **`Alt+2`** | Jump to the crew window (the wall of worker tiles). `Alt+1` jumps back to the deck. |

Every menu entry shows its one-key shortcut in the right column, so the mouse
menu doubles as a keyboard reference.

## When clicks do nothing

Work down this list — most "dead clicks" are one of these:

- **No workers running.** Chips and tiles are clickable *targets*; with nothing
  spawned there is nothing to click. Run `bench status` to confirm, `bench spawn
  <id>` to get a worker on the wall.
- **Windows Terminal + Shift.** Holding **Shift** while clicking does native
  terminal text-selection and *bypasses* tmux's mouse mode entirely. Click
  *without* Shift to hit these bindings; hold Shift only when you actually want
  to select text.
- **tmux older than 3.7.** The `[≡]` glyph rides on `control|N` click ranges,
  which need **tmux ≥3.7**. Tile right-click menus and double-click zoom work
  from 3.3; chip click-to-jump from 3.4. Check with `tmux -V`.
- **Conf not sourced.** No status bar or hotkeys means `bench.tmux.conf` isn't
  loaded. Load it into the running server with
  `tmux source-file /path/to/benchwork/bench.tmux.conf`, and add that
  `source-file` line to your `~/.tmux.conf` so it sticks.
- **Still stuck?** Run **`bench doctor`** — it checks tmux version, mouse mode,
  and whether the conf is sourced, and prints the exact fix for each.

## `bench board` — the self-arranging wall

`bench board` runs one relayout pass over the crew window from task status
(`bench status --json`), so you rarely arrange tiles by hand:

- **Embeds** any live `working`/`blocked`/`review` worker that has no tile yet,
  and **pops** tiles whose task merged/abandoned or whose session died.
- **Promotes** a `review` or confirmed needs-input (`!`) worker to the big main
  pane (`main-vertical`); otherwise settles everything to an even `tiled` grid.
- It **never fights you**: a pass skips entirely when the crew window is zoomed,
  and never moves, resizes, or kills the pane you're actively in.

`bench board --watch` loops this on a debounce. A pass that changes nothing is
silent; every action it takes prints a one-line receipt.
