# Aural: guide for future updates

Use this guide to plan, build, and verify changes without losing saved presets or changing someone's sound unexpectedly. It describes the current expandable workspace; check the repository and GitHub Releases before choosing the next version number.

The [user guide](USER-GUIDE.md) explains current behavior. The [feature comparison](PEACE-FEATURE-ROADMAP.md) tracks gaps against Peace and Equalizer APO. The [release guide](RELEASING.md) covers packaging, signing, and publication.

## What to work on next

These are proposed priorities, not promised release dates. Keep each update focused enough to verify independently.

| Order | Update | Size | What completion should demonstrate |
| --- | --- | --- | --- |
| 1 | Refresh release screenshots for the expandable workspace | Small | Real captures show the shared workspace, selected-filter inspector, faders, and stereo controls. Check first-run output selection, long preset names, keyboard access, and the smallest supported window. |
| 2 | Verify device recovery on hardware | Medium | Resume after sleep, reconnection, and format changes is implemented, along with optional following of the macOS output. Test headphone unplug/replug, USB and Bluetooth outputs, sleep/wake, sample-rate changes, and permission failures on real devices. Recovery must use the intended device, and Cancel or Stop must end it. |
| 3 | Add recoverable settings and complete settings backup | Medium | A damaged file produces an actionable error. A validated recovery copy can restore preferences and per-output settings, with an explicit choice before replacing current data. Existing preset-only backups continue to work. |
| 4 | Expand accessibility and language options | Medium | System, Light, and Dark themes are implemented. Review VoiceOver names, focus order, contrast, and text sizes. Add translations with checks for clipped labels and locale-specific number entry. |
| 5 | Extend advanced EQ in small steps | Medium to large | Start with a clearly defined filter addition, such as higher-order crossovers, with measured response and phase tests. Convolution, live spectrum, plug-ins, and multichannel routing need separate designs and hardware checks. |

Signed packaging and Sparkle update feeds follow the production workflow in RELEASING.md. AutoEQ search uses the public results index and parametric exports; keep its source attribution, original result links, and license information visible. Follow the feature comparison for larger projects rather than bundling them into a routine bug-fix update.

## Behavior to preserve

