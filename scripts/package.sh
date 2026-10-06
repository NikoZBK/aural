#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
# Credential-free CI remains available. Production packages use Apple distribution checks.
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
if [[ -n "$NOTARY_PROFILE" && "${SIGNING_IDENTITY:--}" == "-" ]]; then
    echo "Production packaging requires SIGNING_IDENTITY to be a Developer ID Application identity." >&2
    exit 1
fi
bash scripts/build.sh
PACKAGE_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/aural-package.XXXXXX")"
trap 'rm -rf "$PACKAGE_STAGE"' EXIT
IMAGE_STAGE="$PACKAGE_STAGE/image"
mkdir -p "$IMAGE_STAGE"
ZIP="dist/Aural-$VERSION-universal.zip"
DMG="dist/Aural-$VERSION-universal.dmg"
ditto -x -k "$ZIP" "$IMAGE_STAGE"
APP="$IMAGE_STAGE/Aural.app"
if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "dist/notary-app.json"
    python3 - "dist/notary-app.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
print(json.dumps(result, indent=2))
if result.get('status') != 'Accepted':
    sys.exit('Apple did not accept the app; no release package will be produced.')
PY
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
    ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
fi
codesign --verify --deep --strict "$APP"
ln -s /Applications "$IMAGE_STAGE/Applications"
cp docs/INSTALL.txt "$IMAGE_STAGE/Read Me.txt"
if [[ -z "$NOTARY_PROFILE" ]]; then
    printf '\nDEVELOPMENT PACKAGE: This build is intended for local testing.\n' >> "$IMAGE_STAGE/Read Me.txt"
fi
cp LICENSE "$IMAGE_STAGE/License.txt"
hdiutil create -volname "Aural $VERSION" -srcfolder "$IMAGE_STAGE" -ov -format UDZO "$DMG"
if [[ -n "$NOTARY_PROFILE" ]]; then
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "dist/notary-dmg.json"
    python3 - "dist/notary-dmg.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
print(json.dumps(result, indent=2))
if result.get('status') != 'Accepted':
    sys.exit('Apple did not accept the DMG; do not publish these artifacts.')
PY
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
fi
hdiutil verify "$DMG"
# Retain the exact stapled app represented by the final archives.
if [[ -d dist/Aural.app ]]; then mv dist/Aural.app "$PACKAGE_STAGE/previous.app"; fi
ditto --norsrc "$APP" dist/Aural.app
(cd dist && shasum -a 256 "Aural-$VERSION-universal.dmg" "Aural-$VERSION-universal.zip" > SHA256SUMS.txt)
printf 'Packaged %s\n' "$DMG"
