# macOS per-app routing prototype

An isolated Core Audio experiment for Phase 1 of [Aural's app-volume plan](../../docs/PER-APP-VOLUME-PLAN.md). It builds separate diagnostic apps and never loads the production EQ model, presets, or preferences. [Measured results and remaining gates](../../docs/PER-APP-VOLUME-PROTOTYPE.md).

## What it exercises

One private aggregate uses the selected physical stereo output's clock. Its inputs are:

1. App A, initially a quiet 431 Hz diagnostic source.
2. App B, initially a quiet 997 Hz diagnostic source.
3. Remaining audio, excluding A, B, and the probe. A third diagnostic source plays 1877 Hz here.
4. An unmuted reference excluding the probe, used only for comparison and never mixed into playback.

The C callback sums the first three lanes, with independent 0–1 gains and 20 ms ramps. It performs no allocation, locking, logging, Swift, or app lookup. Capture storage is allocated and prefaulted before IO. Limits are eight input lanes, 8,192 frames per callback, twelve phases, and 32,768 retained stereo frames per lane/phase. The current native topology uses four lanes; this is not an eight-app scaling result. Global EQ and peak protection are outside this diagnostic. `app-test` adds same-sample measurements for real music, including owner-verified helper processes.

Tap ownership is identified by appending one tap at a time and tracking the added stream. Final IOProc offsets come from validated stream configuration and stream identity, then are tested using independent tones. `StartingChannel` is recorded for diagnosis; it did not match callback offsets on the tested OS. A changed or ambiguous stream map is an error.

## Build and offline tests

Requires macOS, Swift tools, and an SDK containing the Core Audio tap APIs. The deployment target is macOS 14.2; the optional native process-restoration test requires macOS 26. Builds default to ad hoc signing. Set `SIGNING_IDENTITY` to use a development identity.

```sh
cd prototypes/macos-app-mixer
bash scripts/test.sh
bash scripts/build.sh
```

If the selected developer tools have mismatched headers, set `SDKROOT` to the installed SDK for both commands. A verified local build used `MacOSX26.5.sdk`. Cloud-synced checkouts can be copied to a local temporary directory for validation; set `AURAL_SOURCE_ROOT` to the original repository root in that case. Build/test scripts use the exact existing `Sources/Aural/Startup.swift` policy. The build materializes an ignored `SharedStartup.swift` in the standalone target; no production source file or installed app bundle is replaced.

## Native checks

Use an unused physical output at a comfortable low volume. `builtin` explicitly selects a built-in stereo output; a device UID selects that exact device. `default` is an explicit choice to use the current default, not a default-device mutation. Playback tests reject virtual/aggregate outputs and eqMac processing on the same output. Another active Aural/probe is conservatively rejected on any output because its private aggregate may hide the physical route. Run one diagnostic at a time.

```sh
mkdir -p reports
probe=.build/apps/AuralMixerProbe.app/Contents/MacOS/MixerProbe
"$probe" inventory --report reports/inventory.json
"$probe" devices --report reports/outputs.json
"$probe" self-test --output builtin --playback monitor --report reports/capture.json
"$probe" self-test --output builtin --playback all --report reports/playback.json
"$probe" handoff-test --output builtin --playback all --report reports/handoff.json
"$probe" relaunch-test --output builtin --playback all --restore off --report reports/relaunch-process.json
"$probe" relaunch-test --output builtin --playback all --restore on --report reports/relaunch-native.json
```

Use an existing writable directory for reports. Alternatively, `bash scripts/native-test.sh builtin` builds a timestamped report directory and runs the playback, handoff, and supported relaunch checks against the already-built apps.

- `monitor` reads unmuted taps and renders silence; source audio continues directly.
- `owned` intercepts and replays A/B; remaining audio plays directly.
- `all` intercepts and replays A/B plus remaining audio.
- `handoff-test` transfers the third source into App A and back while all sources keep playing. Immediate captures cover the sequential tap-description updates; separate settled captures verify the final ownership. The reference is compared against the raw lane sum before gain.
- `relaunch-test` terminates only diagnostic A and starts a fresh process with the same bundle identity. It checks retained 50% gain and an unaffected peer. `--restore off` explicitly replaces process IDs; `on` tests macOS's process-restoration flag without manual replacement.
- `inspect --pids PID,PID --output UID` builds and reports a candidate map for two existing processes, then tears it down without starting IO. This does not prove their playback behavior.

A test launches only its own three source apps, each at amplitude 0.005 (about −46 dBFS). Sources stop when the parent exits and have a 60-second deadline. The probe does not change the default output or system volume. It stops the callback, destroys the aggregate and every tap, and terminates its sources on completion or error. Cleanup failures are reported; uncertain callback memory is retained until HAL confirms removal. macOS may request System Audio Recording permission for the diagnostic app.

## Real-app listening and measurement

Stop competing audio processors first, select the desired physical output for the app, and start playback. `devices` lists the exact output UIDs and transport types. A Bluetooth headset must expose a supported stereo output at 32–192 kHz; 16 kHz headset mode remains unsupported.

```sh
"$probe" app-test --bundle com.spotify.client --output PHYSICAL_OUTPUT_UID \
  --playback owned --phase-seconds 8 --report reports/spotify.json
```

This includes the requested bundle and helpers whose actual enclosing app bundle matches it. It requires an active app stream on that exact physical output, an issue-free preflight catalog, and no conflicting Aural/probe/eqMac route. It never starts, stops, or relaunches the real app itself. A separate quiet diagnostic source provides an independent 997 Hz reference. In `owned` mode, other audio stays on its direct path; `all` additionally intercepts/replays Remaining audio. `monitor` only observes and does not apply the announced gain changes.

Five phases use 100%, 50%, 25%, mute, then 100%. `--phase-seconds` accepts 2–20 seconds (default 8). Output identity/rate, stream-map identity, and callback faults are checked throughout. A change aborts the test and attempts full teardown. The captured windows start after a 250 ms settling period and retain up to 32,768 frames each; they do not cover every instant of a longer phase.

For each retained stereo input sample, analysis reconstructs the expected weighted mix and compares it with the rendered sample. The estimated app gain removes the unchanged peer contributions before projection onto the app signal. This avoids comparing different passages of changing music. App/helper identities must remain stable across the run; churn is reported as a failed gate rather than silently claiming complete app coverage.

The report has an explicit `outcome`, `error` when present, and optional `measurements` containing identities, per-phase gain/error metrics, faults, timings, and gates. It is written after teardown, including on setup/runtime failure. Listening confirmation is recorded separately: a correct callback render does not independently prove the headphones received it or that another direct path was absent. Restore any audio processors paused for the test afterward.

## Automatic output recovery

`recover-test` keeps one diagnostic process alive across reconnects. It uses Aural's existing `StartupPlan` and `RouteRecovery`: the exact saved UID, a settling delay, bounded transient start retries, a format-restart budget, and cancellation generations. It does not follow the default output to speakers or another headphone pair, change macOS's default device, or start/pause Spotify itself.

```sh
"$probe" recover-test --bundle com.spotify.client \
  --output BuiltInHeadphoneOutputDevice --gain 0.5 --duration 300 \
  --control reports/recovery-control.json --status reports/recovery-status.json \
  --report reports/recovery.json --min-reconnects 1
```

Use the actual physical UID from `devices`. `BuiltInHeadphoneOutputDevice` identifies the Mac's headphone-jack output; macOS cannot distinguish the headphone brand plugged into that jack. A Bluetooth device has its own UID. `default` and `builtin` aliases are intentionally rejected for persistent recovery.

The callback, aggregate and diagnostic reference source are released on output loss. A separate private, always-muted app tap stays scoped to the saved output until Stop/Finish. This guards the app's direct path during the interval between the output returning and the rebuilt callback starting. A new engine is primed with the saved effective gain before IO starts. Mute remembers its separate volume value, and Stop releases the standby guard too. Cleanup uncertainty is terminal and retains callback context safely.

Readiness handles stopped/disappearing streams only while probing this exact output. Permission and unexpected errors propagate; unsupported temporary formats remain visibly waiting. Controls are retained while waiting. A rebuild resolves current app process objects instead of reusing cached PIDs. Quiet apps may recover normally: capture waits for actual input before beginning its measurement window, and completed windows are published with release/acquire atomics before control-thread analysis.

**Headphone-jack reconnect fix:** a passive standby tap did not suppress Spotify on the tested system; rebinding that tap alone still leaked brief dry audio. The independent selected-output reader passed three recorded physical reconnects with no burst heard through the FiiO and zero settled Spotify contribution while muted. Selected-output-only control is preserved; no app-wide mute is used. See the dated [hardware findings](../../docs/PER-APP-VOLUME-PROTOTYPE.md#selected-output-standby-reader-verified-headphone-jack-fix).

The recovery guard has a separate input-only reader with no hardware subdevices or outputs. Its callback discards the selected tap without retaining PCM and stays owned across playback teardown. Reports expose guard callback/frame counts and require reader activity as an additional automated gate. Automated passes establish route recovery, reader activity, and completed settled gain captures; transition suppression additionally requires the hardware listening result. Other devices, OS versions, and production integration still need their own verification.

Use `guard-test --bundle com.spotify.client --output EXACT_UID --reader on --duration 15 --report reports/guard.json` to isolate that reader, or `--reader off` for the preceding passive-tap design. The standalone check requires the app to be playing directly through that ready physical output before it creates a tap. It produces no reference tone or EQ replay, releases its resources after the bounded interval, and reports reader activity only. Hearing silence during it is a separate listening result. Recovery itself still supports paused apps; an armed quiet reader may not receive callbacks until playback begins.

The status file reports `waiting`, `starting`, `running`, `stopped` or `failed`, the current generation, stored controls, holding-tap count, and the latest completed measurement. A measurement includes its own generation and controls; an older window is not evidence for newer settings. To change controls, atomically replace the control file with a complete object and a strictly newer revision:

```json
{"revision":1,"enabled":true,"volume":0.25,"muted":false,"finish":false}
```

Set `muted` to true to retain the level while silencing the app. Set `enabled` to false for Stop, which cancels the reconnect wait. A later false→true transition requests a manual Start. Set `finish` to true to tear down and write the final report. Stale revisions are logged and ignored. File access, discovery, measurements, and status writing all happen outside the audio callback; normal gain edits use only the existing atomic gain/ramp path.

This is a bounded diagnostic: 3–600 seconds, at most 16 route generations and 12 measured control segments per generation. Raw PCM stays in RAM. The final report records route generations, disconnect/retry/Stop events, same-sample gain/mute checks and callback faults. Hardware results are documented separately from the pure state-machine and first-frame DSP checks.

## Reading results

A successful exit means every measurement gate passed and teardown returned successfully. Measurement failures retain a report and return nonzero; setup failures print the exact action, status/four-character code, and object when available. No successful placeholder result is written for failed setup.

Read-only inventory can describe an output outside the capture format limits, such as a 16 kHz headset mode; capture still rejects that format. The native runner compares default-output UIDs, records both inventories, and calls out name/rate changes; a stable virtual-device UID does not prove an unchanged backing route.

A process can exit between catalog and metadata reads. Only that object's `!obj` error is recorded as a structured inventory issue with a stderr notice; other errors propagate. Playback preflight requires an issue-free catalog rather than overlooking an unknown mixer.

Reports contain identities, stream maps, callback layouts, tone amplitudes, unity-error metrics, and timing. No audio files are saved or uploaded; short sample captures exist only in RAM. Reports can include local app identities, PIDs, device names and UIDs, so `reports/` is ignored by Git. Keep raw reports local; share the sanitized results document instead.

Offline tests cover bounds, stereo interleaved/planar layouts, summing, six sample rates, smoothing/mute, silent inputs, nonfinite samples, malformed/oversized buffers, immediate capture, and transition-error detection under AddressSanitizer and UndefinedBehaviorSanitizer.

These checks do **not** establish physical loopback equivalence, no direct-path duplication, end-to-end latency, protected audio compatibility, browser-helper churn, PID reuse, sleep/wake, output hotplug, eight-app resource scaling, or older-OS runtime compatibility. Successful sequential tap updates on one output do not establish an atomic HAL transaction. Automatic recovery remains a prototype feature until the production mixer is integrated. Complete the remaining Phase 1 gates before product integration.
