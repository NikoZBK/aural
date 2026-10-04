#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BENCH_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/aural-benchmark.XXXXXX")"
trap 'rm -rf "$BENCH_STAGE"' EXIT
mkdir -p .build
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$BENCH_STAGE/cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$BENCH_STAGE/cache}"
xcrun clang -O3 -std=c11 -I Sources/DSP/include -c Sources/DSP/DSP.c -o "$BENCH_STAGE/dsp.o"
xcrun swiftc -O -whole-module-optimization -parse-as-library -D AURAL_TESTING -I Sources/DSP/include Sources/Aural/*.swift \
    Tests/ThemeTests/main.swift Tests/PerformanceTests/*.swift "$BENCH_STAGE/dsp.o" \
    -framework CoreAudio -framework AppKit -o "$BENCH_STAGE/benchmark"
cp "$BENCH_STAGE/benchmark" .build/ui-benchmark
cp -R Sources/Aural/Resources/Targets "$BENCH_STAGE/Targets"
"$BENCH_STAGE/benchmark" --benchmark-ui
