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
            if recorder.isRecording {
                Image(systemName: "record.circle.fill")
            } else {
                Image(nsImage: .menuBar)
            }
        }
    }
}

private extension NSImage {
    /// Appikonet i menylinje-størrelse. 16 pt er valgt fordi .icns-en har en
    /// representasjon på akkurat 16 og 32 px (se icon.py), så pikselkunsten
    /// skaleres med heltall og forblir skarp i stedet for å bli interpolert.
    @MainActor static let menuBar: NSImage = {
        let icon = NSApplication.shared.applicationIconImage ?? NSImage()
        let sized = icon.copy() as? NSImage ?? icon
        sized.size = NSSize(width: 16, height: 16)
        // Ikonet er i farger med vilje; template-rendering ville gjort det til en klatt.
        sized.isTemplate = false
        return sized
    }()
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
