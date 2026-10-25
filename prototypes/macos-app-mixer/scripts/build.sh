#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/aural-mixer-clang-cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-${TMPDIR:-/tmp}/aural-mixer-swift-cache}"
source_root="${AURAL_SOURCE_ROOT:-../..}"
cp "$source_root/Sources/Aural/Startup.swift" Sources/MixerProbe/SharedStartup.swift
swift build -c release --scratch-path .build/package
binary_dir="$(swift build -c release --scratch-path .build/package --show-bin-path)"
mkdir -p .build/apps
for suffix in Probe SourceA SourceB SourceC; do
    app=".build/apps/AuralMixer$suffix.app"
    mkdir -p "$app/Contents/MacOS"
    cp "$binary_dir/MixerProbe" "$app/Contents/MacOS/MixerProbe"
    python3 - "$app" "$suffix" <<'PY'
import pathlib,plistlib,sys
app=pathlib.Path(sys.argv[1]); suffix=sys.argv[2]
info={'CFBundleIdentifier':'local.aural.mixer-'+suffix.lower(),'CFBundleName':'Aural Mixer '+suffix,
      'CFBundleExecutable':'MixerProbe','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.1','CFBundleVersion':'1',
      'LSMinimumSystemVersion':'14.2','LSUIElement':True,
      'NSAudioCaptureUsageDescription':'This local diagnostic separates audio streams to test per-app volume. Audio is analyzed in memory; no recordings are saved or uploaded.'}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
    codesign --force --sign "${SIGNING_IDENTITY:--}" "$app"
    codesign --verify --strict "$app"
done
printf 'Built %s/.build/apps/AuralMixerProbe.app\n' "$PWD"
