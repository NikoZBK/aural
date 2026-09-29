# Aural 0.9.1

- Replaced the EQ paw app icon with an 8-bit dog wearing lime headphones. The app and About window use the new icon; the menu bar uses a compact headphones symbol.
- Attached Refresh directly to the output picker beneath “Listening on,” removing its isolated position in the output strip. Short device names use their natural width, with a 320-point cap for long names.
- Updated icon documentation and removed the old paw description from About and README.

No audio engine, profile, or settings-format changes. The icon source and exact generation prompt are documented in [ICON.md](ICON.md).

Validation: generated and inspected icon sizes from 16 to 1024 pixels. Universal build and strict signature checks passed. Native inspection confirmed the adjacent Refresh layout; macOS still returned the cached paw in the main window, addressed by explicit bundled-icon loading in 0.9.2.
