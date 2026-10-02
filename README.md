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

**Signing:** this release is ad-hoc signed, not Developer ID signed or notarized. macOS may require **System Settings → Privacy & Security → Open Anyway** after the first blocked launch. Follow [Apple's instructions](https://support.apple.com/102445) if you trust the download. Managed Macs may prohibit this. Developer ID signing and notarization are needed for a release that avoids this approval step.

## Updates

Choose **Check for Updates…** from the Aural menu, menu bar controls, Settings, or About. Aural shows the latest stable version and changelog. **Download Update** opens the universal installer download in your browser. Quit Aural, open the download, and replace the installed app; saved profiles remain in Application Support. The **Releases page** link is always available if the check fails. Updates are not automatically installed.

## Screenshots

The 1.0 workspace keeps the active preset, channel response, filter rack, and output controls in view.

![Aural 1.0 equalizer workspace with left and right response curves and inline filter editing](docs/screenshots/workspace.jpg)

Stereo and timing controls cover balance, width, crossfeed, channel trims, polarity, and delay.

![Aural 1.0 stereo and timing controls](docs/screenshots/stereo-timing.jpg)

Screenshots use an illustrative demo profile, not a headphone correction preset.

## Features

- Three-pane audio workspace: searchable preset sidebar, response graph and inline filter rack, persistent output/preamp monitor.
- Ten-band octave and 31-band third-octave layouts, exact numeric editing, gain faders, and up to 32 parametric filters.
- Independent **left, right, or stereo** filter targets; peak, low/high shelf, low/high pass, band-pass, notch, and all-pass filters.
- A/B comparison with independently editable snapshots, dashed reference curves, and 100-step workspace undo/redo.
- Stereo effects: per-channel trims, balance, width, low-frequency crossfeed, mono sum, polarity inversion, and 0–30 ms channel delay.
- Adaptive response graph, separate left/right curves, individual filter overlays, cursor inspection, and estimated EQ headroom.
- Master preamp, automatic headroom including stereo gain, output peak meter in dBFS, and resettable peak hold.
- Curve transforms: gain offset, scaling, inversion, and frequency shifts.
- AutoEQ / Equalizer APO text import/export, clipboard Copy/Paste, and channel-aware text round trips.
- Searchable preset library with favorites, preview curves, duplicate/rename/delete/undo-delete, and complete JSON backups.
- Saved settings per output, menu-bar controls, keyboard shortcuts, optional login and automatic startup.

The [feature comparison](docs/PEACE-FEATURE-ROADMAP.md) records what is implemented and what remains outside Aural's current engine.

## Using Aural

Select the output that your apps use. Aural does not change the macOS default output or affect audio routed to a different device. **Stop** releases the audio route. **Bypass** removes EQ, preamp, and stereo effects while retaining routing and peak protection. Close the last Aural window with the red close button or **Command-W** to remove Aural from the Dock while keeping EQ and the menu bar controls running. Choose **Show Aural** from the headphones menu to bring the window and Dock icon back. Minimized windows keep their Dock access. **Quit Aural** or **Command-Q** stops EQ and exits completely.

The closed-eyes dog appears while EQ is processing. The original open-eyed dog listens when EQ is stopped or bypassed. The main window, About window, and running app's Dock icon update together, including after using controls in the menu bar. Finder keeps the original happy icon.

The main window and preset menu show the selected preset, with an **EDITED** badge when its EQ values differ from the saved version. The selection is remembered separately for each output. Saving under a new name selects that preset; renaming updates its displayed name, and deleting it leaves the current sound as Custom EQ.

Selecting a preset applies it immediately, enables EQ if stopped, and exits bypass. Switching between saved AutoEQ profiles and built-in presets keeps the active audio route running. A preset that is incompatible with the current sample rate is rejected without replacing the current sound.

The gear menu controls startup. With automatic EQ enabled, Aural restores the saved output and profile and waits up to 60 seconds for that exact device. It does not apply a headphone profile to another device when the original is disconnected. Start or permission failures are displayed and are not retried indefinitely. Sleep stops processing; start again after wake.

### AutoEQ import

Choose **Files & backups → Import AutoEQ text…** (or the Equalizer menu) and select a UTF-8 parametric or fixed-band text export. The complete file is validated before current settings change. Import stops processing, replaces the previous EQ, and saves a named preset. Click **Start EQ** when ready. Repeated filenames receive a numeric suffix instead of overwriting existing presets.

Use the inline filter rack to adjust type (PK/LSC/HSC/LPQ/HPQ/BP/NO/AP), frequency, gain, Q, enabled state, and exact preamp. Add or remove filters up to the 32-filter limit. From graphic EQ, the editor starts with equivalent peaking filters. **Profile actions → Edit as a draft…** opens a separate preview editor. **Apply EQ** validates the complete draft and updates EQ without starting a stopped engine; **Cancel** leaves the current sound unchanged. Invalid values keep the editor open with an explanation. Save a named preset from the main window to reuse the changes. Imported values retain their precision until edited. Choose **New layout → 10-band octave EQ** for a flat ten-band workspace, or select the 31-band layout. Layout changes are undoable and preserve stereo settings. Imports do not stack on top of the slider EQ.

Supported commands are a global `Preamp`, `Channel: ALL`, `Channel: L`, `Channel: R`, and numbered `Filter` lines using `PK`, `LSC`, or `HSC` with `Fc`, `Gain`, and `Q`; or `LPQ`, `HPQ`, `BP`, `NO`, and `AP` with `Fc` and explicit `Q` (no Gain field). Pass/notch filter gain is not adjustable; band-pass has unity peak gain. LPQ/HPQ are second-order filters with adjustable Q. Shorthand LP/HP, omitted Q, bandwidth syntax, and higher-order filters are not yet supported. Blank lines, `#` comments, OFF filters, CRLF, and a UTF-8 BOM are accepted. No Preamp line means 0 dB. Limits are 32 filters, 10–22000 Hz, −30 to +30 dB filter gain, Q 0.05–50, −60 to +24 dB imported preamp, and 64 KB file size. All filters may be disabled; their values remain saved and preamp, stereo effects, and peak protection still affect audio. Global Bypass additionally bypasses preamp and stereo effects. A per-channel `Preamp` command is rejected; use Aural’s channel trims for this.

`GraphicEQ:` curves, WAV convolution, CSV measurements, and other APO commands are not supported. Use AutoEQ's **ParametricEQ.txt** or **FixedBandEQ.txt** export. No headphone correction profiles are included.

## Privacy

Aural does not record audio files, collect telemetry, or upload profiles. Opening **Check for Updates…** sends a request to GitHub for the latest public release (including Aural’s version in the User-Agent); there are no background update checks. GitHub receives normal connection information such as your IP address. Download links open in your default browser. Audio is processed locally in memory. Only system audio input is used; hardware input streams are disabled when present.

Settings and imported profiles are stored in the current user's `~/Library/Application Support/Aural/settings.json`. They are created at runtime and are **not** included in the app, installer, repository, or releases. Tests use invented data rather than downloaded headphone profiles. A new installation starts with flat EQ and both startup options off.

## Current scope

Aural currently targets stereo listening and calibration. It supports a single stereo output stream in 32-bit float format at 32–192 kHz. It does not support mono/surround outputs, multi-stream interfaces, aggregate/multi-output setups, per-app mixing, or convolution. Bluetooth, USB hardware, sleep/wake behavior, protected media, and extended operation need further hardware testing. Intel is cross-compiled; runtime checks to date were performed on Apple silicon.

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

Click the library icon beside Presets, or choose **Equalizer → Preset library…** (⇧⌘P) to search, favorite, duplicate, rename, or delete presets. Built-in presets can be duplicated and favorited; renaming and deletion apply to custom presets. **Undo delete** restores the most recent deletion until Aural quits. Deleting or renaming a saved preset does not change the active EQ.

**Back up presets…** writes a versioned JSON file containing custom presets and favorites. **Restore presets…** validates the entire backup before merging; conflicting names receive numeric suffixes. Restore never replaces the current EQ or enables processing. Device selection, startup preferences, and per-device settings are not part of a preset backup.

The menu bar now includes preset selection, favorites, and preamp adjustments in 1 dB steps within the current profile's limits. These controls preserve the current bypass and playback state when changing preamp. **Export EQ…** saves the current Equalizer APO settings to a text file.

In **Profile actions → Edit as a draft…**, each row's actions menu can duplicate or move a filter up/down. **Undo** and **Redo** restore up to 100 draft edits, including filter additions/removals, order, values, enabled state, and preamp. These changes remain a draft until **Apply EQ**; **Cancel** leaves playback unchanged.

### Comparison, history, and stereo

Select **B** to begin an A/B comparison from the current profile. Edits stay in the selected slot; selecting the other slot recalls its complete profile and preset identity. The dashed graph shows the other slot. Use the comparison menu to copy the active slot to the other or reset both. A/B and undo history are session-local and reset when changing output; save each version as a preset to retain it across launches.

**Undo/Redo** covers main-window EQ and stereo changes, template replacement, transforms, preset application, and comparison. Slider drags form one undo step. Keyboard shortcuts are **⌥⌘Z / ⇧⌥⌘Z** for profile undo/redo, **⌥⌘1 / ⌥⌘2** for A/B, and **⌥⌘B** for bypass. These shortcuts work while Aural is active; ordinary text-field undo/copy/paste remain available. Stop/start and bypass are transport controls and are not part of profile history.

**Stereo & timing** processes EQ output through normalized 700 Hz crossfeed, mid/side width (or mono sum), per-channel trim/balance/polarity, then fractional delay and sample-peak protection. Width 1 is original stereo; width 0 sums to mono. Mono occurs before channel calibration. Defaults are neutral and preserve legacy output. Delay settings add the specified delay; they are not measurements of total system latency. The graph displays EQ/preamp response and intentionally excludes stereo effects and peak protection. Auto headroom reserves a conservative stereo-gain bound, but does not guarantee true-peak headroom.

APO text supports channel-targeted filters, but does not encode Aural's stereo effects. Copy/export rejects nonneutral stereo effects with an explanation, so they cannot be silently discarded. Save a preset and use **Files & backups → Back up presets…** to preserve the complete configuration, including stereo settings. Legacy presets remain compatible; new stereo/channel presets require Aural 1.0.0 or later.

### Engine verification

The engine tests measure response at 32, 44.1, 48, 96, and 192 kHz, check all-pass phase inversion at its center frequency, exercise explicit disabled filters, and stress rapid updates and 32-filter extremes. A magnitude floor of −300 dB per filter keeps exact notch zeros finite in the response calculation; it does not change audio. Nonfinite samples and malformed buffers latch faults for the control thread instead of sending invalid samples to the output.

Filter equations follow the [W3C Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/); text syntax follows the supported subset of the [Equalizer APO reference](https://sourceforge.net/p/equalizerapo/wiki/Configuration%20reference/). Profiles containing new filter types require Aural 0.8.0 or later.

The [0.9.0 interface notes](docs/RELEASE-0.9.0.md) describe the Ultra workspace. [0.9.2 release notes](docs/RELEASE-0.9.2.md) cover selected-preset display and the dog-with-headphones icon. [0.9.3 release notes](docs/RELEASE-0.9.3.md) cover running in the menu bar after closing the window. [0.9.4 release notes](docs/RELEASE-0.9.4.md) cover sleeping and happy icon states.

[1.0.0 studio workspace notes](docs/RELEASE-1.0.0.md) cover the redesigned interface, channel EQ, stereo processing, A/B, and reversed dog states.
