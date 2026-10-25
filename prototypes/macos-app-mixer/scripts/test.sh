#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage="$(mktemp -d "${TMPDIR:-/tmp}/aural-mixer-tests.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
export CLANG_MODULE_CACHE_PATH="$stage/clang-cache"
export SWIFT_MODULECACHE_PATH="$stage/swift-cache"
xcrun clang -std=c11 -Wall -Wextra -Wno-unused-parameter -fsanitize=address,undefined -g \
    -I Sources/ProbeCore/include Sources/ProbeCore/ProbeCore.c Tests/core.c -framework CoreAudio -o "$stage/core-tests"
"$stage/core-tests"

source_root="${AURAL_SOURCE_ROOT:-../..}"
xcrun swiftc -module-cache-path "$stage/swift-cache" "$source_root/Sources/Aural/Startup.swift" Sources/MixerProbe/RecoveryState.swift Sources/MixerProbe/OutputAvailability.swift Tests/recovery.swift -o "$stage/recovery-tests"
"$stage/recovery-tests"
