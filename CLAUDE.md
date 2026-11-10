# LidGlow — notes for Claude

Native macOS menu bar app (SwiftUI, Swift 5.9 language mode, macOS 15+, arm64) that drives the
illuminated Apple logo on PROLED MacBook Pros via **private CoreBrightness APIs**, and shows
Claude Code / Codex task status through lifecycle hooks. No third-party dependencies. MIT.
Originally written with Codex/GPT; version 0.1.1 alpha.

## Run the checks (same as CI, `.github/workflows/ci.yml`)

`swift test` is NOT the check command — the tests are standalone executable runners.

```sh
mkdir -p .build/module-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
F=(-debug-info-format none --scratch-path .build --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox)
swift run "${F[@]}" LidGlowChecks          # core: 58 cases
swift run "${F[@]}" LidGlowAppChecks       # production AppModel, headless: 11 cases
swift build -c release --product LidGlowSignal "${F[@]}"
LIDGLOW_SIGNAL_BINARY="$PWD/.build/release/LidGlowSignal" /usr/bin/python3 -m unittest discover -s Tests -p 'test_hooks.py'   # 36 tests
./scripts/build.sh /some/out/dir           # ad-hoc signed LidGlow.app
```

- The shell is zsh: keep flags in an array (`"${F[@]}"`); a plain string variable is not word-split.
- Without `LIDGLOW_SIGNAL_BINARY`, 9 Python tests silently skip.
- Baseline (2026-11-10, Swift 6.4.2): all pass, zero compiler warnings on clean debug and release builds.

## Layout

| Target | Role |
| --- | --- |
| `LidGlowCore` | Pure logic, no UI: `HardwareControl` (hardware state machine behind a backend protocol), `HardwareRecoveryFile`, `Effects`/`Patterns`, `CoreAgentRules` (per-provider signal rules + renderer), `Activity`/`AgentActivity` (event spool reader), `DirectoryObserver` (kqueue watcher), `ProcessRunner`, `RuntimePolicy` (frame-rate decisions) |
| `LidGlowUI` | SwiftUI app: `AppModel` (central state, timers, persistence, hook management), `LogoHardware` (the real CoreBrightness bridge, `BrightnessBridge`), `ContentView` (large, ~1250 lines), `SetupGuide`, `LoginItem` |
| `LidGlow` | `@main` shim |
| `LidGlowSignal` | Tiny native CLI the agent hooks call; writes one JSON snapshot per session to the events spool |
| `LidGlowChecks` (`Tests/LidGlowCoreTests`) / `LidGlowAppChecks` | Assertion runners using fake hardware backends and in-memory settings |
| `Resources/lidglow-hook.py` | Python installer/uninstaller/status for hooks in `~/.claude/settings.json` and `~/.codex/hooks.json`; also a legacy event writer |

Data: `~/Library/Application Support/LidGlow/` (`events/`, `hardware-recovery.json`, `hardware-owner.lock`,
installed `lidglow-signal` + `lidglow-hook.py`). Settings: UserDefaults domain `local.lidglow.mac`.

## Rules that must hold

- **Never touch real agent settings or real hardware in tests.** Use `LIDGLOW_HOME` + `LIDGLOW_DATA_DIR`
  (disposable absolute dirs) and `--preview` (`LidGlow.app/Contents/MacOS/LidGlow --preview`) for UI work.
- Hook commands must always exit 0, never print, never block (0.5 s stdin deadline, 2 s hook timeout).
  A status light must never interfere with an agent.
- Privacy: snapshots hold only `source`, 24-hex SHA-256 prefix of the session id, `state`, `timestamp`.
  Never store prompts, tool input, paths, or raw session ids.
- Installer must preserve unrelated settings/handlers, back up before writing, write atomically, reject
  symlinks/hard links/malformed JSON, and stay idempotent. Ownership = `--lidglow-hook` marker + managed path.
- Hardware: save the recovery record *before* the first write; verify restoration by reading back mode/factor;
  a pending recovery record blocks automatic re-acquisition (user clicks Reset lighting). Keyboard backlight
  must be corrected after each `DisplayLogicalState` write. Changes here need manual evidence on real hardware.
- Keep idle cost near zero: no timers when nothing animates; static output does no controller polling.

## Hook mapping (verified against both vendors' docs on 2026-11-10)

Claude: UserPromptSubmit/PreToolUse/PostToolUse → working; PermissionRequest and Notification
(`permission_prompt|idle_prompt`) → attention; Stop → complete; StopFailure → error; SessionEnd → idle (`--preserve-finish`).
Codex: same, minus Notification/StopFailure, plus Interrupt → idle. Codex requires the user to trust hooks in `/hooks`.
Note: Claude's `idle_prompt` fires ~60 s after a finished turn, so a completed task turns into "Needs you".

## Known state / caveats

- Not notarized; ad-hoc signed. Private APIs can break on any macOS update.
- Untested physically: sleep/wake/lock recovery, forced-exit recovery, real end-to-end agent lifecycles.
- The Command-Shift-L toggle is a menu shortcut, so it only works while LidGlow is the active app.
- `refreshHookStatus` only runs at launch and after install/remove from the app.
