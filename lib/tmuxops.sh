# lib/tmuxops.sh — tmux layer for bench.
#   cmd_up      navigator surface (session + deck/crew windows)
#   cmd_spawn   create a worker (worktree + branch + detached claude session)
#   cmd_watch   point the deck diff pane at a task's worktree
#   cmd_nudge   send a line of text to a running worker
#   cmd_resume  relaunch a worker that has died, from its durable task file
# All tmux goes through btmux (honours BENCH_TMUX_SOCKET); sourced under set -euo pipefail.

# cmd_up: idempotent create-or-repair of the navigator surface ONLY (Appendix B rule 4).
cmd_up() {
  local sess repo; sess=$(tmux_safe "$(project_name)")   # dots/colons/spaces break tmux names/targets
  repo=$(conf_get repo); repo=${repo:-$(repo_root)}
  if btmux has-session -t "=$sess" 2>/dev/null; then
    btmux list-windows -t "=$sess" -F '#{window_name}' | grep -qx deck || btmux new-window -d -t "=$sess" -n deck
    btmux list-windows -t "=$sess" -F '#{window_name}' | grep -qx crew || btmux new-window -d -t "=$sess" -n crew
  else
    btmux new-session -d -s "$sess" -n deck
    btmux new-window -d -t "=$sess" -n crew
  fi
  btmux set -g mouse on >/dev/null
  # Per-session option the conf reads: status segments + click binds cd here before running
  # bench (tmux #() has no repo cwd). Session-scoped so non-bench sessions render empty.
  # A session option, so it never appears in list-windows — up's byte-identical idempotence holds.
  # NB: set-option's -t rejects the '=' exact-match prefix (unlike has-session), so pass the bare name.
  btmux set-option -t "$sess" @bench_repo "$repo" >/dev/null 2>&1 || true
  echo "bench: session '$sess' ready — attach with: tmux attach -t $sess"
}

# worker_session <id> — the tmux session name for a task's worker. One definition, used by
# spawn/watch/nudge/resume so the name can never drift between the verb that creates it and the
# verbs that talk to it. Sanitized because tmux rejects/rewrites dots, colons and spaces.
worker_session() { echo "bench-$(tmux_safe "$(project_name)")-$1"; }

