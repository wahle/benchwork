# Slice 1 interface contract

Binding for all slice-1 implementation work. The spec (`docs/bench_spec.md`) wins on
intent; this file pins the concrete seams so parallel implementers integrate cleanly.

## File ownership

| File | Owner | Contents |
|---|---|---|
| `bin/bench` | integrator | dispatcher only (done) |
| `lib/common.sh` | integrator | shared helpers (done — read it, use it, do not edit) |
| `lib/state.sh` | state-engine agent | `cmd_init`, `cmd_task_new`, `cmd_task_set`, `cmd_status` |
| `lib/tmuxops.sh` | tmux-layer agent | `cmd_up`, `cmd_spawn` |
| `tests/run.sh`, `tests/mock-claude`, `docs/test_plan.md` | test-harness agent | executable test plan |

Line budget (spec §0: ≤400 total for the tool): state.sh ≤130, tmuxops.sh ≤85.
Tests/docs don't count against the budget. Bash only, must run under `set -euo pipefail`,
no jq/yq/python dependencies inside `bench` itself (tests MAY use jq — it is installed).

## Shared helpers (lib/common.sh — already written)

`die`, `now_iso`, `btmux` (tmux wrapper honoring `$BENCH_TMUX_SOCKET`), `repo_root`,
`project_name` (`$BENCH_PROJECT` override, else basename of git toplevel), `state_dir`,
`conf_get key [default]`, `norm_id` (42|T-42→T-042), `task_file`, `task_num`,
`fm_get file key`, `fm_set file key value` (atomic temp+mv), `state_commit msg`.

## Environment variables

| Var | Default | Purpose |
|---|---|---|
| `BENCH_HOME` | `~/.bench` | state root (tests override) |
| `BENCH_PROJECT` | basename of repo toplevel | project name override |
| `BENCH_TMUX_SOCKET` | unset (default tmux server) | test isolation via `tmux -L` |
| `BENCH_CLAUDE` | `claude` | worker command (tests point at mock-claude) |
| `BENCH_STALE_SECS` | `1200` | staleness threshold (test 4 uses `10`) |

## project.conf (flat key=value, written by `init`)

```
repo=/abs/path/to/repo
base=<branch at init time, e.g. main>
model=opus
port_base=3000
setup=            # optional command run inside a fresh worktree
copy_files=       # space-separated untracked files copied repo→worktree (e.g. .env)
worktree_root=    # optional dir for worktrees; default = dirname(repo)
```

## Verb behaviors

### `init`
Run from inside the target repo. Creates `state_dir` with `project.conf`, `tasks/`,
`archive/`; `git init -q` + initial `state_commit`. Allowlist (spec §5): writes
`<repo>/.claude/settings.json` directly when the repo has none (create-if-absent —
commit it to base so worker worktrees inherit it); if one exists without bench's
entries (`grep 'bench task set'`), emits `.claude/settings.json.bench-suggested`
instead — never overwrites or merges an existing settings.json. Idempotent: re-run
repairs missing pieces, never clobbers an existing project.conf.

### `task new "title" [--files <glob>...]`
Next id = max numeric id across `tasks/` AND `archive/`, +1, zero-padded 3 (T-001).
Writes the §1.2 schema exactly; frontmatter keys in this order:
`id,title,status,branch,worktree,model,port,question,updated`.
status=pending, branch=agent/T-###, worktree left empty (spawn fills it),
model=conf model, port=port_base+num, question empty, updated=now_iso.
Body sections: `## Goal` (placeholder), `## Expected files` (one `- glob` per --files
arg; `- **` whole-repo default if none — a *predicted diff surface*, advisory, checked
at review in slice 2, never a write boundary; see spec A.14), `## Acceptance criteria`
(`- [ ] TBD`), `## Feedback` (empty).
Atomic write (temp+mv), `state_commit "task new T-###: title"`, **print the file path**
(path is the last line of stdout; a human line before it is fine).

### `task set <id> <key> <value>`
`fm_set` the key, always also `fm_set updated $(now_iso)`,
`state_commit "task set T-###: key=value"`. Unknown keys are allowed (forward compat).
Value may contain spaces (`"$3"` onward joined with spaces — accept `"$*"` after shifts).

