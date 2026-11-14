#!/usr/bin/env python3
"""Summarize retained route evidence; never infer a device pass from missing logs.

Exit 1: captured Aural fallback to local output. Exit 2: inconclusive or invalid
input. A passing hardware test still requires sustained audio and audible EQ.
Accepts `log show --style ndjson` or saved Console accessibility text.
"""

import argparse
from datetime import datetime, timedelta
import json
from pathlib import Path
import re
import sys

PROTOCOL = "media-device-protocol.local.aural.route-probe"
SIGNALS = (
    "Activation requested", "activation acknowledged", "Sample delivery",
    "Initialize", "publication", "Publish route driver", "StartIO", "StopIO", "Stream active",
    "HAL withdrawal", "Restoring HAL device list",
    "MusicVAD: YES", "MusicVAD: NO", "Allow session", "Will attempt to switch",
    "No matching AirPlay", "Selecting routes", "MDE fallback to local",
    "MDERouteRevertedToLocal", "doesn't support currently selected protocolID",
)


def read_events(path, date):
    content = path.read_text()
    events = []
    if content.lstrip().startswith("{"):
        for number, line in enumerate(content.splitlines(), 1):
            if not line.strip():
                continue
            record = json.loads(line)
            if "eventMessage" not in record:
                continue  # log metadata, not a message
            stamp = datetime.fromisoformat(record["timestamp"])
            if stamp.tzinfo is None:
                raise ValueError(f"{path}:{number}: timestamp lacks a timezone")
            process = Path(record.get("processImagePath", "unknown")).name
            events.append((stamp, process, record["eventMessage"]))
    elif content.startswith('Window: "Console"'):
        if not date:
            raise ValueError("Console captures require --date YYYY-MM-DD")
        # Offscreen AX rows can lack cells. Only retain complete observed rows.
        for row in re.split(r"(?m)^\s*\d+ row \(", content):
            texts = re.findall(r"(?m)^\s*\d+ text (.*)$", row)
            if len(texts) >= 3 and re.fullmatch(r"\d{2}:\d{2}:\d{2}\.\d+[+-]\d{4}", texts[0]):
                stamp = datetime.fromisoformat(f"{date}T{texts[0]}")
                events.append((stamp, texts[1], texts[2]))
    else:
        raise ValueError(f"{path}: unsupported or empty capture")
    return events


def summarize(events):
    events = sorted(set(events))  # Deduplicate exact overlap, never near timestamps.
    failures = []
    for stamp, process, message in events:
        if process != "audiomxd" or "MDE fallback to local" not in message:
            continue
        # The generic system marker alone could concern another MDE route.
        context = [event for event in events
                   if event[1] == process
                   and timedelta(0) <= stamp - event[0] <= timedelta(seconds=3)
                   and PROTOCOL in event[2]
                   and "doesn't support currently selected protocolID" in event[2]]
        if context:
            failures.append(stamp.isoformat())
    return {
        "verdict": "OBSERVED_AURAL_ROUTE_REVERSION" if failures else "INCONCLUSIVE",
        "failure_times": failures,
        "complete_rows": len(events),
        "limitation": "Log diagnosis only; absence of this marker is not a passing reconnect test.",
        "timeline": [{"time": stamp.isoformat(), "process": process, "message": message}
                     for stamp, process, message in events
                     if any(signal.lower() in message.lower() for signal in SIGNALS)],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--date", help="Local capture date for Console AX input")
    parser.add_argument("captures", type=Path, nargs="+")
    args = parser.parse_args()
    try:
        events = [event for path in args.captures for event in read_events(path, args.date)]
        result = summarize(events)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(2, f"Invalid evidence: {error}\n")
    print(json.dumps(result, indent=2))
    return 1 if result["failure_times"] else 2


if __name__ == "__main__":
    sys.exit(main())
