# App mixer integration

Local development integration, October 26, 2026. This is not a published release. Earlier diagnostic-only hardware evidence remains in [prototype results](PER-APP-VOLUME-PROTOTYPE.md).

## Implemented

- **App volumes** in the rail's Output group, plus the Equalizer menu and menu-bar menu; **⇧⌘M** opens one resizable glass mixer window.
- Per-app 0–100% volume, exact input, separate mute, reset, cached icons, and activity. Quiet remembered apps remain accessible. Safari is visibly **Experimental**, as approved by the user; its helper attribution uses an undocumented responsibility query.
- A separate, versioned `app-mixer.json` preference store. Coalesced asynchronous saves and quit flushing report failures. Invalid files are preserved. Mixer edits never enter EQ presets, A/B, undo, AutoEQ, preamp, or response analysis.
- Eight fixed app lanes plus an explicit unity lane, summed by a bounded C mixer before the existing EQ/stereo/loudness/limiter engine. Gain changes use 20 ms ramps without rebuilding taps or EQ coefficients. A newly assigned lane receives its saved gain before accepting the source. Unknown possible muted helpers wait for attribution.
- A device-scoped input-only protection reader stays armed across playback teardown. The existing recovery coordinator resumes only on the saved output. Stop/Quit releases app control. Bypass retains app volume/mute. Compatible virtual outputs retain global EQ with app controls explicitly inactive.

## Verification

The full regression suite passed before the physical reconnect check. Follow-up lifecycle tests pass after fixing a real hot-unplug discovery race: HAL returned `who?` for an output stream removed during enumeration. Discovery now rechecks that device/stream has actually vanished before skipping it; a genuinely unsupported property and permission failures still propagate. Asynchronous expired-mixer errors use the same bounded recovery coordinator. A separate test caught and fixed delayed publication of the mixer's waiting status.

The C sanitizer checks cover nine-source summing at six rates, equivalence with the existing EQ/stereo/Bypass path, first-frame restored mute, gain ramps, peer isolation, meters, invalid buffers and nonfinite samples. Swift checks cover capacity, helper partitioning, unknown-helper quarantine, persistence, stale callbacks, attempted cleanup of all peers after one failure, retained failed resources, and removal of stale activity. Four hundred control edits produced zero EQ-document publications.

Native Apple-silicon checks on macOS 27.0.1, External Headphones at 48 kHz:

- The ten-input HAL topology starts, with unused app lanes remaining silent. A second owned source and Spotify join without a route restart.
- A 42% source measures 7.5 dB below 100%; muting both sources renders silence. EQ Bypass preserves mute.
- The user confirmed Spotify 100% → 50% → mute → 100% changes and restores music while an independent quiet tone continues.
- A clean Stop/Start restores Spotify's saved 42% and mute. The first physical reconnect exposed the discovery failure above; recovery acceptance is being repeated on the fixed build.

An optimized nine-input C workload with 64 EQ filters measured p95 50 µs for 128 frames at 48 kHz, and 48 µs at 192 kHz (deadlines 2,667/667 µs). Across the twelve block/rate/filter combinations, observed maxima remained below their deadlines. These are offline callback timings, not physical end-to-end latency.

The native UI audit with eight rows and activity updates measured median/p95/max 9.22/15.33/17.63 ms at 720 px and 7.24/10.97/34.31 ms at 480 px. It asserted zero EQ publications. The audit includes layout/display work, not GPU presentation timing; the maximum is reported rather than claiming zero possible stalls.

## Remaining acceptance

- Confirm no muted Spotify leakage on repeated physical FiiO reconnects after the discovery fix; verify unmute returns to the saved level.
- Recheck browser helper churn on the integrated production topology. Earlier Chrome/Safari helper replacements passed in the separate diagnostic, not this installed callback.
- Broader Bluetooth/USB, sleep/wake, sample-rate transitions, protected streams, and older supported macOS runtime coverage remain hardware limitations. Intel compilation does not establish Intel runtime behavior.
- Finish release compilation on the final source, local preview review, then signed packaging/update verification when publication is authorized. Universal volume and smart preset rules follow this mixer acceptance work.

Builds/tests here use the installed macOS 26.5 SDK. The current Command Line Tools default 27 SDK lacks the SwiftUI State macro plug-in needed by the existing app source; this toolchain issue is separate from the mixer.
