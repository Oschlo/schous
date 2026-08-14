import SwiftUI
import Security

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Samme PATH som jobbene får. En .app startet fra Finder arver ikke
    /// /opt/homebrew/bin, og en sjekk med en annen PATH tester noe annet enn
    /// det som gjelder når det står på.
    nonisolated static let subprocessPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    @Published var backendPath: String {
        didSet { UserDefaults.standard.set(backendPath, forKey: "backendPath") }
    }
    @Published var checkResult: String?
    @Published var checking = false

    private var loadedToken: String?

    /// Leses fra Keychain første gang noen spør, ikke ved oppstart: ellers
    /// kjører SecItemCopyMatching idet vinduet bygges, og et ACL-spørsmål
    /// dukker opp uten sammenheng med noe brukeren gjorde.
    var hfToken: String {
        get {
            if loadedToken == nil { loadedToken = Keychain.get("HF_TOKEN") ?? "" }
            return loadedToken!
        }
        set {
            guard newValue != hfToken else { return }   // SecItemDelete+Add bygger ACL-en på nytt
            objectWillChange.send()
            loadedToken = newValue
            Keychain.set(newValue, for: "HF_TOKEN")
        }
    }

    private init() {
        backendPath = UserDefaults.standard.string(forKey: "backendPath") ?? ""
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
        run(["transcribe.py", "--selfcheck"], expect: "selfcheck ok", token: nil)
    }

    /// `--check-access`: er tokenet i live, og er modell-lisensene godtatt med
    /// kontoen det tilhører. Eneste sjekken som rører nettet — derfor egen
    /// knapp, så den som kjører med HF_HUB_OFFLINE=1 slipper.
    func runAccessCheck() {
        run(["transcribe.py", "--check-access"], expect: "access ok", token: hfToken)
    }

    private func run(_ args: [String], expect: String, token: String?) {
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
            let out = Self.capture(py, args: args, cwd: backend, token: token)
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
    private nonisolated static func capture(_ py: URL, args: [String], cwd: URL,
                                            token: String?) -> String {
        let p = Process()
        p.executableURL = py
        p.arguments = args
        p.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = subprocessPATH
        if let token, !token.isEmpty { env["HF_TOKEN"] = token }
        p.environment = env
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

enum Keychain {
    private static let service = "co.oschlo.schous"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
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
                .disabled(settings.checking)
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
            Section("Hugging Face") {
                SecureField("HF_TOKEN", text: $settings.hfToken)
                    .textFieldStyle(.roundedBorder)
                Text("Kreves for pyannote-diarization. Lagres i Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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
            settings.backendPath = url.path
            settings.checkResult = nil
        }
    }
}
