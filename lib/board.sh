# bench board — status-driven crew relayout (nav wave T-B).
# Contract: docs/nav_wave_spec.md §2. Deterministic, transition-gated, layout
# only; never touches task state, never nudges, never answers prompts.
#
# One pass = read every task's status (via _st_load, the same loader panel and
# status --json use — it also yields needs_input_confirmed, the `!` the flat JSON
# does not surface) + the live crew tile inventory (@bench_view tags), then:
#   1. embed working|blocked|review tasks that are alive but have no tile
#   2. pop tiles whose task is merged/abandoned or whose session is dead
#   3. promote to main-vertical (highest-priority tile as main) if any `!`/review
#   4. else settle to tiled
# Each action prints one `board:` receipt; a pass that changes nothing is silent.
# A snapshot of the decision inputs is persisted at $(state_dir)/.board-state so a
# second identical pass is a no-op — the board acts only on CHANGES.

# _board_pass <proj-sess> — one relayout pass. Returns 0 always (a no-op still
# succeeds); the only output is receipts (or a skip line when the crew is zoomed).
_board_pass() {
  local sess=$1
  local proj d statefile prefix
  proj=$(project_name); d=$(state_dir)
  statefile="$d/.board-state"
  prefix="bench-$(tmux_safe "$proj")-"        # worker_session <id> == $prefix$id

  # ── gather task state through the canonical loader (dynamic scope, like panel) ──
  # shellcheck disable=SC2034  # _st_load populates ALL of these via dynamic scope; board reads a subset
  local id title status branch worktree model port question updated last_commit is_stale session alive
  # shellcheck disable=SC2034
  local needs_input needs_input_confirmed
  declare -A B_STATUS B_CONF B_ALIVE
  local f cur_sig stored_sig stored_layout
  local ids=()
  for f in "$d"/tasks/T-*.md; do
    [ -e "$f" ] || continue
    _st_load "$f"
    B_STATUS[$id]=$status
    [ "$needs_input_confirmed" = true ] && B_CONF[$id]=1 || B_CONF[$id]=0
    [ "$alive" = true ] && B_ALIVE[$id]=1 || B_ALIVE[$id]=0
    ids+=("$id")
  done
  # Signature = the decision-relevant state of every task, sorted for stability.
  # Deliberately excludes the tile inventory: pass 1 mutates it (embed/pop), so a
  # tile-inclusive signature would never converge to a no-op on pass 2.
  cur_sig=$(for id in ${ids[@]+"${ids[@]}"}; do
    printf '%s %s %s %s\n' "$id" "${B_STATUS[$id]}" "${B_CONF[$id]}" "${B_ALIVE[$id]}"
  done | sort)

  # ── transition gate: identical input since the snapshot ⇒ no-op (t39 core) ──
  stored_sig=""; stored_layout=tiled
  if [ -f "$statefile" ]; then
    stored_sig=$(grep -v '^@layout ' "$statefile" 2>/dev/null || true)
    stored_layout=$(sed -n 's/^@layout //p' "$statefile" | head -n1); stored_layout=${stored_layout:-tiled}
  fi
  [ "$cur_sig" = "$stored_sig" ] && return 0    # nothing changed — silent, exit 0

  # ── never fight the user: a zoomed crew means hands-off. Skip the whole pass and
  # do NOT persist, so the pending change is re-evaluated once the user un-zooms. ──
  local zoom
  zoom=$(btmux display-message -p -t "=$sess:crew" '#{window_zoomed_flag}' 2>/dev/null || true)
  if [ "$zoom" = 1 ]; then
    echo "board: skipped (zoomed)"
    return 0
  fi

  # Active pane of an attached client is off-limits (never kill/move it out from
  # under someone). No attached client ⇒ nothing to protect (the headless case).
  local attached="" active_pane=""
  if [ -n "$(btmux list-clients -t "=$sess" -F '#{client_name}' 2>/dev/null)" ]; then
    attached=1
    active_pane=$(btmux list-panes -t "=$sess:crew" -f '#{pane_active}' -F '#{pane_id}' 2>/dev/null | head -1)
  fi

  local acted=0 wsess

  # ── 1. embed: alive working|blocked|review tasks with no crew tile ──
  for id in ${ids[@]+"${ids[@]}"}; do
    case "${B_STATUS[$id]}" in working|blocked|review) ;; *) continue ;; esac
    [ "${B_ALIVE[$id]}" = 1 ] || continue
    wsess=$(worker_session "$id")
    [ -n "$(_tx_view_pane "$sess" "$wsess")" ] && continue      # already tiled
    if ( cmd_embed "$id" ) >/dev/null 2>&1; then                # subshell contains cmd_embed's die
      echo "board: embedded $id"
      acted=1
    fi
  done

  # ── 2. pop: tiles whose task is merged/abandoned (archived) or whose session died ──
  local pane view id2 popreason
  while read -r pane view; do
    [ -n "$view" ] || continue
    id2=${view#"$prefix"}
    popreason=""
    if ! btmux has-session -t "=$view" 2>/dev/null; then
      popreason="dead session"
    elif [ -f "$d/tasks/$id2.md" ]; then
      case "$(fm_get "$d/tasks/$id2.md" status)" in merged|abandoned) popreason="merged/abandoned" ;; esac
    else
      popreason="merged/abandoned"                              # task file gone ⇒ archived
    fi
    [ -n "$popreason" ] || continue
    if [ -n "$attached" ] && [ "$pane" = "$active_pane" ]; then continue; fi  # protect active pane
    btmux kill-pane -t "$pane" 2>/dev/null || true
    btmux set-option -u -t "=$view" status 2>/dev/null || true  # hand a still-live session its bar back
    echo "board: popped $id2 ($popreason)"
    acted=1
  done < <(btmux list-panes -t "=$sess:crew" -F '#{pane_id} #{@bench_view}' 2>/dev/null)

  # ── 3/4. decide the layout from the tiles that remain ──
  # priority: ! (confirmed needs-input) > review > blocked > working; ties → lowest id.
  local maxprio=0 mainid="" mainpane="" mainglyph="" pst prio glyph
  while read -r pane view; do
    [ -n "$view" ] || continue
    id2=${view#"$prefix"}
    if [ -n "${B_STATUS[$id2]+x}" ]; then pst=${B_STATUS[$id2]}; else pst=$(fm_get "$d/tasks/$id2.md" status 2>/dev/null || true); fi
    if [ "${B_CONF[$id2]:-0}" = 1 ]; then prio=4; glyph='!'
    else case "$pst" in
      review)  prio=3; glyph=review ;;
      blocked) prio=2; glyph=blocked ;;
      working) prio=1; glyph=working ;;
      *)       prio=0; glyph=$pst ;;
    esac; fi
    if [ "$prio" -gt "$maxprio" ] \
      || { [ "$prio" -eq "$maxprio" ] && [ "$prio" -gt 0 ] && [ -n "$mainid" ] && [[ "$id2" < "$mainid" ]]; }; then
      maxprio=$prio; mainid=$id2; mainpane=$pane; mainglyph=$glyph
    fi
  done < <(btmux list-panes -t "=$sess:crew" -F '#{pane_id} #{@bench_view}' 2>/dev/null)

  local desired
  if [ "$maxprio" -ge 3 ] && [ -n "$mainid" ]; then desired="main-vertical:$mainid"; else desired="tiled"; fi

  if [ "$acted" = 1 ] || [ "$desired" != "$stored_layout" ]; then
    case "$desired" in
      main-vertical:*)
        # Make the top-priority tile the main pane: swap it to pane index 0, which
        # select-layout main-vertical designates as main. Skip the swap if it would
        # yank an attached client's active pane; the relayout itself is expected.
        local first
        first=$(btmux list-panes -t "=$sess:crew" -F '#{pane_index} #{pane_id}' 2>/dev/null | sort -n | head -1 | awk '{print $2}')
        if [ -n "$mainpane" ] && [ -n "$first" ] && [ "$mainpane" != "$first" ] \
          && ! { [ -n "$attached" ] && { [ "$mainpane" = "$active_pane" ] || [ "$first" = "$active_pane" ]; }; }; then
          btmux swap-pane -d -s "$mainpane" -t "$first" 2>/dev/null || true
        fi
        btmux select-layout -t "=$sess:crew" main-vertical >/dev/null 2>&1 || true
        ;;
      tiled)
        btmux select-layout -t "=$sess:crew" tiled >/dev/null 2>&1 || true
        ;;
    esac
    if [ "$desired" != "$stored_layout" ]; then
      case "$desired" in
        main-vertical:*) echo "board: promoted $mainid ($mainglyph)" ;;
        tiled)           echo "board: tiled" ;;
      esac
    fi
  fi

  # ── persist the snapshot (atomic) so the next identical pass is a no-op ──
  local tmp; tmp=$(mktemp "$d/.board-state.XXXXXX")
  : > "$tmp"
  [ -n "$cur_sig" ] && printf '%s\n' "$cur_sig" >> "$tmp"
  printf '@layout %s\n' "$desired" >> "$tmp"
  mv "$tmp" "$statefile"
  return 0
}

