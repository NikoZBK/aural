#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun clang -std=c11 -Wall -Wextra -Wno-unused-parameter -fsanitize=address,undefined -g -I Sources/DSP/include Sources/DSP/DSP.c Tests/DSPTests/test.c -framework CoreAudio -o .build/dsp-tests
.build/dsp-tests

xcrun clang -std=c11 -Wall -Wextra -Wno-unused-parameter -fsanitize=address,undefined -g -I Sources/DSP/include Sources/DSP/DSP.c Tests/DSPTests/engine.c -framework CoreAudio -o .build/engine-tests
.build/engine-tests

xcrun clang -std=c11 -Wall -Wextra -Wno-unused-parameter -fsanitize=address,undefined -g -I Sources/DSP/include Sources/DSP/DSP.c Tests/DSPTests/response.c -framework CoreAudio -o .build/response-sampling-tests
.build/response-sampling-tests

xcrun swiftc Sources/Aural/Profile.swift Sources/Aural/PresetLibrary.swift Sources/Aural/ReleaseInfo.swift Sources/Aural/FilterDraft.swift Sources/Aural/AutoEQ.swift Sources/Aural/Startup.swift Tests/ImportTests/main.swift -o .build/import-tests
.build/import-tests

# Exercise the app's actual Swift-to-C bridge, not a test-only reimplementation.
xcrun clang -std=c11 -I Sources/DSP/include -c Sources/DSP/DSP.c -o .build/dsp-bridge.o
xcrun swiftc -I Sources/DSP/include Sources/Aural/Profile.swift Sources/Aural/ProfileDSP.swift Tests/BridgeTests/main.swift .build/dsp-bridge.o -framework CoreAudio -o .build/bridge-tests
.build/bridge-tests

xcrun swiftc Sources/Aural/Profile.swift Sources/Aural/ProfileWorkspace.swift Tests/WorkflowTests/main.swift -o .build/workflow-tests
.build/workflow-tests

# Preserve imported precision while distinguishing explicit numeric edits from display formatting.
xcrun swiftc -parse-as-library Sources/Aural/PrecisionInput.swift Tests/PrecisionTests/main.swift -o .build/precision-tests
.build/precision-tests

xcrun swiftc -I Sources/DSP/include Sources/Aural/Profile.swift Sources/Aural/ProfileDSP.swift Sources/Aural/ResponseAnalysis.swift Tests/ResponseTests/main.swift .build/dsp-bridge.o -framework CoreAudio -o .build/response-tests
.build/response-tests

xcrun swiftc -I Sources/DSP/include Sources/Aural/Profile.swift Sources/Aural/ProfileDSP.swift Sources/Aural/Headroom.swift Tests/HeadroomTests/main.swift .build/dsp-bridge.o -framework CoreAudio -o .build/headroom-tests
.build/headroom-tests

# Exercise the actual window lifecycle controller without launching audio or showing UI.
xcrun swiftc -parse-as-library Sources/Aural/WindowPresence.swift Tests/WindowTests/main.swift -framework AppKit -o .build/window-tests
.build/window-tests

# Exercise processing-driven icon updates without changing the real app icon or audio.
xcrun swiftc -parse-as-library Sources/Aural/AppIcon.swift Tests/IconTests/main.swift -framework AppKit -o .build/icon-tests
.build/icon-tests

# Check theme persistence, contrast, and native appearance without using personal settings or audio.
xcrun swiftc -whole-module-optimization -parse-as-library -D AURAL_TESTING -I Sources/DSP/include Sources/Aural/*.swift Tests/ThemeTests/main.swift Tests/PerformanceTests/*.swift .build/dsp-bridge.o -framework CoreAudio -framework AppKit -o .build/theme-tests
.build/theme-tests
