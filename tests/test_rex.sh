#!/usr/bin/env bash
# The Rex agent switcher (rex/mu-crew.lua): lint, format, `rex config check` of
# the example init.lua, and the stub harness (tests/rex_harness.lua) inside Rex.
# Run: tests/test_rex.sh (tests/test.sh runs it too)
#
# A missing tool skips its check with a SKIP line (tests/test.sh repeats it
# last). The harness needs a running Rex server: it uses `rex do` with
# --autostart=false, so it never starts one. REX_LIVE=1 adds two cases that
# make read-only `rex api call`s (session.list, a focus of a made-up session)
# against that server.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
fail=0
trap 'rm -rf "$tmp"; exit $fail' EXIT
lua_files=("$root/rex/mu-crew.lua" "$root/rex/init.example.lua")

check() {
	if [[ $2 == "$3" ]]; then
		echo "ok   $1"
	else
		echo "FAIL $1: got [$2] want [$3]"
		fail=1
	fi
}

if command -v luacheck >/dev/null; then
	(cd "$root/rex" && luacheck -q "${lua_files[@]}" >"$tmp/luacheck" 2>&1) && rc=0 || { rc=$?; cat "$tmp/luacheck"; }
	check "luacheck rex/" "$rc" 0
else
	echo "SKIP luacheck rex/: luacheck not on PATH"
fi

if command -v stylua >/dev/null; then
	stylua --check "${lua_files[@]}" && rc=0 || rc=$?
	check "stylua --check rex/" "$rc" 0
else
	echo "SKIP stylua rex/: stylua not on PATH"
fi

if ! command -v rex >/dev/null; then
	echo "SKIP rex config check and harness: rex not on PATH"
	exit 0
fi

# The example, with its HOME-based clone path pointed at this checkout.
sed "s|os.getenv(\"HOME\") .. \"/.local/share/mu-crew-dotfiles/rex/|\"$root/rex/|" \
	"$root/rex/init.example.lua" >"$tmp/init.lua"
check "example points at this checkout" "$(grep -c "\"$root/rex/" "$tmp/init.lua")" 1
timeout 10 rex config check "$tmp/init.lua" >"$tmp/check" 2>&1 && rc=0 || { rc=$?; cat "$tmp/check"; }
check "rex config check of the example" "$rc" 0
check "example defines actions and binds keys" \
	"$(grep -E '^(bindings|modes|actions):' "$tmp/check" | tr '\n' ' ')" "bindings: 8 modes: 1 actions: 5 "
printf 'package.path = "%s/rex/?.lua;" .. package.path\nrequire("mu-crew")\n' "$root" >"$tmp/bare.lua"
timeout 10 rex config check "$tmp/bare.lua" >"$tmp/check" 2>&1 && rc=0 || { rc=$?; cat "$tmp/check"; }
check "require without setup binds and defines nothing" \
	"$rc $(grep -E '^(bindings|actions):' "$tmp/check" | tr '\n' ' ')" "0 bindings: 0 actions: 0 "

if ! timeout 10 rex --autostart=false do -e 'return 1' >/dev/null 2>&1; then
	echo "SKIP rex harness: no running Rex server"
	exit 0
fi
args=("root=$root")
[[ ${REX_LIVE:-} == 1 ]] && args+=(live=1)
timeout 30 rex --autostart=false do "$root/tests/rex_harness.lua" "${args[@]}" >"$tmp/harness.json" && rc=0 || rc=$?
check "rex harness ran" "$rc" 0
python3 -c 'import json,sys; print(json.load(open(sys.argv[1])))' "$tmp/harness.json" >"$tmp/harness" || fail=1
sed -E 's/^PASS /ok   rex harness: /' "$tmp/harness"
grep -q '^FAIL' "$tmp/harness" && fail=1
check "rex harness case count" "$(grep -c '^PASS' "$tmp/harness")" "$([[ ${REX_LIVE:-} == 1 ]] && echo 33 || echo 31)"
