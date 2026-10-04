# Aural 1.2

- Added optional **Liquid Glass** using Apple's native macOS 26 SDK. Choose **Style → Liquid Glass** in Settings, View, or the headphones menu. Style is independent of System, Light, and Dark themes; Standard remains the default. Reduce Transparency and Increase Contrast keep solid surfaces, and older supported macOS versions retain the standard presentation.
- Reworked the main window into one expandable workspace with full-width EQ curves, a preset dropdown, and retained **Selected**, **All rows**, and **Faders** editors. **Show details / Hide details** preserves the current sound and saved disclosure preference.
- Added direct curve editing: select numbered filter points and drag frequency or gain with one-step undo. Exact values, filter type, Q, channel, enabled state, and imported precision stay intact.
- Added online AutoEQ headphone search with measurement-source filtering, correction previews, source attribution, and validated preset imports. Search stays local after loading the public catalog; downloading a profile never applies it without an import action.
- Added display-only Harman acoustic references with licensed source data and a clear distinction between reference response and applied EQ gain.
- Improved keyboard and accessibility support for curve inspection, faders, metering, focus, and error announcements. Hidden retained editors are excluded from pointer and accessibility navigation.
- Moved the headphone icon directly beside the audio-device dropdown. Appearance switches preserve numeric drafts, output selection, playback, bypass, and comparisons.
- Requires **macOS 14.2 or newer**. Native Liquid Glass requires **macOS 26 or newer**. The universal package includes Apple silicon and Intel executables; Intel is cross-compiled rather than runtime-tested. This release is **ad-hoc signed and not notarized**.

Packages: `Aural-1.2.0-universal.dmg`, `Aural-1.2.0-universal.zip`, and `SHA256SUMS.txt`. Quit Aural before replacing the app; saved settings and presets stay on your Mac. Bluetooth/USB recovery, sleep/wake, latency, extended audio sessions, and a complete VoiceOver speech pass remain separate hardware checks.
