#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ICON_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/aural-icon.XXXXXX")"
trap 'rm -rf "$ICON_STAGE"' EXIT
mkdir -p "$ICON_STAGE/AppIcon.iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon.png --out "$ICON_STAGE/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" Resources/AppIcon.png --out "$ICON_STAGE/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_STAGE/AppIcon.iconset" -o Resources/AppIcon.icns
