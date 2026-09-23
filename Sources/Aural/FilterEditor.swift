import SwiftUI

struct FilterEditor: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ParametricDraft
    @State private var error: String?

    init(model: Model) {
        self.model = model
        _draft = State(initialValue: ParametricDraft(model.profile))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Parametric EQ").font(.title2.weight(.semibold))
                    Text("Adjust your filters, then apply to hear the changes.").foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(draft.filters.count) / 32 filters").foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("Preamp").fontWeight(.medium)
                TextField("dB", text: $draft.preamp).frame(width: 80).accessibilityLabel("Parametric preamp")
                Text("dB").foregroundStyle(.secondary)
                Spacer()
                Button("Add filter", systemImage: "plus") { draft.filters.append(FilterDraft()) }
                    .disabled(draft.filters.count >= 32)
            }
            HStack(spacing: 8) {
                Text("ON").frame(width: 36)
                Text("TYPE").frame(width: 112, alignment: .leading)
                Text("FREQUENCY · Hz").frame(width: 126, alignment: .leading)
                Text("GAIN · dB").frame(width: 100, alignment: .leading)
                Text("Q").frame(width: 90, alignment: .leading)
                Spacer()
            }.font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach($draft.filters) { $filter in
                        HStack(spacing: 8) {
                            Toggle("Enabled", isOn: $filter.enabled).labelsHidden().toggleStyle(.checkbox).frame(width: 36)
                            Picker("Filter type", selection: $filter.kind) {
                                Text("Peak · PK").tag(ImportedFilter.Kind.peak)
                                Text("Low shelf · LSC").tag(ImportedFilter.Kind.lowShelf)
                                Text("High shelf · HSC").tag(ImportedFilter.Kind.highShelf)
                            }.labelsHidden().frame(width: 112)
                            TextField("Frequency", text: $filter.frequency).frame(width: 126).accessibilityLabel("Frequency in Hz")
                            TextField("Gain", text: $filter.gain).frame(width: 100).accessibilityLabel("Filter gain in dB")
                            TextField("Q", text: $filter.q).frame(width: 90).accessibilityLabel("Filter Q")
                            Button { draft.filters.removeAll { $0.id == filter.id } } label: {
                                Image(systemName: "minus.circle").frame(width: 24)
                            }.buttonStyle(.borderless).help("Remove filter").accessibilityLabel("Remove filter")
                        }.padding(.vertical, 2)
                    }
                }
            }.frame(height: min(300, max(80, CGFloat(draft.filters.count) * 32)))
            Text("10–22000 Hz · gain −30 to +30 dB · Q 0.05–50 · at least one filter enabled")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if let error {
                Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Save as a named preset from the main window.").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    do {
                        let profile = try draft.profile()
                        if model.replaceProfile(profile) { dismiss() }
                        else { error = model.error }
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.font(.system(size: 12)).textFieldStyle(.roundedBorder)
            .padding(22).frame(width: 660).background(AuralStyle.background)
            .preferredColorScheme(.dark).tint(AuralStyle.accent)
    }
}