# _board_watch <proj-sess> — debounced loop: one pass, then sleep >=2s. Bursts of
# status changes between sleeps coalesce into the next single pass.
_board_watch() {
  local sess=$1 interval=${BENCH_BOARD_INTERVAL:-2}
  [ "$interval" -ge 2 ] 2>/dev/null || interval=2
  echo "board: watching crew every ${interval}s (Ctrl-C to stop)"
  while :; do
    btmux has-session -t "=$sess" 2>/dev/null && { _board_pass "$sess" || true; }
    sleep "$interval"
  done
}

cmd_board() {
  local watch=0 a
  for a in "$@"; do case "$a" in
    --watch) watch=1 ;;
    -*) die "board: unknown flag: $a — usage: bench board [--watch]" ;;
    *)  die "board: unexpected argument '$a' — usage: bench board [--watch]" ;;
  esac; done

  local sess; sess=$(tmux_safe "$(project_name)")
  if [ "$watch" = 1 ]; then
    btmux has-session -t "=$sess" 2>/dev/null || die "no workbench session '$sess' — run 'bench up' first, then 'bench board --watch'"
    _board_watch "$sess"
  else
    btmux has-session -t "=$sess" 2>/dev/null || die "no workbench session '$sess' — run 'bench up' first, then 'bench board'"
    _board_pass "$sess"
  fi
}
