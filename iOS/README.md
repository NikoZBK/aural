# Aural for iOS

Native iPhone-first EQ, with an adaptive iPad layout. This is a development build for iOS 27, built around the route lifecycle verified in prototype builds 11–12. It is not an App Store release.

## Apps

- **Aural**: EQ, presets, AutoEQ, local settings, and physical audio output.
- **Aural Route**: installs the media-device extension that advertises **Aural** in Control Center. Keep both apps installed; everyday controls are in Aural.

The existing development bundle identifiers and registered media-device protocol are retained so this upgrades the prototype. The receiver does not hold the media-device entitlement. Both provider targets do. A single-app architecture and distribution eligibility remain separate investigations.

The production and diagnostic targets share the original fixed `AuralRouteDeviceIdentifier` and exported protocol declaration. Keep the protocol's identifier, description and route UUID stable across upgrades; the visible output name is separate. The extension's bundle display name supplies both discovery and HAL. Build 15 restores the original protocol description and UUID after the build 13–14 selection regression. With this provider and receiver build 14, Bose QuietComfort playback, EQ/Bypass and reconnect while Spotify keeps playing pass the physical check. See `VALIDATION.md` for evidence and remaining coverage.

## Listening

1. Start EQ in Aural at a low listening volume. Allow the audio-session permission. Aural does not connect a microphone input node or record microphone samples.
2. Play music in your music app and select Aural in Control Center's output picker.
3. Adjust EQ or apply a preset. Bypass keeps the connection open; peak protection is an independent setting.
4. Select your normal output before stopping Aural. Reconnecting does not require pausing music.

The app deliberately does not start a session on launch. The prototype's 90-second idle timeout is disabled in this target: pausing music does not discard a prepared session. Stop explicitly when finished. Interruption recovery follows the system's recommendation. A physical output disconnect stops processing and requires an explicit restart, rather than switching unexpectedly to the speaker.

## Editing and files

- Graphic sliders change the level at each band center using the same solver as the Mac app. Tap a numeric value for exact entry.
- Advanced editing starts from an equivalent parametric copy. Apply commits; Cancel preserves the original sound. The editor rejects stale drafts.
- All filter types, channel modes and supported slopes use the shared Mac profile model and DSP. Stereo, headroom, tilt, undo/redo, A/B, and estimated level matching use the same calculations.
- Preset selection starts the receiver and enables EQ. File/AutoEQ imports are previewed first and stop the receiver when applied. Library imports preserve existing names with numbered suffixes.
- JSON profiles and preset backups are compatible with the Mac model. Equalizer APO export reports unsupported features rather than dropping them.
- AutoEQ downloads are bounded, cancellable, attributed, and never applied by a delayed search response.
- Settings and presets are stored atomically in Application Support/Aural/library.json. Unreadable settings are preserved and reported; they are not silently overwritten. Save failures remain visible.

## Appearance

Native Liquid Glass is used for chrome and floating controls by default. Content uses readable surfaces over a tinted background. System/Light/Dark are independent of audio. The filter panel can move right when width permits; narrow windows and accessibility text sizes use a vertical layout. Native accessibility controls and solid high-contrast/reduced-transparency fallbacks are retained.

The current preset and its response share a prominent, tinted panel. The curve's glow and shaded departure from 0 dB use the actual cached EQ analysis, with no simulated spectrum or continuous animation. Cyan and violet accents carry through exact-value controls, preset rows, headphone discovery, and the compact floating connection panel. See `Design/` for native light and dark simulator captures.

## Source layout

- `App/`: SwiftUI screens and app control model.
- `Core/`: persisted library and validated file imports.
- `Provider/`: the small route installation companion.
- `../Sources/Aural/`: shared profile, import, preset, response and headroom code, referenced directly by the project.
- `../Sources/DSP/`: the shared C EQ engine.
- `../prototypes/ios-route/`: the single shared implementation of the proven extension, local transport and receiver lifecycle. Both projects compile these sources; the HAL withdrawal/republish fix has not been duplicated or replaced.
- `Preview/`: simulator-only audio boundary for UI review. It never receives or plays audio and reports this when Start is tapped. Not compiled into Aural.
- `Tests/`: host model tests with a control-boundary stub. Actual PCM/transport tests run against the real C renderer in the route suite.

## Build

Requires Xcode 27, XcodeGen, and the existing registered developer protocol for signed device builds.

```sh
xcodegen generate --spec iOS/project.yml
TEAM_ID=YOUR_TEAM bash iOS/scripts/build.sh --signed
```

`DEVELOPER_DIR`, `DERIVED_DATA_PATH`, `TMPDIR`, and `XCODEGEN` may be set for an external Xcode/build directory. Install both `Aural.app` and `AuralRoute.app`; the latter embeds its ExtensionKit extension.

The iOS icon is generated by `swift scripts/draw-icon.swift OUTPUT --ios`; its full-bleed opaque tile shares the Mac icon’s drawing code.

For UI-only previews, build scheme **AuralPreview** for an installed iOS 26+ simulator. It compiles the same SwiftUI screens and DSP analysis, with an explicitly offline audio boundary. This does not validate iOS 27 routing.

## Verification

```sh
bash iOS/scripts/test.sh
bash prototypes/ios-route/scripts/test.sh --sockets
```

The first tests grouped history, A/B, preset identity, collision-safe restores, exact profile round trips, stale edits, invalid input, and storage failures. The second uses ASan/UBSan and actual loopback PCM to check full-profile filtering, stereo trims, preamp, level-matched bypass, rejected updates, transport framing/restarts, and the HAL teardown lifecycle in Debug and Release.

Physical-device validation must additionally cover audible full-profile changes, reconnects while music plays, screen lock, long pauses, interruptions, output removal and background operation. Latency and battery measurements must be reported as measurements, not inferred from simulator or host tests. See `VALIDATION.md` for the current results.
