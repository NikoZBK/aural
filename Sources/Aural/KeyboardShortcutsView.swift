import SwiftUI

struct KeyboardShortcutsView: View {
    @Environment(\.auralInterfaceScale) private var interfaceScale
    @ObservedObject var model: Model
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22 * interfaceScale) {
                VStack(alignment: .leading, spacing: 8 * interfaceScale) {
                    Label("Keyboard shortcuts", systemImage: "keyboard")
                        .auralFont(size: 22, weight: .semibold)
                        .accessibilityAddTraits(.isHeader)
                    Text("⌘ Command   ⌥ Option   ⇧ Shift")
                        .auralFont(size: 12).foregroundStyle(AuralStyle.secondary)
                        .accessibilityLabel("Command, Option, Shift")
                }
                ForEach(ShortcutReference.sections) { section in
                    VStack(alignment: .leading, spacing: 10 * interfaceScale) {
                        Text(section.title).auralFont(size: 13, weight: .semibold).accessibilityAddTraits(.isHeader)
                        VStack(spacing: 9 * interfaceScale) {
                            ForEach(section.shortcuts) { shortcut in
                                HStack(spacing: 20 * interfaceScale) {
                                    Text(shortcut.title).auralFrame(maxWidth: .infinity, alignment: .leading)
                                    Text(shortcut.keys).auralFont(size: 12, weight: .medium, design: .monospaced)
                                        .fixedSize()
                                }
                                .accessibilityRepresentation {
                                    Text("\(shortcut.title), \(shortcut.spokenKeys)")
                                }
                            }
                        }.auralFont(size: 12)
                        if let note = section.note {
                            Text(note).auralFont(size: 11).foregroundStyle(AuralStyle.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text("Shortcuts work while Aural is active. Closing the main window keeps EQ running; quitting stops it.")
                    .auralFont(size: 11).foregroundStyle(AuralStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.auralPadding(24)
        }
        .auralFrame(minWidth: 480, idealWidth: 540, minHeight: 420, idealHeight: 600)
        .background(AuralStyle.background)
        .auralAppearance(model.theme)
    }
}

private struct ShortcutReference: Identifiable {
    let title: String
    let keys: String
    let spokenKeys: String
    var id: String { title }

    struct Section: Identifiable {
        let title: String
        let shortcuts: [ShortcutReference]
        var note: String? = nil
        var id: String { title }
    }

    fileprivate static let sections: [Section] = [
        Section(title: "Equalizer", shortcuts: [
            Self(title: "Undo", keys: "⌘Z", spokenKeys: "Command Z"),
            Self(title: "Redo", keys: "⇧⌘Z / ⌘Y", spokenKeys: "Shift Command Z or Command Y"),
            Self(title: "Compare A", keys: "⌥⌘1", spokenKeys: "Option Command 1"),
            Self(title: "Compare B", keys: "⌥⌘2", spokenKeys: "Option Command 2"),
            Self(title: "Toggle bypass", keys: "⌥⌘B", spokenKeys: "Option Command B"),
            Self(title: "Copy EQ", keys: "⇧⌘C", spokenKeys: "Shift Command C"),
            Self(title: "Paste EQ", keys: "⇧⌘V", spokenKeys: "Shift Command V"),
            Self(title: "Preset library", keys: "⇧⌘P", spokenKeys: "Shift Command P")
        ], note: "Undo and redo work in the workspace and draft editor. A text field's typing history takes precedence."),
        Section(title: "Interface zoom", shortcuts: [
            Self(title: "Zoom in", keys: "⌘+ / ⌘=", spokenKeys: "Command Plus or Command Equals"),
            Self(title: "Zoom out", keys: "⌘−", spokenKeys: "Command Minus"),
            Self(title: "Actual size", keys: "⌘0", spokenKeys: "Command 0")
        ]),
        Section(title: "Text and numeric fields", shortcuts: [
            Self(title: "Cut / Copy / Paste text", keys: "⌘X / ⌘C / ⌘V", spokenKeys: "Command X, Command C, or Command V"),
            Self(title: "Select all text", keys: "⌘A", spokenKeys: "Command A"),
            Self(title: "Apply a numeric value", keys: "Return", spokenKeys: "Return"),
            Self(title: "Cancel a numeric edit", keys: "Esc", spokenKeys: "Escape")
        ], note: "Return and Escape apply to exact-value fields in the main workspace. Draft changes stay in the editor until Apply EQ; Escape cancels the draft."),
        Section(title: "Focused graph and faders", shortcuts: [
            Self(title: "Inspect graph frequencies", keys: "← / →", spokenKeys: "Left or Right Arrow"),
            Self(title: "Clear graph inspection", keys: "Esc", spokenKeys: "Escape"),
            Self(title: "Adjust fader by 0.5 dB", keys: "↑ / ↓", spokenKeys: "Up or Down Arrow"),
            Self(title: "Reset fader to 0 dB", keys: "0", spokenKeys: "0")
        ], note: "Focus the graph or a fader first. Graph inspection leaves your EQ unchanged."),
        Section(title: "Windows", shortcuts: [
            Self(title: "Close current window", keys: "⌘W", spokenKeys: "Command W"),
            Self(title: "Quit Aural", keys: "⌘Q", spokenKeys: "Command Q")
        ])
    ]
}