### `status [--tmux|--json|--tree|--stale]`
Read-only: task files + `git log` only — never tmux pane contents.
- **default**: human table, one row per task: `ID  STATUS  BRANCH  MODEL  PORT  TITLE`.
- **--json**: JSON array, one object per task:
  `{"id","title","status","branch","worktree","model","port":<num>,"question","updated","last_commit":<unix-epoch-or-null>,"stale":<bool>}`.
  `last_commit` = `git -C <repo> log -1 --format=%ct <branch> --` (null if branch absent).
  Emit with printf + a `json_esc` helper (escape `\` `"` and control chars); no jq inside bench.
- **--json --tree**: the Appendix-B contract every renderer consumes:
  ```json
  {"project":"<name>","session":"<name>","generated":"<iso>",
   "nodes":[{"type":"workbench","name":"<name>","children":[
     {"type":"worker","id":"T-042","status":"working","session":"bench-<project>-T-042",
      "alive":<bool>, ...same fields as --json objects}]}]}
  ```
  `alive` = worker tmux session exists (`btmux has-session`). Shape must be stable; cores
  appear later as additional child type `core`.
- **--stale**: print ids of tasks where status=working AND
  `now - max(taskfile mtime, last_commit) > BENCH_STALE_SECS`. Also mark `"stale":true` in json.
- **--tmux**: one line for the status bar: per task ` T-042 ●working` with tmux colour
  codes `#[fg=green]`(working) yellow(blocked) blue(review) grey(pending); glyphs
  ●working ⛔blocked ✓review ○pending, plain ASCII if `BENCH_ASCII=1`.

### `up`
Idempotent create-or-repair, navigator surface ONLY (Appendix B rule 4):
session named `$(project_name)` with window 1 renamed `deck`; create the `crew` window
if missing. Set `mouse on` (server-wide via `btmux set -g mouse on`). Do NOT spawn
workers/diffpane/lazygit. Second consecutive run must change nothing and exit 0 (test 1).
Never attach; print a hint (`tmux attach -t <name>`). Works when the server isn't
running yet (`btmux start-server` or create session detached handles it).

### `spawn <id>`
1. Task must exist and be `pending` (else die with a clear message).
2. Worktree path: `<worktree_root or dirname(repo)>/<project>-T-###`.
   `git -C <repo> worktree add -b agent/T-### <path> <base>` (if branch already exists,
   reuse it: `worktree add <path> agent/T-###`).
3. Copy each `copy_files` entry repo→worktree if present; run `setup` command in the
   worktree if non-empty (failure = warn, not fatal).
4. `task set` worktree=<path> (via cmd_task_set so audit trail is kept).
5. Launch the worker as a DETACHED tmux **session** (Appendix B rule 3), name
   `bench-<project>-T-###`, cwd = worktree, running:
   `$BENCH_CLAUDE --model <task model> "<spawn prompt>"`.
   Set session env first (`btmux set-environment -t <sess>`) — but note env set that way
   doesn't reach the initial command, so ALSO pass env inline:
   `BENCH_TASK_ID=… BENCH_TASKFILE=… BENCH_PORT=… BENCH_HOME=… BENCH_PROJECT=… BENCH_TMUX_SOCKET=… PATH=…`
   prefixed to the command. Keep the worker alive after command exit is NOT required —
   default remain-on-exit off is fine for slice 1.
6. Pane title: `btmux select-pane -t <sess>: -T "T-### · working"`.
7. Flip status: cmd_task_set status working (single state write path).
8. Print: session name + worktree path.

Spawn prompt = spec §4 template with {id},{branch},{worktree},{taskfile},{port}
substituted. Keep it in a heredoc in tmuxops.sh.

## tmux naming

- All tmux session names are sanitized via `tmux_safe` (common.sh): `.`, `:`, and
  spaces map to `_` — tmux rejects/rewrites them and targets misparse otherwise.
- project session = `tmux_safe(project name)`; windows `deck`, `crew`.
- worker session = `bench-<tmux_safe project>-T-###`. The `session` field in
  `status --json --tree` reports the sanitized (i.e. actual) session name.

## Post-validation amendments (v1.1, after adversarial review)

- `fm_set` forces values to a single line (newline→space) and passes them to awk
  via ENVIRON, not `-v` (so `\n` etc. stay literal). `task new` titles likewise.
- JSON output escapes `\` `"` tab cr; all other C0 control chars are **stripped**
  (valid JSON guaranteed; fidelity for pathological values is not a goal).
- Under concurrent writers, state-dir audit commits may coalesce (`.git/index.lock`
  contention): `task set` always exits 0 once the file write lands, and skipped
  `git add`/`commit` work is swept into the next state commit.
- `task set` serializes same-file writers with `flock` on `<state>/.git/bench.lock`
  (spec test 8: concurrent distinct-key writes both persist). Degrades to
  atomic-mv-only where flock is unavailable.
- `spawn` rolls back the worktree if the worker session fails to launch.

## Single-writer + atomicity rules (spec §1.2/A.1)

Every frontmatter write goes through `fm_set` (temp+mv). Every state change is followed
by `state_commit`. `bench` never derives state from pane contents.

## Test harness contract

`tests/run.sh` — standalone bash, no bats. Per run: fresh `mktemp -d` holding
BENCH_HOME + a fixture repo (git init, one commit, branch main); exports
`BENCH_TMUX_SOCKET=benchtest$$`, `BENCH_CLAUDE=<abs>/tests/mock-claude`,
`PATH=<repo>/bin:$PATH`. TAP-ish output (`ok 1 - …` / `not ok`), nonzero exit on any
failure, `trap` cleanup kills the test tmux server and removes temp dirs.
`tests/mock-claude` — accepts `--model X <prompt>`; uses `$BENCH_TASKFILE`/`$BENCH_TASK_ID`;
default behavior: write a file in the worktree, `git commit`, `bench task set <id> status review`,
then sleep 300 (keeps session alive for liveness checks). `MOCK_MODE=block` → set
`question` + status blocked instead. Must cover acceptance tests 1, 2, 4 (with
BENCH_STALE_SECS=10), 8, plus unit checks (id increment, fm_set atomicity under
concurrent writes, status --json validity via jq, --tree shape).
