#!/usr/bin/env bash
# Integration tests: an isolated tmux server and a fake murmur on PATH.
# Run: tests/test.sh
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
socket="$tmp/tmux.sock"
fail=0
trap 'tmux -S "$socket" kill-server 2>/dev/null; rm -rf "$tmp"' EXIT

# Every tmux call in the scripts goes to our server.
mkdir -p "$tmp/bin"
real_tmux=$(command -v tmux)
printf '#!/bin/sh\nexec %s -S %s "$@"\n' "$real_tmux" "$socket" >"$tmp/bin/tmux"
chmod +x "$tmp/bin/tmux"
# A PATH without the real murmur, so the fake below is the only one.
export PATH="$tmp/bin:/usr/bin:/bin" XDG_STATE_HOME="$tmp/state"

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
wait_for() {
	for _ in $(seq 50); do
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

# --- remote poller --------------------------------------------------------------
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
"$root/tmux/scripts/murmur-remote-poller" --once && rc=0 || rc=$?
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
"$root/tmux/scripts/murmur-remote-poller" --once && rc=0 || rc=$?
check "no peers stops the loop" "$rc" 3
check "no peers clears remote counts" "$(tmux show -gqv @mu_crew_remote_working)" ""

rm "$tmp/bin/murmur"
"$root/tmux/scripts/murmur-remote-poller" --once && rc=0 || rc=$?
check "no murmur stops the loop" "$rc" 2

exit $fail
