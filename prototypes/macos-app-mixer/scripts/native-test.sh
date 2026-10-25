#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 1 ]]; then
    printf 'Usage: bash scripts/native-test.sh builtin|OUTPUT_UID\n' >&2
    exit 2
fi
probe=.build/apps/AuralMixerProbe.app/Contents/MacOS/MixerProbe
if [[ ! -x "$probe" ]]; then
    printf 'Build diagnostic apps with bash scripts/build.sh first.\n' >&2
    exit 2
fi
output="$1"
report_dir="reports/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$report_dir"
"$probe" inventory --report "$report_dir/before.json"
"$probe" self-test --output "$output" --playback all --report "$report_dir/playback.json"
"$probe" handoff-test --output "$output" --playback all --report "$report_dir/handoff.json"
"$probe" relaunch-test --output "$output" --playback all --restore off --report "$report_dir/relaunch-process.json"
version="$(sw_vers -productVersion)"
major="${version%%.*}"
if [[ ! "$major" =~ ^[0-9]+$ ]]; then
    printf 'Cannot determine OS availability: %s\n' "$version" >&2
    exit 2
fi
if (( major >= 26 )); then
    "$probe" relaunch-test --output "$output" --playback all --restore on --report "$report_dir/relaunch-native.json"
else
    printf 'Native restoration check unavailable before macOS 26.\n'
fi
"$probe" inventory --report "$report_dir/after.json"
python3 - "$report_dir" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
before=json.loads((root/'before.json').read_text())
after=json.loads((root/'after.json').read_text())
if before['output']['uid'] != after['output']['uid']:
    raise SystemExit('Default output changed during the test; inspect before/after inventories.')
remaining=[p for p in after['processes'] if p['bundleID'].startswith('local.aural.mixer-source')]
if remaining:
    raise SystemExit('Diagnostic source process objects remain; inspect after.json.')
print('PASS native checks, source teardown and unchanged default-output UID:',root)
if any(before['output'][key] != after['output'][key] for key in ['name','rate']):
    print('NOTE default-device name/rate changed during the run; UID equality does not prove its backing route was unchanged.')
PY
