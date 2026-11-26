#!/usr/bin/env bash
# Integration tests: an isolated tmux server and a fake murmur on PATH.
# Run: tests/test.sh
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
socket="$tmp/tmux.sock"
fail=0
trap 'tmux -S "$socket" kill-server 2>/dev/null; rm -rf "$tmp"; exit $fail' EXIT

# The harness hook examples run the real murmur, mu and muzzle inits, so they
# get the caller's PATH, before the fake murmur below replaces it.
bash "$root/tests/test_examples.sh" | tee "$tmp/examples.log" || fail=1

# Every tmux call in the scripts goes to our server.
mkdir -p "$tmp/bin"
real_tmux=$(command -v tmux)
printf '#!/bin/sh\nexec %s -S %s "$@"\n' "$real_tmux" "$socket" >"$tmp/bin/tmux"
chmod +x "$tmp/bin/tmux"
# A PATH without the real murmur, so the fake below is the only one.
export PATH="$tmp/bin:/usr/bin:/bin" XDG_STATE_HOME="$tmp/state"
# Running the suite from inside tmux must not leak our own pane into the
# isolated server: run-shell there must see no $TMUX_PANE, as in real use.
unset TMUX TMUX_PANE

check() {
	if [[ $2 == "$3" ]]; then
		echo "ok   $1"
	else
		echo "FAIL $1: got [$2] want [$3]"
		fail=1
	fi
}

fake_murmur() {
	cat >"$tmp/bin/murmur"
	chmod +x "$tmp/bin/murmur"
}

# run-shell in the config may still be running when source-file returns.
wait_for() { # $1 = condition, $2 = tries of 0.1s (default 50)
	for _ in $(seq "${2:-50}"); do
		eval "$1" >/dev/null 2>&1 && return 0
		sleep 0.1
	done
	return 1
}

tmux -f /dev/null new-session -d -s work
tmux source-file "$root/tmux/mu-crew.conf"
wait_for "tmux list-keys -T prefix | grep -q mu-workstream-pick" || true

# --- keys --------------------------------------------------------------------
# `list-keys -T prefix <key>` prints nothing on tmux 3.7; read the whole table.
bound() { tmux list-keys -T prefix | grep -E "^bind-key +-T prefix $1 " || true; }
check "mu-crew binds nothing on a" "$(bound a | wc -l | tr -d ' ')" 0
check "agents key forwards to tsesh" "$(tmux show -gv @tsesh_key_agents)" a
check "workstream bound on u" "$(bound u | grep -c mu-workstream-pick)" 1
tmux set -g @mu_crew_key_session_agents none
tmux unbind-key -T prefix u
tmux source-file "$root/tmux/mu-crew.conf"
wait_for "tmux list-keys -T prefix | grep -q mu-workstream-pick" || true
# BSD wc pads its count with spaces; trim it.
check "none forwards as empty, so tsesh leaves the key unbound" "$(tmux show -gqv @tsesh_key_agents)" ""
check "other keys still bound" "$(bound u | grep -c mu-workstream-pick)" 1

# --- part flags ---------------------------------------------------------------------
# Each part is on by default; "off" before sourcing skips it, and sourcing again
# with it off removes what it set.
tmux set -gu @mu_crew_key_session_agents
tmux source-file "$root/tmux/mu-crew.conf"
wait_for "tmux list-keys -T prefix | grep -q 'murmur sidepanel'" || true
check "keys on by default" "$(tmux list-keys -T prefix | grep -cE 'murmur|mu-workstream')" 3
tmux set -g @mu_crew_keys off
tmux set -g @mu_crew_pane_border off
tmux source-file "$root/tmux/mu-crew.conf"
wait_for "! tmux list-keys -T prefix | grep -qE 'murmur|mu-workstream'" || true
check "keys off unbinds mu-crew's keys" "$(tmux list-keys -T prefix | grep -cE 'murmur|mu-workstream')" 0
check "pane border off resets our format" "$(tmux show -gv pane-border-format | grep -c mu_crew_pane_glyph)" 0
tmux set -g pane-border-format mine
tmux source-file "$root/tmux/mu-crew.conf"
check "pane border off leaves a user format alone" "$(tmux show -gv pane-border-format)" mine
tmux set -g @mu_crew_session_keys off
tmux set -g @tsesh_key_pick X
tmux source-file "$root/tmux/mu-crew.conf"
check "session keys off leaves tsesh options alone" "$(tmux show -gv @tsesh_key_pick)" X
for flag in keys pane_border session_keys; do tmux set -gu "@mu_crew_$flag"; done
tmux set -gu pane-border-format
tmux source-file "$root/tmux/mu-crew.conf"
wait_for "tmux list-keys -T prefix | grep -q mu-workstream-pick" || true
check "parts come back when the flags are cleared" \
	"$(tmux list-keys -T prefix | grep -cE 'murmur|mu-workstream') $(tmux show -gv @tsesh_key_pick)$(tmux show -gv @tsesh_key_agents)" "3 sa"

