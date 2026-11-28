# Rex

[`rex/mu-crew.lua`](../rex/mu-crew.lua) adds a picker (`cmd+j` by default) in Rex that lists every agent `murmur` sees — Rex or tmux, on this Mac or a peer — and jumps to the one you pick. A Rex agent is focused on the server that owns it; a tmux agent opens in a new tab on this Mac running `murmur jump`, closing on detach and staying open on failure.

## Requirements

- Rex.app with **Remote Control** enabled in settings (the switcher drives Rex.app from the Rex server).
- `murmur` 3.0+ with peers configured (`murmur peer`) for remote agents.
- Remote Rex hosts connected in Rex.app.

## Setup

Add the clone's `rex/` to `package.path` in `~/.config/rex/init.lua` and call `setup()` (a bare `require` binds nothing):

```lua
package.path = os.getenv("HOME") .. "/.local/share/mu-crew-dotfiles/rex/?.lua;" .. package.path
require("mu-crew").setup()
```

[`rex/init.example.lua`](../rex/init.example.lua) is the same file. Verify with `rex config check`, then `rex config reload`.

### Options

All fields are optional:

| Option | Default | Notes |
| --- | --- | --- |
| `key` | `"cmd+j"` | Direct key for the native agent palette (`agent_jump`). `false` or `""` binds none. |
| `leader` | `"ctrl+b"` | One-shot leader mode matching tmux (`s` = floating `tsesh`, `a` = `agent_jump`, `A` = `agent_jump_crew`, `G` = `murmur_dash`, `T` = `session_name_from_cwd`). Passes through when the focused pane runs `tmux`. `false` or `""` disables it. |
| `tsesh_key` | `false` | Optional direct key for `tsesh_open` (floating `tsesh` popup via `session.new_layer`). |
| `crew_key` | `false` | Optional direct key for `agent_jump_crew` (native palette including hidden crew workers). |
| `dash_key` | `false` | Optional direct key for `murmur_dash` (opens `murmur dash` in a tab). |
| `rename_key` | `false` | Optional direct key for `session_name_from_cwd` (renames the current session to the focused pane's directory name). |
| `path` | `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, plus existing shims (`mise`, `asdf`, `volta`) | List or `:` string where `murmur`, `rex`, and `tsesh` live. Setting it replaces the list; `/usr/bin:/bin:/usr/sbin:/sbin` always follow. |
| `murmur` | `"murmur"` | Command name on `path` or absolute path. |
| `rex` | `"rex"` | Command name on `path` or absolute path. |
| `tsesh` | `"tsesh"` | Command name on `path` or absolute path. |

```lua
require("mu-crew").setup({
  key = "cmd+shift+j",
  path = { "/opt/tools/bin", "/opt/homebrew/bin" },
})
```

### launchd `PATH` and timeouts

The Rex server runs under launchd's `PATH`, not your shell's. Because `murmur` is `#!/usr/bin/env node`, Node from a version manager must be reachable on `path`. The default covers `mise`, `asdf`, and `volta`; for `nvm` or a custom prefix, pass `path = { ..., "/dir/with/node" }`. When `murmur` cannot run, the picker surfaces the reason directly.

Rex caps actions at 30 seconds. The switcher gives `murmur status` 8 seconds, falls back to its cached snapshot for 5 more, and only starts a Rex call when its worst case still fits. With no agents, it shows a single "No agents" row.

## Manual checklist

`tests/test_rex.sh` tests the switcher against stubs; these steps verify a live Rex.app after `rex config reload`:

1. Local session: `cmd+j` opens the picker; `Esc` closes it cleanly. Picking a local Rex agent focuses it; picking a local tmux agent opens a tab in the front session and attaches.
2. Remote session: `cmd+j` opens over it. A local Rex agent switches focus to this Mac; a tmux agent opens its tab on this Mac and runs `murmur jump`; a Rex agent on that same remote host focuses there.
3. Third connected host: focuses there (its Rex host label `user@host` should end in murmur's host name, or the switcher queries every connected server).
4. Empty fleet: shows "No agents"; pressing Enter is a no-op with no error.
5. Same-server other session: focuses the block, then switches to that session.
6. Remote tmux agent over ssh: attaches, closes on detach, holds open with "Press Enter to close." on failure.
7. Remote session calls this Mac via the local `rex` CLI: the Rex server must find `rex` on `path` and reach its socket.
8. Other Rex keybindings still work after reload.
