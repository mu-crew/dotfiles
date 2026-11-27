# tmux

`tmux/mu-crew.conf` wires `mu`, `murmur`, `mule`, `muzzle` and `tsesh` into tmux without touching your theme or status-line layout. Source it from `~/.tmux.conf` (before TPM, so tsesh binds the forwarded session keys once):

```tmux
source-file ~/.local/share/mu-crew-dotfiles/tmux/mu-crew.conf

# Place the pieces where you want them:
set -ag status-right '#{E:@mu_crew_pill}'
set -g window-status-format ' #I #W#{E:@mu_crew_window_glyph} '
set -g window-status-current-format ' #I #W#{E:@mu_crew_window_glyph} '
```

## Feature flags

Each part is on by default. Set its flag to `off` before sourcing to skip it; sourcing again with a flag off removes what that part set.

| Flag | Part |
| --- | --- |
| `@mu_crew_keys` | `C-m` / `G` / `u` |
| `@mu_crew_session_keys` | Forwarding `s` / `a` / `g` / `T` to tsesh |
| `@mu_crew_pane_border` | Pane border format |
| `@mu_crew_probes` | Poller probes; `none` runs no poller (see [Poller and probes](#poller-and-probes)) |

```tmux
set -g @mu_crew_keys off
set -g @mu_crew_pane_border off
source-file ~/.local/share/mu-crew-dotfiles/tmux/mu-crew.conf
```

The formats (pill, glyphs, probe pills) need no flag: they do nothing until you place them.

**Focus clearing** is native in vtmux: it clears `done` and `error` on focus, so no focus hooks are set (sourcing removes old `[42]` hooks).

## Keys

Under the prefix. Set an option before sourcing to move a key, or `none` to leave it unbound.

| Key | Does | Option |
| --- | --- | --- |
| `C-m` | Toggle murmur's side panel in this window | `@mu_crew_key_sidepanel` |
| `G` | Toggle `murmur dash` (open if none runs, or return) | `@mu_crew_key_dash` |
| `u` | Toggle between a workspace session and its mu workstream (`mu-<name>`) | `@mu_crew_key_workstream` |
| `s` / `a` / `g` / `T` | [tsesh](https://github.com/mu-crew/tmux-session-picker): session picker, agents view, last session, session at pane cwd | `@mu_crew_key_session_{pick,agents,last,root}` |

Most terminals send the same code for `C-m` and Enter, so `prefix Enter` opens the side panel too.

**Pane border.** `mu` titles each agent's pane with its name and tasks; the border adds live state (`#{E:@mu_crew_pane_glyph}`). To keep your own `pane-border-format`, set `@mu_crew_pane_border off` before sourcing and place `#{E:@mu_crew_pane_glyph}` yourself.

## Formats

Read through `#{E:...}` so embedded colours apply. They set no background, so they inherit whatever pill or segment wraps them.

| Option | Shows | Reads |
| --- | --- | --- |
| `@mu_crew_pill` | Robot icon, `<count><glyph>` per state (most urgent first), crew total. Empty when no agents exist. | `@murmur_count_*`, `@mu_crew_remote_*` |
| `@mu_crew_window_glyph` | Most urgent agent state in the window; idle glyph when no news (or live OSC 7577 resume record after focus-clear). `crashed` checks the active pane's `pane_dead`; other states are window-wide. | `#{window_program_state}`, `#{pane_resume_command}` |
| `@mu_crew_pane_glyph` | ` · <glyph>` for the pane's own state; a working agent with delegates out shows `▶⧗<n>` from `#{@mu_pending}`. | `#{pane_program_state}`, `#{pane_program_id}`, `#{pane_resume_command}`, `#{@mu_pending}` |
| `@mu_crew_muzzle_pill` | Host muzzle slots: `held/budget`, queued, slow, and starved (>=30s) counts (each hidden at zero). Needs the `muzzle` probe. | `@mu_crew_muzzle_*` |
| `@mu_crew_mem_pill` | Memory use or macOS memory pressure | `@mu_crew_mem` |
| `@mu_crew_cpu_pill` | CPU use | `@mu_crew_cpu` |
| `@mu_crew_uptime` | Compact system uptime | `@mu_crew_uptime_*` |
| `@mu_crew_host_color` | This host's accent hex (value, not a format): `#[bg=#{@mu_crew_host_color}]` | set once at source time |

vtmux also exposes `#{session_program_state}` for session pickers like [tsesh](https://github.com/mu-crew/tmux-session-picker).

## Glyphs and colours

Defaults are Nerd Font glyphs matching `murmur dash`, with Catppuccin Mocha colours. Set `@mu_crew_ascii 1` before sourcing for ASCII fallbacks (`x ! + > - c ai`).

| State | Glyph | Codepoint |
| --- | --- | --- |
| crashed | fa-times-circle | U+F057 |
| error | fa-exclamation-triangle | U+F071 |
| blocked | fa-comment | U+F075 |
| done | fa-check-circle | U+F058 |
| working | fa-play | U+F04B |
| waiting | fa-hourglass-half | U+F252 |
| idle | fa-moon-o | U+F186 |
| crew | fa-users | U+F0C0 |
| agent | md-robot | U+F06A9 |

Override individual glyphs (`@mu_crew_g_<state>`) or colours (`@mu_crew_c_<state>`) after sourcing. The defaults sit between `THEME BEGIN` / `THEME END` markers so a theme generator can rewrite them.

## Host colors

`murmur` assigns every host one accent colour: CRC-32 of its short hostname mod 8 over Catppuccin accents. Sourcing `mu-crew.conf` runs [`tmux/scripts/mu-crew-host-color`](../tmux/scripts/mu-crew-host-color) once and stores the hex in `@mu_crew_host_color`:

```tmux
set -ag status-right '#[fg=#11111b,bg=#{@mu_crew_host_color},bold] #H #[default]'
```

The palette and hash are mirrored in murmur's `src/dash-paint.ts` and pinned in `tests/test_host_color.py`.

## Poller and probes

One background Python process per tmux server (`tmux/scripts/mu-crew-poller`) keeps enabled probes fresh. By default only `murmur_remote` runs. Set `@mu_crew_probes` before sourcing to add more:

```tmux
set -g @mu_crew_probes "murmur_remote memory cpu uptime muzzle"
source-file ~/.local/share/mu-crew-dotfiles/tmux/mu-crew.conf

set -ag status-right '#{E:@mu_crew_mem_pill} #{E:@mu_crew_cpu_pill} #{E:@mu_crew_uptime}'
```

- **Intervals** (`@mu_crew_<probe>_interval` in seconds): defaults are `10` for `murmur_remote`, `5` for `memory`, `cpu`, `muzzle`, and `60` for `uptime`.
- **Thresholds**: `@mu_crew_mem_min`, `@mu_crew_cpu_min` (%), `@mu_crew_uptime_min` (seconds) hide formats below the value. Colours: `@mu_crew_c_{mem,cpu,uptime}`.
- **Backends**: Linux memory reads `/proc/meminfo`, macOS reads `vm_stat` + `memory_pressure`; CPU reads `/proc/stat` on Linux and `top` on macOS; `muzzle` runs `muzzle status --json` (muzzle >= 0.2.3 for slow counts).
- **Lifecycle**: PID file is keyed by tmux socket path; the loop exits when the server stops. Run `tmux/scripts/mu-crew-poller --once` for one-shot debugging.

## Why the pill costs nothing

tmux redraws the status line on every pane, window and session event (measured at 1.2 redraws/s on a 14-window session). Running `murmur status` (Node) inside `#(...)` costs most of a CPU core.

Nothing here runs on a redraw:

- `murmur` writes local counts into `@murmur_count_<state>` on state change; `@mu_crew_pill` is pure tmux format arithmetic.
- Remote counts come from `mu-crew-poller` writing `@mu_crew_remote_<state>` every 10 seconds.

`tests/test.sh` fails if any format in `mu-crew.conf` contains `#(`.
