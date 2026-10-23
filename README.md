<p align="center">
  <img src="Resources/AppIcon.png" width="160" alt="Aural icon: a cyan EQ curve shaped like the letter A on a graphite grid">
</p>
<h1 align="center">Aural</h1>
<p align="center">A native macOS equalizer. Shape your sound, keep your settings local.</p>
<p align="center">
  <a href="https://github.com/NikoZBK/aural/releases/latest"><b>Download</b></a> · macOS 14.2 or later · Apple silicon and Intel
</p>

![Aural in Dark theme with Liquid Glass controls, a teal EQ curve, and all filter rows in a side panel](docs/design/desktop/dark-side-panel.png)

**Light theme.** The same workspace with pale glass, a teal response curve, and exact filter controls.

![Aural in Light theme with the selected filter inspector beside the EQ curve](docs/design/desktop/light-side-panel.png)

<sub>Native desktop previews of the 1.6 design on macOS 27, with processing stopped. Dashed purple shows the Harman reference; the solid curve shows EQ gain.</sub>

## Install

1. Open the DMG and drag **Aural** to **Applications**.
2. Launch Aural, choose your output, and click **Start EQ**. Allow system audio capture when macOS asks.

No audio driver is needed. Later versions install from **Check for Updates…**. If you're on 1.2.1 or earlier, install the latest version manually once.

## Features

- **Parametric and graphic EQ.** Up to 64 filters on the left, right, or both channels, or on mid or side: peak, shelf (12 or 6 dB/octave), low- and high-pass (6 to 48 dB/octave, Butterworth or Linkwitz-Riley), band-pass, notch, and all-pass, each with the same shape at every sample rate. Ten- and 31-band layouts; each ten-band slider sets the exact level at its frequency.
- **Edit on the curve.** Drag numbered points, type exact values, or use faders. Reorder filters from their action menus. A/B comparison and 100 steps of undo.
- **Fair comparisons.** Optional level matching plays Bypass and both A/B versions at the same estimated loudness.
- **AutoEQ built in.** Search the online headphone catalog, preview a correction, and import it. You can also paste or import Equalizer APO text.
- **Stereo and delay.** Balance, width, crossfeed, mono, polarity, a left/right swap, and up to 30 ms of delay.
- **Tilt.** One control brightens or darkens the whole EQ around 1 kHz.
- **Gain staging.** Preamp, Auto preamp, a peak-hold meter, and true-peak protection.
- **Loudness compensation.** Optional ISO 226 compensation keeps bass and treble full as you turn the volume down.
- **Presets.** A searchable library with favorites, curve previews, and backups. Each output remembers its own preset.
- **Follows your Mac.** Optionally switches with the macOS sound output. EQ resumes after sleep, a disconnect, or a sample-rate change.
- **At home on macOS.** System, Light, and Dark themes, native Liquid Glass where supported, and readable accessibility fallbacks. Move the filter panel beside the graph. Menu bar controls, interface zoom, and keyboard shortcuts.

## Privacy

Audio is processed in memory on your Mac. Aural collects no telemetry and uploads nothing. It only contacts GitHub when you check for updates or browse AutoEQ.

## Learn more

- [User guide](docs/USER-GUIDE.md): every control, file format, limitation, and build step
- [Feature comparison](docs/PEACE-FEATURE-ROADMAP.md) with Peace and Equalizer APO
- [Install, update, and removal](docs/INSTALL.txt)
- [Release notes for 1.7.0](docs/RELEASE-1.7.0.md) and [earlier versions](docs/USER-GUIDE.md#release-notes)

To build from source, run `bash scripts/test.sh && bash scripts/build.sh` with Command Line Tools or Xcode and the macOS 26 SDK or later.

## License

MIT. See [LICENSE](LICENSE). Created by **Nikolay Ostroukhov** with the help of AI tools, which assisted with the code, documentation, and app icon. Aural is an independent project and is not affiliated with Apple or AutoEQ.