# --- tsesh key forwarding --------------------------------------------------------
check "session keys forward to tsesh" \
	"$(tmux show -gv @tsesh_key_pick) $(tmux show -gv @tsesh_key_agents) $(tmux show -gv @tsesh_key_last) $(tmux show -gv @tsesh_key_root)" "s a g T"
tmux set -g @mu_crew_key_session_last none
tmux source-file "$root/tmux/mu-crew.conf"
check "none forwards as empty, so tsesh leaves it unbound" "$(tmux show -gv @tsesh_key_last)" ""
check "mu-crew binds no session key itself" "$(tmux list-keys -T prefix | grep -v mu-workstream-pick | grep -c tsesh)" 0
tmux set -gu @mu_crew_key_session_last

# --- host color ---------------------------------------------------------------
check "host color is set at source time" \
	"$(tmux show -gv @mu_crew_host_color)" "$("$root/tmux/scripts/mu-crew-host-color")"

# --- side panel key reaches murmur with a pane ---------------------------------
# run-shell exports no $TMUX_PANE; murmur sidepanel exits 1 without one. Run the
# command exactly as bound, and check what the fake murmur received.
fake_murmur <<SH
#!/bin/sh
if [ "\$1" = sidepanel ]; then
	echo "\$*|\$TMUX_PANE" >"$tmp/murmur-args"
else
	echo '{"peers": [], "panes": []}'
fi
SH
tmux source-file "$root/tmux/mu-crew.conf"
wait_for "tmux list-keys -T prefix | grep -q 'murmur sidepanel'" || true
bound 'C-m' | sed -E 's/^bind-key +-T prefix C-m +//' >"$tmp/cmd.conf"
tmux source-file -t work "$tmp/cmd.conf"
wait_for "test -s $tmp/murmur-args" || true
check "side panel key passes the pane to murmur" \
	"$(sed -E 's/%[0-9]+$/%N/' "$tmp/murmur-args" 2>/dev/null)" "sidepanel|%N"
rm -f "$tmp/bin/murmur"

# --- focus hooks are gone -------------------------------------------------------
# vtmux clears done/error on focus natively; the config sets no [42] hook, and
# sourcing removes ones an older version installed.
tmux set-hook -g after-select-pane[42] "run-shell true"
tmux set-hook -g after-select-window[42] "run-shell true"
tmux set-hook -g client-session-changed[42] "run-shell true"
tmux set-hook -g after-select-pane[7] "run-shell true"
tmux source-file "$root/tmux/mu-crew.conf"
check "all three [42] focus hooks are removed" "$(tmux show-hooks -g | grep -c '\[42\]')" 0
check "user [7] hook is kept" "$(tmux show-hooks -g | grep -c 'after-select-pane\[7\]')" 1
tmux set-hook -gu after-select-pane[7]
check "no murmur clear in the config" "$(grep -c 'murmur clear' "$root/tmux/mu-crew.conf")" 0

# --- pill ----------------------------------------------------------------------
check "pill is empty with no agents" "$(tmux display -p '#{E:@mu_crew_pill}')" ""
tmux set -g @murmur_count_blocked 2
tmux set -g @mu_crew_remote_blocked 1
check "local and remote counts add" "$(tmux display -p '#{E:@mu_crew_n_blocked}')" 3
check "pill shows the sum" "$(tmux display -p '#{E:@mu_crew_pill}' | grep -c '#\[fg=#fab387\]3')" 1
check "zero states are hidden" "$(tmux display -p '#{E:@mu_crew_pill}' | grep -c '#f38ba8')" 0

