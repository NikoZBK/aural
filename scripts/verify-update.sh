#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/sparkle.sh
VERSION="$(cat VERSION)"
VERIFY_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/aural-update-check.XXXXXX")"
trap 'rm -rf "$VERIFY_STAGE"' EXIT
KEY="$("$SPARKLE_ROOT/bin/generate_keys" --account aural -p)"
BUNDLED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' dist/Aural.app/Contents/Info.plist)"
[[ "$KEY" == "$BUNDLED_KEY" ]] || { echo "Update signing key differs from bundled public key." >&2; exit 1; }
"$SPARKLE_ROOT/bin/sign_update" --account aural --verify dist/appcast.xml
SIGNATURE="$(python3 - "$VERSION" <<'PY'
import pathlib, plistlib, sys, xml.etree.ElementTree as ET
version = sys.argv[1]
info = plistlib.loads(pathlib.Path('dist/Aural.app/Contents/Info.plist').read_bytes())
item = ET.parse('dist/appcast.xml').find('./channel/item')
assert item is not None, 'Missing update item'
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
assert item.findtext(ns + 'version') == info['CFBundleVersion'], 'Wrong update build'
assert item.findtext(ns + 'shortVersionString') == version, 'Wrong update version'
archive = pathlib.Path(f'dist/Aural-{version}-universal.dmg')
enclosure = item.find('enclosure')
assert enclosure is not None, 'Missing update download'
assert enclosure.attrib['url'] == f'https://github.com/NikoZBK/aural/releases/download/v{version}/{archive.name}', 'Wrong update URL'
assert int(enclosure.attrib['length']) == archive.stat().st_size, 'Wrong archive size'
print(enclosure.attrib[ns + 'edSignature'])
PY
)"
"$SPARKLE_ROOT/bin/sign_update" --account aural --verify "dist/Aural-$VERSION-universal.dmg" "$SIGNATURE"
cp "dist/Aural-$VERSION-universal.dmg" "$VERIFY_STAGE/tampered.dmg"
printf 'tampered' >> "$VERIFY_STAGE/tampered.dmg"
if "$SPARKLE_ROOT/bin/sign_update" --account aural --verify "$VERIFY_STAGE/tampered.dmg" "$SIGNATURE" > "$VERIFY_STAGE/rejection.log" 2>&1; then
    echo "ERROR: Modified archive passed signature verification." >&2
    exit 1
fi
printf 'PASS signed feed, bundled key, build/version, download URL, archive length, valid signature, and tampered-archive rejection.\n'
