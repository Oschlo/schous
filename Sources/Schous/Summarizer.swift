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

    /// Ren strengerstatning. Tom kontekst blir «(none)» så modellen ikke
    /// får en tom linje å tolke.
    static func prompt(_ template: String, language: String, context: String,
                       transcript: String, using form: String) -> String {
        let ctx = context.trimmingCharacters(in: .whitespacesAndNewlines)
        return form
            .replacingOccurrences(of: "{template}", with: template)
            .replacingOccurrences(of: "{language}", with: language)
            .replacingOccurrences(of: "{context}", with: ctx.isEmpty ? "(none)" : ctx)
            .replacingOccurrences(of: "{transcript}", with: transcript)
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
