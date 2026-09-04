import AppKit
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
        // Uten bundle (swift build) finnes ingen seeds; da må mappa *ikke*
        // lages, ellers har debug-binæren skrudd av seedingen for bundlen.
        guard let seeds else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for url in list(in: seeds) {
            try? fm.copyItem(at: url, to: dir.appending(path: url.lastPathComponent))
        }
    }

    /// Seeder hvis mappa mangler, lager den hvis det ikke fantes seeds, åpner.
    static func open() {
        seedIfMissing()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    static func list(in dir: URL = directory) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func name(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    /// «Customer Call» → «customer-call». Brukes i filnavnet på referatet,
    /// så «/» og «:» må ut først (#42).
    static func slug(_ name: String) -> String {
        filenameSafe(name).lowercased().replacingOccurrences(of: " ", with: "-")
    }
}

/// Ett kall mot ollama, strømmet. Teksten som vokser er fremdriften.
@MainActor
final class Summarizer: ObservableObject {
    enum State: Equatable { case idle, running, done(URL), failed(String) }
    /// Hvor i kjøringen vi er (#39). ollama sender ingenting under lasting og
    /// prefill, så «venter» er alt som kan sies der — med et anslag fra
    /// forrige kjøring på samme modell når det finnes.
    enum Phase: Equatable { case idle, waiting(estimate: TimeInterval?), streaming }

    @Published var text = ""
    @Published var state: State = .idle
    @Published var started: Date?
    @Published private(set) var phase: Phase = .idle
    /// Ord i prompten, til «Modellen leser transkripsjonen (7 716 ord)».
    @Published private(set) var promptWords = 0
    /// Hvor ratene lagres. Injiserbar så selfcheck ikke rører brukerens tall.
    var estimateStore: UserDefaults = .standard

    /// Én linje fra strømmen. `thinking` leses ikke: det er ikke referat.
    struct Chunk: Equatable {
        let content: String
        let done: Bool
        let promptEvalCount: Int?
        /// Fra sluttobjektet, i sekunder (ollama teller nanosekunder). Det er
        /// disse som blir anslaget neste gang samme modell brukes.
        let loadSeconds: Double?
        let promptEvalSeconds: Double?
        /// ollama sender feilen som egen NDJSON-linje midt i en 200-strøm når
        /// runneren dør. Leses her, ikke bare i 404-grenen.
        let error: String?
    }
    private struct Line: Decodable {
        struct Message: Decodable { var content: String? }
        var message: Message?
        var done: Bool?
        var prompt_eval_count: Int?
        var load_duration: Int64?
        var prompt_eval_duration: Int64?
        var error: String?
    }

    static func parse(_ line: String) -> Chunk? {
        guard let data = line.data(using: .utf8),
              let l = try? JSONDecoder().decode(Line.self, from: data) else { return nil }
        return Chunk(content: l.message?.content ?? "", done: l.done ?? false,
                     promptEvalCount: l.prompt_eval_count,
                     loadSeconds: l.load_duration.map { Double($0) / 1e9 },
                     promptEvalSeconds: l.prompt_eval_duration.map { Double($0) / 1e9 },
                     error: l.error)
    }

    private let session: URLSession
    private let timeout: TimeInterval
    private var task: Task<Void, Never>?

    /// `timeoutIntervalForRequest` er stillhet *mellom* to datapakker, ikke
    /// total tid. Et to timers møte får ta tiden det tar; en modell i
    /// tenkesløyfe (gemma4:12b, målt > 900 s i #32) stoppes etter 600 s uten
    /// et eneste token. think:false dekker allerede tenkesløyfe-tilfellet, og
    /// «Stopp» finnes for den som ikke vil vente. Målt 2026-09-04: en kald
    /// 27B-modell (qwen3.8:27b-mlx) med en 18k-tokens prompt sender ingen
    /// pakker i 117 s under prefill — 120 s feilet på nøyaktig dette.
    /// Injiserbar så selfcheck kan se den utløse på 1 s.
    init(timeout: TimeInterval = 600) {
        self.timeout = timeout
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = .infinity
        session = URLSession(configuration: cfg)
    }

    deinit { session.finishTasksAndInvalidate() }

    func run(prompt: String, model: String, baseURL: URL, writeTo: [URL]) {
        cancel()
        text = ""
        state = .running
        started = Date()
        promptWords = prompt.split(whereSeparator: \.isWhitespace).count
        phase = .waiting(estimate: Estimates.summaryEstimate(model: model, promptChars: prompt.utf8.count,
                                                             in: estimateStore))
        task = Task { [weak self] in
            guard let self else { return }
            // Ikke etter cancel(): run() har alt satt fasen for neste kjøring,
            // og den gamle Task-ens avslutning skal ikke viske den ut.
            defer { if !Task.isCancelled { self.phase = .idle } }
            do {
                try await self.stream(prompt: prompt, model: model, baseURL: baseURL)
                guard !Task.isCancelled else { return }
                guard !self.text.isEmpty else {
                    self.state = .failed("Modellen svarte tomt. Den brukte trolig hele "
                        + "budsjettet på tenking; prøv en annen modell.")
                    return
                }
                try self.write(to: writeTo)
                self.state = .done(writeTo[0])
            } catch is CancellationError {
                return
            } catch let e as URLError where e.code == .cancelled {
                return
            } catch let e as URLError where e.code == .cannotConnectToHost {
                self.state = .failed("ollama svarer ikke på \(baseURL.absoluteString) — kjør `ollama serve`.")
            } catch let e as URLError where e.code == .timedOut {
                self.state = .failed("Ingen svar på \(Int(self.timeout)) s — modellen henger, "
                    + "eller maskinen er full. Kjøringen er stoppet.")
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if state == .running { state = .idle }
        phase = .idle
    }

    private struct HTTPError: Error, LocalizedError {
        let status: Int, body: String
        var errorDescription: String? { "ollama svarte \(status): \(body)" }
    }

    private func stream(prompt: String, model: String, baseURL: URL) async throws {
        var req = URLRequest(url: baseURL.appending(path: "api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // think: false alltid. Målt 2026-09-04 (ollama 0.33.3): en modell uten
        // thinking-kapabilitet svarer 200 på feltet, så ingen retry-gren.
        // Med think på gikk hele budsjettet til tenking og svaret kom tomt (#30).
        let body: [String: Any] = [
            "model": model, "stream": true, "think": false,
            "messages": [["role": "user", "content": prompt]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var err = ""
            for try await line in bytes.lines { err += line }
            let msg = (try? JSONDecoder().decode(Line.self, from: Data(err.utf8)))?.error ?? err
            if status == 404 || msg.contains("not found") {
                throw NotFoundError(model: model)
            }
            throw HTTPError(status: status, body: msg)
        }
        // Strupt publisering: målt 2026-09-04 på en 8.8k-ords transkripsjon —
        // ollama strømmet ferdig på ~6 min, appen brukte så ~7 min til på
        // 100 % CPU i SwiftUI-layout som tygget bufrede tokens (ett re-render
        // per linje, se `SpeakerEditorView.hasSummary`). `pending` samles opp
        // og flushes til `text` maks ti ganger i sekundet.
        var pending = ""
        var lastFlush = Date.distantPast
        // Etter cancel() har run() alt nullstilt `text` for neste kjøring;
        // den gamle Task-ens rest skal ikke inn foran den nye.
        defer { if !pending.isEmpty, !Task.isCancelled { text += pending } }
        for try await line in bytes.lines {
            guard let chunk = Self.parse(line) else { continue }
            if let err = chunk.error { throw StreamError(reason: "ollama avbrøt: \(err)") }
            if !chunk.content.isEmpty, phase != .streaming { phase = .streaming }
            pending += chunk.content
            let now = Date()
            if chunk.done || now.timeIntervalSince(lastFlush) >= 0.1 {
                text += pending
                pending = ""
                lastFlush = now
            }
            if chunk.done {
                if let n = chunk.promptEvalCount { NSLog("Schous referat: prompt_eval_count=%d", n) }
                if let load = chunk.loadSeconds, let eval = chunk.promptEvalSeconds {
                    Estimates.recordSummary(model: model, loadSeconds: load, promptSeconds: eval,
                                            promptChars: prompt.utf8.count, in: estimateStore)
                }
                return
            }
        }
        // EOF uten done: runneren døde eller forbindelsen falt. Var det ikke
        // en feil, ville et halvt referat blitt lagret som «Referat lagret».
        throw StreamError(reason: "strømmen ble brutt før modellen var ferdig")
    }

    private struct StreamError: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { "Referatet er ufullstendig — \(reason). Ingen fil er skrevet." }
    }

    private func write(to urls: [URL]) throws {
        for url in urls {
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch {
                throw WriteError(url: url, underlying: error)
            }
        }
    }
    private struct WriteError: Error, LocalizedError {
        let url: URL, underlying: Error
        var errorDescription: String? {
            "Klarte ikke å skrive \(url.lastPathComponent): \(underlying.localizedDescription). "
            + "Filene kan være delvis oppdatert."
        }
    }
    private struct NotFoundError: Error, LocalizedError {
        let model: String
        var errorDescription: String? { "Modellen \(model) finnes ikke — `ollama pull \(model)`." }
    }
}

enum Ollama {
    private struct Tags: Decodable { struct M: Decodable { let name: String }; let models: [M] }

    /// Modellene ollama har. nil = svarer ikke (5 s frist). Kort frist: dette
    /// kjøres når Innstillinger og editoren åpnes, ikke i bakgrunnen.
    static func models(baseURL: URL) async -> [String]? {
        var req = URLRequest(url: baseURL.appending(path: "api/tags"))
        req.timeoutInterval = 5
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let tags = try? JSONDecoder().decode(Tags.self, from: data) else { return nil }
        return tags.models.map(\.name).sorted()
    }
}
