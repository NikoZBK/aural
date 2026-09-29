# Aural 0.8.0 — filter engine expansion

## Behavior

- Added second-order low-pass (LPQ), high-pass (HPQ), unity-peak band-pass (BP), notch (NO), and all-pass (AP), alongside existing peaking and Q-based shelves.
- Explicit disabled state crosses the Swift/C boundary without discarding saved filter gain. All-disabled profiles are accepted; preamp and peak protection still apply. Global bypass also bypasses preamp.
- Coefficients and preamp amplitude are prepared by the single control-thread producer. The callback processes preallocated state with no coefficient calculations, allocation, locks, logging, or Swift calls.
- Changes crossfade complete chains over 20 ms. A new request during a fade becomes the latest pending target; it starts no earlier than the next callback after that fade ends. Unchanged prefixes retain their histories. The wet chain stays warm during global bypass.
- Graphs and playback use the same coefficient generator. The graph floors exact zeros at −300 dB per filter; audio is not floored.
- Active filters near Nyquist are rejected at the C update boundary as well as in Swift. The built-in graphic equalizer retains its existing policy of disabling bands above the valid range.
- Invalid buffer lengths and nonfinite audio latch faults and produce finite output; the existing control loop stops the route when it observes a fault.

## Integration and compatibility

All eight types are available in the filter editor and persist in profiles/backups. File and clipboard export/import support the five new types with explicit Fc and Q and no Gain parameter. Unsupported shorthand, omitted Q, bandwidth, and higher-order syntax are rejected rather than approximated. Gain is shown as inapplicable for the five new types.

Existing profiles retain their steady-state responses. Transition behavior intentionally changes from interpolated gains/reset states to chain crossfades. This does not add stereo-independent filters, surround, effects, or higher-order crossovers. New filter profiles require 0.8.0 or newer; retain a settings backup before downgrading.

Formula reference: [W3C Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/). Interchange reference: [Equalizer APO configuration](https://sourceforge.net/p/equalizerapo/wiki/Configuration%20reference/).

## Verification

- Existing nine DSP regression groups passed under AddressSanitizer and UndefinedBehaviorSanitizer.
- New magnitude/phase, channel isolation, disabled-state, global bypass, and graph/processing agreement checks passed at 32, 44.1, 48, 96, and 192 kHz.
- New stress checks passed for 32 filters, extreme valid parameters, rapid updates, malformed buffers, and nonfinite input.
- A constant-input rapid-transition test measured a maximum adjacent-sample step of 0.00007802 at input amplitude 0.05. This is a specific continuity check, not a guarantee that every possible edit is inaudible.
- Swift parser/editor/persistence and Swift-to-C bridge integration tests passed, including all-disabled profiles and gain preservation.
- Debug app build passed.
- A local optimized synthetic benchmark (10,000 callbacks; 192 kHz; 64 frames; 32 filters; repeated crossfades) measured mean 7.50 µs, p99 14.00 µs, max 137.00 µs versus a 333.33 µs buffer budget. These are process timings on this Mac, not device latency or an all-hardware guarantee.

## Separate startup issue

The recorded 0.7.0 startup stall occurs inside AudioDeviceCreateIOProcID, waiting for the Core Audio server. This patch does not change the audio-route lifecycle and does not claim to fix that stall. Moving that lifecycle off the main thread requires explicit serialized ownership, cancellation, late-completion cleanup, and hardware tests; an arbitrary timeout would not safely release a pending HAL call.

## Local installation verification

Both release architectures built successfully and the universal app passed signature verification. The installed 0.8.0 executable matched the packaged executable. The prior app and pre-update settings were backed up locally.

The installed app resumed processing through the saved output with the prior profile and preamp unchanged. Native UI checks confirmed all eight type choices, inapplicable gain controls for low-pass, undo back to the exact original shelf/gain, and Cancel leaving the running profile untouched. The settings file remained byte-identical to the pre-update backup. This launch did not reproduce the earlier HAL stall, but does not establish that it is fixed. Intel was cross-compiled, not runtime-tested. No remote release was published.
