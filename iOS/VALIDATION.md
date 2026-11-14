# iOS development validation

## Baseline

The starting point is prototype build 12 on iPhone 17 Pro / iOS 27.0.1. The user confirmed audio and EQ after an immediate reconnect. Build 11 additionally passed repeated and rapid uninterrupted Spotify reconnects. Those reports and stored logs are recorded in `../prototypes/ios-route/VALIDATION.md` and `RECONNECT-REPRO.md`.

## Development app

Validation in progress. Do not interpret the prototype's results as proof of the new app's complete behavior.

| Gate | Status |
| --- | --- |
| Actual full-profile PCM through TCP, channel filters, trims, preamp | Passed under ASan/UBSan: measured L −17.00 / R −4.00 dB |
| Actual level-matched bypass PCM | Passed under ASan/UBSan: measured −9.00 dB on both channels |
| Invalid DSP updates retain the last configuration | Passed through rendered PCM |
| Production/preview source separation, protocol and entitlement configuration | Passed |
| Remaining route lifecycle suite | Passed complete host suite, including Debug/Release HAL withdrawal, real stream gating, receiver readiness and reconnect |
| Host model/persistence regression suite | Passed, including saved-preset updates, precision, undo/A-B, malformed imports and visible storage failures |
| Signed native build | Build 15 passed; strict signatures and compiled extension metadata verified |
| Native iPhone/iPad UI review | iPhone offline visual and exact-entry dismissal spot checks passed on 2026-10-13; full iPad, VoiceOver and device review pending |
| Installed and launched | Receiver build 14 + provider build 15 independently verified; real AutoEQ preset retained |
| Audible EQ/reconnect/background checks | Receiver 14 + corrected provider 15 passes Bose playback, metering, EQ/Bypass and uninterrupted reconnect. Background/interruption checks remain open |
| End-to-end latency and battery behavior | Not measured |

## Device check sequence

- Start at a low volume. Start EQ, play Spotify, and select Aural in Control Center.
- Apply a clearly audible EQ preset; compare Bypass. Confirm exact filter edits take effect only after Apply.
- Keep music playing; select Speaker, then Aural again. Check audio and Bypass.
- Lock the phone while playing and confirm audio continues. Pause for more than 90 seconds, then resume without preparing again.
- With headphones, verify Bluetooth/wired behavior separately; disconnect the physical output and confirm Aural stops rather than unexpectedly moving to the speaker.
- Test a real system interruption and its recovery recommendation.
- Save a preset, close/reopen the app, and verify exact values and favorites persist without automatically starting audio.

Diagnostics are available in Settings → Audio diagnostics. They contain counters and audio-session information; no recorded audio. Long-duration energy use and external end-to-end latency measurements remain separate from compilation, UI review and loopback DSP tests.

## Build 13 selection failure, 2026-10-10

The user first observed the picker returning to Bose QuietComfort headphones without an error alert. An unchanged-build speaker comparison also fails. This is not yet evidence that Bluetooth playback itself is unsupported.

The copied receiver report shows the headphone output active at 48 kHz, 12,600,000 rendered frames, zero received frames, zero connections, and no DSP, format, protocol or socket errors. The stored 20:37–20:47 audio-system export independently captures eleven route-selection failures: endpoint lookup misses, followed by `kMRMediaRemoteFrameworkErrorDomain` code 28 after approximately two seconds. It records zero extension activation requests and none of the earlier `MDE fallback` policy markers. Discovery exposes the new `Aural` name while the persisted endpoint cache also loads the old `Aural Route Probe` name for the same UUID. A separate physical-output loss at 20:44 stops the receiver; selection failures precede that event, so it is not the original cause.

