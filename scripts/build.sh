#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
BUILD_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/aural-build.XXXXXX")"
trap 'rm -rf "$BUILD_STAGE"' EXIT
APP="$BUILD_STAGE/Aural.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist

# Separate SwiftPM builds work with Command Line Tools alone (no Xcode project required).
for architecture in arm64 x86_64; do
    swift build -c release --arch "$architecture" --scratch-path ".build/$architecture" \
        -Xswiftc -debug-prefix-map -Xswiftc "$PWD=/aural" \
        -Xcc "-ffile-prefix-map=$PWD=/aural"
    binary_dir="$(swift build -c release --arch "$architecture" --scratch-path ".build/$architecture" --show-bin-path)"
    cp "$binary_dir/Aural" "$BUILD_STAGE/Aural-$architecture"
done
xcrun lipo -create "$BUILD_STAGE/Aural-arm64" "$BUILD_STAGE/Aural-x86_64" -output "$APP/Contents/MacOS/Aural"
xcrun strip -S "$APP/Contents/MacOS/Aural"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
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
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>LSApplicationCategoryType</key><string>public.app-category.music</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAudioCaptureUsageDescription</key><string>Aural processes audio playing through your selected output to apply equalization. Audio stays on your Mac and is never recorded or uploaded.</string>
</dict></plist>
PLIST
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
xcrun lipo "$APP/Contents/MacOS/Aural" -verify_arch arm64 x86_64
ditto --norsrc "$APP" dist/Aural.app
ditto -c -k --norsrc --keepParent "$APP" "dist/Aural-$VERSION-universal.zip"
printf 'Built universal Aural %s\n' "$VERSION"
