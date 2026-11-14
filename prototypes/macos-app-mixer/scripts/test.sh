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

# Exercise process ownership without opening an audio route or private OS query.
xcrun clang -std=c11 -I Sources/ProbeCore/include -c Sources/ProbeCore/ProbeCore.c -o "$stage/probe-core.o"
printf 'module ProbeCore { header "%s/Sources/ProbeCore/include/ProbeCore.h" export * }\n' "$PWD" > "$stage/module.modulemap"
xcrun swiftc -module-cache-path "$stage/swift-cache" -I "$stage" -parse-as-library "$source_root/Sources/Aural/Startup.swift" Sources/MixerProbe/RecoveryState.swift Sources/MixerProbe/HAL.swift Sources/MixerProbe/OutputAvailability.swift Sources/MixerProbe/ProcessOwnership.swift Sources/MixerProbe/BrowserPartition.swift Tests/ownership.swift "$stage/probe-core.o" -framework CoreAudio -framework AppKit -o "$stage/ownership-tests"
"$stage/ownership-tests"
