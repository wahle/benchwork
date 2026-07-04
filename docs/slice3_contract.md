# Slice 3 interface contract — polish: tmux UX, needs-input, peek/doctor/clean, skill

Extends `docs/slice1_contract.md` + `docs/slice2_contract.md` (all their rules still
bind). Spec: `docs/bench_spec.md` §2, §3.1 (peek/doctor/clean rows), §3.2, §5,
§6 tests 3/9/10/11, Appendix B. Priorities (spec §0 rev): useful > elegant > simple >
extremely user- and agent-friendly; line count is a bloat tripwire, not a budget.
Actionable error messages; mutating verbs print receipts. Bash only,
`set -euo pipefail`-safe, no jq/yq/python inside bench (tests MAY use jq).

## File ownership

| File | Owner | Contents |
|---|---|---|
| `bench.tmux.conf` (new) | ux agent | the sourceable conf (§A below) |
| `lib/state.sh` (edit) | ux agent | status: needs-input + bell cache + `--refresh-titles` + click ranges; init: conf-source hint |
| `lib/tmuxops.sh` (edit) | ux agent | `_tx_launch`: monitor-silence; `cmd_up`: `@bench_repo` session option |
| `lib/tools.sh` (new, stub exists) | tools agent | `cmd_peek`, `cmd_doctor`, `cmd_clean` (+ `_tl_*` helpers) |
| `.claude/skills/bench-orchestrator/**` | skill agent | SKILL.md + references/ (§D below) |
| `tests/run.sh` (append t26+), `tests/mock-claude` (extend), `docs/test_plan.md` | test agent | §F below |
| `bin/bench` routes + usage | integrator | done — read, don't edit |

## New environment variables

| Var | Default | Purpose |
|---|---|---|
| `BENCH_SILENCE_SECS` | `60` | needs-input threshold: spawn's `monitor-silence` value AND status's fresh-commit window (test 11 overrides to 2) |
| `BENCH_TRANSCRIPT_HINTS` | unset | `=1` enables the transcript-tail hint (spec §5 layer 2.5) |
| `BENCH_ASCII` | unset | existing — `=1` swaps glyphs for ASCII everywhere (conf + chips) |

## A. `bench.tmux.conf` (ux agent)

Sourced from the user's `~/.tmux.conf`. Global options are acceptable (that is the
spec's design); bench segments render empty in non-bench sessions because
`@bench_repo` is unset there. Contents, pinned:

- `set -g mouse on`
- Hotkeys — the COMPLETE surface, do not add more (spec A.9/A.10):
  `M-1`→`select-window -t deck`, `M-2`→`select-window -t crew`,
  `M-Left/Right/Up/Down`→`select-pane -LRUD`, `M-z`→`resize-pane -Z`,
  `M-r`→`refresh-client -S`,
  `M-Space`→`command-prompt -p "bench>" { run-shell 'cd "#{@bench_repo}" && bench %1' }`.
- Status bar: `status-interval 5`, `status-right-length 150`,
  `status-right '#(cd "#{@bench_repo}" 2>/dev/null && bench status --tmux --refresh-titles)'`,
  status-left shows `⚒ <session>` (plain `bench` text if `$BENCH_ASCII` set at source
  time — `if-shell`).
- Click-to-watch (tmux ≥3.4): chips arrive wrapped in `#[range=user|task_<id>]…#[norange]`
  (emitted by `status --tmux`, see §B); bind
  `bind -Troot MouseDown1StatusRight if -F '#{m:task_*,#{mouse_status_range}}' { run-shell 'cd "#{@bench_repo}" && bench watch "#{s/task_//:mouse_status_range}"' }`.
- Bells visible: `setw -g monitor-bell on`, `set -g bell-action any`, visual-bell off.
- Borders: `setw -g pane-border-status top`; pane-border-format shows `#{pane_title}`
  for worker panes but something sensible (e.g. current command) where the title is
  still the default hostname; dim inactive border style, accent active border.
  (tmux 3.4 has no rounded *pane* border lines — use single; do not fake it.)
