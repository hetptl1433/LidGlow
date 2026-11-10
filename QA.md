# Validation record

This is an experimental alpha, validated on 10 November 2026 with an Apple M5 Pro MacBook Pro, 48 GB RAM, macOS 27.2, Swift 6.4.2, and Xcode Command Line Tools. No serial number, hardware UUID, real agent payload, or personal configuration is included in this record.

## Automated checks

| Suite | Result | Scope |
| --- | --- | --- |
| Core runner | 57 cases, 52,846 assertions, zero failures | Effects, scheduling, event ingestion, hardware state machine, ownership/recovery, filesystem notifications, subprocess bounds, concurrent signal rules |
| Production app model | 9 cases, 77 assertions, zero failures | Saved-settings startup, repeated assignments, bounded Unicode input, corrupt preferences, focus lifecycle, power intent, persistence, concurrent signals, URLs, shutdown |
| Python management and native writer | 36 cases, zero failures | Isolated hook installation/removal/status, native/Python parity, lifecycle mapping, input/file/lock failure cases |

The exact commands are in [README.md](README.md#check-the-source). No check uses physical hardware or real agent configuration. The app-model runner imports the production UI module with hardware and runtime services disabled; it does not duplicate the model implementation.

Meaningful failure cases include:

- Loading the saved `HELLO` Morse value and repeatedly assigning equal text and rule values. This reproduces the startup stack overflow caused by unconditional self-assignment in `@Published` observers. Normalization now assigns only when the value changes.
- Oversized combining-character graphemes, nonfinite numbers, malformed preferences, invalid custom patterns, randomized effect samples, and bounded pattern duration.
- Multiple sessions per provider, duplicate snapshots, stale and expired sessions, provider priorities, alternating tasks, count flashes, alert precedence, and completion while another task continues working. Completion durations are provider-specific; persistent completion ends on later activity from that provider.
- Stop followed immediately by SessionEnd, including execution of the generated native hook commands. SessionEnd preserves a recent completion/error timestamp instead of erasing the finish signal.
- Repeated install/remove, unrelated settings/handlers, malformed and oversized settings, exponent-overflow JSON numbers, partial installation repair, concurrent installer changes, backups, missing helpers, symlinks, nonregular files, and restrictive permissions. Unsupported numeric values are rejected without rewriting the existing settings; output serialization also rejects nonfinite numbers.
- Bounded stdin and lock waits, output flooding, helper timeout/cancellation, termination escalation, and a descendant keeping a pipe open. Shutdown waits briefly for cancelled helper work.
- Actual kernel filesystem notifications, burst coalescing, event-directory replacement, and cancellation of queued callbacks.
- Fake-daemon rejected or ignored commands, lost readback, stalled fades, rapid reversal, keyboard correction failure, sleep during a fade, 50 sleep/wake cycles, wake readiness/release races, crash recovery, ownership contention, and restoration verification. A stable target makes zero backend calls over 10,000 repeated requests/advances.

## Native interface checks

The app was exercised using an isolated app-data directory and fake Claude/Codex settings homes. The production native event writer was used for synthetic activity; no prompts, private code, or real agent settings were used.

Completed checks include opening the interface after the startup fix; the first-run welcome; settings and mode selection; custom-pattern validation; visible preview changes from native events; and independent session display. Both provider setup guides were opened, installed into the fake home, and removed successfully. The Codex guide explicitly asks the user to review and trust hooks and does not claim that installation grants trust.

The final pass on provider/count captions, completion timing, hidden-window resource samples, and final On/Off restoration is pending while the test Mac is locked. Earlier CPU readings were taken with changing window/control state and are excluded from the controlled performance results below.

## Physical hardware evidence

Read-only checks identified the dedicated `bklb-backlight` service. On this host, the registered service name works with `IOServiceNameMatching`; the `@0` location suffix does not.

An earlier live run changed a steady target from 70% to 25%. Raw PWM ratios changed from approximately 11.50% to 4.33%. On normal Quit, output returned to approximately 16.14%, near the approximately 15.52% baseline. These ratios are measurements of the daemon's current automatic output, not calibrated luminance or a linear mapping of the app's slider. Verified automatic-factor restoration also cleared the recovery record.

The hardware wrapper verifies mode/factor before reporting restoration. A successful private-API return alone is not accepted as proof. A pending recovery record blocks automatic reacquisition after a crash and offers an explicit reset. These measures are covered extensively by fake-daemon checks, but cannot make private APIs crash-proof.

## Performance evidence

The native signal helper was measured with the included [microbenchmark](scripts/benchmark-signal.py): ten warm-up launches, then 100 coalesced Working invocations and 100 alternating Working/Complete invocations, using a synthetic approximately 4 KiB payload and isolated temporary storage.

| Native helper workload | Median elapsed | 95th percentile | CPU per invocation | Peak child RSS |
| --- | --- | --- | --- | --- |
| Coalesced Working | 5.686 ms | 6.239 ms | 3.891 ms | 7.953 MiB |
| Changing state | 8.662 ms | 9.642 ms | 5.579 ms | 7.984 MiB |

These are short-lived helper measurements. Peak RSS is the OS child-process high-water mark; it is not the always-running app's memory. Filesystem notifications replace polling for new events; unchanged Working writes coalesce for 30 seconds. Physical transitions poll only until settled or failed; static output stops controller polling. Necessary animation runs at 20 Hz, or 12 Hz in Low Power Mode.

App CPU/RAM, daemon overhead, energy impact, and battery endurance are distinct measurements. A brief CPU or memory sample cannot establish battery-life impact. The LED itself uses power, and animated physical effects require more work than static output.

## Limits before a stable release

- Physical keyboard preservation, real sleep/wake/lock recovery, forced-exit recovery, and competing third-party controllers still need a controlled manual test matrix on more hardware and OS versions. Their deterministic fake-daemon coverage is not a substitute for those physical checks.
- No long-duration idle/memory soak or controlled unplugged battery endurance test has been completed. There is no claim of zero battery impact or exhaustive testing of every scenario.
- Hook schema/install tests use official documented definitions and synthetic local invocations. Real end-to-end task lifecycles in both installed agent applications still need a supervised check after the user reviews/trusts their hooks. Remote/cloud activity cannot automatically reach the local light.
- The logo is a single white light. Relative output depends on macOS, ambient light, and display state; very short custom steps can lag the preview.
- The app requires macOS 15 or later; physical control requires compatible PROLED hardware. Private CoreBrightness behavior can change with an OS update.
- The supplied developer app is ad-hoc signed and is not notarized. No Developer ID or App Store distribution claim is made.
