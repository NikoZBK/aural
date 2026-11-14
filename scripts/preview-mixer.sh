#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c debug --arch arm64 --scratch-path .build/integration
binary_dir="$(swift build -c debug --arch arm64 --scratch-path .build/integration --show-bin-path)"
preview_stage="$(mktemp -d "${TMPDIR:-/tmp}/aural-mixer-preview.XXXXXX")"
python3 - "$binary_dir" "$preview_stage" "${1:-}" "$PWD" <<'PY'
from pathlib import Path
import json,os,plistlib,re,shutil,sys
binary,stage,output,root=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3],Path(sys.argv[4])
app=stage/'Aural Mixer Preview.app'
for child in ['Contents/MacOS','Contents/Resources','Contents/Frameworks']:(app/child).mkdir(parents=True,exist_ok=True)
shutil.copy2(binary/'Aural',app/'Contents/MacOS/Aural')
framework=root/'.build/integration/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
shutil.copytree(framework,app/'Contents/Frameworks/Sparkle.framework',symlinks=True)
for name in ['AppIcon.icns','AppIconActive.icns']:shutil.copy2(root/'Resources'/name,app/'Contents/Resources'/name)
shutil.copytree(root/'Sources/Aural/Resources/Targets',app/'Contents/Resources/Targets')
settings=stage/'settings';settings.mkdir()
# The preview starts from empty settings. AURAL_PREVIEW_COPY_SETTINGS=1 copies
# your real presets and devices into the stage folder, which only you can read
# and which stays there until you delete it.
source=Path.home()/'Library/Application Support/Aural/settings.json'
copy=os.environ.get('AURAL_PREVIEW_COPY_SETTINGS')=='1' and source.exists()
preferences=json.loads(source.read_text()) if copy else {'devices':{},'presets':{},'selectedUID':''}
# One build above the release in scripts/build.sh, so the preview never offers itself that release.
build=int(re.search(r'<key>CFBundleVersion</key><string>(\d+)</string>',(root/'scripts/build.sh').read_text()).group(1))+1
preferences['startEQAutomatically']=False;preferences['followSystemOutput']=False
if output:preferences['selectedUID']=output
(settings/'settings.json').write_text(json.dumps(preferences))
info={'CFBundleIdentifier':'local.aural.integration-preview','CFBundleName':'Aural Mixer Preview','CFBundleDisplayName':'Aural Mixer Preview','CFBundleExecutable':'Aural','CFBundlePackageType':'APPL','CFBundleShortVersionString':(root/'VERSION').read_text().strip(),'CFBundleVersion':str(build),'LSMinimumSystemVersion':'14.2','CFBundleIconFile':'AppIcon','NSHighResolutionCapable':True,'AuralPreviewSettings':str(settings/'settings.json'),'NSAudioCaptureUsageDescription':'This local Aural preview processes selected-output audio to verify per-app volume and mute. No audio is recorded or uploaded.'}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
(stage/'app-path.txt').write_text(str(app))
PY
app="$(cat "$preview_stage/app-path.txt")"
framework="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
for component in "$framework/XPCServices/Downloader.xpc" "$framework/XPCServices/Installer.xpc" "$framework/Autoupdate" "$framework/Updater.app" "$app/Contents/Frameworks/Sparkle.framework" "$app"; do
    codesign --force --sign - "$component"
done
codesign --verify --deep --strict "$app"
printf 'Preview: %s\n' "$app"
printf 'Delete %s when you are done.\n' "$preview_stage"
