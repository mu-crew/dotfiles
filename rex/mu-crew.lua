-- mu-crew for Rex: tmux-matching bindings under a one-shot leader (`cmd+b`)
-- plus `cmd+j` for the floating tsesh agent picker. Nothing happens until
-- setup is called:
--
--   package.path = os.getenv("HOME") .. "/.local/share/mu-crew-dotfiles/rex/?.lua;" .. package.path
--   require("mu-crew").setup()
--
-- See docs/rex.md for the options.
-- luacheck: read globals rex

local M = {}

-- Set by setup.
local path, murmur, rex_cli, tsesh_cli

local function show(session_id, window_id)
	rex.client.queue("session.select", { session_id = session_id, window_id = window_id })
end

-- Call the local Rex server (via rex.call when on this Mac, or the local rex
-- CLI when invoked over a remote session).
local function call_local(job, method, args)
	if job.server then
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
	return rex.call(method, args)
end

-- Rex rejects a label over 128 characters.
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

local function local_session(job)
	local session = not job.server and job.session_id
	if session then
		return session
	end
	local list, err = call_local(job, "session.list", {})
	if type(list) ~= "table" then
		error("session list: " .. tostring(err), 0)
	end
	return list.sessions and list.sessions[1] and list.sessions[1].session_id
end

-- Open tsesh in a centered floating Rex layer (like tmux display-popup -E).
-- Exits and closes the layer automatically when the user picks or cancels.
local tsesh_cmd = [[
export PATH="$0"
if [ -n "$2" ]; then
  exec "$1" pick-and-connect --mode "$2"
else
  exec "$1" pick-and-connect
fi
]]

local function open_tsesh(ctx, mode)
	local job = { server = ctx.server, session_id = ctx.session_id, deadline = os.time() + 28 }
	local layout = rex.layout.block({
		flavor = "com.superlogical.terminal.shell",
		options = { command = { "/bin/sh", "-c", tsesh_cmd, path, tsesh_cli, mode or "" } },
	})
	local session = local_session(job)
	if not session then
		local s, err = call_local(job, "session.create", {
			label = "tsesh",
			initial_windows = { { window_label = "tsesh", layout = layout } },
		})
		if type(s) ~= "table" then
			error("new session: " .. tostring(err), 0)
		end
		return show(s.session_id)
	end
	if not job.server then
		local layer, err = call_local(job, "session.new_layer", {
			session_id = session,
			bounds = { 0.05, 0.05, 0.9, 0.9 },
			focus = true,
			layout = layout,
		})
		if type(layer) == "table" then
			return
		end
		if err and tostring(err):find("out of time", 1, true) then
			error("tsesh layer: " .. tostring(err), 0)
		end
	end
	local w, err = call_local(job, "session.new_window", {
		session_id = session,
		window_label = "tsesh",
		focus = true,
		layout = layout,
	})
	if type(w) ~= "table" then
		error("new tab: " .. tostring(err), 0)
	end
	show(session, w.window_id)
end

local function run_tsesh(ctx)
	return open_tsesh(ctx, nil)
end

local function run_tsesh_agents(ctx)
	return open_tsesh(ctx, "agents")
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
		local s, err = call_local(job, "session.create", { label = "agents", initial_windows = { tab } })
		if type(s) ~= "table" then
			error("new session: " .. tostring(err), 0)
		end
		return show(s.session_id)
	end
	-- Reuse an existing "murmur dash" tab in this session rather than stacking duplicates.
	local view = call_local(job, "session.view", { session_id = session })
	if type(view) == "table" and type(view.windows) == "table" then
		for _, win in ipairs(view.windows) do
			if win.label == "murmur dash" and win.window_id then
				call_local(job, "session.focus_window", { session_id = session, window_id = win.window_id })
				return show(session, win.window_id)
			end
		end
	end
	tab.session_id = session
	local w, err = call_local(job, "session.new_window", tab)
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
-- install directories; the system ones are always added after these.
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
--   key        direct key for tsesh_agents (default "cmd+j"); false or "" binds none
--   leader     leader prefix for tmux-matching chords (default "cmd+b"); false or "" disables
--              the leader mode (s=tsesh_open, a=tsesh_agents, G=murmur_dash,
--              T=session_name_from_cwd). Leaves ctrl+b free for tmux panes inside Rex.
--   tsesh_key  optional direct key for tsesh_open (default false)
--   dash_key   optional direct key for murmur_dash (default false)
--   rename_key optional direct key for session_name_from_cwd (default false)
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
		name = "tsesh_open",
		title = "Open Session Picker (tsesh)",
		description = "Open tsesh in a floating Rex pane for sessions, projects, and agents.",
		keywords = "tsesh session project picker switch tmux rex",
		run = run_tsesh,
	})
	rex.action({
		name = "tsesh_agents",
		title = "Open Agent Picker (tsesh)",
		description = "Open tsesh in agents mode in a floating Rex pane.",
		keywords = "tsesh agent picker jump switch murmur tmux rex",
		run = run_tsesh_agents,
	})
	rex.action({
		name = "murmur_dash",
		title = "Open Murmur Dash",
		description = "Open or focus murmur dash in a Rex tab.",
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

	bind_opt(opts.key, "cmd+j", "tsesh_agents")
	bind_opt(opts.tsesh_key, false, "tsesh_open")
	bind_opt(opts.dash_key, false, "murmur_dash")
	bind_opt(opts.rename_key, false, "session_name_from_cwd")

	local leader = opts.leader
	if leader == nil then
		leader = "cmd+b"
	end
	if leader and leader ~= "" then
		rex.mode("mu_crew_leader", { exclusive = true })
		rex.bind("mu_crew_leader/s", "tsesh_open")
		rex.bind("mu_crew_leader/a", "tsesh_agents")
		rex.bind("mu_crew_leader/shift+g", "murmur_dash")
		rex.bind("mu_crew_leader/shift+t", "session_name_from_cwd")
		rex.bind(leader, "client.mode.enter", { name = "mu_crew_leader", once = true })
	end
end

return M
