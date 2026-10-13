# Aural 1.6.0

- Refreshes the desktop workspace with native Liquid Glass on supported macOS versions, teal and violet accents, rounded typography, and a softly shaded EQ response curve. Glass is the default; older macOS and accessibility settings retain opaque, readable surfaces.
- Brings the same styling to the preset library and AutoEQ browser while keeping exact numeric editing, the movable filter panel, and existing EQ controls available.
- Adds **Move up** and **Move down** to each filter's actions menu in **Selected** and **All rows**. Moves preserve exact values and channel assignments, keep selection with the moved filter, and have their own Undo step.
- Ends an active Solo when the same filters change order, including through Undo, Redo, draft application, or A/B, so Solo does not silently target a different band.

Existing presets, output settings, and audio-processing controls are preserved. Filter order can affect mixed left/right and mid/side chains; use Undo to restore the previous order.

Requires macOS 14.2 or later. Universal app for Apple silicon and Intel.
