# bench slice-1 test plan

Standalone bash harness (no bats) asserting the behaviours pinned in
`docs/slice1_contract.md` and the acceptance tests in `docs/bench_spec.md` §6.

## How to run

```
tests/run.sh
```

Exits `0` iff every assertion passes; TAP-ish output (`ok N - desc` /
`not ok N - desc`, `1..N` plan, `# passed X, failed Y` summary). Runtime ~3–4 s.

### Isolation (nothing touches your real environment)

Each run creates a fresh `mktemp -d` holding `BENCH_HOME` and a throwaway fixture
git repo (`git init -b main`, one real commit), and exports:

| Var | Value |
|---|---|
| `BENCH_HOME` | `$WORK/home` |
| `BENCH_TMUX_SOCKET` | `benchtest$$` (private tmux server via `tmux -L`) |
| `BENCH_CLAUDE` | `tests/mock-claude` (never a real model) |
| `PATH` | `<repo>/bin:$PATH` |
| `GIT_*_NAME/EMAIL` | test identity, so worktree/state commits work |

An `EXIT`/`INT`/`TERM` trap kills the private tmux server, removes its (dead)
socket inode, prunes worktrees, and `rm -rf`s the temp dir (worktrees live under
it). Requires: `tmux` (≥3.4 tested), `git`, `jq` (tests only — `bench` itself uses
no jq), `bash`.

## tests/mock-claude

A `claude` stand-in launched by `bench spawn` exactly as it would launch claude
(`--model X "<prompt>"`), cwd = the worktree. It reads `BENCH_TASK_ID` /
`BENCH_TASKFILE` / `BENCH_PORT` from env and finds `bench` on `PATH`. Behaviour
mode resolves as **`$MOCK_MODE` → `mockmode:` key in the task file → `default`**:

- **default** — append a line to `worker.txt`, git-commit it, `bench task set <id>
  status review`, then `sleep 300` (stays resident so liveness / `--tree.alive`
  checks see a live session).
- **block** — `bench task set <id> question …` + `status blocked`, then sleep.
- **idle** — sleep only; no commit, no status change (drives stale detection).
- **listen** (slice 2) — `read -r` one line from stdin (a `bench nudge` send-keys
  lands there), append it to `nudges.log` in cwd (the worktree), then sleep. Lets
  the nudge test observe delivery without inspecting pane contents.

`resume` launches the worker as `<env> mock-claude --continue` (no `--model`); the
mock accepts `--continue` and still dispatches on the resolved mode, so a resumed
`idle`/`listen` worker behaves the same as a fresh launch.

Why the `mockmode:` frontmatter channel instead of a `MOCK_MODE` env var: the real
`spawn` forwards only the documented `BENCH_*` vars + `PATH` inline into the worker
command, so a `MOCK_MODE` set on the spawning process never reaches the worker.
`BENCH_TASKFILE` *is* forwarded, so tests select behaviour with `bench task set
<id> mockmode <mode>` before spawning. Before any status write the mock waits for
`spawn` to flip the task to `working` (its post-launch step 7), matching a real
worker's latency so its own status write isn't clobbered.

## Test inventory

| # (ok lines) | Group | Asserts |
|---|---|---|
| 1–9   | t1 `init` | state dir + `project.conf` + `tasks/` + `archive/` + `.git` created; ≥1 commit; re-run exits 0 and leaves `project.conf` byte-identical (idempotent, no clobber). |
| 10–16 | t2 `task new` | last stdout line is a path to an existing file; first task `id=T-001 status=pending port=3001 branch=agent/T-001`; second task increments to `T-002`/`port 3002`. |
| 17–20 | t3 `up` (**Acceptance 1**) | `up` run twice; second exits 0 and `list-windows` is byte-identical across the re-run; `deck` + `crew` windows exist. |
| 21–26 | t4 `spawn` (**Acceptance 2**) | worktree dir exists; `git worktree list` shows it on `agent/T-001`; status flipped to `working` (idle worker, so it stays observable); worker tmux session `bench-fixture-T-001` exists; state-dir git log has the spawn commits. |
| 27–29 | t5 worker loop | a default worker, spawned into tmux, commits on its branch and flips status to `review` within 15 s (polled) — proves it really ran `bench` from inside the session. |
| 30–33 | t6 `task set` (**Acceptance 8**) | sequential back-to-back writes on two keys both persist; the two backgrounded concurrent writes are waited on and asserted to **exit 0** (was unchecked — masked G2 below); concurrent (`&`+`wait`) writes leave exactly one frontmatter pair and a still-parseable file. A `# diag:` line reports whether both concurrent values survived (see "Interpretations"). |
| 34–35 | t7 `--stale` (**Acceptance 4**) | with `BENCH_STALE_SECS=1`, an idle working worker is listed after 2 s; a freshly-updated working task is not. |
| 36–45 | t8 `status` | `--json` parses (jq), has the contract keys, `port` is a number; `--json --tree` parses, root node `type==workbench`, worker child `session=="bench-fixture-T-00X"` with boolean `alive`; `--tmux` is one nonempty line; a blocked task shows yellow/`⛔`. |
| 46    | t9 `task set` spaces | a value containing spaces persists intact. |

### Regression tests (added after adversarial validation of the fixes in `lib/`)

