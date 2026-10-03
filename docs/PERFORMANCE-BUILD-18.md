# Performance sweep: local build 18

Verified on Apple Silicon, macOS 26.6.2, October 3, 2026. This is a local update to version 1.0.0, not a published release.

## Causes and changes

- The document published audio peaks every 100 ms, including unchanged silence. Every editor and menu subscribed to those updates. `AudioMeter` now publishes only changed readings to `StudioMeter`; the document does not publish peak readings.
- The one-second poll synchronously queried ServiceManagement, including XPC, on the main actor. Login-status reads now run in a background task on activation or when settings appear. Pending status is explicit; late cancelled reads cannot publish.
- Swapping modes recreated native fields, pickers, sliders, and the nested layout. Each mode now retains one hosting view with an explicit viewport. The inactive view is detached from the window, keyboard focus, and accessibility. Shared environment values, including appearance and window actions, cross the hosting boundary.
- Inactive gesture completion published an unchanged workspace. It now checks that a gesture exists.
- Numerical graph analysis and Auto preamp run on a serial worker actor. Curve results carry their input; cancelled or outdated results cannot be drawn against newer EQ values. Auto preamp rejects stale revisions, outputs, and sample rates and applies through the normal undo/persistence path.
- Frequency-grid sampling prepares coefficients once and shares the scalar response math. The audio callback and processing order are unchanged.
- Filter headings and rows use the same column layout inside one scroll viewport, with pinned headings and centered numeric labels. This includes the scrollbar inset. Invalid numeric input keeps Professional selected; correcting the value commits it before the swap.
- The redundant Professional-mode explanation/button has been removed from Simple.

## Measurements

`bash scripts/benchmark-ui.sh` builds an optimized Swift/C harness with disposable settings and no running audio. The native window is 1240 by 820 points; the 1060 by 700 Professional minimum is also rendered. Layout is flushed explicitly; settings-save time is measured separately. These are individual measurements under the current desktop load, not a latency guarantee or a statistical comparison to the earlier debug baseline.

| Layout | First construction/change | Retained Professional | Switch to Simple |
| --- | ---: | ---: | ---: |
| 10 bands | 500 ms | 112 ms | 49–51 ms |
| 31-band shape change | 971 ms | 150 ms | 45–61 ms |

Settings saves took 1–3 ms. Response analysis averaged 0.71 ms for ten boosted graphic bands and 2.06 ms for 31 alternating boosted/cut filters. It runs outside the UI thread.

A five-second idle sample of the stopped 31-band preview found its main thread waiting in the event loop for 2157 of 2165 samples, with no repeated layout or login-status query. The old installed build was consuming about one CPU core during this sweep; direct stopped-preview readings settled to 0.1 percent. These are different audio states and do not establish a controlled playback CPU comparison.

First construction still costs roughly half a second to a second. Retention fixes repeated construction; native controls cannot be constructed on a worker thread. The first-opening cost remains a limitation and must be recorded separately from warmed switches.

## Verification

All twelve suites passed: DSP/engine with AddressSanitizer and UndefinedBehaviorSanitizer, batched/scalar sampling parity, import, Swift/C bridge, workflow, precision, response, headroom, windows, icons, and theme/performance checks. The final native harness was also checked with optimization enabled.

The performance checks hold a fake system-status query blocked while modes, metering, and timers proceed; 600 readings produce 300 meter publications and no document publication. They cover no-op gestures, mode persistence and failed saves, detached-panel focus and identity, resizing, background analysis, queued cancellation, stale Auto preamp results, supersession, undo, and sound-neutral switching.

Native preview checks confirmed aligned headings with a scrollbar, appearance changes, corrected selector state after invalid input, commit-before-swap, retained edits/curve results, and preset-library opening through the hosting boundary. The Simple-pane cleanup is verified in the final installed build.

The universal build compiles arm64 and x86_64. Intel runtime testing and notarization are not part of this local update.
