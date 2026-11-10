# Validation record

This is an experimental alpha, validated on 10 November 2026 with an Apple M5 Pro MacBook Pro, 48 GB RAM, macOS 27.2, Swift 6.4.2, and Xcode Command Line Tools. No serial number, hardware UUID, real agent payload, or personal configuration is included in this record.

## Automated checks

| Suite | Result | Scope |
| --- | --- | --- |
| Core runner | 58 cases, 52,855 assertions, zero failures | Effects, scheduling, event ingestion, hardware state machine, ownership/recovery, filesystem notifications, subprocess bounds, concurrent signal rules |
| Production app model | 11 cases, 92 assertions, zero failures | Saved-settings startup, repeated assignments, bounded Unicode input, corrupt preferences, focus lifecycle, power intent, persistence, concurrent signals, URLs, shutdown, simplified switch/default migration, login registration/opt-out/approval/errors |
| Python management and native writer | 36 cases, zero failures | Isolated hook installation/removal/status, native/Python parity, lifecycle mapping, input/file/lock failure cases |

The exact commands are in [README.md](README.md#check-the-source). No check uses physical hardware or real agent configuration. The app-model runner imports the production UI module with hardware and runtime services disabled; it does not duplicate the model implementation.

[GitHub CI passed](https://github.com/hetptl1433/LidGlow/actions/runs/42874533127) for source commit `629a71eb1ed7544c8ab539d2d6cd9e3bca792ac9` on a clean hosted macOS 26.7.2 ARM64 runner with Swift 6.3.3 and Python 3.9.6. All 103 cases, native app packaging, property-list/signature verification, and the unchanged-source check succeeded. The first run exposed a cold Python launch exceeding a functional test's two-second budget; functional fixtures now use the production ten-second budget while dedicated short timeout/termination checks retain their explicit limits.

Meaningful failure cases include:

- Loading the saved `HELLO` Morse value and repeatedly assigning equal text and rule values. This reproduces the startup stack overflow caused by unconditional self-assignment in `@Published` observers. Normalization now assigns only when the value changes.
- Oversized combining-character graphemes, nonfinite numbers, malformed preferences, invalid custom patterns, randomized effect samples, and bounded pattern duration.
- Multiple sessions per provider, duplicate snapshots, stale and expired sessions, provider priorities, alternating tasks, count flashes, alert precedence, and completion while another task continues working. Completion durations are provider-specific; persistent completion ends on later activity from that provider.
- Stop followed immediately by SessionEnd, including execution of the generated native hook commands. SessionEnd preserves a recent completion/error timestamp instead of erasing the finish signal.
- Repeated install/remove, unrelated settings/handlers, malformed and oversized settings, exponent-overflow JSON numbers, partial installation repair, concurrent installer changes, backups, missing helpers, symlinks, nonregular files, and restrictive permissions. Unsupported numeric values are rejected without rewriting the existing settings; output serialization also rejects nonfinite numbers.
- Bounded stdin and lock waits, output flooding, helper timeout/cancellation, termination escalation, and a descendant keeping a pipe open. Shutdown waits briefly for cancelled helper work. A child-environment regression reproduces loss of a late-set parent variable with Foundation's nil environment; an explicit current-parent snapshot fixes it, and explicit override/empty environments retain their intended semantics.
- Actual kernel filesystem notifications, burst coalescing, event-directory replacement, and cancellation of queued callbacks.
- Fake-daemon rejected or ignored commands, lost readback, stalled fades, rapid reversal, keyboard correction failure, sleep during a fade, 50 sleep/wake cycles, wake readiness/release races, crash recovery, ownership contention, and restoration verification. A stable target makes zero backend calls over 10,000 repeated requests/advances.

## Native interface checks

Version 0.1.1 adds a 1.5× initial breathing speed, one LidGlow switch (Off returns to Mac automatic), initial On behavior, an About window crediting Het Patel, and default Start at login. New headless checks cover the default migration, retained custom speeds and later Off choices, one-time login registration, external opt-out, pending approval, and registration failure using a fake service. Actual reboot/login execution has not been tested; macOS approval remains authoritative.

The app was exercised using an isolated app-data directory and fake Claude/Codex settings homes. The production native event writer was used for synthetic activity; no prompts, private code, or real agent settings were used.

Completed checks include opening the interface after the startup fix; the first-run welcome; settings and mode selection; custom-pattern validation; visible preview changes from native events; and independent session display. Both provider setup guides were opened and their add/remove flows exercised. The Codex guide explicitly asks the user to review and trust hooks and does not claim that installation grants trust.

A file-level check found that the child helper had not inherited the QA environment. The test-added hooks were removed and their absence verified. After fixing current-parent environment propagation, both guides were retested: Add created eight Claude handlers or seven Codex handlers only in the temporary fake home; Remove cleared them. The real settings had zero LidGlow handlers throughout the corrected pass. The new regression failed on the earlier implementation and passed after the fix.

The final live pass confirmed both providers' priority selection, captions alternating between Claude and Codex, and a two-task/two-blink count caption. Claude completing did not hide Codex's ongoing work. With Codex idle, the configured Steady finish remained visible beyond eight seconds and expired after approximately thirty seconds. Replacing the event directory and immediately writing attention produced a Needs you caption promptly. Normal Quit was confirmed with no LidGlow process remaining, after returning control to Mac automatic lighting.

A fresh QA app identity blocked while opening a test directory under Documents. A process sample identified the exact directory-open call; moving test data and fake settings homes to canonical `/private/tmp` made the process responsive. This is consistent with protected-folder access during startup, rather than a hardware-controller wait. Normal production data remains in Application Support. Developer data overrides should use an unprotected local directory.

## Physical hardware evidence

Read-only checks identified the dedicated `bklb-backlight` service. On this host, the registered service name works with `IOServiceNameMatching`; the `@0` location suffix does not.

An earlier live run changed a steady target from 70% to 25%. Raw PWM ratios changed from approximately 11.50% to 4.33%. On normal Quit, output returned to approximately 16.14%, near the approximately 15.52% baseline. These ratios are measurements of the daemon's current automatic output, not calibrated luminance or a linear mapping of the app's slider. Verified automatic-factor restoration also cleared the recovery record.

On the final live pass, Steady at 60% showed hardware enabled with a raw PWM ratio of `87/(87+820)`, approximately 9.59%. Turning Off showed hardware disabled. Returning to Mac automatic showed hardware enabled at `153/(153+807)`, approximately 15.94%, and the recovery record was absent. This validates the control/readback and restoration paths; physical logo appearance was not independently observed.

The hardware wrapper verifies mode/factor before reporting restoration. A successful private-API return alone is not accepted as proof. A pending recovery record blocks automatic reacquisition after a crash and offers an explicit reset. These measures are covered extensively by fake-daemon checks, but cannot make private APIs crash-proof.

## Performance evidence

In the final approximately twenty-second static Steady preview sample, with Mac automatic lighting selected and Activity Monitor foreground, app CPU time increased from 2.31 to 2.34 seconds: approximately 0.15% of one core. The final snapshot showed 0.0% CPU, four threads, one idle wakeup/second, and 67.1 MB memory. Window closure could not be confirmed, so this is a static preview sample with unconfirmed visibility, not a hidden-window or physical-animation benchmark. Earlier readings with changing mode/control state are excluded.

The native signal helper was measured with the included [microbenchmark](scripts/benchmark-signal.py): ten warm-up launches, then 100 coalesced Working invocations and 100 alternating Working/Complete invocations, using a synthetic approximately 4 KiB payload and isolated temporary storage.

| Native helper workload | Median elapsed | 95th percentile | CPU per invocation | Peak child RSS |
| --- | --- | --- | --- | --- |
| Coalesced Working | 5.686 ms | 6.239 ms | 3.891 ms | 7.953 MiB |
| Changing state | 8.662 ms | 9.642 ms | 5.579 ms | 7.984 MiB |

These are short-lived helper measurements. Peak RSS is the OS child-process high-water mark; it is not the always-running app's memory. Filesystem notifications replace polling for new events; unchanged Working writes coalesce for 30 seconds. Physical transitions poll only until settled or failed; static output stops controller polling. Necessary animation runs at 20 Hz, or 12 Hz in Low Power Mode.

App CPU/RAM, daemon overhead, energy impact, and battery endurance are distinct measurements. A brief CPU or memory sample cannot establish battery-life impact. The LED itself uses power, and animated physical effects require more work than static output.

## Limits before a stable release

- Physical keyboard preservation, real sleep/wake/lock recovery, forced-exit recovery, and competing third-party controllers still need a controlled manual test matrix on more hardware and OS versions. Their deterministic fake-daemon coverage is not a substitute for those physical checks.
- Controlled hidden-window physical Steady/Breathe samples and daemon-overhead measurements remain incomplete. No long-duration idle/memory soak or controlled unplugged battery endurance test has been completed. There is no claim of zero battery impact or exhaustive testing of every scenario.
- Hook schema/install tests use official documented definitions and synthetic local invocations. Real end-to-end task lifecycles in both installed agent applications still need a supervised check after the user reviews/trusts their hooks. Remote/cloud activity cannot automatically reach the local light.
- The logo is a single white light. Relative output depends on macOS, ambient light, and display state; very short custom steps can lag the preview.
- The app requires macOS 15 or later; physical control requires compatible PROLED hardware. Private CoreBrightness behavior can change with an OS update.
- The supplied developer app is ad-hoc signed and is not notarized. No Developer ID or App Store distribution claim is made.
