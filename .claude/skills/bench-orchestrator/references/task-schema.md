# Task file schema (reference)

One file per task at `~/.bench/<project>/tasks/T-042.md` (moves to `archive/`
when merged or abandoned). Flat `key: value` frontmatter — greppable with
`grep '^status:'`, no yq/jq. **Only `bench task set` writes it; never hand-edit.**

## Frontmatter — exact key order

```markdown
---
id: T-042
title: Add spot-interruption drain handler
status: pending        # see lifecycle below
branch: agent/T-042
worktree: /home/nick/src/gamehost-T-042
model: opus
port: 3042             # 3000 + numeric id
question:              # set by the worker ONLY when status=blocked
updated: 2026-07-04T14:03:00Z
---
```

`bench task set <id> <key> <value>` writes atomically (temp file + `mv`) and
commits to the state-dir git repo, so every change is audited.

## Status lifecycle

Allowed values: `pending | working | blocked | review | done | merged |
abandoned`.

```
pending ──spawn──▶ working ⇄ blocked ──▶ review ──approve──▶ done ──merge──▶ merged
                                                    └─────────▶ working (Feedback + redirect)
   (any) ─────────────────────────────────────────────────────────────────▶ abandoned
```

- `pending` → `working`: `bench spawn`.
- `working` ↔ `blocked` → `review`: the worker, as it works, blocks, unblocks,
  and finishes.
- `review` → `done`, or `review` → `working` (with Feedback): the human, via you,
  after looking at the diff.
- `done` → `merged`: `bench done` after the merge lands.
- `abandoned`: `bench abandon` (keeps the branch for salvage).

## Single-writer table

Each transition has exactly one writer — this is what prevents frontmatter races.

| Writer | Owns |
|---|---|
| **Orchestrator** | Creating the task; `status: pending`; assignment fields (branch, worktree, model, port). |
| **Worker** | `status` transitions `working → blocked → working → review`; the `question:` field; `updated:`. |
| **Human (via orchestrator)** | `review → done` or `review → working` (+ append Feedback); `done → merged`. |

Status is **never** derived from screen-scraping. Files and `git log` are the
only state sources; `bench peek` is human convenience only.

## Body sections

```markdown
## Goal
(1–3 sentences, written by the orchestrator from the spec.)

## Expected files
- src/infra/drain/**        (globs; a PREDICTION of the diff surface)

## Acceptance criteria
- [ ] `npm test -- drain` passes
- [ ] CDK synth clean

## Feedback
(appended by human/orchestrator after review; the worker re-reads on resume.)
```

- **Goal** — the intent; also names any shared interfaces/types the task must
  agree on with sibling tasks.
- **Expected files** — see below.
- **Acceptance criteria** — the worker's definition of done; when they pass it
  sets `review` and stops.
- **Feedback** — the ONLY channel workers re-read. All human commentary lands
  here, then `bench nudge`.

## Expected files — prediction, not a boundary (A.14)

Expected files are a **prediction of the diff surface**, used at two moments and
enforced at neither:

- **Decompose time** — an overlap check between tasks. Two tasks predicting the
  same files means serialize or re-cut them; a `**` surface runs alone.
- **Review time** — `bench review`/`done` warn on paths outside the prediction
  (advisory out-of-surface tripwire). It **warns, never blocks.**

It is never a write boundary. Workers are told to *prefer* staying within
Expected files but to make a needed out-of-surface edit and flag it at review
rather than self-block. Unenforceable without hooks, and the wrong control anyway
— git review is the real gate (spec A.14).
