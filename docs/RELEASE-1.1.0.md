# Aural 1.1

- Added System, Light, and Dark themes using your macOS accent color throughout the app.
- Made Simple/Professional switching faster with startup preloading and loading blocks; improved analysis and metering responsiveness.
- Added visual EQ bars to both modes. Imported EQs show their existing frequencies and gains; drag, use arrow keys, or double-click a band to reset its gain.
- Added **Reset EQ** in both modes to zero gains and preamp while preserving other filter and stereo settings. Undo restores the previous EQ.
- Added draggable pane dividers and responsive layouts, with more Simple controls for output, preamp, balance, mono, width, headphone blend, and metering.
- Kept the **AURAL EQUALIZER** header consistent, aligned numeric column headings with their values, and removed the redundant Professional-mode notice from Simple.
- Preserved existing presets, settings, and imported precision. Switching modes and resizing panes keep the current sound unchanged.
- Passed all twelve regression suites and native UI checks on Apple silicon. Mode-switch measurements and test coverage are recorded in the [performance notes](https://github.com/NikoZBK/aural/blob/v1.1.0/docs/PERFORMANCE-BUILD-19.md).
- Requires macOS 14.2 or newer. The universal package supports Apple silicon and Intel; Intel is cross-compiled rather than runtime-tested. This release is ad-hoc signed and not notarized.

Packages: `Aural-1.1.0-universal.dmg`, `Aural-1.1.0-universal.zip`, and `SHA256SUMS.txt`. Quit Aural before replacing the app; saved settings and presets stay on your Mac.
