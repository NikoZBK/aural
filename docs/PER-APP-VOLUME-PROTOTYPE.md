# Per-app audio routing: initial prototype results

Updated October 25, 2026. The isolated [prototype](../prototypes/macos-app-mixer/README.md) demonstrates the core multi-tap routing design. The selected-output standby reader fixes the observed headphone-jack reconnect burst in three recorded physical reconnects with Spotify. Chrome and experimental Safari helper tests now establish active capture and two live helper replacements each with volume/mute retained on the same route. Phase 1 remains open for the broader hardware, supported Safari attribution, app-identity, scaling, and recovery gates below. Production integration has not started.

## Tested setup

- Apple Silicon Mac, macOS 27.0.1; release build with the macOS 26.5 SDK, deployment target 14.2. Older macOS runtime behavior has not been tested.
- Built-in stereo speakers, 48 kHz, 512-frame callbacks (10.667 ms buffer period).
- Three separate diagnostic bundle identities, emitting 431, 997, and 1877 Hz at amplitude 0.005 each. Each source starts on the explicitly selected output; no default-device or system-volume setter is used.
- Four taps in one private aggregate: App A, App B, remaining audio, and an unmuted comparison reference. The reference never enters playback. Aural's live application, preferences, and global DSP are outside the experiment.
- Offline C tests run with AddressSanitizer and UndefinedBehaviorSanitizer. The Swift executable and all four diagnostic app bundles build and pass local signature verification.

## Initial synthetic-source outcomes

| Check | Result |
| --- | --- |
| App/source identity | All three expected bundles are active on the selected physical output; independent frequencies identify their lanes |
| Input isolation | Cross-source leakage below the −60 dB gate; the third source is present in Remaining audio |
| Unity reconstruction | Sum of raw A + B + Remaining matches the reference at zero lag; relative RMS error about `1.15–1.17e-7`, below the `0.001` gate |
| Independent volume | A and B each reach 50%; muting A leaves B at unity within the 2% gate; unity restores correctly |
| Full mixer | The rendered output includes A, B, and the third source exactly through their selected lanes |
| Live ownership transfers | Four runs, eight transfers total: move the playing third source into App A and back. Zero mismatched frames in the immediate transition captures at absolute tolerance `2e-6`; peak difference below `5.6e-9` |
| Settled ownership | After transfer, the third source is present in its new lane and absent from the old lane |
| Process relaunch | Explicit process replacement and macOS 26 native restoration each pass twice. A fresh PID/HAL object returns to A's lane with its retained 50% gain and B unchanged |
| Callback faults | Zero malformed buffers and zero nonfinite samples in successful native runs |
| Callback timing | Largest measured callback across the initial synthetic-source runs: `136.458 µs`, versus the `10,667 µs` buffer period. Initial four-test suite maximum: `102.958 µs`. These are observed maxima, not a worst-case guarantee |
| Teardown | Tests return successfully after callback, aggregate, and tap teardown; the final inventory has no diagnostic source process objects |
| Parent exit / input validation | Diagnostic sources exit after their parent is terminated; unknown options and missing explicit outputs fail before starting audio |
| Existing application work | Hash comparison confirms all 95 pre-existing source/test files are unchanged by this prototype work |

A final gate-strengthening check also verifies source-owner identities, return to unity, and the remaining-source playback mask in both `all` and `owned` modes.

The four-test native suite exercised playback, live transfer, explicit relaunch, and native relaunch. It processed 385,536 / 578,560 / 543,744 / 543,232 frames respectively, with every measurement gate passing. The tests were run sequentially.

Ownership changes use sequential tap-description setters, outside the callback. Measured property-update durations in the first three handoff runs were about 18.8–23.1 ms when adding the third source and 6.1–6.3 ms when removing it. Immediate captures begin before the updates and retain 32,768 frames; separate settled captures verify the new partition. Successful measurements on this setup do not make the two setters an atomic API transaction.

## Findings that affect production design

