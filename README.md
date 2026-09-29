<p align="center">
  <img src="Resources/AppIcon.png" width="160" alt="Aural pixel-art dog wearing headphones">
</p>
<h1 align="center">Aural</h1>
<p align="center">A native macOS equalizer. Shape your sound, keep your settings local.</p>

Aural applies equalization to audio playing through a selected stereo output using Apple's Core Audio process taps. It has a SwiftUI interface, a menu bar controller, and a C signal-processing engine. No extra audio driver is required.

## Download and install

**[Download the latest release](https://github.com/NikoZBK/aural/releases/latest)** — universal DMG for **Apple silicon and Intel**, requiring **macOS 14.2 or newer**. A ZIP is also available.

1. Open the DMG and drag **Aural** to **Applications**.
2. Eject the DMG and launch the installed app.
3. Choose your output, click **Start EQ**, and allow system audio capture when prompted.

**Signing:** the initial public release is ad-hoc signed, not Developer ID signed or notarized. macOS may require **System Settings → Privacy & Security → Open Anyway** after the first blocked launch. Follow [Apple's instructions](https://support.apple.com/102445) if you trust the download. Managed Macs may prohibit this. Developer ID signing and notarization are needed for a release that avoids this approval step.

## Updates

Choose **Check for Updates…** from the Aural menu, menu bar controls, Settings, or About. Aural shows the latest stable version and changelog. **Download Update** opens the universal installer download in your browser. Quit Aural, open the download, and replace the installed app; saved profiles remain in Application Support. The **Releases page** link is always available if the check fails. Updates are not automatically installed.

## Features

- Ten adjustable bands from 31.5 Hz to 16 kHz, with preamp and automatic headroom.
- Resizable dark workspace, frequency-response graph with hover inspection, and output peak meter in dBFS.
- Filter studio with numbered rows, keyboard undo/redo, and a searchable preset library with favorites, backups, and restore.
- Clipboard Copy/Paste and file export in Equalizer APO format.
- Ten built-in presets: Flat, Warm, Voice, Detail, Bass Boost, Treble Boost, Classical, Electronic, Rock, and Vocal. Save your own named presets too.
- Separate saved settings for each output device.
- AutoEQ `ParametricEQ.txt` and `FixedBandEQ.txt` import, retaining exact frequencies, gain, Q, filter type, and preamp.
- Peaking, low/high shelves, low/high pass, band-pass, notch, and all-pass filters; up to 32 filters.
- Bypass, stereo-linked sample-peak protection, and menu bar controls.
- Optional **Launch at login** and **Start EQ automatically**.

## Using Aural

Select the output that your apps use. Aural does not change the macOS default output or affect audio routed to a different device. **Stop** releases the audio route. **Bypass** removes EQ and preamp while retaining routing and peak protection. Closing the window leaves the menu bar app running; **Quit Aural** exits.

The main window and preset menu show the selected preset, with a **Modified** badge when its EQ values differ from the saved version. The selection is remembered separately for each output. Saving under a new name selects that preset; renaming updates its displayed name, and deleting it leaves the current sound as Custom EQ.

Selecting a preset applies it immediately, enables EQ if stopped, and exits bypass. Switching between saved AutoEQ profiles and built-in presets keeps the active audio route running. A preset that is incompatible with the current sample rate is rejected without replacing the current sound.

The gear menu controls startup. With automatic EQ enabled, Aural restores the saved output and profile and waits up to 60 seconds for that exact device. It does not apply a headphone profile to another device when the original is disconnected. Start or permission failures are displayed and are not retried indefinitely. Sleep stops processing; start again after wake.

### AutoEQ import

Choose **Import / export file → Import AutoEQ…** (or the Equalizer menu) and select a UTF-8 parametric or fixed-band text export. The complete file is validated before current settings change. Import stops processing, replaces the previous EQ, and saves a named preset. Click **Start EQ** when ready. Repeated filenames receive a numeric suffix instead of overwriting existing presets.

Click **Edit filters…** to adjust type (PK/LSC/HSC/LPQ/HPQ/BP/NO/AP), frequency, gain, Q, enabled state, and exact preamp. Add or remove filters up to the 32-filter limit. From graphic EQ, the editor starts with equivalent peaking filters. **Apply EQ** validates the complete draft and updates EQ immediately; **Cancel** leaves the current sound unchanged. Invalid values keep the editor open with an explanation. Save a named preset from the main window to reuse the changes. Imported values retain their precision until edited. Choose a built-in preset or **Reset to flat** to return to the ten sliders. Imports do not stack on top of the slider EQ.

Supported commands are `Preamp` and numbered `Filter` lines using `PK`, `LSC`, or `HSC` with `Fc`, `Gain`, and `Q`; or `LPQ`, `HPQ`, `BP`, `NO`, and `AP` with `Fc` and explicit `Q` (no Gain field). Pass/notch filter gain is not adjustable; band-pass has unity peak gain. LPQ/HPQ are second-order filters with adjustable Q. Shorthand LP/HP, omitted Q, bandwidth syntax, and higher-order filters are not yet supported. Blank lines, `#` comments, OFF filters, CRLF, and a UTF-8 BOM are accepted. No Preamp line means 0 dB. Limits are 32 filters, 10–22000 Hz, −30 to +30 dB filter gain, Q 0.05–50, −60 to +24 dB imported preamp, and 64 KB file size. All filters may be disabled; their values remain saved and only preamp/peak protection affect audio. Global Bypass additionally bypasses preamp.

`GraphicEQ:` curves, WAV convolution, CSV measurements, and other APO commands are not supported. Use AutoEQ's **ParametricEQ.txt** or **FixedBandEQ.txt** export. No headphone correction profiles are included.

## Privacy

Aural does not record audio files, collect telemetry, or upload profiles. Opening **Check for Updates…** sends a request to GitHub for the latest public release (including Aural’s version in the User-Agent); there are no background update checks. GitHub receives normal connection information such as your IP address. Download links open in your default browser. Audio is processed locally in memory. Only system audio input is used; hardware input streams are disabled when present.

Settings and imported profiles are stored in the current user's `~/Library/Application Support/Aural/settings.json`. They are created at runtime and are **not** included in the app, installer, repository, or releases. Tests use invented data rather than downloaded headphone profiles. A new installation starts with flat EQ and both startup options off.

## Current scope

This is an early release. It supports a single stereo output stream in 32-bit float format at 32–192 kHz. It does not support mono/surround outputs, multi-stream interfaces, aggregate/multi-output setups, per-app mixing, convolution. Bluetooth, USB hardware, sleep/wake behavior, protected media, and extended operation need further hardware testing. Intel is cross-compiled; runtime checks to date were performed on Apple silicon.

Latency depends on the device buffer size and has not been measured. Peak protection is a sample-peak limiter, not a true-peak mastering limiter. A built-in band at or above 49% of sample rate is disabled. For imported profiles, an enabled filter beyond that threshold prevents starting rather than silently changing the profile; select a higher sample rate in Audio MIDI Setup. The stopped response preview uses 48 kHz; processing uses the actual device rate.

If there is no output signal, check the selected output and **System Settings → Privacy & Security → Screen & System Audio Recording**. Quit and reopen after granting access. See [installation, updates, and removal](docs/INSTALL.txt).

## Build and test

Install Apple's Command Line Tools or Xcode, then run:

```sh
bash scripts/test.sh
bash scripts/build.sh
bash scripts/package.sh
```

- `test.sh`: DSP tests with AddressSanitizer/UndefinedBehaviorSanitizer and Swift parser/startup tests.
- `build.sh`: compiles arm64 and x86_64, combines them into a universal executable, adds the icon, signs locally, and creates a ZIP in `dist/`.
- `package.sh`: builds the app, creates a drag-to-Applications DMG, verifies the image, and writes SHA-256 checksums.
- `make-icon.sh`: regenerates the complete macOS ICNS size set from the included PNG.

No third-party runtime dependencies or package downloads are required. Build outputs are ignored by Git. [Release and signing instructions](docs/RELEASING.md) describe optional Developer ID signing and notarization.

## Implementation

`Audio.swift` owns the private process tap and aggregate device. Aural excludes its own process to prevent feedback and mutes the original stream only while the tap is consumed. It uses the selected output's clock. The callback is stopped and destroyed before its DSP state is freed.

`DSP.c` implements RBJ biquads, preamp, peak protection, and a bounded lock-free settings queue. Coefficients and gain conversion are prepared on the control thread. Live changes crossfade between two preallocated filter chains over 20 ms; rapid edits are coalesced to the latest pending state after the current fade completes. Unchanged filter prefixes retain their state. Bypassed chains continue processing internally to avoid stale-state replay. Steady-state output is unchanged for existing peaking and shelf profiles. The audio callback performs no allocation, locks, logging, filesystem access, or Swift/Objective-C calls.

Tests cover measured frequency response, channel isolation, preamp/bypass, sample rates, clipping protection, buffer layouts, invalid controls, peaking/shelf response, AutoEQ validation and precision, saved-settings migration, and startup device selection. Native launch, import, saved-profile reload, and automatic startup have also been checked on Apple silicon.

[Apple Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) · [AutoEQ](https://github.com/jaakkopasanen/AutoEq) · [Icon provenance](docs/ICON.md)

## About

Created by **Nikolay Ostroukhov**. The app includes an About window with version information, credits, license, and project links.

## License

MIT. See [LICENSE](LICENSE). Aural is an independent project and is not affiliated with Apple or AutoEQ.

### Copy and paste EQ settings

Click **Copy settings (Equalizer APO format)** on a headphone EQ page, then **Paste EQ** in Aural (⇧⌘V). Aural validates the complete text, saves it as a “Clipboard EQ” preset, and stops processing. Click **Start EQ** when ready. Invalid or empty clipboard text reports an error without changing your EQ or stopping audio.

**Copy EQ** (⇧⌘C) copies the current preamp and every filter in Equalizer APO / AutoEQ text format, preserving precision and disabled filters. The ten-band equalizer exports as ten peaking filters with the same frequencies and Q. Both actions are also in the **Equalizer** menu; ordinary text-field copy and paste shortcuts remain available.

### Preset library and editing tools

Click **Library** beside Presets, or choose **Equalizer → Preset library…** (⇧⌘P) to search, favorite, duplicate, rename, or delete presets. Built-in presets can be duplicated and favorited; renaming and deletion apply to custom presets. **Undo delete** restores the most recent deletion until Aural quits. Deleting or renaming a saved preset does not change the active EQ.

**Back up presets…** writes a versioned JSON file containing custom presets and favorites. **Restore presets…** validates the entire backup before merging; conflicting names receive numeric suffixes. Restore never replaces the current EQ or enables processing. Device selection, startup preferences, and per-device settings are not part of a preset backup.

The menu bar now includes preset selection, favorites, and preamp adjustments in 1 dB steps within the current profile's limits. These controls preserve the current bypass and playback state when changing preamp. **Export EQ…** saves the current Equalizer APO settings to a text file.

In **Edit filters…**, each row's actions menu can duplicate or move a filter up/down. **Undo** and **Redo** restore up to 100 draft edits, including filter additions/removals, order, values, enabled state, and preamp. These changes remain a draft until **Apply EQ**; **Cancel** leaves playback unchanged.

### Engine verification

The engine tests measure response at 32, 44.1, 48, 96, and 192 kHz, check all-pass phase inversion at its center frequency, exercise explicit disabled filters, and stress rapid updates and 32-filter extremes. A magnitude floor of −300 dB per filter keeps exact notch zeros finite in the response calculation; it does not change audio. Nonfinite samples and malformed buffers latch faults for the control thread instead of sending invalid samples to the output.

Filter equations follow the [W3C Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/); text syntax follows the supported subset of the [Equalizer APO reference](https://sourceforge.net/p/equalizerapo/wiki/Configuration%20reference/). Profiles containing new filter types require Aural 0.8.0 or later.

The [0.9.0 interface notes](docs/RELEASE-0.9.0.md) describe the Ultra workspace. [0.9.2 release notes](docs/RELEASE-0.9.2.md) cover selected-preset display, the dog-with-headphones icon, and validation.
