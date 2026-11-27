-- Stub harness for rex/mu-crew.lua's agent_jump, run inside Rex:
--   rex --autostart=false do tests/rex_harness.lua root=<repo> [live=1]
-- Every Rex and murmur call is stubbed, so it touches no session. live=1 adds
-- two cases that run read-only `rex api call`s against the running server.
-- Returns one PASS/FAIL line per case.
local root = rex.args.root
local live = tostring(rex.args.live) == "1"
local real_exec = rex.exec

log, action = {}, nil
local function L(s) log[#log + 1] = s end
clock = 1000
fake = {}
os.time = function() return clock end
binds = {}
rex.bind = function(k, a) binds[#binds + 1] = k .. "=" .. a end
rex.action = function(a) action = a end
rex.servers = function() return fake.servers end
rex.call = function(m, a) L("call:" .. m .. ":" .. rex.json.encode(a)); clock = clock + (fake.ctx_cost or 0); return fake.reply(m, a, "ctx") end
rex.session = {}
rex.server = function(label)
	return { call = function(m, a) L("server[" .. label .. "]:" .. m); clock = clock + (fake.peer_cost or 0); return fake.reply(m, a, label) end }
end
rex.client = { queue = function(m, a) L("queue:" .. m .. ":" .. rex.json.encode(a)) end }
rex.ui = { pick = function(o) fake.picked_items = o.items; L("pick:" .. #o.items .. ":" .. o.items[1].title); return fake.pick, "cancelled" end }
rex.exec = function(argv, opts)
	if argv[1] == "murmur" or argv[1] == "/opt/m/murmur" then
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
	if m == "session.focus_block" then
		if fake.owner == who then return {} end
		return nil, "session_not_found"
	end
end

local results = {}
local function case(name, ctx, setup, check, opts)
	log, clock, binds = {}, 1000, {}
	crew.setup(opts)
	fake = { servers = { "me@alpha", "me@beta", "me@gamma" }, reply = default_reply, pick = "T" }
	setup()
	L("setup panes=" .. tostring(fake.panes and #fake.panes))
	local ok, err = pcall(action.run, ctx, {})
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
case("setup: defaults bind cmd+j, generic PATH", home, function() fake.panes = { pane({ server = { kind = "tmux" } }) } end, function(ok, err, l)
	assert(ok, err); assert(table.concat(binds, ",") == "cmd+j=agent_jump", table.concat(binds, ","))
	assert(fake.murmur_argv == "murmur", tostring(fake.murmur_argv))
	local home_dir = os.getenv("HOME") or ""
	assert(fake.murmur_path == home_dir .. "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", fake.murmur_path)
	has(l, '"/bin/sh","-c"'); has(l, '"T","murmur"]'); hasnt(l, "mise") end)
case("setup: key false binds nothing", home, function() fake.panes = {} ; fake.pick = nil end, function(ok, err)
	assert(ok, err); assert(#binds == 0, table.concat(binds, ",")) end, { key = false })
case("setup: key, path, murmur, rex options", remote, function() fake.panes = { pane({ server = { kind = "tmux" } }) }; fake.sessions = { { session_id = "session:HOME1" } } end, function(ok, err, l)
	assert(ok, err); assert(table.concat(binds, ",") == "cmd+k=agent_jump", table.concat(binds, ","))
	assert(fake.murmur_argv == "/opt/m/murmur"); assert(fake.rex_argv == "/opt/r/rex")
	assert(fake.murmur_path == "/a:/b:/usr/bin:/bin:/usr/sbin:/sbin", fake.murmur_path)
	has(fake.last_cli_json, "/opt/m/murmur") end,
	{ key = "cmd+k", path = { "/a", "/b" }, murmur = "/opt/m/murmur", rex = "/opt/r/rex" })
case("setup: path as a string", home, function() fake.panes = {}; fake.pick = nil end, function(ok, err)
	assert(ok, err); assert(fake.murmur_path == "/x:/y:/usr/bin:/bin:/usr/sbin:/sbin", fake.murmur_path) end, { path = "/x:/y" })
return table.concat(results, "\n")
