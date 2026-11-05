#!/usr/bin/env bash
# The harness hook examples (claude/, codex/, cursor/, muse/) against what
# `murmur init`, `mu init` and `muzzle init` write into an empty home.
# Run: tests/test_examples.sh (tests/test.sh runs it too)
#
# The inits come from PATH, or from MURMUR_CMD, MU_CMD and MUZZLE_CMD (an
# executable path each, such as a checkout's dist/cli.js or target/debug/muzzle).
# A CLI on PATH too old to write hook entries skips the comparison, with a SKIP
# line (tests/test.sh repeats it last), or fails when REQUIRE_INITS is set; one
# named through its variable must work, or the test fails.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
fail=0
trap 'rm -rf "$tmp"; exit $fail' EXIT

check() {
	if [[ $2 == "$3" ]]; then
		echo "ok   $1"
	else
		echo "FAIL $1: got [$2] want [$3]"
		fail=1
	fi
}

# example file -> where the inits write it, relative to the home directory.
examples=(
	"claude/settings.json:.claude/settings.json"
	"codex/hooks.json:.codex/hooks.json"
	"cursor/hooks.json:.cursor/hooks.json"
	"muse/settings.json:.config/muse/settings.json"
)

# --- the examples against the entry builders ------------------------------------
# Needs no CLI. Each example is rebuilt from the three inits' entry tables:
# murmur's HOOK_TARGETS (src/hook-install.ts), mu's muHandler and
# STOP_HOOK_TIMEOUT_S (src/mu-init.ts) and muzzle's TARGETS (src/init/plan.rs),
# appended in the order the inits run into an empty home. It must equal the
# example, key order included, so a dropped or added event, a changed timeout,
# matcher or field, or a reordered handler shows up here. Change this table with
# those, and the comparison against the inits below catches the table drifting.
rebuilt=$(python3 -I - "$root" <<'PY'
import json, sys
root = sys.argv[1]
# path, murmur's harness name, flat shape, murmur's events, its async events,
# mu's stop event (None: no mu hook), muzzle's event, matcher, command, extras.
targets = [
    ("claude/settings.json", "claude", False,
     ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Notification",
      "Stop", "StopFailure", "SessionEnd"], [],
     "Stop", ("PreToolUse", "Bash", "muzzle hook claude", {})),
    ("codex/hooks.json", "codex", False,
     ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop",
      "Interrupt", "SessionEnd"], [],
     "Stop", ("PreToolUse", "^Bash$", "muzzle hook codex",
              {"statusMessage": "muzzle: matching the command"})),
    ("cursor/hooks.json", "cursor-agent", True,
     ["sessionStart", "beforeSubmitPrompt", "afterAgentResponse", "stop",
      "sessionEnd"], [],
     "stop", ("beforeShellExecution", None, "muzzle hook cursor", {})),
    ("muse/settings.json", "muse", False,
     ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop",
      "StopFailure", "Interrupt", "SessionEnd"], ["Interrupt"],
     None, ("PreToolUse", "bash", "muzzle hook claude", {})),
]
STOP_HOOK_TIMEOUT_S = 600
problems = []
for path, h, flat, events, asyncs, stop, (z_event, z_matcher, z_command, z_extra) in targets:
    def add(event, handler, matcher=None):
        entry = handler if flat else {**({"matcher": matcher} if matcher else {}), "hooks": [handler]}
        hooks.setdefault(event, []).append(entry)
    root_obj = {"hooks": {}}
    hooks = root_obj["hooks"]
    # murmur init
    for e in events:
        c = f"murmur hook {h}"
        add(e, {"command": c} if flat else
            {"type": "command", "command": c, **({"async": True} if e in asyncs else {})})
    if flat:
        root_obj["version"] = 1
    # mu init
    if stop:
        c = f"mu hook stop {h} --timeout {STOP_HOOK_TIMEOUT_S} || true"
        add(stop, {"command": c, "timeout": STOP_HOOK_TIMEOUT_S, "loop_limit": None} if flat else
            {"type": "command", "command": c, "timeout": STOP_HOOK_TIMEOUT_S})
    # muzzle init
    add(z_event, {"command": z_command} if flat else
        {"type": "command", "command": z_command, **z_extra}, z_matcher)
    example = json.load(open(f"{root}/{path}"))
    if json.dumps(example) != json.dumps(root_obj):
        problems.append(f"{path}: want {json.dumps(root_obj)}")
print("; ".join(problems))
PY
)
check "every example is what the entry builders write" "$rebuilt" ""
# murmur's own test for codex's older notify line: an uncommented `notify = [...]`
# naming murmur.
check "codex/config.toml runs no notify line" \
	"$(grep -cE '^[[:space:]]*notify[[:space:]]*=.*murmur' "$root/codex/config.toml" || true)" 0
for entry in "${examples[@]}"; do
	check "README links ${entry%%:*}" "$(grep -c "(${entry%%:*})" "$root/README.md")" 1
