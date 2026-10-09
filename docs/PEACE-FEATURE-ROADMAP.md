# Aural compared with Peace and Equalizer APO

Checked October 2, 2026 against the official [Peace feature list](https://sourceforge.net/projects/peace-equalizer-apo-extension/), [Peace feature FAQ](https://sourceforge.net/p/peace-equalizer-apo-extension/wiki/Features%20FAQ/), and [Equalizer APO configuration reference](https://sourceforge.net/p/equalizerapo/wiki/Configuration%20reference/). The tables below show what Aural supports and what still needs work. Aural does not support every APO feature or command.

## Available in Aural 1.0.0

| Feature | What Aural provides |
| --- | --- |
| Configurable graphic/parametric EQ | Ten octave bands whose sliders set the exact level at each band frequency, a 31-band third-octave template, and up to 64 editable parametric filters. The 31-band layout is a peaking-filter bank, not APO `GraphicEQ` interpolation. |
| Channel-specific EQ | Every filter targets stereo, left, right, mid, or side; curves and processing follow those targets. Mid/Side filters run in list order between automatic left/right ↔ mid/side conversions, as with Equalizer APO's `Copy` routing. 64 filters total across the stereo chain, so separate left and right corrections can each use up to 32 (or any split). |
| Exact control | Edit frequency, gain, Q, type, and enabled state directly in the main window. The filter editor lets you preview a draft before applying it. |
| Tilt | A ±6 dB tilt around 1 kHz, from a pair of 6 dB/octave shelves after the filters. It is saved with the EQ and does not count toward the 64 filters. Equalizer APO text cannot carry it, so export asks for 0 dB. |
| Editing tools | Undo/redo, duplicate/delete/add, gain offset, gain scaling/inversion, frequency shifting, and band solo, which plays only the part of the spectrum one band acts on. The draft editor also lets you reorder filters. |
| Comparison | Edit and compare two A/B versions, including their stereo settings and preset names. Their curves appear together when they differ. Optional level matching plays Bypass and the louder version at the same K-weighted loudness estimate. A/B settings reset when changing output or quitting. |
| EQ curves | Separate left/right curves calculated from the actual filters, individual filter curves, frequency inspection, an automatically scaled dB range, and estimated headroom. This shows how EQ changes the sound, not a live FFT analysis of the music. |
| Stereo effects | Left/right trims, balance, width, normalized low-frequency crossfeed, mono sum, polarity inversion, left/right swap, and fractional channel delay. Defaults preserve the previous audio path. |
| Volume and peak protection | Preamp, **Auto preamp** that accounts for EQ and stereo gain, an output level meter, highest-level hold/reset, and linked true-peak protection with 1 ms look-ahead. |
| Loudness compensation | Optional compensation from the ISO 226:2003 equal-loudness contours that follows the macOS output volume below a per-output reference volume, with a 70–90 phon reference level. Equalizer APO's `LoudnessCorrection` is not imported or exported. |
| Presets | Search, favorites, save, rename/duplicate/delete, undo the latest deletion, curve previews, and versioned JSON backup/restore. |
| Audio outputs | Saved EQ settings and preset names for each output, device selection and refresh, automatic startup for the saved device, and skipping unavailable devices. Optional following of the macOS output. Running EQ resumes after sleep, on reconnection, and after a format change. |
| Import and export | AutoEQ parametric/fixed-band text and Room EQ Wizard filter files, clipboard and file import/export, every Equalizer APO biquad filter type with its Q, bandwidth, slope and default semantics, `Channel: ALL/L/R`, the mid/side `Copy` routing, and `Delay` in ms. Unsupported commands report the line that needs attention. |
| Menu bar and startup | Start/stop, bypass, presets, preamp, and A/B from the menu bar. Closing the window keeps EQ running and removes the Dock icon. Optional launch at login and keyboard shortcuts while Aural is active. |

## Audio processing

Peaking, Q-based and first-order (6 dB/octave) low/high shelf, second-order low/high pass, band-pass, notch, and all-pass filters are implemented. Live control updates use prepared coefficients and preallocated chains. Audio callbacks allocate no memory, acquire no locks, perform no file I/O, and make no Swift/UI calls. Channel/stereo additions preserve default output and complete bypass semantics; peak protection follows its saved On/Off switch during bypass.

## Added in Aural 1.1

- System, Light, and Dark themes are saved across launches and applied to all windows, graphs, menus, and native file panels. Every theme uses the macOS accent color. The original dark appearance remains the default.
- Liquid Glass is an optional, separately saved interface style on macOS 26 or later, using Apple's native material for controls and window chrome. Standard remains the default, with solid surfaces for content, older macOS, Reduce Transparency, and Increase Contrast.
- Simple and Professional share gain bars at the current EQ's actual frequencies. Imported filter metadata stays intact; Reset EQ resets gains and preamp with one-step Undo.
- Both mode panels prepare at startup. Response analysis and login-status checks use workers, and metering updates are isolated from the main model.
- Native dividers resize panes in both modes and the preset library. Simple adds everyday EQ, output, and stereo controls; responsive layouts keep them reachable.

## Online AutoEQ search

Online AutoEQ search is now implemented in the working tree: a searchable full catalog, measurement-source filters, HTTP caching, parametric curve previews, source attribution retained in presets/backups, validated import, and undo. No correction data is bundled. Search and preview leave audio unchanged; import follows the existing stopped-processing contract. Publication is a separate release step.

## Peak protection

The working tree now provides an On/Off checkbox beside the Level meter and in the Equalizer and menu-bar menus, alongside protection status and measured gain reduction. Protection is enabled by default and the choice persists independently of presets, outputs, undo, and A/B. The stereo-linked limiter follows this choice during Bypass too. It reads true peaks between samples (8x interpolation) and lowers the gain over 1 ms before each one, for a fixed latency of about 1.2 ms that does not change with the switch or Bypass. Brief output peaks and gain reduction are retained between display updates.

## What's still missing

| Feature | Current limit | Work needed |
| --- | --- | --- |
| Surround and arbitrary routing | One stereo output stream; independent L/R filters and calibration only | Channel-layout model, multichannel taps, routing matrix, real 5.1/7.1/USB hardware validation. |
| Convolution / APO `GraphicEQ` | Unsupported and explicitly rejected | Realtime partitioned convolution, impulse loading/resampling, latency reporting, offline response and realtime stress tests. A peak-filter approximation would not preserve APO semantics. |
| Higher-order crossover filters | Second-order LPQ/HPQ only | Cascade/order model, Butterworth/Linkwitz-Riley definitions, response and phase tests, matching import semantics. |
| VST or Audio Unit hosting | No plug-in host | Audio Unit lifecycle, state recall, latency compensation, crash isolation, and permission behavior. Windows VST binaries cannot run natively. |
| Device/app automation, layered presets | Saved-device startup, macOS output following, and resume after sleep or reconnection | Explicit rule precedence, per-app routing support, composable processing stages. |
| Global hotkeys / MIDI | Shortcuts while Aural is active; menu-bar controls | Conflict-aware global registration and editable assignments; CoreMIDI mapping with a serialized control path. |
| Live spectrum / measurements | EQ curve and output sample peak only | Bounded FFT telemetry outside the realtime callback, calibration, measurement metadata and validation. |
| Hearing/test-tone workflows | No generated tones or hearing assessment | User-controlled level/ramp/mute, separate calibration flow and validated playback behavior. |
| Full APO command language | Strict documented subset: every biquad filter type, channel delays and mid/side routing | Native equivalents for routing, includes, expressions and per-channel preamp, with explicit semantics and sandboxed file resolution. |
| Other languages | English only | String catalogs, locale-aware numeric entry, translated layouts and accessibility review. |

These features need more audio processing, hardware testing, or work with outside data sources before Aural can support them.

## Testing requirements

Every DSP feature requires default-equivalence, per-channel isolation, bypass, bounds, transition, and multi-rate tests. Import must reject unsupported semantics without changing sound. Old saved profiles must decode without losing precision. UI changes must be checked in the native app at default and minimum sizes, with long preset names and keyboard access. Universal compilation is separate from runtime verification on physical Intel hardware.
