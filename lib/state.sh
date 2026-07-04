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
  local allow='{"permissions":{"allow":["Bash(git add:*)","Bash(git commit:*)","Bash(bench task set:*)","Bash(npm test:*)","Bash(tsc:*)"]}}'
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
# Populate caller-scoped fields for one task file (dynamic scope: caller declares them local).
_st_load() {
  local repo mt now newest thr
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
}
_st_json_obj() {   # flat --json object (contract key order)
  printf '{"id":"%s","title":"%s","status":"%s","branch":"%s","worktree":"%s","model":"%s","port":%s,"question":"%s","updated":"%s","last_commit":%s,"stale":%s}' \
    "$(_st_esc "$id")" "$(_st_esc "$title")" "$(_st_esc "$status")" "$(_st_esc "$branch")" \
    "$(_st_esc "$worktree")" "$(_st_esc "$model")" "${port:-0}" "$(_st_esc "$question")" \
    "$(_st_esc "$updated")" "${last_commit:-null}" "$is_stale"
}

cmd_status() {
  local json=0 tree=0 stale=0 tmux=0 a first ascii g c d f out
  local id title status branch worktree model port question updated last_commit is_stale session alive
  for a in "$@"; do case "$a" in
    --json) json=1 ;; --tree) tree=1 ;; --stale) stale=1 ;; --tmux) tmux=1 ;;
    *) die "status: unknown flag: $a" ;; esac; done
  d=$(state_dir); local files=()
  for f in "$d"/tasks/T-*.md; do [ -e "$f" ] && files+=("$f"); done
  if [ "$json" = 1 ] && [ "$tree" = 1 ]; then
    printf '{"project":"%s","session":"%s","generated":"%s","nodes":[{"type":"workbench","name":"%s","children":[' \
      "$(project_name)" "$(project_name)" "$(now_iso)" "$(project_name)"
    first=1
    for f in ${files[@]+"${files[@]}"}; do
      _st_load "$f"; [ "$first" = 1 ] || printf ','; first=0
      printf '{"type":"worker","id":"%s","status":"%s","session":"%s","alive":%s,"title":"%s","branch":"%s","worktree":"%s","model":"%s","port":%s,"question":"%s","updated":"%s","last_commit":%s,"stale":%s}' \
        "$(_st_esc "$id")" "$(_st_esc "$status")" "$session" "$alive" "$(_st_esc "$title")" \
        "$(_st_esc "$branch")" "$(_st_esc "$worktree")" "$(_st_esc "$model")" "${port:-0}" \
        "$(_st_esc "$question")" "$(_st_esc "$updated")" "${last_commit:-null}" "$is_stale"
    done
    printf ']}]}\n'; return
  fi
  if [ "$json" = 1 ]; then
    printf '['; first=1
    for f in ${files[@]+"${files[@]}"}; do _st_load "$f"; [ "$first" = 1 ] || printf ','; first=0; _st_json_obj; done
    printf ']\n'; return
  fi
  if [ "$tmux" = 1 ]; then
    ascii=${BENCH_ASCII:-0}; out=""
    for f in ${files[@]+"${files[@]}"}; do
      _st_load "$f"
      case "$status" in
        working) c=green;     [ "$ascii" = 1 ] && g='*' || g='●' ;;
        blocked) c=yellow;    [ "$ascii" = 1 ] && g='!' || g='⛔' ;;
        review)  c=blue;      [ "$ascii" = 1 ] && g='v' || g='✓' ;;
        *)       c=colour244; [ "$ascii" = 1 ] && g='o' || g='○' ;;
      esac
      out+=" #[fg=$c]$id $g$status#[default]"
    done
    printf '%s\n' "$out"; return
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