- Marker for doctor: `set -g @bench_conf 1`.
- Must parse clean: `tmux -f bench.tmux.conf -L <tmpsock> start-server \; kill-server`.

`cmd_init` and `cmd_doctor` both print the enable hint when the conf isn't sourced:
`echo 'source-file <BENCH_ROOT>/bench.tmux.conf' >> ~/.tmux.conf` (BENCH_ROOT is set
by bin/bench).

## B. status: needs-input, bell, titles, click ranges (ux agent, lib/state.sh)

### needs-input (spec §5 layers 2/2.5/3 — ALL advisory: chips/json only, NEVER state)

- `_tx_launch` (tmuxops.sh) sets `monitor-silence ${BENCH_SILENCE_SECS:-60}` on the
  worker session's window after `new-session` (spawn AND resume get it).
- `_st_load` computes `needs_input` (true/false):
  status==`working` AND session alive AND `#{window_silence_flag}`==1 (via
  `btmux display-message -p -t "=$session:"`, `|| true`-guarded) AND no fresh commit
  (`last_commit` empty OR `now - last_commit > BENCH_SILENCE_SECS`).
- Confidence upgrade (layer 3), evaluated ONLY when the silence gate already fired:
  `capture-pane -p` tail (~15 lines) grepped for prompt signatures
  (`Do you want`, `❯`, numbered options `^[[:space:]]*[0-9]+[.)]`). Match →
  `needs_input_confirmed=true`.
- Transcript hints (layer 2.5), evaluated at the same point ONLY when
  `BENCH_TRANSCRIPT_HINTS=1`: helper `_st_transcript_hint <worktree>` looks in
  `~/.claude/projects/<worktree path with / and . → ->/` for the newest `*.jsonl`,
  crude tail check (no jq) for a trailing unresolved tool_use. Returns 0 = hint.
  MUST fail silent-and-safe on any unrecognized shape (every path `|| true`; wrong
  never worse than "no hint"). A hint also sets `needs_input_confirmed=true`.
- Surfacing: `--json` and `--tree` objects gain `"needs_input":<bool>` (after
  `"stale"`). `--tmux` chip for a flagged task: whole chip orange `colour208`,
  glyph `?` (silence only) or `!` (confirmed), e.g. `#[fg=colour208]T-042 ?working#[default]`.
  Default human table: unchanged. State transitions: never.

### Bell on transitions (acceptance 3)

