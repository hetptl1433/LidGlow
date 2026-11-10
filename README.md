# LidGlow

A native macOS menu bar app that turns the illuminated Apple logo into a customizable light and a status signal for Claude Code and Codex. MIT licensed.

**Experimental alpha.** Logo control uses private CoreBrightness interfaces on MacBook Pro with PROLED XDR Display. macOS updates can change those interfaces. LidGlow starts On by default; switch it Off to return control to macOS.

## What it does

- Steady, breathing, pulse, and heartbeat effects with adjustable brightness, speed, and resting glow.
- Customize Claude Code and Codex independently: Working, Finished, Needs you, Error, and Idle can each use an effect, Off, or a custom pattern. Choose how long Finished stays visible, including until the next activity.
- For concurrent tasks, prefer Claude, Codex, or recent activity; alternate between tasks; or blink the number of working tasks. Attention can take priority. One finished task cannot hide another working task.
- A focus countdown with pause/resume and a finish signal.
- A battery indicator, with a gentle charging rhythm.
- Repeating Morse messages and custom patterns such as `100:0.3, 0:0.2, 50:1`.
- Low Power Mode dimming, local automation commands, and URL actions for Shortcuts.

The logo is one fixed white light. Software cannot add RGB colors or pixel imagery. Brightness is relative to macOS's automatic ambient/display-dependent output, and physical fades can lag the preview. [Hardware sources](SOURCES.md)

## Build and open

Use macOS with Xcode Command Line Tools and Swift 5.9 or newer. There are no third-party package dependencies.

```sh
git clone https://github.com/hetptl1433/LidGlow.git
cd LidGlow
./scripts/build.sh "$PWD/dist"
open dist/LidGlow.app
```

The build script creates an ad-hoc signed development app, including its native signal helper and license notices. It does not notarize a public release. Use a toolchain with the macOS 15+ SDK; actual hardware access requires a compatible PROLED Mac and supported private interfaces. See [QA.md](QA.md) for the specific tested environment and remaining checks.

The top **LidGlow** switch is the main control: **On** plays your chosen effect; **Off** returns to Mac automatic lighting. It starts On without a setup sheet. Breathing starts at **1.5×** speed, and the Everyday preset uses the same speed. An old default breathing speed of 1× migrates once to 1.5×; customized speeds are retained. Close the window to keep the menu bar app running; click its icon to reopen it. Normal Quit restores Mac lighting and verifies the result with a bounded grace period. Command-Shift-L toggles LidGlow.

Version 0.1.1 adopts the simpler switch with an initial On setting. Later explicit Off choices are remembered. A pending recovery record blocks automatic acquisition and offers **Reset lighting** instead. Preview mode never controls hardware.

**Start at login** is enabled on the first normal launch using Apple's Service Management API. Turn it off in the footer or macOS Login Items. macOS can require approval; the app shows that requirement and a link to Login Items. Subsequent launches respect system-level opt-outs. No login item is registered by preview mode or automated tests. **About LidGlow**, available in the sidebar footer and app menu, credits **Het Patel**.

## Connect your agents

Choose **Agent signal → Set up** for Claude Code or Codex. A small three-step guide explains installation, provider setup, and testing. **Add integration** preserves unrelated settings, saves a private backup, and installs commands that call a small native executable. **Remove integration** removes only LidGlow's handlers.

- **Codex:** open **Settings → Hooks** or `/hooks`, then review and trust the definitions. Installation does not grant trust automatically.
- **Claude Code:** restart it or review `/hooks` to load the changes. Ordinary Claude desktop/browser chats do not emit Claude Code hooks.
- Local hooks must run on this Mac. Remote/cloud tasks do not automatically signal the local light.

Python 3 from Xcode Command Line Tools is used only for setup/status management. The app checks that a developer installation exists before invoking its Python shim, avoiding an unsolicited installation prompt on a fresh Mac. The native event writer and lighting run independently of Python.

Only source, a hashed session ID, state, and timestamp are stored locally. Prompts, code, tool arguments, paths, transcripts, and raw session IDs are not retained. No API key, server, telemetry, or network connection is required. After 30 minutes without an event, an active session becomes **No recent signal**; it is not reported as finished. Snapshots expire after 24 hours. [Full hook documentation](Resources/HOOKS.md)

