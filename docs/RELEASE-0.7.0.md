# Aural 0.7.0 — first Peace roadmap increment

Implemented, built, and installed locally on September 29, 2026. No GitHub release or remote push was performed.

## Included

- Searchable preset library, favorites, duplication, rename, delete, and session-local undo delete.
- Versioned JSON preset backup/restore with validation, precision preservation, safe name collisions, and favorite remapping.
- Equalizer APO text-file export.
- Menu-bar preset/favorite selection and bounded preamp adjustments.
- Filter duplication/reordering and a 100-edit draft undo/redo history.

## Verification

- Existing nine DSP test groups passed with address/undefined-behavior sanitizers.
- Existing Swift parser, startup, profile, release, and clipboard tests passed.
- New tests passed for duplicate names, rename rejection without mutation, backup precision/version/size validation, merge conflicts, favorites, old settings, filter identity/order/capacity, and undo/redo branching/bounds.
- Debug build and both release architectures (arm64 and x86_64) passed. Universal app signing verification passed.
- Installed executable matched the built executable.
- Native UI inspection confirmed the preset library layout, existing custom presets, editor action menus, Undo/Redo controls, and preserved current EQ after restart. Interactive search and undo/redo UI checks were not completed because the user was interacting with the app; undo/redo history has automated logic coverage; search has build and code-review verification only.

## Known follow-up

The first post-install launch stalled in `AudioDeviceCreateIOProcID` during automatic startup. A process sample captured the main thread waiting on a Core Audio server response. Terminating the unresponsive process and relaunching restored processing, with a live output meter and the saved profile. The cause is not resolved. The audio-route implementation was unchanged in this increment; this does not establish whether the stall can recur.

The larger roadmap remains open: expanded filter types, 31-band sliders, A/B playback, separate channel EQ, effects, headphone database browsing, global automation, MIDI, and surround.
