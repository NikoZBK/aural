# Filter and fader stall fixes — 2026-10-23

The identified edit bottlenecks have been removed while retaining exact numeric editing, native control identity, focus, undo, and audio behavior. In the original audit rerun, ordinary 10/31/64-filter edits measured **7.33–16.71 ms median**, with a **27.81 ms maximum**. The earlier hundreds-of-milliseconds ordinary-edit stalls did not recur in that run.

This is a measured improvement, **not a universal zero-stall claim**. A longer mixed-parameter stress run still recorded a 776.25 ms maximum while other apps were running; the cause of that outlier was not isolated. That run is preserved with the faster observations in [the complete results](performance/2026-10-23-stall-fixes.json).

## What changed

- Hidden Selected, All rows, and Faders editors keep their native controls, but stop refreshing their document contents while inactive. Reactivation supplies the newest profile, revision, selection, and action state. Faders receive a value snapshot so a stable model reference cannot accidentally suppress visible updates.
- Exact numeric fields derive formatted display text directly from the model. Local text State contains only a user draft. Continuous fader edits no longer create another view transaction just to format each incoming value. Invalid drafts still survive focus loss, stale drafts remain rejected, and accepted values retain full precision.
- Fader tracks, fills, and handles draw in a fixed Canvas. Gain changes pixels rather than resizing a stack of shapes. Keyboard, accessibility, drag, reset, and focus behavior remain on the existing control.
- Numeric controls honor the proposed column width while retaining AppKit's font height. A longer formatted number cannot resize its column.
- Workspace, filter-column, and graph-zoom containers align by their own frames. They do not merge descendant explicit alignment guides across retained controls. This uses [SwiftUI's documented explicit-alignment contract](https://developer.apple.com/documentation/swiftui/layout/explicitalignment%28of%3Ain%3Aproposal%3Asubviews%3Acache%3A%29).
- Curve presentation scheduling uses non-published bookkeeping. Finishing an analysis no longer changes view State solely to record its presentation time. Stable graph header controls are retained across response updates, with selection, channel, Harman, comparison, drag, and appearance dependencies preserved.

Model, route, and DSP source were not changed in this fix pass. Audio updates remain immediate; visual curve analysis keeps its existing bounded cadence.

## Controlled comparisons

The focused harness separates the full workspace, retained rack, standalone faders, and interactive curve. It performs 60 accepted gain/frequency/Q edits per case, with 8 ms between samples. Each sample measures document mutation plus forced native layout/display. Final displayed gain, one-step undo, and stopped routing are checked. These are CPU action/layout timings, not displayed FPS.

The old and fixed optimized binaries were run back-to-back for each workspace view, then in reverse order, with 10/31/64 filters in each process. Other apps stayed running. Each median range below contains the two separate run medians; it is not a pooled percentile. All paired p95 and maximum values are in the JSON.

| Workspace | Before median range, ms | After median range, ms | Before maximum, ms | After maximum, ms |
| --- | ---: | ---: | ---: | ---: |
| Faders, 10 filters | 23.9–32.4 | 15.5–16.0 | 57.5 | 24.4 |
| Faders, 31 filters | 36.5–52.6 | 23.7–24.4 | 127.2 | 34.3 |
| Faders, 64 filters | 56.2–68.5 | 37.6–38.2 | 109.0 | 60.8 |
| Filter rows, 10 filters | 12.1–33.0 | 9.1–16.9 | 52.2 | 49.4 |
| Filter rows, 31 filters | 24.0–48.0 | 13.8–14.0 | 81.3 | 31.4 |
| Filter rows, 64 filters | 37.6–70.6 | 20.1–22.7 | 189.7 | 52.6 |

Across the paired runs, the worst measured edit changed from **189.68 to 60.82 ms**. The paired harness performs the same timed edit sequence in both binaries; the fixed harness additionally checks the final displayed value outside that timing interval.

## Original audit rerun

The unchanged broad audit was repeated against the final optimized source: 38 scenarios and 630 timed samples. This table covers 40 edits per ordinary editor case, in milliseconds. It replays the original workload rather than substituting an isolated-control benchmark.

| Editor | Median | p95 | Maximum |
| --- | ---: | ---: | ---: |
| Faders, 10 filters | 8.00 | 9.06 | 9.30 |
| All rows, 10 filters | 7.60 | 9.44 | 10.87 |
| Selected, 10 filters | 7.33 | 8.67 | 11.70 |
| Faders, 31 filters | 14.12 | 19.83 | 27.81 |
| All rows, 31 filters | 12.40 | 14.47 | 20.09 |
| Selected, 31 filters | 12.03 | 13.64 | 15.15 |
| Faders, 64 filters | 16.71 | 22.15 | 25.86 |
| All rows, 64 filters | 15.42 | 22.66 | 23.40 |
| Selected, 64 filters | 14.31 | 19.48 | 20.77 |

Additional editing cases, milliseconds:

| Scenario | Median | p95 | Maximum |
| --- | ---: | ---: | ---: |
| Side panel at 140%, 10 filters | 8.25 | 10.85 | 10.88 |
| Side panel at 140%, 31 filters | 28.22 | 46.18 | 46.91 |
| Side panel at 140%, 64 filters | 18.06 | 29.51 | 31.47 |
| Editing with 1,000-preset library open | 10.24 | 12.17 | 12.24 |
| Editing with 15,000-entry AutoEQ open | 8.54 | 10.33 | 10.39 |
| Editing with maximum-size draft open | 22.81 | 46.55 | 57.54 |

Each 10/31/64-filter case also retained zero document publications during settled idle/meter checks. The new 18-surface stress run, older baseline, all paired runs, and all 38 audit measurements are retained in the JSON. Differences in host activity affect absolute timing; the slower final-source stress observations have not been discarded.

## Behavior and build verification

- **107 PASS groups** in the complete custom suite, including DSP sanitizers, audio lifecycle, precision, history, response analysis, preset/AutoEQ behavior, accessibility, responsive layout, and native controls.
- New native checks prove dormant fields do not refresh, the same controls reactivate with current values, structural/gainless changes are applied, invalid drafts survive focus loss and reject navigation, and accepted edits preserve exact numbers.
- Container alignment, internal notice/toolbar changes, window resizing, minimum sizes, and 80–140% interface zoom pass their native checks.
- Production `arm64` release build passes. No SwiftUI state-mutation-during-update warning appeared in the suite. Existing Command Line Tools linker path warnings remain.
- The updated signed disposable preview was exercised with a fader accessibility edit and an Up-arrow edit. Both the exact field and 1 kHz curve readout changed correctly; two individual Undo operations restored the original EQ. Editor switching showed only the active scrollbar. The fader drawing and spacing were visually checked.
- Every saved output profile, selected output, preset collection, matching preference, and protection preference was compared with the preview snapshot afterward. The original EQ is preserved, and processing stayed stopped.

The installed production app was not replaced or published. Unrelated working-tree changes were checked against the start-of-pass hash inventory. All compiled source/test/resource files were byte-compared with the workspace, and source and log hashes are in the results artifact.

## Remaining scope

The original ordinary-edit workload no longer reproduces its earlier long stalls, but simultaneous gain/frequency/Q stress edits can still stall (776.25 ms in the long run, 60.82 ms maximum in the paired workspace runs). Concurrent host activity was observed, but these measurements do not isolate its contribution. Cold construction, maximum-size draft opening (460.35 ms), and 64-filter editor switching (109.60 ms) remain separate costs. These observations do not establish universal 60 Hz delivery.

The offscreen preset/catalog search harness still emits the previously recorded AppKit table-delegate warning. Physical audio latency/dropouts, GPU frame pacing, prolonged thermal behavior, Intel hardware, and iOS are outside this UI fix validation. The earlier DSP scheduling caveat remains in [the original audit](PERFORMANCE-AUDIT-2026-10-23.md).

## Reproduce

Use optimized builds, disposable settings, writable module caches, and sequential runs:

```sh
bash scripts/benchmark-ui.sh --check-retained-editors
AURAL_INTERACTION_JSON=/private/tmp/aural-interactions.json bash scripts/benchmark-ui.sh --benchmark-interactions
AURAL_AUDIT_JSON=/private/tmp/aural-audit.json bash scripts/benchmark-ui.sh --audit-performance
bash scripts/test.sh
swift build -c release --arch arm64 --scratch-path .build/arm64
```

Set `AURAL_INTERACTION_SURFACE` to `workspaceFaders`, `workspaceRows`, `rackFaders`, `rackRows`, `bars`, or `curve` to isolate a surface. Keep before/after timed workloads the same and reverse their order when host load varies.
