# Aural 0.9.0 — Ultra interface

Aural now gives the response curve and filter chain a dedicated workspace, with everyday controls in a compact side rail. The main window and preset library resize, and the main workspace scrolls on shorter screens.

## Interface

- Charcoal surfaces, a restrained lime accent, larger readable controls, and consistent panels across the app.
- Output selection, Bypass, and Start/Stop share one transport strip. Processing, Bypassed, and Stopped have distinct text and color.
- A larger response graph with readable frequency and dB axes. Hover or use accessibility increment/decrement actions for the exact frequency and combined filter/preamp response. The frequency domain ends below Nyquist at lower sample rates. The drawing clips at ±24 dB; the readout retains the actual value.
- Preamp, automatic headroom, and an output peak readout in dBFS grouped together. The response view skips redraws from unrelated peak updates.
- Direct Copy/Paste buttons, file import/export menu, quick preset selection, library access, and named preset saving.
- Numbered filter rows, explicit enabled states, per-filter accessibility labels, and a clearly separated Apply/Cancel workflow. Undo/Redo also have Command-Z/Shift-Command-Z shortcuts.
- Searchable preset master/detail window with readable rows, no-results states, favorites, and all existing library actions. Hidden or deleted selections no longer leave stale actions enabled.

## Compatibility

The DSP, Core Audio routing, settings format, and existing import/apply behavior are unchanged. Presets and Apply start EQ if stopped; importing or pasting stops processing until Start EQ. Graphic-band gains and imported filter values keep their precision until edited.

## Verification

- Debug build passed.
- Full sanitizer DSP, Swift parser/editor/library/startup, and Swift/C bridge suite passed.
- Universal arm64/x86_64 build and strict ad-hoc signature verification passed; installed binary matches the packaged build.
- Native inspection covered compact and expanded main windows, the preset library, filter studio, an invalid-preamp error, and accessible frequency inspection.
- The final source, tests, build scripts, and version match the package snapshot. The final installation preserved the latest saved settings, including the current preamp.
- On the final restart, the existing startup stall recurred in `HAL_HardwarePlugIn_DeviceStart`. A process sample was retained locally; this UI release does not claim to fix that audio-lifecycle problem. Terminating the stalled Aural process and relaunching recovered processing. The final native check showed Processing through the saved output, with the prior profile and preamp unchanged and a nonzero output peak. Saved settings remained identical to the final-install backup.

The previously observed intermittent Core Audio startup stall has not been addressed by this UI release. Intel remains cross-compiled; native runtime verification uses Apple silicon. This is a local ad-hoc-signed build, not a published release.
