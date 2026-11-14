# Audio route reverts to local output on reactivation

Status: **the targeted reconnect fix passes on installed build 12 with Spotify continuously playing and EQ working**. The user confirmed the final immediate Speaker → Aural check after the behavior became standard. The combined stored exports capture **eleven reconnects**, including three with **0.527018–1.229348 seconds** between StopIO and activation. All selections receive explicit Spotify allowances in the same retained extension; the final connection streams for at least **588.711 seconds**. The user confirms both requested quick tests passed with EQ. Build **12** promotes the tested teardown to normal behavior in Debug and Release and removes its switch. [Validation](VALIDATION.md#build-12--standard-hal-device-withdrawal) separates the extended build 11 log series from build 12 compilation/install checks and its final user-confirmed physical pass. This record does not establish an OS defect or an Apple-supported MediaDevice teardown contract.

The baseline below records builds 1–10, which failed during playback. The external-receiver control reproduced the failure with a native PCM source and separate Mac receiver. Build 10 failed after a full reboot and on both tested iOS versions. Pausing Spotify before selection and resuming after five seconds restored audio/EQ in the retained process, but pausing is not the intended workflow.

## Environment

- iPhone 17 Pro, initially iOS **27.0 (24A437)**, now verified on **27.0.1 (24A446)**; Developer Mode enabled. Timings below are from 27.0 unless explicitly labeled otherwise.
- Xcode **27.0 (27A266a)**, iPhoneOS 27 SDK; signed Debug / arm64.
- Spotify **9.1.90 (919002269)**, recorded during this day's device test; physical output iPhone Speaker.
- Paid development team; both provider targets have the registered media sharing protocol in their signatures and profiles. The separate receiver has no media-device entitlement.
- Protocol `media-device-protocol.local.aural.route-probe`; stable device UUID `41555241-4C52-4F55-A000-000000000001`.

## Implementation

The installation-only provider embeds a `MediaDeviceExtension` conforming to `RealtimeSampleHandling`. It advertises one audio-only device, a loopback endpoint at `127.0.0.1:47103`, and no simultaneous sessions. A separate receiver prepares a mixing `playAndRecord` audio session and uses an `AVAudioSourceNode` to play received stereo PCM through Aural's C DSP to the physical speaker. No microphone node is connected.

Build 3 sets the active session and reports `activatedDevice`, then publishes its single-output HAL driver from `startRealtimeSampleDelivery(session:)`, following [Apple's streaming instructions](https://developer.apple.com/documentation/mediadevice/creating-a-media-device-extension). The HAL device UID matches the advertised UUID, and its transport is `kAudioDeviceTransportTypeRemoteStreaming`. Registration uses the [public Core Audio registration API](https://developer.apple.com/documentation/coreaudio/audioserverpluginregistermediadeviceextension). Its interface and HAL state live for the extension process; it registers again for each delivery start. Generation-tagged atomic state prevents stale interruption callbacks from invalidating a newer registration.

Deactivation stops PCM forwarding and closes the sample transport. The app does not register a NULL driver, invoke private APIs or terminate the extension. The receiver starts a new transport/engine on explicit Stop/Prepare.

## Reproduce the baseline failure (withdrawal disabled)

1. Build and install both applications as described in [README.md](README.md#build-and-install), using a fresh extension process for the first connection. Keep the same installed provider throughout the check.
2. At low volume, open **Aural Route Test**, tap **Prepare receiver**, start Spotify, and select **Aural Route Probe** in Control Center's output picker.
3. Confirm rising received-frame counts and audible music. Set the 1 kHz test filter and compare **Bypass EQ**: the filter muffles the music; bypass restores treble.
4. Keep the receiver and Spotify playback running. Select **iPhone Speaker**, then select **Aural Route Probe** again.
5. Observe the **Unable to Connect** alert. Preserve filtered device Console events for subsystem `local.aural.route-probe` and system messages mentioning `Aural Route Probe`.

Expected: the second selection resumes sustained audio and the EQ comparison.

Actual: registration succeeds, HAL I/O runs, the transport connects and new frames are sent. The system then requests sample-delivery stop and deactivation, reverts to local output, and shows the connection alert. The receiver disconnects after that request.

## Build 3 evidence

All activations and stop/deactivation callbacks carried the same system session ID, matching the extension's active session. The extension started as PID **1633**.

| Event | Local time / result |
| --- | --- |
| First registration | 16:12:36.459074; generation 1; OSStatus 0 |
| First user-directed stop | 16:12:50.685123; 674,816 cumulative driver frames |
| Second registration | 16:12:52.923974; generation 2; OSStatus 0 |
| System stop on reconnect | 16:12:54.417623; 738,304 cumulative frames; 63,488 new frames |
| Further registration | 16:13:17.227293; generation 3; OSStatus 0 |
| System stop on further attempt | 16:13:18.711003; 801,792 cumulative frames; 63,488 more frames |

Each reconnect logged `Initialize`, `StartIO`, connected transport and rising sent-frame counters. The captured failure intervals contain no publication, registration-interruption, transport-start or receiver error preceding the system stop.

For the further attempt, system routing interaction **UJH7** initially completed in **74 ms** and reported the target device found. At **16:13:18.708229**, `audiomxd` requested endpoint deactivation. At **16:13:18.766396**, `mediaremoted` reported `AVOutputContextDeviceConnectionFailureReasonMDERouteRevertedToLocal`; the surfaced route error had `MRMediaRemoteRouteStatusErrorDomain`, code **10**. Those events identify the fallback outcome. The earlier policy decision is described below. Internal system log fields are diagnostic observations, not APIs used by the app.

## Routing decision and paused-source control

Both failed reconnects log `isPlayingVideoOutput: NO` and `routeSharingPolicy 1` for Spotify. The policy controller chooses an AirPlay fallback **before** the system reports its internal `MusicVAD` audio-routing object ready. About 1.5 seconds later, it finds no matching AirPlay device and selects Speaker. In the first successful connection, the object exists before the policy check, which explicitly allows Spotify for that reason.

| Build 3 attempt | Publication succeeds | MusicVAD reported present | Spotify policy decision |
| --- | --- | --- | --- |
| First connection, generation 1 | 16:12:36.459074 | 16:12:36.577963 | Allowed at 16:12:36.662826 |
| Playing reconnect, generation 2 | 16:12:52.923974 | 16:12:53.034142 | AirPlay fallback selected earlier, 16:12:52.895525 |
| Playing reconnect, generation 3 | 16:13:17.227293 | 16:13:17.344686 | AirPlay fallback selected earlier, 16:13:17.209767 |
| Paused reconnect, generation 4 | 16:27:08.476059 | 16:27:08.573605 | Allowed after resume, 16:27:21.095360 |
| Paused reconnect, generation 5 | 16:29:51.065613 | 16:29:51.170504 | Allowed after resume, 16:30:01.896805 |

For the failed attempts, the object is reported present about **139 ms** and **135 ms** after the fallback decision. No video classification or failed registration is needed to explain these captured failures. This is evidence for a readiness/order problem, not proof of which component must fix it.

Control procedure, with the same apps and extension left running:

1. Pause Spotify and choose iPhone Speaker.
2. Prepare Aural Route Test if its receiver has stopped.
3. Select Aural Route Probe while Spotify remains paused.
4. Wait five seconds, resume at low volume, and compare the filter with Bypass EQ.

The user reported that audio and EQ worked, then confirmed both requested repeats. Two successful paused activations are independently present in the retained Console views above; the additional repeat is user-reported. Before and after process inventories confirm unchanged PIDs: extension **1633**, provider **1628**, receiver **1629**, Spotify **930**. At 16:29:17, the first paused session had reached **6,384,640** cumulative captured frames with sender drops **0** and errno **0**. These are extension counters, not a new receiver report.

Five seconds is the tested manual wait, not a measured minimum or an exposed system-readiness guarantee. Pausing first is only a diagnostic workaround; the user explicitly requires seamless reconnection without pausing. Ten-cycle acceptance, immediate-resume behavior, other source apps and longer background playback remain open.

## Controls already performed

- Build 1 skipped repeat driver registration and failed without new frames.
- Build 2 repeated registration from activation: first connection passed; reconnect failed with new frames.
- Stopping and preparing only the receiver did not restore build 2's connection.
- A one-time debugger termination of only build 2's extension changed PID **1445** to **1591**. The same receiver/provider remained alive and the same installed apps then played audio with working bypass. This is a diagnostic control, not an application workaround.
- Build 3 uses the documented registration stage and still fails reconnection while Spotify plays. Its session logs do not show a mismatched session stopping the newer activation.
- Build 3 reconnects successfully in that same retained process when Spotify is paused before selection. This supersedes the earlier inference that retained extension state alone prevents all reconnection.
- Host TCP → decoder → DSP → renderer and restart tests passed with address/undefined-behavior sanitizers. Native compilation, signing, profile authorization, installation and first audible playback passed. These do not validate system reactivation.

The remaining engineering question is how to satisfy the system's readiness ordering when Spotify is already playing. The public registration documentation provides no unregister operation or explicit MusicVAD readiness notification. Do not query private routing state, register NULL, add arbitrary activation delays or terminate the extension as a product fix. Reduce the reproduction and clarify the supported lifecycle; preserve the proven paused-source procedure while doing so. Builds 1–4 also reported the fixed device lost when discovery stopped. Build 5 removes that false loss report and logs discovery start/stop and activation acknowledgment. Apple documents discovery stopping when the picker closes, which does not mean a previously found device disappeared. The build 5 test still failed after successful first playback. Discovery stopped while retaining the device before the first stop, and did not stop again until after reconnection failed. Build 6 gates activation on an actual receiver connection, with timeout/cancellation handling. It also failed: the fallback decision at 16:48:32.985919 precedes the activation callback at 16:48:33.004127 by about 18.2 ms. Receiver readiness at 16:48:33.010804 and successful publication at 16:48:33.063004 did not cancel that earlier decision. MusicVAD was reported present at 16:48:33.358871, about 373 ms after the decision. The system returned to Speaker at 16:48:34.478936. This rules out acknowledgment-before-transport-readiness as a sufficient explanation; it does not yet isolate the same-phone receiver session from the system’s routing lifecycle.

## Receiver-session isolation

Only the receiver was updated to build 7; provider/extension build 6 remained installed, with unchanged extension PID **1896**. Its transport-only launch creates no AVAudioSession or AVAudioEngine and never invokes the DSP renderer. The same playing-Spotify selection failed. At **16:57:53.302495**, system policy selected fallback; publication succeeded at **16:57:53.346528**, MusicVAD was reported present at **16:57:53.653208**, and Speaker was selected at **16:57:54.867516**. Before fallback, the sink independently counted **34,816** received/discarded frames with no drops or socket error. Removing the receiver’s active playback session does not remove the failure.

Build 8 replaced Spotify with a quiet local PCM source using stock AVAudioPlayer and long-form audio routing, retaining the same provider/extension process. It also failed. System policy explicitly names `local.aural.route-probe.receiver` as the playing, non-video source on **two** failed attempts:

| Native source attempt | Fallback decision | MusicVAD reported present | Speaker selected |
| --- | --- | --- | --- |
| First | 17:10:11.702713 | 17:10:11.976011 | 17:10:13.134249 |
| Second | 17:10:16.685683 | 17:10:17.067528 | 17:10:18.184051 |

The readiness event arrives approximately **273 ms** and **382 ms** after the rejection. The first attempt received/discarded **28,672** frames at 17:10:12.642064 with zero drops/socket error. The second publication succeeded (generation 8, OSStatus 0) at 17:10:16.761359. A later failure at 17:10:33 is explicitly **Spotify**, not a third native-source attempt. The user stopped the source at 17:10:39.058157.

Spotify-specific playback and an active receiver audio session are not necessary for the reproduction. Build 9 also removes the same-phone loopback endpoint, as recorded below.

## External receiver control

Build **9** uses the same driver, stable device ID and documented callbacks, but advertises and sends to a private IPv4 endpoint on a separate Mac. The iPhone plays the same native, unprotected PCM tone; it runs no local transport receiver or DSP renderer. The Mac validates/counts and discards samples without audio playback or recording. Installing this provider started a fresh extension, PID **2240**. The first connection worked. The user reported reconnect failure; the captured logs independently show **two** failed reconnects in that same process and system session.

| Event | First connection | Reconnect 1 | Reconnect 2 |
| --- | --- | --- | --- |
| Activation requested | 17:30:14.617058 | 17:30:34.149966 | 17:30:37.717051 |
| Receiver connected / activation acknowledgment | 17:30:14.625211 | 17:30:34.164083 | 17:30:37.725136 |
| Delivery requested | 17:30:14.628254 | 17:30:34.188633 | 17:30:37.743644 |
| Publication success (status 0) | 17:30:14.678483 | 17:30:34.227452 | 17:30:37.785989 |
| MusicVAD reported present | 17:30:14.974807 | 17:30:34.533482 | 17:30:38.084028 |
| System policy | Allowed at 17:30:15.090995 | Fallback at 17:30:34.176683 | Fallback at 17:30:37.732485 |
| Selection ends | User switches at 17:30:30.508399 | Speaker at 17:30:35.680171 | Speaker at 17:30:39.241487 |
| Mac frames this connection | 742,400 | 53,248 | 53,248 |

Both failed policy checks identify Aural's native source, non-video playback, and route-sharing policy 1. Fallback precedes the delivery callback on both reconnects; MusicVAD becomes present approximately **357 ms** and **352 ms** after the decisions. The Mac receives **848,896** total frames across all three connections, with zero drops, protocol errors or socket errors. Successful transport and publication do not prevent the later return to Speaker.

This isolates the failure from Spotify, receiver playback/EQ, and the same-phone transport endpoint. It does not prove all conforming drivers fail or establish an Apple defect. The remaining boundary is driver lifecycle versus system routing policy.

The source stopped at **17:30:57.970357**. The Mac sink closed at **17:31:06**. Block all incoming connections was restored, the temporary sink exception removed, and the closed listener verified. The provider was rebuilt/reinstalled with the default loopback configuration and the receiver launched normally. No diagnostic tone was started automatically.

## Driver stream-state control

Build **10** fixes an independently reproduced HAL contract bug: the stream's active property was advertised as writable, but its setter ignored requests and its getter always returned 1. The driver now validates/stores that state, notifies the host and gates PCM forwarding; host tests cover suppression and resumption. Device logs confirm iOS exercises the corrected setter. Nevertheless, the user reports **first works; reconnect fails**.

The first route stops with zero active I/O clients. On reconnect the driver begins inactive and not running, receives an enable request, and starts I/O with one client. The failure again stops it with zero clients. Publication succeeds, new frames total **53,248**, and transport counters show zero drops/socket errors. This rules out the ignored active-setting bug and an unmatched active I/O client as sufficient explanations for this captured failure.

At **17:49:17.611069**, system policy chooses fallback for playing, non-video Spotify. Only afterward does Aural receive the delivery callback (**17:49:17.614382**) and publish successfully (**17:49:17.649192**). MusicVAD becomes present at **17:49:17.951256**, approximately **340 ms after the decision**. Speaker is selected at **17:49:19.098575**. The first successful selection has the opposite ordering: MusicVAD is present before policy explicitly allows Spotify. The tested phone remains on iOS **27.0 (24A437)**.

No public readiness notification or supported way to cancel the already-selected fallback was found in the iOS 27 SDK contract. This remains a suspected system/driver lifecycle interaction, not a proven Apple defect. The user authorized a full phone restart, completed at approximately **18:00**. The phone returned with iOS **27.0 (24A437)** and both applications still at build **10**, without reinstalling them. Only the extension had been restarted during earlier reconnect controls. The user unlocked the phone; both applications were reopened and fresh Console logs were verified at **18:03:16**. The user again reported **first works; reconnect fails**. A filtered stored-log export independently confirms the same ordering failure: policy selects fallback at **18:04:41.683202**, delivery is requested at **18:04:41.693373**, publication succeeds at **18:04:41.794740**, and MusicVAD appears at **18:04:42.136549**. Speaker is selected at **18:04:43.189968**, followed by `MDERouteRevertedToLocal`. The same extension PID **630** captures **48,128** new frames before the failed reconnect stops, with balanced I/O clients and no reported transport drops/error. Stale state accumulated before the full boot is therefore not necessary. Stored events contain one StopIO for each selection; duplicate-looking live Console entries are not evidence of repeated driver callbacks. Detailed timings and capture limits are in [VALIDATION.md](VALIDATION.md#build-10--full-phone-restart-control-reconnect-still-fails). Finder independently offers iOS 27.0.1 for this device. After the unchanged-OS control failed, the user authorized updating to 27.0.1 while keeping Aural build 10 unchanged. Apple's notes do not promise a routing fix. The user also accepted the presented license terms. The Mac-side download was stopped with explicit ejection approval because its 12.73 GB package exceeded available internal space; Finder removed the incomplete package automatically. The user was directed to install the authorized 27.0.1 update on the phone, preserving build 10. CoreDevice now verifies **iOS 27.0.1 (24A446)** after the OTA update, and both installed apps remain **0.1.0 (10)**. The user reports **first works; reconnect fails** after the update. The filtered stored-log export confirms two failed reconnects in extension PID **877**. Policy chooses fallback **11.103 ms** and **26.956 ms** before the delivery callback, with MusicVAD appearing **364.019 ms** and **409.215 ms** after that decision. Publication succeeds both times; the driver captures **52,224** and **47,104** additional frames before returning to Speaker about **1.507 seconds** after each decision. Transport reports remain connected with zero drops and errno 0. The same ordering failure survives the patch update. Do not replace these controls with another unsubstantiated timing or device-identity change.

## Build 11 — explicit HAL device withdrawal experiment

Remaining hypotheses, in test order:

1. The retained plug-in leaves a stale HAL object graph after delivery stops. Prediction: explicitly reporting an empty plug-in device list on teardown changes subsequent device creation or compatibility ordering.
2. A separate driver property/lifetime contract is incomplete. Prediction: a targeted callback audit identifies a host request or invalid state that differs between the first connection and reconnect. Existing evidence has not established this.
3. iOS evaluates its cached-route compatibility before the documented publication callback, independently of a correct driver teardown. Prediction: the same early fallback persists after the host accepts removal and subsequent registration succeeds.

Build 11 adds a **Debug-only, default-off diagnostic** selected with `AURAL_DIAGNOSTIC_WITHDRAW_HAL_ON_STOP=YES`. After stopping PCM forwarding and closing transport, the plug-in exposes empty `DeviceList` and `OwnedObjects` properties and an unknown result for device-UID lookup. It notifies the existing host through the public plug-in `PropertiesChanged` callback. The next `startRealtimeSampleDelivery` restores the single device immediately before normal registration; device UUID, driver interface, object IDs, stream settings, transport and DSP are unchanged. Repeated stop/deactivation is idempotent. Notification failures are explicitly logged and invalidate a claim that removal was accepted.

This follows the plug-in device-list notification pattern in Apple's [NullAudio sample](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in). That macOS example does **not** establish the iOS MediaDevice teardown contract. This is an isolated experiment, not a proven correction or an unregister API. It does not report the discoverable media endpoint lost, rotate its identity, terminate the extension, pause the source or introduce a delay. Normal builds retain the previous behavior.

Acceptance requires a successful first selection, then two reconnects while Spotify keeps playing, with sustained received audio and audible EQ/bypass. Capture the withdrawal notification result, restoration, registration generation, I/O counts and policy timing. If removal fails, or the first connection is broken, the reconnect hypothesis remains untested. Passing local callback tests or registration alone cannot establish success.

The user reports **both initial reconnects and eight requested repeats work, including EQ/bypass**, with Spotify left playing. The subsequent stored export independently captures registration generations 1–9: first connection plus **eight** reconnects, all in extension PID **1405**. Each selection has positive policy permission after MusicVAD becomes present; the last continues for at least **81.718 seconds**. Eight withdrawal notifications return status 0. No correlated fallback appears. The export does not independently establish all ten reported reconnects, and one captured connection lasts **5.816 seconds**, below the requested ten-second hold. Exact timings and frame increments are in [VALIDATION.md](VALIDATION.md#build-11--stored-result-and-capture-limits); stored timestamps supersede the preliminary live Console timings.

The captured gaps between previous StopIO and next activation are **5.972–16.254 seconds**, longer than the build 10 failure gaps of about 2–3 seconds. This supports the withdrawal hypothesis but does not isolate it from reselection timing. The subsequent quick test below resolves the need to deliberately wait on Speaker. Absence of a fallback log alone is never a hardware pass.

### Quick reselection result and promotion

The user confirmed **both quick reconnects work; EQ works**, without pausing Spotify or deliberately waiting on Speaker. Live Console records successful withdrawal/deactivation at **19:32:08.574578 / 19:32:08.574970**, followed by activation **19:32:09.830450** and explicit Spotify allowance **19:32:10.291717**. The second withdrawal/deactivation is **19:32:27.052194 / 19:32:27.052933**, activation **19:32:27.620973**, and allowance **19:32:28.110981**. Those are live-view timestamps, kept separate from stored timestamps. CoreDevice still reports extension **1405**, provider **1374**, receiver **1371**. The later stored export confirms this result and also captures the preceding quick reconnect. Its exact timestamps and three-attempt table in [VALIDATION.md](VALIDATION.md#stored-quick-reselection-evidence) supersede these live timings.

Build 12 is now installed and launched on the iPhone. It removes the diagnostic guard, plist key and build setting; teardown always uses the same tested withdrawal path, including Release. Stable identity, transport, DSP and publication ordering are unchanged. Host regression tests exercise the default behavior in both compiler configurations. The build 11 source and quick-test evidence were preserved locally before promotion. This result supports the teardown change as the prototype fix; broader background, interruption and output-route coverage remains open.

## Retained records

Filtered text evidence is stored locally at `/Volumes/DevBackup/Aural-Development/ios-route/reconnect-evidence-2026-10-10/`. Build/signature records and the original receiver report are in its parent directory. [VALIDATION.md](VALIDATION.md) records the exact files and outcomes. The approved lifecycle question was submitted to Apple Developer Forums as text only; raw device logs remain local. Device logs may contain source-app metadata and require review before sharing; no PCM was recorded. Full device screenshots are temporary local diagnostics and are not part of this document.

## Apple lifecycle question — submitted; awaiting moderation

The user authorized posting the following question and selected the public username **clob**. After separate approval of the Apple Developer Forums Agreement, it was submitted on **2026-10-10** under **Media Technologies → Audio**, tagged **Core Audio**. [Forum thread 850435](https://developer.apple.com/forums/thread/850435) confirms receipt and states that the post is being reviewed and will be published if approved. The submitted body is **4,001 characters**, verified as one copy matching the approved draft apart from editor whitespace. It excludes account/device identifiers, raw logs, local paths and source-app metadata beyond the names of the tested apps. No attachments were uploaded. Moderator approval and a technical response remain outstanding.

### MediaDevice real-time audio reconnect falls back before startRealtimeSampleDelivery

I am testing an audio-only `MediaDeviceExtension` on an iPhone 17 Pro, with Xcode 27.0 (27A266a). The same application build reproduces this on iOS 27.0 (24A437), after a full reboot, and on iOS 27.0.1 (24A446).

The extension advertises `.realtimeAudioStreaming`, one stable device UUID and a reachable, nonzero-port endpoint. It connects to the receiver before reporting `activatedDevice`. From `startRealtimeSampleDelivery(session:)`, it calls `AudioServerPlugInRegisterMediaDeviceExtension`. The plug-in exposes one output device with the same UID and `kAudioDeviceTransportTypeRemoteStreaming`. The driver interface lives for the extension process and is registered on each delivery start. Stop/deactivation closes the transport and stops forwarding samples; it does not terminate the extension or register a null interface.

Reproduction: start audio, select the extension's route, confirm audio flows, switch to iPhone Speaker, then reselect the same route while the source keeps playing. First selection works; subsequent selections briefly deliver audio before reverting to Speaker with `AVOutputContextDeviceConnectionFailureReasonMDERouteRevertedToLocal`. Pausing the source before route selection, waiting five seconds and resuming worked repeatedly in the same extension process; uninterrupted reconnection is the required behavior.

The normal test uses Spotify and a separate receiving app. A diagnostic control on iOS 27.0 also reproduces first-success/reconnect-failure using a native `AVAudioPlayer` PCM source and a separate Mac receiver that counts/discards the samples. That control has no Spotify, DSP processing, local receiver playback session or same-phone transport endpoint.

Stored device logs on 27.0.1 show two failed reconnects:

| Observation | Reconnect 1 | Reconnect 2 |
| --- | --- | --- |
| System policy chooses fallback before `startRealtimeSampleDelivery` | 11.103 ms earlier | 26.956 ms earlier |
| MusicVAD reported present after fallback decision | 364.019 ms later | 409.215 ms later |
| Driver registration result | OSStatus 0 | OSStatus 0 |
| New captured frames before system stops delivery | 52,224 | 47,104 |
| Time from fallback decision to Speaker selection | 1,507.218 ms | 1,507.904 ms |

The policy logs identify the active, non-video source as not supporting the extension's protocol, then attempt AirPlay fallback. On the first successful connection, MusicVAD is already present and the policy explicitly permits that same source. On reconnect, successful driver publication and subsequent I/O do not cancel the earlier fallback decision. Transport reports show zero drops and socket errors; StartIO/StopIO counts balance, the stream-active setter is honored, and callback session IDs match. No registration interruption is captured during these attempts.

[Creating a media device extension](https://developer.apple.com/documentation/mediadevice/creating-a-media-device-extension) directs publication from `startRealtimeSampleDelivery`. The [registration API](https://developer.apple.com/documentation/coreaudio/audioserverpluginregistermediadeviceextension) describes the interface, UID and transport requirements, but I have not found the supported teardown/re-registration contract for this retained-process case.

1. Between `stopRealtimeSampleDelivery` / deactivation and the next delivery start, should the extension retain and re-register the same driver interface, recreate it, or withdraw the audio device through a documented operation?
2. How should an audio-only extension using the documented publication callback ensure the system's compatibility check waits for its audio device? Is there a supported readiness or completion signal that the implementation must provide?

The evidence identifies an ordering difference; I am not assuming it proves an OS defect. Guidance on the required lifecycle, or a reference implementation demonstrating uninterrupted reconnects, would help isolate the remaining driver-versus-system boundary.
