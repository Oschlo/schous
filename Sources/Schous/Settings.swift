import SwiftUI
import Security

/// Fram til #26 lå tokenet i login-nøkkelringen. Koden som skrev det er borte,
/// men elementet blir liggende hos alle som brukte en eldre versjon — en
/// hemmelighet ingenting lenger eier. Målt på denne maskinen etter oppgraderingen:
/// `security find-generic-password -s co.oschlo.schous -a HF_TOKEN` → finnes.
///
/// Appen sletter det ikke selv. For den som aldri kjørte `hf auth login` er
/// dette den siste kopien, og en app som stille kaster den ville tatt en
/// avgjørelse som ikke er dens. Så den sier fra, slik `systemWarning` gjør med
/// tapp-stillheten: oppgi det som er observert, og la den som sitter der velge.
///
/// Kun attributter, aldri `kSecReturnData`: uten dekryptering er det ingen
/// ACL-dialog. Målt — svar med én gang, `SecurityAgent` startet ikke.
enum LegacyKeychain {
    /// `static let`, ikke en beregnet property: den leses fra en SwiftUI-`body`,
    /// som kjøres på nytt ved hvert tastetrykk i backend-feltet — en
    /// Keychain-spørring per tegn er sløsing uten gevinst. Elementet dukker
    /// ikke opp midt i en økt. Prisen er at varselet blir stående til appen
    /// startes på nytt hvis du sletter elementet mens den kjører.
    static let hasOrphanedToken: Bool = {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "co.oschlo.schous",
            kSecAttrAccount as String: "HF_TOKEN",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess
    }()

