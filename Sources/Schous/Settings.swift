import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Samme PATH som jobbene får. En .app startet fra Finder arver ikke
    /// /opt/homebrew/bin, og en sjekk med en annen PATH tester noe annet enn
    /// det som gjelder når det står på.
    nonisolated static let subprocessPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    /// Miljøet både jobbene og sjekkene kjører med.
    ///
    /// `HF_TOKEN` fjernes med vilje. Appen har ikke lenger noe token selv —
    /// `huggingface_hub.get_token()` i backenden leser fila — men den *arver*
    /// ett hvis den ble startet fra et skall der `~/.zshenv` har exportet det.
    /// Finder gjør ikke det. Uten denne linja svarer «Test modelltilgang»
    /// ✓ på et token som forsvinner ved neste normale start, altså et grønt
    /// svar på et spørsmål ingen stilte. Én kilde, den fila eier.
    nonisolated static var subprocessEnv: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = subprocessPATH
        env["HF_TOKEN"] = nil
        return env
    }

    /// Endres stien eller tokenet, gjelder ikke lenger svaret fra forrige sjekk.
    /// Å la et grønt «✓ access ok» stå over et token som nettopp ble byttet er
    /// verre enn ikke å ha svart: det er et svar på et spørsmål ingen stilte.
    @Published var backendPath: String {
        didSet {
            UserDefaults.standard.set(backendPath, forKey: "backendPath")
            checkResult = nil
        }
    }
    /// Standardformatene «Lagre» skriver. Lagres som rawValues; ukjente
    /// strenger fra en nyere versjon droppes stille av init(rawValue:).
    @Published var formats: Set<OutputFormat> {
        didSet {
            // Fast rekkefølge, ikke Set-ens: `defaults read` skal se likt ut mellom kjøringer.
            UserDefaults.standard.set(OutputFormat.allCases.filter(formats.contains).map(\.rawValue),
                                      forKey: "outputFormats")
        }
    }
    @Published var checkResult: String?
    @Published var checking = false

    private init() {
        backendPath = UserDefaults.standard.string(forKey: "backendPath") ?? ""
        let saved = UserDefaults.standard.stringArray(forKey: "outputFormats")
        formats = saved.map { Set($0.compactMap(OutputFormat.init(rawValue:))) }
            ?? Set(OutputFormat.allCases)
    }

    var backendURL: URL? { backendPath.isEmpty ? nil : URL(fileURLWithPath: backendPath) }
    var pythonURL: URL? { backendURL?.appending(path: ".venv/bin/python") }

    var isConfigured: Bool {
        guard let py = pythonURL else { return false }
        return FileManager.default.isExecutableFile(atPath: py.path)
    }

    /// `--selfcheck`: ffmpeg på PATH, de tre tunge importene, og parserne.
    /// Lokalt og uten nett, men tar noen sekunder på å importere torch.
    func runSelfcheck() {
        run(["transcribe.py", "--selfcheck"], expect: "selfcheck ok")
    }

    /// `--check-access`: er tokenet i live, og er modell-lisensene godtatt med
    /// kontoen det tilhører. Eneste sjekken som rører nettet — derfor egen
    /// knapp, så den som kjører med HF_HUB_OFFLINE=1 slipper.
    func runAccessCheck() {
        run(["transcribe.py", "--check-access"], expect: "access ok")
    }

    private func run(_ args: [String], expect: String) {
        guard let backend = backendURL, let py = pythonURL else {
            checkResult = "Velg backend-mappen først."
            return
        }
        guard FileManager.default.isExecutableFile(atPath: py.path) else {
            checkResult = "Fant ikke .venv/bin/python i \(backend.lastPathComponent)."
            return
        }
        checking = true
        checkResult = nil
        Task.detached {
            let out = Self.capture(py, args: args, cwd: backend)
            await MainActor.run {
                self.checking = false
                self.checkResult = out.contains(expect)
                    ? "✓ \(expect)"
                    : "Feilet: \(out.isEmpty ? "ingen output" : out)"
            }
        }
    }

    /// Utenfor MainActor: torch-importen og nettkallet tar sekunder, og et
    /// waitUntilExit på hovedtråden ville frosset vinduet så lenge.
    private nonisolated static func capture(_ py: URL, args: [String], cwd: URL) -> String {
        let p = Process()
        p.executableURL = py
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.environment = subprocessEnv
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "Kunne ikke starte python: \(error.localizedDescription)"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Backend") {
                HStack {
                    TextField("mac-local-transcribe-with-diarization", text: $settings.backendPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Velg…", action: pickBackend)
                }
                HStack {
                    Button("Test backend", action: settings.runSelfcheck)
                    Button("Test modelltilgang", action: settings.runAccessCheck)
                    if settings.checking { ProgressView().controlSize(.small) }
                }
                if let r = settings.checkResult {
                    Text(r).font(.caption).textSelection(.enabled)
                        .foregroundStyle(r.hasPrefix("✓") ? .green : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("«Test backend» er lokal: ffmpeg, torch, pyannote, mlx-whisper. "
                     + "«Test modelltilgang» spør Hugging Face om tokenet lever og om "
                     + "modell-lisensene er godtatt — den eneste sjekken som bruker nett.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Eksportformater") {
                ForEach(OutputFormat.allCases) { f in
                    Toggle(f.label, isOn: Binding(
                        get: { settings.formats.contains(f) },
                        set: { on in
                            if on { settings.formats.insert(f) } else { settings.formats.remove(f) }
                        }))
                }
                Text("Hva «Lagre» skriver som standard. Menyen på Lagre-knappen "
                     + "kan skrive ett enkelt format uten å endre dette.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Hugging Face") {
                // Ikke et felt: tokenet eies av huggingface_hub, som leser
                // HF_TOKEN og faller tilbake på ~/.cache/huggingface/token.
                // En egen kopi her måtte ligge i Keychain, og den ACL-en er
                // nøklet på cdhash — altså én dialog per build. Se #26.
                Text("Tokenet settes med `hf auth login` i backend-mappen, "
                     + "ikke her. «Test modelltilgang» sier fra hvis det mangler.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        // Hele skjemaet, ikke bare knappene: sjekken kjører på stien slik den
        // var da den startet, så et felt som kan endres mens den går, gir et
        // grønt svar på noe som aldri ble sjekket.
        .disabled(settings.checking)
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
    }

    private func pickBackend() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Velg"
        if panel.runModal() == .OK, let url = panel.url {
            settings.backendPath = url.path   // nullstiller checkResult selv
        }
    }
}
