# Agent activity bridge

LidGlow uses lifecycle hooks from Claude Code and Codex. It receives only the agent source, a hashed session identity, a status, and the event time. It does not save prompts, code, tool arguments, project paths, transcripts, or raw session identifiers. Nothing is sent over the network. Local hook invocations finish silently and exit successfully if their input is malformed or the status file cannot be written.

## Connect an agent

Use the app's integration controls to install Claude Code or Codex hooks. The installer adds its own handlers to the existing JSON settings, keeps other settings and handlers, and makes a timestamped backup before changing a settings file. Installing twice does not duplicate handlers. Disconnecting removes only the handlers created by LidGlow.

- **Claude Code:** the settings file is `~/.claude/settings.json`. Restart Claude Code after connecting and inspect `/hooks` if needed. This integration is for Claude Code, not ordinary chats in the Claude app or browser.
- **Codex:** the settings file is `~/.codex/hooks.json`. Open **Settings > Hooks** in Codex desktop or `/hooks` in Codex CLI, then review and trust the LidGlow definitions. Codex intentionally skips untrusted hooks. Local hooks must be available where the coding agent runs; a remote or cloud task does not automatically write to this Mac.

Hook installation, removal, and status checks use Python 3 at `/usr/bin/python3`, provided by the Xcode Command Line Tools on this Mac. The app installs a small native Swift signal executable for the hooks themselves. Normal agent activity does not start Python or a background server. The management helper uses only Python's standard library. No API keys or model subscription are needed by LidGlow.

## Signal mapping

| Event | Status |
| --- | --- |
| Prompt submitted, before a tool, after a tool | Working |
| Permission requested | Needs attention |
| Claude permission or idle notification | Needs attention |
| Main agent stops | Complete |
| Claude stop failure | Error |
| Codex interrupt | Idle |
| Either agent session end | Idle, preserving a recent completion or error |

The helper observes lifecycle events; it does not approve, deny, block, or otherwise decide tool permissions. Multiple concurrent sessions each have a separate snapshot. A later event for a session replaces its previous snapshot atomically. Repeated working signals within 30 seconds are coalesced, while state transitions are written immediately. SessionEnd uses `--preserve-finish` so exiting the CLI does not immediately erase Stop's completion or error signal; it retains that snapshot's original timestamp. An explicit idle signal or Codex interruption still clears the finish. There is no continuous heartbeat when an agent emits no events.

## Files

The installed native signal executable is `~/Library/Application Support/LidGlow/lidglow-signal`. The management helper is `lidglow-hook.py` in that directory. Session snapshots live in the `events` subdirectory. Each snapshot filename is `<source>-<24-character SHA-256 prefix>.json`. Normal use retains at most 256 snapshots. Old snapshots are pruned when a new session writes or at most once per minute during changing activity; files older than 24 hours are removed during pruning. Snapshot files have mode `0600`.

```json
{"source":"codex","session_id":"4ca7c1579dd6e8e42d6a6226","state":"working","timestamp":1794320000.0}
```

The exact fields are `source`, `session_id`, `state`, and `timestamp`. `source` is `claude`, `codex`, or `custom`. `state` is `working`, `attention`, `complete`, `idle`, or `error`. Time is Unix seconds. No input fields besides `session_id` are used; missing or invalid session identifiers are ignored.

## CLI and custom automations

For a one-off signal from a build, script, or shortcut:

```sh
"$HOME/Library/Application Support/LidGlow/lidglow-signal" emit --source custom --state working --session my-build
"$HOME/Library/Application Support/LidGlow/lidglow-signal" emit --source custom --state complete --session my-build
```

Use the same session name for the start and finish of a job. Other supported commands are:

```sh
/usr/bin/python3 lidglow-hook.py install --agent codex --native-helper /path/to/LidGlowSignal
/usr/bin/python3 lidglow-hook.py uninstall --agent codex
/usr/bin/python3 lidglow-hook.py status --agent codex
```

Replace `codex` with `claude` for Claude Code. Management commands print one JSON object containing `ok`, `installed`, and `message`. The exit code is `0` on success and `1` on management failure. Status checks do not write files and verify the helper plus the complete expected hook configuration; they cannot establish Codex's trust state. A partial installation offers Install hooks again to repair it. Omitting `--native-helper` installs the legacy Python signal commands for source compatibility and tests.

Malformed or ambiguous JSON settings, settings larger than 8 MiB, symlinks, and nonregular files are rejected without replacing settings. Backups remain in the agent settings directory and can contain other user settings. Advisory locks coordinate LidGlow installers; a last-moment update from an unrelated editor that ignores those locks can still race the final comparison and rename.

For isolated development and tests, `LIDGLOW_HOME` overrides the settings root and `LIDGLOW_DATA_DIR` overrides the application support directory. Do not set these when connecting the app for normal use.

## Validation and sources

Build the `LidGlowSignal` product, then run `LIDGLOW_SIGNAL_BINARY="$PWD/.build/release/LidGlowSignal" python3 -m unittest discover -s Tests -p 'test_hooks.py' -v` from the source folder. Tests use temporary fake homes and never change real agent settings. See [CONTRIBUTING.md](../CONTRIBUTING.md) for the complete check commands.

The schemas and lifecycle mappings were checked against [Codex hooks](https://learn.chatgpt.com/docs/hooks) and the [Claude Code hooks reference](https://code.claude.com/docs/en/hooks).
