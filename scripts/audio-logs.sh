#!/bin/bash
set -euo pipefail
PREDICATE='subsystem == "local.aural.equalizer" AND (category == "AudioRoute" OR category == "AudioLifecycle")'
case "${1:-recent}" in
    recent) exec /usr/bin/log show --last 20m --info --style compact --predicate "$PREDICATE" ;;
    live) exec /usr/bin/log stream --level info --style compact --predicate "$PREDICATE" ;;
    *) echo "Usage: bash scripts/audio-logs.sh [recent|live]" >&2; exit 2 ;;
esac
