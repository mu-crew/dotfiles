# Harnesses

Under vtmux >= 3.8-rc3 or Rex, harnesses report live state over OSC 7501 (program status) and relaunch commands over OSC 7577 (program resume):

| Harness | OSC 7501 (status) | OSC 7577 (resume) | Notes |
| --- | --- | --- | --- |
| Claude Code (>= 2.1.295) | native | — | — |
| Codex (>= 0.164.0) | native | — | — |
| Pi (>= 1.1.0) | native | [`pi/osc7577.ts`](../pi/osc7577.ts) | Extension needed until Pi emits 7577 natively |
| Cursor CLI | [`cursor/osc7501`](../cursor/osc7501) | [`cursor/osc7501`](../cursor/osc7501) | Single hook bridges both protocols |

## Cursor CLI bridge

The Cursor CLI does not yet emit OSC 7501 or OSC 7577 natively. [`cursor/osc7501`](../cursor/osc7501) reads Cursor's hook JSON from stdin, writes OSC 7501 to `/dev/tty` (or the nearest ancestor process's tty when Cursor detaches hooks), and — when `$OSC7577_TOKEN` is set (`vtmux-program-resume on`) — signs an OSC 7577 record (`argv=["cursor-agent","--resume",<conversation id>]` plus workspace cwd) for the hook's parent process on `sessionStart`/`beforeSubmitPrompt`, clearing it on `sessionEnd`. It always exits 0 and prints nothing.

Add it to `~/.cursor/hooks.json` for `sessionStart`, `beforeSubmitPrompt`, `beforeShellExecution`, `stop`, and `sessionEnd`:

```json
{ "command": "$HOME/.local/share/mu-crew-dotfiles/cursor/osc7501" }
```

Remove it once Cursor ships native OSC 7501.

## Pi OSC 7577 extension

Pi emits OSC 7501 natively, but not OSC 7577. Without a live `#{pane_resume_command}`, a finished Pi pane loses its idle glyph in tmux and disappears from `murmur` and `tsesh` as soon as vtmux clears `done`/`error` on focus.

[`pi/osc7577.ts`](../pi/osc7577.ts) signs and writes `argv=["pi","--session",<file>]` plus session cwd to `/dev/tty` on `session_start` and clears it on `session_shutdown` (not on `/reload`). No-op without `$OSC7577_TOKEN` or for ephemeral sessions.

Enable it in `~/.pi/agent/settings.json`:

```json
{
  "extensions": ["~/.local/share/mu-crew-dotfiles/pi/osc7577.ts"]
}
```

Or symlink it into `~/.pi/agent/extensions/osc7577.ts`. Remove it once Pi ships native OSC 7577.

## Harness hooks (`mu` and `muzzle`)

For keep-driving (`mu`) and command queueing (`muzzle`), each tool's `init` merges its own hook entries into the harness config files without touching other entries:

```sh
mu init       # keep-driving Stop hook (not Muse Code) + mu skills
muzzle init   # shell-command queueing hook
```

- `CLAUDE_CONFIG_DIR` and `CODEX_HOME` relocate Claude Code's and Codex's files when set and non-empty.
- Codex asks you to trust new or changed hooks once (`/hooks`).
- Cursor's `mu hook stop` lifts `loop_limit` (`mu` caps follow-ups with `MU_KEEP_DRIVING_MAX`).
- `mu init` installs skills into `~/.claude/skills` and `~/.codex/skills` (never `~/.agents/skills`; Cursor reads those two paths too).

### Checked-in hook examples (murmur 2.x)

`murmur` 3.0 removed `murmur hook` and `murmur notify` — `murmur init` no longer edits harness configs, and `murmur doctor` flags leftover 2.x entries as stale. The checked-in example files below still show the **murmur 2.x** (`release/2.x`) hook layout alongside `mu` and `muzzle`:

| Harness | Example | Target path |
| --- | --- | --- |
| Claude Code | [`claude/settings.json`](../claude/settings.json) | `~/.claude/settings.json` |
| Codex | [`codex/hooks.json`](../codex/hooks.json) | `~/.codex/hooks.json` |
| Cursor CLI | [`cursor/hooks.json`](../cursor/hooks.json) | `~/.cursor/hooks.json` |
| Muse Code | [`muse/settings.json`](../muse/settings.json) | `~/.config/muse/settings.json` (`hooks` key) |
| OpenCode | [`opencode/plugins/murmur/tui.ts`](../opencode/plugins/murmur/tui.ts) | `~/.config/opencode/plugins/murmur/tui.ts` (attention-only `murmur notify` plugin for OpenCode 2 + murmur 2.x) |

[`codex/config.toml`](../codex/config.toml) explains why `~/.codex/config.toml` needs no inline hook or `notify` entries.