| # (ok lines) | Group | Asserts |
|---|---|---|
| 47–50 | t10 dotted project name (was **B1**) | a repo dir named `my.app`: `bench up` twice both exit 0 and the second is a byte-identical no-op; an idle worker's `status --json --tree` reports `session=="bench-my_app-T-001"` (`.`→`_` via `tmux_safe`) with `alive==true`. |
| 51–56 | t11 frontmatter injection (was **B2**) | `task set title "evil\n---\nHIJACKED"` leaves exactly two `---` fence lines, `status`/`branch`/`port` still parse, and the newline is collapsed to a space in the stored title; a literal `a\nb` (backslash-n text) is stored verbatim as those 4 chars (`fm_set` passes values via `ENVIRON`, not `awk -v`). |
| 57–58 | t12 control chars (was **G1**) | a title containing C0 controls (`ESC`, `BEL`) keeps both `status --json` and `--json --tree` valid JSON (jq parses) — controls other than tab/cr are stripped from JSON output. |
| 59–63 | t13 concurrent writers (was **G2**) | 5 concurrent `task set <distinct-id> status working &`: each backgrounded call's rc is captured and asserted 0; all 5 files persist `status=working` with intact frontmatter; state-dir `HEAD` exists and the working tree is clean afterwards (audit commits may coalesce under `index.lock`, so this asserts everything landed in *some* commit, not one-commit-per-change). |
| 64–67 | t14 spawn rollback (was **N2**) | a forced worker-launch failure (`new-session` fails via a read-only `TMUX_TMPDIR` socket dir, which is reached *after* worktree add — past the existing-session guard) makes spawn fail cleanly: task stays `pending`, the worktree directory is removed, and it is not registered in `git worktree list` (no orphan). |

### Slice 2 — review/merge path (`watch`/`review`/`done`/`resume`/`nudge`/`abandon`)

Appended as `t15`–`t20`, asserting `docs/slice2_contract.md`. A long-lived
`diffpane` stand-in is dropped on `PATH` and pushed into the tmux server's global
environment (`set-environment -g PATH`) so the pane `bench watch` launches resolves
it and stays resident for `pane_current_path` checks. Pane roles are read via the
`@bench_role` tmux pane option — never pane contents.

| # (ok lines) | Group | Asserts |
|---|---|---|
| 69–74  | t15 `watch` (**Acceptance 5**) | after `watch T-A`, the `deck` window has exactly one pane with `@bench_role=diffpane` whose `pane_current_path` is T-A's worktree; after `watch T-B` the **same pane id** now follows T-B's worktree (repoint-in-place, no new pane). |
| 75–82  | t16 `review` (**A.14** detective control) | diffstat names the file the default worker committed; an in-surface commit (glob `worker.txt`) yields no warning while an out-of-surface commit (glob `src/**`) prints `⚠ outside expected surface:` naming the file; `review` exits 0 and leaves status unchanged in both cases (read-only). |
| 83–98  | t17 `done` (**Acceptance 6**) | `done --yes` on a review task squash-commits `<id>: <title>` onto base, removes+unregisters the worktree, deletes the branch, moves the task to `archive/` as `status=merged`, and the state-dir log records `done <id>`; the output carries a serial-merge `bench nudge` hint naming a still-working sibling. Gates: `done` on a `working` task dies (even with `--yes`) and leaves it untouched; `done` on a dirty base repo dies without archiving; plain `done` (no `--yes`) fed `n` aborts, leaving the task in `review` and adding no commit to base. |
| 99–102 | t18 `resume` (**Acceptance 7**) | after `kill-server` + `up`, `resume` relaunches the dead worker session, the task file is intact (`status` still `working`), and a second `resume` reports already-running. |
| 103–105| t19 `nudge` | a `listen`-mode worker receives `nudge T-x "hello world"` within 5 s (line lands in the worktree's `nudges.log`); `nudge` on a never-spawned/dead session dies. |
| 106–109| t20 `abandon` | worktree removed, agent branch **kept** (work salvageable), task archived with `status=abandoned`. |

Total: 109 assertions (68 slice-1 + 41 slice-2). Runtime ~8 s (well under the 120 s
budget); verified non-flaky across repeated runs. Some slice-2 gate assertions (that
expect a verb to *die*) also pass against a bare `die "not implemented"` stub, so a
green line there is only meaningful against a real implementation; the positive
assertions are the ones that turn red until the verbs land.

## Interpretations (contract ambiguities resolved)

- **Acceptance 8 "no lost update" (t6).** §6.8's stated mechanism is "atomic mv",
  which guarantees no corruption always, and no lost update only for *sequential*
  rapid writes; §1.2's single-writer rule keeps two writers off the same file
  concurrently. `cmd_task_set` (state.sh) has no lock, so a *truly concurrent*
  pair on distinct keys can lose one — allowed under the single-writer rule. The
  harness therefore hard-asserts sequential both-persist and concurrent
  corruption-safety, and emits the concurrent both-persist result as a diagnostic
  rather than a flaky hard failure. If concurrent no-lost-update is later made a
  requirement, `cmd_task_set` needs an `flock` around read-modify-write.
- **`spawn` status flip vs. a fast worker (t4/t5).** `spawn` flips status to
  `working` *after* launching the worker (contract steps 5 then 7). A real worker
  is seconds slow, so `working` always lands first; the mock reproduces that by
  waiting for `working` before its own status write.
- **t4 uses an idle worker** so `working` is deterministically observable; t5 uses
  a separate default worker to prove the full loop closes. t8's blocked chip is
  driven by a direct `task set … status blocked` (deterministic) rather than a
  block-mode spawn.

## Deferred to later slices (not tested here)

- **Slice 3:** status-bar refresh + pane titles + bell latency (§6 test 3 timing),
  `peek`, `doctor`/`clean`, needs-input detection (§5), `bench.tmux.conf`
  styling, VS Code integrated-terminal run (§6 test 9), `core new` tree nodes.
  (`nudge` and crash/`resume` recovery, §6 test 7, are now covered by t18–t19.)
- Not covered by design: `BENCH_ASCII` glyph fallback, transcript hints
  (`BENCH_TRANSCRIPT_HINTS`), `copy_files`/`setup` worktree provisioning.