- Cache file `$(state_dir)/.git/bench.lastseen` (in `.git/` so audit commits never
  sweep it). One line per task: `<id> <status> <needs01>`. Rewritten atomically
  (temp+mv) on every `status --tmux` run, under the same `flock` on
  `$(state_dir)/.git/bench.lock` (reuse, don't invent another).
- Bell fires when, vs the cached line: status changed AND new status ∈
  {blocked, review}; OR needs_input went 0→1. A task with NO cached line that is
  already blocked/review/needs-input also bells (fresh cache after restart: things
  needing attention still ding).
- Mechanism (must work detached — prove in tests): write BEL to the crew pane's tty:
  `printf '\a' > "$(btmux display-message -p -t "=<proj sess>:crew" '#{pane_tty}')"`,
  fully `|| true`-guarded; skip silently when the project session/crew window is
  absent. (Escape hatch if the tty write provably fails to set
  `#{window_bell_flag}` in the harness: `send-keys -t "=<sess>:crew" C-g` — pick
  whichever the test proves, document the choice in a comment.)
- Bell + cache update happen ONLY in `--tmux` runs (the 5s heartbeat), not `--json`.

### `status --refresh-titles`

- For each task whose worker session is alive:
  `btmux select-pane -t "=$session:" -T "<id> · <status>"`.
- Alone: prints a receipt (`retitled N worker pane(s)`). Combined with `--tmux`:
  silent side effect, stdout stays the single chip line (the conf uses the combined
  form so borders stay fresh for free).

### Click ranges

- `--tmux` wraps each chip in `#[range=user|task_<id>]…#[norange]` — but only when
  the running tmux is ≥3.4 (helper parses `btmux -V`; non-numeric versions like
  "next-3.5" count as ≥3.4). Below 3.4: plain chips, no ranges (degrade to no-op).

## C. `lib/tools.sh` — peek / doctor / clean (tools agent)

A stub with the three `cmd_*` names exists; replace its bodies. Use `require_task`,
`worker_session`, `conf_get`, `btmux`, `die` from common.sh/tmuxops.sh.

### `peek <id> [-n N]` (default 30)

Human convenience only — never used for state. `require_task`; worker session alive
or die pointing at `bench resume <id>` (archive-aware comes free from require_task).
Print a one-line header (`── T-042 · <sess> — last N lines ──`), then
`capture-pane -p -S -` of the worker pane piped through `tail -n N`, trailing blank
lines trimmed. `-n` may appear before or after the id.

### `doctor`

Diagnose, don't mutate. One line per check: `ok|warn|FAIL <what>` and, for
warn/FAIL, ` — <exact next command>` on the same line. Checks, in order:

1. tools: tmux, git, lazygit, diffpane, `$BENCH_CLAUDE` (claude) on PATH. Missing
   lazygit/diffpane = warn (state the degraded behavior + install hint); missing
   tmux/git = FAIL.
2. tmux ≥3.4 (else warn: click-to-watch disabled).
3. mouse on (`btmux show -gv mouse`), only when a server is running; else skip.
4. state dir: exists + is a git repo (else FAIL — `bench init`); project.conf
   readable and its `repo=` path exists; no `.fm.*` temp files in tasks|archive
   (half-written write = warn + the rm command).
5. orphaned worktrees: `git worktree list --porcelain` entries matching
   `<proj>-T-*` whose task id has no file in `tasks/` → warn, fix = `bench clean`.
6. conf sourced: if a server is running and `btmux show -gv @bench_conf` is empty →
   warn with the §A source-file hint.
7. transcript hints: only when `BENCH_TRANSCRIPT_HINTS=1` — report whether
   `~/.claude/projects` exists and the newest transcript looks familiar
   (`warn: enabled but format unfamiliar — hints will stay silent` otherwise).

Exit 0 when everything is ok/warn; exit 1 only on a FAIL (tmux/git missing, state
dir broken/missing). Acceptance test 10: missing diffpane → clear actionable line,
everything else still checked, exit 0.

### `clean`

Prune leftovers; receipt like `done`'s (aligned `<thing>  <action>  <detail>` lines),
or `nothing to clean — workbench is tidy` when no-op. Steps:

1. Kill worker sessions `bench-<proj>-T-*` whose task id is not in `tasks/`.
2. Remove registered worktrees matching `<proj>-T-*` whose task id is not in
   `tasks/` (`git worktree remove --force`, tolerate failure), then
   `git worktree prune` (always).
3. Delete branches `agent/T-###` whose task is archived with status `merged`
   (abandoned tasks KEEP their branch — salvage rule; unknown ids keep theirs).
4. Remove `.fm.*` temp files older than 60s in tasks/ and archive/.
5. `state_commit "clean"` only if anything actually changed.

## D. Skill `.claude/skills/bench-orchestrator/` (skill agent)

- `SKILL.md` ≤150 lines. Frontmatter `name: bench-orchestrator` and the pushy
  `description:` quoting spec §3.2's wording ("Use this skill whenever the user asks
  to parallelize work, spawn workers/agents, check on tasks, review or merge agent
  work, or says anything like 'crew', 'workers', 'spin up', 'what's the status',
  even if they don't say 'bench'."). Body: the full verb table (§3.1 rows that exist
  today: init, up, task new/set, spawn, status + flags, watch, peek, review, done,
  abandon, nudge, resume, doctor, clean), the 7-step operating loop verbatim from
  §3.2, the single-writer rules, needs-input reading guidance (`needs_input` in
  `--json` is advisory — peek/nudge, never assume), and "never merge without human
  approval".
- `references/spawn-prompt.md`: the §4 template with the `{id}` etc. placeholders
  explained, plus a note that `bench spawn` fills it automatically (the reference
  exists so the orchestrator understands what workers were told).
