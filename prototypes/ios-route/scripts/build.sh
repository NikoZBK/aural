#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! xcodebuild -version >/dev/null 2>&1; then
    echo "Full Xcode 27 or newer is required; Command Line Tools cannot build iPhone apps." >&2
    echo "Install Xcode, open it once, and set DEVELOPER_DIR to its Contents/Developer directory." >&2
    exit 1
fi
sdk="$(xcrun --sdk iphoneos --show-sdk-version)"
if [[ "${sdk%%.*}" -lt 27 ]]; then
    echo "iPhoneOS SDK 27 or newer is required (found $sdk)." >&2
    exit 1
fi
signing=(CODE_SIGNING_ALLOWED=NO)
if [[ "${1:-}" == "--signed" ]]; then
    : "${TEAM_ID:?Set TEAM_ID to your Apple Developer team; provision both provider targets first.}"
    signing=("DEVELOPMENT_TEAM=$TEAM_ID")
elif [[ $# -gt 0 ]]; then
    echo "Usage: $0 [--signed]" >&2
    exit 2
fi
xcodebuild -project AuralRoutePrototype.xcodeproj -scheme AuralRouteTest \
    -configuration Debug -destination 'generic/platform=iOS' -jobs 1 \
    -derivedDataPath "${DERIVED_DATA_PATH:-../../.build/ios-route/xcode}" \
    'OTHER_SWIFT_FLAGS=$(inherited) -j1' "${signing[@]}" build
