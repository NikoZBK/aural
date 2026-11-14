#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
out=.build/ios-route
mkdir -p "$out"
export CLANG_MODULE_CACHE_PATH="$PWD/$out/clang-cache"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun clang -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -fblocks \
    -I prototypes/ios-route/Shared prototypes/ios-route/Tools/NetworkSink.c \
    prototypes/ios-route/Shared/RouteCore.c prototypes/ios-route/Shared/LocalTransport.c \
    -o "$out/network-sink"
exec "$out/network-sink" "$@"
