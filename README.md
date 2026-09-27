# mu-crew dotfiles

tmux, ssh and harness config that makes [mu](https://github.com/mu-crew/mu),
[murmur](https://github.com/mu-crew/murmur) and
[mule](https://github.com/mu-crew/mule) work as one setup: agent state in
your tab bar and pane borders, a status pill, keys for the picker, side panel
and dash, and the hooks that clear an agent's badge when you look at it.

It adds wiring, not a theme. Your status line, colours and other keys stay
yours; you place the pieces where you want them.

## Requirements

- tmux 3.3 or newer.
- murmur, for anything agent-related. Without it the keys print "murmur is not
  installed" and the formats stay empty.
- A [Nerd Font](https://www.nerdfonts.com) for the default glyphs. No Nerd
  Font? See [Glyphs](#glyphs).
- `fzf` for the workstream picker, `python3` for the remote poller.

## Install

Clone it anywhere and source it from `~/.tmux.conf`:

```sh
git clone https://github.com/mu-crew/dotfiles ~/.local/share/mu-crew-dotfiles
```

```tmux
source-file ~/.local/share/mu-crew-dotfiles/tmux/mu-crew.conf

# Place the pieces:
set -ag status-right '#{E:@mu_crew_pill}'
set -g window-status-format ' #I #W#{E:@mu_crew_window_glyph} '
set -g window-status-current-format ' #I #W#{E:@mu_crew_window_glyph} '
```

Pin a commit if you manage dotfiles declaratively, and move it forward when
you update murmur: both sides read the same tmux options.

## What sourcing it does

**Focus hooks.** Selecting an agent's pane, window or session runs
`murmur clear` for that pane, which acknowledges a `done` or `blocked` badge.
Without these a badge never clears. They use hook index 42, so hooks you set
yourself are kept.

**Keys**, under the prefix:

| Key | Does | Option |
| --- | --- | --- |
| `a` | Agent picker popup, across every machine murmur peers with | `@mu_crew_key_pick` |
| `C-m` | Toggle murmur's side panel in this window | `@mu_crew_key_sidepanel` |
| `G` | Back to the running `murmur dash` | `@mu_crew_key_dash` |
| `u` | Toggle between a workspace session and its mu workstream session (`mu-<name>`) | `@mu_crew_key_workstream` |

Set an option before sourcing to move a key, or set it to `none` to leave it
unbound. Most terminals send the same code for `C-m` and Enter, so
`prefix Enter` opens the side panel too.

**Pane border.** mu titles each agent's pane with the agent name and its tasks;
the border shows that title plus murmur's live state. To keep your own
`pane-border-format`, set `@mu_crew_keep_pane_border 1` before sourcing and add
`#{E:@mu_crew_pane_glyph}` to your format.

**Remote poller.** If murmur has peers, a small background loop keeps remote
agents' counts in the pill. See [Why the pill costs nothing](#why-the-pill-costs-nothing).

## Formats you place

| Option | Shows | Reads |
| --- | --- | --- |
| `@mu_crew_pill` | Robot icon, then `<count><glyph>` per state, most urgent first, then the crew total. Empty when no agents exist. | `@murmur_count_*`, `@mu_crew_remote_*` |
| `@mu_crew_window_glyph` | One glyph for the window's most urgent agent state; the idle glyph for an agent window with no news | `@murmur_window_state` |
| `@mu_crew_pane_glyph` | ` · <glyph>` for the pane's own state | `@murmur_pane_state` |

Read them through `#{E:...}` so the colour runs inside apply. They set no
background, so they take the background of wherever you place them.

murmur also sets `@murmur_session_state` on each session. Session pickers can
colour rows from it; [tsesh](https://github.com/martintrojer/tmux-session-picker)
does.

## Glyphs

The defaults are Nerd Font glyphs, the same ones `murmur dash` draws, so one
agent looks the same in every surface:

| State | Glyph | Codepoint |
| --- | --- | --- |
| crashed | fa-times-circle | U+F057 |
| blocked | fa-comment | U+F075 |
| done | fa-check-circle | U+F058 |
| working | fa-play | U+F04B |
| idle | fa-moon-o | U+F186 |
| crew | fa-users | U+F0C0 |
| agent | md-robot | U+F06A9 |

Without a Nerd Font these render as boxes. Set `@mu_crew_ascii 1` before
sourcing to use `x ! + > - c ai` instead.

To change one glyph or colour, set its option after sourcing:
`@mu_crew_g_<state>` for glyphs and `@mu_crew_c_<state>` for colours
(Catppuccin Mocha by default). The defaults sit between `THEME BEGIN` /
`THEME END` markers, so a theme generator can rewrite them.

## Why the pill costs nothing

tmux redraws the status line on every pane, window and session event, not only
every `status-interval`. A 14-window session was measured redrawing 1.2 times
a second. Anything a status line runs through `#(...)` runs that often, and
`murmur status` is a Node start: as a `#(...)` it cost most of a CPU core.

So nothing here runs on a redraw:

- murmur writes this host's counts into `@murmur_count_<state>` whenever an
  agent's state changes. The pill is tmux format arithmetic over those options.
- Remote peers' counts come from `tmux/scripts/murmur-remote-poller`: one loop
  per tmux server, started when the config is sourced, running
  `murmur status --json` every 10 seconds (`MU_CREW_POLL_SECS`) and writing
  `@mu_crew_remote_<state>` only through tmux options. It exits when murmur has
  no peers, when murmur is missing, or when the tmux server stops; sourcing the
  config again restarts it.

Keep it that way when you extend the config. A new format reads options; if it
needs data from a program, a long-lived loop writes the data into an option.
`tests/test.sh` fails if a format in `mu-crew.conf` contains `#(`.

## ssh

[`ssh/mu-crew.conf`](ssh/mu-crew.conf) is an `Include` for `~/.ssh/config`:

- a shared ControlMaster, so murmur can collect from a host that needs a
  second factor after you log in once;
- what to do on a host with `MaxSessions 1`, where murmur, mule and your shell
  must not share one master;
- mule's own socket, so long jobs never take murmur's slot.

Background: murmur's [SSH.md](https://github.com/mu-crew/murmur/blob/main/SSH.md).

## Codex and Cursor

pi reports to murmur from inside the agent. Codex and Cursor instead run a
command when a turn ends:

- [`codex/config.toml`](codex/config.toml): the `notify` line for
  `~/.codex/config.toml`.
- [`cursor/hooks.json`](cursor/hooks.json): a `stop` hook for
  `~/.cursor/hooks.json`.

These report attention only (`done`, `blocked`), not running, idle or crashes.
The agent must run inside tmux.

## Tests

```sh
tests/test.sh
```

Runs against an isolated tmux server with a fake `murmur` on `PATH`: keys and
the `none` opt-out, the side panel key, glyph defaults and ASCII, the pill and
window formats, the cheap-tick rule, and the remote poller's counting and exit
codes.

## Related

- [mu-crew](https://github.com/mu-crew): the org, with the stance and design
  rules these files follow.
- [tsesh](https://github.com/martintrojer/tmux-session-picker): a session
  picker that shows murmur's session state.
