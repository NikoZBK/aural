#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
sdk="$(xcrun --sdk macosx --show-sdk-path)"
version="$(xcrun --sdk macosx --show-sdk-version)"
if [[ "${version%%.*}" -lt 27 ]]; then
    echo "This additional API check requires the macOS 27 SDK's Catalyst interfaces." >&2
    exit 1
fi
# A host-side type-check, not an iPhone build. The iPhone-only Swift MediaDevice
# module is unavailable here; build.sh must still pass with the iPhoneOS SDK.
target="$(uname -m)-apple-ios27.0-macabi"
xcrun swiftc -parse-as-library -warnings-as-errors -typecheck -target "$target" -sdk "$sdk" \
    -F "$sdk/System/iOSSupport/System/Library/Frameworks" \
    -I Sources/DSP/include -I prototypes/ios-route/Shared \
    -import-objc-header prototypes/ios-route/Receiver/Bridging-Header.h \
    -module-cache-path .build/ios-route/swift-cache \
    prototypes/ios-route/Receiver/ProbeAudio.swift prototypes/ios-route/Receiver/ProbeApp.swift
xcrun swiftc -parse-as-library -warnings-as-errors -typecheck -target "$target" -sdk "$sdk" \
    -F "$sdk/System/iOSSupport/System/Library/Frameworks" \
    -module-cache-path .build/ios-route/swift-cache prototypes/ios-route/Provider/ProviderApp.swift
xcrun swiftc -frontend -parse prototypes/ios-route/Extension/RouteExtension.swift
echo "PASS receiver/provider Catalyst API type-check and extension Swift syntax (not an iPhone build)"
