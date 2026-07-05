#!/usr/bin/env bash
# bench slice-1 test harness — standalone, no bats. TAP-ish output.
#
# Asserts the behaviours pinned in docs/slice1_contract.md and the acceptance
# tests in docs/bench_spec.md §6. Every run is fully isolated: a private tmux
# socket, a scratch BENCH_HOME, and a throwaway fixture git repo under mktemp.
# Nothing touches the developer's real tmux server, ~/.bench, or the project repo.
#
# Usage:  tests/run.sh            (exit 0 iff every assertion passes)
#
# NOTE: state.sh / tmuxops.sh may still be stubs while other agents implement
# them; against stubs these tests report `not ok`, which is the intended signal.

# `bench done <id>` uses `done` as a literal verb argument; shellcheck reads it as
# the loop keyword (SC1010). A stray keyword would fail `bash -n` anyway, so silence it.
# shellcheck disable=SC1010
set -u

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# ---- isolation env (must be set before sourcing common.sh / calling bench) ----
WORK=$(mktemp -d)
export BENCH_HOME="$WORK/home"
export BENCH_TMUX_SOCKET="benchtest$$"
export BENCH_CLAUDE="$REPO/tests/mock-claude"
export PATH="$REPO/bin:$PATH"
# Worktrees created by `git worktree add` inherit no committer identity from a
# bare env; give bench's own commits (run in this process) an identity too.
export GIT_AUTHOR_NAME=bench-test GIT_AUTHOR_EMAIL=test@bench.test
export GIT_COMMITTER_NAME=bench-test GIT_COMMITTER_EMAIL=test@bench.test

FIX="$WORK/fixture"

tmuxs() { command tmux -L "$BENCH_TMUX_SOCKET" "$@"; }

