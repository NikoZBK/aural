# Aural user guide

Aural adjusts the sound playing through your chosen stereo output. Use the main window to fine-tune your EQ, or control it from the menu bar. No extra audio driver is required.

- [The workspace](#the-workspace)
- [Output, bypass, and the menu bar](#output-bypass-and-the-menu-bar)
- [Presets](#presets)
- [Themes](#themes)
- [A/B comparison, undo, zoom, and shortcuts](#ab-comparison-undo-zoom-and-shortcuts)
- [Stereo and delay](#stereo-and-delay)
- [Peak protection](#peak-protection)
- [Loudness compensation](#loudness-compensation)
- [AutoEQ search and import](#autoeq-search-and-import)
- [Editing filters and drafts](#editing-filters-and-drafts)
- [Copy, paste, and supported text](#copy-paste-and-supported-text)
- [Startup and updates](#startup-and-updates)
- [Privacy](#privacy)
- [Current scope and troubleshooting](#current-scope-and-troubleshooting)
- [Build, implementation, and tests](#build-implementation-and-tests)
- [Release notes](#release-notes)

## The workspace

The main window has one workspace. Use **Show details / Hide details** to expand or collapse editing controls without changing your sound. Select a numbered point on the EQ curve to open that filter’s exact values. Click and drag a point horizontally to change frequency and vertically to change gain; each drag is one undo step. Fixed graphic bands move vertically only, while gainless filters move horizontally only. Q, filter type, channel, and disabled state are preserved. The **Selected filter** picker also reaches overlapping points, disabled filters, and frequencies outside the graph. **Selected**, **All rows**, and **Faders** offer focused numeric editing, a complete filter table, or gain sliders. **Stereo & delay** exposes the complete stereo controls.

The **Filters** and **Stereo & delay** tabs, the **Filter panel position** button, and **Show/Hide details** form the header of the editing card. With details hidden, the card shrinks to that header. Use the **Filter panel position** button, or **View → Filter panel position → Right of graph**, to move editing controls to the side. The graph narrows and the panel uses the available height, showing more rows at once. Narrow panels wrap each filter's Hz, dB, and Q fields onto a second line. Choose **Below graph** to move it back. Placement is remembered and keeps unfinished numeric input intact.

The previous saved Simple/Professional preference determines whether details initially open collapsed or expanded. New installations start collapsed. All menu commands, clipboard shortcuts, A/B comparison, preamp, and output controls remain available in either state. Showing details never replaces or flattens the active EQ. Graphic EQ gain edits retain their existing representation; **Edit filter parameters…** or **All rows** explicitly converts graphic bands to equivalent editable filters.

Each ten-band slider sets the level you hear at its frequency, and the curve passes through every slider. The bands are Q 1.4 peaks an octave apart, so they overlap: Aural solves each band's filter gain so the combined response at every band frequency equals its slider, at every sample rate. Raising one slider therefore lowers its neighbours' filters slightly. Between band frequencies, the response dips by at most 0.2 dB for a single +6 dB slider (0.4 dB at +12 dB). Converted filters and exported text carry the solved gains. Converted filters do not depend on the sample rate, so at 44.1 and 48 kHz the 8 and 16 kHz levels can shift slightly on conversion. The shift is typically under 0.1 dB and reaches about 1.3 dB when the top two sliders are at opposite extremes.

Aural 1.3 and earlier used the sliders directly as filter gains, so overlapping bands overshot: ten +6 dB sliders measured +8.9 dB near 500 Hz. Profiles, presets and backups saved by those versions are converted when loaded and keep their sound within 0.05 dB. Their sliders move to the levels you were actually hearing; for example, Bass Boost's 5, 5, 4 dB becomes 6.1, 6.8, 5.5 dB. A profile that would need more than ±12 dB on a slider becomes the same ten bands as editable filters. Aural 1.3 and earlier read the new slider values as filter gains, so settings or backups opened in those versions sound slightly stronger.

Choose a preset from the dropdown at the top of the full-width workspace. Favorites, personal presets, and factory presets are grouped in the dropdown, with **Manage presets…** below them. **Save** sits beside the current preset. **Undo**, **Redo**, and the labeled **Compare** A/B control are directly available beside it; **AutoEQ**, **Files**, and **EQ options** group the remaining preset and editing tools. Hover over a shortened preset name to read its full title.

The top listening bar groups **Output**, EQ status, **Bypass**, and **Start EQ / Stop EQ**. The bottom bar follows the signal path: **Preamp** and **Auto**, **Tilt**, then the **Level** meter and **Peak protection**. In narrow windows or at larger interface zoom, controls wrap into rows and peak protection moves below the meter, keeping the curve full width and numeric editors intact. The **Level** meter shows the loudest sample leaving Aural, in dB below full scale (dBFS): 0 dB is the most the output can carry, so readings are negative, and loud music often peaks within a few dB of 0. The bar spans −60 to 0 dB and turns orange within 1 dB of 0. It measures the signal before your Mac's volume control, so changing the volume doesn't move it. Hover over the peak reset button to inspect the held peak. The EQ curve reports estimated headroom separately from the measured output level.

Faders show the active EQ’s actual frequencies and gains: drag up to boost and down to cut, double-click for 0 dB, or use the arrow keys on a focused bar. Imported filters keep their frequency, Q, type, channel, and enabled state; gainless filters have no gain control. **Reset EQ** sets band gains, tilt, and preamp to 0 dB while preserving filter settings and stereo adjustments; one Undo restores the previous EQ. Meter readings update independently, while curve and Auto preamp calculations run in the background. Auto preamp shows progress and rejects results if the EQ or output changed during calculation.

The graph shows separate left/right EQ curves (solid cyan and dotted rose), individual filter curves, and values as you move over the curve. It also includes a dashed purple **Harman** acoustic reference, normalized to 0 dB at 1 kHz. Use its **Harman** menu to hide it or choose **over-ear 2018** or **in-ear 2019**. Automatic selection uses in-ear 2019 for online profiles identified as in-ear and over-ear 2018 otherwise. The solid lines show EQ gain; the dashed Harman line is an acoustic target, so their difference is not a measurement of headphone accuracy. It does not change audio, Auto preamp, or the reported EQ headroom. Both published curves and their [source license](../Sources/Aural/Resources/Targets/AutoEQ-LICENSE.txt) are bundled for offline use. The same reference controls appear in the main graph, AutoEQ search, preset library, and draft editor.

## Output, bypass, and the menu bar

Select the output that your apps use. Aural does not change the macOS default output or affect sound playing through another device. To switch automatically, turn on **Follow macOS output** in the gear menu, the Equalizer menu, or the headphones menu. When macOS switches its sound output, Aural switches too and loads that output's saved EQ. EQ stays on if it was running. Aural stays on its current output if macOS switches to one it cannot equalize, and tells you. Choosing another output in Aural stays in effect until macOS switches again. **Stop** returns audio to its normal path. **Bypass** turns off EQ, preamp, and stereo effects while keeping Aural's audio connection active. Peak protection follows its saved On/Off switch.

EQ usually lowers the overall level, because the preamp makes room for boosts. Bypass then sounds louder, and louder tends to sound better, which makes a fair comparison hard. Turn on **Match levels** (gear menu: **Match levels for Bypass and A/B**) to play Bypass at the EQ's estimated loudness. The curve shows the matched level, such as **Bypassed · matched -5.2 dB**. Matching sets Bypass between −24 and +12 dB, lowers an A/B version by at most 24 dB, and never takes the preamp below −60 dB. When a difference is larger, the curve says **partly matched**. The estimate uses pink noise with ITU-R BS.1770 loudness weighting and covers EQ, preamp, trims, and balance. It leaves out width, crossfeed, mono, and delay, which depend on the music. Matching changes playback only. Saved presets and the preamp stay the same. Close the last Aural window with the red close button or **Command-W** to remove Aural from the Dock while keeping EQ and the menu bar controls running. Choose **Show Aural** from the headphones menu to bring the window and Dock icon back. Minimized windows keep their Dock access. **Quit Aural** or **Command-Q** stops EQ and exits completely.

**Stop EQ** remains available while a numeric edit needs correction. Starting EQ still requires valid pending edits.

The menu bar includes preset selection, favorites, preamp adjustments in 1 dB steps within the current EQ limits, and tilt in 0.5 dB steps. These controls preserve the current bypass and playback state.

Aural's icon is an EQ curve shaped like the letter A. While EQ is processing, the A lights up inside; when EQ is stopped or bypassed, it shows the curve alone. The main window, About window, and running app's Dock icon update together, including after using controls in the menu bar. Finder keeps the idle icon.

## Presets

The main window and preset menu show the selected preset. An **EDITED** badge in the main window marks changes from the saved version. The selection is remembered separately for each output. Saving under a new name selects that preset; renaming updates its displayed name, and deleting it leaves the current sound as Custom EQ.

Selecting a preset applies it immediately, starts EQ if stopped, and turns bypass off. Switching between saved AutoEQ profiles and built-in presets keeps audio running. If a preset cannot run at the output's current sample rate, Aural explains the problem and keeps the current sound unchanged.

Choose **Manage presets…** in the preset dropdown, or choose **Equalizer → Preset library…** (⇧⌘P) to search, favorite, duplicate, rename, or delete presets. Built-in presets can be duplicated and favorited; renaming and deletion apply to custom presets. **Undo delete** restores the most recent deletion until Aural quits. Deleting or renaming a saved preset does not change the active EQ.

**Back up presets…** writes a versioned JSON file containing custom presets and favorites. **Restore presets…** validates the entire backup before merging; conflicting names receive numeric suffixes. Restore never replaces the current EQ or enables processing. Device selection, startup preferences, and per-device settings are not part of a preset backup.

## Themes

Choose **Theme** in the gear settings, **View** menu, or headphones menu. **System** follows your Mac's light/dark appearance; **Light** and **Dark** keep a fixed appearance. The choice is saved and applies immediately to all Aural windows, popovers, graphs, and file dialogs. Changing themes keeps the current EQ, playback, and drafts. Dark remains the default for both new and existing installations.

Every theme uses solid surfaces: the header and level bar are docked to the window edges, and the graph and editing controls sit on flat panels with hairline borders. One fixed instrument color — cyan, deeper in Light and brighter in Dark — marks the EQ curve, the selected band, Start EQ, checked options, and the level meter, so it means the same thing on every Mac regardless of the system accent. Amber is reserved for warnings, such as Bypass and peaks near full scale. Increase Contrast strengthens borders and the accent. Earlier Standard/Liquid Glass style preferences are retired without changing saved audio or presets.

## A/B comparison, undo, zoom, and shortcuts

Select **B** to make a second copy of your current EQ settings. Edit A or B, then switch between them to compare. Each keeps its own EQ, stereo settings, and preset name. A dashed curve shows the other version when it differs. With **Match levels** on, the louder version plays at the quieter one's estimated loudness, so you compare tone rather than volume. Use the comparison menu to copy one version to the other or reset both. A/B settings and undo history reset when you change output or quit Aural; save each version as a preset to keep it.

**Undo/Redo** covers EQ and stereo edits, band layout changes, applying presets, and A/B switching, up to 100 changes. Each slider drag counts as one change. Use **⌘Z** to undo and **⇧⌘Z** or **⌘Y** to redo in the workspace and draft editor. Text-field typing history takes precedence; an untouched field does not block EQ history. Shortcuts are **⌥⌘1 / ⌥⌘2** for A/B and **⌥⌘B** for bypass. These shortcuts work while Aural is active; ordinary text-field copy/paste remain available. Undo does not change whether EQ is running or bypassed.

Use **⌘+** (or **⌘=**) and **⌘−** to enlarge or reduce text and controls in 10% steps, from 80% to 140%. **⌘0** restores actual size. These commands are also in **View**. The workspace keeps its window size and gives the graph less space as controls grow; narrow layouts wrap the toolbar, and small windows let the inspector and workspace scroll. Aural remembers the size without changing your EQ or submitting a pending number.

Open **Help → Keyboard shortcuts…** for the shortcut reference. It is also available from Aural's headphones menu.

## Stereo and delay

**Stereo & delay** lets you adjust left/right levels, balance, stereo width, crossfeed, mono, polarity, and 0–30 ms delay, and swap left and right. Crossfeed blends low frequencies from the opposite channel for headphone listening. Width 1 keeps the original stereo sound; width 0 combines both channels into mono. Mono is applied before the separate left/right adjustments. **Swap left and right** exchanges the channels before EQ, so left and right filters, trims, delay, and polarity still apply to the left and right outputs; use it when headphones or speakers are reversed. Defaults leave the sound unchanged. Delay adds the amount you enter; it does not measure the total delay through your Mac. The EQ curve shows filters and preamp only, without stereo effects or peak protection. **Auto preamp** sets a level based on estimated EQ and stereo gain to help prevent clipping; it is not a true-peak guarantee.

APO text supports channel-targeted and Mid/Side filters and channel delays, but no other stereo effects. Copy/export rejects trims, balance, width, crossfeed, mono, polarity, and swap with an explanation, so they cannot be silently discarded. Save a preset and use **Files → Back up presets…** to preserve the complete configuration, including stereo settings. Legacy presets remain compatible; new stereo/channel presets require Aural 1.0.0 or later.

## Peak protection

Use the **Peak protection** checkbox beside the Level meter to turn protection on or off. It starts enabled and remembers your choice across restarts, presets, outputs, and A/B comparisons. When enabled, it limits both channels together to 0.98 (about −0.2 dB, just under full scale), including during Bypass. **Reducing** shows its gain reduction; **Ready** means EQ is stopped. Off fades out any limiter attenuation within about half a second, without a click, and allows peaks above full scale. The switch is also in the Equalizer and menu-bar menus. Brief peaks are retained between display updates. Lower the preamp if protection frequently reduces the level. Protection limits true peaks: the waveform your Mac reconstructs between samples, which can rise above every sample. It looks 1 ms ahead, so the level eases down before each peak instead of jumping. Below 13 kHz at 44.1 kHz, true peaks stay within 0.05 dB of the limit; near 20 kHz, within about 0.2 dB. The look-ahead delays audio by about 1.2 ms, the same whether protection is on or off and in Bypass. The Level meter still shows sample peaks.

## Loudness compensation

Quiet music sounds thinner than loud music: hearing loses bass, and to a lesser extent the highest treble, faster than the midrange as the level drops. **Loudness compensation** (gear menu, Equalizer menu, or headphones menu) restores that balance as you turn the macOS volume down, following the ISO 226:2003 equal-loudness contours. Set the volume where your EQ sounds right and choose **Use current volume as reference** in the gear menu; Aural captures the current volume automatically the first time you turn compensation on for an output, and each output keeps its own reference. **Reference level** says how loud music is at that volume, from 70 to 90 phon; 80 phon suits a comfortable, full level. At or above the reference volume, EQ plays as set. Each decibel below it lowers the listening level by one phon, down to 40 phon below the reference, and Aural adds the difference between the two contours with 1 kHz unchanged. Ten fixed filters follow it within about 1.2 dB from 20 Hz to 12.5 kHz at every sample rate; 20 dB below an 80 phon reference, bass rises about 8 dB at 50 Hz and treble about 3 dB at 12.5 kHz. The gear menu shows the current listening level and boost.

Compensation only boosts, so it can raise peaks above full scale: keep peak protection on, or lower the preamp if protection often reduces the level. It needs an output whose volume macOS controls; with fixed-volume outputs, such as some USB interfaces and HDMI, it has nothing to follow. Bypass turns it off with the rest of the EQ. The EQ curve, Auto preamp, and level matching leave it out, because it changes with the volume rather than the EQ.

## AutoEQ search and import

Click **AutoEQ** in the main toolbar, choose **Files → Search AutoEQ profiles…** or **Equalizer → Search AutoEQ profiles…**, or use **AutoEQ…** in the preset library. Search by headphone brand/model and filter by measurement source. Model numbers match with or without spaces and hyphens. Each measurement stays separate; its source, rig/collection, and original result link appear alongside a preview of the downloaded parametric correction. These are AutoEQ’s computed settings, not necessarily the measurement author’s manually tuned EQ.

**Import profile** validates the complete download, replaces the current EQ, stops processing, and saves a named preset with its source attribution. Click **Start EQ** when ready. Repeated imports receive numeric suffixes; **Undo** restores the previous EQ. Searching, previewing, cancelling, or a failed download leaves the current sound unchanged. The loaded catalog stays available in the browser window; **Refresh AutoEQ catalog** fetches the latest index. The first load and uncached profile downloads require an internet connection. Headphone data is fetched from the public [AutoEQ results catalog](https://github.com/jaakkopasanen/AutoEq/tree/master/results), under the project’s [MIT license](https://github.com/jaakkopasanen/AutoEq/blob/master/LICENSE); correction data is not bundled with Aural.

Choose **Files → Import AutoEQ text…** (or the Equalizer menu) and select a UTF-8 parametric or fixed-band text export. The complete file is validated before current settings change. Import stops processing, replaces the previous EQ, and saves a named preset. Click **Start EQ** when ready. Repeated filenames receive a numeric suffix instead of overwriting existing presets.

## Editing filters and drafts

Edit filters directly in the main window: choose their type, frequency, gain, Q (which controls filter width), and whether they are enabled. Set the exact overall gain with **Preamp**. Each filter applies to both channels (**L+R**), **Left**, **Right**, **Mid**, or **Side**. Mid is what the channels share, (L + R)/2, and Side is their difference, (L − R)/2: a Mid cut softens centred vocals and bass, and a Side boost widens the stereo image. Filters run in list order, and both channels return to left and right after them. Once the EQ has a Mid or Side filter, the curve shows mid (solid) and side (dotted) instead of left and right, and **M + S**, **M**, and **S** inspect them; the peak readout and Auto preamp still cover what each output can reach. **Low shelf 6 dB/oct** and **High shelf 6 dB/oct** are gentler, first-order shelves for broad tilts: they have no Q, and like the other shelves they reach half their gain at their frequency. Add or remove filters up to the 64-filter limit. Adjust all band gains at once, reduce or invert their effect, or shift their frequencies. To replace the current EQ deliberately, choose **EQ actions → New EQ → New flat 10-band EQ** or **New flat 31-band EQ**. You can undo a layout change, and it preserves stereo settings. Imports replace the previous EQ rather than adding to it.

**Tilt** in the bottom bar brightens or darkens the whole EQ around 1 kHz, from −6 to +6 dB. Positive values raise the treble and lower the bass, and negative values do the reverse: +3 dB plays about 3 dB louder at 16 kHz and 3 dB quieter at 20 Hz, and 1 kHz stays where it was. Tilt is a pair of 6 dB/octave shelves at 1 kHz that runs after the filters. It belongs to the EQ, so presets, A/B, undo, the curve, Auto preamp, and level matching include it, and it does not count toward the 64 filters. It does not appear as a numbered point. Switching to a new flat layout or **Reset EQ** sets it to 0 dB.

**EQ options → Edit as a draft…** opens a separate editor where you can preview changes before applying them. Each row's actions menu can duplicate or move a filter up/down. **Undo** and **Redo** restore up to 100 draft edits, including filter additions/removals, order, values, enabled state, and preamp. **Apply EQ** checks the complete draft and updates EQ; if EQ was stopped, it stays stopped. **Cancel** leaves the current sound unchanged. Invalid values keep the editor open with an explanation. Save a named preset to reuse the changes. Imported values retain their precision until edited.

## Copy, paste, and supported text

Click **Copy settings (Equalizer APO format)** on a headphone EQ page, then **Paste EQ** in Aural (⇧⌘V). Aural validates the complete text, saves it as a “Clipboard EQ” preset, and stops processing. Click **Start EQ** when ready. Invalid or empty clipboard text reports an error without changing your EQ or stopping audio.

**Copy EQ** (⇧⌘C) copies the current preamp and every filter in Equalizer APO / AutoEQ text format, preserving precision and disabled filters. The ten-band equalizer exports as ten peaking filters with the same frequencies and Q, and the solved gains that put each slider's level at its frequency. **Export EQ…** saves the same text to a file. Equalizer APO has no shelf that matches Aural's 6 dB/octave shelves, so copying or exporting a profile with one explains which filter to change, and a profile with tilt asks you to set Tilt to 0 dB; presets and backups keep both. These actions are also in the **Equalizer** menu; ordinary text-field copy and paste shortcuts remain available.

Supported commands are a global `Preamp`, `Channel: ALL`, `Channel: L`, `Channel: R`, the mid/side `Copy` commands below, `Delay` in ms, and `Filter` lines with or without a number. Filter types are `PK`, `PEQ`, and Room EQ Wizard's `Modal` (peaking, with `Gain`); `LSC` and `HSC` shelves (center frequency, with `Gain`); `LS` and `HS` shelves (`Gain`, corner frequency when a Q or slope is given); `LP`/`LPQ` and `HP`/`HPQ` (second-order pass filters); `BP` (band-pass with unity peak gain); `NO`; and `AP`. Every filter needs `Fc`; parameters may come in any order. Q is given as `Q`, as `BW Oct` (bandwidth in octaves, not for shelves), or for shelves as a slope after the type, such as `LSC 12dB` (12 dB is the steepest standard slope). As in Equalizer APO, an omitted Q means 0.707 for pass and band-pass filters, 30 for notches, and a 10.8 dB slope at the center frequency for shelves; peaking and all-pass filters need a Q. `LS 6dB` and `HS 6dB` are 6 dB slopes of the standard shelf, not Aural's 6 dB/octave shelves. `None` lines, which Room EQ Wizard writes for unused filters, are skipped. Pass, notch, and all-pass filters have no adjustable gain; a nonzero `Gain` on them is rejected. Numbers may use a decimal comma. A frequency with exactly three decimals and at least five characters, such as `1.000`, is read as Room EQ Wizard's thousands separator, as Equalizer APO does; Aural adds a fourth decimal when exporting such frequencies. Lines without a colon, such as a Room EQ Wizard file header, and its `Dated:`, `Notes:`, and `Equaliser:` lines are ignored, so Room EQ Wizard filter files import directly. Blank lines, `#` comments, OFF filters, CRLF, and a UTF-8 BOM are accepted. No Preamp line means 0 dB. `Delay` lines add up per channel up to 30 ms and become the Stereo & delay settings; Aural delays the channels after every filter, so a delay that differs between left and right must come after any Mid/Side filters, and delays in samples are rejected. Limits are 64 filters, 10–22000 Hz, −30 to +30 dB filter gain, Q 0.05–50, −60 to +24 dB imported preamp, and 64 KB file size. All filters may be disabled; their values remain saved and preamp, stereo effects, and enabled peak protection still affect audio. Global Bypass additionally bypasses preamp and stereo effects. A per-channel `Preamp` command is rejected; use Aural’s channel trims for this. Raw `IIR` coefficients, `GraphicEQ`, `Include`, and other commands are rejected with the line that needs attention.

Equalizer APO has no mid/side channels, so Mid/Side filters use its `Copy` routing, which Aural writes and reads. `Copy: L=0.5*L+0.5*R R=0.5*L+-0.5*R` puts mid on the left channel and side on the right; `Channel: L` filters then apply to mid and `Channel: R` filters to side, and `Copy: L=L+R R=L+-1*R` restores left and right. Copy EQ adds the restoring line before the next Left or Right filter and at the end. Import also accepts these two lines with any scale the second undoes, and assignments in either order or with dB factors. Any other `Copy` command, and a mid/side `Copy` that is never restored, is rejected.

`GraphicEQ:` curves, WAV convolution, CSV measurements, and other APO commands are not supported. Use AutoEQ's **ParametricEQ.txt** or **FixedBandEQ.txt** export for file import. Online search downloads **ParametricEQ.txt** profiles.

## Startup and updates

The gear menu controls startup. With automatic EQ enabled, Aural restores the saved output and EQ settings and waits up to 60 seconds for that exact device. It does not apply headphone settings to another device when the original is disconnected. Aural displays startup and permission errors.

EQ that was running resumes on its own after these interruptions:

- **Sleep.** Aural releases its audio connection before sleep and resumes about two seconds after wake.
- **Disconnect.** If the output disconnects, EQ waits for that same device and resumes when it reconnects. It never moves headphone settings to another device, unless **Follow macOS output** is on.
- **Sample-rate or format change.** Aural restarts once on the same output. If the route keeps failing within 30 seconds, EQ stops and shows the error.

While EQ waits, the status reads **Waiting**. **Cancel** or **Stop EQ** ends the wait. EQ that was stopped stays stopped.

Choose **Check for Updates…** from the Aural menu, menu bar controls, Settings, or About. Aural downloads and verifies updates, then installs them and relaunches. Your saved settings and presets stay on your Mac. Automatic checks and downloads are optional. Installing an update briefly stops EQ; after relaunch, Aural follows your existing **Start EQ automatically** setting. The **Releases page** link is available if a check fails.

Users upgrading from 1.2.1 or earlier install the latest version manually once to enable future in-app updates.

## Privacy

Aural does not record audio files, collect telemetry, or upload profiles. Checking for updates requests the update feed for the latest public release from GitHub (including Aural’s version in the User-Agent); automatic checks happen only if you turn them on. Opening AutoEQ search requests the public catalog from GitHub, and selecting a result downloads that profile. Search terms and source filters stay on your Mac. Downloads use normal HTTP caching; Refresh requests a fresh catalog. GitHub receives normal connection information such as your IP address and the requested profile path. Source links open in your default browser. Audio is processed locally in memory. Only system audio input is used; hardware input streams are disabled when present.

Settings and imported profiles are stored in the current user's `~/Library/Application Support/Aural/settings.json`. They are created at runtime and are **not** included in the app, installer, repository, or releases. Tests use invented data rather than downloaded headphone profiles. A new installation starts with flat EQ and both startup options off.

## Current scope and troubleshooting

Aural currently targets stereo listening and calibration. It supports a single stereo output stream in 32-bit float format at 32–192 kHz. It does not support mono/surround outputs, multi-stream interfaces, aggregate/multi-output setups, per-app mixing, or convolution. Bluetooth, USB hardware, sleep/wake behavior, protected media, and extended operation need further hardware testing. Intel is cross-compiled; runtime checks to date were performed on Apple silicon.

Latency depends on the device buffer size and has not been measured end to end. Aural's own processing adds a fixed 1 ms plus 7 samples (about 1.2 ms) for the peak protection look-ahead. A built-in band at or above 49% of sample rate is disabled. For imported profiles, an enabled filter beyond that threshold prevents starting rather than silently changing the profile; select a higher sample rate in Audio MIDI Setup. The stopped response preview uses 48 kHz; processing uses the actual device rate.

If there is no output signal, check the selected output and **System Settings → Privacy & Security → Screen & System Audio Recording**. Quit and reopen after granting access. See [installation, updates, and removal](INSTALL.txt).

The [feature comparison](PEACE-FEATURE-ROADMAP.md) lists what Aural supports and what is still missing compared with Peace and Equalizer APO.

## Build, implementation, and tests

Install Apple's Command Line Tools or Xcode with the macOS 26 SDK or newer, then run:

```sh
bash scripts/test.sh
bash scripts/build.sh
bash scripts/package.sh
```

- `test.sh`: DSP tests with AddressSanitizer/UndefinedBehaviorSanitizer and Swift parser/startup tests.
- `build.sh`: compiles arm64 and x86_64, combines them into a universal executable, adds the icon, signs locally, and creates a ZIP in `dist/`.
- `package.sh`: builds the app, creates a drag-to-Applications DMG, verifies the image, and writes SHA-256 checksums.
- `make-icon.sh`: regenerates the complete macOS ICNS size set from the included PNG.

Swift Package Manager downloads the pinned Sparkle update framework. Build outputs are ignored by Git. [Release instructions](RELEASING.md) cover signed packaging and the update feed. The [future updates guide](FUTURE-UPDATES.md) covers proposed priorities, code locations, compatibility rules, testing, and release handoffs.

`Audio.swift` owns the private process tap and aggregate device. Aural excludes its own process to prevent feedback and mutes the original stream only while the tap is consumed. It uses the selected output's clock. The callback is stopped and destroyed before its DSP state is freed. Startup validates native 32-bit float stereo frame layouts; periodic route checks stop processing if stream identities or channel offsets change, or a stream format becomes unsupported.

`DSP.c` implements the biquad filters, preamp, peak protection, and a bounded lock-free settings queue. Coefficients and gain conversion are prepared on the control thread. Live changes crossfade between two preallocated filter chains over 20 ms; rapid edits are coalesced to the latest pending state after the current fade completes. Unchanged filter prefixes retain their state independently for each channel, including when edits to the other channel move filter slots. Mid/Side filters convert to mid and side when the list reaches one and back before the next Left or Right filter and at the end; Stereo filters run in either form, and filter state converts exactly when an edit moves that boundary. Bypassed chains continue processing internally to avoid stale-state replay. The audio callback performs no allocation, locks, logging, filesystem access, or Swift/Objective-C calls. The optional channel swap exchanges the inputs before the filters. Stereo processing applies normalized 700 Hz crossfeed, mid/side width or mono sum, per-channel trim/balance/polarity, fractional delay, then true-peak protection with 1 ms look-ahead. Peak protection interpolates 8x with a 12-tap Kaiser-windowed sinc and applies a stereo-linked gain that is the 1 ms average of a held minimum, so each frame's gain is at or below the limit for every peak it contributes to.

Tests cover measured frequency response, channel isolation, Mid/Side routing, tilt, the ISO 226 contours and loudness filter accuracy, preamp/bypass, level-matched bypass, sample rates, clipping protection, buffer layouts, invalid controls, peaking/shelf response, AutoEQ validation and precision, saved-settings migration, startup device selection, resume waits after sleep or disconnect, and output following. Native launch, import, saved-profile reload, and automatic startup have also been checked on Apple silicon.

The engine tests measure response at 32, 44.1, 48, 96, and 192 kHz, check all-pass phase inversion at its center frequency, exercise explicit disabled filters, and stress rapid updates and 64-filter extremes. A magnitude floor of −300 dB per filter keeps exact notch zeros finite in the response calculation; it does not change audio. Nonfinite samples and malformed buffers latch faults for the control thread instead of sending invalid samples to the output.

Filter shapes follow the analog prototypes of the [W3C Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/), digitized with M. Vicanek's matched second-order design ("Matched Second Order Digital Filters", 2016): poles map exactly, and each filter matches its analog level at 0 Hz, at its own frequency and at half the sample rate. A filter therefore keeps its shape at every sample rate instead of narrowing toward the top of the audio band. All-pass filters keep the cookbook's bilinear form, whose magnitude is already exact. The 6 dB/octave shelves use the same match with one real pole; one pole cannot follow the analog curve all the way to half the sample rate, but at 44.1 kHz shelves up to 15 kHz stay within 0.6 dB of it. Equalizer APO, AutoEQ and Aural 1.3 and earlier use the bilinear form, so at 44.1 and 48 kHz treble filters sound slightly different from them: by under 0.8 dB for filters below 4 kHz, and by up to about 3 dB for wide ±6 dB filters near 16 kHz. At 96 kHz the difference stays under 0.6 dB. Text syntax follows the supported subset of the [Equalizer APO reference](https://sourceforge.net/p/equalizerapo/wiki/Configuration%20reference/). Profiles containing new filter types require Aural 0.8.0 or later, and 6 dB/octave shelves and Mid/Side filters require Aural 1.4 or later. Aural 1.3 and earlier play a tilted profile without its tilt.

[Apple Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) · [AutoEQ](https://github.com/jaakkopasanen/AutoEq) · [Icon provenance](ICON.md)

## Release notes

- [1.4](RELEASE-1.4.0.md): Mid/Side filters, 6 dB/octave shelves, tilt, loudness compensation, true-peak protection, and up to 64 filters.
- [1.3](RELEASE-1.3.0.md): verified in-app updates and signed packaging.
- [1.2.1](RELEASE-1.2.1.md): undo/redo, interface zoom, and a keyboard shortcuts guide.
- [1.2](RELEASE-1.2.0.md): Liquid Glass, the expandable workspace, and direct curve editing.
- [1.1](RELEASE-1.1.0.md): system-accent themes, faster mode switching, visual EQ bars, Reset EQ, and resizable panes.
- [1.0.0](RELEASE-1.0.0.md): the redesigned equalizer, left/right EQ, stereo controls, A/B comparison, and reversed dog states.
- [0.9.4](RELEASE-0.9.4.md): sleeping and happy icon states.
- [0.9.3](RELEASE-0.9.3.md): running in the menu bar after closing the window.
- [0.9.2](RELEASE-0.9.2.md): selected-preset display and the dog-with-headphones icon.
- [0.9.0](RELEASE-0.9.0.md): the earlier Ultra interface.
