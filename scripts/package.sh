#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
bash scripts/build.sh
PACKAGE_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/aural-package.XXXXXX")"
trap 'rm -rf "$PACKAGE_STAGE"' EXIT
# Unpack the clean signed ZIP so file-provider/Finder metadata cannot enter the image.
ditto -x -k "dist/Aural-$VERSION-universal.zip" "$PACKAGE_STAGE"
ln -s /Applications "$PACKAGE_STAGE/Applications"
cp docs/INSTALL.txt "$PACKAGE_STAGE/Read Me.txt"
cp LICENSE "$PACKAGE_STAGE/License.txt"
hdiutil create -volname "Aural $VERSION" -srcfolder "$PACKAGE_STAGE" -ov -format UDZO "dist/Aural-$VERSION-universal.dmg"
hdiutil verify "dist/Aural-$VERSION-universal.dmg"
(cd dist && shasum -a 256 "Aural-$VERSION-universal.dmg" "Aural-$VERSION-universal.zip" > SHA256SUMS.txt)
printf 'Packaged %s\n' "dist/Aural-$VERSION-universal.dmg"