**Use the callback layout, not tap StartingChannel alone.** The first experiment reported tap starting channels 7/9/11/13, while the IOProc received four stereo buffers: eight channels total. Treating those values as callback offsets correctly failed the buffer gate. The prototype now tracks stream identities while adding taps, validates the final stream configuration, derives a candidate mapping from it, and verifies that mapping with independently identifiable sources. A changed or unprovable map fails explicitly.

**Keep format validation separate from discovery.** Read-only inventory encountered a 16 kHz default headset route during validation. Inventory now reports it, while capture continues to reject unsupported formats. Tests remained explicitly targeted at the 48 kHz built-in output. The default virtual output retained its UID during the final suite but its displayed name/rate changed; UID equality alone is not proof that its backing route stayed unchanged.

**Treat inventory as a changing snapshot.** Terminating a diagnostic parent exposed a `!obj` error between process-list and metadata reads. That exact typed error is now recorded as an inventory issue and logged; other failures propagate. Playback preflight requires an issue-free catalog so an unidentified active mixer cannot be overlooked. A second active prototype is rejected before starting playback, even if its private aggregate hides its physical output.

**Retain both lifecycle paths.** The macOS 26 restoration flag works for the diagnostic app on this OS. Explicit PID replacement also works here, but that does not verify behavior on macOS 14.2. Neither result establishes browser-helper grouping or safe treatment of reused identifiers.

**Separate gain updates from topology.** Gains cross the control/audio boundary through lock-free atomic values and a 20 ms ramp. They do not perform HAL calls, process discovery, allocations, or graph analysis. Topology tests deliberately happen through a separate control path.

## Evidence and reproducibility

Run `bash scripts/test.sh`, `bash scripts/build.sh`, then `bash scripts/native-test.sh builtin` from `prototypes/macos-app-mixer`. The native runner saves its own timestamped directory under ignored `reports/`, stops on a failed gate, and records before/after inventories. `monitor` and `owned` modes can be run separately as described in the README.

Raw reports remain local. They contain process and device identifiers, so this document shares only the sanitized findings. No audio files were written or uploaded; captured samples exist only in the diagnostic process's preallocated memory.

## Spotify and Bose Bluetooth follow-up

The next test used the user's paired Bose headphones, a physical stereo Bluetooth output at **44.1 kHz**, with live Spotify playback. eqMac was temporarily quit with approval and the installed Aural EQ paused to isolate the diagnostic route. Both were restored afterward. Spotify was controlled through its existing main process plus a helper whose actual enclosing application bundle was verified as `com.spotify.client`; the helper was idle in these captures, so active helper audio/churn is not established.

`app-test` now measures real music against the exact same captured input samples, rather than comparing RMS from different passages. An independent quiet reference process remains at unity while Spotify steps through 100%, 50%, 25%, mute, and 100%. All runs require stable app/helper identities, audible Spotify samples, valid buffers, unity reconstruction, the reference source, and matching rendered gain.

| Run | Duration | Rendered frames | Observed Spotify gains | Maximum callback |
| --- | --- | --- | --- | --- |
| Spotify plus independent reference; remaining audio direct | 40 s | 1,764,352 | 1 / 0.5 / 0.25 / 0 / 1 | 122.916 µs |
| Full mixer including remaining audio | 15 s | 661,504 | 1 / 0.5 / 0.25 / 0 / 1 | 294.208 µs |
| Fresh full-mixer session after Bluetooth reconnect | 20 s | 882,688 | 1 / 0.5 / 0.25 / 0 / 1 | 158.791 µs |

All measurement gates passed in all three runs, with **zero malformed buffers and zero nonfinite samples**. The 512-frame period at 44.1 kHz is 11.610 ms. The largest callback in this follow-up was 0.294 ms. These are observed timing results, not a guarantee of worst-case scheduling behavior or Bluetooth end-to-end latency.

Gain estimates matched their targets to better than `4e-10` in the recorded captures. The maximum normalized same-sample render error was below `2.6e-8` in the first run; its mute capture measured exactly zero Spotify contribution while the reference remained audible. No PCM audio files were written.