# --- muzzle pill ----------------------------------------------------------------
check "muzzle pill is empty with nothing set" "$(tmux display -p '#{E:@mu_crew_muzzle_pill}')" ""
tmux set -g @mu_crew_muzzle_held 0
tmux set -g @mu_crew_muzzle_budget 14
check "muzzle pill is empty when nothing holds or waits" "$(tmux display -p '#{E:@mu_crew_muzzle_pill}')" ""
tmux set -g @mu_crew_muzzle_held 4
check "muzzle pill shows held/budget" "$(tmux display -p '#{E:@mu_crew_muzzle_pill}' | grep -c ' 4/14')" 1
check "muzzle pill hides zero counts" "$(tmux display -p '#{E:@mu_crew_muzzle_pill}' | grep -Ec '#74c7ec|#fab387|#eba0ac')" 0
tmux set -g @mu_crew_muzzle_waiting 2
tmux set -g @mu_crew_muzzle_slow_holders 1
tmux set -g @mu_crew_muzzle_slow_waiters 3
pill=$(tmux display -p '#{E:@mu_crew_muzzle_pill}')
check "muzzle pill shows waiting" "$(grep -c '#\[fg=#74c7ec\]2' <<<"$pill")" 1
check "muzzle pill shows slow holders" "$(grep -c '#\[fg=#fab387\]1' <<<"$pill")" 1
check "muzzle pill shows slow waiters" "$(grep -c '#\[fg=#eba0ac\]#\[bold\]3' <<<"$pill")" 1
tmux set -g @mu_crew_muzzle_held 0
check "muzzle pill shows a queue with nothing held" "$(tmux display -p '#{E:@mu_crew_muzzle_pill}' | grep -c ' 0/14')" 1
for o in held budget waiting slow_holders slow_waiters; do tmux set -gu "@mu_crew_muzzle_$o"; done

# --- window and pane glyphs ---------------------------------------------------
# #{window_program_state}, #{pane_program_state} and #{pane_program_id} exist
# only in vtmux (OSC 7501); stock tmux expands them to empty. Detect that, and
# assert the state mapping only on vtmux. Everything else runs on both.
probe=$(tmux display -p '#{window_program_state}x#{pane_program_state}x')
check "plain shell: no window glyph" "$(tmux display -p '#{E:@mu_crew_window_glyph}')" ""
check "plain shell: no pane glyph" "$(tmux display -p '#{E:@mu_crew_pane_glyph}')" ""
# Crashed needs only stock tmux: a dead pane with a nonzero exit status.
tmux set -g remain-on-exit on
tmux new-session -d -s dead "exit 3"
wait_for "test \"\$(tmux display -p -t dead '#{pane_dead}')\" = 1" || true
check "crashed pane glyph" "$(tmux display -p -t dead '#{E:@mu_crew_pane_glyph}' | grep -c f38ba8)" 1
check "crashed window glyph" "$(tmux display -p -t dead '#{E:@mu_crew_window_glyph}' | grep -c f38ba8)" 1
tmux kill-session -t dead
tmux new-session -d -s ok "exit 0"
wait_for "test \"\$(tmux display -p -t ok '#{pane_dead}')\" = 1" || true
check "clean exit is not crashed" "$(tmux display -p -t ok '#{E:@mu_crew_pane_glyph}')" ""
tmux kill-session -t ok
tmux set -gu remain-on-exit
# State mapping runs only under a vtmux that supports program status.
vtver=$(tmux display -p '#{vtmux_version}')
if [[ -n $vtver ]] && tmux set -s vtmux-program-status on 2>/dev/null; then
	osc() { # state id
		printf "tmux new-session -d -s %s \"printf '\\033]7501;state=%s:id=%s\\007'; sleep 30\"" "st_$1" "$1" "$2"
	}
	for st in blocked error working done idle; do
		eval "$(osc $st x)"
		wait_for "test -n \"\$(tmux display -p -t st_$st '#{pane_program_state}')\"" || true
		check "vtmux $st: pane state" "$(tmux display -p -t st_$st '#{pane_program_state}')" "$st"
		check "vtmux $st: window glyph set" "$(tmux display -p -t st_$st '#{E:@mu_crew_window_glyph}' | grep -c .)" 1
		check "vtmux $st: pane glyph set" "$(tmux display -p -t st_$st '#{E:@mu_crew_pane_glyph}' | grep -c .)" 1
		tmux kill-session -t "st_$st"
	done
	eval "$(osc working mu/delegates)"
	wait_for "test -n \"\$(tmux display -p -t st_working '#{pane_program_state}')\"" || true
	check "vtmux delegates: pane glyph is waiting colour" "$(tmux display -p -t st_working '#{E:@mu_crew_pane_glyph}' | grep -c "$(tmux show -gv @mu_crew_c_waiting | sed 's/#//')")" 1
	tmux kill-session -t st_working
else
	echo "SKIP vtmux state mapping: not vtmux with vtmux-program-status ($(tmux -V))"
fi

