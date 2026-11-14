#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate
elif [[ -n "${XCODEGEN:-}" ]]; then
    "$XCODEGEN" generate
elif [[ ! -d AuralIOS.xcodeproj ]]; then
    echo "Install XcodeGen or set XCODEGEN to its executable." >&2
    exit 1
fi
signing=(CODE_SIGNING_ALLOWED=NO)
if [[ "${1:-}" == "--signed" ]]; then
    : "${TEAM_ID:?Set TEAM_ID to the team that owns the existing route protocol.}"
    signing=("DEVELOPMENT_TEAM=$TEAM_ID")
elif [[ $# -gt 0 ]]; then
    echo "Usage: $0 [--signed]" >&2
    exit 2
fi
xcodebuild -project AuralIOS.xcodeproj -scheme Aural -configuration Debug \
    -destination 'generic/platform=iOS' -jobs 2 \
    -derivedDataPath "${DERIVED_DATA_PATH:-../.build/ios}" \
    'OTHER_SWIFT_FLAGS=$(inherited) -j2' "${signing[@]}" build
