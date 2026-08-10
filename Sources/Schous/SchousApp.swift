import SwiftUI

@main
struct SchousApp: App {
    @StateObject private var recorder = Recorder.shared

    init() {
        if CommandLine.arguments.contains("--selfcheck") { runSelfcheckAndExit() }
        // SwiftPM-binærer starter uten Dock-ikon/fokus; .app-bundlen trenger dette eksplisitt.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        // Window, ikke WindowGroup: appen kjører én jobb av gangen, og openWindow(id:)
        // mot en WindowGroup lager et nytt vindu for hvert opptak i stedet for å løfte det.
        Window("Schous", id: "main") {
            ContentView()
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
        }

        MenuBarExtra {
            MenuBarContent(recorder: recorder)
        } label: {
            // Menylinjen tegner ikonet som template-bilde, så farge slår ikke gjennom —
            // det er symbolet selv som må skille opptak fra ikke-opptak.
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "waveform")
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var recorder: Recorder
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(recorder.isRecording ? "Stopp opptak — \(clock)" : "Start opptak") {
            let wasRecording = recorder.isRecording
            recorder.toggle()
            // Etter stopp: løft vinduet, der opptaket nå ligger forhåndsvalgt.
            if wasRecording { showWindow() }
        }
        if let error = recorder.errorMessage {
            Text(error)
        }
        Divider()
        Button("Åpne Schous") { showWindow() }
        Divider()
        Button("Avslutt Schous") { NSApplication.shared.terminate(nil) }
    }

    private var clock: String {
        let s = Int(recorder.elapsed)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func showWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
