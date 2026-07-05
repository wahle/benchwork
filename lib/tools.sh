# lib/tools.sh — human/ops conveniences (slice 3): peek, doctor, clean.
# Owned by the tools agent per docs/slice3_contract.md §C. Diagnose/convenience only:
# peek never feeds state, doctor never mutates, clean only prunes provable leftovers.
# Sourced under `set -euo pipefail` — every non-essential probe is `|| true`-guarded so a
# missing tool or dead server can never take bench down with it. All tmux via btmux.

# ── shared helpers ──────────────────────────────────────────────────────────

# _tl_server_up — true iff a tmux server is already reachable, WITHOUT starting one.
# `list-sessions` errors out (no server file) instead of spawning a server, unlike most
# tmux subcommands; that is exactly what we want for the "only when a server is running"
# gates on the mouse / @bench_conf checks.
_tl_server_up() { btmux list-sessions >/dev/null 2>&1; }

# ── panel ───────────────────────────────────────────────────────────────────

# panel — the Appendix-B tier-1 control palette (user-requested during the first wave):
# an fzf list of every task in a tmux popup. Enter jumps INTO that worker's session
# (answer its prompts in person), ctrl-w points the deck diff pane at it, ctrl-o peeks.
# Pure client of the same state every other renderer reads; every action is a bench verb
# or a session switch — no new state, no scraping.
cmd_panel() {
  [ -n "${TMUX:-}" ] || die "panel runs inside tmux — attach first: tmux attach -t $(tmux_safe "$(project_name)")"
  command -v fzf >/dev/null 2>&1 \
    || die "panel needs fzf — install: sudo apt install fzf  (or drop the static binary into ~/.local/bin)"

  local d f rows="" mark sel key line pick
  # shellcheck disable=SC2034  # _st_load populates ALL of these via dynamic scope; panel reads a subset
  local id title status branch worktree model port question updated last_commit is_stale session alive
  local needs_input needs_input_confirmed
  d=$(state_dir)
  for f in "$d"/tasks/T-*.md; do
    [ -e "$f" ] || continue
    _st_load "$f"
    mark=" "
    [ "$needs_input" = true ] && mark="?"
    [ "$needs_input_confirmed" = true ] && mark="!"
    rows+=$(printf '%-7s %-8s %s  %s' "$id" "$status" "$mark" "$title")$'\n'
  done
  [ -n "$rows" ] || die "no tasks yet — 'bench task new \"title\"' to cut one"

  sel=$(printf '%s' "$rows" | fzf --no-sort --reverse \
        --prompt='bench> ' \
        --header='enter: open worker session · ctrl-w: watch · ctrl-o: peek · esc: close' \
        --expect=ctrl-w,ctrl-o) || return 0
  key=$(printf '%s\n' "$sel" | head -n1)
  line=$(printf '%s\n' "$sel" | sed -n 2p)
  pick=${line%% *}
  [ -n "$pick" ] || return 0

  case "$key" in
    ctrl-w) cmd_watch "$pick" ;;
    ctrl-o) cmd_peek "$pick" -n 40 || true
            printf '\n[any key to close] '; read -r -n1 -s || true ;;
    *)  if ! btmux switch-client -t "=$(worker_session "$pick")" 2>/dev/null; then
          echo "no live worker session for $pick — 'bench spawn $pick' (pending) or 'bench resume $pick' (dead)"
          printf '[any key to close] '; read -r -n1 -s || true
        fi ;;
  esac
}

# ── peek ────────────────────────────────────────────────────────────────────

