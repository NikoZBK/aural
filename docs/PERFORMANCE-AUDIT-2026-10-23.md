# Aural desktop performance audit — 2026-10-23

Follow-up: [filter and fader stall fixes, measured later on the same day](PERFORMANCE-STALL-FIXES-2026-10-23.md). The observations below remain the pre-fix audit record.

The audit found and reduced several UI bottlenecks. **A zero-slowdown claim is not supported.** Intermittent stalls remain in ordinary and large banks; initial window construction and the maximum-size draft editor also have measurable delays. This report records those limits alongside the improvements.

## Scope and method

Tested native macOS on Mac15,13, 16 GiB RAM, 8 logical CPUs, macOS 27.0.1 (26A434), arm64, Swift 6.4, macOS SDK 26.5. UI benchmarks use `-O -whole-module-optimization` and disposable settings through the native test entry point. The production release build also passes. Audio stays stopped during UI tests.

The broad audit includes **38 scenarios and 630 timed samples**: 10/31/64 filters in all editor views; view changes; resizing; Bypass; level matching; a 900×620 window at 140% zoom with the side inspector; idle/meter publication isolation; 1,000 saved presets; a 15,000-entry offline AutoEQ catalog; editing with secondary windows open; draft, stereo, and settings construction.

Each edit sample measures a model action followed by native layout/display flushing. Asynchronous curve analysis runs between samples. These are CPU action/layout observations, **not GPU frame times or measured user-perceived frame rate**. The median is the upper-middle sample for even counts; p95 uses nearest rank. Small samples and single openings do not establish latency distributions.

Heavy builds and benchmarks ran sequentially. Unrelated applications were active on the shared host and repeats varied. A sampled repeat had profiler overhead. No other apps or jobs were stopped to improve the result.

## Changes

