#!/usr/bin/env python3
"""Serve synthetic AAC fixtures on loopback; never capture browser audio."""

import argparse
import json
import math
from pathlib import Path
import re
import struct
import subprocess
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
import wave


def generate_tone(directory: Path, frequency: int) -> None:
    wav = directory / f"tone-{frequency}.wav"
    with wave.open(str(wav), "wb") as output:
        output.setparams((2, 2, 48000, 0, "NONE", "not compressed"))
        # Exactly 30 seconds; integer-Hz tones loop without a phase discontinuity.
        second = b"".join(struct.pack("<hh", *([round(32767 * 0.005 * math.sin(
            2 * math.pi * frequency * frame / 48000))] * 2)) for frame in range(48000))
        for _ in range(30):
            output.writeframesraw(second)
    subprocess.run(["/usr/bin/afconvert", "-f", "m4af", "-d", "aac ", "-b", "96000",
                    str(wav), str(directory / f"tone-{frequency}.m4a")], check=True)
    wav.unlink()


def serve(directory: Path, port: int, events: Path | None) -> None:
    page = (Path(__file__).resolve().parent.parent / "Fixtures/browser-audio.html").read_bytes()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_resource(False)

        def do_HEAD(self):
            self.send_resource(True)

        def send_resource(self, head_only):
            path = urlsplit(self.path).path
            if path == "/":
                data, content_type = page, "text/html; charset=utf-8"
            elif path in ("/tone-431.m4a", "/tone-1877.m4a"):
                data, content_type = (directory / path[1:]).read_bytes(), "audio/mp4"
            else:
                self.send_error(404)
                return
            start, end = 0, len(data) - 1
            requested = self.headers.get("Range")
            if requested:
                match = re.fullmatch(r"bytes=(\d+)-(\d*)", requested)
                if not match:
                    self.send_error(416, "Only a single byte range is supported")
                    return
                start = int(match[1])
                end = min(int(match[2]) if match[2] else end, end)
                if start > end:
                    self.send_error(416, "Range is outside the fixture")
                    return
            self.send_response(206 if requested else 200)
            self.send_header("Content-Type", content_type)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Cache-Control", "no-store")
            if requested:
                self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
            self.send_header("Content-Length", str(end - start + 1))
            self.end_headers()
            if not head_only:
                self.wfile.write(data[start:end + 1])

        def do_POST(self):
            if self.path != "/event":
                self.send_error(404)
                return
            try:
                count = int(self.headers.get("Content-Length", "0"))
                if not 0 < count <= 4096:
                    raise ValueError("Invalid event size")
                item = json.loads(self.rfile.read(count))
            except (ValueError, UnicodeDecodeError):
                self.send_error(400, "Invalid event JSON")
                return
            if (not isinstance(item, dict) or set(item) != {"kind", "label", "session", "frequency", "time"}
                    or item["kind"] not in ("loaded", "started", "stopped", "error")
                    or item["frequency"] not in (431, 1877)
                    or any(not isinstance(item[key], str) or len(item[key]) > 80
                           for key in ("label", "session", "time"))):
                self.send_error(400, "Invalid event fields")
                return
            if events is not None:
                with events.open("a") as output:
                    output.write(json.dumps(item) + "\n")
            self.send_response(204)
            self.end_headers()

        def log_request(self, code="-", size="-"):
            # Avoid noisy successful byte-range requests; keep HTTP failures visible.
            if code not in (200, 204, 206):
                super().log_request(code, size)

    with ThreadingHTTPServer(("127.0.0.1", port), Handler) as server:
        print(f"Safari: http://127.0.0.1:{port}/?tone=431&label=Safari", flush=True)
        print(f"Chrome: http://127.0.0.1:{port}/?tone=1877&label=Chrome", flush=True)
        print("Start/Stop tones in each browser. Ctrl-C stops the local server.", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            print("Local browser fixture stopped.", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8764)
    parser.add_argument("--events", type=Path, help="Optional local metadata JSONL path; no audio")
    arguments = parser.parse_args()
    if not 1 <= arguments.port <= 65535:
        parser.error("port must be between 1 and 65535")
    if arguments.events is not None and not arguments.events.parent.is_dir():
        parser.error("event directory must already exist")
    with tempfile.TemporaryDirectory(prefix="aural-browser-audio-") as temporary:
        root = Path(temporary)
        for tone in (431, 1877):
            generate_tone(root, tone)
        serve(root, arguments.port, arguments.events)
