import Foundation
import CryptoKit

enum JobState: Equatable {
    case idle, running, paused, done
    case stopped(Int)       // brukeren trykket Stopp; N segmenter er skrevet og kan gjenopptas
    case failed(String)
}

@MainActor
final class TranscriptionJob: ObservableObject {
    @Published var state: JobState = .idle
    @Published var step = 0                 // 1-4, 0 = ikke startet
    @Published var stepLabel = ""
    @Published var detail = ""              // fri statustekst under progressbaren
    @Published var done = 0                 // ferdige segmenter (steg 4)
    @Published var total = 0
    @Published var eta = ""
    @Published var speakerCount = 0
    @Published var segments: [Segment] = []
    @Published var log: [String] = []

    private var process: Process?
    private var step4Start: Date?
    private(set) var jobDir: URL?
    private(set) var base = ""

    static let stepNames = ["", "Lyd", "Diarization", "Språk per taler", "Transkriberer"]

    /// Steg 2 rapporterer nå fremdrift per understeg, ikke bare steg 4.
    /// Baren fylles og nullstilles per understeg i steg 2; det er med vilje.
    /// Klemmes fordi pyannote teller forbi taket på siste chunk — målt
    /// `completed: 64` av `total: 36` i segmentation.
    var fraction: Double? {
        guard step == 2 || step == 4, total > 0 else { return nil }
        return min(1, Double(done) / Double(total))
    }

    // MARK: - Start