The user confirmed that the first listening sequence changed levels and muted Spotify while the reference continued, then returned cleanly. The user also confirmed playback and volume/mute control after reconnect. This supplies listening evidence on this headphone pair; it does not replace quantitative hardware loopback or establish every direct-playback edge case.

### Bluetooth loss and reconnect

A live diagnostic route was opened, Spotify was paused to avoid spilling music onto the laptop speakers, and only the Bose device was disconnected through macOS Bluetooth Settings. The diagnostic detected that its stream became unreadable (`who?`, HAL status `2003332927`), returned a nonzero exit and an explicit failed report, and attempted full callback/aggregate/tap cleanup. A subsequent inventory showed no diagnostic source processes. This is an intentional device-loss result, not a passed audio capture while disconnected.

The same device was reconnected without restarting Spotify. A fresh full-mixer session then passed every gate, as recorded above. **That first diagnostic stopped on device loss**; the automatic-recovery work described below supersedes that limitation. Production integration still needs to connect the mixer to Aural's lifecycle coordinator.

Restoration checks confirmed the eqMac virtual default output returned, Spotify was playing, the saved eqMac output/46% volume/EQ settings were retained, and the installed Aural resumed processing. The real application and test-source teardown remained separate from the synthetic source relaunch experiments above.

## Automatic recovery follow-up

The recovery prototype now keeps the same process alive across output loss. Its policy comes directly from Aural's existing `StartupPlan` and `RouteRecovery` source, rather than a fork of that logic. Stop cancels the wait, start attempts have generation tokens, transient retries are bounded, permission failures stop immediately, and repeated format changes consume the existing restart budget.

The user switched to FiiO headphones plugged into the **Mac headphone jack**, exposed by Core Audio as **External Headphones at 48 kHz**. This is an analog-jack test, not a FiiO USB DAC test. The jack's UID identifies that output endpoint; it cannot identify the brand of analog headphones plugged into it. The prototype stays bound to this UID instead of following a fallback speaker or the still-connected Bose output.

A normal-volume run recorded a physical disconnect and automatic reconstruction in the same process. The measured app gain was `0.4999999999638078` before disconnect and `0.5000000000597177` after reconnect, with complete 32,768-frame capture windows. The user confirmed that music returned automatically without another Start command or restarting Spotify. That preliminary report ended before its configured second reconnect, so it did not satisfy that run's full repeat-count gate; the single recovered route and its gain measurement are the verified evidence.

Two implementation details came from the live checks:

- A disappearing stream may report `stop` as well as `who?` before the device vanishes. These statuses are treated as waiting only during readiness reads for the saved output. Unexpected and permission errors remain explicit failures.
- Releasing every muting tap would expose a dry playback path during rebuild. The initial approach retained a separate private, always-muted tap for only the saved app/output while waiting. That passive guard did **not** prevent the reconnect burst; the subsequent reader fix is recorded below. New engines receive their saved effective gains before IO starts; Stop/Finish release the standby tap. A quiet app is allowed to recover normally, and measurement waits for actual app input before retaining its window.

Offline sanitizer tests cover first-frame attenuation/mute, quiet-app capture deferral, immutable capture publication, and existing buffer/gain checks. Pure Swift checks cover exact-output selection, readiness delay, saved controls and waiting edits, cancellation, stale attempts including retries, bounded retries, permission failures, and format-restart limits. A further live check began with Spotify paused and mute on at a stored 25% level. After playback started, the deferred capture measured exactly zero app contribution with nonzero input (`0.2059322750` RMS). Unmuting restored `0.2499999999659509` gain with normalized render error `6.3827e-9`. The physical muted unplug/replug listening check was not completed in that early run; the subsequent physical checks are recorded below. The test was ended and audio restored rather than leaving Spotify muted.

Native Stop testing confirmed that standby taps were released and a stale enabled command did not restart processing while the output was available. The normal-volume and muted-control runs processed 11,486,720 and 23,916,544 frames respectively, with zero invalid buffers/nonfinite samples; observed callback maxima were 122.208 and 241.125 µs against a 10.667 ms period. Neither run completed its requested repeat-count gate, so their raw report outcomes correctly remain failed for that incomplete protocol. The single normal-volume recovery, mute/unmute measurements, and Stop/stale-command checks are the verified subsets.

