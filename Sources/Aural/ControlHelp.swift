/// Shared descriptions keep hover help consistent across windows and menus.
enum AuralHelp {
    static let signalPath = "Audio passes through preamp, filters and tilt, loudness compensation, stereo and delay, then optional peak protection. Bypass skips EQ and stereo effects; peak protection follows its On/Off switch. Stop releases the audio connection. Closing the window keeps audio running in the menu bar."
    static let preamp = "Adjust the overall level before the filters. Lower it to leave room for EQ boosts."
    static let tilt = "Tilt the EQ around 1 kHz. Positive values brighten the sound; negative values darken it."
    static let balance = "Move the sound toward the left or right output. Zero keeps both channels balanced."
    static let width = "Adjust stereo width: 0 is mono, 1 is the original width, and 2 is wider. Turn off Mono to adjust width."
    static let crossfeed = "Blend low frequencies from the opposite channel for headphone listening. Zero turns crossfeed off."
    static let followOutput = "Follow the macOS sound output and load its saved EQ. Keep EQ running if it is already on."
    static let matchLevels = "Play Bypass and the louder A/B version at the same estimated loudness for a fair comparison."
    static let bypass = "Skip EQ, preamp, and stereo effects while routing stays active. Peak protection follows its On/Off switch."
    static let peakProtection = "Limit true peaks in both channels together, including during Bypass. Turn off to allow peaks above full scale."
    static let loudness = "Restore bass and treble as you turn the volume below its reference level."
    static let copyEQ = "Copy the current EQ to the clipboard as Equalizer APO text."
    static let pasteEQ = "Replace the current EQ with Equalizer APO text from the clipboard. Undo restores the previous EQ."
    static let exportEQ = "Save the current EQ as an Equalizer APO text file."
    static let presetLibrary = "Search, organize, and back up presets (⇧⌘P)."
    static let autoEQ = "Search online headphone correction profiles and preview them before importing."
    static let appMixer = "Open per-app volume and mute (⌥⌘M)."
    static let about = "Show Aural's version, credits, and project links."
    static let updates = "Open software updates and check for a newer version of Aural."
    static let shortcuts = "Show keyboard shortcuts for editing, playback controls, zoom, and windows."
    static let panelPosition = "Place editing controls below or to the right of the graph. Your choice is remembered."

    static func processing(_ active: Bool) -> String {
        active ? "Stop audio processing, cancel any pending start, and release the audio connection."
               : "Start audio processing on the selected output using the current EQ."
    }

    static func applyPreset(_ name: String) -> String {
        "Apply preset “\(name)”. Applying starts EQ if it is stopped."
    }

    static func filterChannel(_ number: Int) -> String {
        "Choose whether filter \(number) affects both channels, left, right, mid, or side."
    }
}