- **Details change the controls shown, not the sound.** One workspace retains the preset pane and curve. The persisted `interfaceMode` values remain compatible: `easy` collapses details and `professional` expands them. All commands remain available in either state. Pending numeric edits must submit before selection, disclosure, or page changes; rejected edits keep their controls visible. Graph selection opens the selected-filter inspector. Hidden details must leave no inaccessible focused field behind.
- **Editing is deliberate.** Ordinary EQ edits, undo/redo, and A/B keep the current running and bypass states. Applying a saved preset starts EQ and turns bypass off. A valid import stops processing; invalid import must leave the current sound intact.
- **Bypass and Stop remain distinct.** Bypass skips EQ, preamp, and stereo effects while routing remains active. Peak protection follows its saved On/Off switch, including during Bypass. Keep it enabled by default, independent of presets, outputs, history, and A/B. Stop releases the audio connection. Aural does not change the Mac's default output. Optional **Follow macOS output** only reacts to macOS switches; it saves before publishing, skips unsupported outputs with a notice, and keeps EQ on only if it was running or waiting.
- **Recovery resumes only what was running.** Sleep, disconnect, and format changes create a resume wait for the same output UID, with no deadline. Launch waits keep their 60-second limit. A resumed start retries at most three times, and a failing route restarts at most once per 30 seconds. Cancel and Stop always end a wait, and Bypass is kept across a resume.
- **Level matching changes playback, never saved values.** The bypass gain and the louder A/B version's offset come from a K-weighted pink-noise estimate of EQ, preamp, trims, and balance at a fixed 48 kHz. The offset is never positive. Off must reproduce the original, unmatched output exactly, and the curve keeps showing the EQ shape.
- **Loudness compensation follows the volume, not the EQ.** It stays out of presets, A/B, undo, the curve, Auto preamp, and level matching, and Bypass skips it. Each output keeps its own reference volume, captured on the first reading so turning compensation on never changes the sound at once. At or above the reference it adds nothing; below, it only boosts, relative to 1 kHz, and relies on peak protection. Keep `Profile.maxFilters`, the two tilt shelves, and `Loudness.filterCount` within `EQMaxFilters`.
- **Preset identity follows the sound.** Preserve the selected preset, modified indicator, per-output settings, favorites, and exact imported numbers. A/B and undo history currently reset on output changes and app quit.
- **Close and Quit remain distinct.** Closing the last window leaves EQ and menu-bar controls running and hides the Dock icon. Quit stops EQ and exits. Minimized windows retain Dock access.
- **Icon states stay consistent.** Processing with bypass off uses `AppIconActive` (the lit curve with nodes); stopped or bypassed uses `AppIcon`. Check the main window, About, and Dock together. The artwork is drawn by `scripts/draw-icon.swift`; see [ICON.md](ICON.md).
- **Themes change appearance, not sound.** System releases both native and SwiftUI appearance overrides. Light/Dark apply to all presentations, including open drafts and graphs whose EQ has not changed. All themes use the fixed `AuralStyle.accent`, not the macOS accent; prominent button labels choose contrasting ink. Native controls are tinted with `AuralStyle.staticAccent(for:)`, a plain sRGB color per scheme: bridging a dynamic `NSColor` into `.tint` can turn popup arrows red under older SDK compatibility. Borderless menus use `.tint(.primary)` so their labels read as text, not links. Persist before publishing a theme; failed saves retain the previous choice and show an error. Missing theme fields retain Dark.
- **A serious, solid instrument look.** No translucency, materials, gradients, or washes. The header and footer are docked full-width bars on `surface`, separated from the `background` workspace by hairline dividers; cards use `auralWorkspaceSurface` (6 pt radius, 1 px `border`). Separate control groups with vertical hairlines rather than floating pills, and keep corner radii between 4 and 6 pt. Reserve the accent for state and data — the curve, selection, Start EQ, checked options, and the meter — and amber for warnings; window badges and empty states stay neutral. Keep Light/Dark/System themes independent of audio. Retired `interfaceStyle` values are validated on load and omitted on the next save; never reset presets, output, EQ, or startup preferences during migration. Keep every `AuralMotion` animation: relocation fades, symbol transitions, and press/focus feedback.
- **Keep the brand and shared controls consistent.** Use the compact Aural header and processing-driven EQ-curve icon. The curve and faders show actual active filter frequencies. Graph selection and dragging must not convert or flatten the EQ. A graph drag freezes its coordinate scale, groups frequency/gain changes into one undo step, and preserves Q, type, channel, disabled state, and playback. Keep the pointer target attached while background response analysis updates. Abort a drag if another action replaces the EQ or output; graphic-to-parametric conversion remains explicit. Imported metadata, disabled state, and precision stay intact. Keep preset selection in the workspace dropdown; filter panel placement determines the graph width. Preserve grouped favorites, personal and factory presets, and access to preset management. Retain native filter editors across Selected, All rows, Faders, and disclosure changes; hidden editors must be disabled and excluded from pointer and accessibility navigation. Use `--benchmark-rack` to measure actual native segmented-control switches in the full workspace. Selecting a graph point opens exact values even after using faders. Keep all filters reachable through the selected-filter picker when graph points overlap or lie outside its frequency range.
- **Panel placement is audio-neutral.** Keep one retained `AuralWorkspaceLayout` for Below graph and Right of graph. Save `filterPanelPosition` before publishing it; legacy settings default below. The side inspector uses available height and the graph yields width. Compact filter rows wrap existing native fields rather than constructing replacement editors. Preserve focus, partial numeric drafts, history, A/B, and output across placement, resize, and zoom changes. Keep the placement menu and View command consistent. Test both layouts at 900 × 620 and 140% zoom, including stereo controls.
- **Reset EQ is one deliberate, undoable edit.** All presentations use the same Model action after submitting pending numeric input. Reset clears band gains and preamp while preserving frequency, Q, filter type, channel, enabled state, source identity, and stereo settings. It retains playback/bypass state and supports one-step Undo and Redo. Creating a new flat template remains a separate explicit action.
- **Keep metering and analysis separate from document updates.** Only the meter observes output peaks and protection gain reduction. Retain interval maxima so a brief peak survives until the next display update; equal readings and inactive gestures must not publish changes. Protection stays linked across channels and active in bypass; show Ready while stopped, On while routed, and Reducing with the measured attenuation. Login-status XPC and numerical EQ analysis run outside the main actor; cancelled or outdated work must not overwrite newer edits. Keep the audio callback unchanged by UI performance work.
- **Errors must be visible.** Validate before accepting changes. A rejected audio update keeps the accepted EQ. If saving fails after an audio edit was accepted, keep that live edit visible and undoable and report the save failure.
- **Saved data stays compatible.** Add defaults or migrations for new fields; reject corrupt values explicitly. APO text export must reject settings it cannot represent. Complete stereo settings belong in native preset backups.

