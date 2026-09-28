#!/usr/bin/env bash
# Integration tests: an isolated tmux server and a fake murmur on PATH.
# Run: tests/test.sh
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
socket="$tmp/tmux.sock"
fail=0
trap 'tmux -S "$socket" kill-server 2>/dev/null; rm -rf "$tmp"; exit $fail' EXIT

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
check "picker bound on a" "$(bound a | grep -c 'murmur pick')" 1
check "workstream bound on u" "$(bound u | grep -c mu-workstream-pick)" 1
tmux set -g @mu_crew_key_pick none
tmux unbind-key -T prefix a
tmux unbind-key -T prefix u
tmux source-file "$root/tmux/mu-crew.conf"
wait_for "tmux list-keys -T prefix | grep -q mu-workstream-pick" || true
check "none leaves a key unbound" "$(bound a | wc -l)" 0
check "other keys still bound" "$(bound u | grep -c mu-workstream-pick)" 1

# --- tsesh key forwarding --------------------------------------------------------
check "session keys forward to tsesh" \
	"$(tmux show -gv @tsesh_key_pick) $(tmux show -gv @tsesh_key_last) $(tmux show -gv @tsesh_key_root)" "s g T"
tmux set -g @mu_crew_key_session_last none
tmux source-file "$root/tmux/mu-crew.conf"
check "none forwards as empty, so tsesh leaves it unbound" "$(tmux show -gv @tsesh_key_last)" ""
check "mu-crew binds no session key itself" "$(tmux list-keys -T prefix | grep -c tsesh)" 0
tmux set -gu @mu_crew_key_session_last

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
tmux set -g @mu_crew_key_pick a
tmux source-file "$root/tmux/mu-crew.conf"
wait_for "tmux list-keys -T prefix | grep -q 'murmur sidepanel'" || true
bound 'C-m' | sed -E 's/^bind-key +-T prefix C-m +//' >"$tmp/cmd.conf"
tmux source-file -t work "$tmp/cmd.conf"
wait_for "test -s $tmp/murmur-args" || true
check "side panel key passes the pane to murmur" \
	"$(sed -E 's/%[0-9]+$/%N/' "$tmp/murmur-args" 2>/dev/null)" "sidepanel|%N"
rm -f "$tmp/bin/murmur"

# --- pill ----------------------------------------------------------------------
check "pill is empty with no agents" "$(tmux display -p '#{E:@mu_crew_pill}')" ""
tmux set -g @murmur_count_blocked 2
tmux set -g @mu_crew_remote_blocked 1
check "local and remote counts add" "$(tmux display -p '#{E:@mu_crew_n_blocked}')" 3
check "pill shows the sum" "$(tmux display -p '#{E:@mu_crew_pill}' | grep -c '#\[fg=#fab387\]3')" 1
check "zero states are hidden" "$(tmux display -p '#{E:@mu_crew_pill}' | grep -c '#f38ba8')" 0

# --- window glyph -------------------------------------------------------------
tmux set -w @murmur_window_state blocked
check "window glyph shows state" "$(tmux display -p '#{E:@mu_crew_window_glyph}' | grep -c fab387)" 1
tmux set -wu @murmur_window_state
tmux set -w @murmur_window_has_agent 1
check "idle agent window shows idle glyph" "$(tmux display -p '#{E:@mu_crew_window_glyph}' | grep -c 6c7086)" 1
tmux set -wu @murmur_window_has_agent
check "no agent, no glyph" "$(tmux display -p '#{E:@mu_crew_window_glyph}')" ""

# --- ASCII glyphs ---------------------------------------------------------------
tmux set -g @mu_crew_ascii 1
tmux source-file "$root/tmux/mu-crew.conf"
check "@mu_crew_ascii picks ASCII glyphs" "$(tmux show -gv @mu_crew_g_blocked)" "!"
tmux set -gu @mu_crew_ascii
tmux source-file "$root/tmux/mu-crew.conf"
check "default glyphs are Nerd Font" "$(tmux show -gv @mu_crew_g_blocked)" $'\uf075'

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
kill "$loop_pid" 2>/dev/null; wait "$loop_pid" 2>/dev/null || true
tmux set -gu @mu_crew_cpu_interval

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

exit $fail
