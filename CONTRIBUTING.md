# Contributing to LidGlow

LidGlow is a native macOS utility. Changes should keep background CPU use low, preserve the user's existing agent settings, and release logo control cleanly. The physical logo is a single white light; RGB controls and pixel imagery are outside its capabilities.

## Build and check

Use macOS with the Xcode Command Line Tools, a macOS 15+ SDK, and Python 3. No third-party package installation is needed.

```sh
mkdir -p .build/module-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift run -debug-info-format none --scratch-path .build --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox LidGlowChecks
swift run -debug-info-format none --scratch-path .build --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox LidGlowAppChecks
swift build -c release --product LidGlowSignal -debug-info-format none --scratch-path .build --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
LIDGLOW_SIGNAL_BINARY="$PWD/.build/release/LidGlowSignal" /usr/bin/python3 -m unittest discover -s Tests -p 'test_hooks.py' -v
./scripts/build.sh "$PWD/dist"
```

`LidGlowChecks` is a standalone assertion runner, so `swift test` is not the project check command. Hook tests create temporary fake homes; they do not install hooks in your real agent settings. Supplying `LIDGLOW_SIGNAL_BINARY` enables the native writer's parity and failure tests. CI runs these checks and builds the app without enabling hardware control.

For UI work, launch `dist/LidGlow.app/Contents/MacOS/LidGlow --preview`. To inspect simulated activity, set `LIDGLOW_DATA_DIR` and `LIDGLOW_HOME` to disposable absolute directories. Keep these overrides out of normal integration setup.

## Review expectations

- Explain the behavior changed and the checks that cover it. Add tests for meaningful failure cases, rather than assertions that repeat implementation details.
- Changes to the hardware bridge need manual evidence on compatible hardware: model family, macOS version, observed output, keyboard behavior, sleep/wake behavior, and successful restoration. Do not include serial numbers or hardware UUIDs.
- For background behavior, measure steady and animated modes with the window hidden as well as visible. Report sampling duration, CPU, memory, wakeups if available, and whether hardware control was enabled. Do not turn a brief sample into a battery-life claim.
- Keep snapshots limited to source, hashed session identity, status, and time. Do not log prompts, code, tool arguments, transcripts, credentials, or project paths.
- Preserve unrelated agent settings and handlers. Install and uninstall must remain idempotent, reject malformed settings, and use isolated tests.
- Keep generated apps, `.build`, personal settings, event snapshots, and profiler output out of commits. Retain the third-party notices when distributing binaries or adapted source.

Use a focused pull request. A hardware limitation or an unavailable test should be stated plainly. Contributions are licensed under the project's MIT license.