# peek <id> [-n N] — tail of the worker pane, for human eyes only (never parsed for state).
# `-n N` may appear before or after the id; N defaults to 30.
cmd_peek() {
  local id="" n=30
  while [ $# -gt 0 ]; do
    case "$1" in
      -n)  shift; n=${1:-30} ;;
      -n*) n=${1#-n} ;;
      -*)  die "peek: unknown flag: $1 — usage: bench peek <id> [-n N]" ;;
      *)   [ -n "$id" ] || id=$1 ;;
    esac
    shift
  done
  [ -n "$id" ] || die "peek: which task? — usage: bench peek <id> [-n N]"
  [[ $n =~ ^[0-9]+$ ]] || die "peek: -n takes a number, got '$n'"
  id=$(norm_id "$id")
  require_task "$id" >/dev/null                    # archive-aware: says so if merged/abandoned

  local sess; sess=$(worker_session "$id")
  btmux has-session -t "=$sess" 2>/dev/null \
    || die "$id has no running worker session ($sess) — 'bench resume $id' to relaunch it, then peek again"

  # capture-pane -S - is the whole scrollback. Trim trailing blank lines BEFORE tailing:
  # a repainting TUI (claude's) leaves a wall of blank rows at the END of its history, so
  # tail-then-trim returns nothing exactly when there's something to see (found live, wave 1).
  local out
  out=$(btmux capture-pane -p -S - -t "=$sess:" 2>/dev/null \
        | sed -e :a -e '/^[[:space:]]*$/{ $d; N; ba }' | tail -n "$n") || true
  printf '── %s · %s — last %s lines ──\n' "$id" "$sess" "$n"
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# ── doctor ──────────────────────────────────────────────────────────────────

# _tl_line <level> <what> [fix] — one diagnosis line. ok has no fix; warn/FAIL append the
# exact next command after an em-dash so the reader never has to go look it up.
_tl_line() {
  if [ -n "${3:-}" ]; then printf '%s %s — %s\n' "$1" "$2" "$3"
  else printf '%s %s\n' "$1" "$2"; fi
}

