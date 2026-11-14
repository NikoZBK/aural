#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
out=.build/ios-route
mkdir -p "$out"
export CLANG_MODULE_CACHE_PATH="$PWD/$out/clang-cache"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
flags=(-isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -Wno-unused-parameter -fblocks -g
       -fsanitize=address,undefined -I Sources/DSP/include -I prototypes/ios-route/Shared -I prototypes/ios-route/Receiver)
xcrun clang "${flags[@]}" prototypes/ios-route/Shared/RouteCore.c prototypes/ios-route/Shared/LocalTransport.c \
    prototypes/ios-route/Receiver/ProbeRenderer.c Sources/DSP/DSP.c prototypes/ios-route/Tests/route.c \
    -framework CoreAudio -o "$out/route-tests"
"$out/route-tests" "$@"
# Check the actual Objective-C render bridge and HAL implementation with the host SDK.
# iOS-only publication and SwiftUI/MediaDevice still require Xcode's iPhoneOS SDK.
xcrun clang -isysroot "$sdk" -fsyntax-only -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter \
    -I prototypes/ios-route/Shared prototypes/ios-route/Extension/RouteDriver.m
xcrun clang -isysroot "$sdk" -fsyntax-only -fobjc-arc -Wall -Wextra -Werror \
    -I Sources/DSP/include -I prototypes/ios-route/Shared prototypes/ios-route/Receiver/SourceNode.m
python3 prototypes/ios-route/Tests/configuration.py
xcrun swiftc -module-cache-path "$out/swift-cache" -parse-as-library \
    prototypes/ios-route/Receiver/ReferenceSource.swift prototypes/ios-route/Tests/SourceTone.swift \
    -o "$out/source-tone-test"
"$out/source-tone-test" "$out/reference-tone.wav"
python3 prototypes/ios-route/Tests/source_tone.py "$out/reference-tone.wav"
# Teardown must work without the former Debug-only opt-in as well as in Release.
for debug in 1 0; do
    xcrun clang "${flags[@]}" -DDEBUG="$debug" -fobjc-arc -I prototypes/ios-route/Extension \
        prototypes/ios-route/Tests/driver_withdrawal.m \
        prototypes/ios-route/Shared/RouteCore.c prototypes/ios-route/Shared/LocalTransport.c \
        -framework Foundation -framework CoreAudio -o "$out/driver-withdrawal-tests-$debug"
    "$out/driver-withdrawal-tests-$debug"
done
if [[ "${1:-}" == "--sockets" ]]; then
    xcrun clang "${flags[@]}" -DDEBUG=1 -fobjc-arc -I prototypes/ios-route/Extension \
        prototypes/ios-route/Tests/activation.m prototypes/ios-route/Extension/RouteDriver.m \
        prototypes/ios-route/Shared/RouteCore.c prototypes/ios-route/Shared/LocalTransport.c \
        -framework Foundation -framework CoreAudio -o "$out/activation-tests"
    "$out/activation-tests"
    xcrun clang "${flags[@]}" -DDEBUG=1 -fobjc-arc -I prototypes/ios-route/Extension \
        prototypes/ios-route/Tests/driver.m \
        prototypes/ios-route/Shared/RouteCore.c prototypes/ios-route/Shared/LocalTransport.c \
        -framework Foundation -framework CoreAudio -o "$out/driver-tests"
    "$out/driver-tests"
fi
