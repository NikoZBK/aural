# Aural 0.9.2

The main Equalizer card and preset picker now show the selected preset by name. A **Modified** indicator appears when the current EQ differs from its saved preset. Menus mark the selected preset with a checkmark, including Favorites and the menu bar.

Selection is stored per output device, independently of editable EQ values. Applying, importing, or saving a preset updates its selection; editing retains its name and updates Modified. Rename updates references across outputs. Delete clears the name while leaving current audio unchanged; undo delete restores the library entry without automatically selecting it.

Existing settings gain optional selection metadata. Legacy profiles migrate only when a preset can be identified from the import origin or a unique EQ match. Ambiguous copies remain Custom EQ. Source labels alone do not count as EQ modifications.

This build also includes the 8-bit dog-with-headphones icon and Refresh beside the output selector from 0.9.1. Aural explicitly loads its bundled icon to avoid displaying the previous paw from macOS's icon cache. The original generated PNG and exact built-in image-generation prompt are in [ICON.md](ICON.md).

## Verification

- Added tests for migration, per-output persistence, modification detection, duplicate ambiguity, invalid selections, and rename/delete references.
- Full sanitizer DSP, Swift import/editor/library/startup, preset-identity, and Swift/C bridge suite passed.
- Universal arm64/x86_64 build and strict signature verification passed. Installed executable and icon match the package; release inputs match the workspace.
- Native inspection confirmed the dog icon, Refresh directly beside the output picker, and the saved preset name in the Equalizer heading and preset picker.
- Automatic startup resumed Processing with a nonzero output meter. Saved EQ values, presets, output, favorites, and startup preference were preserved.
- Previous app and settings backed up locally.

Audio processing is unchanged. The previously documented intermittent Core Audio startup stall remains a separate issue.
