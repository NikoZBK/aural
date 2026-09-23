<p align="center">
  <img src="Resources/AppIcon.png" width="160" alt="Aural EQ dog paw icon">
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

## Features

- Ten adjustable bands from 31.5 Hz to 16 kHz, with preamp and automatic headroom.
- Frequency-response graph and output peak meter.
- Ten built-in presets: Flat, Warm, Voice, Detail, Bass Boost, Treble Boost, Classical, Electronic, Rock, and Vocal. Save your own named presets too.
- Separate saved settings for each output device.
- AutoEQ `ParametricEQ.txt` and `FixedBandEQ.txt` import, retaining exact frequencies, gain, Q, filter type, and preamp.
- Peaking, low-shelf, and high-shelf filters; up to 32 imported filters.
- Bypass, stereo-linked sample-peak protection, and menu bar controls.
- Optional **Launch at login** and **Start EQ automatically**.

## Using Aural

Select the output that your apps use. Aural does not change the macOS default output or affect audio routed to a different device. **Stop** releases the audio route. **Bypass** removes EQ and preamp while retaining routing and peak protection. Closing the window leaves the menu bar app running; **Quit Aural** exits.

Selecting a preset applies it immediately, enables EQ if stopped, and exits bypass. Switching between saved AutoEQ profiles and built-in presets keeps the active audio route running. A preset that is incompatible with the current sample rate is rejected without replacing the current sound.

The gear menu controls startup. With automatic EQ enabled, Aural restores the saved output and profile and waits up to 60 seconds for that exact device. It does not apply a headphone profile to another device when the original is disconnected. Start or permission failures are displayed and are not retried indefinitely. Sleep stops processing; start again after wake.

### AutoEQ import

Click **Import AutoEQ…** and select a UTF-8 parametric or fixed-band text export. The complete file is validated before current settings change. Import stops processing, replaces the previous EQ, and saves a named preset. Click **Start EQ** when ready. Repeated filenames receive a numeric suffix instead of overwriting existing presets.

Imported filters appear in a read-only table. Their original values remain exact; the preamp is adjustable. Choose a built-in preset or **Reset to flat** to return to the ten sliders. Imports do not stack on top of the slider EQ.

Supported commands are `Preamp` and `Filter` using `PK`, `LSC`, or `HSC`, with `Fc`, `Gain`, and `Q`. Blank lines, `#` comments, OFF filters, CRLF, and a UTF-8 BOM are accepted. No Preamp line means 0 dB. Limits are 32 filters, 10–22000 Hz, −30 to +30 dB filter gain, Q 0.05–50, −60 to +24 dB imported preamp, and 64 KB file size. At least one filter must be enabled.

`GraphicEQ:` curves, WAV convolution, CSV measurements, and other APO commands are not supported. Use AutoEQ's **ParametricEQ.txt** or **FixedBandEQ.txt** export. No headphone correction profiles are included.

## Privacy

Aural's application code makes no network requests and does not record audio files, collect telemetry, or upload profiles. Audio is processed locally in memory. Only system audio input is used; hardware input streams are disabled when present.

Settings and imported profiles are stored in the current user's `~/Library/Application Support/Aural/settings.json`. They are created at runtime and are **not** included in the app, installer, repository, or releases. Tests use invented data rather than downloaded headphone profiles. A new installation starts with flat EQ and both startup options off.

## Current scope

This is an early release. It supports a single stereo output stream in 32-bit float format at 32–192 kHz. It does not support mono/surround outputs, multi-stream interfaces, aggregate/multi-output setups, per-app mixing, convolution, or manual parametric filter editing. Bluetooth, USB hardware, sleep/wake behavior, protected media, and extended operation need further hardware testing. Intel is cross-compiled; runtime checks to date were performed on Apple silicon.

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

`DSP.c` implements RBJ peaking and Q-based shelf biquads, preamp, peak protection, and a bounded lock-free settings queue. The audio callback performs no allocation, locks, logging, filesystem access, or Swift/Objective-C calls.

Tests cover measured frequency response, channel isolation, preamp/bypass, sample rates, clipping protection, buffer layouts, invalid controls, peaking/shelf response, AutoEQ validation and precision, saved-settings migration, and startup device selection. Native launch, import, saved-profile reload, and automatic startup have also been checked on Apple silicon.

[Apple Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) · [AutoEQ](https://github.com/jaakkopasanen/AutoEq) · [Icon provenance](docs/ICON.md)

## About

Created by **Nikolay Ostroukhov**. The app includes an About window with version information, credits, license, and project links.

## License

MIT. See [LICENSE](LICENSE). Aural is an independent project and is not affiliated with Apple or AutoEQ.
