# lib/review.sh — the review/merge path (slice 2): review, done, abandon.
# Every state change goes through fm_set + a single state_commit; bench never reads
# task state from tmux panes. Runs under `set -euo pipefail`.

# _rv_ctx <id> — load the task's context into caller-scoped vars:
#   id repo base proj branch wt sess. Dies with a helpful pointer if the task is gone.
_rv_ctx() {
  id=$(norm_id "${1:-}")
  local tf; tf=$(require_task "$id")   # archive-aware: a merged/abandoned task says so

  repo=$(conf_get repo)
  base=$(conf_get base main)
  proj=$(project_name)
  branch="agent/$id"
  wt=$(fm_get "$tf" worktree)
  sess="bench-$(tmux_safe "$proj")-$id"
}

# _rv_archive <id> <status> <verb> — the one atomic archive step shared by done/abandon:
# stamp the terminal status + updated time, move the task file tasks/ -> archive/, and
# record exactly one audit commit. (Direct fm_set here on purpose — routing through
# cmd_task_set would double-commit; this keeps the archive a single clean step.)
_rv_archive() {
  local id=$1 status=$2 verb=$3 tf
  tf=$(task_file "$id")
  fm_set "$tf" status "$status"
  fm_set "$tf" updated "$(now_iso)"
  mv "$tf" "$(state_dir)/archive/$id.md"
  state_commit "$verb $id"
}

# _rv_teardown <sess> <repo> <wt> — retire a worker: kill its tmux session if alive and
# drop its worktree. The branch is left to the caller (done deletes it; abandon keeps it).
# Every step tolerates an already-gone target so re-runs stay clean.
_rv_teardown() {
  local sess=$1 repo=$2 wt=$3
  if btmux has-session -t "=$sess" 2>/dev/null; then
    btmux kill-session -t "=$sess" 2>/dev/null || true
  fi
  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
  git -C "$repo" worktree prune >/dev/null 2>&1 || true
}

# _rv_lazygit <proj> <wt> — show lazygit for the worktree in the deck window's review pane
# (tmux pane option @bench_role=review). Needs lazygit on PATH and a live project session;
# degrades gracefully (a one-line note) when either is missing, and never fails review.
_rv_lazygit() {
  local proj=$1 wt=$2 sess pane
  if ! command -v lazygit >/dev/null 2>&1; then
    echo "lazygit not installed — diffstat only"
    return 0
  fi
  sess=$(tmux_safe "$proj")
  btmux has-session -t "=$sess" 2>/dev/null || return 0
  # Self-heal a manually-killed deck window; cmd_up is idempotent.
  btmux list-windows -t "=$sess" -F '#{window_name}' | grep -qx deck || cmd_up >/dev/null

  # Reuse the existing review pane if one is already tagged; otherwise split a fresh one.
  # Locked (same lock as task set / watch) so concurrent reviews can't each split a pane.
  (
    flock -w 5 9 2>/dev/null || true
    pane=$(btmux list-panes -t "=$sess:deck" -F '#{pane_id} #{@bench_role}' 2>/dev/null \
           | awk '$2 == "review" { print $1; exit }')
    if [ -n "$pane" ]; then
      btmux respawn-pane -k -t "$pane" -c "$wt" lazygit -p "$wt"
    else
      pane=$(btmux split-window -d -h -P -F '#{pane_id}' -t "=$sess:deck" -c "$wt" lazygit -p "$wt")
      btmux set-option -p -t "$pane" @bench_role review
    fi
  ) 9>>"$(state_dir)/.git/bench.lock"
  echo "opened lazygit for $wt in the deck review pane"
}

# review <id> — read-only. Print the branch-vs-base diffstat, flag any files that fall
# outside the task's predicted surface (A.14 detective control — advisory, never blocks),
# and open lazygit on the worktree. Task state is never touched.
cmd_review() {
  local id repo base proj branch wt tf changed glob matched warn=()
  _rv_ctx "$1"
  [ -d "$wt" ] || die "$id has no worktree yet — run 'bench spawn $id' first, then review it"
  tf=$(task_file "$id")

  echo "diff of $branch vs $base:"
  git -C "$repo" diff --stat "$base...$branch"

  # Match every changed file against the task's expected globs. In this [[ == ]] context a
  # glob's * spans '/', and a '**' surface matches everything. Collect what matches nothing.
  # A task file with no '## Expected files' section (legacy/hand-written) declares no surface
  # at all — skip the check with a note instead of flagging every single file.
  local globs=()
  mapfile -t globs < <(task_globs "$tf")
  if [ "${#globs[@]}" -eq 0 ]; then
    echo
    echo "note: no '## Expected files' section in the task file — surface check skipped"
  else
  while IFS= read -r changed; do
    [ -n "$changed" ] || continue
    matched=0
    for glob in "${globs[@]}"; do
      # shellcheck disable=SC2053  # unquoted RHS is deliberate: we want glob matching here
      if [ -n "$glob" ] && [[ $changed == $glob ]]; then
        matched=1
        break
      fi
    done
    [ "$matched" = 1 ] || warn+=("$changed")
  done < <(git -C "$repo" diff --name-only "$base...$branch")
  fi

  if [ "${#warn[@]}" -gt 0 ]; then
    echo
    echo "⚠ outside expected surface:"
    printf '    %s\n' "${warn[@]}"
    echo "  (advisory only — nothing is blocked. These paths aren't listed under the task's"
    echo "   '## Expected files'; give them an extra look, and widen that list if they belong.)"
  fi

  echo
  _rv_lazygit "$proj" "$wt"
}

