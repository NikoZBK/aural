# Per-app volume control — implementation proposal

Updated October 26, 2026. The routing prototype's selected-output reader and verified helper grouping are now integrated locally with the production EQ engine, independent preference store, route coordinator, and accessible Apps window. The user approved clearly labeled experimental Safari support; its undocumented attribution API remains an explicit compatibility limitation. The full regression suite passes. Native integration acceptance and release checks are tracked in [integration results](PER-APP-VOLUME-INTEGRATION.md); earlier Bose, FiiO reconnect, and browser-helper evidence remains separately recorded in [prototype results](PER-APP-VOLUME-PROTOTYPE.md).

## Goal and first-version scope

Add a practical app mixer for audio playing through Aural's selected stereo output. Retain macOS 14.2 support, the existing global EQ, and the current driverless installation model.

- One row per identified application: icon, name, volume from 0–100%, mute, and reset to 100%/unmuted. Default settings reproduce today's sound. No gain above unity in the first version.
- A mute switch remembers the app's chosen level; unmuting restores that level with a short gain ramp.
- Group verified helper processes under their owning app. Browser tabs are controlled together as their browser; separate tab controls are outside this version.
- Remember levels and mute by stable app identity across relaunches and output changes. Mixer preferences are global app preferences, separate from output EQ profiles, presets, A/B, and EQ undo history.
- Keep quiet remembered apps accessible without continually reordering rows as playback starts and stops. Explicitly label audio that cannot be attributed to an app; never guess an owner from a process name.
- Limit controls to eligible audio on the selected output. Other outputs, microphones, and unsupported/protected streams are not represented as successfully controlled.
- Preserve selected-output-only control during recovery, as explicitly confirmed in the October 25 hardware check. Keep the selected-device standby reader alive across playback teardown; do not substitute an app-wide mute across other outputs.

## Processing and lifecycle contract

Proposed signal flow:

```text
App A audio ── smoothed volume/mute ─┐
App B audio ── smoothed volume/mute ─┼─ sum ─ existing global EQ/stereo/limiter ─ selected output
Other audio ── unchanged gain ───────┘
```

The integrated routing design uses eight fixed app taps and an explicit remaining-process tap with disjoint replay sets. An independently consumed selected-output protection tap suppresses direct playback while ownership is established; its samples are never replayed. One private playback aggregate and output clock feed a bounded C mixer into the existing EQ engine. A separate input-only guard reader survives playback teardown during reconnect. No app-wide control is applied to other outputs.

