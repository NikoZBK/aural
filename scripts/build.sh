#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
BUILD_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/aural-build.XXXXXX")"
trap 'rm -rf "$BUILD_STAGE"' EXIT
APP="$BUILD_STAGE/Aural.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" dist

# Separate SwiftPM builds work with Command Line Tools alone (no Xcode project required).
for architecture in arm64 x86_64; do
    swift build -c release --arch "$architecture" --scratch-path ".build/$architecture" \
        -Xswiftc -debug-prefix-map -Xswiftc "$PWD=/aural" \
        -Xcc "-ffile-prefix-map=$PWD=/aural"
    binary_dir="$(swift build -c release --arch "$architecture" --scratch-path ".build/$architecture" --show-bin-path)"
    cp "$binary_dir/Aural" "$BUILD_STAGE/Aural-$architecture"
done
# SwiftPM does not embed dynamic frameworks into our hand-built app bundle.
SPARKLE_FRAMEWORK=".build/arm64/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto --norsrc "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
xcrun lipo -create "$BUILD_STAGE/Aural-arm64" "$BUILD_STAGE/Aural-x86_64" -output "$APP/Contents/MacOS/Aural"
xcrun strip -S "$APP/Contents/MacOS/Aural"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/AppIconSleeping.icns "$APP/Contents/Resources/AppIconSleeping.icns"
cp -R Sources/Aural/Resources/Targets "$APP/Contents/Resources/Targets"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.aural.equalizer</string>
<key>CFBundleName</key><string>Aural</string>
<key>CFBundleDisplayName</key><string>Aural</string>
<key>CFBundleExecutable</key><string>Aural</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHumanReadableCopyright</key><string>© 2026 Nikolay Ostroukhov</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>25</string>
<key>SUFeedURL</key><string>https://github.com/NikoZBK/aural/releases/latest/download/appcast.xml</string>
<key>SUPublicEDKey</key><string>bepiHGdLL56z7M4YHNiO+V4uDB9umTF631XeUeRCi8Q=</string>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
<key>SURequireSignedFeed</key><true/>
<key>SUAutomaticallyUpdate</key><false/>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>LSApplicationCategoryType</key><string>public.app-category.music</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAudioCaptureUsageDescription</key><string>Aural processes audio playing through your selected output to apply equalization. Audio stays on your Mac and is never recorded or uploaded.</string>
</dict></plist>
PLIST
# Sign nested executable code from the inside out with the app's identity.
SIGN_OPTIONS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    SIGN_OPTIONS+=(--options runtime --timestamp)
fi
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign "${SIGN_OPTIONS[@]}" --preserve-metadata=entitlements "$FRAMEWORK/XPCServices/Downloader.xpc"
for component in "$FRAMEWORK/XPCServices/Installer.xpc" "$FRAMEWORK/Autoupdate" "$FRAMEWORK/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework" "$APP"; do
    codesign "${SIGN_OPTIONS[@]}" "$component"
done
codesign --verify --deep --strict "$APP"
for architecture in arm64 x86_64; do
    xcrun lipo "$APP/Contents/MacOS/Aural" -verify_arch "$architecture"
done
# A fresh destination avoids retaining old bundle files or Finder metadata.
if [[ -d dist/Aural.app ]]; then
    mv dist/Aural.app "$BUILD_STAGE/Previous-Aural.app"
fi
ditto --norsrc "$APP" dist/Aural.app
# Archive the verified temporary bundle; sync services can add Finder metadata to dist.
ditto -c -k --norsrc --keepParent "$APP" "dist/Aural-$VERSION-universal.zip"
printf 'Built universal Aural %s\n' "$VERSION"
