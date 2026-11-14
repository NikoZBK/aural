#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 iOS/Tests/configuration.py
out="${AURAL_TEST_OUTPUT:-.build/ios-tests}"
mkdir -p "$out"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ios-tests/clang-cache"
xcrun clang -std=c11 -I Sources/DSP/include -c Sources/DSP/DSP.c -o "$out/dsp.o"
xcrun swiftc -whole-module-optimization -parse-as-library -module-cache-path "$PWD/.build/ios-tests/swift-cache" -I Sources/DSP/include \
    Sources/Aural/Profile.swift Sources/Aural/GraphicEQ.swift Sources/Aural/ProfileDSP.swift \
    Sources/Aural/PresetLibrary.swift Sources/Aural/FilterDraft.swift Sources/Aural/AutoEQ.swift \
    Sources/Aural/AutoEQCatalog.swift Sources/Aural/Headroom.swift Sources/Aural/LevelMatch.swift \
    Sources/Aural/ResponseAnalysis.swift iOS/Core/LibraryState.swift iOS/App/AuralModel.swift \
    iOS/Tests/AudioStub.swift iOS/Tests/ModelTests.swift "$out/dsp.o" \
    -framework CoreAudio -o "$out/model-tests"
"$out/model-tests"
