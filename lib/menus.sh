# bench menus — mouse-first context menus (nav wave T-A).
# Contract: docs/nav_wave_spec.md §1. ONE menu implementation (`bench menu`),
# reached from tile right-click, chip right-click, a per-tile [≡] glyph, and the
# keyboard. All tmux via btmux. The menu is a tmux `display-menu -M`; because a
# tmux target never expands #{} (docs/handoff-2026-07-05.md gotchas), every menu
# entry is a tmux command whose formats (#{@bench_repo}, socket, client) are
# expanded by tmux itself at selection time — bench only bakes in the known-safe
# literals (task id, worker session name).

# _mn_id_from_session <worker-session> — reverse worker_session(): bench-<safeproj>-<id> -> <id>.
# Returns non-zero (and prints nothing) when the name is not a worker session for this project.
_mn_id_from_session() {
  local ws=$1 prefix
  prefix="bench-$(tmux_safe "$(project_name)")-"
  case "$ws" in
    "$prefix"T-*) printf '%s\n' "${ws#"$prefix"}" ;;
    *) return 1 ;;
  esac
}

# _mn_name <label> <key> — a menu-item name (a tmux format) that shows <label> on the
# left and its keyboard equivalent <key> right-aligned in the menu's right column.
_mn_name() { printf '%s#[align=right] %s ' "$1" "$2"; }

# cmd_menu — build and show the per-task context menu, or (with --print) emit its entries
# as text so the acceptance suite can assert headless.
#   bench menu <id>                       explicit id (keyboard path / panel integration), centered
#   bench menu --from-pane <pane_id>      resolve the task from the clicked tile's @bench_view, at mouse
#   --client <name>                       display on this client (mouse/keyboard bindings pass #{client_name})
#   --mouse                               open at the mouse (-x M -y M) instead of centered (-x C -y C)
#   --print                               print the entries instead of displaying (headless-testable)
cmd_menu() {
  local id="" pane="" client="" pos=center print=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --from-pane) shift; pane=${1:-} ;;
      --client)    shift; client=${1:-} ;;
      --mouse)     pos=mouse ;;
      --center)    pos=center ;;
      --print)     print=1 ;;
      -*)          die "menu: unknown flag: $1 — usage: bench menu <id> | --from-pane <pane_id> [--mouse|--print]" ;;
      *)           [ -n "$id" ] || id=$1 ;;
    esac
    shift
  done

  # Resolve the task. --from-pane reads the clicked tile's @bench_view (the worker session
  # name) and reverses it to the task id; a pane without the tag is not a bench tile.
  if [ -n "$pane" ]; then
    local view
    view=$(btmux display-message -p -t "$pane" '#{@bench_view}' 2>/dev/null) || true
    [ -n "$view" ] || die "menu: pane $pane is not a bench crew tile (no @bench_view) — right-click a worker tile, or run 'bench menu <id>'"
    id=$(_mn_id_from_session "$view") || die "menu: '$view' is not a worker session for this project — cannot open its menu"
    pos=mouse   # a pane click is always a mouse event
  fi
  [ -n "$id" ] || die "menu: which task? — usage: bench menu <id> | --from-pane <pane_id>"
  id=$(norm_id "$id")
  local tf title
  tf=$(require_task "$id")            # archive-aware: a merged/abandoned task says so
  title=$(fm_get "$tf" title)

  # The menu only makes sense against a live worker: jump/peek/nudge/embed all need the
  # session. A task that was never launched dies naming the fix.
  local proj sess wsess
  proj=$(project_name); sess=$(tmux_safe "$proj"); wsess=$(worker_session "$id")
  btmux has-session -t "=$wsess" 2>/dev/null \
    || die "$id has no live worker session — 'bench spawn $id' to launch it (pending), or 'bench resume $id' if it died — then its menu lights up"

  # Pop vs Embed: whichever applies given the current crew state.
  local poe_label poe_verb
  if [ -n "$(_tx_view_pane "$sess" "$wsess")" ]; then poe_label='Pop tile'; poe_verb=pop
  else poe_label='Embed tile'; poe_verb=embed; fi

  if [ "$print" = 1 ]; then
    printf 'menu %s — %s\n' "$id" "$title"
    printf '  %-20s %s\n' 'Jump into worker' j
    printf '  %-20s %s\n' 'Watch diff'       w
    printf '  %-20s %s\n' 'Peek'             p
    printf '  %-20s %s\n' 'Nudge…'           n
    printf '  %-20s %s\n' 'Review'           r
    printf '  %-20s %s\n' "$poe_label"       e
    return 0
  fi

  # Menu-entry commands. Formats expand at selection time; the task id and worker session
  # are baked as literals (both are tmux-safe). Jump runs in the menu's own client, so no
  # socket/client pinning is needed; the others cd into the project via #{@bench_repo}.
  local jump_cmd watch_cmd peek_cmd nudge_cmd review_cmd poe_cmd
  jump_cmd="switch-client -t \"=$wsess\""
  watch_cmd="run-shell 'cd \"#{@bench_repo}\" && bench watch $id'"
  peek_cmd="display-popup -E 'cd \"#{@bench_repo}\" && bench peek $id -n 40; printf \"\\n[any key to close] \"; read -rn1'"
  review_cmd="display-popup -E 'cd \"#{@bench_repo}\" && bench review $id; printf \"\\n[any key to close] \"; read -rn1'"
  nudge_cmd="display-popup -E 'cd \"#{@bench_repo}\" && printf \"nudge $id › \" && IFS= read -r l && [ -n \"\$l\" ] && bench nudge $id \"\$l\"'"
  poe_cmd="run-shell 'cd \"#{@bench_repo}\" && bench $poe_verb $id'"

  local xpos ypos
  if [ "$pos" = mouse ]; then xpos=M; ypos=M; else xpos=C; ypos=C; fi

  local -a menu=(display-menu -M)
  [ -n "$client" ] && menu+=(-c "$client")
  [ -n "$pane" ] && menu+=(-t "$pane")
  menu+=(-x "$xpos" -y "$ypos" -T " $id ")
  menu+=("$(_mn_name 'Jump into worker' j)" j "$jump_cmd")
  menu+=("$(_mn_name 'Watch diff' w)"       w "$watch_cmd")
  menu+=("$(_mn_name 'Peek' p)"             p "$peek_cmd")
  menu+=("$(_mn_name 'Nudge…' n)"           n "$nudge_cmd")
  menu+=("$(_mn_name 'Review' r)"           r "$review_cmd")
  menu+=('' '' '')
  menu+=("$(_mn_name "$poe_label" e)"       e "$poe_cmd")

  btmux "${menu[@]}"
}
