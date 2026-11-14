#!/bin/bash
# Read-only, local iPhone routing evidence export. Does not restart any process.
set -euo pipefail

if [[ $# != 4 ]]; then
    printf 'Usage: bash %s DEVICE_UDID START_TIME END_TIME OUTPUT_BASE\n' "$0" >&2
    printf 'Times use YYYY-MM-DD HH:MM:SS-0400. OUTPUT_BASE must not exist.\n' >&2
    exit 2
fi

device="$1"
start="$2"
end="$3"
output="$4"
archive="${output}.logarchive"
events="${output}.ndjson"
if [[ -e "$archive" || -e "$events" ]]; then
    printf 'Refusing to overwrite existing evidence: %s\n' "$output" >&2
    exit 2
fi
if [[ ! -d "$(dirname "$output")" ]]; then
    printf 'Output parent directory does not exist: %s\n' "$output" >&2
    exit 2
fi

# System markers are diagnostic observations, not APIs used by the prototype.
# Collection is bounded and filtered so unrelated device activity is excluded.
predicate='subsystem BEGINSWITH "local.aural.route-probe" OR eventMessage CONTAINS "modifyCurrentSelectionIfNecessary" OR eventMessage CONTAINS "MusicVAD" OR eventMessage CONTAINS "MDERouteRevertedToLocal"'
printf 'Exporting filtered iPhone audio events to %s\n' "$archive"
printf 'macOS requires administrator authentication to read attached-device logs.\n'
sudo /usr/bin/log collect --device-udid "$device" --start "$start" \
    --size 30m --predicate "$predicate" --output "$archive"

# noclobber also protects against a file created while collection was running.
set -o noclobber
/usr/bin/log show --archive "$archive" --start "$start" --end "$end" \
    --info --debug --style ndjson --predicate "$predicate" > "$events"
printf 'Export complete: %s\n' "$events"
printf 'An empty export is missing evidence, not a successful route test.\n'