Keep public labels plain: “preset,” “output,” “EQ curve,” and “Show details / Hide details.” Introduce audio terminology where it helps someone make an adjustment, with a short explanation when needed.

Keep the listening bar focused on output, processing status, Bypass, and Start/Stop. Put Save beside the preset and keep Undo/Redo and labeled A/B comparison visible in the workspace. AutoEQ, Files, and EQ options belong with these editing tools. Responsive rows must retain control identity and pending input; check long preset/output names and the 900 × 620 window at 140% zoom. Status must remain readable without depending on color, and Stop must still work when a numeric edit is invalid.

## Where changes belong

| Area | Main files |
| --- | --- |
| App state, applying edits, persistence, startup | [Model.swift](../Sources/Aural/Model.swift), [Profile.swift](../Sources/Aural/Profile.swift), [Startup.swift](../Sources/Aural/Startup.swift) |
| Shared workspace and retained legacy views | [MainView.swift](../Sources/Aural/MainView.swift), [EasyModeView.swift](../Sources/Aural/EasyModeView.swift), [StudioControls.swift](../Sources/Aural/StudioControls.swift) |
| Menus, shortcuts, startup settings | [Aural.swift](../Sources/Aural/Aural.swift) |
| Numeric entry and filter editing | [PrecisionInput.swift](../Sources/Aural/PrecisionInput.swift), [UIStyle.swift](../Sources/Aural/UIStyle.swift), [FilterRack.swift](../Sources/Aural/FilterRack.swift), [FilterEditor.swift](../Sources/Aural/FilterEditor.swift) |
| Presets, history, A/B, import/export | [PresetLibrary.swift](../Sources/Aural/PresetLibrary.swift), [ProfileWorkspace.swift](../Sources/Aural/ProfileWorkspace.swift), [AutoEQ.swift](../Sources/Aural/AutoEQ.swift) |
| Online AutoEQ catalog, search, preview | [AutoEQCatalog.swift](../Sources/Aural/AutoEQCatalog.swift), [AutoEQBrowserView.swift](../Sources/Aural/AutoEQBrowserView.swift), [CatalogChecks.swift](../Tests/PerformanceTests/CatalogChecks.swift) |
| Harman acoustic graph references | [HarmanReference.swift](../Sources/Aural/HarmanReference.swift), [bundled targets and provenance](../Sources/Aural/Resources/Targets/README.txt) |
| Audio routing and processing | [Audio.swift](../Sources/Aural/Audio.swift), [ProfileDSP.swift](../Sources/Aural/ProfileDSP.swift), [DSP.c](../Sources/DSP/DSP.c), [DSP.h](../Sources/DSP/include/DSP.h) |
| Curves, Auto preamp, stereo controls | [ResponseAnalysis.swift](../Sources/Aural/ResponseAnalysis.swift), [ResponseCurve.swift](../Sources/Aural/ResponseCurve.swift), [Headroom.swift](../Sources/Aural/Headroom.swift), [StereoPanel.swift](../Sources/Aural/StereoPanel.swift) |
| Window and icon behavior | [WindowPresence.swift](../Sources/Aural/WindowPresence.swift), [AppIcon.swift](../Sources/Aural/AppIcon.swift) |
| Update checking and release files | [ReleaseInfo.swift](../Sources/Aural/ReleaseInfo.swift), [Updates.swift](../Sources/Aural/Updates.swift), [VERSION](../VERSION), [build.sh](../scripts/build.sh), [package.sh](../scripts/package.sh) |

