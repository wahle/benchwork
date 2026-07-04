# Worker spawn prompt (reference)

`bench spawn <id>` fills this template and delivers it as the worker session's
initial prompt automatically. **The orchestrator never sends it** — it lives here
so you understand the rules every worker is already operating under, so your
`nudge`s and Feedback stay consistent with them.

It matches `_tx_prompt` in `lib/tmuxops.sh` exactly as implemented (spec §4).

## Template

The placeholders are filled at spawn time from the task file and project config:

- `{id}` — task id, e.g. `T-042`.
- `{branch}` — `agent/{id}`, created off the base branch.
- `{worktree}` — the task's private git worktree path.
- `{taskfile}` — path to `~/.bench/<project>/tasks/{id}.md`, the worker's durable context.
- `{port}` — `3000 + numeric id`; the worker's assigned server/test port (no collisions).

> You are worker **{id}** on branch `{branch}` in worktree `{worktree}`. Your task file is `{taskfile}` — read it now; it is your durable context and survives you.
> Rules: (1) Prefer to stay within Expected files; if the task genuinely needs an edit outside them, make the edit and note it when you set status review — do not block to ask. (2) Commit checkpoints early and often — commits are your heartbeat. (3) Update status **only** via `bench task set {id} status <value>`. (4) If blocked, `bench task set {id} question "…"` then status blocked, and wait. (5) Use port {port} for any server/test that needs one. (6) When acceptance criteria pass, make a final commit, set status review, and stop. (7) Re-read the Feedback section whenever you resume or are nudged.

## What the rules mean for you

- **Rule 1 (prefer-don't-block on Expected files):** workers won't self-block on
  out-of-surface edits — they make the edit and flag it at review. Expected files
  are a prediction, not a fence (see `task-schema.md`).
- **Rule 2 (commits as heartbeat):** absence of commits is how `--stale` detects a
  frozen worker. Frequent commits are expected, not a smell.
- **Rule 3 (status only via `bench task set`):** the worker never hand-edits
  frontmatter, same rule you follow.
- **Rule 4 (blocked + question):** a blocked worker has written a `question:` and
  is waiting. Read it, answer via `## Feedback` + `bench nudge`.
- **Rule 5 (port):** each worker has its own port, so parallel dev servers/tests
  don't fight.
- **Rule 6 (review-and-stop):** `review` means the worker finished and halted —
  it is waiting on human approval, not still working.
- **Rule 7 (re-read Feedback on resume/nudge):** appending to `## Feedback` then
  nudging is the reliable way to redirect a worker; it re-reads that section.
