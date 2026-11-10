# Distribute LidGlow as a DMG

LidGlow is a native macOS app. A DMG is a convenient way to ship the **existing** `LidGlow.app` bundle; it does not replace the Swift/macOS build step.

## Build on a Mac

Requires Xcode Command Line Tools, Swift 5.9+, and a macOS SDK that can compile the app.

```sh
git clone https://github.com/hetptl1433/LidGlow.git
cd LidGlow
./scripts/build.sh "$PWD/dist"
zsh scripts/package-dmg.sh "$PWD/dist/LidGlow.app"
```

The second script verifies the ad-hoc code signature and creates `dist/LidGlow-<version>-macOS-<architecture>.dmg`. It contains `LidGlow.app` and a shortcut to `/Applications`, so installation is drag and drop. It also verifies the image and prints its SHA-256 checksum.

## Build without a Mac

Use the **Build LidGlow DMG** GitHub Actions workflow. On a successful run, open its **Artifacts** section and download the `LidGlow-DMG` artifact. The artifact is a ZIP containing the DMG; extract the ZIP to obtain the actual installer. Artifacts are retained for 30 days.

## Distribution security

**These automated builds are ad-hoc signed, not Developer ID signed or Apple notarized.** They are suitable for testing and may be blocked by Gatekeeper when downloaded by another Mac. A public no-warning release requires a Developer ID Application signing certificate, hardened-runtime signing of the helper and app, notarization of the DMG with Apple's `notarytool`, and stapling the notarization ticket. None of those credentials are stored or requested by this repository workflow.

Hardware support remains experimental and specific to compatible illuminated-logo MacBook Pro models, as explained in the main README. A successful DMG build does not verify the lighting hardware on a GitHub runner.
