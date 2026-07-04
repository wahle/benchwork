# bench common helpers — sourced by bin/bench. Shared by all verb layers.
BENCH_HOME=${BENCH_HOME:-$HOME/.bench}

die() { echo "bench: $*" >&2; exit 1; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# All tmux calls go through btmux so tests can isolate on a private socket.
btmux() {
  if [ -n "${BENCH_TMUX_SOCKET:-}" ]; then command tmux -L "$BENCH_TMUX_SOCKET" "$@"
  else command tmux "$@"; fi
}

repo_root() { git rev-parse --show-toplevel 2>/dev/null || die "not inside a git repo (or set BENCH_PROJECT)"; }

project_name() {
  if [ -n "${BENCH_PROJECT:-}" ]; then echo "$BENCH_PROJECT"; else basename "$(repo_root)"; fi
}
state_dir() { echo "$BENCH_HOME/$(project_name)"; }
tmux_safe() { local s=${1//[.:]/_}; printf '%s\n' "${s// /_}"; }  # tmux session names: no dots/colons/spaces

conf_get() { # conf_get <key> [default]
  local v
  v=$(grep -m1 "^$1=" "$(state_dir)/project.conf" 2>/dev/null | cut -d= -f2-) || true
  echo "${v:-${2:-}}"
}

norm_id() { # 42 | T-42 | T-042  ->  T-042
  local n=${1#T-}
  [[ $n =~ ^[0-9]+$ ]] || die "bad task id: $1"
  printf 'T-%03d' "$((10#$n))"
}
task_file() { echo "$(state_dir)/tasks/$(norm_id "$1").md"; }
task_num() { local id; id=$(norm_id "$1"); echo "$((10#${id#T-}))"; }

fm_get() { # fm_get <file> <key>  — read one frontmatter value
  awk -v k="$2" '
    NR==1 && /^---$/ { infm=1; next }
    infm && /^---$/ { exit }
    infm && index($0, k": ")==1 { print substr($0, length(k)+3); exit }
    infm && $0 == k":" { print ""; exit }' "$1"
}

fm_set() { # fm_set <file> <key> <value>  — atomic write (temp file + mv)
  # value forced single-line (newlines would break out of the frontmatter fence);
  # passed via ENVIRON, not awk -v, so backslash sequences stay literal
  local tmp v=${3//$'\n'/ }
  tmp=$(mktemp "$(dirname "$1")/.fm.XXXXXX")
  FMV=$v awk -v k="$2" '
    NR==1 && /^---$/ { infm=1; print; next }
    infm && /^---$/ { if (!done) { print k": " ENVIRON["FMV"]; done=1 }; infm=0; print; next }
    infm && (index($0, k": ")==1 || $0 == k":") { print k": " ENVIRON["FMV"]; done=1; next }
    { print }' "$1" >"$tmp" && mv "$tmp" "$1"
}

require_task() { # require_task <id> — print the task file path; die archive-aware if gone
  local id=$1 tf arch st
  tf="$(state_dir)/tasks/$id.md"
  if [ -f "$tf" ]; then echo "$tf"; return 0; fi
  arch="$(state_dir)/archive/$id.md"
  if [ -f "$arch" ]; then
    st=$(fm_get "$arch" status)
    die "$id is already $st and archived — see $arch. 'bench status' shows the active tasks"
  fi
  die "no such task: $id — run 'bench status' to see the current tasks"
}

tmux_ge34() { # 0 iff the running tmux is >= 3.4 (status-line click ranges land in 3.4)
  # Non-numeric build tags ("next-3.5") count as >= 3.4; integer maj/min compare so a
  # hypothetical 3.10 doesn't lose to 3.4 the way a float compare would.
  local raw v maj min
  raw=$(btmux -V 2>/dev/null | awk '{print $2}') || true
  [ -n "$raw" ] || return 1
  v=${raw%%[!0-9.]*}                 # "3.4a"->"3.4"; "next-3.5"->"" (leading non-digit)
  [ -n "$v" ] || return 0            # unparseable tag: assume modern
  maj=${v%%.*}
  case "$v" in *.*) min=${v#*.}; min=${min%%.*} ;; *) min=0 ;; esac
  [ "${maj:-0}" -gt 3 ] && return 0
  { [ "${maj:-0}" -eq 3 ] && [ "${min:-0}" -ge 4 ]; } && return 0
  return 1
}

task_globs() { # task_globs <taskfile> — globs from '## Expected files' (inline comments stripped)
  awk '/^## Expected files/{f=1;next} /^## /{f=0} f&&/^- /{sub(/^- +/,"");sub(/[ \t].*/,"");print}' "$1"
}

state_commit() { # state_commit <message>  — audit-trail commit of the state dir
  local d; d=$(state_dir)
  # || true: concurrent writers contend on .git/index.lock; the file write already
  # landed (atomic mv), so a skipped audit commit coalesces into the next one
  git -C "$d" add -A >/dev/null 2>&1 || true
  git -C "$d" commit -qm "$*" >/dev/null 2>&1 || true
}
