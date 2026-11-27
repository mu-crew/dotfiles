# Tests

Run the integration suite:

```sh
tests/test.sh
```

And the unit suites:

```sh
python3 tests/test_poller.py
python3 tests/test_host_color.py
python3 tests/test_cursor_osc7501.py
python3 tests/test_cursor_osc7577.py
node --test tests/test_pi_osc7577.ts
```

## What each suite covers

- **`tests/test.sh`**: runs against an isolated tmux server with a fake `murmur` on `PATH`. Covers keys and `none` opt-outs, side panel, glyph defaults and ASCII mode, pill/window/pane formats (including vtmux OSC 7501 states and `@mu_pending`), the no-`#(` redraw rule, local/remote/muzzle probes, host colour, and exit codes. Also invokes `test_examples.sh` and `test_rex.sh`, repeating any `SKIP` lines at the end.
- **`tests/test_examples.sh`**: checks the harness hook examples (`claude/`, `codex/`, `cursor/`, `muse/`) against expected entry tables and against `murmur init` / `mu init` / `muzzle init` on `PATH` (or `MURMUR_CMD` / `MU_CMD` / `MUZZLE_CMD`). Skips the live-CLI half if the CLIs on `PATH` don't match; set `REQUIRE_INITS=1` to turn skips into failures.
- **`tests/test_rex.sh`**: runs `luacheck`, `stylua --check`, `rex config check` on `rex/init.example.lua` and bare `require`, and `tests/rex_harness.lua` inside Rex (`rex --autostart=false do`). Skips parts whose tools or Rex server are missing; `REX_LIVE=1` adds two read-only live-server checks.
- **`tests/test_poller.py`**: parsers and probe calculations for `tmux/scripts/mu-crew-poller`.
- **`tests/test_host_color.py`**: pins `tmux/scripts/mu-crew-host-color` against murmur's CRC-32 palette.
- **`tests/test_cursor_osc7501.py`** & **`tests/test_cursor_osc7577.py`**: Cursor bridge OSC 7501 sequences and OSC 7577 records verified against a mirror of vtmux's D35 verifier.
- **`tests/test_pi_osc7577.ts`**: Pi OSC 7577 extension verified against the same vtmux verifier.
