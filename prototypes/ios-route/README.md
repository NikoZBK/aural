# Aural iOS audio-route prototype

This experiment tests whether another iPhone app's audio can pass through Aural's existing C equalizer and return to the speaker or headphones. **Spotify → Aural EQ → iPhone speaker works, including repeated reconnection while Spotify keeps playing.** Build 11's HAL device withdrawal passed the user's repeated playback/EQ checks and two quick reselections. The two stored exports independently capture **eleven reconnects** in the same extension process, including three with only **0.53–1.23 seconds** between StopIO and reactivation. The final connection continues for at least **588.7 seconds**, and the user confirms audio and EQ after the quick switches. Build **12** makes this tested lifecycle standard in Debug and Release and removes the experimental switch. The signed native build, host regression suite, installation and both app launches passed. The user then confirmed **audio returns and EQ works on build 12** after an immediate Speaker → Aural switch with Spotify still playing. Remaining reliability checks are recorded in [VALIDATION.md](VALIDATION.md#build-12--standard-hal-device-withdrawal).

The change withdraws the stopped HAL device from the plug-in's device list and notifies the host; the next registration exposes the same stable device again. It does not pause Spotify or add a delay. Build 10 failed on both iOS 27.0 and 27.0.1. See [RECONNECT-REPRO.md](RECONNECT-REPRO.md) for the comparisons and limits of the evidence.

The test device is **iPhone 17 Pro**, originally on **iOS 27.0 (24A437)** and now verified on **27.0.1 (24A446)**, with Developer Mode enabled. This Mac has **Xcode 27.0 (27A266a)** on DevBackup, with first-run setup complete. The protocol is registered and assigned to both provider targets, and signed entitlements/profiles have been verified. The first report contains about **122 seconds of received audio**, no dropped frames and **48 underrun frames (1 ms)**; see [VALIDATION.md](VALIDATION.md) for the evidence and remaining checks.

The reconnect investigation and diagnostic controls are collected in [RECONNECT-REPRO.md](RECONNECT-REPRO.md).

## Architecture and the key restriction

```text
Music app → system output picker → Aural Route Provider's extension
                                      │ float32 stereo / 48 kHz
                                      │ TCP on 127.0.0.1:47103
                                      ▼
                              Aural Route Test app
                              bounded queue → Aural DSP
                              → AVAudioEngine → physical output
```

There are two installable apps and one embedded extension:

- **AuralRouteProvider** only delivers the extension and shows setup instructions.
- **AuralRouteExtension** advertises **Aural Route Probe**, publishes a single output audio driver and sends PCM to the local receiver.
- **AuralRouteTest** hosts the audio session, EQ, bypass and diagnostics. It does not embed the extension or hold its entitlement.

Apple's [media-device entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.media-device-extension) requires the actual protocol identifier in both the extension and its containing app, and restricts the container to extension delivery. Both provider targets use the same nonempty entitlement. This prototype does not use an empty entitlement array to obtain playback in that container.

The [Media Device API](https://developer.apple.com/documentation/mediadevice/creating-a-media-device-extension) is intended for playback devices. **Whether a separate receiver on the same phone is permitted and reliable remains the experiment**, not an established platform guarantee. A successful test also does not establish App Store eligibility or a supported single-app product architecture.

## Build and install

1. Install **Xcode 27 or newer**, including iOS platform support, and open it once to finish setup. Set the active developer directory to that Xcode in its Settings → Locations, or export `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` in the shell. No global developer-directory change is made by the prototype scripts.
2. Open **AuralRoutePrototype.xcodeproj** in this directory. The generated project and shared schemes are checked in; XcodeGen is not required to open or build it.
3. Select your Apple Developer Program team for all three targets. The provider app and extension need the **Media Device Sharing Extension** capability and profiles authorizing `media-device-protocol.local.aural.route-probe`. Verify availability in your developer account; ordinary personal-team signing is not assumed sufficient. A missing entitlement/profile is a real blocker, not a reason to remove the key.
4. Use unique bundle identifiers if the provided development IDs are unavailable. Keep the extension bundle identifier underneath the provider's. If you change the protocol identifier, change both entitlement files, `Configuration/Extension.plist` and `Extension/RouteExtension.swift` together. Keep the route UUID and description stable during the test series.
5. Connect and trust the iPhone, enable Developer Mode when requested, and select it as the run destination.
6. Run the **AuralRouteProvider** scheme once to install the provider and embedded extension.
7. Run the **AuralRouteTest** scheme to install and launch the receiver. Building both apps does not install both; step 6 is necessary.

For an unsigned device compilation check, from the repository root:

```sh
bash prototypes/ios-route/scripts/build.sh
```

After provisioning the targets, a signed build can use:

```sh
TEAM_ID=YOUR_TEAM_ID bash prototypes/ios-route/scripts/build.sh --signed
```

The script does not register identifiers, download profiles, install an app, publish a release, or modify the Mac app. Build products go to `.build/ios-route/xcode` by default. Set `DERIVED_DATA_PATH` to keep build products and module caches on another disk. For the Xcode installation on this Mac:

```sh
DEVELOPER_DIR=/Volumes/DevBackup/Applications/Xcode.app/Contents/Developer \
DERIVED_DATA_PATH=/Volumes/DevBackup/Aural-Development/ios-route/DerivedData \
bash prototypes/ios-route/scripts/build.sh
```

Keep DevBackup mounted when using that toolchain, build directory or this phone's debugging symbols; the symbols were also moved there with checksum verification and a compatibility symlink. The build script limits Xcode to one job and requests Swift `-j1` to reduce memory pressure. The generated Swift command also includes `-j8`, so fully serialized Swift compilation has not been established. External build storage does not move macOS's memory swap files, so internal free space still matters. Use Xcode to manage signing and installation.

Build 12 always withdraws the stopped HAL device before republication. No build setting or user-facing switch is needed. The former build 11 `AURAL_DIAGNOSTIC_WITHDRAW_HAL_ON_STOP` option has been removed. The route identity, normal EQ receiver and public publication callback are preserved. Longer background playback, interruptions and additional physical outputs remain separate reliability checks.

## First audible test

1. Choose the iPhone speaker or headphones and use a low listening volume.
2. Open **Aural Route Test** and tap **Prepare receiver**. The microphone permission is for the prototype's `playAndRecord` session category; no input node is connected and no microphone samples are read or stored. It allows the receiving player to attempt an independent, mixing output session. Denial is shown as an error.
3. Play Spotify and select **Aural Route Probe** in Control Center's audio output picker. For the reconnect test, keep Spotify playing, switch to the normal physical output, then select Aural again. Apple Music remains a separate unverified test.
4. Return to the test app. Look for **Receiving audio**, a rising received-frame count, and nonzero input/output meters. A connected socket alone does not count as audio success.
5. Use **Set 1 kHz test filter**. The sound should be muffled. **Bypass EQ** should restore the treble while the route remains connected. Peak protection stays on in both states; bypass retains the DSP's look-ahead latency.
6. Use **Share test report** to save diagnostics. This exports text metrics and event timestamps, never PCM or track metadata.
7. Select the normal physical output in Control Center, then tap **Stop test**. Stop closes the receiver; it cannot choose the global output on the user's behalf.

If no audio frames arrive for 90 seconds, the receiver stops instead of keeping an idle audio session alive indefinitely. Opening the output picker must happen within that setup window.

## Silent routing diagnostic

A Debug-only launch argument, `--transport-only-diagnostic`, selects a foreground transport sink. It validates and counts frames without activating an audio session or creating the EQ/audio renderer; silence is expected while Aural is selected. This isolates same-phone playback from the routing failure. Play Spotify on Speaker, open the receiver, prepare it, and open Control Center from the receiver. Select Aural, then Speaker and Aural again while Spotify keeps playing. Judge route retention and rising counters, not sound. Leaving the app for another app or locking the phone stops this control explicitly. A regular launch without the argument restores the normal EQ test.

Only receiver builds **7** and **8** were installed for the isolation controls; provider/extension build **6** and its existing process remained in use. Both the silent transport-only receiver and the independent AVAudioPlayer source reproduced the same failure. In the native-source control, the system rejected Aural’s own source bundle before its internal audio-routing object became ready. Spotify and active receiver playback are therefore not necessary for the reproduction. See the [reproduction record](RECONNECT-REPRO.md) for timestamps and limits of this conclusion.

## Device test record

Record exact iOS build, Xcode version, signing/capability outcome, source app version, output device, test duration and the exported report. **Signing, installation, first launch and the first audible Spotify/speaker test passed on 2026-10-10.** Paused-source reconnects also passed the user checks; broader audio acceptance remains outstanding.

| Test | Evidence required |
| --- | --- |
| Entitlement and provisioning — passed | Both provider targets' signatures and profiles contain the correct protocol. Receiver has no media-device entitlement; all profiles authorize the test phone. |
| Installation and first launch — passed | Both apps installed and launched on iPhone 17 Pro / iOS 27.0 (24A437). Receiver starts ready for preparation. |
| First connection / Spotify / speaker — passed | Spotify 9.1.90 (919002269), about 122 seconds of received audio, nonzero signal and user-confirmed low-pass/bypass difference. No dropped frames or protocol/render/DSP errors; 48 underrun frames. See the saved report in VALIDATION.md. |
| Apple Music — not run | Route appears, frames and signal arrive, low-pass/bypass are audibly different. Record whether protected content routes. |
| Spotify Canvas — not run | Repeat with Canvas disabled and enabled; distinguish routing failure from silent input. Canvas state and content protection were not recorded for the first test. |
| AirPods / wired / USB | Correct physical output and stereo; inspect actual rate, drops and underruns. |
| Sample-rate conversion | A non-48 kHz output keeps pitch and duration. The source stays at 48 kHz and the engine mixer performs conversion; this needs device verification. |
| Screen locked / background | At least 15 minutes of uninterrupted playback, then inspect counters and report. |
| Stop / start and route switching — partial | Pausing Spotify before selection, waiting five seconds and resuming restored audio/EQ in the same build 3 extension process; the user confirmed the initial control and two repeats. Playing reconnects still fail. Ten connect/disconnect cycles and uninterrupted-playback reconnects remain open; see RECONNECT-REPRO.md. |
| Phone call / Siri | Interruption stops playback; resume only when the OS permits and the user had not stopped. Reselect the route if necessary. |
| Headphone removal | Test stops rather than unexpectedly sending headphone audio to the speaker. Restart is explicit. |
| Receiver killed / provider removed | System output recovers or the failure is recorded. No residual loud feedback or permanent route selection. |
| Latency | Measure input-to-output externally; UI buffer durations and DSP timing are not end-to-end latency. |
| Battery | Compare equal-duration playback with and without the route under the same volume, output and screen conditions. |

**Do not proceed to a full UI port on one successful song.** Confirm usable repeat connections, background playback and interruption handling, then resolve the supported distribution/product architecture.

## Implementation limits

- Stereo float32 at 48 kHz, one source route and one local receiver. Normal mode has no external network listener, file recording, preset import or microphone processing. The separate Debug network control below uses a temporary Mac listener.
- Sender and receiver each use a 16,384-frame SPSC queue. The consumer owns its read index; overflow rejects new samples rather than racing unread data. Each rejection and active-render underrun is counted. Receiver preroll is 2,048 frames (about 43 ms). This is intentionally a measurable first path, not a low-latency claim.
- Socket work and framing run on a serial worker queue. Both audio callbacks stay in C. No Swift/Objective-C message sends, locks, networking or allocation occur in the sample transfer/render functions.
- TCP framing checks version, channel count, sample rate and bounded frame count. Partial reads/writes preserve byte offsets. Invalid framing disconnects the peer. Queues and protocol state are cleared at connection boundaries.
- Physical outputs are restricted to speaker, wired headphones, A2DP and USB for the first test. A receiver routed to an extension or another unsupported output stops to prevent a feedback loop. AirPlay, receiver earpiece and HFP are outside this prototype.
- Driver registration has no documented unregister counterpart. The prototype stops forwarding on deactivation and lets the system own the extension process. It neither registers a NULL driver nor forcibly exits/restarts the extension. Publication follows `startRealtimeSampleDelivery(session:)`, as specified by [Apple's streaming instructions](https://developer.apple.com/documentation/mediadevice/creating-a-media-device-extension), and ignores interruption callbacks from older publications. Reconnecting while Spotify plays fails after about 1.5 seconds; reconnecting while paused works in the same process. Five seconds is the tested manual wait, not a guaranteed minimum or a supported readiness API. See [RECONNECT-REPRO.md](RECONNECT-REPRO.md) for the policy timing and controls.
- There is no claim of systemwide coverage for every app, video, DRM-protected stream or call. Upstream experiments report video-related route failures. Keep these cases in the device record.
- The localhost connection is an isolated development probe with one expected peer and strict framing, not a production authenticated transport. A production design would need explicit peer authentication and lifecycle review.

## Local verification

```sh
bash prototypes/ios-route/scripts/test.sh          # deterministic core + host syntax/config checks
bash prototypes/ios-route/scripts/test.sh --sockets # adds actual localhost transport → DSP → renderer
bash prototypes/ios-route/scripts/check-receiver-apis.sh # optional macOS 27/Catalyst API check
```

The socket test needs permission to bind localhost when run under a restricted agent sandbox. It does not activate the Mac's audio session or play sound.

Local coverage includes repeated driver-publication state, stale interruption callbacks, interruption during publication, registration failure, ring overflow/wrap/concurrency, every packet split boundary, malformed headers, stereo preservation, real loopback transport through Aural DSP, bypass, underrun accounting, muted rendering, disconnection and transport restart. It uses AddressSanitizer and UndefinedBehaviorSanitizer. Host Objective-C checks, Catalyst API type-checking and Swift parsing **do not replace an iPhoneOS build**. See [VALIDATION.md](VALIDATION.md) for the checks actually completed.

The only changes to the shared Mac DSP are platform-specific guards around the two macOS HAL helpers and a portable audio-types import. Filter arithmetic and the existing Mac route remain unchanged. Existing DSP, engine, response, state and Swift/C bridge regression tests should pass before this work is merged.

Regenerate the committed project after changing target membership with XcodeGen 2.46.0:

```sh
xcodegen generate --spec prototypes/ios-route/project.yml
```

## Provenance

The HAL property implementation in `Extension/RouteDriver.m` was adapted from [ios27-media-device-passthrough](https://github.com/satomasahiro2005/ios27-media-device-passthrough), commit `0ed6091ec6e82d5aa9fb4320bef7a083260f6a0f`, copyright 2026 nemut.ai, MIT-0. The license is retained in `ThirdParty/LICENSE-MIT-0.txt`. Aural supplies its existing DSP; the bounded transport, receiver and test harness are local prototype code. The upstream empty-container-entitlement and forced-process-exit approaches are not used here.

## External receiver diagnostic (build 9)

This control tests the same route driver against a receiver on another device. It is diagnostic only, not a reconnect fix. The default build remains loopback. For a Debug build, set `AURAL_DIAGNOSTIC_RECEIVER_IPV4` to the Mac’s numeric private IPv4 address. The extension reads that value once and uses the identical endpoint in discovery and the transport. Release builds ignore the override. Invalid addresses fail explicitly; only loopback and RFC1918 unicast hosts are accepted.

Run `bash prototypes/ios-route/scripts/network-sink.sh <Mac-private-IPv4> 900` on the Mac. It binds only that address, validates and discards PCM without playback or recording, logs counters, and closes after the bounded duration or SIGINT/SIGTERM. Keep both devices on the same trusted local network. Launch the receiver app with `--network-source-diagnostic`; its explicit Start button plays the quiet reference tone, but it does not start an iPhone transport receiver.

Installing the diagnostic provider replaces its process, so a first success alone is insufficient: test two reconnects while the source keeps playing, keeping the same device ID and provider process. Rebuild/reinstall the provider with the empty default override and launch the receiver without diagnostic arguments to restore the regular EQ test. Host and signed native validation passed. The physical control reproduced the failure: the first selection worked, then both captured reconnects returned to Speaker, each after delivering 53,248 frames to the Mac with zero transport/protocol errors or drops. See [RECONNECT-REPRO.md](RECONNECT-REPRO.md#external-receiver-control) for the timing evidence. The Mac listener was stopped, Block all incoming connections restored, and its temporary firewall exception removed. The provider was rebuilt and reinstalled with the empty loopback override; the receiver was launched normally without diagnostic arguments. Seamless reconnection remains unresolved.


Build **10** corrects the HAL stream active property and logs stream changes and I/O client counts. Host regressions and signed iPhone validation pass, and the installed phone exercises the corrected setter. The physical test still reports **first works; reconnect fails**. Driver stop/start accounting is balanced; iOS selects fallback before requesting the new driver publication. See [the driver control record](RECONNECT-REPRO.md#driver-stream-state-control). The normal loopback/EQ build 10 remains installed.

## Retaining device routing evidence

Live Console can discard earlier events, and its streaming view showed duplicate-looking entries in the reboot control. Prefer a bounded stored-log export for timing comparisons:

```sh
bash prototypes/ios-route/scripts/capture-route-logs.sh DEVICE_UDID \
  'YYYY-MM-DD HH:MM:SS-0400' 'YYYY-MM-DD HH:MM:SS-0400' /path/to/new-output-base
python3 prototypes/ios-route/scripts/route-events.py /path/to/new-output-base.ndjson
```

The first command prompts for local administrator authentication, reads only Aural and relevant system-routing events, and saves them locally. It does not restart applications, record PCM, change settings or upload data. Existing outputs are never overwritten. Collection starts at the specified time with a 30 MB limit; the NDJSON view also applies the end time.

The analyzer exits **1** when it captures a system fallback associated with Aural, or **2** when evidence is inconclusive/invalid. It deliberately has no automatic passing verdict: missing system markers cannot establish sustained audio or audible EQ. Saved Console accessibility text is supported with `--date YYYY-MM-DD`, but offscreen rows may be incomplete. Exact overlapping records are deduplicated; nearby timestamps are preserved. Run `python3 prototypes/ios-route/Tests/route_events.py` to check the analyzer. These checks validate diagnostic tooling, not the reconnect fix.
