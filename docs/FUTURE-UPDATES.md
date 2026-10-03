# Aural: guide for future updates

Use this guide to plan, build, and verify changes without losing saved presets or changing someone's sound unexpectedly. It describes the code at version 1.1.0; check the repository and GitHub Releases before choosing the next version number.

The [README](../README.md) explains current behavior. The [feature comparison](PEACE-FEATURE-ROADMAP.md) tracks gaps against Peace and Equalizer APO. The [release guide](RELEASING.md) covers packaging, signing, and publication.

## What to work on next

These are proposed priorities, not promised release dates. Keep each update focused enough to verify independently.

| Order | Update | Size | What completion should demonstrate |
| --- | --- | --- | --- |
| 1 | Refresh screenshots and finish Simple-mode polish | Small | Real captures show **Simple / Professional**, the correct selected mode, and readable controls. Check first-run output selection, long preset names, keyboard access, and the smallest supported window. |
| 2 | Improve device recovery | Medium | Test headphone unplug/replug, USB and Bluetooth outputs, sleep/wake, sample-rate changes, and permission failures. Any optional automatic recovery must use the intended device and have a clear way to stop it. |
| 3 | Add recoverable settings and complete settings backup | Medium | A damaged file produces an actionable error. A validated recovery copy can restore preferences and per-output settings, with an explicit choice before replacing current data. Existing preset-only backups continue to work. |
| 4 | Expand accessibility and language options | Medium | System, Light, and Dark themes are implemented. Review VoiceOver names, focus order, contrast, and text sizes. Add translations with checks for clipped labels and locale-specific number entry. |
| 5 | Extend advanced EQ in small steps | Medium to large | Start with a clearly defined filter addition, such as higher-order crossovers, with measured response and phase tests. Convolution, live spectrum, plug-ins, and multichannel routing need separate designs and hardware checks. |

Developer ID signing and notarization are a separate distribution improvement when credentials are available. A headphone catalog also needs clear data licensing and source information. Follow the feature comparison for those larger projects rather than bundling them into a routine bug-fix update.

## Behavior to preserve

- **Simple and Professional change the controls shown, not the sound.** Detailed adjustments stay active in Simple. Simple's preamp and listening controls share the same profile, validation, precision coordinator, and undo paths as Professional. Both panels prepare at startup behind inexpensive loading blocks and retain their native controls. New installs start in Simple; existing settings without a mode retain Professional. The saved value for Simple is still `easy`; preserve it or provide an explicit migration.
- **Editing is deliberate.** Ordinary EQ edits, undo/redo, and A/B keep the current running and bypass states. Applying a saved preset starts EQ and turns bypass off. A valid import stops processing; invalid import must leave the current sound intact.
- **Bypass and Stop remain distinct.** Bypass skips EQ, preamp, and stereo effects while routing and sample-peak protection remain active. Stop releases the audio connection. Aural does not change the Mac's default output.
- **Preset identity follows the sound.** Preserve the selected preset, modified indicator, per-output settings, favorites, and exact imported numbers. A/B and undo history currently reset on output changes and app quit.
- **Close and Quit remain distinct.** Closing the last window leaves EQ and menu-bar controls running and hides the Dock icon. Quit stops EQ and exits. Minimized windows retain Dock access.
- **Dog states stay consistent.** Processing with bypass off uses the closed-eyes dog; stopped or bypassed uses the listening dog. Check the main window, About, and Dock together.
- **Themes change appearance, not sound.** System releases both native and SwiftUI appearance overrides. Light/Dark apply to all presentations, including open drafts and graphs whose EQ has not changed. All themes use the native macOS accent; prominent button labels choose contrasting ink. Persist before publishing a theme; failed saves retain the previous choice and show an error. Missing theme fields retain Dark.
- **Keep the brand and shared controls consistent.** Both modes retain the AURAL EQUALIZER header and use the same visual gain bars and profile editing path. Bars show the active EQ's actual frequencies and gains, preserve imported filter metadata and disabled state, and do not create flat templates when changing views. Gainless filters are not gain-editable. A drag is one undo step. New flat templates are explicitly labeled under New EQ in Professional. Native pane dividers retain each mode's widths across switches and respect usable minimums; Simple's cards respond to their pane's available width. Simple's Listening reset changes only its visible settings, preserving advanced trims, delays, and polarity.
- **Reset EQ is one deliberate, undoable edit.** Both modes use the same Model action after submitting pending numeric input. Reset clears band gains and preamp while preserving frequency, Q, filter type, channel, enabled state, source identity, and stereo settings. It retains playback/bypass state and supports one-step Undo and Redo. Creating a new flat template remains a separate explicit action.
- **Keep metering and analysis separate from document updates.** Only the meter observes peak readings. Equal readings and inactive gestures must not publish changes. Mode panels retain their native controls but detach inactive panels from the window, focus, and accessibility hierarchy. Pass the SwiftUI environment across hosting boundaries. Login-status XPC and numerical EQ analysis run outside the main actor; cancelled or outdated work must not overwrite newer edits. Keep the audio callback unchanged by UI performance work.
- **Errors must be visible.** Validate before accepting changes. A rejected audio update keeps the accepted EQ. If saving fails after an audio edit was accepted, keep that live edit visible and undoable and report the save failure.
- **Saved data stays compatible.** Add defaults or migrations for new fields; reject corrupt values explicitly. APO text export must reject settings it cannot represent. Complete stereo settings belong in native preset backups.