# _tx_prompt: spec §4 worker spawn prompt with {id}{branch}{worktree}{taskfile}{port} filled.
_tx_prompt() { # id branch worktree taskfile port
  cat <<EOF
You are worker **$1** on branch \`$2\` in worktree \`$3\`. Your task file is \`$4\` — read it now; it is your durable context and survives you.
Rules: (1) Prefer to stay within Expected files; if the task genuinely needs an edit outside them, make the edit and note it when you set status review — do not block to ask. (2) Commit checkpoints early and often — commits are your heartbeat. (3) Update status **only** via \`bench task set $1 status <value>\`. (4) If blocked, \`bench task set $1 question "…"\` then status blocked, and wait. (5) Use port $5 for any server/test that needs one. (6) When acceptance criteria pass, make a final commit, set status review, and stop. (7) Re-read the Feedback section whenever you resume or are nudged.
EOF
}

# _tx_launch <id> <tf> <port> <proj> <sess> <wt> <cmdtail>
# Shared worker launcher for spawn and resume. Builds the inline env prefix the worker needs
# (env applied via `tmux set-environment` does NOT reach a session's initial command, so it must
# be prefixed inline), launches the worker as a DETACHED session whose cwd is the worktree, then
# also records that env on the session and titles the pane. <cmdtail> is already %q-quoted.
# Returns nonzero *without dying* if the session fails to launch, so the caller can roll back.
_tx_launch() {
  local id=$1 tf=$2 port=$3 proj=$4 sess=$5 wt=$6 cmdtail=$7
  local env kv

  env="BENCH_TASK_ID=$(printf %q "$id") BENCH_TASKFILE=$(printf %q "$tf") BENCH_PORT=$(printf %q "$port")"
  env="$env BENCH_HOME=$(printf %q "$BENCH_HOME") BENCH_PROJECT=$(printf %q "$proj")"
  env="$env PATH=$(printf %q "${BENCH_ROOT:-}/bin:$PATH")"
  [ -n "${BENCH_TMUX_SOCKET:-}" ] && env="$env BENCH_TMUX_SOCKET=$(printf %q "$BENCH_TMUX_SOCKET")"

  btmux new-session -d -s "$sess" -c "$wt" "$env $cmdtail" || return 1

  # Needs-input layer 2 (spec §5): mark the worker window silent after this many seconds
  # with no output. status --tmux reads #{window_silence_flag}; advisory only, never state.
  btmux set-option -w -t "=$sess:" monitor-silence "${BENCH_SILENCE_SECS:-60}" 2>/dev/null || true

  # These reach later shells opened in the session (the running worker already has env inline).
  for kv in BENCH_TASK_ID="$id" BENCH_TASKFILE="$tf" BENCH_PORT="$port"; do
    btmux set-environment -t "=$sess" "${kv%%=*}" "${kv#*=}" 2>/dev/null || true
  done
  btmux select-pane -t "$sess:" -T "$id · working" 2>/dev/null || true
}

# cmd_spawn: contract §spawn steps 1-8 — worktree+branch, setup, launch worker session, flip status.
cmd_spawn() {
  local id; id=$(norm_id "${1:-}")
  local tf; tf=$(task_file "$id")
  [ -f "$tf" ] || die "no such task: $id"
  local st; st=$(fm_get "$tf" status)
  [ "$st" = pending ] || die "$id is '$st' — only pending tasks can be spawned"

  local repo base proj model port branch sess wroot wt
  repo=$(conf_get repo); base=$(conf_get base main); proj=$(project_name)
  model=$(fm_get "$tf" model); model=${model:-$(conf_get model opus)}
  port=$(fm_get "$tf" port); branch="agent/$id"; sess=$(worker_session "$id")
  wroot=$(conf_get worktree_root); wroot=${wroot:-$(dirname "$repo")}; wt="$wroot/$proj-$id"

  [ -e "$wt" ] && die "worktree path exists: $wt — run 'bench clean' first"
  btmux has-session -t "=$sess" 2>/dev/null && die "worker session already running: $sess"

  if git -C "$repo" show-ref -q --verify "refs/heads/$branch"; then
    git -C "$repo" worktree add "$wt" "$branch" >/dev/null || die "git worktree add failed"
  else
    git -C "$repo" worktree add -b "$branch" "$wt" "$base" >/dev/null || die "git worktree add failed"
  fi

  local f
  for f in $(conf_get copy_files); do
    [ -e "$repo/$f" ] && { cp "$repo/$f" "$wt/$f" 2>/dev/null || true; }
  done
  local setup; setup=$(conf_get setup)
  [ -n "$setup" ] && { ( cd "$wt" && eval "$setup" ) || echo "bench: setup failed in $wt (continuing)" >&2; }

  cmd_task_set "$id" worktree "$wt"

  local prompt claude cmd
  claude=${BENCH_CLAUDE:-claude}
  prompt=$(_tx_prompt "$id" "$branch" "$wt" "$tf" "$port")
  cmd="$(printf %q "$claude") --model $(printf %q "$model") $(printf %q "$prompt")"
  _tx_launch "$id" "$tf" "$port" "$proj" "$sess" "$wt" "$cmd" || {
    # roll the worktree back so the task stays 'pending' and can be spawned again cleanly
    git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
    die "failed to launch worker session $sess (worktree rolled back)"
  }

  cmd_task_set "$id" status working
  echo "$sess"
  echo "$wt"
}

# cmd_watch: re-point the deck's diff pane at <id>'s worktree so you see that task's live diff.
# Never touches task state — this is purely a viewing convenience (spec A.8: one live diff at a time).
# Default view is the FULL task diff vs base (committed + uncommitted — `git diff <base>` two-dot):
# found live in wave 1 that diffpane only shows uncommitted changes, i.e. it goes blank at the
# review stage, exactly when you most want the diff. `--tui` opts into diffpane's prettier view.
cmd_watch() {
  local id="" tf wt sess tui=0 a
  for a in "$@"; do case "$a" in
    --tui) tui=1 ;;
    -*)    die "watch: unknown flag: $a — usage: bench watch <id> [--tui]" ;;
    *)     [ -n "$id" ] || id=$a ;;
  esac; done
  id=$(norm_id "${id:-}")
  tf=$(require_task "$id")
  wt=$(fm_get "$tf" worktree)
  [ -d "${wt:-/nonexistent}" ] || die "$id has no live worktree yet — run 'bench spawn $id' to create it"
  sess=$(tmux_safe "$(project_name)")
  btmux has-session -t "=$sess" 2>/dev/null || die "no workbench session '$sess' — run 'bench up' first, then 'bench watch $id'"
  # Self-heal a manually-killed deck window; cmd_up is idempotent and recreates only what's missing.
  btmux list-windows -t "=$sess" -F '#{window_name}' | grep -qx deck || cmd_up >/dev/null

  local cmd how
  if [ "$tui" = 1 ] && command -v diffpane >/dev/null 2>&1; then
    cmd=diffpane
    how="diffpane TUI (uncommitted changes only — blank once the worker commits)"
  else
    [ "$tui" = 1 ] && echo "bench: diffpane not installed — showing the standard full-diff view instead"
    cmd="watch --color -n 2 git -c color.ui=always diff $(printf %q "$(conf_get base main)")"
    how="full task diff vs $(conf_get base main), committed + uncommitted (refreshes every 2s; --tui for diffpane)"
  fi

  # The diff pane is whichever pane in the deck window is tagged @bench_role=diffpane, if any.
  # Discover-and-split runs under the same lock task set uses: two concurrent cold-start
  # watches (e.g. a double-click on a status-bar chip) would otherwise each split a pane.
  (
    flock -w 5 9 2>/dev/null || true
    local pane role diffpane_id=""
    while read -r pane role; do
      [ "$role" = diffpane ] && { diffpane_id=$pane; break; }
    done < <(btmux list-panes -t "=$sess:deck" -F '#{pane_id} #{@bench_role}' 2>/dev/null)

    if [ -n "$diffpane_id" ]; then
      # Re-use the existing diff pane in place (kill its old command, keep the pane and its layout).
      btmux respawn-pane -k -t "$diffpane_id" -c "$wt" "$cmd"
    else
      # First watch: split the deck, run the viewer there, and tag the new pane as the diff pane.
      diffpane_id=$(btmux split-window -d -h -t "=$sess:deck" -c "$wt" -P -F '#{pane_id}' "$cmd")
      btmux set-option -p -t "$diffpane_id" @bench_role diffpane
    fi
  ) 9>>"$(state_dir)/.git/bench.lock"

  echo "bench: deck diff pane now follows $wt ($id) — $how"
}

# ── embed / pop: project worker sessions into the crew window as live tiles (Appendix B
# rule 3: panes are VIEWS of sessions). Each tile is a nested tmux client attached to the
# worker's session — fully interactive (type in the tile = type at the worker), and killing
# the tile only detaches a client; the worker session is never owned by its view.
# (join-pane would MOVE the pane and kill the worker's session identity — never that.)

# _tx_view_pane <proj-sess> <worker-sess> — pane id of the crew tile viewing that worker, if any.
_tx_view_pane() {
  btmux list-panes -t "=$1:crew" -F '#{pane_id} #{@bench_view}' 2>/dev/null \
    | awk -v w="$2" '$2 == w { print $1; exit }'
}

# cmd_embed <id>|--all — tile live worker session(s) into crew. Idempotent per worker.
cmd_embed() {
  local sess proj ids=() id wsess attach pane f
  proj=$(project_name); sess=$(tmux_safe "$proj")
  btmux has-session -t "=$sess" 2>/dev/null || die "no workbench session '$sess' — run 'bench up' first"
  btmux list-windows -t "=$sess" -F '#{window_name}' | grep -qx crew || cmd_up >/dev/null

  if [ "${1:-}" = --all ]; then
    for f in "$(state_dir)"/tasks/T-*.md; do
      [ -e "$f" ] || continue
      id=$(fm_get "$f" id)
      btmux has-session -t "=$(worker_session "$id")" 2>/dev/null && ids+=("$id")
    done
    [ "${#ids[@]}" -gt 0 ] || die "no live worker sessions to embed — 'bench status' shows who's running"
  else
    ids=("$(norm_id "${1:-}")")
    require_task "${ids[0]}" >/dev/null
  fi

  for id in "${ids[@]}"; do
    wsess=$(worker_session "$id")
    btmux has-session -t "=$wsess" 2>/dev/null \
      || die "$id has no live worker session — 'bench spawn $id' (pending) or 'bench resume $id' (dead), then embed"
    if [ -n "$(_tx_view_pane "$sess" "$wsess")" ]; then
      echo "embedded  already   $id (crew tile exists)"
      continue
    fi
    # The tile runs a nested client of the worker session on the SAME server/socket.
    # TMUX must be cleared or tmux refuses to nest.
    attach="env TMUX= tmux ${BENCH_TMUX_SOCKET:+-L $(printf %q "$BENCH_TMUX_SOCKET") }attach-session -t $(printf %q "=$wsess")"
    btmux set-option -t "=$wsess" status off 2>/dev/null || true   # tile shows work, not a second bar
    pane=$(btmux split-window -d -t "=$sess:crew" -P -F '#{pane_id}' "$attach") \
      || die "could not split a crew tile for $id"
    btmux set-option -p -t "$pane" @bench_view "$wsess"
    echo "embedded  view      $id → crew (interactive; closing the tile detaches, never kills)"
  done
  btmux select-layout -t "=$sess:crew" tiled >/dev/null 2>&1 || true
}

# cmd_pop <id> — remove a worker's crew tile. The session keeps running headless.
cmd_pop() {
  local id sess wsess pane
  id=$(norm_id "${1:-}")
  require_task "$id" >/dev/null
  sess=$(tmux_safe "$(project_name)")
  wsess=$(worker_session "$id")
  pane=$(_tx_view_pane "$sess" "$wsess")
  [ -n "$pane" ] || die "$id has no crew tile — 'bench embed $id' creates one"
  btmux kill-pane -t "$pane" 2>/dev/null || true
  btmux set-option -u -t "=$wsess" status 2>/dev/null || true     # give the session its bar back
  btmux select-layout -t "=$sess:crew" tiled >/dev/null 2>&1 || true
  echo "popped    view      $id (worker session $wsess keeps running)"
}

# cmd_nudge: type a line into a running worker — literal text, a 100 ms pause, then Enter as a
# separate send (the pause + split send work around interactive-TUI paste handling; spec §3.1).
cmd_nudge() {
  local id sess text
  id=$(norm_id "${1:-}"); shift || true
  require_task "$id" >/dev/null          # archive-aware: a merged/abandoned task says so
  text="$*"                              # everything after the id, spaces preserved
  sess=$(worker_session "$id")
  btmux has-session -t "=$sess" 2>/dev/null \
    || die "worker session $sess is not running — 'bench resume $id' to relaunch it, then nudge again"

  btmux send-keys -t "=$sess:" -l -- "$text"
  sleep 0.1
  btmux send-keys -t "=$sess:" Enter
  echo "bench: nudged $id — delivered to $sess"
}

# cmd_resume: bring a dead worker back to life in its existing worktree. The task file is the
# durable context, so the worker recovers from it — we do NOT change status. Tries claude
# --continue first and falls back to a fresh session pointed at the task file (contract §resume).
cmd_resume() {
  local id tf wt sess
  id=$(norm_id "${1:-}")
  tf=$(require_task "$id")
  wt=$(fm_get "$tf" worktree)
  [ -d "${wt:-/nonexistent}" ] \
    || die "$id has no worktree on disk — 'bench task set $id status pending' then 'bench spawn $id' to recreate it"
  sess=$(worker_session "$id")

  if btmux has-session -t "=$sess" 2>/dev/null; then
    echo "bench: $id is already running in $sess — nothing to do (use 'bench nudge $id \"…\"' to talk to it)"
    return 0
  fi

  local proj model port claude prompt continue_cmd fresh_cmd
  proj=$(project_name)
  model=$(fm_get "$tf" model); model=${model:-$(conf_get model opus)}
  port=$(fm_get "$tf" port)
  claude=${BENCH_CLAUDE:-claude}
  prompt=$(_tx_prompt "$id" "agent/$id" "$wt" "$tf" "$port")

  # Resume if claude can; otherwise start fresh — the task file re-establishes the worker's context.
  continue_cmd="$(printf %q "$claude") --continue"
  fresh_cmd="$(printf %q "$claude") --model $(printf %q "$model") $(printf %q "$prompt")"
  _tx_launch "$id" "$tf" "$port" "$proj" "$sess" "$wt" "sh -c $(printf %q "$continue_cmd || $fresh_cmd")" \
    || die "failed to relaunch worker session $sess — check 'tmux ${BENCH_TMUX_SOCKET:+-L $BENCH_TMUX_SOCKET} list-sessions' and that $wt is intact"

  echo "bench: resumed $id in $sess (claude --continue, falling back to a fresh session from the task file)"
}
