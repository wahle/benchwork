# benchwork — notes for Claude sessions

`bench` is a talk-driven agent workbench on tmux + git. Spec: `docs/bench_spec.md`.
Binding interface contracts: `docs/slice1_contract.md`, `docs/slice2_contract.md`.
Slice 3 onboarding: `docs/slice3_handoff.md` — read it before slice-3 work.

## Priorities (user decision, spec §0 rev)

Useful > elegant > simple > extremely user- and agent-friendly. Line count is a
bloat tripwire, not a budget. Error messages say what's wrong AND the exact next
command; mutating verbs print receipts of what they did.

## Working agreements

- **Shut down spawned teammates before the session ends.** Named agents spawned
  via the Agent tool stay alive after their task completes (idle ≠ terminated) and
  block a clean `/exit`. When their work is accepted, send each one
  `SendMessage {"type": "shutdown_request"}`. Do this as part of wrapping up a
  work phase — not as an afterthought at exit time.
- Subagent final-message reports often never reach the orchestrator: instruct
  every spawned agent to deliver results via SendMessage to "main" BEFORE it
  finishes.
- Agents test ONLY in throwaway environments: mktemp `BENCH_HOME`, private
  `BENCH_TMUX_SOCKET`, `BENCH_CLAUDE` pointed at a mock. Never the real
  `~/.bench`, never the default tmux server.
- Commit to `main`, push to `origin`. End commit messages with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

## Tests

`tests/run.sh` — one harness, extend it (TAP-ish, currently 124 assertions, ~9s).
Lint: `shellcheck -s bash bin/bench lib/*.sh` (run from the repo root so sourced
files resolve). Both must be green before any commit.

## Codebase gotchas (paid for in slices 1–2 — don't rediscover)

- All frontmatter writes via `fm_set` (atomic temp+mv); values pass to awk via
  `ENVIRON`, never `-v` (backslash mangling). Same-file writers serialize on
  `flock $(state_dir)/.git/bench.lock` — reuse that lock, don't invent another.
- tmux session names via `tmux_safe` / `worker_session` only (dots/colons/spaces
  break targets). All tmux calls via `btmux`.
- Task lookups in verbs use `require_task` (archive-aware error messages).
- mock-claude behavior is selected per task: `bench task set T-00X mockmode
  idle|block|listen` (frontmatter channel) — NOT env vars (tmux server env races).
- `claude -p` + `--allowedTools` is variadic and eats a trailing positional
  prompt — pipe prompts via stdin.
- Static binaries go to `~/.local/bin` (no sudo needed); the sandbox blocks
  agent-initiated binary downloads — surface the command for the user to run.