Keep public labels plain: “preset,” “output,” “EQ curve,” and “Simple / Professional.” Introduce audio terminology where it helps someone make an adjustment, with a short explanation when needed.

## Where changes belong

| Area | Main files |
| --- | --- |
| App state, applying edits, persistence, startup | [Model.swift](../Sources/Aural/Model.swift), [Profile.swift](../Sources/Aural/Profile.swift), [Startup.swift](../Sources/Aural/Startup.swift) |
| Simple and Professional views | [MainView.swift](../Sources/Aural/MainView.swift), [EasyModeView.swift](../Sources/Aural/EasyModeView.swift), [StudioControls.swift](../Sources/Aural/StudioControls.swift) |
| Menus, shortcuts, startup settings | [Aural.swift](../Sources/Aural/Aural.swift) |
| Numeric entry and filter editing | [PrecisionInput.swift](../Sources/Aural/PrecisionInput.swift), [UIStyle.swift](../Sources/Aural/UIStyle.swift), [FilterRack.swift](../Sources/Aural/FilterRack.swift), [FilterEditor.swift](../Sources/Aural/FilterEditor.swift) |
| Presets, history, A/B, import/export | [PresetLibrary.swift](../Sources/Aural/PresetLibrary.swift), [ProfileWorkspace.swift](../Sources/Aural/ProfileWorkspace.swift), [AutoEQ.swift](../Sources/Aural/AutoEQ.swift) |
| Audio routing and processing | [Audio.swift](../Sources/Aural/Audio.swift), [ProfileDSP.swift](../Sources/Aural/ProfileDSP.swift), [DSP.c](../Sources/DSP/DSP.c), [DSP.h](../Sources/DSP/include/DSP.h) |
| Curves, Auto preamp, stereo controls | [ResponseAnalysis.swift](../Sources/Aural/ResponseAnalysis.swift), [ResponseCurve.swift](../Sources/Aural/ResponseCurve.swift), [Headroom.swift](../Sources/Aural/Headroom.swift), [StereoPanel.swift](../Sources/Aural/StereoPanel.swift) |
| Window and icon behavior | [WindowPresence.swift](../Sources/Aural/WindowPresence.swift), [AppIcon.swift](../Sources/Aural/AppIcon.swift) |
| Update checking and release files | [ReleaseInfo.swift](../Sources/Aural/ReleaseInfo.swift), [Updates.swift](../Sources/Aural/Updates.swift), [VERSION](../VERSION), [build.sh](../scripts/build.sh), [package.sh](../scripts/package.sh) |

Theme preferences live in `Settings` and `Model`; shared adaptive colors and presentation styling live in `UIStyle.swift`. `Aural.swift` also applies the theme to AppKit menus and panels.

The internal names `EasyModeView` and `ProfileWorkspace` do not need cosmetic renaming to match public labels.

## Build each change safely

1. Read the relevant code and existing tests. Write a short before/after example and define how to prove the result. Record unrelated local changes before editing.
2. Follow existing validation and commit paths in `Model`; reuse helpers before adding new state or UI-specific copies of processing logic. Keep new optional audio effects neutral by default.
3. Cover every entry point: main window, menu bar, keyboard shortcuts, presets, A/B, imports, and both interface modes. A feature is incomplete if one route silently behaves differently.
4. Add focused regression tests for bugs and behavior changes. Check the actual native app for focus, layout, window, and audio-routing behavior that pure tests cannot demonstrate.
5. Update the README, release notes, and feature comparison when behavior or supported formats change. Keep unfinished features clearly marked as proposals.

### Numeric edits and drafts

Use `PrecisionField` and `PrecisionSubmissionCoordinator` for new exact-value controls. A macOS popup can leave a number field focused: submit pending input before an action copies, exports, saves, or changes related settings. Invalid input should remain visible for correction. Do not use an old filter snapshot after another field has already committed.

Keep the live revision check so a late callback cannot overwrite a different preset. Untouched rounded display text must retain the imported number's full precision, while an intentional edit to that displayed value must be accepted. Opening an unchanged draft must not immediately mark it stale. If the active EQ changes while a draft is open, require an explicit reload before applying it.

Keep slider drags grouped into one Undo step and end that group before unrelated actions. Preserve ordinary text-field undo/copy/paste shortcuts.

### Audio changes

Prepare coefficients and control changes outside the audio callback. Keep the callback free of allocations, locks, file access, logging, and Swift/UI calls. Maintain bounded queues, fault reporting, and smooth transitions when controls change quickly.

Preserve unchanged filter history during preamp changes. Test both channels, disabled filters, bypass, extreme valid settings, malformed buffers, and supported sample rates. The displayed EQ curve excludes stereo effects and limiting; Auto preamp estimates steady-state gain and is not a guarantee against every transient or intersample peak. Do not silently broaden those claims.

