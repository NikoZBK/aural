import SwiftUI

struct EasyModeView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                AuralSectionLabel(title: "Current preset")
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(model.selectedPresetName ?? "Custom EQ")
                        .font(.system(size: 28, weight: .semibold)).lineLimit(2)
                    if model.isPresetModified {
                        Text("Customized").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AuralStyle.warning)
                    }
                }.accessibilityElement(children: .ignore)
                    .accessibilityLabel("Current preset: \(model.currentPresetTitle)")
                Text("Choose a preset, start EQ, and enjoy your music.")
                    .font(.system(size: 14)).foregroundStyle(AuralStyle.secondary)
            }
            SessionNotices(model: model)
            HStack(alignment: .top, spacing: 20) {
                PresetBrowser(model: model, comfortable: true)
                    .auralPanel(padding: 20).frame(maxWidth: .infinity, maxHeight: .infinity)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        OutputSelection(model: model, comfortable: true).auralPanel(padding: 20)
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Keep your sound", systemImage: "checkmark.circle")
                                .font(.system(size: 16, weight: .semibold)).foregroundStyle(AuralStyle.accent)
                            Text("Your preset and any detailed adjustments stay active in either mode.")
                                .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                            Text("Professional gives you all equalizer controls whenever you need them.")
                                .font(.system(size: 13)).foregroundStyle(AuralStyle.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button { model.setInterfaceMode(.professional) } label: {
                                Label("Open Professional", systemImage: "slider.horizontal.3")
                                    .frame(maxWidth: .infinity)
                            }.buttonStyle(AuralButtonStyle())
                                .help("Show all controls while keeping your current sound.")
                        }.auralPanel(padding: 20)
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "gearshape").accessibilityHidden(true)
                            Text("Use Settings above to start EQ automatically or open Aural when you log in.")
                                .fixedSize(horizontal: false, vertical: true)
                        }.font(.system(size: 13)).foregroundStyle(AuralStyle.secondary).padding(.horizontal, 4)
                    }
                }.frame(width: 320)
            }.frame(maxHeight: .infinity)
        }.padding(24).frame(maxWidth: 1060).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