    /// Kommandoen brukeren kan kopiere. `/usr/bin/security` ligger i
    /// `apple-tool:`-partisjonen og slipper gjennom ACL-en stille — den samme
    /// asymmetrien som er dokumentert under «Hemmeligheter hører ikke hjemme i
    /// fil-nøkkelringen»: verktøyet leser og sletter der en Schous-signert
    /// binær ville blitt stoppet.
    static let removeCommand =
        "security delete-generic-password -s co.oschlo.schous -a HF_TOKEN"
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Samme PATH som jobbene får. En .app startet fra Finder arver ikke
    /// /opt/homebrew/bin, og en sjekk med en annen PATH tester noe annet enn
    /// det som gjelder når det står på.
    nonisolated static let subprocessPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    /// Grunnmiljøet både jobbene og sjekkene bygger videre på.
    ///
    /// Token-variablene fjernes med vilje. Appen har ikke noe token selv —
    /// `huggingface_hub.get_token()` i backenden leser fila — men den *arver*
    /// det skallet hadde hvis den ble startet med `open` fra et skall der
    /// `~/.zshenv` exporterer noe. Finder gjør ikke det. Uten strippingen
    /// svarer «Test modelltilgang» ✓ på et token som forsvinner ved neste
    /// normale start, altså et grønt svar på et spørsmål ingen stilte.
    ///
    /// Én variabel er ikke nok, og det er hele grunnen til at dette er en
    /// liste: `_auth.py:147` er `os.environ.get("HF_TOKEN") or
    /// os.environ.get("HUGGING_FACE_HUB_TOKEN")`, og `HF_TOKEN_PATH`/`HF_HOME`
    /// flytter *fila* fallbacken leser. Målt med `HF_HOME` mot en tom mappe,
    /// så bare miljøet kunne svare:
    ///
    ///     ingen av variablene satt        get_token -> None
    ///     kun HUGGING_FACE_HUB_TOKEN      get_token -> len=19
    ///
    /// `HF_HOME` tar modell-cachen med seg, ikke bare tokenet. Det er med
    /// vilje: en Finder-start ser den aldri, så en app som følger den fra et
    /// skall ville oppført seg forskjellig avhengig av hvordan den ble startet
    /// — og det er nøyaktig feilen dette skal fjerne.
    nonisolated static var subprocessEnv: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = subprocessPATH
        for key in hfEnvKeys { env.removeValue(forKey: key) }
        return env
    }

    /// Alt `huggingface_hub` leser for å finne et token. Egen konstant fordi
    /// `--selfcheck` må kunne slå fast at *hele* lista blir borte, ikke bare
    /// den første — en sjekk på `HF_TOKEN` alene ville stått grønn gjennom
    /// nøyaktig den feilen som gjorde dette nødvendig.
    nonisolated static let hfEnvKeys = ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN",
                                        "HF_TOKEN_PATH", "HF_HOME"]

    /// Endres stien, gjelder ikke lenger svaret fra forrige sjekk. Å la et
    /// grønt «✓ access ok» stå over en backend som nettopp ble byttet er verre
    /// enn ikke å ha svart: det er et svar på et spørsmål ingen stilte.
    ///
    /// Tokenet har ikke det vernet lenger, og det er en reell kostnad ved å
    /// gi det fra seg: det settes med `hf auth login` *utenfor* appen, og
    /// ingenting her får vite at det skjedde. Et grønt svar kan altså stå over
    /// et token som er byttet siden. Trykk «Test modelltilgang» på nytt etter
    /// en `hf auth login` — appen kan ikke gjøre det for deg.
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
    ///
    /// Fristen er rundhåndet fordi den bare skal fange en henging, ikke en treg
    /// maskin. Målt her: 4,7 s kald, 2,7 s varm. Første kjøring etter en
    /// installasjon leser torch fra kald disk og kan bruke atskillig lenger.
    func runSelfcheck() {
        run(["transcribe.py", "--selfcheck"], expect: "selfcheck ok", timeout: 120)
    }

    /// `--check-access`: er tokenet i live, og er modell-lisensene godtatt med
    /// kontoen det tilhører. Eneste sjekken som rører nettet — derfor egen
    /// knapp, så den som kjører med HF_HUB_OFFLINE=1 slipper.
    ///
    /// Kortere frist enn selvtesten, og det er nettopp nettet som er grunnen:
    /// `whoami` sender ingen `timeout=`, og sesjonen i `_http.py` har
    /// `timeout=None`. Målt her: 0,8 s. 30 s er raust for et tregt nett og
    /// kort nok til at en portal som aldri svarer ikke blir et evig venterom.
    func runAccessCheck() {
        run(["transcribe.py", "--check-access"], expect: "access ok", timeout: 30)
    }

    private func run(_ args: [String], expect: String, timeout: TimeInterval) {
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
            let out = Self.capture(py, args: args, cwd: backend, timeout: timeout)
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
    ///
    /// **Fristen er ikke pynt.** `readDataToEndOfFile` + `waitUntilExit` venter
    /// evig, og `whoami` i `huggingface_hub` sender ingen `timeout=` — sesjonen
    /// i `_http.py:311,322` står på `timeout=None`. På et nett som tar imot
    /// TCP-forbindelsen og så tier — hotell- og konferanseportaler gjør nettopp
    /// det — kom prosessen aldri tilbake. Og siden `SettingsView` legger
    /// `.disabled(checking)` på *hele* skjemaet, satt brukeren igjen med en
    /// snurrende ProgressView, ingen felt som kunne klikkes, ingen feilmelding
    /// og ingen avbryt-knapp. Eneste vei ut var å drepe appen.
    ///
    /// Derfor en frist per kall i stedet for én felles: den lokale importen og
    /// nettkallet feiler på helt ulike tidsskalaer, og ett tall som er trygt
    /// for torch på kald disk ville gjort portal-tilfellet til tre minutters
    /// venting.
    /// Ikke `private`: `--selfcheck` må kunne kjøre den mot noe som henger med
    /// vilje. En frist som aldri er sett utløse er en frist man tror på, ikke
    /// en man vet virker.
    nonisolated static func capture(_ py: URL, args: [String], cwd: URL,
                                    timeout: TimeInterval) -> String {
        let p = Process()
        p.executableURL = py
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.environment = subprocessEnv
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let started = Date()
        do {
            try p.run()
        } catch {
            return "Kunne ikke starte python: \(error.localizedDescription)"
        }
        // Drepes utenfra når fristen går. `terminate()` lukker skriveenden, så
        // readDataToEndOfFile under får EOF og slipper taket — uten dette ville
        // en frist ikke hjulpet, for det er *lesingen* som henger, ikke ventingen.
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()

        // Stdout og stderr deler rør, så dette er alt prosessen rakk å si.
        // Kappes: en advarselsstorm fra torch ville ellers strukket
        // Innstillinger-vinduet ut av skjermen.
        var text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 800 { text = "…" + text.suffix(800) }

        // Målt forløpt tid, ikke et delt flagg: fristen er den eneste veien til
        // en terminate() her, så en kjøring som varte så lenge *er* den som ble
        // drept — og da slipper vi en Bool to tråder må enes om.
        if Date().timeIntervalSince(started) >= timeout {
            return "Ga opp etter \(Int(timeout)) s. Prosessen svarte ikke — "
                + "sjekk nettforbindelsen (en åpen WiFi-portal tar imot "
                + "forbindelsen og svarer så aldri).\n" + text
        }
        // Exit-koden leses, ellers ser en drept prosess ut som en som rakk å
        // svare: avkortet output og ingenting som sier at den døde underveis.
        guard p.terminationReason == .exit else {
            return "Prosessen ble drept (signal \(p.terminationStatus)).\n" + text
        }
        return p.terminationStatus == 0 ? text : "kode \(p.terminationStatus): " + text
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
                     + "ikke her. Appen ignorerer `HF_TOKEN` i miljøet med vilje, "
                     + "så en `export` i `~/.zshenv` gjelder terminalen og ikke "
                     + "appen. «Test modelltilgang» sier fra hvis det mangler.")
                    .font(.caption).foregroundStyle(.secondary)
                if LegacyKeychain.hasOrphanedToken {
                    Text("En eldre versjon la et token i nøkkelringen. Det brukes "
                         + "ikke lenger, og blir liggende til du fjerner det:")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(LegacyKeychain.removeCommand)
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
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
