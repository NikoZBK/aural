#!/bin/bash
# Source from test/benchmark scripts after changing to the repository root.
# Resolve the same pinned framework used by the application, including SwiftPM's checksum validation.
swift package --scratch-path .build/sparkle-tools resolve
SPARKLE_ROOT="$PWD/.build/sparkle-tools/artifacts/sparkle/Sparkle"
SPARKLE_FRAMEWORK_DIR="$SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64"
[[ -d "$SPARKLE_FRAMEWORK_DIR/Sparkle.framework" ]] || { echo "Sparkle framework missing after dependency resolution." >&2; exit 1; }
SPARKLE_FLAGS=(-F "$SPARKLE_FRAMEWORK_DIR" -framework Sparkle -Xlinker -rpath -Xlinker "$SPARKLE_FRAMEWORK_DIR")