done

# --- the inits ------------------------------------------------------------------
# cli <var> <name> <flag>: the command, or "" to skip. A CLI supports hook
# entries when its `init --help` names the flag that picks harnesses.
cli() {
	local explicit=${!1:-} cmd
	cmd=${explicit:-$(command -v "$2" || true)}
	if [[ -n $cmd ]] && in_home "$tmp/help" "$cmd" init --help 2>&1 | grep -q -- "$3"; then
		echo "$cmd"
	elif [[ -n $explicit ]]; then
		echo "FAIL $1=$explicit: its init has no $3" >&2
		echo "!"
	fi
}

# in_home <home> <cmd...>: run with nothing of the caller's environment but
# PATH, so no CLAUDE_CONFIG_DIR, CODEX_HOME, MURMUR_HOOK_HOME or MU_INIT_HOME
# redirects a write out of the temp home.
in_home() {
	local home=$1
	shift
	mkdir -p "$home"
	env -i PATH="$PATH" HOME="$home" TMPDIR="$tmp" \
		XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" \
		XDG_DATA_HOME="$home/.local/share" XDG_CACHE_HOME="$home/.cache" "$@"
}

murmur=$(cli MURMUR_CMD murmur --hooks)
mu=$(cli MU_CMD mu --harness)
muzzle=$(cli MUZZLE_CMD muzzle --hooks)
if [[ $murmur == "!" || $mu == "!" || $muzzle == "!" ]]; then
	fail=1
	exit
fi
if [[ -z $murmur || -z $mu || -z $muzzle ]]; then
	# Not a pass: the examples were checked against the table above only.
	echo "SKIP examples against the inits: murmur, mu and muzzle with hook-writing inits are not all on PATH (set MURMUR_CMD, MU_CMD, MUZZLE_CMD)"
	if [[ -n ${REQUIRE_INITS:-} ]]; then
		echo "FAIL REQUIRE_INITS is set and the inits did not run"
		fail=1
	fi
	exit
fi

# A fresh home, every harness asked for: the examples, byte for byte.
fresh="$tmp/fresh"
rc=0
{
	in_home "$fresh" "$murmur" init --hooks all &&
		in_home "$fresh" "$mu" init --harness all &&
		in_home "$fresh" "$muzzle" init --hooks all
} >"$tmp/fresh.log" 2>&1 || rc=$?
check "the inits succeed in an empty home" "$rc" 0
for entry in "${examples[@]}"; do
	example=${entry%%:*} written=$fresh/${entry#*:}
	if cmp -s "$root/$example" "$written"; then
		check "$example is what the inits write" same same
	else
		diff -u "$root/$example" "$written" || true
		check "$example is what the inits write" differs same
	fi
done
# Hook configs aside, the inits write only state and mu's skill copies (every
# skill mu ships, not only `mu`).
check "the inits write no other config file" \
	"$(cd "$fresh" && find . -type f ! -path './.local/*' ! -path './.cache/*' ! -path './*/skills/*' | sort | tr '\n' ' ')" \
	"./.claude/settings.json ./.codex/hooks.json ./.config/muse/settings.json ./.cursor/hooks.json "
check "mu's skill lands in claude's and codex's skill dirs" \
	"$(ls "$fresh/.claude/skills/mu/SKILL.md" "$fresh/.codex/skills/mu/SKILL.md" 2>/dev/null | wc -l | tr -d ' ')" 2
check "nothing is written under ~/.agents" "$(test -e "$fresh/.agents" && echo yes || echo no)" no

# A home already holding the examples, codex/config.toml included, with no
# harness named: each init finds the four set up, and changes nothing.
seeded="$tmp/seeded"
for entry in "${examples[@]}"; do
	mkdir -p "$(dirname "$seeded/${entry#*:}")"
	cp "$root/${entry%%:*}" "$seeded/${entry#*:}"
done
cp "$root/codex/config.toml" "$seeded/.codex/config.toml"
rc=0
{
	in_home "$seeded" "$murmur" init &&
		in_home "$seeded" "$mu" init &&
		in_home "$seeded" "$muzzle" init
} >"$tmp/seeded.out" 2>"$tmp/seeded.err" || rc=$?
check "the inits succeed over the examples" "$rc" 0
check "the inits warn about nothing over the examples" "$(cat "$tmp/seeded.err")" ""
changed=""
for entry in "${examples[@]}"; do
	cmp -s "$root/${entry%%:*}" "$seeded/${entry#*:}" || changed+="${entry%%:*} "
done
check "the inits leave the examples as they are" "$changed" ""

# The control: the older notify line is the one murmur warns about.
printf 'notify = ["murmur", "notify", "--source", "codex"]\n' >"$seeded/.codex/config.toml"
check "murmur warns about the older notify line" \
	"$(in_home "$seeded" "$murmur" init 2>&1 >/dev/null | grep -c notify)" 1

exit $fail