### October 25 muted reconnect: audible failure

An initial listening retry was inconclusive: the physical headphone output was also hardware-muted, and no logical route loss was recorded. Its silence is not evidence that Aural preserved mute. The hardware mute was then cleared and checked through Core Audio before the following tests, with the physical headphone level restored to 47%.

The clean retry recorded one disconnect and an automatic rebuild without another Start command. The user heard about one second of Spotify through the headphones immediately after plugging them back in, followed by only the quiet diagnostic reference tone. Settled 32,768-frame captures before and after the rebuild measured exactly zero Spotify contribution with nonzero input. The run processed 10,182,144 frames with zero invalid buffers/nonfinite samples and a 122.833 µs observed callback maximum. Its automated measurement gates passed, but the **hardware mute-continuity gate failed**. The original raw report is retained unchanged alongside that listening result.

The logs showed a replacement hardware object with the same output UID and unchanged Spotify process objects. The standby guard had been reused based only on the process group and its readable tap UID. Guard reuse now also requires the same hardware object, output UID, and recovery generation. A replacement guard is created on the first readable endpoint snapshot, before the route's one-second settling delay; the old guard is retained until its replacement exists. Guard setup errors propagate explicitly. Regression checks cover changed hardware objects, reused object IDs across generations, changed process groups, and the settling interval.

That change **did not eliminate the burst** in a second physical reconnect. The new guard was created before the rebuilt route started, but the user still heard brief music. Both settled mute captures again measured zero with nonzero input. This run processed 5,897,216 frames, with zero invalid buffers/nonfinite samples and a 208.458 µs observed callback maximum. A stale guard was a real lifecycle defect, but rebinding it after device discovery is insufficient evidence of continuous protection. That failure required protection before dry playback resumed; faster polling and passing settled captures alone did not close the gate.

The user explicitly retained **selected-output-only control**. An app-wide mute across speakers or other outputs is excluded as a workaround. No production mixer changes were made. Offline sanitizer and recovery checks and the locally signed diagnostic build passed, while hardware continuity still failed with the passive guard. Both diagnostic sessions were stopped with no standby taps retained, and normal eqMac/FiiO playback and the temporary speaker settings were restored.

### Selected-output standby reader: verified headphone-jack fix

The device-scoped guard now has its own private, tap-only aggregate and C input-discard callback. It has exactly one tap input, no hardware subdevices or output streams, and writes no PCM files. The reader remains owned while the separate playback aggregate is torn down. A replacement reader is prepared before releasing the preceding guard. Stop/Finish attempt callback, aggregate, and tap cleanup independently and retain uncertain callback memory. Reports include per-guard callback/frame counts and a separate reader-activity gate, in addition to the settled mixer measurements.

The C sanitizer checks pass for interleaved and planar input, no PCM modification/retention, empty input while disconnected, malformed layouts, frame bounds, and defensive silencing of an unexpected output. Recovery policy checks and the locally signed build also pass. Quiet apps may arm a reader without callbacks yet; this is not represented as measured mute continuity.

`guard-test` isolates a passive tap (`--reader off`) or input-only reader (`--reader on`) from all EQ playback and reference tones. An early attempt was inconclusive because Spotify was paused and a different Bluetooth device was selected. The standalone check now requires a ready exact endpoint and an actively playing matching app/output before creating a tap; the revised native preflight rejected that inactive-source setup without starting audio.

The controlled repeat verified Spotify playing directly through the FiiO jack at 48 kHz, with hardware mute off and the physical level at 47%. The user heard music throughout the 25-second **passive guard** check. In the 20-second **reader** check, Spotify became silent and returned when the check ended. The reader received 961,536 frames in 1,878 callbacks, with zero invalid buffers and a 3.458 µs observed callback maximum. Both standalone checks released their resources. On this tested system, a readable tap object with `.muted` was insufficient protection without an active reader; the earlier guard-rebinding change alone therefore could not close the gap.

