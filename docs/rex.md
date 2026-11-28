# Rex

[`rex/mu-crew.lua`](../rex/mu-crew.lua) mirrors your tmux `tsesh` and `murmur` bindings in Rex under a one-shot `cmd+b` leader mode (leaving `ctrl+b` free for tmux panes opened inside Rex), plus `cmd+j` for the floating `tsesh` agent picker.

## Requirements

- Rex.app with **Remote Control** enabled in settings.
- `tsesh` (`mu-crew/tmux-session-picker`) on `PATH` or installed via TPM at `~/.tmux/plugins/tmux-session-picker/bin/tsesh`.
- `murmur` 3.1+ for agent state, `murmur dash`, and cross-mux jumping.

## Setup

Add the clone's `rex/` to `package.path` in `~/.config/rex/init.lua` and call `setup()` (a bare `require` binds nothing):

```lua
package.path = os.getenv("HOME") .. "/.local/share/mu-crew-dotfiles/rex/?.lua;" .. package.path
require("mu-crew").setup()
```

[`rex/init.example.lua`](../rex/init.example.lua) is the same file. Verify with `rex config check`, then `rex config reload`.

### Default bindings

| Key | Action | What it does |
| --- | --- | --- |
| `cmd+j` | `tsesh_agents` | Floating `tsesh --mode agents` popup (90% layer) |
| `cmd+b` then `s` | `tsesh_open` | Floating `tsesh` session/project/agent popup (90% layer) |
| `cmd+b` then `a` | `tsesh_agents` | Floating `tsesh --mode agents` popup |
| `cmd+b` then `G` | `murmur_dash` | Open or focus `murmur dash` in a Rex tab |
| `cmd+b` then `T` | `session_name_from_cwd` | Rename the current Rex session to the focused pane's directory name |

### Options

All fields are optional:

| Option | Default | Notes |
| --- | --- | --- |
| `key` | `"cmd+j"` | Direct key for `tsesh_agents`. `false` or `""` binds none. |
| `leader` | `"cmd+b"` | One-shot exclusive `mu_crew_leader` mode (`s`, `a`, `G`, `T`). `false` or `""` disables it. |
| `tsesh_key` | `false` | Optional direct key for `tsesh_open`. |
| `dash_key` | `false` | Optional direct key for `murmur_dash`. |
| `rename_key` | `false` | Optional direct key for `session_name_from_cwd`. |
| `path` | `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, plus existing `mise`/`asdf`/`volta` shims and `~/.tmux/plugins/tmux-session-picker/bin` | List or `:` string where `murmur`, `rex`, and `tsesh` live. `/usr/bin:/bin:/usr/sbin:/sbin` always follow. |
| `murmur` | `"murmur"` | Command name on `path` or absolute path. |
| `rex` | `"rex"` | Command name on `path` or absolute path. |
| `tsesh` | `"tsesh"` | Command name on `path` or absolute path. |
