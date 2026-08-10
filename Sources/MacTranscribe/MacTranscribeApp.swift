import SwiftUI

@main
struct MacTranscribeApp: App {
    init() {
        if CommandLine.arguments.contains("--selfcheck") { runSelfcheckAndExit() }
        // SwiftPM-binærer starter uten Dock-ikon/fokus; .app-bundlen trenger dette eksplisitt.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("MacTranscribe") {
            ContentView()
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
        }
    }
}
