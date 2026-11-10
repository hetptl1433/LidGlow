# Distribute LidGlow on macOS

LidGlow is a native Swift app. A DMG distributes the compiled `LidGlow.app`; it is not a substitute for building on macOS.

## Development/test DMG (ad-hoc signed)

On a Mac with Xcode Command Line Tools, Swift 5.9+ and a compatible macOS SDK:

```sh
git clone https://github.com/hetptl1433/LidGlow.git
cd LidGlow
./scripts/build.sh "$PWD/dist"
zsh scripts/package-dmg.sh "$PWD/dist/LidGlow.app"
```

Alternatively, GitHub Actions **Build LidGlow DMG** creates a downloadable artifact named `LidGlow-DMG`. Extract the ZIP artifact to get the DMG. It contains the native app and a shortcut to `/Applications` for drag-to-install. The image is checked with `hdiutil verify` and a SHA-256 checksum is printed.

**This development DMG is not Apple notarized.** Do not claim it is verified for public distribution.

## Apple-verified distribution: Developer ID and notarization

Apple's notarization service requires a **Developer ID Application** certificate, hardened runtime, secure timestamp, and an accepted notarization submission. The release workflow signs the app and bundled native signal helper, creates the DMG, submits it to Apple with `notarytool`, staples the ticket, validates it, and uploads `LidGlow-Notarized-DMG`. It runs **manually on main only**; PR builds do not receive signing secrets.

### One-time Apple account setup

1. In the [Apple Developer account](https://developer.apple.com/account/resources/certificates/list), the team's **Account Holder** must create a **Developer ID Application** certificate (not Apple Development, Apple Distribution, or Developer ID Installer). This is for direct distribution outside the Mac App Store.
2. In **Keychain Access → My Certificates**, make sure the Developer ID certificate is paired with its private key. Export that identity to a password-protected `.p12` file. Do not commit or upload the P12 or password to the repository or to chat.
3. In [App Store Connect](https://appstoreconnect.apple.com/access/integrations/api), create a **team App Store Connect API key** with adequate permissions to use the notary service. Save the downloaded `.p8` file securely (Apple normally offers it only once). Note its **Key ID** and **Issuer ID**.
4. In the GitHub repository's **Settings → Secrets and variables → Actions**, create these **repository secrets**:

| Name | Value |
| --- | --- |
| `APPSTORE_CERTIFICATES_FILE_BASE64` | Base64 of the exported Developer ID Application `.p12` |
| `APPSTORE_CERTIFICATES_PASSWORD` | Password used to export the P12 |
| `APPSTORE_API_PRIVATE_KEY` | Entire text of the App Store Connect team `.p8` key, including BEGIN/END lines |
| `APPSTORE_API_KEY_ID` | App Store Connect API key ID |
| `APPSTORE_ISSUER_ID` | App Store Connect API issuer ID |

On macOS, to copy the Base64 P12 text into your clipboard without printing it in Terminal:

```sh
base64 -i "/path/to/DeveloperID.p12" | pbcopy
```

Paste this into the GitHub secret; repeat for the other secret values via their source. **Never put these values into a workflow YAML file, a commit, a PR comment, or chat.** Only repository admins should be able to trigger trusted release builds.

### Create the notarized installer

1. Merge the DMG packaging PR into `main`. The manual workflow will then appear in **Actions**.
2. In **Actions → Notarized LidGlow release → Run workflow**, select `main` and run it. Release signing is deliberately not performed for pull requests.
3. After the run succeeds, download the `LidGlow-Notarized-DMG` artifact and extract its ZIP. The DMG is now Developer ID signed, accepted by Apple's notary service, and stapled.
4. Install and test on a **real supported Mac**. Notarization is a security scan, not proof that private CoreBrightness hardware interfaces still work.

If the workflow fails at Apple's notarization step, read the job log: the accepted or rejected result and any codesigning reason must be resolved before calling the release verified. A **Developer ID certificate/private key** and **App Store Connect API key** are prerequisites; an Apple Developer membership by itself does not automatically sign or notarize an ad-hoc build.

Apple references: [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates).