Build 14 tests a one-time identity migration for the renamed production route: `41555241-4C49-4F53-A000-000000000001`, kept constant across future launches and reconnects. The diagnostic target retains its original identity. Production discovery attempts to retire the replaced probe through Apple's documented `lostDevice(_:)` API before reporting the current endpoint. Discovery and HAL now share the bundle's display name. The protocol entitlement, app identifiers, saved profiles, receiver session options and tested HAL withdrawal lifecycle remain the same. Reports include build, port types, route transitions and interruption context.

### Build 14 result — both route identities fail before activation

Both signed apps compiled, installed and launched, and their entitlements and configured device identity were verified. The user reports that EQ and Bypass make no audible difference. A captured output-picker screenshot shows Jade Jukebox selected and **two Aural entries**. The migration therefore has not demonstrated successful retirement of the old entry or repaired selection.

The copied build 14 report has status “Select Aural in Control Center,” a physical `BluetoothA2DPOutput` at 48 kHz, zero connections, zero received frames and silent input/output meters, despite ten DSP sections with bypass disabled. Its counters cover the current receiver run beginning at 21:04:06 EDT; an earlier run was stopped at 21:04:04, so these counters alone do not describe every preceding selection. The retained event history has no successful connection.

The subsequent stored export independently captures eight failures between 21:02:51 and 21:03:59 EDT: **four selections of the original UUID and four of the new UUID**. All fail endpoint lookup with MediaRemote code 28, before any extension activation request. Extension PID 2297 explicitly logs build 14 and the new UUID. Each discovery invokes prototype retirement and then reports the new route, but iOS continues to expose both entries. Thus the new identity does not resolve the failure; this is not evidence of a DSP or Bluetooth-format fault. The export has 41,144 valid JSON records with no malformed lines. The detailed selection summary and SHA-256 are retained privately alongside the export.

### Original-provider comparison — Bluetooth audio and EQ passed

The preserved, signed **build 12 route provider** was reinstalled without rebuilding it, then launched with the unchanged **build 14 Aural receiver**. CoreDevice independently verifies those two installed versions. The provider's strict signature and approved media-device protocol entitlement pass. This comparison preserves the new editor, saved presets, receiver session and DSP, while restoring the provider that previously passed audible speaker reconnect checks. The temporary route name is **Aural Route Probe**. The user reports “Connects; meter moves; EQ works” through the Bose headphones. This establishes working Bluetooth playback and EQ with the new receiver and original provider. The user then confirms “Reconnect and EQ work” after switching Jade Jukebox → Aural Route Probe with Spotify left playing. It does not prove which provider metadata field caused the selection regression, or that every type of headphone works.

The offline simulator interaction run was interrupted when the Mac ran low on storage; it is not a UI test pass. The simulator is shut down. Only the task's disposable compiler module caches were removed, recovering working space; source, app data and device evidence were retained.

Private evidence is retained in `/Volumes/DevBackup/Aural-Development/ios-route/headphone-evidence-2026-10-10/`: `aural-bose-report-build13.txt`, `aural-bose-build13-20261010-2047.ndjson`, and the export script. Raw logs are not intended for publication.


### Build 15 — preserve protocol metadata and route identity

The provider comparison motivates a targeted metadata correction: restore the original route UUID and exported `UTTypeDescription` while retaining **Aural** as the discovery and HAL display name. Remove build 14's ineffective identity migration. The exported protocol declaration is now identical in both targets, and configuration regression checks enforce that identity/metadata contract separately from branding. No transport, session options, DSP or HAL teardown behavior changes. The production configuration check is now part of the standard iOS host test command. Configuration checks for both targets pass, and the signed native build succeeds. Strict signatures for both apps pass; the embedded extension independently verifies build 15, the original UUID, the original protocol description, the Aural display name, the loopback endpoint and the authorized entitlement. Only provider build 15 was installed; the receiver remains build 14. CoreDevice verifies both versions and successful launches. The user subsequently confirms “Both selections and EQ work” for the first selection and one Jade Jukebox → Aural reconnect with Spotify left playing, including input metering and Bypass. This validates the corrected provider with the Bose QuietComfort headphones on the tested iPhone 17 Pro / iOS 27.0.1. The already-passing DSP and transport suites were not rerun because those implementations are unchanged.


