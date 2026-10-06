# Releasing Aural

For behavior contracts and regression checks, start with [future updates](FUTURE-UPDATES.md).

## Build and test

1. Update `VERSION` and increment the numeric `CFBundleVersion` in `scripts/build.sh`. Sparkle compares the build number, so it must increase for every published update.
2. Write `docs/RELEASE-<version>.md` and run `bash scripts/test.sh`.
3. Build on macOS with the macOS 26 SDK or newer. Runtime support remains macOS 14.2 and newer, with arm64 and x86_64 executables.

SwiftPM resolves Sparkle 2.10.0 using `Package.resolved` and verifies its binary checksum. The build embeds the framework and signs its helpers, XPC services, framework, and app from the inside out. Test and benchmark scripts link the same pinned framework.

## Production package

Install a Developer ID Application certificate with its private key in the build Mac's keychain. Store distribution credentials interactively with `xcrun notarytool store-credentials aural-notary`. Keep secrets out of source and shell history.

```sh
export SIGNING_IDENTITY='Developer ID Application: Nikolay Ostroukhov (V6BJ44TRY9)'
export NOTARY_PROFILE=aural-notary
bash scripts/package.sh
bash scripts/appcast.sh
bash scripts/verify-update.sh
```

`package.sh` builds once, submits the ZIP to Apple, requires Accepted status, staples and assesses the app, recreates the ZIP, creates and signs the DMG, then submits and staples the DMG. It finally writes checksums. Apple submission responses remain in `dist/notary-app.json` and `dist/notary-dmg.json`. If submission fails, inspect the submission ID using `xcrun notarytool log <id> --keychain-profile aural-notary`; never publish partial artifacts. Do not rebuild or modify an accepted app before distribution.

Without `NOTARY_PROFILE`, packaging produces a development artifact and labels its installation instructions accordingly. Public releases must pass the production packaging checks.

## Update signing and feed

Sparkle's Ed25519 private key lives in the login Keychain under account `aural`; only its public key is in `scripts/build.sh`. Preserve this key when moving build machines. `generate_keys --account aural -p` displays the public key without exporting the private key. An existing installation must trust the signing key used for its next update.

`scripts/appcast.sh` requires a stapled, signed DMG and uses Sparkle's official `generate_appcast` to sign the archive and feed and embed release notes. The app requires a signed feed and verifies archives before extraction. The feed is hosted as the `appcast.xml` asset of the latest public GitHub Release:

`https://github.com/NikoZBK/aural/releases/latest/download/appcast.xml`

Upload this asset with **every** future release, along with the versioned DMG, ZIP, and `SHA256SUMS.txt`. Do not publish a newer release lacking a feed, or the stable feed URL will break. Archive URLs in the feed use the immutable version tag. Do not replace archives after generating the feed. Feed generation currently uses full DMG updates, without deltas.

Automatic checking uses Sparkle's permission prompt; automatic downloads are off until enabled. A single updater lives for the app's lifetime, including menu-bar-only operation. Installation uses normal application termination, which stops the audio engine. On relaunch the existing startup settings determine whether EQ starts. The bundle identifier remains `local.aural.equalizer`, preserving settings and update identity.

## Verify and publish

- Run the full suite and confirm the exact release commit passes GitHub Actions.
- Verify `codesign --verify --deep --strict dist/Aural.app`, both executable architectures, `xcrun stapler validate` for app and DMG, and `spctl --assess --type execute dist/Aural.app`.
- Run `scripts/verify-update.sh` to verify the bundled public key, feed and archive signatures, version/URL/length metadata, and rejection of a tampered archive.
- Mount the final DMG, verify the bundled app matches the ZIP and inspect installation instructions. Check `SHA256SUMS.txt`.
- Exercise the Sparkle update flow from an older updater-enabled build to the candidate: check, download, signature verification, install, relaunch, and settings preservation. Test cancellation and unavailable-feed behavior. Cross-compilation is not physical Intel runtime coverage.
- Tag the verified commit. Prepare a draft GitHub Release with DMG, ZIP, checksums, and `appcast.xml`; verify remote asset digests before publishing.
- Download public assets anonymously and verify hashes. Confirm the stable feed URL and every enclosure URL work. Versions before 1.3 still use the GitHub release parser and require one manual installation.

Development artifacts must pass production checks before publication. Report local packaging, CI, publication, and end-to-end updater evidence separately.

Apple: https://developer.apple.com/developer-id/
Sparkle: https://sparkle-project.org/documentation/

## CI

GitHub Actions tests and packages credential-free development builds on pull requests, pushes to main, and manual runs. It does not hold signing credentials or publish releases. Public release assets must come from the verified production workflow above.