Theme preferences live in `Settings` and `Model`; shared adaptive colors, the fixed accent, and presentation styling live in `UIStyle.swift`; animation timing lives in `Motion.swift`. `Aural.swift` also applies the color theme to AppKit menus and panels; AppKit-native UI such as alerts keeps the system accent.

The internal names `EasyModeView` and `ProfileWorkspace` do not need cosmetic renaming to match public labels.

## Build each change safely

1. Read the relevant code and existing tests. Write a short before/after example and define how to prove the result. Record unrelated local changes before editing.
2. Follow existing validation and commit paths in `Model`; reuse helpers before adding new state or UI-specific copies of processing logic. Keep new optional audio effects neutral by default.
3. Cover every entry point: main window, menu bar, keyboard shortcuts, presets, A/B, imports, and collapsed/expanded details. A feature is incomplete if one route silently behaves differently.
4. Add focused regression tests for bugs and behavior changes. Check the actual native app for focus, layout, window, and audio-routing behavior that pure tests cannot demonstrate.
5. Update the user guide, README, release notes, and feature comparison when behavior or supported formats change. Keep unfinished features clearly marked as proposals.

### Numeric edits and drafts

Use `PrecisionField` and `PrecisionSubmissionCoordinator` for new exact-value controls. A macOS popup can leave a number field focused: submit pending input before an action copies, exports, saves, or changes related settings. Invalid input should remain visible for correction. Do not use an old filter snapshot after another field has already committed.

Keep the live revision check so a late callback cannot overwrite a different preset. Untouched rounded display text must retain the imported number's full precision, while an intentional edit to that displayed value must be accepted. Opening an unchanged draft must not immediately mark it stale. If the active EQ changes while a draft is open, require an explicit reload before applying it.

Keep slider drags grouped into one Undo step and end that group before unrelated actions. Preserve ordinary text-field undo/copy/paste shortcuts.

### Audio changes

AutoEQ catalog work must preserve all measurement variants and use the published result path rather than guessing filenames from search text. Search stays local after catalog loading. Downloads run outside the audio callback and main-thread parsing path, use bounded responses, and surface HTTP/format failures. Selection changes and window closure cancel pending work; stale results must never become importable. Validate before stopping audio, retain imported precision/source metadata, avoid overwriting presets, and keep import undoable. Test malformed catalogs, URL encoding, offline refresh, failed downloads, cancellation, and out-of-order responses. `theme-tests --check-autoeq-live` is an optional live catalog/profile smoke check; the standard suite uses deterministic HTTP fixtures.

Prepare coefficients and control changes outside the audio callback. Keep the callback free of allocations, locks, file access, logging, and Swift/UI calls. Maintain bounded queues, fault reporting, and smooth transitions when controls change quickly.

Preserve unchanged filter history during preamp changes. Test both channels, disabled filters, bypass, extreme valid settings, malformed buffers, and supported sample rates. The displayed EQ curve excludes stereo effects and limiting; Auto preamp estimates steady-state gain and is not a guarantee against every transient or intersample peak. Do not silently broaden those claims.

### Accessibility

Harman references are display-only acoustic target curves normalized at 1 kHz, separate from EQ gain, A/B comparison, and headroom. Preserve the published samples and license, log-frequency interpolation, sample-rate clipping, and explicit distinction in the legend and accessible inspection values. Never apply the target as EQ or imply that an EQ transfer curve measures a headphone’s acoustic response. Bundle targets in SwiftPM and signed app builds, and copy them into native test/benchmark fixtures. Automatic in-ear selection comes from saved AutoEQ source metadata; it does not claim that a correction was generated using that target.

Custom faders and curve inspection use native slider accessibility representations; the output meter uses a progress indicator. Keep the adjustable representation on filters with a gain parameter only. Fader arrows and the zero/reset action use the shared editing path and remain undoable. Curve Left/Right arrows inspect frequencies without editing EQ; Escape clears inspection. Pointer hover must not erase an assistive inspection position.