### Build 15 conclusion and limits

The selection regression is resolved for the tested Bose configuration. Preserve the original protocol declaration and device UUID while keeping the user-visible route name separate. The successful build uses the new Aural name; a new UUID alone had failed in build 14. No Bluetooth session flags, audio transport, DSP or reconnect timing workaround was required. Configuration regression checks now guard this compatibility contract.

Physical audio, EQ and uninterrupted reconnect are established by the user's report. A post-test CoreDevice inventory independently locates extension PID 2452 in the verified build 15 installation, with receiver PID 2391 and provider PID 2455. This snapshot does not independently count frames or prove process retention across the whole test. No new stored audio-system export was requested after success. Duplicate-picker-entry cleanup was not separately confirmed. Wired/USB outputs, prolonged background operation, interruptions, battery and end-to-end latency remain separate validation items; no claim of universal headphone compatibility or release readiness is made.


## Paused at the user's request — 2026-10-10

The user shelved the remaining iOS plan and will explicitly return when ready. Stop implementation and testing until then. Leave the working iPhone installation intact: receiver build 14 and provider build 15, with Bose playback, EQ/Bypass and uninterrupted reconnect confirmed. No background-playback or long-pause result was obtained; the user canceled that check when pausing.

Remaining work: iPhone/iPad UI review (landscape, side panel, large text, VoiceOver, reduced transparency, keyboard and exact-value editing), preset persistence on the real device, background/locked playback and long pauses, interruption and headphone-disconnect behavior, dropout/latency/battery measurements. The offline preview was booted again for review, but DeviceHub accessibility timed out and no completed UI review resulted. Its install/launch task was stopped and simulator shutdown was requested for the pause; preserve simulator data. The installed iPhone apps were not changed during this resumed UI-check attempt.

## Visual refresh — 2026-10-13

The user requested a more expressive interface, resuming visual work only. The equalizer now gives the current preset and actual response curve one prominent panel, with adaptive cyan/violet surfaces, a shaded response relative to 0 dB, a restrained glow, rounded typography, clearer exact-value buttons and numbered filters. Headphone discovery and preset rows share the same visual language. Liquid Glass remains the default for navigation and floating controls; the connection panel is capped at 640 points on wider layouts. Larger accessibility text stacks action rows, and increased contrast/reduced transparency remove decorative translucency where needed. No audio model, DSP, transport, route identity, protocol declaration, or entitlement was changed.

Validation for this change:

- The final AuralPreview simulator build and signed Aural/AuralRoute device build pass with Xcode 27. Strict signature verification of both device bundles passes with access to the Mac's certificate trust settings.
- Configuration checks pass, including the original protocol and device identity and production/preview separation. Source whitespace checks pass.
- The offline iPhone 16 Pro / iOS 26.5 preview was inspected in light and dark appearances. Equalizer and Presets captures are in `Design/`. These are actual native screens with the Warm test fixture; the preview does not receive audio.
- Accessibility Medium text and Increase Contrast were inspected on Equalizer and Presets: controls stack, long labels wrap, and the graph/panel fallbacks remain legible. This is a spot check, not a complete VoiceOver or all-text-sizes audit.
- The connection guide opens and dismisses. Exact preamp entry displays `-7.123456` without rounding; dismissing that draft leaves the active preamp at `-5.0` and the graph at its original response. This does not claim an Apply-button or full filter-workspace interaction pass.
- Device Hub's accessibility actions work, but coordinate actions repeatedly fail. Settings-tab interaction, landscape and actual iPad review remain open. The original simulator appearance, text size and contrast are restored, and the simulator is shut down after the captures.

No new app was installed on the physical iPhone. The prior background, interruption, headphone-disconnect, persistence, latency and battery checks remain outstanding. This visual refresh is not a new physical audio-validation result.
