-- Stub harness for rex/mu-crew.lua's agent_jump, run inside Rex:
--   rex --autostart=false do tests/rex_harness.lua root=<repo> [live=1]
-- Every Rex and murmur call is stubbed, so it touches no session. live=1 adds
-- two cases that run read-only `rex api call`s against the running server.
-- Returns one PASS/FAIL line per case.
local root = rex.args.root
local live = tostring(rex.args.live) == "1"
local real_exec = rex.exec

log, action, actions = {}, nil, {}
local function L(s) log[#log + 1] = s end
clock = 1000
fake = {}
os.time = function() return clock end
binds, modes, leader_fn = {}, {}, nil
rex.mode = function(name) modes[#modes + 1] = name end
rex.bind = function(k, a, o)
	if type(a) == "function" then
		leader_fn = a
		binds[#binds + 1] = k .. "=fn"
	else
		binds[#binds + 1] = (o and o.mode and (o.mode .. ":") or "") .. k .. "=" .. a
	end
end
rex.action = function(a) actions[a.name] = a; if a.name == "agent_jump" then action = a end end
rex.servers = function() return fake.servers end
rex.call = function(m, a) L("call:" .. m .. ":" .. rex.json.encode(a)); clock = clock + (fake.ctx_cost or 0); return fake.reply(m, a, "ctx") end
rex.session = {}
rex.block = { call = function(f, m, a) L("block:" .. f .. ":" .. m); return fake.block_reply and fake.block_reply(f, m, a) or nil end }
rex.server = function(label)
	return { call = function(m, a) L("server[" .. label .. "]:" .. m); clock = clock + (fake.peer_cost or 0); return fake.reply(m, a, label) end }
end
rex.client = { queue = function(m, a) L("queue:" .. m .. ":" .. rex.json.encode(a)) end }
rex.ui = { pick = function(o) fake.picked_items = o.items; L("pick:" .. #o.items .. ":" .. o.items[1].title); return fake.pick, "cancelled" end }
rex.exec = function(argv, opts)
	if argv[1] == "murmur" or argv[1] == "/opt/m/murmur" then
		if fake.murmur_result then fake.murmur_path = opts.env.PATH; return fake.murmur_result end
		fake.murmur_argv = argv[1]; fake.murmur_path = opts.env.PATH
		local o = rex.json.encode({ panes = fake.panes }); L("murmur:" .. o:sub(1, 300) .. " n=" .. tostring(fake.panes and #fake.panes) .. " t=" .. type(fake.panes and fake.panes[1])); return { ok = true, stdout = o }
	end
	if argv[1] == "rex" or argv[1] == "/opt/r/rex" then
		fake.rex_argv = argv[1]
		L("exec:" .. table.concat(argv, " ", 1, 7))
		fake.last_cli_json = argv[8]
		if fake.real_cli and (argv[7] == "session.list" or argv[7] == "session.focus_block") then
			return real_exec(argv, opts)
		end
		local res = fake.reply(argv[7], rex.json.decode(argv[8]), "home-cli")
		if res == nil then return { ok = false, stderr = "Error: not found\n" } end
		return { ok = true, stdout = rex.json.encode(res) }
	end
	return real_exec(argv, opts)
end
package.path = root .. "/rex/?.lua"
local crew = require("mu-crew")

local function pane(t)
	local p = { visible = true, render_state = "waiting", label = "agent", host = "macbook", ["local"] = true,
		server = { kind = "rex" }, session = "session:S", pane = "block:B", window = "window:W", jump_target = "T" }
	for k, v in pairs(t) do p[k] = v end
	return p
end
local function default_reply(m, a, who)
	if m == "session.list" then return { sessions = fake.sessions or {} } end
	if m == "session.create" then return { session_id = "session:NEW" } end
	if m == "session.new_window" then return { window_id = "window:NEW" } end
	if m == "session.new_layer" then return { layer_id = "layer:NEW" } end
	if m == "session.set_label" then return { revision = 1 } end
	if m == "session.focus_block" then
		if fake.owner == who then return {} end
		return nil, "session_not_found"
	end
end

local results = {}
local function case(name, ctx, setup, check, opts, act_name)
	log, clock, binds, modes, leader_fn, actions = {}, 1000, {}, {}, nil, {}
	crew.setup(opts)
	fake = { servers = { "me@alpha", "me@beta", "me@gamma" }, reply = default_reply, pick = "T" }
	setup()
	L("setup panes=" .. tostring(fake.panes and #fake.panes))
	local target_action = act_name and actions[act_name] or action
	local ok, err = pcall(target_action.run, ctx, {})
	local good, why = pcall(check, ok, err, table.concat(log, "\n"))
	results[#results + 1] = (good and "PASS " or "FAIL ") .. name .. (good and "" or (": " .. tostring(why) .. "\n  err=" .. tostring(err) .. "\n  log=" .. table.concat(log, " | ")))
end
local function has(s, pat) assert(s:find(pat, 1, true), "missing " .. pat) end
local function hasnt(s, pat) assert(not s:find(pat, 1, true), "unexpected " .. pat) end

local home = { session_id = "session:FRONT" }
local remote = { session_id = "session:RFRONT", server = "me@beta" }

-- ctx.server == nil
case("nil/local rex", home, function() fake.panes = { pane({}) }; fake.owner = "ctx" end, function(ok, err, l)
	assert(ok, err); has(l, "call:session.focus_block"); has(l, "queue:session.select"); hasnt(l, "exec:"); hasnt(l, "server[") end)
case("nil/remote rex, matching host only", home, function() fake.panes = { pane({ ["local"] = false, host = "beta" }) }; fake.owner = "me@beta" end, function(ok, err, l)
	assert(ok, err); has(l, "server[me@beta]"); hasnt(l, "server[me@alpha]"); hasnt(l, "call:session.focus_block"); has(l, "queue:session.select") end)
case("nil/remote rex, owner unreachable -> error", home, function() fake.panes = { pane({ ["local"] = false, host = "beta" }) } end, function(ok, err)
	assert(not ok); has(err, "agent on beta") end)
case("nil/tmux in front session, clamped label", home, function()
	fake.panes = { pane({ server = { kind = "tmux" }, label = string.rep("é", 200) }) } end, function(ok, err, l)
	assert(ok, err); has(l, "call:session.new_window"); has(l, '"session_id":"session:FRONT"'); hasnt(l, "exec:")
	local lbl = l:match('"window_label":"(.-)"'); local n = 0; for _ in lbl:gmatch("[%z\1-\127\192-\255][\128-\191]*") do n = n + 1 end
	assert(n == 128, "label chars " .. n); assert(lbl:sub(-3) == "…", "no ellipsis") end)
case("nil/tmux, no local session -> create", {}, function() fake.panes = { pane({ server = { kind = "tmux" } }) } end, function(ok, err, l)
	assert(ok, err); has(l, "call:session.list"); has(l, "call:session.create"); has(l, 'session:NEW') end)
case("nil/empty fleet -> No agents item, no error", home, function() fake.panes = {}; fake.pick = "none" end, function(ok, err, l)
	assert(ok, err); has(l, "pick:1:No agents"); hasnt(l, "queue:") end)
case("nil/cancel", home, function() fake.panes = { pane({}) }; fake.pick = nil end, function(ok, err, l)
	assert(ok, err); hasnt(l, "call:"); hasnt(l, "queue:") end)
-- ctx.server set
case("srv/local rex -> home CLI", remote, function() fake.panes = { pane({}) }; fake.owner = "home-cli" end, function(ok, err, l)
	assert(ok, err); has(l, "exec:rex --autostart=false --timeout 5s api call session.focus_block"); hasnt(l, "call:"); hasnt(l, "server["); has(l, "queue:session.select") end)
case("srv/local rex, home says no -> error, no peers", remote, function() fake.panes = { pane({}) } end, function(ok, err, l)
	assert(not ok); has(err, "not found"); hasnt(l, "server[") end)
case("srv/rex on ctx.server -> rex.call", remote, function() fake.panes = { pane({ ["local"] = false, host = "beta" }) }; fake.owner = "ctx" end, function(ok, err, l)
	assert(ok, err); has(l, "call:session.focus_block"); hasnt(l, "server["); hasnt(l, "exec:") end)
case("srv/rex on another peer -> rex.server", remote, function() fake.panes = { pane({ ["local"] = false, host = "alpha" }) }; fake.owner = "me@alpha" end, function(ok, err, l)
	assert(ok, err); has(l, "server[me@alpha]"); hasnt(l, "exec:") end)
case("srv/tmux -> home CLI list + new_window", remote, function() fake.panes = { pane({ server = { kind = "tmux" } }) }; fake.sessions = { { session_id = "session:HOME1" } } end, function(ok, err, l)
	assert(ok, err); has(l, "api call session.list"); has(l, "api call session.new_window"); hasnt(l, "call:"); has(fake.last_cli_json, '"session_id":"session:HOME1"'); has(l, '"window_id":"window:NEW"') end)
case("srv/tmux, home has no session -> CLI create", remote, function() fake.panes = { pane({ server = { kind = "tmux" } }) } end, function(ok, err, l)
	assert(ok, err); has(l, "api call session.create"); hasnt(l, "call:"); has(l, "session:NEW") end)
if live then
case("srv/real CLI: session.list on this Mac + bogus focus", remote, function() fake.panes = { pane({ session = "session:00000000-0000-0000-0000-000000000000" }) }; fake.real_cli = true end, function(ok, err, l)
	assert(not ok); has(err, "session_not_found"); hasnt(err, "\n"); has(l, "api call session.focus_block") end)
case("srv/tmux real CLI list (read-only) then stub", remote, function() fake.panes = { pane({ server = { kind = "tmux" } }) }; fake.real_cli = true end, function(ok, err, l)
	assert(ok, err); has(l, "api call session.list") end)
end
-- deadline: fleet took 13 s, unknown host, every peer 10 s and dead
case("deadline caps peer probes", home, function()
	fake.panes = { pane({ ["local"] = false, host = "nowhere" }) }; fake.peer_cost = 10
	local orig = rex.exec
	rex.exec = function(argv, o) if argv[1] == "murmur" then clock = clock + 13 end return orig(argv, o) end
	fake.restore = function() rex.exec = orig end
end, function(ok, err, l)
	fake.restore(); assert(not ok); has(err, "out of time")
	local n = select(2, l:gsub("server%[", "")); assert(n == 1, "probed " .. n) end)
case("srv/deadline also caps the ctx.server probe", remote, function()
	fake.servers = { "me@alpha", "me@gamma", "me@beta" }
	fake.panes = { pane({ ["local"] = false, host = "nowhere" }) }; fake.peer_cost = 10; fake.ctx_cost = 10
	local orig = rex.exec
	rex.exec = function(argv, o) if argv[1] == "murmur" then clock = clock + 13 end return orig(argv, o) end
	fake.restore = function() rex.exec = orig end
end, function(ok, err, l)
	fake.restore(); assert(not ok); has(err, "out of time"); hasnt(l, "call:session.focus_block")
	assert(clock - 1000 <= 28, "took " .. (clock - 1000) .. " s") end)
case("srv/tmux, session.list fails -> error, no create", remote, function()
	fake.panes = { pane({ server = { kind = "tmux" } }) }
	fake.reply = function(m, a, who) if m == "session.list" then return nil end return default_reply(m, a, who) end
end, function(ok, err, l)
	assert(not ok); has(err, "session list: not found"); hasnt(l, "session.create") end)
case("nil/tmux, session.list fails -> error, no create", {}, function()
	fake.panes = { pane({ server = { kind = "tmux" } }) }
	fake.reply = function(m, a, who) if m == "session.list" then return nil, "boom" end return default_reply(m, a, who) end
end, function(ok, err, l)
	assert(not ok); has(err, "session list: boom"); hasnt(l, "session.create") end)
-- setup options
case("setup: key and leader false binds nothing", home, function() fake.panes = {} ; fake.pick = nil end, function(ok, err)
	assert(ok, err); assert(#binds == 0, table.concat(binds, ",")) end, { key = false, leader = false })
case("setup: key, path, murmur, rex options", remote, function() fake.panes = { pane({ server = { kind = "tmux" } }) }; fake.sessions = { { session_id = "session:HOME1" } } end, function(ok, err, l)
	assert(ok, err); has(table.concat(binds, ","), "cmd+k=agent_jump")
	assert(fake.murmur_argv == "/opt/m/murmur"); assert(fake.rex_argv == "/opt/r/rex")
	assert(fake.murmur_path == "/a:/b:/usr/bin:/bin:/usr/sbin:/sbin", fake.murmur_path)
	has(fake.last_cli_json, "/opt/m/murmur") end,
	{ key = "cmd+k", path = { "/a", "/b" }, murmur = "/opt/m/murmur", rex = "/opt/r/rex" })
case("setup: path as a string", home, function() fake.panes = {}; fake.pick = nil end, function(ok, err)
	assert(ok, err); assert(fake.murmur_path == "/x:/y:/usr/bin:/bin:/usr/sbin:/sbin", fake.murmur_path) end, { path = "/x:/y" })
-- default PATH with shim dirs (io.open and os.getenv stubbed)
local function with_env(env, dirs, f)
	local go, oo = os.getenv, io.open
	os.getenv = function(k) if env[k] ~= nil then return env[k] end return go(k) end
	io.open = function(p, ...)
		local d = p:match("^(.*)/%.$")
		if d then
			if dirs[d] then return { close = function() end } end
			return nil, "no"
		end
		return oo(p, ...)
	end
	local ok, err = pcall(f)
	os.getenv, io.open = go, oo
	assert(ok, err)
end
local SYS = ":/usr/bin:/bin:/usr/sbin:/sbin"
with_env({ HOME = "/h", MISE_DATA_DIR = "", ASDF_DATA_DIR = "" }, {}, function()
case("setup: defaults bind cmd+j and ctrl+b leader, generic PATH", home, function() fake.panes = { pane({ server = { kind = "tmux" } }) } end, function(ok, err, l)
	assert(ok, err)
	local b = table.concat(binds, ",")
	has(b, "cmd+j=agent_jump"); has(b, "mu_crew_leader:s=tsesh_open"); has(b, "mu_crew_leader:a=agent_jump")
	has(b, "mu_crew_leader:shift+g=murmur_dash"); has(b, "ctrl+b=fn")
	assert(fake.murmur_argv == "murmur", tostring(fake.murmur_argv))
	local home_dir = "/h"
	assert(fake.murmur_path == home_dir .. "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", fake.murmur_path)
	has(l, '"/bin/sh","-c"'); has(l, '"T","murmur"]'); hasnt(l, "mise") end)
end)
local E = { HOME = "/h", MISE_DATA_DIR = "/m", ASDF_DATA_DIR = "/a" }
with_env(E, { ["/h/.local/share/mise/shims"] = 1, ["/m/shims"] = 1, ["/a/shims"] = 1, ["/h/.asdf/shims"] = 1, ["/h/.volta/bin"] = 1, ["/h/.tmux/plugins/tmux-session-picker/bin"] = 1 }, function()
case("setup: default PATH adds existing shim dirs", home, function() fake.panes = {}; fake.pick = nil end, function(ok, err)
	assert(ok, err); assert(fake.murmur_path == "/h/.local/bin:/opt/homebrew/bin:/usr/local/bin:/h/.local/share/mise/shims:/m/shims:/a/shims:/h/.asdf/shims:/h/.volta/bin:/h/.tmux/plugins/tmux-session-picker/bin" .. SYS, fake.murmur_path) end)
end)
with_env({ HOME = "/h", MISE_DATA_DIR = "", ASDF_DATA_DIR = "" }, {}, function()
case("setup: default PATH without shim dirs", home, function() fake.panes = {}; fake.pick = nil end, function(ok, err)
	assert(ok, err); assert(fake.murmur_path == "/h/.local/bin:/opt/homebrew/bin:/usr/local/bin" .. SYS, fake.murmur_path) end)
end)
case("setup: explicit path ignores shim dirs", home, function() fake.panes = {}; fake.pick = nil end, function(ok, err)
	assert(ok, err); assert(fake.murmur_path == "/x" .. SYS, fake.murmur_path) end, { path = "/x" })
case("murmur: env node missing -> says why", home, function()
	fake.murmur_result = { ok = false, stderr = "env: node: No such file or directory\n" } end, function(ok, err)
	assert(not ok); has(err, "murmur needs node on the switcher's PATH"); has(err, "path = {...}") end)
case("murmur: cannot exec -> says why", home, function()
	local orig = rex.exec
	rex.exec = function(argv, o) if argv[1] == "murmur" then return nil, "spawn failed" end return orig(argv, o) end
	fake.restore = function() rex.exec = orig end
end, function(ok, err)
	fake.restore(); assert(not ok); has(err, "spawn failed"); has(err, "on the switcher's PATH") end)
case("tsesh_open: floating layer in active window", { session_id = "session:FRONT", window_id = "window:W1" }, function() end, function(ok, err, l)
	assert(ok, err); has(l, "call:session.new_layer"); has(l, '"window_id":"window:W1"'); has(l, '"tsesh"') end, nil, "tsesh_open")
case("murmur_dash: opens tab in front session", home, function() end, function(ok, err, l)
	assert(ok, err); has(l, "call:session.new_window"); has(l, '"window_label":"murmur dash"') end, nil, "murmur_dash")
case("session_name_from_cwd: renames session to cwd basename", { session_id = "session:FRONT", block_id = "block:B1" }, function()
	fake.block_reply = function() return { foreground = { cwd = "/Users/me/hacking/murmur" }, home = "/Users/me" } end
end, function(ok, err, l)
	assert(ok, err); has(l, "call:session.set_label"); has(l, '"label":"murmur"') end, nil, "session_name_from_cwd")
case("agent_jump_crew: includes hidden crew workers", home, function()
	fake.panes = { pane({ visible = false, label = "worker-1" }) }; fake.owner = "ctx"
end, function(ok, err, l)
	assert(ok, err); has(l, "pick:1:worker-1"); has(l, "call:session.focus_block") end, nil, "agent_jump_crew")
case("leader: passes ctrl+b through to tmux, enters mode otherwise", home, function()
	fake.panes = {}; fake.pick = nil
end, function(ok, err)
	assert(ok, err); assert(type(leader_fn) == "function")
	fake.block_reply = function() return { foreground = { name = "tmux" } } end
	assert(leader_fn({ block_id = "block:1" }) == false)
	fake.block_reply = function() return { foreground = { name = "zsh" } } end
	assert(leader_fn({ block_id = "block:1" }) == true)
	has(table.concat(log, "\n"), "queue:client.mode.enter")
end)
return table.concat(results, "\n")
