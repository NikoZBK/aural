#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun clang -std=c11 -Wall -Wextra -Wno-unused-parameter -fsanitize=address,undefined -g -I Sources/DSP/include Sources/DSP/DSP.c Tests/DSPTests/test.c -framework CoreAudio -o .build/dsp-tests
.build/dsp-tests

xcrun swiftc Sources/Aural/Profile.swift Sources/Aural/AutoEQ.swift Sources/Aural/Startup.swift Tests/ImportTests/main.swift -o .build/import-tests
.build/import-tests
