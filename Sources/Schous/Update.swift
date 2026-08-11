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
    private var page: URL?

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
        UserDefaults.standard.set(Date(), forKey: key)
        await check(quiet: true)
    }

    func check(quiet: Bool = false) async {
        guard let current = Self.current else { return }
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
                return
            }
            let release = try JSONDecoder.gitHub.decode(Release.self, from: data)
            page = URL(string: release.htmlUrl)
            let latest = release.tagName.trimmingPrefix("v")
            if isNewer(String(latest), than: current) {
                available = String(latest)
                status = nil
            } else {
                available = nil
                status = quiet ? nil : "Du har nyeste versjon (\(current))."
            }
        } catch {
            status = quiet ? nil : "Fant ikke ut av det: \(error.localizedDescription)"
        }
    }

    /// Åpner release-siden — den konkrete når sjekken fant en, ellers oversikten.
    func openReleasePage() {
        NSWorkspace.shared.open(page ?? URL(string: "https://github.com/Oschlo/schous/releases")!)
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlUrl: String
    }
}

private extension JSONDecoder {
    static let gitHub: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
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
