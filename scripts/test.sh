#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun clang -std=c11 -Wall -Wextra -Wno-unused-parameter -fsanitize=address,undefined -g -I Sources/DSP/include Sources/DSP/DSP.c Tests/DSPTests/test.c -framework CoreAudio -o .build/dsp-tests
.build/dsp-tests

xcrun clang -std=c11 -Wall -Wextra -Wno-unused-parameter -fsanitize=address,undefined -g -I Sources/DSP/include Sources/DSP/DSP.c Tests/DSPTests/engine.c -framework CoreAudio -o .build/engine-tests
.build/engine-tests

xcrun swiftc Sources/Aural/Profile.swift Sources/Aural/PresetLibrary.swift Sources/Aural/ReleaseInfo.swift Sources/Aural/FilterDraft.swift Sources/Aural/AutoEQ.swift Sources/Aural/Startup.swift Tests/ImportTests/main.swift -o .build/import-tests
.build/import-tests

# Exercise the app's actual Swift-to-C bridge, not a test-only reimplementation.
xcrun clang -std=c11 -I Sources/DSP/include -c Sources/DSP/DSP.c -o .build/dsp-bridge.o
xcrun swiftc -I Sources/DSP/include Sources/Aural/Profile.swift Sources/Aural/ProfileDSP.swift Tests/BridgeTests/main.swift .build/dsp-bridge.o -framework CoreAudio -o .build/bridge-tests
.build/bridge-tests
