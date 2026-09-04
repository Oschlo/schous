import Foundation

enum SummaryLanguage: String, CaseIterable, Identifiable {
    case norwegian, english
    var id: String { rawValue }
    var label: String { self == .norwegian ? "Norsk" : "Engelsk" }
    /// Verdien som settes inn i prompten. Engelsk, fordi prompten er det.
    var promptValue: String { self == .norwegian ? "Norwegian" : "English" }
}

enum Summary {
    /// Det som sendes er nøyaktig denne teksten med fire verdier byttet inn —
    /// ingen skjult system-prompt. Engelsk fordi modellene følger engelske
    /// instrukser mest pålitelig; språket på referatet styres av {language}.
    static let defaultPrompt = """
    You are writing a meeting summary. Follow the template below exactly: \
    its sections, its order and its style notes.

    {template}

    Additional context from the user:
    {context}

    Write the summary in {language}. Use the timestamps in the transcript \
    when citing what was said. Do not invent names or facts that are not \
    in the transcript.

    Transcript:
    {transcript}
    """

    /// Étt gjennomløp av `form` — en verdi som selv inneholder f.eks.
    /// «{transcript}» (mulig i en brukerskrevet mal, eller i konteksten)
    /// skal stå urørt, ikke skannes på nytt av et senere bytte.
    static func prompt(_ template: String, language: String, context: String,
                       transcript: String, using form: String) -> String {
        let ctx = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = ["template": template, "language": language,
                      "context": ctx.isEmpty ? "(none)" : ctx, "transcript": transcript]
        let pattern = try! NSRegularExpression(pattern: #"\{(template|language|context|transcript)\}"#)
        let ns = form as NSString
        var result = ""
        var scanned = 0
        for match in pattern.matches(in: form, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: scanned, length: match.range.location - scanned))
            result += values[ns.substring(with: match.range(at: 1))]!
            scanned = match.range.location + match.range.length
        }
        result += ns.substring(from: scanned)
        return result
    }
}

/// Malene er *.md i én mappe. Filnavnet er malnavnet; ingenting parses.
enum Templates {
    static let directory = URL.applicationSupportDirectory.appending(path: "Schous/templates")

    /// Seedmalene fra bundlen. `swift build` har ingen bundle; da er dette nil
    /// og mappa opprettes tom.
    static var bundled: URL? { Bundle.main.resourceURL?.appending(path: "templates") }

    /// Kopierer seedmalene bare når mappa *ikke finnes*. En tom mappe er et
    /// valg den som sitter der har tatt, og seedes ikke på nytt.
    static func seedIfMissing(into dir: URL = directory, from seeds: URL? = bundled) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dir.path) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let seeds else { return }
        for url in list(in: seeds) {
            try? fm.copyItem(at: url, to: dir.appending(path: url.lastPathComponent))
        }
    }

    static func list(in dir: URL = directory) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func name(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    /// «Customer Call» → «customer-call». Brukes i filnavnet på referatet.
    static func slug(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}
