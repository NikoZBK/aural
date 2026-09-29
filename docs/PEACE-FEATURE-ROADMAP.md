# Aural: Peace feature roadmap

Planning baseline: September 29, 2026. This is a proposed implementation sequence, not a claim of feature parity or a release commitment. No audio behavior changes are included in this document.

## Goal and reference

Bring Peace's everyday EQ, channel, effects, profile, and control workflows to a native macOS application. Keep Aural's simple main window and expose advanced tools progressively.

Reference inventory: [Peace project features](https://sourceforge.net/projects/peace-equalizer-apo-extension/) and [official wiki](https://sourceforge.net/p/peace-equalizer-apo-extension/wiki/Home/). Peace is an interface to Equalizer APO; Aural owns its processing engine. Consequently, several apparent UI additions require DSP and audio-routing work.

The reference covers configurable bands and filter types, channel-specific processing and graphs, effects and routing, preset/device management, headphone databases, automation and layered configurations, hotkeys, MIDI, hearing tests, themes, localization, and an APO command editor. Feature-equivalent native workflows are the target; Windows-specific integration needs macOS equivalents.

## Verified starting point

The current source provides ten fixed graphic bands, up to 32 parametric filters, peaking and Q-based shelves, exact preamp/filter editing, built-in/custom presets, saved settings per output, file/clipboard AutoEQ import, clipboard export, a combined response graph, peak metering/protection, bypass, menu bar controls, and optional login/automatic startup.

The engine supports one stereo output stream. Both channels share filter settings. Presets contain one curve, not composable processing stages. Import understands a limited APO text subset. Startup restores one saved device; it is not a general automation system. There is no headphone database browser, MIDI mapping, independent channel EQ, surround path, or effects rack.

## Proposed milestones

### 0. Foundations and compatibility contract

- Define a checklist for every reference feature, marking it implemented, partial, planned, or dependent on a hardware feasibility test.
- Introduce a versioned profile schema with stable identifiers, explicit enabled state, filter parameters, channel targets, ordered stages, and source metadata. Preserve original imported text separately from editable settings when useful.
- Migrate existing device and preset settings with a recoverable backup. Existing profiles must retain their response and precision.
- Establish one validated command path for UI, menu, keyboard, automation, and MIDI operations. Separate stored profiles from temporary editor drafts and active audio state.
- Keep audio callbacks free of allocation, locks, file access, and UI calls. Serialize control producers before the current single-producer queue.
- Record baseline CPU cost, latency, switching transients, route cleanup, and device recovery. Build with local temporary caches to avoid the workspace cache stalls observed during installation.

Acceptance: legacy settings migrate correctly; measured output remains equivalent; existing test suites pass; failed validation or persistence has an explicit, documented outcome.

### 1. Complete everyday EQ editing

- Provide 10- and 31-band layouts plus custom frequencies, while retaining the parametric editor and 32-filter starting limit. Band count and filter type should not depend on import origin.
- Add low/high-pass, band-pass, notch, and all-pass types, then higher-order Butterworth and Linkwitz-Riley variants with defined order and slope semantics.
- Replace gain-zero disabling with explicit filter bypass. The present coefficient shortcut treats zero gain as identity; new filter types require different math and transition handling.
- Add undo/redo, duplicate/reorder filters, multi-selection, gain offset/scaling, frequency shifting, and A/B comparison.
- Show individual and combined response curves, cursor values, and predicted headroom. Derive graphs from the same coefficients used for playback.
- Extend import/export only as each filter's semantics are implemented and tested. Reject unsupported syntax with line-specific explanations; never approximate silently.

Acceptance: analytical response matches measured processing across supported sample rates; OFF filters remain identity; edits and bypass transitions are bounded and click-free; copy/file round trips preserve supported settings.

### 2. Profile library and headphone discovery

- Add search, favorites, rename, duplicate, delete with recovery, and backup/restore for presets. Add native profile file export/import alongside APO text.
- Browse AutoEQ first, with measurement source, target, variant, provenance, and preview before applying. Add OPRA through a separate provider adapter after verifying its data format, availability, and redistribution requirements.
- Cache downloaded profiles for offline use. Keep current sound intact if fetching or parsing fails; avoid automatic replacement when upstream data changes.
- Add named processing layers for headphone correction and personal preferences. Show their combined response and headroom, with deterministic ordering and per-layer bypass.

Acceptance: duplicate names are handled predictably, offline profiles work, backups restore, and stacked correction never applies twice unintentionally.

### 3. Stereo channels and effects

- Add linked/unlinked left/right EQ, per-channel preamp, balance, mute, polarity, swap, and mono mix.
- Add bounded per-channel delay, crossfeed, and bass/treble controls as explicit processing stages. Define routing/mixing order and headroom before implementing controls.
- Add per-channel meters and response selection. Preserve stereo-linked peak protection by default.

Acceptance: impulse tests verify channel routing and delay; no unintended crosstalk; mixes have predictable gain; resets, bypass, and state transitions are verified at every supported sample rate.

### 4. Automation and external control

- Add preset selection and preamp/mute controls to the menu bar, configurable global shortcuts, and a macOS shortcut/deep-link entry point.
- Support rules for output-device arrival/selection and application launch/exit. Application-triggered switching is distinct from per-application audio processing.
- Define conflict priority, manual override, disconnect behavior, and fallback explicitly. Never apply a headphone correction to a different output by accident.
- Add MIDI learn, mapping persistence, range scaling, optional feedback, and disconnect handling. Coalesce rapid controller events before submitting audio updates.

Acceptance: simultaneous rules resolve deterministically; manual overrides are respected; shortcut conflicts are shown; controller floods do not starve or overflow the engine.

### 5. Multichannel feasibility and advanced compatibility

- Prototype channel discovery and routing on actual multichannel hardware before promising surround support. Test a single multichannel output first; multiple devices and clocks are a separate project.
- Generalize DSP state and buffer handling beyond stereo, then expose channel groups, routing matrices, and up/downmix presets with bounded gain.
- Expand processing capacity only after profiling CPU, queue memory, and worst-case callback time. Do not advertise unlimited filters.
- Consider an advanced APO-subset editor with validation and an explicit supported-command list. Arbitrary APO commands and Peace configuration files are separate compatibility projects, not implied by text import.
- Evaluate convolution separately if desired; it is an additional engine project, not part of the initial reference-feature commitment.

Acceptance: channel identity, layouts, format changes, cleanup, and sustained playback pass on real supported hardware. Unproven configurations remain unavailable with a clear explanation.

### 6. Guided personalization and interface polish

- Add an optional, non-diagnostic listening comparison workflow with conservative test levels, explicit start/stop, and a separate result layer. Validate the protocol and its limitations before calling it a hearing test.
- Provide basic and advanced views, accessible controls and graph descriptions, light/dark/high-contrast appearance, and localization using native string resources.
- Prepare strings and accessibility semantics from the first milestone rather than retrofitting them at the end.

Acceptance: keyboard and VoiceOver workflows pass; layout survives long translations; test playback stops reliably on interruption; calibration is never presented as a medical result.

## Release strategy and dependencies

Deliver milestones 0–1 first, then 2. Milestones 3 and 4 depend on the shared profile/command foundation. Multichannel discovery can be investigated earlier, but delivery depends on proven routing and DSP behavior. Hearing-test work should remain separate from ordinary EQ releases.

For every milestone: migration tests, numerical DSP tests where applicable, UI interaction checks, real-device playback, rapid setting changes, unplug/replug, permission failure, sample-rate changes, sleep/wake, quit cleanup, and signed universal builds. Intel runtime support needs an Intel test machine; cross-compilation alone is insufficient evidence.

Do not silently change the existing semantics of Start, Stop, Bypass, import, or device selection. Introduce deliberate changes with visible controls and regression coverage.

The first release should deliver a richer editor and dependable profile model. Avoid attaching dates to full parity until the foundational and multichannel spikes have been measured. A complete feature match is a sequence of releases, not a single UI patch.

## Implemented first increment (September 29, 2026)

Completed the lowest-risk library and editor work ahead of the engine milestones:

- Searchable preset library; favorites; custom preset rename/delete with session-local undo delete; duplication of built-in/custom presets.
- Versioned preset backups with complete validation, precision preservation, collision-safe merge, and favorite remapping. This is a preset-library format, not yet a versioned full processing graph.
- Menu-bar preset/favorite selection and bounded preamp controls; Equalizer APO text-file export.
- Filter duplication/reordering and bounded draft undo/redo.

DSP filter expansion, 31-band sliders, A/B playback, independent channels, effects, database browsing, automatic switching, MIDI, and surround remain planned. The audio engine and routing behavior are unchanged in this increment.

## Engine increment (0.8.0)

Added explicit per-filter disabling, prepared coefficients, 20 ms complete-chain crossfades, and second-order low/high-pass, band-pass, notch and all-pass filters. Integrated types through editing, graphing, persistence, and explicit-Q APO text import/export. Added numerical, stress, bridge, and benchmark coverage. See RELEASE-0.8.0.md for results and limits. Higher-order Butterworth/Linkwitz-Riley filters and channel/effects work remain planned. The separate Core Audio startup stall remains unresolved.
