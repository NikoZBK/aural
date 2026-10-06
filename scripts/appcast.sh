#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/sparkle.sh
VERSION="$(cat VERSION)"
APPCAST_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/aural-appcast.XXXXXX")"
trap 'rm -rf "$APPCAST_STAGE"' EXIT
# Only release archives that pass distribution checks may enter the public update feed.
xcrun stapler validate "dist/Aural-$VERSION-universal.dmg"
codesign --verify --strict "dist/Aural-$VERSION-universal.dmg"
cp "dist/Aural-$VERSION-universal.dmg" "$APPCAST_STAGE/"
cp "docs/RELEASE-$VERSION.md" "$APPCAST_STAGE/Aural-$VERSION-universal.md"
"$SPARKLE_ROOT/bin/generate_appcast" --account aural --maximum-deltas 0 \
    --download-url-prefix "https://github.com/NikoZBK/aural/releases/download/v$VERSION/" \
    --embed-release-notes --link "https://github.com/NikoZBK/aural/releases/tag/v$VERSION" \
    -o "$APPCAST_STAGE/appcast.xml" "$APPCAST_STAGE"
"$SPARKLE_ROOT/bin/sign_update" --account aural --verify "$APPCAST_STAGE/appcast.xml"
cp "$APPCAST_STAGE/appcast.xml" dist/appcast.xml
printf 'Publish dist/appcast.xml alongside the verified v%s release assets.\n' "$VERSION"