# doctor — read-only health check. One line per check; exit 1 only when a hard prerequisite is
# missing (tmux, git, or a broken/absent state dir), exit 0 with any number of warns otherwise.
# ALL check lines print before the exit so a FAIL never hides the checks after it.
cmd_doctor() {
  local fail=0 d repo proj claude m c
  proj=$(project_name); d="$BENCH_HOME/$proj"

  # 1. required + optional tooling on PATH.
  if command -v tmux >/dev/null 2>&1; then _tl_line ok "tmux on PATH"
  else _tl_line FAIL "tmux not on PATH" "install tmux (e.g. apt install tmux) — bench needs it for every worker"; fail=1; fi
  if command -v git >/dev/null 2>&1; then _tl_line ok "git on PATH"
  else _tl_line FAIL "git not on PATH" "install git — bench's state and worktrees are all git"; fail=1; fi
  if command -v lazygit >/dev/null 2>&1; then _tl_line ok "lazygit on PATH"
  else _tl_line warn "lazygit not on PATH" "install lazygit for the review TUI — without it 'bench review' shows a diffstat only"; fi
  if command -v diffpane >/dev/null 2>&1; then _tl_line ok "diffpane on PATH (bench watch --tui)"
  else _tl_line warn "diffpane not on PATH" "install diffpane for 'bench watch --tui' (pretty uncommitted-changes view); default watch works without it"; fi
  if command -v fzf >/dev/null 2>&1; then _tl_line ok "fzf on PATH (Alt+g task panel)"
  else _tl_line warn "fzf not on PATH" "install fzf for the Alt+g task panel — sudo apt install fzf"; fi
  claude=${BENCH_CLAUDE:-claude}
  if command -v "$claude" >/dev/null 2>&1; then _tl_line ok "claude on PATH ($claude)"
  else _tl_line warn "claude not on PATH ($claude)" "install claude or set BENCH_CLAUDE=/path/to/claude — workers can't spawn without it"; fi

  # 2. tmux version (click-to-watch needs >= 3.4).
  if tmux_ge34; then _tl_line ok "tmux >= 3.4 (click-to-watch supported)"
  else _tl_line warn "tmux < 3.4" "upgrade tmux to >= 3.4 — status-bar click-to-watch stays disabled below that"; fi

  # 3. mouse on — only meaningful while a server runs (gate so doctor never starts one).
  if _tl_server_up; then
    m=$(btmux show -gv mouse 2>/dev/null) || true
    if [ "$m" = on ]; then _tl_line ok "tmux mouse on"
    else _tl_line warn "tmux mouse is '${m:-unset}'" "run 'bench up' (enables mouse) or: tmux set -g mouse on"; fi
  fi

  # 4. state dir health.
  if [ -d "$d/.git" ]; then
    _tl_line ok "state dir is a git repo ($d)"
    if [ -r "$d/project.conf" ]; then
      repo=$(conf_get repo)
      if [ -n "$repo" ] && [ -d "$repo" ]; then _tl_line ok "project.conf repo path exists ($repo)"
      else _tl_line FAIL "project.conf repo path is missing (repo=${repo:-<empty>})" "fix the repo= line in $d/project.conf, or re-run 'bench init' from the repo"; fail=1; fi
    else
      _tl_line FAIL "project.conf missing/unreadable" "re-run 'bench init' from the repo to recreate $d/project.conf"; fail=1
    fi
    local fm=""
    fm=$(find "$d/tasks" "$d/archive" -maxdepth 1 -name '.fm.*' 2>/dev/null | head -n1) || true
    if [ -n "$fm" ]; then _tl_line warn "half-written frontmatter temp files in the state dir" "run 'bench clean' to sweep stale .fm.* temp files (e.g. $fm)"
    else _tl_line ok "no leftover frontmatter temp files"; fi
  else
    _tl_line FAIL "state dir missing or not a git repo ($d)" "run 'bench init' from inside the project repo"; fail=1
  fi

  # 5. orphaned worktrees (only when we have a repo to ask).
  repo=$(conf_get repo)
  if [ -n "$repo" ] && { [ -d "$repo/.git" ] || [ -f "$repo/.git" ]; }; then
    local orphans=() key val bn tid
    while read -r key val; do
      [ "$key" = worktree ] || continue
      bn=$(basename "$val")
      case "$bn" in
        "$proj"-T-*) tid=${bn#"$proj"-}
          [ -f "$d/tasks/$tid.md" ] || orphans+=("$bn") ;;
      esac
    done < <(git -C "$repo" worktree list --porcelain 2>/dev/null || true)
    if [ "${#orphans[@]}" -gt 0 ]; then _tl_line warn "orphaned worktree(s): ${orphans[*]}" "run 'bench clean' to remove worktrees whose task is gone"
    else _tl_line ok "no orphaned worktrees"; fi
  fi

  # 6. conf sourced — only when a server runs (the @bench_conf marker lives on it).
  if _tl_server_up; then
    c=$(btmux show -gv @bench_conf 2>/dev/null) || true
    if [ -n "$c" ]; then _tl_line ok "bench.tmux.conf is sourced"
    else _tl_line warn "bench.tmux.conf not sourced (status bar / hotkeys inactive)" "echo 'source-file $BENCH_ROOT/bench.tmux.conf' >> ~/.tmux.conf"; fi
  fi

  # 7. transcript hints — opt-in only; report whether the format looks parseable.
  if [ "${BENCH_TRANSCRIPT_HINTS:-}" = 1 ]; then
    local pdir="$HOME/.claude/projects" newest=""
    if [ -d "$pdir" ]; then
      newest=$(find "$pdir" -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-) || true
      if [ -n "$newest" ] && grep -q '"type"' "$newest" 2>/dev/null; then _tl_line ok "transcript hints enabled and transcripts look parseable"
      else _tl_line warn "transcript hints enabled but format unfamiliar — hints will stay silent" "no action needed, or unset BENCH_TRANSCRIPT_HINTS to silence this"; fi
    else
      _tl_line warn "transcript hints enabled but $pdir is absent — hints will stay silent" "no action needed, or unset BENCH_TRANSCRIPT_HINTS to silence this"
    fi
  fi

  [ "$fail" = 0 ] || return 1
  return 0
}

# ── clean ───────────────────────────────────────────────────────────────────

# _tl_receipt <thing> <action> <detail> — one aligned receipt line, done.sh's column style.
_tl_receipt() { printf '%-9s %-8s %s\n' "$1" "$2" "$3"; }

