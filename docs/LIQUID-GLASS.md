# Liquid Glass appearance option

Introduced in Aural 1.2.0. See the [release notes](RELEASE-1.2.0.md) for the complete update.

Choose **Style → Liquid Glass** in gear settings, the View menu, or the headphones menu. The setting is independent of **Theme → System / Light / Dark** and is saved before the UI changes. Existing and new installations default to Standard. A save failure retains the accepted style and reports an error.

## Native SDK integration

Aural uses Apple's macOS 26 `glassEffect(_:in:)` with the regular material and `GlassEffectContainer`. The main header and footer become glass control surfaces; shared secondary action buttons adopt interactive glass in the main workspace, preset library, AutoEQ browser, draft editor, and settings. Buttons inside glass chrome retain solid backgrounds to avoid layering glass on glass, and prominent actions retain opaque accent backgrounds with contrasting labels.

Graphs, filter tables, numeric fields, and content panels stay solid. The effect container and effect modifier are retained in both styles on supported macOS; the modifier switches between regular glass and Apple's identity effect without replacing editor content. Apply the effect to complete controls so their labels stay sharp above the material. Style changes preserve EQ, output selection, playback, bypass, comparisons, and pending numeric or draft edits.

Hidden retained editors explicitly remove button glass effects as well as suppressing opacity, hit testing, and accessibility. The glass container renders effects independently of parent clipping and opacity, including labels with identity glass, so those properties alone do not hide the controls. Only the always-visible chrome uses identity glass; hidden buttons omit the modifier completely.

- macOS 26 or later renders native glass. Older supported versions keep solid surfaces and disable new Liquid Glass selections; a saved preference remains compatible.
- Reduce Transparency or Increase Contrast uses the existing solid presentation without changing the saved style.
- Reduce Motion disables the custom glass interaction effect. Aural adds no material-switch animations.
- The app's minimum supported macOS version stays 14.2; SDK 26 or later is required to build this feature.

## Verification

The custom suite checks legacy settings, independent material/theme persistence, invalid values, save-before-publish ordering, failed saves, audio neutrality, availability and accessibility fallbacks, supported workspace sizes, and retained native numeric editors across material changes. Use the disposable native preview to check glass in both appearances, gear/View/menu-bar entry points, drafts and auxiliary windows, keyboard focus, and accessibility navigation. Keep personal settings and audio outside preview fixtures.

## Apple references

- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Human Interface Guidelines: Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
