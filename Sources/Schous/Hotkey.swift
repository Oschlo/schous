import Carbon.HIToolbox
import AppKit

/// Global snarvei for opptak: ⌃⌥R starter og stopper uansett hvilken app som
/// har fokus. Carbon `RegisterEventHotKey` er fortsatt den eneste offentlige
/// API-en som gjør dette uten tilgjengelighetstillatelse, og den virker på
/// Apple silicon. Tastekombinasjonen er fast; en innstilling for den kommer
/// når noen kolliderer med den.
enum Hotkey {
    private static let id = EventHotKeyID(signature: OSType(0x5343_484F), id: 1) // 'SCHO'
    @MainActor private static var ref: EventHotKeyRef?

    @MainActor static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            // Carbon leverer på hovedtråden; assumeIsolated er en påstand, ikke en hopp.
            MainActor.assumeIsolated {
                let recorder = Recorder.shared
                let wasRecording = recorder.isRecording
                recorder.toggle()
                if wasRecording { Hotkey.showMainWindow() }
            }
            return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey),
                            id, GetApplicationEventTarget(), 0, &ref)
    }

    /// Samme som «Åpne Schous» i menyen: løft vinduet der opptaket nå ligger
    /// forhåndsvalgt. Utenfor en View finnes ingen `openWindow`, så dette
    /// finner NSWindow-et scenen «main» eier. Det ligger i `windows` også
    /// etter at brukeren har lukket det — målt på v0.5.0 (#46), så ingen
    /// reserve via `openWindow` trengs.
    @MainActor static func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let w = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            w.makeKeyAndOrderFront(nil)
        }
    }
}
