# Aural 0.9.4 — a dog that follows your EQ

The dog sleeps when EQ is stopped or bypassed, and returns to the original happy expression when processing. The main window, About window, and running application's Dock icon share this state. Finder keeps the original happy bundle icon; the menu bar keeps its headphones symbol.

Both icon variants load once. An application-owned observer watches only running/bypass transitions and skips duplicate states, so output-meter updates do not repeatedly redraw the Dock icon. The observer continues working with every window closed. Dock updates begin after AppKit finishes launching. Missing artwork reports a specific error in Aural.

The sleeping artwork was edited from the original with the built-in image-generation tool. The happy PNG and ICNS are unchanged. Both sources, full macOS icon sets, and the exact prompts are documented in [ICON.md](ICON.md).

This version also includes the [0.9.3 menu-bar window behavior](RELEASE-0.9.3.md): closing the last window hides Aural from the Dock while audio continues; Quit exits completely.

## Verification

- Full DSP sanitizer, import/editor/preset, Swift/C bridge, window-lifecycle, and icon suites passed. After the final startup-lifecycle adjustment, focused icon tests passed again with warnings treated as errors, and both release architectures were rebuilt.
- Icon tests exercise every running/bypass combination, live transitions without windows, shared image publication, resource caching, duplicate suppression, pre-launch state changes, idempotent launch activation, observation cancellation, and missing-resource errors.
- Universal arm64/x86_64 app packaging, strict ad-hoc signature verification, and DMG verification passed. Installed executable and sleeping icon match the package; all 41 package inputs match the workspace.
- Native Apple silicon checks showed the sleeping dog on initial stopped launch, happy during automatic processing, sleeping in Bypass and after Stop, and happy again after Start. An already-open About window also changed from sleeping to happy.
- The app was left processing through the saved output with Bypass off, then its windows were closed. Read-only process inspection confirmed accessory activation policy with the process still running. Saved settings, EQ, presets, and startup preferences were unchanged.

Dock image assignment and windowless icon transitions have automated coverage; native visual inspection covered the main and About windows. Intel remains cross-compiled, not runtime-tested. The prior intermittent Core Audio startup issue is outside this change. This build is ad-hoc signed, not notarized, and installed locally; no GitHub release was published for this change.
