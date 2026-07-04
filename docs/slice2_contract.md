# Slice 2 interface contract — review/merge path

Extends `docs/slice1_contract.md` (all its rules still bind). Spec: `docs/bench_spec.md`
§3.1 (watch/review/done/abandon/nudge/resume rows), §7 slice-2 line, A.5, A.8, A.12, A.14.

## File ownership

| File | Owner | Contents |
|---|---|---|
| `lib/review.sh` | review-merge agent | `cmd_review`, `cmd_done`, `cmd_abandon` (+ `_rv_*` helpers) |
| `lib/tmuxops.sh` (append) | session-verbs agent | `cmd_watch`, `cmd_nudge`, `cmd_resume` (+ `_tx_*` helpers; may factor spawn's launcher) |
| `tests/run.sh` (append), `tests/mock-claude` (extend), `docs/test_plan.md` | test-harness agent | tests 15+ |
| `bin/bench`, `lib/common.sh` | integrator | routes + `task_globs` (done — read, don't edit) |

**Line budgets RELAXED** (user decision 2026-07-04): size is no longer a constraint.
Priorities in order: useful, elegant, simple, extremely user- and agent-friendly —
actionable error messages, clear receipts of what a verb did, friendly confirmations.
Bash only, `set -euo pipefail`-safe, no jq/yq/python inside bench.

## New shared helper (common.sh, done)

`task_globs <taskfile>` — prints the glob per line from `## Expected files`
(leading `- ` and trailing inline comments stripped). May print `**`.

## Verb behaviors

### `watch <id>`
1. Task must exist; `worktree` frontmatter must point at an existing dir (else die).
2. Project session must exist (else die: "run 'bench up' first").
3. The diff pane is the pane in window `deck` whose tmux pane option `@bench_role`
   is `diffpane` (`btmux list-panes -t "=<sess>:deck" -F '#{pane_id} #{@bench_role}'`).
   If present: `btmux respawn-pane -k -t <pane_id> -c <wt> <cmd>`.
   If absent: `btmux split-window -d -h -t "=<sess>:deck" -c <wt> <cmd>` then
   `btmux set-option -p -t <new_pane_id> @bench_role diffpane` (get the id via
   `split-window -P -F '#{pane_id}'`).
4. `<cmd>`: `diffpane` if `command -v diffpane`, else fallback
   `watch --color -n 2 git -c color.ui=always diff <base>` (live diff of the
   worktree vs base, refreshed every 2s — degrades per acceptance test 10; print
   a one-line note when falling back).
5. Print which worktree the pane now follows. Never touches task state.

### `review <id>`
1. Task + worktree must exist. Read-only on task state (status is NOT changed).
2. Print `git -C <repo> diff --stat <base>...agent/<id>` (branch vs merge-base).
3. **Expected-files check (A.14 detective control)**: for each file from
   `git -C <repo> diff --name-only <base>...agent/<id>`, match against every glob
   from `task_globs` using bash `[[ $file == $glob ]]` (extglob not needed; `*`
   spans `/` in this context). Files matching NO glob → print a warning block:
   `⚠ outside expected surface:` + one path per line. No matches → print nothing
   extra. Advisory only — never blocks, never changes state.
4. If `lazygit` is on PATH and the project session exists: show lazygit for the
   worktree in the deck window's review pane — same @bench_role pattern as watch,
   role value `review`, command `lazygit -p <wt>`. If lazygit missing, print
   `lazygit not installed — diffstat only` and still succeed.

### `done <id> [--yes]`
1. Task must exist, status must be `review` (any other status: die naming the
   status; `--yes` does NOT override this gate — it only skips the prompt).
2. Repo must currently be on `<base>` (`git -C <repo> rev-parse --abbrev-ref HEAD`)
   and clean (`git -C <repo> diff --quiet HEAD`) — else die with what to do.
3. Confirm `merge <id> into <base>? [y/N]` on stdin unless `--yes` (abort cleanly
   on anything but y/Y).
4. `git -C <repo> merge --squash agent/<id>` then
   `git -C <repo> commit -m "<id>: <title>"`. On merge failure:
   `git -C <repo> reset --merge` and die "conflict — rebase the worker first
   (bench nudge <id> ...)".
5. Cleanup: kill worker session if alive; `git -C <repo> worktree remove --force <wt>`
   (tolerate already-gone); `git -C <repo> branch -D agent/<id>`;
   `git -C <repo> worktree prune`.
6. Archive: fm_set status=merged + updated, `mv` task file tasks/ → archive/,
   single `state_commit "done <id>"`. (Direct fm_set is fine here — cmd_task_set
   would re-commit twice; keep it one atomic archive step.)
7. Serial-merge convention: after success, list every OTHER task with status
   `working`, printing for each:
   `next: bench nudge T-0xx "base updated; rebase onto <base> and re-run tests"`.

### `abandon <id>`
Kill worker session if alive; `git -C <repo> worktree remove --force <wt>` +
`worktree prune` (tolerate missing); archive with status=abandoned (same
mechanism as done step 6); **keep the branch** (work may be salvaged). No prompt.

### `nudge <id> "text"`
Worker session must be alive (else die suggesting `bench resume`). Two sends,
100 ms apart (spec §3.1 interactive-TUI paste quirk):
`btmux send-keys -t "=<sess>:" -l -- "$text"`, `sleep 0.1`, `btmux send-keys -t "=<sess>:" Enter`.
Values may contain spaces — join `$2...` with `"$*"` after shift.

### `resume <id>`
1. Task must exist; worktree dir must exist (else die: suggest re-`spawn` after
   `bench task set <id> status pending`).
2. If worker session alive: print "already running: <sess>", exit 0.
3. Else launch detached session (same name/env/quoting pattern as spawn) in the
   worktree running: `$BENCH_CLAUDE --continue` and, if that exits nonzero,
   falling back to a fresh `$BENCH_CLAUDE --model <model> "<spawn prompt>"` —
   i.e. the pane command is `sh -c '<continue-cmd> || <fresh-cmd>'` built with
   printf %q. Reuse/factor spawn's env-prefix + prompt helpers rather than
   duplicating them.
4. Do not change status (the task file is the durable context; worker re-reads it).
5. Print session name.

## mock-claude extensions (test-harness agent)

- Accept `--continue` as first arg (no `--model`): behave per MOCK_MODE as usual.
- New `MOCK_MODE=listen`: `read -r line` from stdin; append `$line` to
  `nudges.log` in cwd; then sleep 300. (Enables the nudge test: send-keys text
  lands on the pane's stdin.)

## New tests (15+, keep total runtime < 2 min)

- **Acceptance 5** (watch): after `bench watch T-A`, deck window has exactly one
  pane with @bench_role=diffpane and `#{pane_current_path}` == T-A's worktree;
  after `bench watch T-B`, same pane id now has T-B's worktree path.
- **review**: diffstat contains the file the mock committed; surface check —
  worker commit inside globs → no warning; commit a file outside the globs on the
  branch → warning names it. review exits 0 in both cases; status unchanged.
- **Acceptance 6** (done): task set to review, `bench done T-x --yes` → squash
  commit on base (`git log -1 --format=%s` == "T-x: <title>"), worktree gone,
  `git worktree list` clean, branch deleted, task file in archive/ with
  status=merged, state-dir log has "done T-x". Also: done on a working task dies;
  done with dirty base repo dies.
- **Acceptance 7** (resume): spawn MOCK_MODE=idle, `kill-server`, `bench up`,
  `bench resume T-x` → worker session exists again, task file intact
  (status still working), `resume` again prints already-running.
- **nudge**: spawn MOCK_MODE=listen, `bench nudge T-x "hello world"` → within 5s
  worktree/nudges.log contains "hello world". nudge on dead session dies.
- **abandon**: worktree gone, branch STILL exists, archive/ has status=abandoned.
- **done serial-merge hint**: with a second task still working, done output
  contains `bench nudge` suggestion naming it.
