import SwiftUI

@main
struct AuralApp: App {
    @StateObject private var model = AuralModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            AuralRootView()
                .environmentObject(model)
                .environmentObject(model.audio)
                .preferredColorScheme(model.state.library.theme == .system ? nil : model.state.library.theme == .dark ? .dark : .light)
                .tint(Color.auralAccent)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { model.gesture(false); model.persist() }
                }
        }
    }
}