- `references/task-schema.md`: the §1.2 frontmatter contract (fields, allowed
  status values, key order), single-writer table, Expected-files semantics per
  A.14 (prediction, not boundary; review warns, never blocks).

## F. Tests (test agent — tests/run.sh t26+, mock-claude, docs/test_plan.md)

Extend the ONE harness; keep total runtime under ~2 min; every test isolated on the
private socket/scratch home already established. New mock-claude mode
`prompt` (frontmatter channel `bench task set <id> mockmode prompt`): print a
permission-prompt lookalike —

```
Do you want to allow this tool call?
  1. Yes
  2. No
❯
```

then block on `read -r` (no commit, no status change).

- **t26 conf lint**: `command tmux -f "$REPO/bench.tmux.conf" -L "conflint$$" start-server \; kill-server`
  exits 0 with empty stderr (use `command tmux`, NOT btmux — separate throwaway socket).
- **t27 acceptance 3 (bell)**: spawn a `block`-mode worker; poll status blocked;
  run `bench status --tmux`; assert crew `#{window_bell_flag}` == 1 and the chip is
  yellow/⛔. Then a second `--tmux` run does NOT re-bell (clear the flag first via
  `select-window`/`kill the flag` — document how the flag is reset in the test).
- **t28 acceptance 11 (needs-input)**: `BENCH_SILENCE_SECS=2`, spawn a `prompt`-mode
  worker; within 15s `status --json` has `needs_input==true` for it (jq), `--tmux`
  chip contains colour208 and `!` (prompt signature should confirm). Negative: a
  fresh `idle` worker with `BENCH_SILENCE_SECS` at default is `needs_input==false`.
- **t29 refresh-titles**: spawn idle worker; `bench task set` a status; run
  `status --refresh-titles`; `#{pane_title}` of the worker session ==
  `T-0xx · <status>`; receipt names the count. Combined `--tmux --refresh-titles`
  output is still a single line.
- **t30 peek**: `prompt`-mode worker; `bench peek <id>` output contains
  `Do you want`; `-n 5` returns ≤5 content lines + header; peek on a dead session
  dies naming `bench resume`.
- **t31 doctor**: green run exits 0; with diffpane hidden from PATH → exit 0, line
  matching diffpane + an install/degrade hint, other checks still present (test 10);
  doctor before init (fresh BENCH_HOME/project) exits 1 naming `bench init`.
- **t32 clean**: manufacture an orphan (spawn idle, kill its session, `mv` its task
  file to archive/ + fm_set status merged — simulating a crash mid-done); `bench clean`
  → worktree gone, branch gone, receipt lines name both; second `clean` prints
  `nothing to clean`. An abandoned task's branch survives clean.
- **t33 click ranges**: `status --tmux` output contains `#[range=user|task_T-` and
  `#[norange]` (tmux here IS 3.4).
- `--json` needs_input key: extend the t8-style key check (`has("needs_input")`,
  type boolean).
- docs/test_plan.md: document t26+ AND the manual acceptance-9 check (VS Code
  integrated terminal: attach, mouse focus, status bar, Alt keys — step-by-step).

## Integration & validation (integrator)

Full suite green + `shellcheck -s bash bin/bench lib/*.sh` clean before commit.
Adversarial validator pass after integration (0-findings bar: BLOCKER/BUG; UX nits
are findings too — fix, don't log). Then the dogfood README task (handoff §E),
artifact update, commit + push.

## Gotchas (inherited — will cost you an hour each if ignored)

- awk values via `ENVIRON`, never `-v`. All frontmatter writes via `fm_set`.
- tmux names via `tmux_safe`/`worker_session`; all tmux via `btmux`.
- Same-file/pane serialization: flock on `$(state_dir)/.git/bench.lock` — reuse it.
- mock behavior via per-task `mockmode` frontmatter, not env vars.
- Test ONLY in throwaway env: mktemp BENCH_HOME, private BENCH_TMUX_SOCKET,
  BENCH_CLAUDE=tests/mock-claude. Never the real ~/.bench or default tmux server.
- `bench status` run by tmux `#()` has no repo cwd — that's what `@bench_repo` fixes.