# clean — prune provable leftovers (orphan sessions/worktrees, merged branches, stale temp
# files) and print a receipt of exactly what went. A no-op says so. Every git/tmux call is
# fault-tolerant: a target that is already gone is success, not an error.
cmd_clean() {
  local d repo proj changed=0 stuck=0
  proj=$(project_name); d=$(state_dir); repo=$(conf_get repo)

  # 1. Orphan worker sessions: bench-<safeproj>-T-* with no live task file.
  local sprefix sname tid
  sprefix="bench-$(tmux_safe "$proj")-"
  while read -r sname; do
    case "$sname" in
      "$sprefix"T-*) tid=${sname#"$sprefix"}
        if [ ! -f "$d/tasks/$tid.md" ]; then
          btmux kill-session -t "=$sname" 2>/dev/null || true
          _tl_receipt session killed "$sname"; changed=1
        fi ;;
    esac
  done < <(btmux list-sessions -F '#{session_name}' 2>/dev/null || true)

  # 2. Orphan registered worktrees: <proj>-T-* whose task file is gone. prune always runs
  #    afterwards to drop admin entries for worktrees deleted out from under git.
  if [ -n "$repo" ] && { [ -d "$repo/.git" ] || [ -f "$repo/.git" ]; }; then
    local key val bn wpath
    while read -r key val; do
      [ "$key" = worktree ] || continue
      wpath=$val; bn=$(basename "$wpath")
      case "$bn" in
        "$proj"-T-*) tid=${bn#"$proj"-}
          if [ ! -f "$d/tasks/$tid.md" ]; then
            # Only claim "removed" when git agrees (a locked/odd worktree fails even
            # with --force) — a receipt must never lie about what happened.
            if git -C "$repo" worktree remove --force "$wpath" >/dev/null 2>&1; then
              _tl_receipt worktree removed "$wpath"; changed=1
            else
              _tl_receipt worktree stuck "$wpath — remove failed; try: git -C $repo worktree unlock $wpath && bench clean"
              stuck=1
            fi
          fi ;;
      esac
    done < <(git -C "$repo" worktree list --porcelain 2>/dev/null || true)
    git -C "$repo" worktree prune >/dev/null 2>&1 || true

    # 3. Merged-and-archived branches only. Abandoned tasks keep their branch (salvage rule);
    #    unknown ids keep theirs (we only delete what we can prove is safely merged).
    local br arch
    while read -r br; do
      br=${br#\* }; br=${br// /}          # strip the current-branch marker + stray spaces
      [ -n "$br" ] || continue
      case "$br" in
        agent/T-*) tid=${br#agent/}
          arch="$d/archive/$tid.md"
          if [ ! -f "$d/tasks/$tid.md" ] && [ -f "$arch" ] && [ "$(fm_get "$arch" status)" = merged ]; then
            if git -C "$repo" branch -D "$br" >/dev/null 2>&1; then
              _tl_receipt branch deleted "$br"; changed=1
            else
              _tl_receipt branch stuck "$br — delete failed (checked out somewhere?); try: git -C $repo branch -D $br"
              stuck=1
            fi
          fi ;;
      esac
    done < <(git -C "$repo" branch --list 'agent/T-*' 2>/dev/null || true)
  fi

  # 4. Stale frontmatter temp files (> 60s old) left by an interrupted fm_set.
  local f mt now; now=$(date +%s)
  for f in "$d"/tasks/.fm.* "$d"/archive/.fm.*; do
    [ -e "$f" ] || continue
    mt=$(date -r "$f" +%s 2>/dev/null || echo "$now")
    if [ $((now - mt)) -gt 60 ]; then
      rm -f "$f"; _tl_receipt tempfile removed "$f"; changed=1
    fi
  done

  # 5. One audit commit iff something actually changed (state_commit no-ops when the state
  #    dir itself is unchanged, so this is safe even when only sessions/branches moved).
  if [ "$changed" = 1 ]; then
    state_commit "clean"
  elif [ "$stuck" = 0 ]; then
    echo "nothing to clean — workbench is tidy"
  fi
  return 0
}
