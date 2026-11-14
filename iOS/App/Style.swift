import SwiftUI

extension Color {
    static let auralAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.28, green: 0.88, blue: 0.94, alpha: 1)
            : UIColor(red: 0, green: 0.40, blue: 0.47, alpha: 1)
    })
    static let auralViolet = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.72, green: 0.66, blue: 1, alpha: 1)
            : UIColor(red: 0.42, green: 0.29, blue: 0.73, alpha: 1)
    })
}

struct AuralBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        ZStack {
            scheme == .dark ? Color(red: 0.025, green: 0.05, blue: 0.075) : Color(red: 0.94, green: 0.97, blue: 0.97)
            if contrast != .increased {
                RadialGradient(colors: [Color.auralAccent.opacity(scheme == .dark ? 0.22 : 0.14), .clear], center: .topLeading, startRadius: 0, endRadius: 540)
                RadialGradient(colors: [Color.auralViolet.opacity(scheme == .dark ? 0.16 : 0.12), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 480)
            }
        }.ignoresSafeArea()
    }
}

struct GlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        if opaque || contrast == .increased {
            content.background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(.primary.opacity(0.25), lineWidth: 1))
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
    }
}

struct ContentCard<Content: View>: View {
    var emphasized = false
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 28)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(opaque || contrast == .increased ? 1 : scheme == .dark ? 0.62 : 0.82))
                    .overlay {
                        if emphasized && !opaque && contrast != .increased {
                            RoundedRectangle(cornerRadius: 28).fill(LinearGradient(colors: [Color.auralAccent.opacity(0.15), .clear, Color.auralViolet.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        }
                    }
            }
            .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(LinearGradient(colors: [.primary.opacity(contrast == .increased ? 0.45 : emphasized ? 0.18 : 0.08), .primary.opacity(contrast == .increased ? 0.45 : 0.03)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .shadow(color: .black.opacity(emphasized && !opaque ? 0.08 : 0), radius: 24, y: 12)
    }
}

/// A static symbol, never a simulated audio meter.
struct AuralIcon: View {
    let symbol: String
    var color: Color = .auralAccent
    var body: some View {
        Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
            .foregroundStyle(color).frame(width: 44, height: 44)
            .background(color.opacity(0.12), in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(color.opacity(0.16), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

struct SectionHeading: View {
    let title: String
    let symbol: String
    var body: some View {
        Label(title, systemImage: symbol).font(.system(.headline, design: .rounded))
            .labelStyle(.titleAndIcon)
    }
}

struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit = "dB"
    var editing: (Bool) -> Void = { _ in }
    @State private var exact = false
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(spacing: 4) {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout())
            layout {
                Text(title).fontWeight(.medium)
                if !typeSize.isAccessibilitySize { Spacer() }
                Button { exact = true } label: {
                    Text(value.formatted(.number.precision(.fractionLength(1))) + " " + unit)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.auralAccent.opacity(0.09), in: .capsule)
                        .frame(minHeight: 44)
                }.buttonStyle(.plain).foregroundStyle(Color.auralAccent).accessibilityLabel("Edit exact \(title)")
            }.font(.subheadline)
            Slider(value: $value, in: range, onEditingChanged: editing)
                .accessibilityLabel(title)
                .accessibilityValue(value.formatted(.number.precision(.fractionLength(1))) + " " + unit)
        }.padding(.vertical, 2)
            .sheet(isPresented: $exact) {
                ExactValueSheet(title: title, initial: value, range: range, unit: unit) { next in
                    editing(true); value = next; editing(false)
                }
            }
    }
}

struct ExactValueSheet: View {
    let title: String
    let range: ClosedRange<Double>
    let unit: String
    let apply: (Double) -> Void
    @State private var text: String
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    init(title: String, initial: Double, range: ClosedRange<Double>, unit: String, apply: @escaping (Double) -> Void) {
        self.title = title; self.range = range; self.unit = unit; self.apply = apply
        _text = State(initialValue: String(initial))
    }
    var body: some View {
        NavigationStack {
            Form {
                NumericField(title: title, text: $text, unit: unit).focused($focused)
                Text("Range: \(range.lowerBound.formatted()) to \(range.upperBound.formatted()) \(unit). Use a decimal point.").font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply") {
                            guard let next = Double(text.trimmingCharacters(in: .whitespaces)), next.isFinite, range.contains(next) else {
                                error = "Enter a number within the allowed range."; return
                            }
                            apply(next); dismiss()
                        }
                    }
                }.onAppear { focused = true }
        }.presentationDetents([.medium, .large])
    }
}

func frequencyLabel(_ value: Double) -> String {
    value >= 1000 ? (value / 1000).formatted(.number.precision(.fractionLength(0...2))) + " kHz" : value.formatted(.number.precision(.fractionLength(0...2))) + " Hz"
}
