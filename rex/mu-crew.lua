-- mu-crew for Rex: a key that jumps to any agent murmur sees, Rex or tmux,
-- on this Mac or a peer. Nothing happens until setup is called:
--
--   package.path = os.getenv("HOME") .. "/.local/share/mu-crew-dotfiles/rex/?.lua;" .. package.path
--   require("mu-crew").setup()
--
-- See the Rex section of the README for the options.
-- luacheck: read globals rex

local M = {}

-- Rex.app sends a key to its home server (this Mac) even while it shows a
-- remote session, so the action always runs here, and the palette prompt is
-- the app's own, so it opens over whatever session is in front. Its Rex calls
-- are another matter: see call below.

-- Set by setup.
local path, murmur, rex_cli, tsesh_cli

-- Most urgent first (matches murmur's priority order); the rest keep murmur's order.
local rank = { error = 1, blocked = 2, done = 3, working = 4, waiting = 5, idle = 6 }

local function fleet(include_crew)
	-- Live first; a slow peer must not eat the action's 30 s, so fall back to
	-- the snapshots murmur already has.
	local r, err = rex.exec({ murmur, "status", "--json" }, { env = { PATH = path }, timeout = 8 })
	if r and r.timed_out then
		r, err = rex.exec({ murmur, "status", "--json", "--cached" }, { env = { PATH = path }, timeout = 5 })
	end
	if r == nil then
		error("murmur status: " .. err .. "; is murmur on the switcher's PATH? Pass path = {...} to setup()", 0)
	end
	if not r.ok then
		local stderr = r.stderr or ""
		-- `#!/usr/bin/env node` with node only in a version manager's shims.
		local missing = stderr:match("env: ([^:\n]+): No such file")
		if missing then
			error("murmur needs " .. missing .. " on the switcher's PATH; pass path = {...} to setup()", 0)
		end
		error("murmur status: " .. (r.timed_out and "timed out" or stderr), 0)
	end
	local status, bad = rex.json.decode(r.stdout)
	if status == nil then
		error("murmur status: " .. bad, 0)
	end
	local panes = {}
	for i, p in ipairs(status.panes or {}) do
		-- visible is murmur's own filter (it hides finished crew workers); a
		-- crashed pane is gone, so there is nothing to jump to.
		if (include_crew or p.visible) and p.render_state ~= "crashed" and p.jump_target then
			p.order = i
			panes[#panes + 1] = p
		end
	end
	table.sort(panes, function(a, b)
		local ra, rb = rank[a.render_state] or 9, rank[b.render_state] or 9
		if ra ~= rb then
			return ra < rb
		end
		return a.order < b.order
	end)
	return panes
end

local function show(session_id, window_id)
	rex.client.queue("session.select", { session_id = session_id, window_id = window_id })
end

-- Every Rex server call goes through here, so the local and remote-session
-- cases can't drift: server is a rex.servers() label, or THIS_MAC. One action
-- may run 30 s, so a call only starts if its worst case still fits: the CLI's
-- rex.exec timeout, or a relayed call's 10 s reply limit.
local THIS_MAC = false
local function call(job, server, method, args)
	if not server and job.server then
		-- Pressed over a remote session: rex.call goes to that server and an
		-- action can't rex.server its own, so this Mac gets the local CLI.
		if os.time() + 6 > job.deadline then
			return nil, "out of time"
		end
		local cmd = { rex_cli, "--autostart=false", "--timeout", "5s", "api", "call", method, rex.json.encode(args) }
		local r, err = rex.exec(cmd, { env = { PATH = path }, timeout = 6 })
		if r == nil then
			return nil, err
		end
		if r.timed_out then
			return nil, "rex " .. method .. ": timed out"
		end
		if not r.ok then
			local first = r.stderr:match("[^\n]+") or ("exit " .. tostring(r.code))
			return nil, (first:gsub("^Error: ", ""))
		end
		return rex.json.decode(r.stdout) or true
	end
	if not server then
		return rex.call(method, args)
	end
	-- Relayed, to ctx.server or a peer: both wait up to 10 s for the reply.
	if os.time() + 10 > job.deadline then
		return nil, "out of time"
	end
	if server == job.server then
		return rex.call(method, args)
	end
	return rex.server(server).call(method, args)
end

-- A Rex pane: focus its block on the server that owns it, then show its
-- session. No ssh and no Remote Control: the app relays calls to the servers
-- it is connected to, and a remote pane on a host it isn't connected to is
-- one the app couldn't show anyway.
local function jump_rex(job, p)
	local owners = { THIS_MAC }
	if not p["local"] then
		-- Host labels read like user@host; ask only the matching ones when
		-- there are any, since each dead server can take 10 s.
		local all, match = rex.servers(), {}
		for _, label in ipairs(all) do
			if label:match("[^@]*$") == p.host then
				match[#match + 1] = label
			end
		end
		owners = #match > 0 and match or all
	end
	local args = { session_id = p.session, block_id = p.pane }
	local ok, err = nil, "no connected Rex server has it (connect the host in Rex.app)"
	for _, server in ipairs(owners) do
		local why
		ok, why = call(job, server, "session.focus_block", args)
		if ok then
			break
		end
		err = why or err
	end
	if not ok then
		error(p.label .. " on " .. p.host .. ": " .. err, 0)
	end
	show(p.session, p.window and p.window:match("^window:") and p.window or nil)
end

-- A tmux pane: `murmur jump` in a new tab on this Mac, which attaches there
-- (switch-client needs a tmux client, and the server has none). The tab owns
-- the attach, so ssh and a peer's hardware-tap prompt get a terminal and no
-- 30 s action limit; it closes on detach, and stays up to show a failure.
-- $0 is the PATH, $1 the jump target, $2 the murmur command.
local attach = [[
export PATH="$0"
unset TERM_PROGRAM TMUX
"$2" jump "$1" || { printf '\nPress Enter to close.'; read -r _; }
]]

-- Rex rejects a window label over 128 characters.
local function clamp(s, n)
	local out = {}
	for ch in s:gmatch("[%z\1-\127\192-\255][\128-\191]*") do
		if #out == n then
			out[n] = "…"
			break
		end
		out[#out + 1] = ch
	end
	return table.concat(out)
end

local function jump_tmux(job, p)
	local tab = {
		window_label = clamp(p["local"] and p.label or (p.host .. " · " .. p.label), 128),
		layout = rex.layout.block({
			flavor = "com.superlogical.terminal.shell",
			options = { command = { "/bin/sh", "-c", attach, path, p.jump_target, murmur } },
		}),
	}
	-- The tab goes in the session in front when it is this Mac's (job.server
	-- names the other server otherwise), else in any local session, else a new one.
	local session = not job.server and job.session_id
	if not session then
		local list, err = call(job, THIS_MAC, "session.list", {})
		if type(list) ~= "table" then
			error("session list: " .. tostring(err), 0)
		end
		session = list.sessions and list.sessions[1] and list.sessions[1].session_id
	end
	if not session then
		local s, err = call(job, THIS_MAC, "session.create", { label = "agents", initial_windows = { tab } })
		if type(s) ~= "table" then
			error("new session: " .. tostring(err), 0)
		end
		return show(s.session_id)
	end
	tab.session_id = session
	local w, err = call(job, THIS_MAC, "session.new_window", tab)
	if type(w) ~= "table" then
		error("new tab: " .. tostring(err), 0)
	end
	show(session, w.window_id)
end

local function format_age(updated_at)
	if type(updated_at) ~= "number" then
		return nil
	end
	local secs = math.floor(os.time() - updated_at / 1000)
	if secs < 60 then
		return nil
	end
	if secs < 3600 then
		return math.floor(secs / 60) .. "m"
	end
	if secs < 86400 then
		return math.floor(secs / 3600) .. "h"
	end
	return math.floor(secs / 86400) .. "d"
end

local function run_jump(ctx, args, include_crew)
	-- Only time spent running counts toward the 30 s, not the pick.
	local started = os.time()
	local panes = fleet(include_crew)
	local used = os.time() - started
	local target = args.target
	if target == nil then
		local items = {}
		for _, p in ipairs(panes) do
			local where = p.session_name or ""
			if p.window_name and p.window_name ~= "" then
				where = where .. "/" .. p.window_name
			end
			local parts = { p.host }
			if p.workstream and p.workstream ~= "" and p.workstream ~= p.label then
				parts[#parts + 1] = p.workstream
			elseif where ~= "" then
				parts[#parts + 1] = where
			end
			parts[#parts + 1] = p.harness or p.cli or "?"
			parts[#parts + 1] = p.server.kind == "rex" and "rex" or "tmux"
			local elapsed = format_age(p.updated_at)
			if elapsed then
				parts[#parts + 1] = elapsed
			end
			items[#items + 1] = {
				id = p.jump_target,
				title = p.label,
				subtitle = table.concat(parts, " · "),
				detail = p.render_state,
				icon = p["local"] and "terminal" or "server",
			}
		end
		if #panes == 0 then
			items[1] = { id = "none", title = "No agents", subtitle = "murmur status lists no live panes" }
		end
		local why
		target, why = rex.ui.pick({
			title = include_crew and "Jump to agent (crew)" or "Jump to agent",
			placeholder = "Filter agents",
			items = items,
		})
		if target == nil then
			if why ~= "cancelled" then
				error("agent picker: " .. why, 0)
			end
			return
		end
		if #panes == 0 then
			return
		end
	end
	-- 2 s spare for os.time's whole seconds.
	local job = { server = ctx.server, session_id = ctx.session_id, deadline = os.time() + 28 - used }
	for _, p in ipairs(panes) do
		if p.jump_target == target then
			if p.server.kind == "rex" then
				return jump_rex(job, p)
			end
			return jump_tmux(job, p)
		end
	end
	error("no such agent: " .. target, 0)
end

local function run(ctx, args)
	return run_jump(ctx, args, false)
end

local function run_crew(ctx, args)
	return run_jump(ctx, args, true)
end

local function local_session(job)
	local session = not job.server and job.session_id
	if session then
		return session
	end
	local list, err = call(job, THIS_MAC, "session.list", {})
	if type(list) ~= "table" then
		error("session list: " .. tostring(err), 0)
	end
	return list.sessions and list.sessions[1] and list.sessions[1].session_id
end

-- Open tsesh in a centered floating Rex layer (like tmux display-popup -E).
-- Exits and closes the layer automatically when the user picks or cancels.
local tsesh_cmd = [[
export PATH="$0"
exec "$1" pick-and-connect
]]

local function run_tsesh(ctx)
	local job = { server = ctx.server, session_id = ctx.session_id, deadline = os.time() + 28 }
	local layout = rex.layout.block({
		flavor = "com.superlogical.terminal.shell",
		options = { command = { "/bin/sh", "-c", tsesh_cmd, path, tsesh_cli } },
	})
	local session = local_session(job)
	if not session then
		local s, err = call(job, THIS_MAC, "session.create", {
			label = "tsesh",
			initial_windows = { { window_label = "tsesh", layout = layout } },
		})
		if type(s) ~= "table" then
			error("new session: " .. tostring(err), 0)
		end
		return show(s.session_id)
	end
	if not job.server then
		local layer, err = call(job, THIS_MAC, "session.new_layer", {
			session_id = session,
			bounds = { 0.05, 0.05, 0.9, 0.9 },
			focus = true,
			layout = layout,
		})
		if type(layer) == "table" then
			return
		end
		-- Fall through to a tab if the window rejected the floating layer.
		if err and tostring(err):find("out of time", 1, true) then
			error("tsesh layer: " .. tostring(err), 0)
		end
	end
	local w, err = call(job, THIS_MAC, "session.new_window", {
		session_id = session,
		window_label = "tsesh",
		layout = layout,
	})
	if type(w) ~= "table" then
		error("new tab: " .. tostring(err), 0)
	end
	show(session, w.window_id)
end

local dash_cmd = [[
export PATH="$0"
"$1" dash || { printf '\nPress Enter to close.'; read -r _; }
]]

local function run_dash(ctx)
	local job = { server = ctx.server, session_id = ctx.session_id, deadline = os.time() + 28 }
	local tab = {
		window_label = "murmur dash",
		focus = true,
		layout = rex.layout.block({
			flavor = "com.superlogical.terminal.shell",
			options = { command = { "/bin/sh", "-c", dash_cmd, path, murmur } },
		}),
	}
	local session = local_session(job)
	if not session then
		local s, err = call(job, THIS_MAC, "session.create", { label = "agents", initial_windows = { tab } })
		if type(s) ~= "table" then
			error("new session: " .. tostring(err), 0)
		end
		return show(s.session_id)
	end
	-- Reuse an existing "murmur dash" tab in this session rather than stacking duplicates.
	local view = call(job, THIS_MAC, "session.view", { session_id = session })
	if type(view) == "table" and type(view.windows) == "table" then
		for _, win in ipairs(view.windows) do
			if win.label == "murmur dash" and win.window_id then
				call(job, THIS_MAC, "session.focus_window", { session_id = session, window_id = win.window_id })
				return show(session, win.window_id)
			end
		end
	end
	tab.session_id = session
	local w, err = call(job, THIS_MAC, "session.new_window", tab)
	if type(w) ~= "table" then
		error("new tab: " .. tostring(err), 0)
	end
	show(session, w.window_id)
end

local function run_rename_from_cwd(ctx)
	if not ctx.session_id or not ctx.block_id then
		error("no focused pane to read cwd from", 0)
	end
	local proc = rex.block.call("com.superlogical.terminal", "process", { block_id = ctx.block_id })
	local cwd = proc and proc.foreground and proc.foreground.cwd
	if (not cwd or cwd == "") and proc and proc.ancestors and proc.ancestors[1] then
		cwd = proc.ancestors[1].cwd
	end
	if not cwd or cwd == "" then
		error("could not read cwd from focused pane", 0)
	end
	local trimmed = cwd:gsub("/+$", "")
	local label
	if proc.home and trimmed == proc.home:gsub("/+$", "") then
		label = "~"
	else
		label = trimmed:match("([^/]+)$") or "/"
	end
	local ok, err = rex.call("session.set_label", { session_id = ctx.session_id, label = clamp(label, 128) })
	if not ok then
		error("rename session: " .. tostring(err), 0)
	end
end

-- The Rex server runs with launchd's PATH, which has none of the usual
-- install directories; the system ones are always added after these. Version
-- manager shim directories follow when they exist, so `#!/usr/bin/env node`
-- finds node.
local function is_dir(d)
	local f = io.open(d .. "/.")
	if f then
		f:close()
		return true
	end
	return false
end

local function default_path()
	local home = os.getenv("HOME") or ""
	local dirs = { home .. "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin" }
	local shims = { home .. "/.local/share/mise/shims" }
	for _, v in ipairs({ { "MISE_DATA_DIR", "/shims" }, { "ASDF_DATA_DIR", "/shims" } }) do
		local d = os.getenv(v[1])
		if d and d ~= "" then
			shims[#shims + 1] = d .. v[2]
		end
	end
	shims[#shims + 1] = home .. "/.asdf/shims"
	shims[#shims + 1] = home .. "/.volta/bin"
	shims[#shims + 1] = home .. "/.tmux/plugins/tmux-session-picker/bin"
	for _, d in ipairs(shims) do
		if is_dir(d) then
			dirs[#dirs + 1] = d
		end
	end
	return dirs
end

-- opts (every field optional):
--   key        direct key for the agent switcher (default "cmd+j"); false or "" binds none
--   leader     leader prefix for tmux-matching chords (default "cmd+b"); false or "" disables
--              the leader mode (s=tsesh, a=agent_jump, A=agent_jump_crew, G=murmur_dash,
--              T=session_name_from_cwd). Leaves ctrl+b free for tmux panes inside Rex.
--   tsesh_key  optional direct key for the floating tsesh picker (default false)
--   crew_key   optional direct key for the crew agent switcher (default false)
--   dash_key   optional direct key for opening murmur dash in a tab (default false)
--   rename_key optional direct key for renaming the current session from cwd (default false)
--   path       directories to find murmur, rex and tsesh in, a list or ":" string
--   murmur     murmur command, a name on path or an absolute path (default "murmur")
--   rex        rex command, likewise (default "rex")
--   tsesh      tsesh command, likewise (default "tsesh")
function M.setup(opts)
	opts = opts or {}
	local dirs = opts.path or default_path()
	if type(dirs) == "table" then
		dirs = table.concat(dirs, ":")
	end
	path = dirs .. ":/usr/bin:/bin:/usr/sbin:/sbin"
	murmur = opts.murmur or "murmur"
	rex_cli = opts.rex or "rex"
	tsesh_cli = opts.tsesh or "tsesh"

	rex.action({
		name = "agent_jump",
		title = "Jump to Agent…",
		description = "Pick a Rex or tmux agent on any murmur host and go to it.",
		keywords = "murmur agent jump switch session peer",
		args = { target = "string?" },
		run = run,
	})
	rex.action({
		name = "agent_jump_crew",
		title = "Jump to Agent (All Crew)…",
		description = "Pick any Rex or tmux agent including hidden crew workers.",
		keywords = "murmur agent crew jump switch",
		args = { target = "string?" },
		run = run_crew,
	})
	rex.action({
		name = "tsesh_open",
		title = "Open Session Picker (tsesh)",
		description = "Open tsesh in a floating Rex pane for sessions, projects, and agents.",
		keywords = "tsesh session project picker switch tmux rex",
		run = run_tsesh,
	})
	rex.action({
		name = "murmur_dash",
		title = "Open Murmur Dash",
		description = "Open murmur dash in a new Rex tab.",
		keywords = "murmur dash agents monitor",
		run = run_dash,
	})
	rex.action({
		name = "session_name_from_cwd",
		title = "Rename Session from Directory",
		description = "Rename the current Rex session to the focused pane's directory name.",
		keywords = "session rename label cwd directory",
		run = run_rename_from_cwd,
	})

	local function bind_opt(val, default, action_name)
		local k = val
		if k == nil then
			k = default
		end
		if k and k ~= "" then
			rex.bind(k, action_name)
		end
	end

	bind_opt(opts.key, "cmd+j", "agent_jump")
	bind_opt(opts.tsesh_key, false, "tsesh_open")
	bind_opt(opts.crew_key, false, "agent_jump_crew")
	bind_opt(opts.dash_key, false, "murmur_dash")
	bind_opt(opts.rename_key, false, "session_name_from_cwd")

	local leader = opts.leader
	if leader == nil then
		leader = "cmd+b"
	end
	if leader and leader ~= "" then
		rex.mode("mu_crew_leader", { exclusive = true })
		rex.bind("mu_crew_leader/s", "tsesh_open")
		rex.bind("mu_crew_leader/a", "agent_jump")
		rex.bind("mu_crew_leader/shift+a", "agent_jump_crew")
		rex.bind("mu_crew_leader/shift+g", "murmur_dash")
		rex.bind("mu_crew_leader/shift+t", "session_name_from_cwd")
		rex.bind(leader, "client.mode.enter", { name = "mu_crew_leader", once = true })
	end
end

return M
