# mu-crew dotfiles

Shared wiring for [mu](https://github.com/mu-crew/mu), [murmur](https://github.com/mu-crew/murmur), [mule](https://github.com/mu-crew/mule) and [muzzle](https://github.com/mu-crew/muzzle): agent state in tmux tabs and pane borders, status pill and system probes, the Rex agent switcher, OSC 7501/7577 harness bridges, notifications, and ssh config.

It adds wiring, not a theme. Your status line, colours and other keys stay yours.

## Requirements

- **vtmux >= 3.8-rc3** (with `set -s vtmux-program-status on` and `set -s vtmux-program-resume on`) or **Rex**, for live OSC 7501/7577 state and native focus clearing.
  - Vanilla tmux 3.8 works with reduced functionality (no live glyphs; `crashed` dead panes still work). Stay on murmur 2.x (`release/2.x`) for vanilla tmux.
- **murmur 3.0+** for keys, the status pill, and multi-machine counts (without it, keys report it missing and the pill stays empty).
- **Nerd Font** for default glyphs (or set `@mu_crew_ascii 1`), **fzf** for the workstream picker, **Python 3.11+** for the poller and Cursor bridge.

## Install

```sh
git clone https://github.com/mu-crew/dotfiles ~/.local/share/mu-crew-dotfiles
```

**tmux** (`~/.tmux.conf`, before TPM):

```tmux
source-file ~/.local/share/mu-crew-dotfiles/tmux/mu-crew.conf

set -ag status-right '#{E:@mu_crew_pill}'
set -g window-status-format ' #I #W#{E:@mu_crew_window_glyph} '
set -g window-status-current-format ' #I #W#{E:@mu_crew_window_glyph} '
```

**Rex** (`~/.config/rex/init.lua`):

```lua
package.path = os.getenv("HOME") .. "/.local/share/mu-crew-dotfiles/rex/?.lua;" .. package.path
require("mu-crew").setup()
```

Pin a commit if you manage dotfiles declaratively, and bump it when updating `murmur`.

## What's in this repo

| Component | Entry point | Docs |
| --- | --- | --- |
| tmux status, glyphs, keys, probes | [`tmux/mu-crew.conf`](tmux/mu-crew.conf) | [`docs/tmux.md`](docs/tmux.md) |
| Rex `cmd+j` agent switcher | [`rex/mu-crew.lua`](rex/mu-crew.lua) | [`docs/rex.md`](docs/rex.md) |
| Cursor OSC 7501/7577 bridge | [`cursor/osc7501`](cursor/osc7501) | [`docs/harnesses.md`](docs/harnesses.md#cursor-cli-bridge) |
| Pi OSC 7577 resume extension | [`pi/osc7577.ts`](pi/osc7577.ts) | [`docs/harnesses.md`](docs/harnesses.md#pi-osc-7577-extension) |
| Harness hook examples (`mu`, `muzzle`, murmur 2.x) | `claude/`, `codex/`, `cursor/`, `muse/` | [`docs/harnesses.md`](docs/harnesses.md#harness-hooks-mu-and-muzzle) |
| Desktop notifications | [`murmur/on-attention`](murmur/on-attention) | [Notifications](#notifications) |
| SSH ControlMaster / mule snippet | [`ssh/mu-crew.conf`](ssh/mu-crew.conf) | [ssh](#ssh) |
| Test suites | `tests/test.sh` + unit tests | [`docs/tests.md`](docs/tests.md) |

## Notifications

[`murmur/on-attention`](murmur/on-attention) sends one desktop notification per new `done`, `blocked`, `error` or `crashed` event (skipping `done` from orchestrated crew agents):

```sh
ln -s ~/.local/share/mu-crew-dotfiles/murmur/on-attention ~/.config/murmur/on-attention
```

- **Linux:** `notify-send -a murmur` (`done` normal; `blocked`/`error`/`crashed` critical). For mako, set `max-icon-size=72` under `[app-name=murmur]` if 64px feels small.
- **macOS:** `terminal-notifier` (with icon), else `osascript`.
- **Icons:** 128px rounded frame in `MURMUR_HOST_COLOR` with `MURMUR_GLYPH` in `MURMUR_KIND_COLOR`, rendered once with ImageMagick (`magick`) and cached in `~/.cache/murmur/`. Override fill/font with `MURMUR_ICON_BASE` (default `#1e1e2e`) and `MURMUR_ICON_FONT` (default `JetBrainsMono Nerd Font`). Falls back to no icon if `magick` or the font is missing.
- **Test:** `MURMUR_KIND=blocked MURMUR_AGENT=test MURMUR_HOST=$(hostname) MURMUR_HOST_COLOR='#cba6f7' MURMUR_GLYPH=$'\uf075' MURMUR_KIND_COLOR='#fab387' murmur/on-attention`.

## ssh

[`ssh/mu-crew.conf`](ssh/mu-crew.conf) is an `Include` snippet for `~/.ssh/config`: shared ControlMaster for 2FA hosts, `MaxSessions 1` guidance, and a dedicated socket for `mule`. Background: murmur's [SSH.md](https://github.com/mu-crew/murmur/blob/main/SSH.md).

## Related

- [mu-crew](https://github.com/mu-crew): the org, with the stance and design rules these files follow.
- [tsesh](https://github.com/mu-crew/tmux-session-picker): session picker reading `#{session_program_state}` and murmur's agent list.

---

Part of [mu-crew](https://github.com/mu-crew). Written mostly by AI coding agents, with a human reviewing what ships, and built for running them.