## Customize and automate

Morse supports letters, digits, and common punctuation; playback uses the first 160 characters. A custom pattern accepts up to 64 comma-separated `percent:seconds` steps. Percent is 0–100, each duration 0.05–20 seconds, and total duration at most 180 seconds. Invalid patterns emit no light. Speed scales playback; very short steps are approximate on real hardware.

**Copy automation command** copies a direct invocation of the bundled native helper. Use the same session name for a job's start and finish; select Agent signal to display it. Copy the command again after moving the app.

```sh
"/path/to/LidGlow.app/Contents/MacOS/LidGlowSignal" emit --source custom --state working --session my-build
"/path/to/LidGlow.app/Contents/MacOS/LidGlowSignal" emit --source custom --state complete --session my-build
```

Mode and focus URL actions adjust the app's current selection. The explicit On/Off actions also apply that lighting choice:

```text
lidglow://mode?name=breathe&brightness=0.6
lidglow://mode?name=agents
lidglow://focus?minutes=25
lidglow://off
lidglow://on
```

Mode names: `steady`, `breathe`, `pulse`, `heartbeat`, `agents`, `focus`, `battery`, `morse`, `custom`.

## Designed for background use

- Hidden, disconnected previews stop scheduling frames. Steady, static agent rules, disabled, and suspended states also need no animation timer. An animated Idle rule runs only when a preview or physical output needs it.
- A settled hardware level performs zero controller polling until the target or lifecycle state changes. Only transitions, bounded wake retries, and release verification poll the daemon.
- Filesystem notifications replace repeated event-directory scans. Bursts are coalesced, and directory replacement is rearmed promptly.
- Only the small preview observes frame changes; cached compositor layers avoid rebuilding the settings window each frame. Necessary animation runs at 20 Hz, or 12 Hz in Low Power Mode.
- Hidden focus sessions use a single deadline timer unless physical focus output needs progress updates. Battery sampling runs only when relevant. Settings saves are debounced.
- The native event writer coalesces unchanged working states for 30 seconds, while meaningful state changes are immediate. Normal storage is capped at 256 snapshots; UI history and sessions are bounded.

Measurements and their limits are recorded in [QA.md](QA.md). CPU/RAM samples do not establish battery endurance. Animated lighting still requires work, and the LED itself uses power.

## Restoration and failures

LidGlow saves the previous logo mode before the first mutation, restores normal fading on release/sleep, verifies the fade factor when awake, and reports failures. A nonblocking ownership lock prevents two LidGlow instances from controlling simultaneously. Do not run competing third-party logo controllers at the same time.

A crash or Force Quit cannot restore hardware synchronously. A small private recovery record remains; **Reset lighting** attempts restoration, and a pending record prevents automatic acquisition on launch. There is no privileged daemon, administrator shell command, clamshell override, or change to screen brightness settings. Keyboard preservation and sleep/wake behavior have deterministic fake-daemon coverage; physical validation limits are listed in QA.

## Check the source

```sh
mkdir -p .build/module-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift run -debug-info-format none --scratch-path .build --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox LidGlowChecks
swift run -debug-info-format none --scratch-path .build --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox LidGlowAppChecks
swift build -c release --product LidGlowSignal -debug-info-format none --scratch-path .build --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
LIDGLOW_SIGNAL_BINARY="$PWD/.build/release/LidGlowSignal" /usr/bin/python3 -m unittest discover -s Tests -p 'test_hooks.py' -v
```

The check runners work without XCTest or full Xcode. `LidGlowAppChecks` runs the actual production model with in-memory preferences, disabled hardware, and no runtime services; run it in the default debug configuration. Tests cover synthetic events, fake hardware, real filesystem notifications, saved-settings startup, and temporary fake homes. CI never enables physical hardware. Use `--preview` for hardware-disabled app inspection; `LIDGLOW_DATA_DIR` and `LIDGLOW_HOME` isolate development data.

To reproduce the native helper microbenchmark, run `/usr/bin/python3 scripts/benchmark-signal.py .build/release/LidGlowSignal`. This measures only the short-lived helper; it does not measure app memory or battery endurance.

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Portions of the hardware bridge derive from MIT-licensed LogoLight; its notices are retained.
