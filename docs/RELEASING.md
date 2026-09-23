# Releasing Aural

## Local release

1. Update `VERSION` and the numeric `CFBundleVersion` in `scripts/build.sh`.
2. Run `bash scripts/test.sh`.
3. Run `bash scripts/package.sh` on macOS with Xcode or Command Line Tools.
4. Check `lipo -archs dist/Aural.app/Contents/MacOS/Aural` for both arm64 and x86_64.
5. Open the DMG, verify the app and Applications shortcut, then test the app on supported hardware.
6. Publish the DMG, ZIP, and `SHA256SUMS.txt` as GitHub Release assets. Never upload `.build`, local settings, imported profiles, signing credentials, or private screenshots.

The scripts build in clean staging directories and explicitly copy only the executable, icon, and Info.plist. Packaging adds installation instructions, the license, and an Applications shortcut. Settings and profiles are created in each user's Application Support directory at runtime.

## Signing status

The current release uses an ad-hoc code signature. This is not a Developer ID signature and does not pass Gatekeeper's notarization policy. The download and installation instructions must state this. Do not advertise the release as notarized or recommend globally disabling Gatekeeper.

For a future notarized release, install a Developer ID Application certificate and its private key into the build Mac's keychain, then set `SIGNING_IDENTITY` to that identity before building. The build script will enable the hardened runtime and timestamp the signature. Signing credentials must never be committed.

Before notarizing a future release, remove the not-notarized message from About and update release documentation. Rebuild once, then submit the ZIP using `xcrun notarytool submit` with an explicitly configured keychain profile and `--wait`. Staple the accepted app using `xcrun stapler staple`, repackage the stapled app into the DMG and ZIP, and regenerate checksums. Do not rebuild or edit the app after notarization. Verify the final app using `codesign --verify --strict`, `xcrun stapler validate`, and `spctl --assess --type execute`.

Apple's official guidance: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution

## Automation

GitHub Actions tests the source and compiles/packages a universal app on pull requests, pushes to main, and manual runs. Artifacts are retained for seven days. Creating a public GitHub Release remains a deliberate maintainer action; CI does not publish releases or access signing credentials.