Keep curve points ordered by filter number inside their own accessibility group, so their sort priorities do not reorder the rest of the window. Report balance direction, actual stereo width/crossfeed percentages, trim in decibels, and output peaks in decibels relative to full scale. Rejected precision input announces its valid range; the focused window announces new notices and update results. Bypassed filters retain readable text and use checkbox state and dashed curve-point outlines to communicate bypass.

Verify the native accessibility tree in the disposable design preview for collapsed details, Selected, All rows, Faders, Stereo & delay, drafts, presets, and settings. Check keyboard focus visibly, as well as names and roles. Direct queries in the standalone AppKit test harness expose hidden backing views rather than SwiftUI's complete virtual accessibility tree; they cannot establish VoiceOver navigation. The suite covers inspection state and rendered palette contrast, including alpha compositing; native checks cover the representations and actions. Check Increase Contrast in both appearances, and keep graph/reference/filter traces readable without relying on color alone.

Remaining review work includes a full VoiceOver speech/navigation pass and the system Increase Contrast setting. Interface zoom scales text, controls, spacing, and hit targets together from 80% to 140% with ⌘+/⌘− and resets with ⌘0. Keep numeric editor identity and unsubmitted text intact; the main window keeps its size while the graph yields space and the inspector scrolls. Verify minimum-size layouts at both zoom limits. Translations remain follow-up work.

## Verification

Run from the repository root on macOS with Xcode or Command Line Tools. The custom test script runs twelve suites; `swift test` alone does not run this coverage.

For native dropdown tint regressions, run the theme-test executable in a disposable preview bundle with identifier `local.aural.performance-preview.accent`. Match the installed app's SDK compatibility version (inspect `LC_BUILD_VERSION` with `vtool`), bring the preview to the foreground, and compare its system-reference and Aural popup arrows in Light and Dark. Palette tests and offscreen snapshots do not exercise this native indicator rendering path.

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

For native checks, replay the bugs that prompted the last sweep: type a gain then choose a channel without Return; try an invalid number then select another graph point or hide details; reopen the app to check the saved disclosure state; open a draft after editing; and change the active EQ while that draft is open. Change a channel, toggle individual filter curves, and load a flat preset: every graph should redraw immediately. Also check closing/reopening from the menu bar and starting/stopping on the intended output.

For performance work, run `bash scripts/benchmark-ui.sh` separately from tests and packaging. It builds an optimized, disposable-data harness for 10/31-band workspace layout and curve analysis. Record first construction separately from inspector disclosure; compiler load and background apps affect timings. Sampling the live app is also necessary to identify idle publications or synchronous system calls. Native controls and SwiftUI layout must remain on the main thread.

Use a separate test account or disposable data for screenshots and destructive recovery tests. If personal settings must be backed up, quit Aural first, preserve `~/Library/Application Support/Aural/settings.json`, and avoid restoring an older copy over changes made during testing. Inspect the saved image itself: confirm the inspector state, labels, visible controls, and absence of personal data before adding it to the README.

## Prepare and publish an update

1. Choose the next version based on the actual changes. Use a patch update for fixes, a minor update for compatible features, and document any breaking migration explicitly.
2. Update `VERSION`, increment the numeric `CFBundleVersion` in `scripts/build.sh`, and write `docs/RELEASE-<version>.md`. Update the README and screenshots where needed.
3. Test and package the final source. Commit only the intended files and push. Confirm GitHub checks for that exact commit before publication.
4. Tag the verified commit and publish the matching DMG, ZIP, and `SHA256SUMS.txt` using the [release guide](RELEASING.md). For example, version `1.0.1` must use tag `v1.0.1` and assets `Aural-1.0.1-universal.dmg` and `Aural-1.0.1-universal.zip`. Older versions derive exact filenames from the tag; shortened tags can break their download link. Version 1.3 and newer also require the signed appcast.xml release asset.
5. Verify the public release's version, notes, asset names, download links, and checksums. Check **Check for Updates** from an older installed version. Record what was actually tested and the release verification results.

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
