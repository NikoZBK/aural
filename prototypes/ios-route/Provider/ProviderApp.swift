import SwiftUI

@main
struct AuralRouteProviderApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section("Route extension installed") {
                        Label("Aural Route Probe", systemImage: "antenna.radiowaves.left.and.right")
                        Text("This app delivers the test extension. Audio playback and EQ run in the separate Aural Route Test app.")
                    }
                    Section("Connect or reconnect") {
                        Text("1. Use a low listening volume. Open Aural Route Test and tap Prepare receiver if it is stopped.")
                        Text("2. Play Spotify, then select Aural Route Probe in Control Center.")
                        Text("3. To test reconnection, keep Spotify playing, switch to iPhone Speaker, then select Aural Route Probe again.")
                        Text("4. Return to Aural Route Test. Check for rising received frames and compare the filter with Bypass EQ.")
                        Text("Keep the receiver running between output changes. You do not need to pause the music before reconnecting.")
                    }
                    Section("Disconnect") {
                        Text("Select your normal output in Control Center, then stop the receiver. If the extension fails to reconnect, save the diagnostics; do not treat one successful connection as a completed routing test.")
                    }
                }
                .navigationTitle("Aural Route Provider")
            }
        }
    }
}