- Isolate unchanged filter strips, rows, toolbar controls, and native pickers from unrelated model publications. Preserve exact input, focus, action availability, rejected-picker resets, selected preset, sample rate, and appearance dependencies.
- Capture the current revision when an untouched numeric field gains focus. Keep existing typed drafts tied to their original revision, so stale edits remain rejected.
- Reuse completed curve samples at exact filter centers. Preserve the live path for unsampled centers and graph dragging. Immediate audio edits and the existing bounded curve-update cadence remain separate.
- Share workspace measurements between sizing and placement. Invalidate the layout cache for child-size changes and key every geometry input. Native tests cover internal notice/toolbar changes and resizing, following [Apple's layout cache contract](https://developer.apple.com/documentation/swiftui/layout/updatecache%28_%3Asubviews%3A%29).
- Render draft rows lazily while preserving row IDs and incomplete strings in the draft model. The last row remains reachable without constructing all 192 numeric fields initially.
- Avoid repeated preset sorting within one render and large secondary-window redraws on each main-window fader edit. Cache AutoEQ entry identity. The live native preview check also covers filtered counts after an unmatched preset addition.

## Before and after

Median action/layout observations, milliseconds. Baseline is the workspace at the start of this audit, including the preceding graph/scroll fixes. The baseline, cached reference, and final verification runs were separate shared-host observations. The cached reference precedes only the filtered-total key correction in the preset library. Both optimized runs are retained because their variation is material; the reference is not a replacement for final-source evidence.

| Operation | Baseline | Cached reference | Final verification |
| --- | ---: | ---: | ---: |
| 10-filter fader edit | 21.48 | 11.56 | 41.04 |
| 10-filter row edit | 20.88 | 11.66 | 64.86 |
| 31-filter fader edit | 36.08 | 19.52 | 25.26 |
| 31-filter row edit | 53.35 | 19.47 | 24.63 |
| 64-filter fader edit | 77.86 | 34.68 | 103.32 |
| 64-filter row edit | 86.91 | 36.45 | 196.97 |
| 64-filter editor switch | 176.76 | 105.59 | 128.50 |

A separate back-to-back 90-event fader comparison reduced **mean layout work from 19.39 to 13.22 ms for 10 filters (32%) and 36.25 to 19.01 ms for 31 filters (48%)**. Document mutation averaged 0.73/0.72 ms afterward; this figure excludes layout. These comparison results precede only the filtered-total cache dependency correction; that correction is covered by the final broad audit, native regression suite, and live preset-count check. The raw comparison uses its existing p95 convention; do not compare that percentile with the broad audit's small-sample p95.

## Final broad audit

Milliseconds. All 38 measurements, baseline results, definitions, source hashes, and verification receipts are retained in [the machine-readable results](performance/2026-10-23.json).

| Operation | Samples | Median | p95 | Maximum |
| --- | ---: | ---: | ---: | ---: |
| 10-filter fader edit | 40 | 41.04 | 162.77 | 280.86 |
| 31-filter fader edit | 40 | 25.26 | 32.88 | 36.95 |
| 64-filter fader edit | 40 | 103.32 | 302.51 | 344.14 |
| 31-filter row edit | 40 | 24.63 | 33.40 | 41.89 |
| 64-filter row edit | 40 | 196.97 | 397.76 | 456.19 |
| 10-filter editor switch | 6 | 58.73 | 74.02 | 74.02 |
| 31-filter editor switch | 6 | 81.90 | 86.44 | 86.44 |
| 64-filter editor switch | 6 | 128.50 | 147.84 | 147.84 |
| 64-filter window resize | 3 | 161.62 | 169.76 | 169.76 |
| 64-filter Bypass | 12 | 21.08 | 23.30 | 23.30 |
| 64-filter level-matched edit | 20 | 40.39 | 47.90 | 49.15 |
| Minimum window, side panel, 140%, 64 filters | 20 | 60.25 | 140.02 | 149.82 |
| 1,000-preset native search | 7 | 35.34 | 138.03 | 138.03 |
| 15,000-entry native AutoEQ search | 7 | 64.72 | 161.88 | 161.88 |
| Edit with 1,000-preset library open | 20 | 17.92 | 24.39 | 32.21 |
| Edit with 15,000-entry AutoEQ open | 20 | 17.17 | 35.31 | 42.70 |
| Edit with 64-filter draft open | 20 | 45.50 | 82.99 | 90.77 |

Initial construction, one observation per window. These observations include framework/view setup and should not be treated as repeat-use timings.

| Window | Milliseconds |
| --- | ---: |
| 10-filter main workspace | 741.98 |
| 31-filter main workspace | 801.86 |
| 64-filter main workspace | 825.21 |
| 1,000-preset library | 359.32 |
| 15,000-entry AutoEQ browser | 207.88 |
| 64-filter draft editor | 647.96 |
| Stereo panel | 134.28 |
| Settings | 96.18 |

The live optimized preview used **0.20% CPU and 142.69 MiB resident memory over 5.01 seconds idle**, with EQ stopped. Each 10/31/64-filter harness case also produced **zero document publications** after 200 meter updates and 1.1 seconds of settled idle time. These are bounded idle observations, not a long-duration playback or battery test.

## Verification

- **105 PASS groups** in `bash scripts/test.sh`, including DSP sanitizers, audio lifecycle, precision, undo, response analysis, preset/AutoEQ behavior, retained native editors, layout cache invalidation, lazy draft persistence, and action-state updates.
- `swift build -c release --arch arm64 --scratch-path .build/arm64` passed. Existing Command Line Tools linker search-path warnings remain.
- Native preview: Faders → All rows → Faders switches; only the active editor exposes its scrollbars; preset search narrows correctly, including the total after an unmatched preset addition; selecting a graph point restores exact filter controls. The preview remained stopped. Temporary library test data was removed; concurrent edits in the disposable preview were left intact.
- Existing unrelated audio/DSP, storage, icon, and document changes were checked against the pre-task hash inventory. The audit did not install or release the production app.

## Remaining limits

1. **Intermittent stalls remain at ordinary sizes too.** The final 10-filter fader p95/max is 162.77/280.86 ms, compared with 12.63/17.16 ms in the earlier cached reference run. Other apps were active, but the audit does not establish the cause of every spike. **Large banks are still expensive:** the final 64-filter fader p95 is 302.51 ms; editor switching reaches 147.84 ms. Even 31-filter interaction work can exceed a 16.7 ms budget. These timings cannot certify uninterrupted 60 Hz presentation.
2. **Cold and secondary-window work remains.** The maximum-size draft opened in 647.96 ms in this run; repeat observations varied with load. Lazy rows improve construction substantially from the earlier 1,199 ms observation, but opening is not instantaneous. Edits with that maximum draft open still reach 90.77 ms.
3. A **321 ms row-edit outlier** was observed before the workspace cache change. It did not recur in the subsequent unprofiled cached run (31-filter rows max 31.63 ms). The final run contains further spikes, including other band counts; this is not evidence that stalls were eliminated.
4. The offscreen native-search audit emitted **4 reentrant `NSTableView` delegate warnings** while forcing layout. The real preview search worked, and its five-minute process-log query contained no matching warning. The warning remains a harness/framework investigation item; it is not certified absent everywhere. Native functional tests did not report SwiftUI state-mutation-during-update warnings.
5. Synthetic DSP stress at 192 kHz, 64 frames, 80 filters with repeated transitions measured mean **53.58 µs**, p99 **105 µs**, maximum **335 µs**, against a **333.33 µs** buffer budget. The maximum exceeded that budget by about 1.67 µs. No physical audio-route dropout test was performed; zero dropouts cannot be claimed.
6. GPU frame pacing, real network waits, prolonged thermal behavior, physical route reconnects, Intel hardware, and iOS require separate evidence. This audit covers the current desktop source and the listed scenarios.

The next performance work should capture live foreground frame pacing during the intermittent spikes, then target retained-tree/layout cost and initial draft/window construction. A lower-load repeat can help isolate causes, but cannot replace the slower observations already recorded. Preserve native editor identity and incomplete draft text while doing so; replacing the retained views merely to lower a benchmark would break established editing behavior.

## Reproduction

Run against the same source with writable Swift/Clang module caches. Cloud-synced file reads stalled on this host, so compilation used a stable local validation copy whose audited files were byte-checked against the workspace.

```sh
bash scripts/test.sh
swift build -c release --arch arm64 --scratch-path .build/arm64
AURAL_AUDIT_JSON=/private/tmp/aural-audit.json bash scripts/benchmark-ui.sh --audit-performance
bash scripts/benchmark-ui.sh --benchmark-edits
bash scripts/benchmark-ui.sh --benchmark-rack
```

Run these sequentially. Record host load, optimize the benchmark build, keep disposable settings, and separate stopped-route UI measurements from hardware audio validation. The JSON artifact contains exact source hashes and log hashes for this run.
