import SwiftUI

enum AuralStyle {
    static let accent = Color(red: 0.72, green: 0.93, blue: 0.53)
    static let background = Color(red: 0.055, green: 0.064, blue: 0.068)
    static let surface = Color(red: 0.085, green: 0.099, blue: 0.105)
    static let elevated = Color(red: 0.12, green: 0.137, blue: 0.143)
    static let border = Color.white.opacity(0.09)
    static let secondary = Color(red: 0.66, green: 0.71, blue: 0.72)
    static let warning = Color(red: 1, green: 0.73, blue: 0.40)
}

extension View {
    func auralPanel(padding: CGFloat = 18) -> some View {
        self.padding(padding)
            .background(AuralStyle.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(AuralStyle.border))
    }
}

struct AuralSectionLabel: View {
    let title: String
    var systemImage: String? = nil
    var body: some View {
        HStack(spacing: 7) {
            if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
            Text(title.uppercased()).tracking(1.1)
        }.font(.system(size: 10, weight: .semibold)).foregroundStyle(AuralStyle.secondary)
    }
}

struct AuralNotice: View {
    let message: String
    var isError = false
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(isError ? AuralStyle.warning : AuralStyle.accent)
                .accessibilityHidden(true)
            Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 12)).padding(12)
            .background((isError ? AuralStyle.warning : AuralStyle.accent).opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AuralButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .foregroundStyle(prominent ? AuralStyle.background : Color.primary)
            .background(prominent ? AuralStyle.accent : AuralStyle.elevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(prominent ? .clear : AuralStyle.border))
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
    }
}