Apple exposes process-specific and excluding-process tap descriptions, and supports taps as aggregate inputs. This establishes an API path, not proof that seamless live repartitioning works for every device. Phase 1 must validate it before committing the production architecture. See [Apple's tap sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) and [CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription).

- **Bypass EQ** keeps app levels and mute active while retaining existing EQ/stereo bypass and peak-protection behavior.
- The single **Start/Stop** control owns the audio route. Stopped controls show remembered values as inactive; starting applies them. Stopping or quitting releases every tap and returns audio to macOS control, so app attenuation/mute no longer applies. Update status wording and help consistently, without introducing an independent mixer start state.
- Opening the mixer never starts processing. Preset application, output following, startup, sleep/wake, and reconnect continue through the existing lifecycle coordinator.
- App preferences must not enter preset exports, AutoEQ imports, A/B comparisons, or EQ history. Auto preamp and response curves remain calculations of the global EQ; app volume does not change their inputs.
- A route failure must surface a truthful inactive/error state and attempt all cleanup. Preserve uncertain callback contexts until callback removal is confirmed. Do not report a saved mute as applied after processing stops.

## Phase 1 — prove capture, ownership, and live handoff

Work in an isolated diagnostic using disposable settings before changing the production callback.

1. Enumerate Core Audio process objects, active output devices, and application identities. Verify Spotify and browser helper grouping, process termination/relaunch, and PID reuse. Keep ambiguous processes distinct and unmodified.
2. Capture two independently identifiable sources and the remaining system audio into one aggregate. Validate each input's format, channel range, and ownership rather than relying on the current single-tap `inputStreams.last` assumption. Hardware input channels remain disabled.
3. At unity gain, compare the combined signal with today's global capture, accounting for alignment and existing processing latency. Check system alerts, stereo phase, clipping behavior, and source timing.
4. Exercise adding/removing an app and transferring ownership between an app tap and the remaining-audio tap. Measure gaps, duplication, feedback, and unintended direct playback. Do not assume multiple HAL property updates are atomic.
5. Measure resource scaling with active and idle apps. Decide which sources to retain and establish a tested bounded capacity, with explicit behavior at the limit. Topology work must remain outside volume gestures.

**Gate:** demonstrate independent attenuation, unity equivalence within defined numerical tolerances, no duplicate playback, and acceptable measured handoffs. If the proposed multi-tap design fails this gate, revise the routing design before building product UI; do not conceal the failure with repeated route restarts.

## Phase 2 — implement the real-time mixer

- Add a dedicated C mixer component ahead of the current DSP engine. Keep process discovery and HAL ownership in the macOS layer, not in the shared EQ filter code.
- Preallocate source maps, bounded mixing buffers, and gain state. Use the existing project's bounded control/audio handoff patterns, with explicit lifetime and generation tracking.
- Smooth gain and mute transitions over a short, measured ramp. A volume update changes only mixer gain state; it never recreates taps, rebuilds EQ coefficients, or schedules response analysis.
- Preserve global stereo effects, level matching, loudness, bypass, and final true-peak protection. Handle nonfinite samples and invalid/oversized buffers explicitly through the existing fault/reporting contract.
- Perform no allocation, locks, logging, file access, app lookup, or Swift/Objective-C work inside the audio callback.

**Gate:** offline summing, channel isolation, exact mute, gain-ramp, invalid-buffer, capacity, and rapid-update tests pass; unity behavior preserves the existing EQ tests.

## Phase 3 — integrate app discovery, state, and recovery

- Introduce a process catalog and an app-mixer store separate from the broadly observed EQ document. Resolve and cache names/icons outside the volume-edit path; coalesce process-list changes.
- Use process-object identities for live routing and validated persistent app identities for settings. Availability-gate macOS 26 bundle-ID/restoration APIs; the minimum supported OS retains a tested process-ID path.
- Serialize ownership changes and reject stale discovery/setup completions after Stop, output changes, or newer generations. Reuse the existing output-recovery policy rather than adding a competing restart loop.
- Migrate settings with neutral defaults. Apply gains immediately in memory, persist coalesced/final edits outside the gesture, and report save failures without claiming that values will survive relaunch. Mute/reset are persisted promptly without synchronous disk work on the slider path.
- Reconcile the existing uncommitted audio-recovery work as an explicit baseline before overlapping engine edits. Preserve it and the shelved iOS work; do not silently fold unrelated changes into the feature release.

**Gate:** app relaunch, helper churn, stale identifiers, output following, reconnect, sleep/wake, permission failure, partial setup, cleanup failure, and saved-state migration tests pass.

## Phase 4 — build the accessible mixer window

- Add a visible **Apps** button in the listening bar, a menu-bar entry, and a keyboard shortcut, all opening the same resizable mixer window. The filter inspector keeps its current space and placement behavior.
- Use Aural's glass styling, readable app rows, native keyboard-accessible sliders, an exact percentage field, mute, and reset. Provide clear playing/quiet/stopped/error states and a remembered-app section.
- Keep row identity and sorting stable during interaction. Apply existing precision-field submission rules and accessibility patterns. Validate minimum window sizes, 80–140% zoom, dark/light appearance, Increase Contrast, and Reduce Transparency.
- Meter/activity updates observe only the affected rows and are bounded while visible. They must not publish EQ-document changes or resize the global graph.

**Gate:** a person can open Apps and adjust Spotify while another app plays, using pointer, keyboard, or VoiceOver; controls remain readable at minimum size and existing EQ edits retain focus and precision.

## Phase 5 — validate and deliver

- Extend the custom test/benchmark scripts to compile and exercise the mixer component; run the complete suite and universal build against the exact release scope.
- Audit mixer drags, simultaneous EQ editing, process churn, and meter activity against the existing 10/31/64-filter baseline. Assert zero EQ-document publications and response-analysis requests caused by app-volume changes. Record UI median/p95/max and audio callback deadline margin; report spikes rather than promising universal zero stalls.
- Test Spotify plus Safari/Chrome, a call app's output, system sounds, rapid mute/unmute, app quit/relaunch, and Stop/Quit restoration. Cover built-in speakers, the Bose Bluetooth headphones, a USB output when available, sample-rate changes, and sleep/wake. Keep physical hardware evidence separate from automated tests.
- Present a local preview and hardware findings for review. Commit/push and publish only after the implementation is approved; retain the normal app's signed updater identity and verify the production updater independently of the separate preview.

## Main implementation surfaces

| Surface | Expected work |
| --- | --- |
| `Audio.swift` | Multiple tap ownership, validated source mapping, aggregate lifecycle and complete cleanup |
| New process catalog/identity resolver | Core Audio discovery, helper grouping, stale-object handling and cached metadata |
| New mixer C component and bridge | Bounded summing, smoothed gains, callback ownership and faults |
| New app-mixer store/settings types | Independent observation, persistence, migration and applied-versus-saved state |
| `Model.swift` | Shared route lifecycle and existing startup/output/recovery integration |
| `MainView.swift`, `Aural.swift`, new mixer view | Apps entry points, window registration, status/help and accessibility |
| Tests and build/benchmark scripts | DSP, routing, state, native controls, performance and linking |
| User/release documentation | Mixer behavior, Stop/Bypass distinction, compatibility and verified limits |

Per-app EQ, per-app output routing, positive volume boost, preset automation, plug-in hosting, spectrum analysis, and iOS remain outside this first feature.
