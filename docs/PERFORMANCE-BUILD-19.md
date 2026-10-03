# Local build 19

Follow-up to [build 18's performance sweep](PERFORMANCE-BUILD-18.md). Version 1.0.0 remains unchanged; this is a local update.

Both mode panels now prepare at startup, after inexpensive native loading blocks have had a chance to draw. Native controls and layout stay on the main thread; numerical analysis and system login-status reads use their workers. The latest requested mode wins during preparation. After preparation, switching reuses the existing controls and detaches the inactive panel from focus and accessibility.

Simple and Professional share visual gain bars at the active EQ's actual frequencies and gains. Changing views does not replace the EQ with a flat template. New flat templates are explicitly labeled under New EQ in Professional. The bars change the active band's gain through the existing validated, persisted profile-edit path and coalesce a drag into one undo step. They preserve imported frequency, Q, filter type, channel, and enabled state. Pass, notch, and all-pass filters show inactive gain controls. Bars support pointer dragging, double-clicking to flatten one band, arrow keys, and accessibility adjustment. Professional retains its exact numeric Rows editor and aligned pinned headings. Bar height follows the available pane height, keeping frequency labels and enable controls inside the minimum Professional viewport.

Both modes retain the AURAL EQUALIZER header. Simple uses the available space for EQ bars, output selection, preamp/Auto preamp, balance, mono, width, headphone blend, level metering, and Undo/Redo. Its control cards switch between one and two columns according to pane width. Resetting Listening preserves advanced trims, delays, and polarity.

Native dividers resize the Simple preset/control panes, all three Professional panes, and the preset library. Each mode retains its custom widths across switches. Minimum widths and scroll views keep controls reachable when the window shrinks. Pane widths are view state; this change does not add audio settings or promise persistence after quitting.

## Verification

The native regression harness covers startup placeholders, complete two-panel preparation, requests made during preparation, retained controls and focus release, pane dragging, independent pane widths across mode switches, minimum viewport bounds, gain-position mapping, gain limits, exact gain precision, drag undo, shared mode edits, imported filter preservation, and gainless filter rejection. Other build 18 performance and theme checks remain in the suite.

`bash scripts/benchmark-ui.sh` creates separate disposable 10-band and 31-band startup fixtures, measures preparation separately from subsequent switches, and renders both minimum viewports. `AURAL_BENCH_CAPTURE_DIR` saves startup, Professional minimum, Simple minimum, and Simple wide captures. UI measurements are individual observations under current desktop load, not a latency guarantee.

The final optimized run measured 515 ms startup preparation for ten bands and 824 ms for 31 bands, covered by the startup blocks. Subsequent ten-band layouts took 40–67 ms and 31-band layouts took 116–130 ms, including the first switch after preload. Saves took 0.7–2.6 ms except one 13 ms observation. Response analysis averaged 0.36–0.44 ms for ten boosted bands and 1.02–1.26 ms for 31 alternating boosted/cut filters. Earlier runs under heavier desktop load measured slower preparation and switches; these are not controlled before/after percentages.

All twelve regression suites passed, followed by the final optimized theme/performance harness. Native pointer checks verified divider dragging, bar dragging, keyboard and accessibility adjustment, the double-click reset gesture, matching imported frequencies/gains in both modes, retained preamp, and numeric heading alignment. The imported fixture had ten nonflat bands at custom frequencies, including 42.3456789 Hz and 943.7 Hz.

## Build 20 follow-up

Reset EQ is now available beside the bars in both modes. It resets adjustable gains and preamp to 0 dB through the shared validated edit path, preserving filter frequencies, Q, types, channels, enabled state, and stereo settings. One Undo restores the complete prior EQ; Redo reapplies the reset. Pending numeric input uses the existing submission coordinator before reset. The tests cover reset metadata preservation and one-step undo/redo. The measurements above belong to build 19.

All twelve regression suites passed for build 20. Native checks on an isolated imported EQ verified Reset EQ and Undo in both modes, including the retained custom frequencies and restored preamp. The signed universal build was installed and relaunched; the latest settings were preserved byte for byte during replacement. The installed app shows Reset EQ in both modes, retains the user's current frequencies and gains, and resumes audio processing through its saved startup preference.

## Release 1.1

Build 21 packages the verified changes as version 1.1.0. The [condensed release notes](RELEASE-1.1.0.md) summarize the update. Import/updater regression checks, universal compilation, strict signatures, DMG verification, ZIP/DMG app equality, installer contents, and SHA-256 checks passed. The installed app reports Version 1.1.0 (21) in About, preserves the latest saved settings, and resumes audio processing. These checks were completed locally before publication.

Release build 22 makes the drag-position conversion from `CGFloat` to `Double` explicit, resolving an operator ambiguity found by the macOS 15 CI compiler. The gain mapping and measurements above are unchanged.

The pane regression checks wait for SwiftUI to attach the requested mode before inspecting its native dividers. This accommodates asynchronous observed-model rendering on macOS 15 without skipping any resizing or state-preservation assertions.
