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
local path, murmur, rex_cli

-- Most urgent first; the rest keep murmur's order.
local rank = { blocked = 1, waiting = 2, error = 3, done = 4, working = 5, idle = 6 }

local function fleet()
	-- Live first; a slow peer must not eat the action's 30 s, so fall back to
	-- the snapshots murmur already has.
	local r, err = rex.exec({ murmur, "status", "--json" }, { env = { PATH = path }, timeout = 8 })
	if r and r.timed_out then
		r, err = rex.exec({ murmur, "status", "--json", "--cached" }, { env = { PATH = path }, timeout = 5 })
	end
	if r == nil then
		error("murmur status: " .. err, 0)
	end
	if not r.ok then
		error("murmur status: " .. (r.timed_out and "timed out" or r.stderr), 0)
	end
	local status, bad = rex.json.decode(r.stdout)
	if status == nil then
		error("murmur status: " .. bad, 0)
	end
	local panes = {}
	for i, p in ipairs(status.panes or {}) do
		-- visible is murmur's own filter (it hides finished crew workers); a
		-- crashed pane is gone, so there is nothing to jump to.
		if p.visible and p.render_state ~= "crashed" and p.jump_target then
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

local function run(ctx, args)
	-- Only time spent running counts toward the 30 s, not the pick.
	local started = os.time()
	local panes = fleet()
	local used = os.time() - started
	local target = args.target
	if target == nil then
		local items = {}
		for _, p in ipairs(panes) do
			local where = p.session_name or ""
			if p.window_name and p.window_name ~= "" then
				where = where .. "/" .. p.window_name
			end
			items[#items + 1] = {
				id = p.jump_target,
				title = p.label,
				subtitle = table.concat({
					p.host,
					where,
					p.harness or p.cli or "?",
					p.server.kind == "rex" and "rex" or "tmux",
				}, " · "),
				detail = p.render_state,
				icon = p["local"] and "terminal" or "server",
			}
		end
		if #panes == 0 then
			items[1] = { id = "none", title = "No agents", subtitle = "murmur status lists no live panes" }
		end
		local why
		target, why = rex.ui.pick({ title = "Jump to agent", placeholder = "Filter agents", items = items })
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

-- The Rex server runs with launchd's PATH, which has none of the usual
-- install directories; the system ones are always added after these.
local function default_path()
	local home = os.getenv("HOME") or ""
	return { home .. "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin" }
end

-- opts (every field optional):
--   key    key for the switcher (default "cmd+j"); false or "" binds none,
--          and the action agent_jump is still there to bind yourself
--   path   directories to find murmur and rex in, a list or a ":" string
--          (default ~/.local/bin, /opt/homebrew/bin, /usr/local/bin)
--   murmur murmur command, a name on path or an absolute path (default "murmur")
--   rex    rex command, likewise (default "rex")
function M.setup(opts)
	opts = opts or {}
	local dirs = opts.path or default_path()
	if type(dirs) == "table" then
		dirs = table.concat(dirs, ":")
	end
	path = dirs .. ":/usr/bin:/bin:/usr/sbin:/sbin"
	murmur = opts.murmur or "murmur"
	rex_cli = opts.rex or "rex"

	rex.action({
		name = "agent_jump",
		title = "Jump to Agent…",
		description = "Pick a Rex or tmux agent on any murmur host and go to it.",
		keywords = "murmur agent jump switch session peer",
		args = { target = "string?" },
		run = run,
	})
	local key = opts.key
	if key == nil then
		key = "cmd+j"
	end
	if key and key ~= "" then
		rex.bind(key, "agent_jump")
	end
end

return M
