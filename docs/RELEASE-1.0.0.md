# Aural 1.0.0 — Studio workspace

Aural now centers the workflow on an editable response and filter workspace, with a searchable preset rail and persistent output monitoring. The interface uses a restrained graphite/teal palette, compact controls, aligned numeric fields, and a minimum window size that keeps the main controls accessible.

## New capabilities

- Session-local A/B snapshots and main-workspace undo/redo, including gesture-coalesced slider edits.
- Ten/31-band flat layouts, direct filter editing, gain transforms, and frequency shifts.
- Stereo/left/right filter targets and channel-aware APO text import/export.
- Per-channel trims, balance, width, crossfeed, mono, polarity, and 0–30 ms delay.
- Adaptive response plots, independent channel traces, per-filter overlays, comparison references, and estimated EQ headroom.
- Preset-library response preview and main-window preset search.
- dBFS output metering with peak hold and reset.
- Closed-eyes dog while processing; original open-eyed dog while stopped or bypassed. Main, About, and Dock stay synchronized.
- Known stale Core Audio devices are logged and skipped without hiding healthy outputs.

Editing, history, and comparison preserve stopped/running and bypass state. Explicitly applying a saved preset retains its established behavior of starting EQ and leaving bypass. Closing the final window continues to keep EQ running in the menu bar.

The full [feature audit](PEACE-FEATURE-ROADMAP.md) documents implemented functionality and remaining gaps relative to Peace and Equalizer APO.

## Compatibility

Existing settings and presets decode with neutral stereo processing and stereo filter targets. Complete preset JSON backups include the new settings. APO text export rejects nonneutral stereo effects instead of discarding them. New channel/stereo presets require Aural 1.0.0 or newer. A/B and edit history are session-local; saved presets remain the durable format.

The graph is an EQ/preamp transfer function, not a spectrum analyzer; stereo effects and limiting are excluded. Peak protection is sample-based, not a true-peak mastering limiter. Hardware routing remains a single stereo stream on macOS 14.2 or newer.

## Validation

- The complete local suite passed: DSP response and sanitizer checks, Swift/C integration, APO import/export, preset migration, draft editing, startup selection, workflow history/A/B, response analysis, window lifecycle, and icon transitions.
- Universal arm64/x86_64 packaging, strict code-signature verification, and DMG verification passed.
- Native UI checks on Apple silicon covered graph redraws, channel selection, overlays, bypass, A/B, undo, numeric validation, stereo controls, 10/31-band layouts, draft editing, and preset previews. Start/stop routing succeeded at 48 kHz on the built-in speakers.
- Intel is cross-compiled, not runtime-tested. Extended Bluetooth/USB, sleep/wake, latency, and long-session audio testing remain outstanding. These checks do not establish full Equalizer APO/Peace parity.

## Download and update

Download **Aural-1.0.0-universal.dmg**, open it, and drag Aural to Applications. A ZIP and SHA-256 checksums are also provided. Requires macOS 14.2 or newer.

Quit Aural before replacing the installed app, then reopen it. Existing settings and presets stay on your Mac. This release is **ad-hoc signed and not notarized**. If macOS blocks the first launch and you trust the download, follow [Apple's instructions](https://support.apple.com/102445) for Open Anyway.

[Workspace screenshots](https://github.com/NikoZBK/aural#screenshots) · [Changes since 0.9.2](https://github.com/NikoZBK/aural/compare/v0.9.2...v1.0.0)
