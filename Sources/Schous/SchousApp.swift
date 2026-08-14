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
                // Window-scenen åpnes ved start, så dette er oppstartssjekken.
                // Den er stille og spør GitHub høyst én gang i døgnet.
                .task { await Updater.shared.checkIfDue() }
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
    @ObservedObject private var updater = Updater.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(recorder.isRecording ? "Stopp opptak — \(clock)" : "Start opptak") {
            let wasRecording = recorder.isRecording
            recorder.toggle()
            // Etter stopp: løft vinduet, der opptaket nå ligger forhåndsvalgt.
            if wasRecording { showWindow() }
        }
        if recorder.isRecording {
            // Nivået mens det pågår. Et dødt spor oppdaget etter at møtet er
            // over er en obduksjon; dette er tidsnok til å gjøre noe.
            Text("System   \(meter(recorder.systemLevel))")
            if recorder.inputLabel != nil {
                Text("Mikrofon \(meter(recorder.micLevel))")
            }
        }
        if let mic = recorder.inputLabel {
            // «Inngang», ikke «Mikrofon»: målerraden over heter allerede
            // Mikrofon, og to rader med samme ord leses som en gjentakelse.
            Text("Inngang: \(mic)")
        }
        if let warning = recorder.liveWarning {
            Text("⚠︎ \(warning)")
        }
        if let error = recorder.errorMessage {
            Text(error)
        }
        Divider()
        Button("Åpne Schous") { showWindow() }
        if let version = updater.available {
            Button("Hent oppdatering — \(version)…") { updater.openReleasePage() }
        } else {
            Button("Se etter oppdateringer…") { Task { await updater.check() } }
        }
        if let status = updater.status {
            Text(status)
        }
        Divider()
        Button("Avslutt Schous") { NSApplication.shared.terminate(nil) }
    }

    /// Åtte blokker. En meny tar bare tekst — ingen ProgressView, ingen Canvas —
    /// og en tekstmåler er lesbar nok til å svare på det eneste spørsmålet som
    /// betyr noe: kommer det lyd inn her?
    private func meter(_ level: Float) -> String {
        let filled = Int((level * 8).rounded())
        return String(repeating: "▮", count: filled)
            + String(repeating: "▯", count: 8 - filled)
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