Two subsequent recovery sessions kept the reader alive across physical unplug/replug while Spotify continued playing:

| Session | Recorded disconnects / rebuilt routes | Playback frames | Maximum playback callback | Result |
| --- | --- | --- | --- | --- |
| First reader recovery | 1 / 1 | 13,837,824 | 103.791 µs | All automated gates passed; no audible burst reported |
| Repeat reader recovery | 2 / 2 | 4,835,328 | 305.791 µs | All automated gates passed; both returns had no audible burst |

The user confirmed **three actual reconnects without a music burst through the FiiO**. Every started route had a complete 32,768-frame capture with nonzero Spotify input and exactly zero rendered Spotify contribution while muted. Every guard delivered input frames, and both sessions had zero invalid buffers/nonfinite rendered samples. The largest observed guard-reader callback was 15.708 µs; the 512-frame period at 48 kHz is 10.667 ms. The earlier response given before physically unplugging, and cycles not recorded during an active session, are not counted.

After the final reconnect, unmuting restored the retained 25% setting: measured gain `0.2500000000345804`, normalized render error `7.622678283672465e-9`. Finish left no standby taps/readers owned. Normal Spotify playback through eqMac returned with the saved FiiO F1 preset, −6.5 dB preamp, and 47% headphone level. Headphone/speaker hardware mute flags were off and their original volume values were verified; the installed Aural EQ remained stopped. All 95 pre-existing source/test hashes remained unchanged.

This closes the observed headphone-jack burst on the tested setup. Control remains tied to the selected output UID; no app-wide mute, fallback-output selection, or Spotify pause is part of recovery. Independent hardware loopback, other devices/OS versions, and production integration remain separate gates.

## Safari and Chrome active-helper tests

The October 25 follow-up used macOS 27.0.1, Safari **27.0.1**, and signed/notarized Google Chrome **156.0.8078.48**, with the FiiO connected to the Mac headphone jack at **48 kHz**. Chrome ran from a temporary official-vendor bundle in a Guest window; no default-browser setting, sign-in, or installed browser was replaced. Test tabs played local synthetic AAC at 431 Hz (Safari) and 1877 Hz (Chrome). The fixture uses no microphone, account, external media, or audio recording. Safari's existing Lockdown Mode remained enabled; it disabled the original Web Audio fixture, so testing used HTML media, AAC, and HTTP byte ranges instead.

**Chrome:** the active Core Audio process was Chrome's AudioService helper, not its main process. Its actual enclosing application resolved to `com.google.Chrome`. Both runs below used the default enclosing-app ownership policy.

**Safari:** the active audio process had bundle ID `com.apple.WebKit.GPU`. eqMac also had a distinct process with that same bundle ID. Default attribution correctly left these shared helpers unowned; a Safari `app-test` failed before opening a route. An explicitly enabled prototype experiment used the undocumented OS responsibility query, with PID/user/birth-time checks for both helper and responsible app. Read-only inventory attributed Safari's helper to Safari and eqMac's helper to eqMac independently. This is experimental evidence, **not a supported public API or a production Safari implementation**. The flag is restricted to inventory/app tests; it cannot enable shared-bundle native restoration in recovery tests.

Every successful run applied 100%, 50%, 25%, mute, then 100%, with three seconds per phase and 32,768 retained frames per phase. All six gates passed: real-app samples, stable verified ownership, valid callback buffers, unity reconstruction, unchanged independent reference, and same-sample attenuation/mute.

| Run | Rendered frames | Maximum callback | Result |
| --- | --- | --- | --- |
| Chrome active audio helper | 720,896 | 111.041 µs | All five levels match |
| Chrome replacement helper, fresh session | 721,920 | 104.375 µs | All five levels match |
| Safari experimental ownership, Chrome also playing | 720,896 | 278.875 µs | Safari levels match; Remaining samples retain unity contribution |
| Safari replacement helper, fresh session, Chrome still playing | 720,896 | 166.875 µs | All five levels match |