cleanup() {
  cd / 2>/dev/null || true
  tmuxs kill-server 2>/dev/null || true
  command tmux -L "conflint$$" kill-server 2>/dev/null || true   # t26's throwaway conf-lint server
  rm -f "${TMUX_TMPDIR:-/tmp/tmux-$(id -u)}/$BENCH_TMUX_SOCKET" 2>/dev/null || true  # dead socket inode
  git -C "$FIX" worktree prune 2>/dev/null || true
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---- fixture repo: one real commit on main ----
mkdir -p "$FIX/src"
git -C "$FIX" init -qb main
git -C "$FIX" config user.email test@bench.test
git -C "$FIX" config user.name bench-test
printf 'hello\n' > "$FIX/README.md"
git -C "$FIX" add -A
git -C "$FIX" commit -qm "initial fixture commit"
cd "$FIX" || { echo "cannot cd to fixture"; exit 2; }

# common.sh gives us fm_get / task_file / state_dir for *reading* state the same
# way bench writes it — these are the "done, use it" shared helpers.
# shellcheck source=/dev/null
. "$REPO/lib/common.sh"

# ---- TAP-ish reporting ----
TESTNUM=0
FAILS=0
report() { # report <desc> <rc> [diag]   rc==0 => pass
  TESTNUM=$((TESTNUM + 1))
  if [ "$2" -eq 0 ]; then
    printf 'ok %d - %s\n' "$TESTNUM" "$1"
  else
    FAILS=$((FAILS + 1))
    printf 'not ok %d - %s\n' "$TESTNUM" "$1"
    [ -n "${3:-}" ] && printf '# %s\n' "$3"
  fi
}
t() { # t <desc> <cmd...>   pass iff cmd exits 0
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then report "$d" 0; else report "$d" 1; fi
}

task_status() { fm_get "$(task_file "$1")" status; }
poll_status() { # poll_status <id> <want> <timeout_secs>
  local end; end=$(( $(date +%s) + $3 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    [ "$(task_status "$1" 2>/dev/null)" = "$2" ] && return 0
    sleep 0.3
  done
  return 1
}

# =====================================================================
# Test 1 — init: state dir, config, git-init, idempotent re-run
# =====================================================================
t "t1 init exits 0" bench init
SD=$(state_dir)
# Give the state-dir audit repo an identity so mock-driven state_commits succeed.
git -C "$SD" config user.email test@bench.test 2>/dev/null || true
git -C "$SD" config user.name bench-test 2>/dev/null || true
t "t1 state dir created"      test -d "$SD"
t "t1 project.conf written"   test -f "$SD/project.conf"
t "t1 tasks/ dir"             test -d "$SD/tasks"
t "t1 archive/ dir"           test -d "$SD/archive"
t "t1 state dir git-inited"   test -d "$SD/.git"
t "t1 state dir has >=1 commit" test "$(git -C "$SD" rev-list --count HEAD 2>/dev/null || echo 0)" -ge 1
conf_before=$(cat "$SD/project.conf" 2>/dev/null)
t "t1 re-run exits 0" bench init
conf_after=$(cat "$SD/project.conf" 2>/dev/null)
t "t1 re-run is a no-op (conf unchanged)" test "$conf_before" = "$conf_after"

# =====================================================================
# Test 2 — task new: id/port assignment, printed path, increment
# =====================================================================
out1=$(bench task new "A" --files 'src/**' 2>/dev/null)
p1=$(printf '%s\n' "$out1" | tail -n1)
rc=0; [ -f "$p1" ] || rc=1; report "t2 task new prints path to an existing file" "$rc" "got: $p1"
t "t2 first task id=T-001"    grep -q '^id: T-001$'          "$p1"
t "t2 status=pending"         grep -q '^status: pending$'    "$p1"
t "t2 port=3001"              grep -q '^port: 3001$'         "$p1"
t "t2 branch=agent/T-001"     grep -q '^branch: agent/T-001$' "$p1"
out2=$(bench task new "B" 2>/dev/null)
p2=$(printf '%s\n' "$out2" | tail -n1)
t "t2 second task id=T-002"   grep -q '^id: T-002$'  "$p2"
t "t2 second task port=3002"  grep -q '^port: 3002$' "$p2"

# =====================================================================
# Test 3 — Acceptance 1: `up` idempotent (byte-identical, exit 0)
# =====================================================================
bench up >/dev/null 2>&1
win_before=$(tmuxs list-windows -t fixture -F '#{window_index}:#{window_name}' 2>/dev/null)
t "t3 up second run exits 0" bench up
win_after=$(tmuxs list-windows -t fixture -F '#{window_index}:#{window_name}' 2>/dev/null)
rc=0; [ "$win_before" = "$win_after" ] || rc=1
report "t3 list-windows byte-identical across re-run" "$rc" "before=[$win_before] after=[$win_after]"
t "t3 deck window exists" grep -q deck <<<"$win_after"
t "t3 crew window exists" grep -q crew <<<"$win_after"

# =====================================================================
# Test 4 — Acceptance 2: spawn (idle worker so `working` is observable)
# =====================================================================
# Select idle behaviour through the task file (the channel spawn actually forwards),
# so this worker never commits or changes status — `working` stays observable.
bench task set T-001 mockmode idle >/dev/null 2>&1
t "t4 spawn exits 0" bench spawn T-001
WT="$WORK/fixture-T-001"
rc=0; [ -d "$WT" ] || rc=1; report "t4 worktree directory exists" "$rc" "expected $WT"
git -C "$FIX" worktree list 2>/dev/null | grep -q agent/T-001; rc=$?
report "t4 worktree on branch agent/T-001" "$rc"
# idle mock never touches status, so it is still exactly what spawn set it to.
rc=0; [ "$(task_status T-001)" = working ] || rc=1
report "t4 status flipped to working" "$rc" "got $(task_status T-001)"
t "t4 worker tmux session exists" tmuxs has-session -t bench-fixture-T-001
git -C "$SD" log --oneline 2>/dev/null | grep -q T-001; rc=$?
report "t4 state-dir git log has spawn commits" "$rc"

# =====================================================================
# Test 5 — worker loop closes: default mock commits + flips to review
# =====================================================================
out3=$(bench task new "C" 2>/dev/null)
p3=$(printf '%s\n' "$out3" | tail -n1)
t "t5 third task id=T-003" grep -q '^id: T-003$' "$p3"
bench spawn T-003 >/dev/null 2>&1
rc=0; poll_status T-003 review 15 || rc=1
report "t5 worker set status=review within 15s" "$rc" "status=$(task_status T-003)"
t "t5 worker committed on agent/T-003" \
  test "$(git -C "$FIX" rev-list --count agent/T-003 2>/dev/null || echo 0)" -ge 2

# =====================================================================
# Test 6 — Acceptance 8: rapid task set on distinct keys stays intact.
# Spec §6.8's mechanism is "atomic mv", which guarantees no corruption always
# and no lost update for *sequential* rapid writes; cmd_task_set additionally
# flocks the state dir, so truly concurrent same-file writes on distinct keys
# must BOTH persist — a hard assertion since the lock landed.
# =====================================================================
bench task set T-002 model sonnet >/dev/null 2>&1
bench task set T-002 port 4242    >/dev/null 2>&1
grep -q '^model: sonnet$' "$p2"; r1=$?
grep -q '^port: 4242$'    "$p2"; r2=$?
report "t6 back-to-back writes on two keys both persist" $(( r1 || r2 ))
bench task set T-002 title concurA    >/dev/null 2>&1 & bp1=$!
bench task set T-002 question concurB >/dev/null 2>&1 & bp2=$!
brc=0; wait "$bp1" || brc=1; wait "$bp2" || brc=1
report "t6 both backgrounded task set calls exit 0" "$brc"
t "t6 concurrent writes leave exactly one frontmatter pair" test "$(grep -c '^---$' "$p2")" -eq 2
rc=0; [ "$(fm_get "$p2" id)" = T-002 ] || rc=1
report "t6 frontmatter still parses after concurrent writes" "$rc"
grep -q '^title: concurA$'    "$p2"; r3=$?
grep -q '^question: concurB$' "$p2"; r4=$?
report "t6 truly concurrent same-file writes both persist (flock)" $(( r3 || r4 ))

# =====================================================================
# Test 7 — Acceptance 4: --stale flags idle worker, not a fresh one
# =====================================================================
export BENCH_STALE_SECS=1
sleep 2                                    # push the idle T-001 past the threshold
bench task new "D" >/dev/null 2>&1         # T-004, fresh
bench task set T-004 status working >/dev/null 2>&1   # working + freshly updated
stale=$(bench status --stale 2>/dev/null)
t "t7 --stale lists the idle worker" grep -q 'T-001' <<<"$stale"
rc=0; grep -q 'T-004' <<<"$stale" && rc=1
report "t7 --stale omits a freshly-updated task" "$rc" "stale=[$stale]"
unset BENCH_STALE_SECS

# =====================================================================
# Test 8 — status --json / --json --tree / --tmux
# =====================================================================
json=$(bench status --json 2>/dev/null)
jq -e . >/dev/null 2>&1 <<<"$json"; rc=$?; report "t8 --json parses" "$rc"
jq -e '.[0]|has("id") and has("status") and has("port") and has("last_commit") and has("stale")' \
  >/dev/null 2>&1 <<<"$json"; rc=$?; report "t8 --json has expected keys" "$rc"
jq -e '.[0].port|type=="number"' >/dev/null 2>&1 <<<"$json"; rc=$?
report "t8 --json port is a number" "$rc"

tree=$(bench status --json --tree 2>/dev/null)
jq -e . >/dev/null 2>&1 <<<"$tree"; rc=$?; report "t8 --json --tree parses" "$rc"
jq -e '.nodes[0].type=="workbench"' >/dev/null 2>&1 <<<"$tree"; rc=$?
report "t8 tree root node type==workbench" "$rc"
jq -e '.nodes[0].children[]|select(.id=="T-001")|.session=="bench-fixture-T-001"' \
  >/dev/null 2>&1 <<<"$tree"; rc=$?; report "t8 tree worker session==bench-fixture-T-001" "$rc"
jq -e '.nodes[0].children[]|select(.id=="T-001")|(.alive|type)=="boolean"' \
  >/dev/null 2>&1 <<<"$tree"; rc=$?; report "t8 tree worker alive is boolean" "$rc"

tmline=$(bench status --tmux 2>/dev/null)
rc=0; [ -n "$tmline" ] || rc=1; report "t8 --tmux emits nonempty output" "$rc"
t "t8 --tmux is a single line" test "$(printf '%s\n' "$tmline" | wc -l)" -eq 1
bench task set T-002 status blocked >/dev/null 2>&1
bench status --tmux 2>/dev/null | grep -qE '⛔|fg=yellow'; rc=$?
report "t8 --tmux marks blocked task yellow/blocked-glyph" "$rc"

# =====================================================================
# Test 9 — task set with a value containing spaces
# =====================================================================
bench task set T-002 title "hello world foo" >/dev/null 2>&1
t "t9 spaced value persists intact" grep -q '^title: hello world foo$' "$p2"

# =====================================================================
# Test 10 — B1: dotted project name is sanitized in tmux session names.
# A repo dir named `my.app` → session `bench-my_app-T-001`; up stays idempotent.
# =====================================================================
FIX2="$WORK/my.app"
mkdir -p "$FIX2"
git -C "$FIX2" init -qb main
git -C "$FIX2" config user.email test@bench.test
git -C "$FIX2" config user.name bench-test
printf 'x\n' > "$FIX2/f"; git -C "$FIX2" add -A; git -C "$FIX2" commit -qm "init my.app"
cd "$FIX2" || { echo "cannot cd to my.app fixture"; exit 2; }
bench init >/dev/null 2>&1
SD2=$(state_dir)
git -C "$SD2" config user.email test@bench.test 2>/dev/null || true
git -C "$SD2" config user.name bench-test 2>/dev/null || true
bench up >/dev/null 2>&1; e1=$?
w2_before=$(tmuxs list-windows -t my_app -F '#{window_index}:#{window_name}' 2>/dev/null)
bench up >/dev/null 2>&1; e2=$?
w2_after=$(tmuxs list-windows -t my_app -F '#{window_index}:#{window_name}' 2>/dev/null)
rc=0; { [ "$e1" -eq 0 ] && [ "$e2" -eq 0 ]; } || rc=1
report "t10 up twice exits 0 on dotted project name" "$rc"
rc=0; [ -n "$w2_before" ] && [ "$w2_before" = "$w2_after" ] || rc=1
report "t10 up is a byte-identical no-op on dotted name" "$rc" "before=[$w2_before] after=[$w2_after]"
bench task new "dotted" >/dev/null 2>&1                 # T-001 in the my.app state dir
bench task set T-001 mockmode idle >/dev/null 2>&1
bench spawn T-001 >/dev/null 2>&1
tree2=$(bench status --json --tree 2>/dev/null)
jq -e '.nodes[0].children[]|select(.id=="T-001")|.session=="bench-my_app-T-001"' >/dev/null 2>&1 <<<"$tree2"
rc=$?; report "t10 tree worker session sanitized to bench-my_app-T-001" "$rc"
rc=1; for _ in $(seq 1 30); do
  jq -e '.nodes[0].children[]|select(.id=="T-001")|.alive==true' \
    >/dev/null 2>&1 <<<"$(bench status --json --tree 2>/dev/null)" && { rc=0; break; }
  sleep 0.2
done
report "t10 dotted-name worker session alive==true" "$rc"
cd "$FIX" || { echo "cannot cd back to fixture"; exit 2; }

# =====================================================================
# Test 11 — B2: newline in a value can't break out of the frontmatter fence;
# literal backslash-n text is stored verbatim (fm_set via ENVIRON, not awk -v).
# =====================================================================
p5=$(bench task new "B2" 2>/dev/null | tail -n1)        # T-005, pending
bench task set T-005 title "$(printf 'evil\n---\nHIJACKED')" >/dev/null 2>&1
t "t11 exactly two frontmatter fence lines after newline injection" \
  test "$(grep -c '^---$' "$p5")" -eq 2
rc=0; [ "$(fm_get "$p5" status)" = pending ]      || rc=1; report "t11 status field still parses" "$rc"
rc=0; [ "$(fm_get "$p5" branch)" = agent/T-005 ]  || rc=1; report "t11 branch field still parses" "$rc"
rc=0; [ "$(fm_get "$p5" port)" = 3005 ]           || rc=1; report "t11 port field still parses" "$rc"
rc=0; [ "$(fm_get "$p5" title)" = "evil --- HIJACKED" ] || rc=1
report "t11 newline in title collapsed to space" "$rc" "got: [$(fm_get "$p5" title)]"
bench task set T-005 title 'a\nb' >/dev/null 2>&1
rc=0; [ "$(fm_get "$p5" title)" = 'a\nb' ] || rc=1
report "t11 literal backslash-n stored verbatim" "$rc" "got: [$(fm_get "$p5" title)]"

# =====================================================================
# Test 12 — G1: C0 control chars in a value keep JSON output valid.
# =====================================================================
bench task set T-005 title "$(printf 'a\x1bb\x07c')" >/dev/null 2>&1
jq -e . >/dev/null 2>&1 <<<"$(bench status --json 2>/dev/null)"; rc=$?
report "t12 --json parses with control chars in a title" "$rc"
jq -e . >/dev/null 2>&1 <<<"$(bench status --json --tree 2>/dev/null)"; rc=$?
report "t12 --json --tree parses with control chars in a title" "$rc"

# =====================================================================
# Test 13 — G2: 5 concurrent `task set status working` all succeed, persist,
# and leave the state repo fully committed (commits may coalesce under lock).
# =====================================================================
g2ids=()
for n in 1 2 3 4 5; do
  g2p=$(bench task new "g2-$n" 2>/dev/null | tail -n1); g2ids+=("$(fm_get "$g2p" id)")
done
gpids=()
for gid in "${g2ids[@]}"; do bench task set "$gid" status working >/dev/null 2>&1 & gpids+=($!); done
grc=0; for gp in "${gpids[@]}"; do wait "$gp" || grc=1; done
report "t13 all 5 concurrent task set calls exit 0" "$grc"
gv=0; for gid in "${g2ids[@]}"; do [ "$(fm_get "$(task_file "$gid")" status)" = working ] || gv=1; done
report "t13 all 5 tasks persisted status=working" "$gv"
gf=0; for gid in "${g2ids[@]}"; do [ "$(grep -c '^---$' "$(task_file "$gid")")" -eq 2 ] || gf=1; done
report "t13 all 5 task files keep intact frontmatter" "$gf"
git -C "$SD" rev-parse HEAD >/dev/null 2>&1; rc=$?
report "t13 state-dir HEAD commit exists" "$rc"
rc=0; [ -z "$(git -C "$SD" status --porcelain 2>/dev/null)" ] || rc=1
report "t13 state-dir working tree clean (changes swept into a commit)" "$rc" \
  "dirty: [$(git -C "$SD" status --porcelain 2>/dev/null | tr '\n' ';')]"

# =====================================================================
# Test 14 — N2: a failed worker launch rolls back the worktree (no orphan).
# Force `btmux new-session` to fail via a read-only tmux socket dir; the
# existing-session guard runs before worktree add, so this exercises the
# rollback branch (new-session failure after worktree add), not the guard.
# =====================================================================
rbp=$(bench task new "rollback" 2>/dev/null | tail -n1)   # T-011, pending
rbid=$(fm_get "$rbp" id)
mkdir -p "$WORK/ro"; chmod 500 "$WORK/ro"
TMUX_TMPDIR="$WORK/ro" BENCH_TMUX_SOCKET="rbbrk" bench spawn "$rbid" >/dev/null 2>&1; rc=$?
chmod 700 "$WORK/ro" 2>/dev/null || true
rc2=0; [ "$rc" -ne 0 ] || rc2=1; report "t14 spawn fails cleanly when worker launch fails" "$rc2"
rc=0; [ "$(fm_get "$rbp" status)" = pending ] || rc=1
report "t14 task stays pending after failed spawn" "$rc"
wt14="$WORK/$(project_name)-$rbid"
rc=0; [ ! -e "$wt14" ] || rc=1; report "t14 no orphan worktree directory remains" "$rc" "still exists: $wt14"
git -C "$FIX" worktree list 2>/dev/null | grep -q "$rbid"; rc=$?
rc2=0; [ "$rc" -ne 0 ] || rc2=1; report "t14 worktree not registered in git after rollback" "$rc2"

# =====================================================================
# Slice 2 — review/merge path (watch/review/done/resume/nudge/abandon).
# Asserts docs/slice2_contract.md. These verbs are implemented by the
# review-merge and session-verbs agents; against their `die "not implemented"`
# stubs the positive assertions here report `not ok` — the intended red signal.
# (Gate assertions that expect a *die* will pass against a stub too, since the
# stub also dies; they are correct against the real gate.)
# =====================================================================

# A long-lived `diffpane` stand-in: `bench watch` picks it (command -v diffpane)
# and the deck pane it launches stays resident so pane_current_path is observable.
# BOTH this process (for bench's own command -v) AND the tmux server (for the pane
# that runs it) must resolve it — export it onto PATH and push that PATH into the
# server's global environment, which split-window/respawn-pane children inherit.
mkdir -p "$WORK/shimbin"
printf '#!/bin/sh\nexec sleep 300\n' > "$WORK/shimbin/diffpane"
chmod +x "$WORK/shimbin/diffpane"
export PATH="$WORK/shimbin:$PATH"
bench up >/dev/null 2>&1
tmuxs set-environment -g PATH "$PATH" 2>/dev/null || true

SESS=fixture
wt_of() { fm_get "$(task_file "$1")" worktree; }   # worktree path recorded by spawn
# the deck pane tagged @bench_role=diffpane: its current path / id / how many exist
diffpane_path() { tmuxs list-panes -t "=$1:deck" -F '#{pane_id} #{@bench_role} #{pane_current_path}' 2>/dev/null | awk '$2=="diffpane"{print $3; exit}'; }
diffpane_id()   { tmuxs list-panes -t "=$1:deck" -F '#{pane_id} #{@bench_role}' 2>/dev/null | awk '$2=="diffpane"{print $1; exit}'; }
diffpane_count(){ tmuxs list-panes -t "=$1:deck" -F '#{@bench_role}' 2>/dev/null | grep -cx diffpane; }
poll_diffpane() { # <sess> <want_wt> <timeout> — wait until the diffpane follows want (realpath-compared)
  local end p; end=$(( $(date +%s) + $3 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    p=$(diffpane_path "$1")
    [ -n "$p" ] && [ "$(realpath "$p" 2>/dev/null)" = "$(realpath "$2" 2>/dev/null)" ] && return 0
    sleep 0.2
  done
  return 1
}
mk_task() { NEWP=$(bench task new "$@" 2>/dev/null | tail -n1); NEWID=$(fm_get "$NEWP" id); }

# =====================================================================
# Test 15 — Acceptance 5: watch re-points the deck diffpane pane IN PLACE
# =====================================================================
mk_task "watch-A"; wa=$NEWID
mk_task "watch-B"; wb=$NEWID
bench task set "$wa" mockmode idle >/dev/null 2>&1
bench task set "$wb" mockmode idle >/dev/null 2>&1
bench spawn "$wa" >/dev/null 2>&1
bench spawn "$wb" >/dev/null 2>&1

t "t15 watch first task exits 0" bench watch "$wa"
rc=0; [ "$(diffpane_count "$SESS")" -eq 1 ] || rc=1
report "t15 deck has exactly one diffpane pane" "$rc" "count=$(diffpane_count "$SESS")"
rc=0; poll_diffpane "$SESS" "$(wt_of "$wa")" 5 || rc=1
report "t15 diffpane follows first task's worktree" "$rc" "have=$(diffpane_path "$SESS") want=$(wt_of "$wa")"
pid_a=$(diffpane_id "$SESS")
t "t15 watch second task exits 0" bench watch "$wb"
rc=0; poll_diffpane "$SESS" "$(wt_of "$wb")" 5 || rc=1
report "t15 diffpane repointed to second task's worktree" "$rc" "have=$(diffpane_path "$SESS") want=$(wt_of "$wb")"
pid_b=$(diffpane_id "$SESS")
rc=0; { [ -n "$pid_a" ] && [ "$pid_a" = "$pid_b" ]; } || rc=1
report "t15 same pane id reused (repoint in place, not a new pane)" "$rc" "before=$pid_a after=$pid_b"

# =====================================================================
# Test 16 — review: diffstat + A.14 expected-files detective control (read-only)
# =====================================================================
mk_task "review-pos" --files 'worker.txt'; rvpos=$NEWID   # default mock commits worker.txt → in surface
mk_task "review-neg" --files 'src/**';     rvneg=$NEWID   # worker.txt is OUTSIDE src/** → warn
bench spawn "$rvpos" >/dev/null 2>&1
bench spawn "$rvneg" >/dev/null 2>&1
poll_status "$rvpos" review 15 || true
poll_status "$rvneg" review 15 || true

rvout=$(bench review "$rvpos" 2>&1); report "t16 review (in-surface) exits 0" $?
grep -q 'worker.txt' <<<"$rvout"; report "t16 diffstat names the committed file" $?
rc=0; grep -q 'outside expected surface' <<<"$rvout" && rc=1
report "t16 in-surface commit yields no surface warning" "$rc"
rc=0; [ "$(task_status "$rvpos")" = review ] || rc=1
report "t16 review leaves status unchanged (in-surface)" "$rc" "status=$(task_status "$rvpos")"
rnout=$(bench review "$rvneg" 2>&1); report "t16 review (out-of-surface) exits 0" $?
grep -q 'outside expected surface' <<<"$rnout"; report "t16 out-of-surface warning present" $?
grep -q 'worker.txt' <<<"$rnout"; report "t16 out-of-surface warning names the offending file" $?
rc=0; [ "$(task_status "$rvneg")" = review ] || rc=1
report "t16 review leaves status unchanged (out-of-surface)" "$rc" "status=$(task_status "$rvneg")"

# =====================================================================
# Test 17 — Acceptance 6: review→done squash-merges + cleans up + archives;
# status/dirty gates die; plain-done 'n' aborts; serial-merge rebase hint.
# =====================================================================
mk_task "done-working-sib"; dsib=$NEWID       # a still-working sibling → serial-merge hint target
bench task set "$dsib" mockmode idle >/dev/null 2>&1
bench spawn "$dsib" >/dev/null 2>&1
mk_task "Land me" --files 'worker.txt'; dland=$NEWID
bench spawn "$dland" >/dev/null 2>&1
poll_status "$dland" review 15 || true

dwt="$(wt_of "$dland")"
dout=$(bench done "$dland" --yes 2>&1); report "t17 done --yes exits 0" $?
rc=0; [ "$(git -C "$FIX" log -1 --format=%s main 2>/dev/null)" = "$dland: Land me" ] || rc=1
report "t17 squash commit on base subject is '<id>: <title>'" "$rc" "got: [$(git -C "$FIX" log -1 --format=%s main 2>/dev/null)]"
rc=0; [ ! -d "$dwt" ] || rc=1; report "t17 worktree directory removed" "$rc" "still: $dwt"
rc=0; git -C "$FIX" worktree list 2>/dev/null | grep -q "$dland" && rc=1
report "t17 worktree unregistered in git" "$rc"
rc=0; git -C "$FIX" show-ref -q --verify "refs/heads/agent/$dland" && rc=1
report "t17 agent branch deleted" "$rc"
rc=0; [ -f "$SD/archive/$dland.md" ] || rc=1; report "t17 task file moved to archive/" "$rc"
rc=0; [ ! -f "$SD/tasks/$dland.md" ] || rc=1; report "t17 task file gone from tasks/" "$rc"
rc=0; [ "$(fm_get "$SD/archive/$dland.md" status 2>/dev/null)" = merged ] || rc=1
report "t17 archived task status=merged" "$rc" "status=$(fm_get "$SD/archive/$dland.md" status 2>/dev/null)"
git -C "$SD" log --oneline 2>/dev/null | grep -q "done $dland"; report "t17 state-dir log records 'done <id>'" $?
grep -q "bench nudge $dsib" <<<"$dout"; report "t17 serial-merge hint nudges the still-working sibling" $?

# gate: not-in-review dies (even with --yes, which only skips the prompt)
bench done "$dsib" --yes >/dev/null 2>&1; rc=$?
rc2=0; [ "$rc" -ne 0 ] || rc2=1; report "t17 done on a working task dies" "$rc2"
rc=0; [ "$(task_status "$dsib")" = working ] || rc=1
report "t17 working task untouched after refused done" "$rc" "status=$(task_status "$dsib")"

# gate: dirty base repo dies (fresh review task; restore the base afterwards)
mk_task "dirty-gate" --files 'worker.txt'; ddirty=$NEWID
bench spawn "$ddirty" >/dev/null 2>&1
poll_status "$ddirty" review 15 || true
printf 'dirt\n' >> "$FIX/README.md"
bench done "$ddirty" --yes >/dev/null 2>&1; rc=$?
git -C "$FIX" checkout -- README.md 2>/dev/null || true
rc2=0; [ "$rc" -ne 0 ] || rc2=1; report "t17 done on a dirty base repo dies" "$rc2"
rc=0; { [ -f "$SD/tasks/$ddirty.md" ] && [ "$(task_status "$ddirty")" = review ]; } || rc=1
report "t17 task not archived after dirty-base refusal" "$rc"

# plain `done` (no --yes) fed 'n' aborts without merging
base_before=$(git -C "$FIX" rev-parse main 2>/dev/null)
printf 'n\n' | bench done "$ddirty" >/dev/null 2>&1 || true
rc=0; { [ -f "$SD/tasks/$ddirty.md" ] && [ "$(task_status "$ddirty")" = review ]; } || rc=1
report "t17 plain done answered 'n' leaves task unmerged in review" "$rc"
rc=0; [ "$(git -C "$FIX" rev-parse main 2>/dev/null)" = "$base_before" ] || rc=1
report "t17 plain done answered 'n' adds no commit to base" "$rc"

# =====================================================================
# Test 18 — Acceptance 7: kill the server; `up` rebuilds; `resume` relaunches a
# dead worker from its task file (status intact); a second resume is a no-op.
# =====================================================================
mk_task "resume-me"; rsid=$NEWID
bench task set "$rsid" mockmode idle >/dev/null 2>&1
bench spawn "$rsid" >/dev/null 2>&1
tmuxs kill-server 2>/dev/null || true          # simulate reboot/crash: every session dies
bench up >/dev/null 2>&1                        # rebuild the navigator surface

bench resume "$rsid" >/dev/null 2>&1; report "t18 resume exits 0" $?
rc=1; for _ in $(seq 1 25); do
  tmuxs has-session -t "=bench-fixture-$rsid" 2>/dev/null && { rc=0; break; }; sleep 0.2
done
report "t18 worker session is alive again after resume" "$rc"
rc=0; [ "$(task_status "$rsid")" = working ] || rc=1
report "t18 task file intact (status still working)" "$rc" "status=$(task_status "$rsid")"
again=$(bench resume "$rsid" 2>&1)
grep -qi 'already running' <<<"$again"; report "t18 second resume reports already-running" $?

# =====================================================================
# Test 19 — nudge: send-keys delivers a line to the live worker's stdin; a dead
# worker session is refused.
# =====================================================================
mk_task "nudge-me"; ndid=$NEWID
bench task set "$ndid" mockmode listen >/dev/null 2>&1
bench spawn "$ndid" >/dev/null 2>&1
for _ in $(seq 1 15); do tmuxs has-session -t "=bench-fixture-$ndid" 2>/dev/null && break; sleep 0.2; done
bench nudge "$ndid" "hello world" >/dev/null 2>&1; report "t19 nudge exits 0 on a live worker" $?
ndlog="$(wt_of "$ndid")/nudges.log"
rc=1; nend=$(( $(date +%s) + 5 ))
while [ "$(date +%s)" -lt "$nend" ]; do
  [ -f "$ndlog" ] && grep -q 'hello world' "$ndlog" && { rc=0; break; }; sleep 0.2
done
report "t19 nudged text reaches the worker within 5s" "$rc" "log=[$(cat "$ndlog" 2>/dev/null)]"
mk_task "never-spawned"; nxid=$NEWID
bench nudge "$nxid" "anyone home" >/dev/null 2>&1; rc=$?
rc2=0; [ "$rc" -ne 0 ] || rc2=1; report "t19 nudge on a dead worker session dies" "$rc2"

# =====================================================================
# Test 20 — abandon: worktree removed, branch KEPT (salvageable), archived
# with status=abandoned; no prompt.
# =====================================================================
mk_task "abandon-me"; abid=$NEWID
bench task set "$abid" mockmode idle >/dev/null 2>&1
bench spawn "$abid" >/dev/null 2>&1
abwt="$(wt_of "$abid")"
bench abandon "$abid" >/dev/null 2>&1; report "t20 abandon exits 0" $?
rc=0; [ ! -d "$abwt" ] || rc=1; report "t20 worktree directory removed" "$rc" "still: $abwt"
rc=0; git -C "$FIX" show-ref -q --verify "refs/heads/agent/$abid" || rc=1
report "t20 agent branch kept (work salvageable)" "$rc"
rc=0; { [ -f "$SD/archive/$abid.md" ] && [ "$(fm_get "$SD/archive/$abid.md" status 2>/dev/null)" = abandoned ]; } || rc=1
report "t20 task archived with status=abandoned" "$rc" "status=$(fm_get "$SD/archive/$abid.md" status 2>/dev/null)"

# =====================================================================
# Slice-2 regression tests (t21–t25) — lock in the 5 validator NIT fixes so
# they stay fixed. Each asserts a specific hardening in lib/ (concurrency lock,
# archive-aware lookups, honest receipts, watch self-heal, legacy task files).
# =====================================================================
# t18's kill-server wiped the tmux global env; re-publish the diffpane shim PATH
# the watch-based tests below depend on (see the t15 setup note for why).
tmuxs set-environment -g PATH "$PATH" 2>/dev/null || true

# --- t21: two concurrent cold-start watches split exactly ONE diff pane (flock) ---
mk_task "concurrent-watch"; wcid=$NEWID
bench task set "$wcid" mockmode idle >/dev/null 2>&1
bench spawn "$wcid" >/dev/null 2>&1
tmuxs kill-window -t "=$SESS:deck" 2>/dev/null || true   # guarantee a clean deck: no pre-existing diffpane
bench up >/dev/null 2>&1
bench watch "$wcid" >/dev/null 2>&1 &
bench watch "$wcid" >/dev/null 2>&1 &
wait
rc=1; for _ in $(seq 1 20); do [ "$(diffpane_count "$SESS")" -ge 1 ] && { rc=0; break; }; sleep 0.2; done
report "t21 concurrent cold-start watch created a diff pane" "$rc"
rc=0; [ "$(diffpane_count "$SESS")" -eq 1 ] || rc=1
report "t21 two concurrent watches split exactly one diffpane (flock, not two)" "$rc" "count=$(diffpane_count "$SESS")"

# --- t22: archive-aware lookups name the terminal state (require_task) ---
d22=$(bench done "$dland" --yes 2>&1);  grep -q 'already merged and archived'    <<<"$d22"
report "t22 done on a merged task says 'already merged and archived'" $?
r22=$(bench resume "$abid" 2>&1);       grep -q 'already abandoned and archived' <<<"$r22"
report "t22 resume on an abandoned task says 'already abandoned and archived'" $?
n22=$(bench nudge "$dland" "hi" 2>&1);  grep -q 'already merged and archived'    <<<"$n22"
report "t22 nudge on a merged task says 'already merged and archived'" $?
x22=$(bench done "T-909" --yes 2>&1);   grep -q 'no such task'                   <<<"$x22"
report "t22 a truly-missing id still says 'no such task'" $?

# --- t23: abandon on a never-spawned task gives an honest receipt (no "removed <blank>") ---
mk_task "never-spawned-abandon"; nsid=$NEWID
a23=$(bench abandon "$nsid" 2>&1); report "t23 abandon on a never-spawned task exits 0" $?
grep -q 'never spawned' <<<"$a23"; report "t23 receipt says the worktree was never spawned" $?
rc=0; grep -q 'removed' <<<"$a23" && rc=1
report "t23 receipt does not claim it removed a (blank) worktree" "$rc" "out=[$a23]"

# --- t24: watch self-heals a manually-killed deck window ---
mk_task "selfheal"; shid=$NEWID
bench task set "$shid" mockmode idle >/dev/null 2>&1
bench spawn "$shid" >/dev/null 2>&1
tmuxs kill-window -t "=$SESS:deck" 2>/dev/null || true
rc=0; tmuxs list-windows -t "=$SESS" -F '#{window_name}' 2>/dev/null | grep -qx deck && rc=1
report "t24 deck window is gone after kill-window (precondition)" "$rc"
bench watch "$shid" >/dev/null 2>&1; report "t24 watch exits 0 with the deck window missing" $?
rc=0; tmuxs list-windows -t "=$SESS" -F '#{window_name}' 2>/dev/null | grep -qx deck || rc=1
report "t24 watch self-healed the deck window" "$rc"

# --- t25: a task file with no '## Expected files' section skips the surface check ---
mk_task "legacy-review" --files 'src/**'; lgid=$NEWID   # worker.txt would be OUT of src/** → would warn
bench spawn "$lgid" >/dev/null 2>&1
poll_status "$lgid" review 15 || true
# simulate a legacy/hand-written task file: strip the whole '## Expected files' section
sed -i '/^## Expected files$/,/^## Acceptance criteria$/{/^## Acceptance criteria$/!d}' "$(task_file "$lgid")"
l25=$(bench review "$lgid" 2>&1); report "t25 review exits 0 on a legacy task file" $?
grep -q 'surface check skipped' <<<"$l25"; report "t25 review notes the surface check was skipped" $?
rc=0; grep -q 'outside expected surface' <<<"$l25" && rc=1
report "t25 no surface warning emitted without an Expected files section" "$rc" "out=[$l25]"

# =====================================================================
# Slice 3 — polish: tmux UX, needs-input, peek/doctor/clean (t26–t33).
# Asserts docs/slice3_contract.md §A/§B/§C. These target lib/state.sh,
# lib/tools.sh, and bench.tmux.conf, which sibling agents are implementing in
# this same working tree — against their stubs the positive assertions here
# report `not ok` (the intended red signal) and go green as the code lands.
# The project session is $SESS=fixture; worker sessions are bench-fixture-<id>.
# =====================================================================

# --- t26: bench.tmux.conf parses clean on a THROWAWAY server (own socket) ---
# Must use `command tmux` (not btmux/tmuxs — those are the harness socket) with a
# private `conflint$$` server so a config parse error can't taint the test run; the
# EXIT trap also kills this server. `start-server \; kill-server` loads + tears down.
conflint_err=$(command tmux -f "$REPO/bench.tmux.conf" -L "conflint$$" start-server \; kill-server 2>&1 >/dev/null)
conflint_rc=$?
rc=0; { [ "$conflint_rc" -eq 0 ] && [ -z "$conflint_err" ]; } || rc=1
report "t26 bench.tmux.conf parses clean (exit 0, empty stderr)" "$rc" "rc=$conflint_rc stderr=[$conflint_err]"

# --- t27: Acceptance 3 — bell fires on a working→blocked transition ---
# A `status --tmux` run that observes a task newly blocked (no cache line, or a
# working→blocked change) must ring the crew window's bell. Reset semantics proven
# on this tmux 3.4 build: writing BEL to a pane tty sets #{window_bell_flag}=1 even
# detached; `select-window` on the crew window clears it back to 0. So we clear the
# flag, leave crew UN-selected (deck current) so a fresh bell can re-set it, then run.
mk_task "bell-block"; blid=$NEWID
bench task set "$blid" mockmode block >/dev/null 2>&1
bench up >/dev/null 2>&1                                  # ensure deck + crew windows exist
bench spawn "$blid" >/dev/null 2>&1
rc=0; poll_status "$blid" blocked 15 || rc=1
report "t27 block-mode worker reaches status=blocked" "$rc" "status=$(task_status "$blid")"
tmuxs select-window -t "=$SESS:crew" 2>/dev/null || true  # clear any stale bell flag
tmuxs select-window -t "=$SESS:deck" 2>/dev/null || true  # crew now unselected: a bell will register
tmout27=$(bench status --tmux 2>/dev/null)                # uncached blocked task → must bell crew
bell1=$(tmuxs display-message -p -t "=$SESS:crew" '#{window_bell_flag}' 2>/dev/null)
rc=0; [ "$bell1" = 1 ] || rc=1
report "t27 crew window bell fires when a task goes blocked" "$rc" "window_bell_flag=$bell1"
rc=0; grep -q "fg=yellow]$blid" <<<"$tmout27" || rc=1
report "t27 blocked task chip is rendered yellow" "$rc" "chip=[$(grep -oE "fg=[^]]*]$blid [^#]*" <<<"$tmout27")]"
tmuxs select-window -t "=$SESS:crew" 2>/dev/null || true  # reset flag to 0 again
tmuxs select-window -t "=$SESS:deck" 2>/dev/null || true
bench status --tmux >/dev/null 2>&1                       # still blocked, now cached → must NOT re-bell
bell2=$(tmuxs display-message -p -t "=$SESS:crew" '#{window_bell_flag}' 2>/dev/null)
rc=0; [ "$bell2" = 0 ] || rc=1
report "t27 a second --tmux on a still-blocked task does not re-bell" "$rc" "window_bell_flag=$bell2"

# --- t28: Acceptance 11 — needs-input flagged for a prompt-parked worker ---
# BENCH_SILENCE_SECS=2 shrinks both the spawn's monitor-silence value AND status's
# fresh-commit window; export it for the spawn AND the status calls (contract).
export BENCH_SILENCE_SECS=2
mk_task "needs-prompt"; npid=$NEWID
bench task set "$npid" mockmode prompt >/dev/null 2>&1
bench spawn "$npid" >/dev/null 2>&1
ni=""; rc=1; nend=$(( $(date +%s) + 15 ))                 # silence trips at ~2s; poll up to 15s
while [ "$(date +%s)" -lt "$nend" ]; do
  ni=$(bench status --json 2>/dev/null | jq -r --arg id "$npid" '.[]|select(.id==$id)|.needs_input' 2>/dev/null)
  [ "$ni" = true ] && { rc=0; break; }
  sleep 0.5
done
report "t28 prompt-parked worker flagged needs_input within 15s" "$rc" "needs_input=$ni"
tmc28=$(bench status --tmux 2>/dev/null)
rc=0; grep -q "colour208]$npid" <<<"$tmc28" || rc=1
report "t28 --tmux chip for the flagged task is orange (colour208)" "$rc" "line=[$(grep -oE "colour208]$npid [^#]*" <<<"$tmc28")]"
rc=0; grep -qE "colour208]$npid !" <<<"$tmc28" || rc=1     # ! = capture-pane confirmed (prompt signature)
report "t28 --tmux chip shows the confirmed needs-input glyph (!)" "$rc"
# --json needs_input key: extend the t8-style key/type check.
json28=$(bench status --json 2>/dev/null)
jq -e '.[0]|has("needs_input")' >/dev/null 2>&1 <<<"$json28"; rc=$?
report "t28 --json objects carry a needs_input key" "$rc"
jq -e '.[0].needs_input|type=="boolean"' >/dev/null 2>&1 <<<"$json28"; rc=$?
report "t28 --json needs_input is a boolean" "$rc"
# Negative: a fresh idle worker at the DEFAULT silence window is not flagged.
unset BENCH_SILENCE_SECS                                   # spawn below gets monitor-silence 60
mk_task "fresh-idle"; fiid=$NEWID
bench task set "$fiid" mockmode idle >/dev/null 2>&1
bench spawn "$fiid" >/dev/null 2>&1
ni2=$(bench status --json 2>/dev/null | jq -r --arg id "$fiid" '.[]|select(.id==$id)|.needs_input' 2>/dev/null)
rc=0; [ "$ni2" = false ] || rc=1                           # checked immediately, well inside the 60s window
report "t28 fresh idle worker is needs_input==false at the default silence window" "$rc" "needs_input=$ni2"

# --- t29: status --refresh-titles retitles worker panes ---
mk_task "retitle"; rtid=$NEWID
bench task set "$rtid" mockmode idle >/dev/null 2>&1
bench spawn "$rtid" >/dev/null 2>&1
for _ in $(seq 1 25); do tmuxs has-session -t "=bench-fixture-$rtid" 2>/dev/null && break; sleep 0.2; done
bench task set "$rtid" status review >/dev/null 2>&1
rtout=$(bench status --refresh-titles 2>/dev/null)
grep -qE 'retitled [0-9]+ worker pane' <<<"$rtout"; report "t29 --refresh-titles prints a receipt naming the count" $?
rttitle=$(tmuxs display-message -p -t "=bench-fixture-$rtid:" '#{pane_title}' 2>/dev/null)
rc=0; [ "$rttitle" = "$rtid · review" ] || rc=1
report "t29 worker pane title set to '<id> · <status>'" "$rc" "title=[$rttitle]"
comb=$(bench status --tmux --refresh-titles 2>/dev/null)
rc=0; [ "$(printf '%s\n' "$comb" | wc -l)" -eq 1 ] || rc=1
report "t29 combined --tmux --refresh-titles stays a single chip line" "$rc" "lines=$(printf '%s\n' "$comb" | wc -l)"

# --- t30: peek tails the worker pane (human eyes only) ---
mk_task "peek-me"; pkid=$NEWID
bench task set "$pkid" mockmode prompt >/dev/null 2>&1
bench spawn "$pkid" >/dev/null 2>&1
rc=1; pend=$(( $(date +%s) + 10 ))                        # wait for the pane to render the prompt text
while [ "$(date +%s)" -lt "$pend" ]; do
  bench peek "$pkid" 2>/dev/null | grep -q 'Do you want' && { rc=0; break; }
  sleep 0.3
done
report "t30 peek surfaces the worker's prompt text ('Do you want')" "$rc"
pk5=$(bench peek "$pkid" -n 5 2>/dev/null)                # -n may precede or follow the id
rc=0; [ "$(printf '%s\n' "$pk5" | wc -l)" -le 6 ] || rc=1  # header + <=5 content lines
report "t30 peek -n 5 bounds output to a header + <=5 lines" "$rc" "lines=$(printf '%s\n' "$pk5" | wc -l)"
grep -q "$pkid" <<<"$pk5"; report "t30 peek prints a header naming the task" $?
mk_task "peek-dead"; pdid=$NEWID
bench task set "$pdid" mockmode idle >/dev/null 2>&1
bench spawn "$pdid" >/dev/null 2>&1
for _ in $(seq 1 25); do tmuxs has-session -t "=bench-fixture-$pdid" 2>/dev/null && break; sleep 0.2; done
tmuxs kill-session -t "=bench-fixture-$pdid" 2>/dev/null || true
pderr=$(bench peek "$pdid" 2>&1); rc=$?
rc2=0; [ "$rc" -ne 0 ] || rc2=1; report "t30 peek on a dead worker session dies" "$rc2"
grep -q 'bench resume' <<<"$pderr"; report "t30 peek dead-session error names 'bench resume'" $?

# --- t31: doctor — diagnostics, exit 0 unless a hard tool/state FAIL (test 10) ---
gout=$(bench doctor 2>&1); grc=$?
rc=0; [ "$grc" -eq 0 ] || rc=1
report "t31 doctor exits 0 on a healthy (warns-only) workbench" "$rc" "rc=$grc out=[$(grep -iE '^fail' <<<"$gout" | tr '\n' ';')]"
# Hide diffpane: strip the t15 shim dir, ~/.local/bin, and any dir still holding a
# diffpane, so `doctor` sees it missing while tmux/git/bench still resolve.
filt=""; IFS=: read -ra _pdirs <<<"$PATH"
for _d in "${_pdirs[@]}"; do
  case "$_d" in "$WORK/shimbin"|"$HOME/.local/bin") continue ;; esac
  [ -x "$_d/diffpane" ] && continue
  filt="${filt:+$filt:}$_d"
done
dout=$(PATH="$filt" bench doctor 2>&1); drc=$?
rc=0; [ "$drc" -eq 0 ] || rc=1
report "t31 doctor with diffpane missing still exits 0 (acceptance 10)" "$rc" "rc=$drc"
dline=$(grep -i diffpane <<<"$dout" | head -1)
rc=0; grep -qi 'warn' <<<"$dline" || rc=1
report "t31 missing diffpane is a warn, not a hard fail" "$rc" "line=[$dline]"
rc=0; grep -q '—' <<<"$dline" || rc=1                     # doctor appends ' — <next command>' to warn/FAIL lines
report "t31 missing-diffpane line carries an actionable next step" "$rc" "line=[$dline]"
rc=0; { grep -qiE '(^|[^a-z])tmux' <<<"$dout" && grep -qiE '(^|[^a-z])git' <<<"$dout"; } || rc=1
report "t31 doctor still runs the other tool checks (tmux + git lines present)" "$rc"
# Uninitialized project: no state dir → hard FAIL, exit 1, name `bench init`.
FRESH="$WORK/fresh-doctor"; mkdir -p "$FRESH"
git -C "$FRESH" init -qb main
git -C "$FRESH" config user.email test@bench.test; git -C "$FRESH" config user.name bench-test
( cd "$FRESH" && bench doctor ) >"$WORK/fd.out" 2>&1; frc=$?
rc2=0; [ "$frc" -ne 0 ] || rc2=1; report "t31 doctor before init exits nonzero" "$rc2" "rc=$frc"
grep -q 'bench init' "$WORK/fd.out"; report "t31 uninitialized doctor names 'bench init'" $?

# --- t32: clean prunes crashed-mid-done leftovers; abandoned branches survive ---
mk_task "orphan-clean"; ocid=$NEWID
bench task set "$ocid" mockmode idle >/dev/null 2>&1
bench spawn "$ocid" >/dev/null 2>&1
for _ in $(seq 1 25); do tmuxs has-session -t "=bench-fixture-$ocid" 2>/dev/null && break; sleep 0.2; done
ocwt="$(wt_of "$ocid")"
# Simulate a crash after `done` merged+archived but before it cleaned up: kill the
# session, move the task to archive/ as merged — the worktree + agent branch linger.
tmuxs kill-session -t "=bench-fixture-$ocid" 2>/dev/null || true
mv "$SD/tasks/$ocid.md" "$SD/archive/$ocid.md"
fm_set "$SD/archive/$ocid.md" status merged
fm_set "$SD/archive/$ocid.md" updated "$(now_iso)"
# A fresh abandoned task whose branch must SURVIVE clean (salvage rule).
mk_task "clean-keep-abandoned"; ckid=$NEWID
bench task set "$ckid" mockmode idle >/dev/null 2>&1
bench spawn "$ckid" >/dev/null 2>&1
for _ in $(seq 1 25); do tmuxs has-session -t "=bench-fixture-$ckid" 2>/dev/null && break; sleep 0.2; done
bench abandon "$ckid" >/dev/null 2>&1                     # archived abandoned; worktree gone; branch kept
rc=0; [ -d "$ocwt" ] || rc=1; report "t32 orphan worktree exists before clean (precondition)" "$rc" "wt=$ocwt"
git -C "$FIX" show-ref -q --verify "refs/heads/agent/$ocid"; report "t32 orphan agent branch exists before clean (precondition)" $?
clout=$(bench clean 2>&1); report "t32 clean exits 0" $?
rc=0; [ ! -d "$ocwt" ] || rc=1; report "t32 clean removed the orphan worktree" "$rc" "still: $ocwt"
rc=0; git -C "$FIX" worktree list 2>/dev/null | grep -q "$ocid" && rc=1
report "t32 orphan worktree unregistered in git" "$rc"
rc=0; git -C "$FIX" show-ref -q --verify "refs/heads/agent/$ocid" && rc=1
report "t32 clean deleted the merged task's agent branch" "$rc"
rc=0; { grep -qiE 'worktree|worker' <<<"$clout" && grep -qi 'branch' <<<"$clout"; } || rc=1
report "t32 clean receipt names both the worktree and the branch" "$rc" "out=[$clout]"
grep -q "$ocid" <<<"$clout"; report "t32 clean receipt names the pruned task id" $?
rc=0; git -C "$FIX" show-ref -q --verify "refs/heads/agent/$ckid" || rc=1
report "t32 an abandoned task's branch survives clean (salvage rule)" "$rc"
cl2=$(bench clean 2>&1)
grep -q 'nothing to clean' <<<"$cl2"; report "t32 a second clean reports nothing to clean" $?

# --- t33: --tmux wraps chips in click ranges (this tmux IS 3.4) ---
tmr=$(bench status --tmux 2>/dev/null)
grep -qF '#[range=user|task_T-' <<<"$tmr"; report "t33 --tmux wraps chips in #[range=user|task_<id>]" $?
grep -qF '#[norange]' <<<"$tmr"; report "t33 --tmux closes each chip range with #[norange]" $?

# =====================================================================
# Slice-3 validator regression tests (t34–t35) — lock in the 2 BUG fixes.
# =====================================================================

# --- t34: status --tmux degrades cleanly BEFORE bench init (no .git for the
# bell cache/lock — the conf's status-right runs this form every 5s). ---
FIX3="$WORK/preinit"
mkdir -p "$FIX3"
git -C "$FIX3" init -qb main
git -C "$FIX3" config user.email test@bench.test
git -C "$FIX3" config user.name bench-test
printf 'x\n' > "$FIX3/f"; git -C "$FIX3" add -A; git -C "$FIX3" commit -qm "init preinit"
cd "$FIX3" || { echo "cannot cd to preinit fixture"; exit 2; }
t34out=$(bench status --tmux 2>&1); rc=$?
report "t34 pre-init status --tmux exits 0" "$rc" "out=[$t34out]"
rc=0; grep -qi 'no such file' <<<"$t34out" && rc=1
report "t34 pre-init status --tmux emits no lock/cache error" "$rc" "out=[$t34out]"
bench status --tmux --refresh-titles >/dev/null 2>&1
report "t34 pre-init status --tmux --refresh-titles exits 0 (the conf's exact form)" $?
cd "$FIX" || { echo "cannot cd back to fixture"; exit 2; }

# --- t35: clean receipt honesty — a LOCKED orphan worktree cannot be removed;
# clean must say "stuck" with the fix, not lie "removed", and must not converge
# to "nothing to clean" while the leftover persists. ---
mk_task "locked-orphan"; loid=$NEWID
bench task set "$loid" mockmode idle >/dev/null 2>&1
bench spawn "$loid" >/dev/null 2>&1
lowt="$(wt_of "$loid")"
tmuxs kill-session -t "=bench-fixture-$loid" 2>/dev/null || true
fm_set "$(task_file "$loid")" status merged
mv "$(task_file "$loid")" "$SD/archive/$loid.md"          # crash-mid-done orphan
git -C "$FIX" worktree lock "$lowt" 2>/dev/null
lo1=$(bench clean 2>&1); report "t35 clean exits 0 with a locked worktree" $?
rc=0; grep -q "stuck" <<<"$lo1" || rc=1
report "t35 receipt says the locked worktree is stuck (with the unlock fix)" "$rc" "out=[$lo1]"
rc=0; grep -qE "worktree +removed +$lowt" <<<"$lo1" && rc=1
report "t35 receipt does NOT claim the locked worktree was removed" "$rc" "out=[$lo1]"
rc=0; [ -d "$lowt" ] || rc=1; report "t35 locked worktree really is still on disk" "$rc"
rc=0; grep -q 'nothing to clean' <<<"$lo1" && rc=1
report "t35 stuck leftovers suppress the 'nothing to clean' all-tidy claim" "$rc"
git -C "$FIX" worktree unlock "$lowt" 2>/dev/null
lo2=$(bench clean 2>&1)
rc=0; { grep -qE "worktree +removed" <<<"$lo2" && [ ! -d "$lowt" ]; } || rc=1
report "t35 after unlock, clean removes the worktree and says so" "$rc" "out=[$lo2]"

# --- t36: panel (Appendix-B tier-1 palette) — guard rails only; fzf interaction is manual ---
p36=$(TMUX='' bench panel 2>&1); rc=$?
rc2=0; [ "$rc" -ne 0 ] || rc2=1; report "t36 panel outside tmux dies" "$rc2"
grep -qi 'inside tmux' <<<"$p36"; report "t36 panel names the fix (attach to tmux first)" $?
bench help 2>&1 | grep -q 'panel'; report "t36 usage lists the panel verb" $?

# --- t37: embed/pop — crew tiles are VIEWS; popping one never kills the worker ---
view_pane() { tmuxs list-panes -t "=$SESS:crew" -F '#{pane_id} #{@bench_view}' 2>/dev/null | awk -v w="$1" '$2==w{print $1; exit}'; }
mk_task "embed-me"; emid=$NEWID
bench task set "$emid" mockmode idle >/dev/null 2>&1
bench spawn "$emid" >/dev/null 2>&1
for _ in $(seq 1 25); do tmuxs has-session -t "=bench-fixture-$emid" 2>/dev/null && break; sleep 0.2; done
bench embed "$emid" >/dev/null 2>&1; report "t37 embed exits 0 on a live worker" $?
rc=1; for _ in $(seq 1 25); do [ -n "$(view_pane "bench-fixture-$emid")" ] && { rc=0; break; }; sleep 0.2; done
report "t37 crew gains a tile tagged @bench_view=<worker session>" "$rc"
em2=$(bench embed "$emid" 2>&1)
grep -q 'already' <<<"$em2"; report "t37 second embed is an idempotent no-op" $?
rc=0; [ "$(tmuxs list-panes -t "=$SESS:crew" -F '#{@bench_view}' 2>/dev/null | grep -cx "bench-fixture-$emid")" -eq 1 ] || rc=1
report "t37 exactly one tile per worker" "$rc"
bench pop "$emid" >/dev/null 2>&1; report "t37 pop exits 0" $?
rc=0; [ -z "$(view_pane "bench-fixture-$emid")" ] || rc=1; report "t37 pop removed the crew tile" "$rc"
t "t37 worker session STILL ALIVE after pop (views never own sessions)" \
  tmuxs has-session -t "=bench-fixture-$emid"
bench pop "$emid" >/dev/null 2>&1; rc=$?
rc2=0; [ "$rc" -ne 0 ] || rc2=1; report "t37 pop with no tile dies naming 'bench embed'" "$rc2"
mk_task "never-embed"; neid=$NEWID
bench embed "$neid" >/dev/null 2>&1; rc=$?
rc2=0; [ "$rc" -ne 0 ] || rc2=1; report "t37 embed on a never-spawned task dies with spawn/resume hint" "$rc2"

# ═══ t38 RESERVED — nav wave T-A: menu verb + conf bindings (docs/nav_wave_spec.md §1.3).
# Only T-A edits between these markers. ═══

# ═══ end t38 ═══

# ═══ t39 RESERVED — nav wave T-B: board pass + safety rules (docs/nav_wave_spec.md §2.3).
# Only T-B edits between these markers. ═══

# ═══ end t39 ═══

# ═══ t40 RESERVED — nav wave T-C: review on demand + chip trust (docs/nav_wave_spec.md §3.3).
# Only T-C edits between these markers. ═══

# --- t40a: review is on-demand — diffstat + receipt, but NEVER spawns a deck pane. ---
mk_task "t40-review" --files 'worker.txt'; t40r=$NEWID   # default mock commits worker.txt
bench spawn "$t40r" >/dev/null 2>&1
poll_status "$t40r" review 15 || true
bench up >/dev/null 2>&1                                   # guarantee a deck window to count panes in
deck_before=$(tmuxs list-panes -t "=$SESS:deck" -F '#{pane_id}' 2>/dev/null | wc -l)
rv40=$(bench review "$t40r" 2>&1); report "t40 review exits 0" $?
deck_after=$(tmuxs list-panes -t "=$SESS:deck" -F '#{pane_id}' 2>/dev/null | wc -l)
rc=0; [ "$deck_before" = "$deck_after" ] || rc=1
report "t40 review spawns NO deck pane (count unchanged)" "$rc" "before=$deck_before after=$deck_after"
grep -q 'worker.txt' <<<"$rv40"; report "t40 review prints the diffstat" $?
rc=0; grep -qi 'opened lazygit' <<<"$rv40" && rc=1
report "t40 plain review never opens lazygit" "$rc"
grep -qF "bench review $t40r --tui" <<<"$rv40"; report "t40 receipt names 'review --tui' next command" $?
grep -qF "bench watch $t40r" <<<"$rv40"; report "t40 receipt names 'watch' next command" $?
# The two follow-up commands are the receipt's closing lines (nav_wave_spec §3.1).
tail2=$(printf '%s\n' "$rv40" | tail -n2)
{ grep -qF -- "--tui" <<<"$tail2" && grep -qF "bench watch $t40r" <<<"$tail2"; }
report "t40 receipt ENDS with the --tui + watch commands" $?
# review leaves task state untouched.
rc=0; [ "$(task_status "$t40r")" = review ] || rc=1
report "t40 review leaves status unchanged" "$rc" "status=$(task_status "$t40r")"

# --- t40b: review --tui opens lazygit on demand (as far as headless allows). ---
tui40=$(bench review "$t40r" --tui 2>&1); report "t40 review --tui exits 0" $?
if command -v lazygit >/dev/null 2>&1; then
  rc=0; tmuxs list-panes -t "=$SESS:deck" -F '#{@bench_role}' 2>/dev/null | grep -qx review || rc=1
  report "t40 review --tui opens a lazygit pane in the deck (@bench_role=review)" "$rc"
else
  grep -qi 'lazygit not installed' <<<"$tui40"
  report "t40 review --tui degrades cleanly when lazygit is absent" $?
fi
# unknown flag is rejected with a usage hint.
bench review "$t40r" --bogus >/dev/null 2>&1; rc=$?
rc2=0; [ "$rc" -ne 0 ] || rc2=1; report "t40 review rejects an unknown flag" "$rc2"

# --- t40c: chip trust — orange RESERVED for confirmed '!'; bare silence '?' renders dim. ---
export BENCH_SILENCE_SECS=2                                # trip monitor-silence fast (as in t28)
# Confirmed prompt → orange '!'.
mk_task "t40-confirm"; t40c=$NEWID
bench task set "$t40c" mockmode prompt >/dev/null 2>&1
bench spawn "$t40c" >/dev/null 2>&1
for _ in $(seq 1 30); do
  ni=$(bench status --json 2>/dev/null | jq -r --arg id "$t40c" '.[]|select(.id==$id)|.needs_input' 2>/dev/null)
  [ "$ni" = true ] && break; sleep 0.5
done
# Bare silence (idle worker, no prompt signature) → dim '?'.
mk_task "t40-silent"; t40s=$NEWID
bench task set "$t40s" mockmode idle >/dev/null 2>&1
bench spawn "$t40s" >/dev/null 2>&1
for _ in $(seq 1 30); do
  ni=$(bench status --json 2>/dev/null | jq -r --arg id "$t40s" '.[]|select(.id==$id)|.needs_input' 2>/dev/null)
  [ "$ni" = true ] && break; sleep 0.5
done
tm40=$(bench status --tmux 2>/dev/null)
# Confirmed '!' chip: orange (colour208). This is the ONLY thing orange is spent on now.
rc=0; grep -qE "colour208]$t40c !" <<<"$tm40" || rc=1
report "t40 confirmed '!' chip renders orange (colour208)" "$rc" "line=[$(grep -oE "colour208]$t40c [^#]*" <<<"$tm40")]"
# Bare-silence '?' chip: renders, but NOT orange (dim demotion — assert on the format string).
qchip=$(grep -oE "fg=[a-z0-9]+]$t40s \?[a-z]*" <<<"$tm40")
rc=0; [ -n "$qchip" ] || rc=1
report "t40 bare-silence chip renders the '?' glyph" "$rc" "chip=[$qchip]"
rc=0; grep -q colour208 <<<"$qchip" && rc=1
report "t40 bare-silence '?' chip is NOT orange (trust demotion)" "$rc" "chip=[$qchip]"
unset BENCH_SILENCE_SECS

# ═══ end t40 ═══

# ---- summary ----
printf '1..%d\n' "$TESTNUM"
printf '# passed %d, failed %d\n' "$((TESTNUM - FAILS))" "$FAILS"
[ "$FAILS" -eq 0 ]