# --- ASCII glyphs ---------------------------------------------------------------
tmux set -g @mu_crew_ascii 1
tmux source-file "$root/tmux/mu-crew.conf"
check "@mu_crew_ascii picks ASCII glyphs" "$(tmux show -gv @mu_crew_g_blocked)" "!"
tmux set -gu @mu_crew_ascii
tmux source-file "$root/tmux/mu-crew.conf"
# U+F075 as UTF-8 bytes: bash 3.2 (macOS) does not expand $'\u...'.
check "default glyphs are Nerd Font" "$(tmux show -gv @mu_crew_g_blocked)" "$(printf '\357\201\265')"

# --- opt-in probes ---------------------------------------------------------------
check "default probes preserve remote-only behavior" "$(tmux show -gv @mu_crew_probes)" murmur_remote
tmux set -g @mu_crew_mem 76
tmux set -g @mu_crew_mem_text '76%'
check "memory pill renders the published value" "$(tmux display -p -- '#{E:@mu_crew_mem_pill}' | grep -c 'MEM 76%')" 1
tmux set -g @mu_crew_mem_min 76
check "memory threshold is show-only-above" "$(tmux display -p '#{E:@mu_crew_mem_pill}')" ""
tmux set -g @mu_crew_cpu 42
tmux set -g @mu_crew_cpu_text '42%'
check "cpu pill uses its colour option" "$(tmux display -p -- '#{E:@mu_crew_cpu_pill}' | grep -c '#\[fg=#a6adc8\]CPU 42%')" 1
tmux set -g @mu_crew_uptime_value 90061
tmux set -g @mu_crew_uptime_text '1d 1h'
check "uptime format renders the published text" "$(tmux display -p '#{E:@mu_crew_uptime}' | grep -c '1d 1h')" 1

# --- cheap tick --------------------------------------------------------------------
# A status line redraws on every pane, window and session event, not just on
# status-interval; anything it runs, it runs per redraw. The formats must be
# pure tmux format: no #(...) command, which here would mean a Node start.
check "no format option runs a command per redraw" \
	"$(grep -E '^set -g @mu_crew_' "$root/tmux/mu-crew.conf" | grep -c '#(')" 0
check "the config sets no status line" \
	"$(grep -cE '^set(-option)? .*status-(left|right|format)' "$root/tmux/mu-crew.conf")" 0

# --- poller ---------------------------------------------------------------------
# PATH here is $tmp/bin:/usr/bin:/bin, with no sbin: a probe that needs a tool
# from there must name it by full path.
tmux set -g @mu_crew_probes 'memory cpu uptime'
"$root/tmux/scripts/mu-crew-poller" --once && rc=0 || rc=$?
check "local probes succeed" "$rc" 0
check "memory probe publishes a percentage" "$(tmux show -gv @mu_crew_mem | grep -Ec '^[0-9]+$')" 1
check "cpu probe publishes a percentage" "$(tmux show -gv @mu_crew_cpu | grep -Ec '^[0-9]+$')" 1
check "uptime probe publishes text" "$(tmux show -gv @mu_crew_uptime_text | grep -Ec '^[0-9]+[dhm]')" 1

# The loop, not --once: dropping a probe clears what it published, so a pill
# does not keep its last value. A bad interval must not stall the probe.
tmux set -g @mu_crew_probes 'memory cpu'
tmux set -g @mu_crew_cpu_interval 5s
"$root/tmux/scripts/mu-crew-poller" --loop &
loop_pid=$!
wait_for "test -n \"\$(tmux show -gqv @mu_crew_mem)\"" || true
sleep 0.5
kill -0 "$loop_pid" 2>/dev/null && rc=0 || rc=1
check "a non-numeric interval does not kill the loop" "$rc" 0
tmux set -g @mu_crew_probes 'cpu'
wait_for "test -z \"\$(tmux show -gqv @mu_crew_mem)\"" && rc=0 || rc=1
check "dropping a probe clears its options" "$rc" 0
tmux set -g @mu_crew_probes none
wait_for "! kill -0 $loop_pid" 30 && rc=0 || rc=1
check "probes none stops the loop" "$rc" 0
check "probes none clears the last probe's options" "$(tmux show -gqv @mu_crew_cpu)" ""
kill "$loop_pid" 2>/dev/null || true; wait "$loop_pid" 2>/dev/null || true
tmux set -gu @mu_crew_cpu_interval