    func start(input: URL, speakers: Int?) {
        let settings = AppSettings.shared
        guard let backend = settings.backendURL, let python = settings.pythonURL,
              FileManager.default.isExecutableFile(atPath: python.path) else {
            state = .failed("Backend er ikke satt opp. Åpne Innstillinger og velg mappen.")
            return
        }

        base = input.deletingPathExtension().lastPathComponent
        let dir = Self.jobDirectory(for: input)
        jobDir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        segments = []
        log = []
        done = 0; total = 0; eta = ""; detail = ""; speakerCount = 0
        step = 1
        stepLabel = Self.stepNames[1]
        state = .running

        let p = Process()
        p.executableURL = python
        // -u: uten den blir stdout blokk-bufret ved pipe og stegmarkørene kommer i én klump.
        p.arguments = ["-u", backend.appending(path: "transcribe.py").path, input.path,
                       "--progress", "json"]
        if let n = speakers { p.arguments! += ["--speakers", String(n)] }
        p.currentDirectoryURL = dir

        // Setter PATH (Finder gir ikke Homebrew, og transcribe.py kaller ffmpeg
        // direkte) og fjerner et arvet HF_TOKEN, så jobben ser samme token som sjekken.
        var env = AppSettings.subprocessEnv
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        attach(out) { [weak self] in self?.parseStdout($0) }
        attach(err) { [weak self] in self?.parseStderr($0) }

        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.finish(proc) }
        }

        do {
            try p.run()
            process = p
        } catch {
            state = .failed("Kunne ikke starte python: \(error.localizedDescription)")
        }
    }

    // MARK: - Kontroll

    func pause() {
        guard case .running = state, let pid = process?.processIdentifier else { return }
        kill(pid, SIGSTOP)
        state = .paused
    }

    func resume() {
        guard case .paused = state, let pid = process?.processIdentifier else { return }
        kill(pid, SIGCONT)
        state = .running
    }

    func stop() {
        guard let p = process else { return }
        if case .paused = state { kill(p.processIdentifier, SIGCONT) }  // ellers dør SIGTERM aldri
        p.terminate()
    }

    // MARK: - Output-lesing

    /// readabilityHandler kalles serielt per file handle, så en enkel boks holder.
    private final class LineBuffer: @unchecked Sendable { var text = "" }

    private func attach(_ pipe: Pipe, _ handler: @escaping @MainActor (String) -> Void) {
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            buffer.text += String(decoding: data, as: UTF8.self)
            // tqdm bruker \r, print bruker \n — begge er linjeskiller for oss.
            var lines = buffer.text.components(separatedBy: CharacterSet(charactersIn: "\n\r"))
            buffer.text = lines.removeLast()
            let complete = lines
            Task { @MainActor in complete.forEach(handler) }
        }
    }

    private func note(_ line: String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        log.append(t)
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    /// Én linje fra `--progress json`. Ukjente nøkler ignoreres av Decodable,
    /// så backend kan legge til felt uten å knekke dette.
    struct Event: Decodable {
        let event: String
        var step: Int?
        var name: String?
        var sub: String?
        var completed: Int?
        var total: Int?
        var speaker: String?
        var language: String?
        var segments: Int?
        var speakers: Int?
    }

    func parseStdout(_ line: String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        guard t.hasPrefix("{"), let data = t.data(using: .utf8),
              let e = try? JSONDecoder().decode(Event.self, from: data) else {
            // Ikke-JSON på stdout i json-modus betyr at noe gikk galt — behold det.
            note(t)
            return
        }
        apply(e)
    }

    func apply(_ e: Event) {
        switch e.event {
        case "step":
            step = e.step ?? step
            stepLabel = Self.stepNames[(1...4).contains(step) ? step : 0]
            detail = ""
            done = 0
            if step == 4 { step4Start = Date() }
        case "progress":
            done = e.completed ?? done
            total = e.total ?? total
            if let sub = e.sub {
                detail = sub
            } else if let s = e.speaker, let l = e.language {
                detail = "\(s) (\(l))"
            }
            if step == 4 { eta = estimate() }
        case "diarized":
            total = e.segments ?? 0
            speakerCount = e.speakers ?? 0
            detail = "\(total) segmenter, \(speakerCount) talere"
        case "language":
            detail = "taler \(e.completed ?? 0)/\(e.total ?? 0) — "
                + "\(e.speaker ?? "?"): \(e.language ?? "?")"
        case "resume":
            detail = "gjenopptar \(e.completed ?? 0) ferdige segmenter"
        case "done", "interrupted":
            detail = ""
            eta = ""
        default:
            break
        }
    }

    /// ponytail: enkelt snitt siden steg 4 startet. Ved gjenopptagelse flyr de
    /// allerede ferdige segmentene forbi på null tid, så anslaget er for
    /// optimistisk de første sekundene og retter seg selv etter hvert.
    private func estimate() -> String {
        guard let t0 = step4Start, done > 0, total > done else { return "" }
        let left = Date().timeIntervalSince(t0) / Double(done) * Double(total - done)
        let m = Int(left) / 60, s = Int(left) % 60
        return m > 0 ? "\(m)m\(String(format: "%02d", s))s" : "\(s)s"
    }

    func parseStderr(_ line: String) {
        // sys.exit(melding) i backend skriver hit, ikke til stdout.
        // Delstreng, ikke likhet: backendens linje ender på punktum, og punktumet
        // er dens å endre. Rådslinja under kommer uansett som sin egen linje —
        // attach() splitter på \n og \r — så den kan ikke havne her.
        //
        // Appen må formulere rådet selv, og må nevne strippingen: backendens
        // egen andre linje tilbyr «eller export HF_TOKEN=hf_...», og det er
        // nøyaktig det subprocessEnv fjerner. Uten den setningen ser brukeren
        // et satt HF_TOKEN i skallet, en backend som virker for hånd, og en app
        // som sier at tokenet mangler — uten noen vei fra motsigelsen til svaret.
        if line.contains("Fant ikke noe Hugging Face-token") {
            state = .failed("Fant ikke noe Hugging Face-token. Appen ignorerer "
                            + "HF_TOKEN i miljøet med vilje — kjør "
                            + "`.venv/bin/hf auth login` i backend-mappen.")
        }
        note(line)
    }

    // MARK: - Avslutning

    private func finish(_ p: Process) {
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (p.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil

        if case .failed = state { return }

        // 130/143 = backend fanget SIGINT/SIGTERM, skrev det som var ferdig, og
        // la partial-fila igjen. Ikke en feil, og ikke et tap.
        let interrupted = p.terminationReason == .exit && [130, 143].contains(p.terminationStatus)

        guard p.terminationReason == .exit, p.terminationStatus == 0 || interrupted else {
            if p.terminationReason == .uncaughtSignal {
                state = .failed("Prosessen ble drept. Steg 1–3 er cachet og hoppes over ved ny start.")
            } else {
                state = .failed(lastMeaningfulError() ?? "Python avsluttet med kode \(p.terminationStatus).")
            }
            return
        }

        guard let dir = jobDir else { state = .failed("Mangler jobbmappe."); return }
        let json = dir.appending(path: "output/\(base).json")
        do {
            segments = try JSONDecoder().decode([Segment].self, from: Data(contentsOf: json))
            state = interrupted ? .stopped(segments.count) : .done
            step = 4
            detail = "\(segments.count) segmenter"
        } catch {
            state = .failed("Kjøringen \(interrupted ? "ble avbrutt" : "fullførte"), men \(json.lastPathComponent) kunne ikke leses: \(error.localizedDescription)")
        }
    }

    private func lastMeaningfulError() -> String? {
        // Python-traceback: siste linje er som regel den informative.
        log.last(where: { $0.contains("Error") || $0.contains("error") || $0.contains("Traceback") })
            ?? log.last
    }

    // MARK: - Jobbmappe

    /// Stabil per inputfil, så work/-cachen overlever selv om brukeren bytter output-mappe.
    static func jobDirectory(for input: URL) -> URL {
        let digest = SHA256.hash(data: Data(input.path.utf8))
        let hash = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return URL.applicationSupportDirectory
            .appending(path: "Schous/jobs/\(hash)")
    }
}

// Liten regex-hjelper: returnerer capture groups som [String] (index 0 = hele treffet).
extension String {
    func firstMatch(_ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self))
        else { return nil }
        return (0..<m.numberOfRanges).map { i in
            guard let r = Range(m.range(at: i), in: self) else { return "" }
            return String(self[r])
        }
    }
}
