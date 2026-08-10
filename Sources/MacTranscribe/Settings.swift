import SwiftUI
import Security

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var backendPath: String {
        didSet { UserDefaults.standard.set(backendPath, forKey: "backendPath") }
    }
    @Published var hfToken: String {
        didSet { Keychain.set(hfToken, for: "HF_TOKEN") }
    }
    @Published var checkResult: String?

    private init() {
        backendPath = UserDefaults.standard.string(forKey: "backendPath") ?? ""
        hfToken = Keychain.get("HF_TOKEN") ?? ""
    }

    var backendURL: URL? { backendPath.isEmpty ? nil : URL(fileURLWithPath: backendPath) }
    var pythonURL: URL? { backendURL?.appending(path: ".venv/bin/python") }

    var isConfigured: Bool {
        guard let py = pythonURL else { return false }
        return FileManager.default.isExecutableFile(atPath: py.path)
    }

    /// Kjører `transcribe.py --selfcheck`. Bekrefter både sti og at venv-et importerer numpy/soundfile.
    func runSelfcheck() {
        guard let backend = backendURL, let py = pythonURL else {
            checkResult = "Velg backend-mappen først."
            return
        }
        guard FileManager.default.isExecutableFile(atPath: py.path) else {
            checkResult = "Fant ikke .venv/bin/python i \(backend.lastPathComponent)."
            return
        }
        let p = Process()
        p.executableURL = py
        p.arguments = ["transcribe.py", "--selfcheck"]
        p.currentDirectoryURL = backend
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            checkResult = out.contains("selfcheck ok") ? "✓ selfcheck ok" : "Feilet: \(out.isEmpty ? "ingen output" : out)"
        } catch {
            checkResult = "Kunne ikke starte python: \(error.localizedDescription)"
        }
    }
}

enum Keychain {
    private static let service = "co.oschlo.mactranscribe"

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
                    Button("Test", action: settings.runSelfcheck)
                    if let r = settings.checkResult {
                        Text(r).font(.caption)
                            .foregroundStyle(r.hasPrefix("✓") ? .green : .red)
                    }
                }
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
