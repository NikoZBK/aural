# Aural 1.0.0 — A redesigned equalizer

Aural puts your presets, EQ curve, filters, and output controls together in one window. The redesigned equalizer uses a dark gray and teal theme, clear labels, and exact numeric controls. Search your presets, make changes directly, and see how they affect the curve.

## What's new

- Choose **Simple** for presets and everyday listening, or **Professional** for all EQ and stereo controls. Aural remembers your choice; switching modes keeps the current sound unchanged.
- Compare two versions of your settings with A/B. Undo or redo up to 100 changes; each slider drag counts as one change.
- Choose 10 or 31 bands, edit filters directly, adjust gains together, or shift their frequencies.
- Apply filters to the left, right, or both channels, including when importing or exporting APO text.
- Adjust left/right levels, balance, width, crossfeed, mono, polarity, and 0–30 ms delay under **Stereo & delay**.
- See separate left/right EQ curves, individual filter curves, and the other A/B version for comparison.
- Preview preset curves in the library and search presets from the main window.
- Use **Auto preamp** to help prevent clipping. The **Output level** meter remembers the highest level until you reset it.
- The dog closes its eyes while EQ is on and listens with open eyes when EQ is stopped or bypassed. The main window, About window, and Dock update together.
- Device entries left behind after disconnection are skipped so available outputs can still appear.

## Fixes from the final bug sweep

- Changing preamp preserves bass filter history, avoiding a brief change in the EQ curve during volume adjustments.
- Auto preamp checks narrow boosts and filters outside the graph's visible frequency range.
- Numeric fields accept intentional rounded values and reject unfinished edits from a previously selected EQ. Changing a filter's type or channel preserves other edits already applied to it.
- The draft editor detects changes to the active EQ and requires a reload before applying an outdated draft. Invalid input no longer makes the form jump.
- Preset changes stay separate from slider drags in Undo. Offline preset selection, backup name conflicts, and Windows import line numbers are handled consistently.
- Inactive graphic-band values no longer mark an unchanged parametric preset as edited. The active-band count reflects the output's supported frequencies, and an audio buffer error clears the level meter.

Editing, undo/redo, and A/B comparison keep EQ running or stopped as you left it, without changing bypass. Applying a saved preset starts EQ and turns bypass off, as before. Closing the last window keeps EQ running in the menu bar.

The [feature comparison](https://github.com/NikoZBK/aural/blob/v1.0.0/docs/PEACE-FEATURE-ROADMAP.md) lists what Aural supports and what is still missing compared with Peace and Equalizer APO.

## Compatibility

Existing settings and presets keep their sound, with the new stereo controls turned off by default. Preset JSON backups include all new settings. APO text export reports an error if stereo effects are active, so those settings cannot be silently lost. New channel/stereo presets require Aural 1.0.0 or newer. Save A/B versions as presets to keep them after quitting; A/B settings and undo history last only for the current session and reset when changing output.

The EQ curve shows the effect of filters and preamp, not a live analysis of the music. Stereo effects and limiting are excluded. Peak protection is sample-based, not a true-peak mastering limiter. Aural supports a single stereo output stream on macOS 14.2 or newer.

## Validation

- The complete local suite passed: DSP response and sanitizer checks, Swift/C integration, APO import/export, preset migration, draft editing, startup selection, EQ history/A/B, response analysis, window lifecycle, and icon transitions.
- Universal arm64/x86_64 packaging, strict code-signature verification, and DMG verification passed.
- Native UI checks on Apple silicon covered EQ curve updates, channel selection, filter curves, bypass, A/B, undo, numeric validation, stereo controls, 10/31-band layouts, draft editing, and preset previews. Start/stop routing succeeded at 48 kHz on the built-in speakers.
- Intel is cross-compiled, not runtime-tested. Extended Bluetooth/USB, sleep/wake, latency, and long-session audio testing remain outstanding. These checks do not establish full Equalizer APO/Peace parity.

## Download and update

Download **Aural-1.0.0-universal.dmg**, open it, and drag Aural to Applications. A ZIP and SHA-256 checksums are also provided. Requires macOS 14.2 or newer.

Quit Aural before replacing the installed app, then reopen it. Existing settings and presets stay on your Mac. This release is **ad-hoc signed**. If macOS blocks the first launch and you trust the download, follow [Apple's instructions](https://support.apple.com/102445) for Open Anyway.

[Screenshots](https://github.com/NikoZBK/aural#screenshots) · [Changes since 0.9.2](https://github.com/NikoZBK/aural/compare/v0.9.2...v1.0.0)
