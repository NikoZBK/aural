# Aural feature audit: Peace and Equalizer APO

Audited October 2, 2026 against the official [Peace feature list](https://sourceforge.net/projects/peace-equalizer-apo-extension/), [Peace feature FAQ](https://sourceforge.net/p/peace-equalizer-apo-extension/wiki/Features%20FAQ/), and [Equalizer APO configuration reference](https://sourceforge.net/p/equalizerapo/wiki/Configuration%20reference/). This inventory distinguishes implemented native behavior from remaining work; Aural does not claim full APO compatibility.

## Implemented in the 1.0.0 workspace

| Workflow | Aural implementation |
| --- | --- |
| Configurable graphic/parametric EQ | Ten octave bands, a 31-band third-octave template, and up to 32 editable parametric filters. The 31-band layout is a peaking-filter bank, not APO `GraphicEQ` interpolation. |
| Channel-specific EQ | Every filter targets stereo, left, or right; curves and processing follow those targets. 32 filters total across the stereo chain. |
| Exact control | Frequency, gain, Q, type, and enabled state in the main rack; an optional draft editor offers preview before applying. |
| Editing tools | Main-workspace undo/redo, duplicate/delete/add, gain offset, gain scaling/inversion, and frequency shifting. Draft editing additionally supports filter reordering. |
| Comparison | Independent session-local A/B snapshots with reference curves, including stereo settings and preset identity. |
| Response analysis | Actual DSP coefficients, independent L/R curves, individual filter overlays, logarithmic frequency inspection, adaptive dB range, and estimated headroom. This is a transfer-function plot, not an FFT spectrum analyzer. |
| Stereo effects | Left/right trims, balance, width, normalized low-frequency crossfeed, mono sum, polarity inversion, and fractional channel delay. Defaults preserve the previous audio path. |
| Gain management | Master preamp, automatic headroom including stereo gain, output sample peak, peak hold/reset, and linked sample-peak protection. |
| Presets | Search, favorites, named save, rename/duplicate/delete with latest-delete recovery, preview graph, and versioned JSON backup/restore. |
| Output management | Saved profile and preset identity per output; explicit output selection, refresh, auto-start for the saved device, and recovery from stale device records. |
| Interoperability | AutoEQ parametric/fixed-band text, clipboard and file import/export, and `Channel: ALL/L/R`. Unsupported commands fail with line-specific explanations. |
| Desktop operation | Menu-bar transport, presets, preamp and A/B; window close keeps processing and removes the Dock icon. Launch-at-login and application keyboard shortcuts. |

## Existing processing retained

Peaking, Q-based low/high shelf, second-order low/high pass, band-pass, notch, and all-pass filters are implemented. Live control updates use prepared coefficients and preallocated chains. Audio callbacks allocate no memory, acquire no locks, perform no file I/O, and make no Swift/UI calls. Channel/stereo additions preserve default output and complete bypass semantics; the safety limiter remains active during bypass.

## Remaining gaps and prerequisites

| Reference capability | Current boundary | Work needed before implementation |
| --- | --- | --- |
| Surround and arbitrary routing | One stereo output stream; independent L/R filters and calibration only | Channel-layout model, multichannel taps, routing matrix, real 5.1/7.1/USB hardware validation. |
| Convolution / APO `GraphicEQ` | Unsupported and explicitly rejected | Realtime partitioned convolution, impulse loading/resampling, latency reporting, offline response and realtime stress tests. A peak-filter approximation would not preserve APO semantics. |
| Higher-order crossover filters | Second-order LPQ/HPQ only | Cascade/order model, Butterworth/Linkwitz-Riley definitions, response and phase tests, matching import semantics. |
| VST or Audio Unit hosting | No plug-in host | Audio Unit lifecycle, state recall, latency compensation, crash isolation, and permission behavior. Windows VST binaries cannot run natively. |
| Online headphone catalog | Import supported AutoEQ text files | Provider adapter with measurement/target provenance, dataset licensing review, cached search, preview and rollback. No imported correction data is bundled. |
| Device/app automation, layered presets | Saved-device startup and profile restore | Explicit rule precedence, device arrival recovery, per-app routing support, composable processing stages. |
| Global hotkeys / MIDI | Shortcuts while Aural is active; menu-bar controls | Conflict-aware global registration and editable assignments; CoreMIDI mapping with a serialized control path. |
| Live spectrum / measurements | EQ transfer plot and output sample peak | Bounded FFT telemetry outside the realtime callback, calibration, measurement metadata and validation. |
| Hearing/test-tone workflows | No generated tones or hearing assessment | User-controlled level/ramp/mute, separate calibration flow and validated playback behavior. |
| Full APO command language | Strict documented subset | Native equivalents for routing, includes, expressions and per-channel preamp, with explicit semantics and sandboxed file resolution. |
| Localization and light appearance | English, dark workspace | String catalogs, locale-aware numeric entry, translated layouts and accessibility review. |

These gaps require distinct engine, hardware, or provider work. They are not represented by inactive buttons or simulated controls in the UI.

## Verification contract

Every DSP feature requires default-equivalence, per-channel isolation, bypass, bounds, transition, and multi-rate tests. Import must reject unsupported semantics without changing sound. Old saved profiles must decode without losing precision. UI changes must be checked in the native app at default and minimum sizes, with long preset names and keyboard access. Universal compilation is separate from runtime verification on physical Intel hardware.
