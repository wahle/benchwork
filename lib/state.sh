# bench state engine — task files + git are the only truth (spec §1, §3.1). All
# frontmatter via fm_set (atomic) + state_commit; status never reads tmux panes.
cmd_init() {
  local repo d sug
  repo=$(repo_root); d=$(state_dir)
  mkdir -p "$d/tasks" "$d/archive"
  [ -d "$d/.git" ] || git -C "$d" init -q
  if [ ! -f "$d/project.conf" ]; then          # never clobber an existing conf
    printf 'repo=%s\nbase=%s\nmodel=opus\nport_base=3000\nsetup=\ncopy_files=\nworktree_root=\n' \
      "$repo" "$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)" >"$d/project.conf"
  fi
  mkdir -p "$repo/.claude"
  # Mutating verbs the loop needs, plus read-only verbs so a worker can inspect its
  # task file and repo without a prompt per look (dogfood papercut: T-001 couldn't
  # even `cat` its own task file before its first nudge).
  # Read/Edit/Write in-tree + Read of ~/.bench (task files) keep fresh workers
  # prompt-free — no agent ever answers a live permission prompt (nav spec §5).
  local allow='{"permissions":{"allow":["Bash(git add:*)","Bash(git commit:*)","Bash(bench task set:*)","Bash(npm test:*)","Bash(tsc:*)","Bash(git status:*)","Bash(git diff:*)","Bash(git log:*)","Bash(cat:*)","Read(./**)","Edit(./**)","Write(./**)","Read(~/.bench/**)"]}}'
  if [ ! -f "$repo/.claude/settings.json" ]; then
    printf '%s\n' "$allow" >"$repo/.claude/settings.json"   # commit to base so worktrees inherit it
    echo "wrote $repo/.claude/settings.json (allowlist) — commit it so workers inherit it"
  elif ! grep -q 'bench task set' "$repo/.claude/settings.json"; then
    sug="$repo/.claude/settings.json.bench-suggested"
    printf '%s\n' "$allow" >"$sug"      # existing settings: never overwrite/merge JSON in bash
    echo "existing .claude/settings.json lacks bench entries — merge $sug by hand"
  fi
  state_commit "init $(project_name)"
  echo "initialized $d"
  echo "tmux UX: enable the bench status bar, hotkeys, and click-to-watch with —"
  echo "  echo 'source-file $BENCH_ROOT/bench.tmux.conf' >> ~/.tmux.conf"
}
cmd_task_new() {
  local title="" files=() d f n max=0 num id model port tmp g
  while [ $# -gt 0 ]; do
    case "$1" in
      --files) shift
        while [ $# -gt 0 ] && [ "${1:0:2}" != "--" ]; do files+=("$1"); shift; done ;;
      *) [ -n "$title" ] || title=$1; shift ;;
    esac
  done
  [ -n "$title" ] || die "task new: title required"
  title=${title//$'\n'/ }              # frontmatter values are single-line
  d=$(state_dir)
  for f in "$d"/tasks/T-*.md "$d"/archive/T-*.md; do   # next id spans tasks/ AND archive/
    [ -e "$f" ] || continue
    n=$(basename "$f" .md); n=$((10#${n#T-}))
    [ "$n" -gt "$max" ] && max=$n
  done
  num=$((max+1)); id=$(printf 'T-%03d' "$num")
  model=$(conf_get model opus); port=$(( $(conf_get port_base 3000) + num ))
  tmp=$(mktemp "$d/tasks/.new.XXXXXX")
  { printf -- '---\nid: %s\ntitle: %s\nstatus: pending\nbranch: agent/%s\nworktree:\nmodel: %s\nport: %s\nquestion:\nupdated: %s\n---\n\n## Goal\n(1–3 sentences — fill from the spec)\n\n## Expected files\n' \
      "$id" "$title" "$id" "$model" "$port" "$(now_iso)"
    if [ ${#files[@]} -gt 0 ]; then for g in "${files[@]}"; do echo "- $g"; done
    else echo "- **  (unspecified — whole repo)"; fi
    printf '\n## Acceptance criteria\n- [ ] TBD\n\n## Feedback\n'; } >"$tmp"
  mv "$tmp" "$d/tasks/$id.md"
  state_commit "task new $id: $title"
  echo "created $id"
  echo "$d/tasks/$id.md"
}
cmd_task_set() {
  [ $# -ge 2 ] || die "usage: task set <id> <key> <value...>"
  local id key file
  id=$(norm_id "$1"); key=$2; shift 2
  file=$(task_file "$id")
  [ -f "$file" ] || die "no such task: $id"
  ( # flock serializes same-file writers (spec test 8: no lost update); lock lives
    # in .git so it is never swept into the audit commits. Degrades to unlocked
    # if flock is absent. Remaining args joined so values may hold spaces.
    flock -w 5 9 2>/dev/null || true
    fm_set "$file" "$key" "$*"
    fm_set "$file" updated "$(now_iso)"
  ) 9>>"$(state_dir)/.git/bench.lock"
  state_commit "task set $id: $key=$*"
}
# escape \ " tab cr; remaining C0 controls are stripped (valid JSON beats fidelity here)
_st_esc() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\r'/\\r}; printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'; }

# _st_prompt_signature <session> — 0 if the worker pane tail looks like a permission prompt
# (spec §5 layer 3, advisory: upgrades a silence hint's confidence, never drives state).
_st_prompt_signature() {
  local tail
  tail=$(btmux capture-pane -p -t "=$1:" 2>/dev/null | tail -n 15) || return 1
  [ -n "$tail" ] || return 1
  printf '%s\n' "$tail" | grep -Eq 'Do you want|❯|^[[:space:]]*[0-9]+[.)]'
}

# _st_transcript_hint <worktree> — 0 if Claude Code's newest transcript for that cwd ends in an
# unresolved tool_use (spec §5 layer 2.5, BENCH_TRANSCRIPT_HINTS=1 only). The transcript format
# is internal and may drift, so EVERY path fails silent-and-safe: worst case is a missing hint,
# never a broken status or a wrong state. No jq — crude tail heuristics only.
_st_transcript_hint() {
  local wt=$1 enc dir newest last usel resl
  [ -n "$wt" ] || return 1
  enc=${wt//\//-}; enc=${enc//./-}            # cwd path with '/' and '.' -> '-'
  dir="$HOME/.claude/projects/$enc"
  [ -d "$dir" ] || return 1
  # shellcheck disable=SC2012  # transcript names are session UUIDs (no odd chars); ls -t by mtime is exactly the pick
  newest=$(ls -1t "$dir"/*.jsonl 2>/dev/null | head -n1) || return 1
  [ -n "$newest" ] || return 1
  last=$(tail -n 40 "$newest" 2>/dev/null) || return 1
  printf '%s\n' "$last" | grep -q '"tool_use"' || return 1
  # A tool_result after the last tool_use means the tool resolved — no pending approval.
  usel=$(printf '%s\n' "$last" | grep -n '"tool_use"'   | tail -n1 | cut -d: -f1) || return 1
  resl=$(printf '%s\n' "$last" | grep -n '"tool_result"' | tail -n1 | cut -d: -f1) || true
  [ -n "$usel" ] || return 1
  if [ -n "$resl" ] && [ "$resl" -gt "$usel" ]; then return 1; fi
  return 0
}

# Populate caller-scoped fields for one task file (dynamic scope: caller declares them local).
_st_load() {
  local repo mt now newest thr silence_secs sflag fresh
  id=$(fm_get "$1" id); title=$(fm_get "$1" title); status=$(fm_get "$1" status)
  branch=$(fm_get "$1" branch); worktree=$(fm_get "$1" worktree); model=$(fm_get "$1" model)
  port=$(fm_get "$1" port); question=$(fm_get "$1" question); updated=$(fm_get "$1" updated)
  repo=$(conf_get repo)
  last_commit=$(git -C "$repo" log -1 --format=%ct "$branch" -- 2>/dev/null || true)
  mt=$(date -r "$1" +%s); newest=$mt
  [ -n "$last_commit" ] && [ "$last_commit" -gt "$newest" ] && newest=$last_commit
  now=$(date +%s); thr=${BENCH_STALE_SECS:-1200}
  is_stale=false
  if [ "$status" = working ] && [ $((now-newest)) -gt "$thr" ]; then is_stale=true; fi
  session="bench-$(tmux_safe "$(project_name)")-$id"
  alive=false; if btmux has-session -t "=$session" 2>/dev/null; then alive=true; fi

  # needs-input (spec §5, ALL advisory — chips/json only, NEVER a state transition):
  # working AND alive AND the window's silence flag is set AND no fresh commit within the window.
  needs_input=false; needs_input_confirmed=false
  if [ "$status" = working ] && [ "$alive" = true ]; then
    silence_secs=${BENCH_SILENCE_SECS:-60}
    fresh=false
    [ -n "$last_commit" ] && [ $((now-last_commit)) -le "$silence_secs" ] && fresh=true
    sflag=$(btmux display-message -p -t "=$session:" '#{window_silence_flag}' 2>/dev/null || true)
    if [ "$sflag" = 1 ] && [ "$fresh" = false ]; then
      needs_input=true
      # Confidence upgrade (layer 3 + 2.5), evaluated ONLY once the silence gate has fired.
      if _st_prompt_signature "$session"; then needs_input_confirmed=true; fi
      if [ "${BENCH_TRANSCRIPT_HINTS:-}" = 1 ] && _st_transcript_hint "$worktree"; then
        needs_input_confirmed=true
      fi
    fi
  fi
}
_st_json_obj() {   # flat --json object (contract key order)
  printf '{"id":"%s","title":"%s","status":"%s","branch":"%s","worktree":"%s","model":"%s","port":%s,"question":"%s","updated":"%s","last_commit":%s,"stale":%s,"needs_input":%s}' \
    "$(_st_esc "$id")" "$(_st_esc "$title")" "$(_st_esc "$status")" "$(_st_esc "$branch")" \
    "$(_st_esc "$worktree")" "$(_st_esc "$model")" "${port:-0}" "$(_st_esc "$question")" \
    "$(_st_esc "$updated")" "${last_commit:-null}" "$is_stale" "$needs_input"
}

# _st_bell_and_cache <cache-lines> — heartbeat-only (spec acceptance 3). Diffs the just-computed
# per-task lines ("<id> <status> <needs01>") against $(state_dir)/.git/bench.lastseen, rings the
# crew window's bell when a task newly needs attention, then rewrites the cache atomically. Shares
# the one bench lock (never invent a second). Fully guarded — never breaks a status run.
_st_bell_and_cache() {
  local newcache=$1 cache proj sess
  # Pre-init there is no .git to hold the lock/cache — degrade silently like every
  # other status form does (the conf's status-right runs this form every 5s).
  [ -d "$(state_dir)/.git" ] || return 0
  cache="$(state_dir)/.git/bench.lastseen"
  proj=$(project_name); sess=$(tmux_safe "$proj")
  (
    flock -w 5 9 2>/dev/null || true
    local ring=0 id2 st2 need2 old ost oneed tmp tty
    while IFS=' ' read -r id2 st2 need2; do
      [ -n "$id2" ] || continue
      old=$(grep -m1 "^$id2 " "$cache" 2>/dev/null || true)
      if [ -z "$old" ]; then
        # No cached line (fresh cache / first sight): ding if it already needs attention.
        { [ "$st2" = blocked ] || [ "$st2" = review ] || [ "$need2" = 1 ]; } && ring=1
      else
        ost=$(printf '%s' "$old" | awk '{print $2}')
        oneed=$(printf '%s' "$old" | awk '{print $3}')
        { [ "$st2" != "$ost" ] && { [ "$st2" = blocked ] || [ "$st2" = review ]; }; } && ring=1
        { [ "$need2" = 1 ] && [ "${oneed:-0}" != 1 ]; } && ring=1
      fi
    done <<< "$newcache"
    tmp=$(mktemp "$(state_dir)/.git/.lastseen.XXXXXX")
    printf '%s' "$newcache" > "$tmp" && mv "$tmp" "$cache"
    if [ "$ring" = 1 ]; then
      # Write BEL to the crew pane's own tty — proven to set #{window_bell_flag} on a detached
      # server (tty-write works; see tests/run.sh t27). Skip silently if crew is absent.
      tty=$(btmux display-message -p -t "=$sess:crew" '#{pane_tty}' 2>/dev/null || true)
      [ -n "$tty" ] && [ -e "$tty" ] && { printf '\a' > "$tty" 2>/dev/null || true; }
    fi
  ) 9>>"$(state_dir)/.git/bench.lock"
}

cmd_status() {
  local json=0 tree=0 stale=0 tmux=0 refresh=0 a first ascii d f out
  local id title status branch worktree model port question updated last_commit is_stale session alive
  local needs_input needs_input_confirmed chip glyph col need01 ranges cachelines n
  for a in "$@"; do case "$a" in
    --json) json=1 ;; --tree) tree=1 ;; --stale) stale=1 ;; --tmux) tmux=1 ;;
    --refresh-titles) refresh=1 ;;
    *) die "status: unknown flag: $a" ;; esac; done
  d=$(state_dir); local files=()
  for f in "$d"/tasks/T-*.md; do [ -e "$f" ] && files+=("$f"); done
  if [ "$json" = 1 ] && [ "$tree" = 1 ]; then
    printf '{"project":"%s","session":"%s","generated":"%s","nodes":[{"type":"workbench","name":"%s","children":[' \
      "$(project_name)" "$(project_name)" "$(now_iso)" "$(project_name)"
    first=1
    for f in ${files[@]+"${files[@]}"}; do
      _st_load "$f"; [ "$first" = 1 ] || printf ','; first=0
      printf '{"type":"worker","id":"%s","status":"%s","session":"%s","alive":%s,"title":"%s","branch":"%s","worktree":"%s","model":"%s","port":%s,"question":"%s","updated":"%s","last_commit":%s,"stale":%s,"needs_input":%s}' \
        "$(_st_esc "$id")" "$(_st_esc "$status")" "$session" "$alive" "$(_st_esc "$title")" \
        "$(_st_esc "$branch")" "$(_st_esc "$worktree")" "$(_st_esc "$model")" "${port:-0}" \
        "$(_st_esc "$question")" "$(_st_esc "$updated")" "${last_commit:-null}" "$is_stale" "$needs_input"
    done
    printf ']}]}\n'; return
  fi
  if [ "$json" = 1 ]; then
    printf '['; first=1
    for f in ${files[@]+"${files[@]}"}; do _st_load "$f"; [ "$first" = 1 ] || printf ','; first=0; _st_json_obj; done
    printf ']\n'; return
  fi
  if [ "$tmux" = 1 ]; then
    ascii=${BENCH_ASCII:-0}; out=""; cachelines=""
    ranges=0; tmux_ge34 && ranges=1         # click-to-watch ranges are a tmux >=3.4 feature (common.sh)
    for f in ${files[@]+"${files[@]}"}; do
      _st_load "$f"
      if [ "$needs_input" = true ]; then
        col=colour208                       # orange: needs you (silence ? / confirmed !)
        [ "$needs_input_confirmed" = true ] && glyph='!' || glyph='?'
      else
        case "$status" in
          working) col=green;     [ "$ascii" = 1 ] && glyph='*' || glyph='●' ;;
          blocked) col=yellow;    [ "$ascii" = 1 ] && glyph='!' || glyph='⛔' ;;
          review)  col=blue;      [ "$ascii" = 1 ] && glyph='v' || glyph='✓' ;;
          *)       col=colour244; [ "$ascii" = 1 ] && glyph='o' || glyph='○' ;;
        esac
      fi
      chip="#[fg=$col]$id $glyph$status#[default]"
      # Wrap in a click range so the conf's MouseDown1StatusRight bind can 'bench watch' the task.
      [ "$ranges" = 1 ] && chip="#[range=user|task_$id]$chip#[norange]"
      out+=" $chip"
      need01=0; [ "$needs_input" = true ] && need01=1
      cachelines+="$id $status $need01"$'\n'
      # --refresh-titles combined with --tmux: silent side effect (keeps pane-border titles fresh).
      if [ "$refresh" = 1 ] && [ "$alive" = true ]; then
        btmux select-pane -t "=$session:" -T "$id · $status" 2>/dev/null || true
      fi
    done
    _st_bell_and_cache "$cachelines"        # bell-on-transition + cache, heartbeat only
    printf '%s\n' "$out"; return
  fi
  if [ "$refresh" = 1 ]; then               # --refresh-titles alone: retitle + a receipt
    n=0
    for f in ${files[@]+"${files[@]}"}; do
      _st_load "$f"
      [ "$alive" = true ] || continue
      btmux select-pane -t "=$session:" -T "$id · $status" 2>/dev/null || true
      n=$((n+1))
    done
    echo "retitled $n worker pane(s)"; return
  fi
  if [ "$stale" = 1 ]; then
    for f in ${files[@]+"${files[@]}"}; do _st_load "$f"; [ "$is_stale" = true ] && echo "$id"; done
    return 0                     # bare return would propagate the last non-stale test's status 1
  fi
  printf '%-7s %-8s %-16s %-6s %-5s %s\n' ID STATUS BRANCH MODEL PORT TITLE
  for f in ${files[@]+"${files[@]}"}; do
    _st_load "$f"
    printf '%-7s %-8s %-16s %-6s %-5s %s\n' "$id" "$status" "$branch" "$model" "$port" "$title"
  done
}
