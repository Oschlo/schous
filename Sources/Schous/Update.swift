import SwiftUI

/// Ser etter nyere utgivelser på GitHub Releases.
///
/// Ingen selvoppdatering: den åpner release-siden, og du drar den nye appen inn
/// i /Applications selv. Å bytte ut bundlen mens den kjører er ikke problemet —
/// signaturen er det. Både TCC (mikrofon, lydopptak) og Keychain-ACL-en på
/// HF_TOKEN henger på designated requirement, så en nedlastet app som er signert
/// med noe annet enn «Schous Dev» spør om alt på nytt. Se CLAUDE.md.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    /// Versjonen som ligger ute, satt bare når den er nyere enn denne appen.
    @Published private(set) var available: String?
    /// Kort svar til menyen etter en manuell sjekk. Nil mens den ikke har sjekket.
    @Published private(set) var status: String?

    private static let api = URL(string: "https://api.github.com/repos/Oschlo/schous/releases/latest")!

    /// Nil under `swift build`, som kjører uten .app-bundle og dermed uten
    /// Info.plist. Da er det ingen versjon å sammenligne med, og sjekken hopper
    /// over — ellers ville hver utviklingsbuild meldt om en oppdatering.
    static var current: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Oppstartssjekken. Stille: sier ingenting når alt er som det skal, og
    /// spør GitHub høyst én gang i døgnet.
    func checkIfDue() async {
        let key = "lastUpdateCheck"
        let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        // Stempelet settes først når GitHub faktisk svarte. En app som starter før
        // nettet er oppe ville ellers brent døgnets sjekk på en feil ingen ser.
        if await check(quiet: true) { UserDefaults.standard.set(Date(), forKey: key) }
    }

    /// Returnerer om GitHub svarte i det hele tatt — `checkIfDue` stempler bare da.
    @discardableResult
    func check(quiet: Bool = false) async -> Bool {
        guard let current = Self.current else { return false }
        // Menylinja lever i ukevis. Uten dette står «Fant ikke ut av det: …» fra en
        // sjekk i forrige uke og lyser mens den neste er underveis.
        status = nil
        do {
            var req = URLRequest(url: Self.api)
            // Uten denne svarer GitHub med v3-standardformatet uansett, men de ber
            // eksplisitt om at klienter pinner versjonen.
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: req)
            // Statuskoden må leses: URLSession kaster ikke på 404, og uten dette
            // ville «ingen utgivelser ennå» kommet ut som en dekodingsfeil.
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                available = nil
                status = quiet ? nil : (code == 404 ? "Ingen utgivelser ennå." : "GitHub svarte \(code).")
                return true   // GitHub svarte, bare ikke med en utgivelse
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = String(release.tagName.trimmingPrefix("v"))
            if isNewer(latest, than: current) {
                available = latest
            } else {
                available = nil
                status = quiet ? nil : "Du har nyeste versjon (\(current))."
            }
            return true
        } catch {
            status = quiet ? nil : "Fant ikke ut av det: \(error.localizedDescription)"
            return false
        }
    }

    /// Åpner nyeste utgivelse. Adressen bygges her og leses ikke ut av svaret:
    /// `html_url` er en streng fra nettet, og `NSWorkspace.open` bryr seg ikke om
    /// hvilket skjema den har — `file://` ville startet en app på maskinen.
    /// GitHub redirigerer `/releases/latest` til den konkrete siden uansett.
    func openReleasePage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/Oschlo/schous/releases/latest")!)
    }

    private struct Release: Decodable {
        let tagName: String

        enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
    }
}

/// Sammenligner versjoner tallvis, ikke leksikografisk — «0.10.0» er nyere enn
/// «0.9.0», selv om strengen sorterer motsatt vei.
///
/// Alt fra første bindestrek og ut kastes. `bundle.sh` stempler fra
/// `git describe`, så en build tre commits etter v0.2.0 heter «0.2.0-3-gf84a688»
/// — den er nyere enn taggen, ikke eldre, og skal ikke mases om.
func isNewer(_ remote: String, than local: String) -> Bool {
    func parts(_ s: String) -> [Int] {
        (s.split(separator: "-").first ?? "").split(separator: ".").map { Int($0) ?? 0 }
    }
    let (r, l) = (parts(remote), parts(local))
    for i in 0 ..< max(r.count, l.count) {
        let a = i < r.count ? r[i] : 0
        let b = i < l.count ? l[i] : 0
        if a != b { return a > b }
    }
    return false
}
