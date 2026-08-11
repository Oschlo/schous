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
    /// Mikrofonen fra appikonet som silhuett — samme rutenett i icon.py, uten
    /// flisen bak. Menylinja er laget for template-bilder og farger dem selv
    /// etter lys/mørk meny; hele appikonet krympet til 16 pt ble bare en klatt.
    @MainActor static let menuBar: NSImage = {
        // swift build kjører uten .app-bundle og har ingen ressurser å laste.
        guard let icon = Bundle.main.image(forResource: "MenuBarIcon") else {
            return NSImage(systemSymbolName: "waveform", accessibilityDescription: "Schous") ?? NSImage()
        }
        icon.size = NSSize(width: 16, height: 16)
        icon.isTemplate = true
        return icon
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
        if let mic = defaultInputName() {
            Text("Mikrofon: \(mic)")
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