# A cold start sources the config before any session exists, and a restart
# finds the previous server's loop still alive. Both must end with a loop
# publishing to the new server.
tmux kill-server
printf 'set -g @mu_crew_probes cpu\nsource-file %s/tmux/mu-crew.conf\nrun-shell "sleep 1"\n' "$root" >"$tmp/cold.conf"
tmux -f "$tmp/cold.conf" new-session -d -s work
wait_for "test -n \"\$(tmux show -gqv @mu_crew_cpu)\"" 40 && rc=0 || rc=1
check "a loop started during config load keeps polling" "$rc" 0
tmux kill-server
tmux -f "$tmp/cold.conf" new-session -d -s work
wait_for "test -n \"\$(tmux show -gqv @mu_crew_cpu)\"" 40 && rc=0 || rc=1
check "a restarted server gets a loop" "$rc" 0

tmux set -g @mu_crew_probes murmur_remote
fake_murmur <<'SH'
#!/bin/sh
cat <<'JSON'
{"counts": {}, "orchestrated_counts": {}, "peers": [{"name": "dev"}],
 "panes": [
  {"local": true,  "driver": "human", "activity": "running", "attention": [{"kind": "blocked"}]},
  {"local": false, "driver": "human", "activity": "running", "attention": []},
  {"local": false, "driver": "human", "activity": "stopped", "attention": [{"kind": "crashed"}]},
  {"local": false, "driver": "orchestrated", "activity": "running", "attention": [{"kind": "blocked"}]},
  {"local": false, "driver": "orchestrated", "activity": "running", "attention": [{"kind": "done"}]}
 ]}
JSON
SH
tmux set -gu @mu_crew_remote_blocked
"$root/tmux/scripts/mu-crew-poller" --once && rc=0 || rc=$?
check "poll with peers succeeds" "$rc" 0
check "remote working counted" "$(tmux show -gv @mu_crew_remote_working)" 1
check "remote crashed counted" "$(tmux show -gv @mu_crew_remote_crashed)" 1
check "crew blocked counts, local pane ignored" "$(tmux show -gv @mu_crew_remote_blocked)" 1
check "crew done does not count" "$(tmux show -gqv @mu_crew_remote_done)" ""
check "crew total" "$(tmux show -gv @mu_crew_remote_crew)" 2

fake_murmur <<'SH'
#!/bin/sh
echo '{"counts": {}, "orchestrated_counts": {}, "peers": [], "panes": []}'
SH
"$root/tmux/scripts/mu-crew-poller" --once && rc=0 || rc=$?
check "no peers stops the remote probe" "$rc" 3
check "no peers clears remote counts" "$(tmux show -gqv @mu_crew_remote_working)" ""

rm "$tmp/bin/murmur"
"$root/tmux/scripts/mu-crew-poller" --once && rc=0 || rc=$?
check "no murmur stops the remote probe" "$rc" 2

tmux set -g @mu_crew_probes muzzle
cat >"$tmp/bin/muzzle" <<'SH'
#!/bin/sh
echo '{"budget":14,"held":4,"waiting":[{"slow":true},{"slow":false}],"holders":[{}],"slow_holders":1,"slow_waiters":1}'
SH
chmod +x "$tmp/bin/muzzle"
"$root/tmux/scripts/mu-crew-poller" --once && rc=0 || rc=$?
check "muzzle probe succeeds" "$rc" 0
check "muzzle probe publishes held/budget" "$(tmux show -gv @mu_crew_muzzle_held)/$(tmux show -gv @mu_crew_muzzle_budget)" 4/14
check "muzzle probe counts waiters" "$(tmux show -gv @mu_crew_muzzle_waiting)" 2
check "muzzle probe publishes slow counts" "$(tmux show -gv @mu_crew_muzzle_slow_holders)$(tmux show -gv @mu_crew_muzzle_slow_waiters)" 11
printf '#!/bin/sh\nexit 1\n' >"$tmp/bin/muzzle"
"$root/tmux/scripts/mu-crew-poller" --once && rc=0 || rc=$?
check "a failing muzzle is a failed round" "$rc" 1
check "a failing muzzle clears its options" "$(tmux show -gqv @mu_crew_muzzle_held)" ""
tmux set -g @mu_crew_muzzle_held 9
rm "$tmp/bin/muzzle"
"$root/tmux/scripts/mu-crew-poller" --once && rc=0 || rc=$?
check "no muzzle is a failed round" "$rc" 2
check "no muzzle clears its options" "$(tmux show -gqv @mu_crew_muzzle_held)" ""
tmux set -g @mu_crew_probes murmur_remote

# A skipped check is not a pass: say so last, where it is seen.
grep '^SKIP' "$tmp/examples.log" || true

exit $fail
