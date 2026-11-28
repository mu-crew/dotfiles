-- Stub harness for rex/mu-crew.lua, run inside Rex:
--   rex --autostart=false do tests/rex_harness.lua root=<repo> [live=1]
local root = rex.args.root
local live = tostring(rex.args.live) == "1"
local real_exec = rex.exec

log, actions = {}, {}
local function L(s) log[#log + 1] = s end
clock = 1000
fake = {}
os.time = function() return clock end
binds, modes = {}, {}
rex.mode = function(name) modes[#modes + 1] = name end
rex.bind = function(k, a) binds[#binds + 1] = k .. "=" .. a end
rex.action = function(a) actions[a.name] = a end
rex.call = function(m, a) L("call:" .. m .. ":" .. rex.json.encode(a)); return fake.reply(m, a, "ctx") end
rex.block = { call = function(f, m, a) L("block:" .. f .. ":" .. m); return fake.block_reply and fake.block_reply(f, m, a) or nil end }
rex.client = { queue = function(m, a) L("queue:" .. m .. ":" .. rex.json.encode(a)) end }
rex.exec = function(argv, opts)
	if argv[1] == "rex" or argv[1] == "/opt/r/rex" then
		fake.rex_argv = argv[1]
		fake.rex_path = opts.env.PATH
		L("exec:" .. table.concat(argv, " ", 1, 7))
		fake.last_cli_json = argv[8]
		if fake.real_cli and argv[7] == "session.list" then
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

local function default_reply(m)
	if m == "session.list" then return { sessions = fake.sessions or {} } end
	if m == "session.create" then return { session_id = "session:NEW" } end
	if m == "session.new_window" then return { window_id = "window:NEW" } end
	if m == "session.new_layer" then return { layer_id = "layer:NEW" } end
	if m == "session.view" then return { windows = fake.windows or {} } end
	if m == "session.focus_window" then return { revision = 1 } end
	if m == "session.set_label" then return { revision = 1 } end
end

local results = {}
local function case(name, ctx, setup, check, opts, act_name)
	log, clock, binds, modes, actions = {}, 1000, {}, {}, {}
	crew.setup(opts)
	fake = { reply = default_reply }
	setup()
	local target_action = actions[act_name]
	local ok, err = pcall(target_action.run, ctx, {})
	local good, why = pcall(check, ok, err, table.concat(log, "\n"))
	results[#results + 1] = (good and "PASS " or "FAIL ") .. name .. (good and "" or (": " .. tostring(why) .. "\n  err=" .. tostring(err) .. "\n  log=" .. table.concat(log, " | ")))
end
local function has(s, pat) assert(s:find(pat, 1, true), "missing " .. pat) end
local function hasnt(s, pat) assert(not s:find(pat, 1, true), "unexpected " .. pat) end

local home = { session_id = "session:FRONT" }
local remote = { session_id = "session:RFRONT", server = "me@beta" }

case("tsesh_open: floating layer in active window", home, function() end, function(ok, err, l)
	assert(ok, err); has(l, "call:session.new_layer"); has(l, '"session_id":"session:FRONT"'); has(l, '"tsesh"') end, nil, "tsesh_open")
case("tsesh_agents: floating layer in agents mode", home, function() end, function(ok, err, l)
	assert(ok, err); has(l, "call:session.new_layer"); has(l, '"agents"') end, nil, "tsesh_agents")
case("tsesh_open: remote ctx uses home CLI", remote, function() fake.sessions = { { session_id = "session:HOME1" } } end, function(ok, err, l)
	assert(ok, err); has(l, "api call session.list"); has(l, "api call session.new_window"); has(l, "queue:session.select") end, nil, "tsesh_open")
case("tsesh_open: no local session -> creates one", {}, function() end, function(ok, err, l)
	assert(ok, err); has(l, "call:session.list"); has(l, "call:session.create"); has(l, "session:NEW") end, nil, "tsesh_open")
case("murmur_dash: floating layer in active window", home, function() end, function(ok, err, l)
	assert(ok, err); has(l, "call:session.new_layer"); has(l, '"label":"murmur dash"') end, nil, "murmur_dash")
case("murmur_dash: remote ctx opens tab via home CLI", remote, function() fake.sessions = { { session_id = "session:HOME1" } } end, function(ok, err, l)
	assert(ok, err); has(l, "api call session.new_window"); has(l, "queue:session.select") end, nil, "murmur_dash")
case("session_name_from_cwd: renames session to cwd basename", { session_id = "session:FRONT", block_id = "block:B1" }, function()
	fake.block_reply = function() return { foreground = { cwd = "/Users/me/hacking/murmur" }, home = "/Users/me" } end
end, function(ok, err, l)
	assert(ok, err); has(l, "call:session.set_label"); has(l, '"label":"murmur"') end, nil, "session_name_from_cwd")
case("session_name_from_cwd: home dir becomes ~", { session_id = "session:FRONT", block_id = "block:B1" }, function()
	fake.block_reply = function() return { foreground = { cwd = "/Users/me" }, home = "/Users/me" } end
end, function(ok, err, l)
	assert(ok, err); has(l, '"label":"~"'); end, nil, "session_name_from_cwd")

-- setup options
case("setup: key and leader false binds nothing", home, function() end, function(ok, err)
	assert(ok, err); assert(#binds == 0, table.concat(binds, ",")) end, { key = false, leader = false }, "tsesh_open")
case("setup: defaults bind cmd+j and cmd+b leader", home, function() end, function(ok, err)
	assert(ok, err)
	local b = table.concat(binds, ",")
	has(b, "cmd+j=tsesh_agents"); has(b, "mu_crew_leader/s=tsesh_open"); has(b, "mu_crew_leader/a=tsesh_agents")
	has(b, "mu_crew_leader/shift+g=murmur_dash"); has(b, "mu_crew_leader/shift+t=session_name_from_cwd")
	has(b, "cmd+b=client.mode.enter")
end, nil, "tsesh_open")

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
local E = { HOME = "/h", MISE_DATA_DIR = "/m", ASDF_DATA_DIR = "/a" }
with_env(E, { ["/h/.local/share/mise/shims"] = 1, ["/m/shims"] = 1, ["/a/shims"] = 1, ["/h/.asdf/shims"] = 1, ["/h/.volta/bin"] = 1, ["/h/.tmux/plugins/tmux-session-picker/bin"] = 1 }, function()
case("setup: default PATH adds existing shim and tsesh dirs", remote, function() fake.sessions = { { session_id = "session:HOME1" } } end, function(ok, err)
	assert(ok, err); assert(fake.rex_path == "/h/.local/bin:/opt/homebrew/bin:/usr/local/bin:/h/.local/share/mise/shims:/m/shims:/a/shims:/h/.asdf/shims:/h/.volta/bin:/h/.tmux/plugins/tmux-session-picker/bin" .. SYS, fake.rex_path) end, nil, "tsesh_open")
end)
case("setup: explicit path and custom binaries", remote, function() fake.sessions = { { session_id = "session:HOME1" } } end, function(ok, err)
	assert(ok, err); assert(fake.rex_argv == "/opt/r/rex"); assert(fake.rex_path == "/a:/b" .. SYS, fake.rex_path) end,
	{ path = { "/a", "/b" }, rex = "/opt/r/rex" }, "tsesh_open")

if live then
case("srv/real CLI: session.list on this Mac", remote, function() fake.real_cli = true end, function(ok, err, l)
	assert(ok, err); has(l, "api call session.list") end, nil, "tsesh_open")
end

return table.concat(results, "\n")