## Verification

Run from the repository root on macOS with Xcode or Command Line Tools. The custom test script runs twelve suites; `swift test` alone does not run this coverage.

```sh
AURAL_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/aural-cache.XXXXXX")"
export CLANG_MODULE_CACHE_PATH="$AURAL_CACHE"
export SWIFT_MODULECACHE_PATH="$AURAL_CACHE"
bash scripts/test.sh
bash scripts/package.sh
codesign --verify --strict dist/Aural.app
xcrun lipo -archs dist/Aural.app/Contents/MacOS/Aural
(cd dist && shasum -a 256 -c SHA256SUMS.txt)
```

Run tests and builds sequentially against unchanged source. `package.sh` already builds the app, so a separate `build.sh` run is unnecessary for packaging. If a cloud-synced folder interferes with compilation or metadata, use a stable local copy with writable caches. Finder metadata can invalidate signatures; use the clean packaging flow and verify the final files.

The checks below combine automated suites with native app and failure-recovery checks; not every listed scenario is currently automated.

| Change | Required evidence |
| --- | --- |
| Filters, gain, routing, or stereo processing | DSP and engine suites with memory/error checks; Swift/C bridge; measured response, transitions, and channel isolation at 32, 44.1, 48, 96, and 192 kHz. Actual-device checks for routing changes. |
| Curves or Auto preamp | Response and headroom suites, including narrow boosts between sample points, filter centers outside the visible graph, overlapping filters, and left/right differences. |
| Presets, settings, imports, editing | Import, workflow, and precision suites; old settings, malformed files, exact numbers, failed saves, name collisions, and mode persistence. |
| Interface, windows, or icons | Native checks at default and minimum sizes; keyboard/focus checks; relevant window and icon suites. |
| Release or update checker | Universal build, strict signature, DMG verification, checksums, and release version/asset lookup tests. |

Before a release, run the complete suite and verify the exact commit in [GitHub Actions](https://github.com/NikoZBK/aural/actions). A universal executable proves both architectures compile; it does not prove physical Intel hardware was tested. Record hardware, macOS version, output type, sample rate, buffer size, test duration, and any untested areas for audio checks. Measure end-to-end latency separately from DSP throughput; processing speed alone does not establish what a listener experiences.

For native checks, replay the bugs that prompted the last sweep: type a gain then choose a channel without Return; try an invalid number then switch modes; reopen the app to check the saved mode; open a draft after editing; and change the active EQ while that draft is open. Change a channel, toggle individual filter curves, and load a flat preset: every graph should redraw immediately. Also check closing/reopening from the menu bar and starting/stopping on the intended output.

For performance work, run `bash scripts/benchmark-ui.sh` separately from tests and packaging. It builds an optimized, disposable-data harness for 10/31-band mode layout and curve analysis. Record first construction separately from retained-panel switches; compiler load and background apps affect timings. Sampling the live app is also necessary to identify idle publications or synchronous system calls. Native controls and SwiftUI layout must remain on the main thread.

Use a separate test account or disposable data for screenshots and destructive recovery tests. If personal settings must be backed up, quit Aural first, preserve `~/Library/Application Support/Aural/settings.json`, and avoid restoring an older copy over changes made during testing. Inspect the saved image itself: confirm the selected mode, labels, visible controls, and absence of personal data before adding it to the README.

## Prepare and publish an update

1. Choose the next version based on the actual changes. Use a patch update for fixes, a minor update for compatible features, and document any breaking migration explicitly.
2. Update `VERSION`, increment the numeric `CFBundleVersion` in `scripts/build.sh`, and write `docs/RELEASE-<version>.md`. Update the README and screenshots where needed.
3. Test and package the final source. Commit only the intended files and push. Confirm GitHub checks for that exact commit before publication.
4. Tag the verified commit and publish the matching DMG, ZIP, and `SHA256SUMS.txt` using the [release guide](RELEASING.md). For example, version `1.0.1` must use tag `v1.0.1` and assets `Aural-1.0.1-universal.dmg` and `Aural-1.0.1-universal.zip`. The updater derives exact filenames from the tag; shortened tags can break its download link.
5. Verify the public release's version, notes, asset names, download links, and checksums. Check **Check for Updates** from an older installed version. Record what was actually tested and the signing/notarization status.

A push and a published release are separate steps. GitHub Actions tests and packages; it does not publish releases. Keep credentials, user settings, and imported profiles out of commits and installers.

If a release must be withdrawn, preserve its source and investigation notes. Tell users which earlier version to use and whether its settings format is compatible. Test that downgrade with a copy of the settings before recommending it; do not assume newer fields or presets can be read by an older app.

## Handoff for the next update

Include this short record in the issue, pull request, or release notes:

```text
Problem and before/after behavior:
Source commit and version:
Affected controls, menus, file formats, and audio behavior:
Compatibility or settings migration:
Tests passed and native/hardware checks performed:
Screenshots and documentation updated:
Known limitations and remaining work:
Status: local / pushed / published
Release URL and asset checks, if published:
Recovery or downgrade instructions, if relevant:
```