# done <id> [--yes] — squash-merge a reviewed task into base, retire the worker, archive it
# as merged, then remind you to rebase the other in-flight workers (serial-merge convention).
cmd_done() {
  local id repo base proj branch wt sess tf status current answer sha other other_id
  local yes=0 arg idarg="" printed_header=0
  for arg in "$@"; do
    case "$arg" in
      --yes) yes=1 ;;
      *)     idarg=$arg ;;
    esac
  done
  _rv_ctx "$idarg"
  tf=$(task_file "$id")

  # Gate 1: the task must be in review. --yes skips the prompt, never this check.
  status=$(fm_get "$tf" status)
  [ "$status" = review ] || die "$id is '$status', not 'review' — a task can only be merged from review. \
Review it with 'bench review $id', or wait for the worker to run 'bench task set $id status review'. (--yes skips the confirm prompt, not this check.)"

  # Gate 2: the base repo must be on the base branch and clean, so the squash commit lands
  # where it should and nothing of yours gets swept into it.
  current=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
  [ "$current" = "$base" ] || die "the repo at $repo is on '$current', not the base branch '$base' — run 'git -C $repo checkout $base', then 'bench done $id' again"
  git -C "$repo" diff --quiet HEAD || die "the repo at $repo has uncommitted changes — commit or stash them, then re-run 'bench done $id'"

  # Confirm unless --yes.
  if [ "$yes" = 0 ]; then
    read -r -p "merge $id into $base? [y/N] " answer
    if [ "$answer" != y ] && [ "$answer" != Y ]; then
      echo "aborted — nothing was merged; $id is still in review."
      return 0
    fi
  fi

  # Squash-merge. On conflict, undo cleanly (base untouched) and explain the fix.
  if ! git -C "$repo" merge --squash "$branch" >/dev/null 2>&1; then
    git -C "$repo" reset --merge >/dev/null 2>&1 || true
    die "squash-merge of $branch into $base hit a conflict — I ran 'git reset --merge', so $base is untouched. \
Rebase the worker onto the current base first: bench nudge $id \"base updated; rebase onto $base and re-run tests\" — then run 'bench done $id' again."
  fi
  # A branch with no net change vs base stages nothing — skip the commit rather than
  # let the empty git commit kill the flow; still retire and archive the task below.
  if git -C "$repo" diff --cached --quiet; then
    sha=""
  else
    git -C "$repo" commit -qm "$id: $(fm_get "$tf" title)"
    sha=$(git -C "$repo" rev-parse --short HEAD)
  fi

  # Retire the worker, delete its branch (the work now lives in base), and archive the task.
  local had_wt=0
  if [ -n "$wt" ] && [ -d "$wt" ]; then had_wt=1; fi
  _rv_teardown "$sess" "$repo" "$wt"
  git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || true
  _rv_archive "$id" merged "done"

  # Receipt: exactly what happened.
  echo "merged $id into $base"
  if [ -n "$sha" ]; then
    echo "  commit    $sha  $id: $(fm_get "$(state_dir)/archive/$id.md" title)"
  else
    echo "  commit    none — $branch had no new changes vs $base"
  fi
  if [ "$had_wt" = 1 ]; then
    echo "  worktree  removed   $wt"
  else
    echo "  worktree  none — already gone${wt:+ ($wt)}"
  fi
  echo "  branch    deleted   $branch"
  echo "  task      archived  $(state_dir)/archive/$id.md (status: merged)"

  # Serial-merge convention (A.5): every other still-working branch was cut from the old
  # base and should rebase now. List a ready-to-run nudge for each.
  for other in "$(state_dir)"/tasks/T-*.md; do
    [ -e "$other" ] || continue
    [ "$(fm_get "$other" status)" = working ] || continue
    other_id=$(fm_get "$other" id)
    if [ "$printed_header" = 0 ]; then
      echo
      echo "next — rebase the other in-flight workers onto the updated $base:"
      printed_header=1
    fi
    echo "  bench nudge $other_id \"base updated; rebase onto $base and re-run tests\""
  done
}

# abandon <id> — retire the worker and archive the task as abandoned, but KEEP the branch:
# the work may still be worth salvaging. No confirmation prompt.
cmd_abandon() {
  local id repo base proj branch wt sess had_wt=0
  _rv_ctx "$1"

  if [ -n "$wt" ] && [ -d "$wt" ]; then had_wt=1; fi
  _rv_teardown "$sess" "$repo" "$wt"
  _rv_archive "$id" abandoned abandon

  echo "abandoned $id"
  if [ "$had_wt" = 1 ]; then
    echo "  worktree  removed   $wt"
  else
    echo "  worktree  none — task was never spawned${wt:+ (or already gone: $wt)}"
  fi
  echo "  branch    kept      $branch (salvage with 'git checkout $branch', or delete once you're sure)"
  echo "  task      archived  $(state_dir)/archive/$id.md (status: abandoned)"
}