Across these runs, maximum absolute gain error was below `5.6e-10`, maximum normalized render error below `6.1e-8`, and maximum relative unity reconstruction error below `1.18e-7`. Invalid buffers and nonfinite rendered samples were zero. The largest callback observed was 0.279 ms against the 10.667 ms buffer period; this is not a worst-case scheduling guarantee. These are callback/sample measurements; no new headphone listening confirmation or independent hardware loopback was obtained.

### Controlled helper exit and regrouping

One active Chrome AudioService helper and one active Safari-owned WebKit GPU helper were terminated individually during their respective test runs, only after verifying the exact current test-owned process. Neither browser main process nor eqMac's shared WebKit helper was targeted. Each diagnostic detected the changed/empty verified process group during playback, returned a nonzero exit and explicit ownership-change report, and completed cleanup without a reported teardown failure. The schema-version-2 reports retain initial/latest groups even when no complete measurement is available. Identity checks run on the control thread at intervals up to 250 ms; they do not run in the C audio callback.

Both browser main processes stayed alive. Chrome's interrupted test tab did not recover playback on reload; a fresh Guest tab created a replacement audio helper. Safari reloaded its test page and created a replacement GPU helper. Each replacement had a new PID and birth identity, and the fresh-session runs above passed. Safari's replacement reused a previously observed HAL object number, reinforcing why object number alone is not identity. This establishes safe diagnostic abort and successful fresh-session regrouping. It does **not** retain gain/mute continuously across helper replacement; after teardown normal direct playback is released.

Offline ownership tests cover same-user/lifetime checks, helper and owner exits, PID-reuse fixtures, unknown attribution, duplicate HAL objects, and separating Safari from eqMac despite their shared helper bundle ID. Native PID reuse was not forced. The C sanitizer suite, Swift recovery tests, ownership tests, diagnostic build, and local bundle-signature checks passed. A reproducible loopback fixture is included in `scripts/browser-audio.py`; page, AAC generation, byte-range, HEAD, event, and invalid-path/range smoke checks passed.

All browser tones and diagnostic source processes were stopped, owned test tabs/temporary browsers closed, and the local fixture server stopped. Spotify playback, eqMac's saved FiiO F1 preset/−6.5 dB preamp/47% level, Aural's stopped state, and its original saved output/settings were restored. Hardware headphone/speaker volume and mute values matched the pre-test readings. Raw identifiers/reports remain local; no production source or installed Aural binary was changed.

### Live helper handoff with retained controls

The follow-up keeps the same callback, C engine, and gain state alive across helper replacements. The earlier `app-test` still deliberately aborts on churn; the new `browser-handoff-test` exercises live reassignment. Both use the same verified birth/owner identities. On the same FiiO jack/macOS/browser setup above, two actual helper replacements per browser passed without another route Start or a fresh diagnostic session.

**Prevent the discovery gap from reaching unity playback.** A catch-all Remaining lane would replay a new helper at full gain before attribution. The handoff route instead uses an explicit other-process list and actively reads its device-scoped global reference with `.mutedWhenTapped`. The reference blocks direct playback on the selected output and is never replayed. Unknown arrivals cannot enter the rendered mix until classified; positively attributed browser helpers join the app lane with its unchanged gain, and other sources enter the unity lane. Existing peers continue playing. All taps retain the same selected physical UID. There is no app-wide guard on speakers or other outputs.

Native bundle restoration is disabled on this path. Apple's [restoration API](https://developer.apple.com/documentation/coreaudio/catapdescription/isprocessrestoreenabled) matches bundle IDs after exit, which is insufficient to separate the shared WebKit helper identities. The control thread instead clears the previous app binding and attaches each verified replacement. Unresolved possible browser helpers remain withheld; attribution timeout, output/format changes, competing processors, or stream-map uncertainty fail explicitly. This can introduce a short wait for a new source and does not promise seamless media-service recovery inside the browser.

