import Foundation

/// Estimater fra forrige kjøring (#39). Backend rapporterer ingen tid i steg
/// 1–3, og ollama sender ingenting under prefill — det eneste som finnes er
/// hvor lang tid det tok sist, på denne maskinen. Ratene er lineære i
/// lydlengde (steg) og promptlengde (referat); det er en tilnærming, og
/// teksten sier «ca.» og «vanligvis» av den grunn.
///
/// `UserDefaults` er injiserbar så `--selfcheck` kan kjøre mot en egen suite
/// og aldri røre brukerens tall.
enum Estimates {
    static let stepKey = "stepRates"        // ["2": sek per lydsekund, …]
    static let summaryKey = "summaryRates"  // [modell: [lastSek, sekPerTegn]]

    static func stepEstimate(_ step: Int, audioSeconds: Double,
                             in d: UserDefaults = .standard) -> TimeInterval? {
        guard audioSeconds > 0,
              let rate = (d.dictionary(forKey: stepKey) as? [String: Double])?[String(step)]
        else { return nil }
        return rate * audioSeconds
    }

    static func recordStep(_ step: Int, seconds: TimeInterval, audioSeconds: Double,
                           in d: UserDefaults = .standard) {
        guard audioSeconds > 0, seconds > 0 else { return }
        var rates = (d.dictionary(forKey: stepKey) as? [String: Double]) ?? [:]
        rates[String(step)] = seconds / audioSeconds
        d.set(rates, forKey: stepKey)
    }

    static func summaryEstimate(model: String, promptChars: Int,
                                in d: UserDefaults = .standard) -> TimeInterval? {
        guard let r = (d.dictionary(forKey: summaryKey) as? [String: [Double]])?[model],
              r.count == 2 else { return nil }
        return r[0] + r[1] * Double(promptChars)
    }

    static func recordSummary(model: String, loadSeconds: Double, promptSeconds: Double,
                              promptChars: Int, in d: UserDefaults = .standard) {
        guard promptChars > 0 else { return }
        var rates = (d.dictionary(forKey: summaryKey) as? [String: [Double]]) ?? [:]
        rates[model] = [loadSeconds, promptSeconds / Double(promptChars)]
        d.set(rates, forKey: summaryKey)
    }

    /// «under ett minutt», «ca. 3 min», «ca. 1 t 10 min». Rundet til minutt:
    /// et anslag med sekunder ser mer presist ut enn det er.
    static func describe(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded())
        if m < 1 { return "under ett minutt" }
        if m < 60 { return "ca. \(m) min" }
        return "ca. \(m / 60) t \(m % 60) min"
    }
}
