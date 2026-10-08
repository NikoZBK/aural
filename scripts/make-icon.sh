#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ICON_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/aural-icon.XXXXXX")"
trap 'rm -rf "$ICON_STAGE"' EXIT
if [[ $# -eq 0 ]]; then set -- AppIcon AppIconActive; fi
for icon in "$@"; do
    case "$icon" in
        AppIcon|AppIconActive) ;;
        *) printf 'Unknown icon: %s\n' "$icon" >&2; exit 1 ;;
    esac
    mkdir -p "$ICON_STAGE/$icon.iconset"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "Resources/$icon.png" --out "$ICON_STAGE/$icon.iconset/icon_${size}x${size}.png" >/dev/null
        retina_size=$((size * 2))
        sips -z "$retina_size" "$retina_size" "Resources/$icon.png" --out "$ICON_STAGE/$icon.iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICON_STAGE/$icon.iconset" -o "Resources/$icon.icns"
done