| Browser session | Helper replacements | Retained controls | Rendered frames | Maximum callback |
| --- | --- | --- | --- | --- |
| Chrome | 2 | 25% → mute → replacement remains muted → unmute returns to 25% → second replacement stays at 25% | 3,758,592 | 126.833 µs |
| Safari, experimental attribution; Chrome remains a unity peer | 2 | 50% → mute → replacement remains muted → unmute returns to 50% → change to 25% during second restart → replacement begins at 25% | 6,353,408 | 328.041 µs |

Both reports passed every live-handoff gate, with **zero invalid buffers and zero nonfinite samples**. Each original/replacement group had a complete 32,768-frame same-sample capture beginning at its first nonzero app-lane sample. Every completed control-edit window passed too. Across all ten completed windows, maximum absolute gain error was below `3.8e-10` and maximum normalized render error below `5.1e-8`; the independent 997 Hz peer remained present. A control-edit window superseded while Safari's helper was absent was not represented as a completed measurement. Safari resumed its fixture automatically after GPU helper exit. Chrome needed a new Guest fixture tab after AudioService exit; its browser and the diagnostic stayed running.

**Deliberately delayed assignment:** a separate `quarantine-test` started a 2467 Hz synthetic process only after the route's explicit lists were established and held it unassigned for the capture window. Its reference amplitude was `0.00499608645`; its rendered contribution was `4.7818e-12`. After assignment to the existing app lane, observed gain was `0.2499999999587`, with normalized render error `1.97e-8`. All quarantine, assignment, buffer, and cleanup gates passed. This tests the undiscovered-source interval directly rather than treating fast attribution as protection.

The C callback was unchanged; process discovery, explicit partition updates, and JSON controls remain outside it. Regression checks cover unknown shared helpers, unaffected peers, missing/replacement groups, object/PID reuse fixtures, and retained mute/volume. Sanitizers, recovery/ownership checks, final diagnostic build and local signatures passed. Stop/Finish released the guarded route and reference source. Both browsers/owned fixtures and the loopback server were closed. The original Aural settings matched as JSON, EQ was stopped, Spotify remained paused as at the start of this follow-up, and eqMac/FiiO levels and hardware mute flags were restored.

These are native captured-input/render measurements. They do not independently verify physical loopback or absence of every audible transition artifact. No new headphone listening confirmation was obtained. Safari still requires the explicitly enabled undocumented responsibility query; broader races, OS versions, outputs, and production integration remain separate gates.

## Gates still required before product integration

- Quantitative hardware loopback and broader direct-playback/duplication checks. Spotify/Bose listening and gain/mute checks above passed; the report's rendered samples are still not an independent hardware recording. End-to-end latency is unmeasured.
- Broader live-helper races (rapid repeated churn, app exit/restart, competing sources), native PID/object reuse, physical-output transition measurements, and a supported Safari attribution strategy. The four live browser replacements and deliberately unassigned-source checks above passed; the Safari policy remains an opt-in private-API experiment. Unknown possible target helpers stay withheld until attributed.
- Other Bluetooth rates/devices, USB outputs, native hardware input exclusion, format changes, sleep/wake, and permission failures. Bose at 44.1 kHz and its original clean-stop/fresh-session reconnect passed; automatic recovery has a headphone-jack hardware result above, with broader Bluetooth recovery still pending. Offline planar/stereo and input-exclusion tests do not replace broader hardware coverage.
- Capacity/resource measurements across more active and idle apps. The C engine is bounded to eight lanes, but the native result covers four taps, including the comparison reference.
- Fault-injected lifecycle teardown and stale completion tests before integrating with Aural's existing route coordinator. Preserve the uncommitted disconnect-recovery work as the explicit integration baseline.
- Existing EQ/stereo/bypass/limiter equivalence, the app-volume preference store, accessible mixer UI, performance audit, full Aural suite, and universal release validation in their later planned phases.

Next are the Safari ownership decision, broader helper/recovery races, capacity/resource measurements, additional outputs, and production recovery integration. The selected-output reader closes the observed FiiO reconnect leak above; the synthetic, Spotify/Bose, FiiO, and browser results do not close the remaining gates.
