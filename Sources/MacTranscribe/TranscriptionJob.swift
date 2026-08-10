import Foundation
import CryptoKit

enum JobState: Equatable {
    case idle, running, paused, done
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
    private(set) var jobDir: URL?
    private(set) var base = ""

    static let stepNames = ["", "Lyd", "Diarization", "Språk per taler", "Transkriberer"]

    var fraction: Double? {
        guard step == 4, total > 0 else { return nil }
        return Double(done) / Double(total)
    }

    /// Segmentene som faktisk går tapt hvis vi dreper prosessen nå (backend har ingen checkpointing).
    var segmentsAtRisk: Int { step == 4 ? done : 0 }

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
        p.arguments = ["-u", backend.appending(path: "transcribe.py").path, input.path]
        if let n = speakers { p.arguments! += ["--speakers", String(n)] }
        p.currentDirectoryURL = dir

        var env = ProcessInfo.processInfo.environment
        // En .app startet fra Finder arver ikke Homebrew-PATH, og transcribe.py:31 kaller ffmpeg direkte.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PYTHONUNBUFFERED"] = "1"
        if !settings.hfToken.isEmpty { env["HF_TOKEN"] = settings.hfToken }
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

    func parseStdout(_ line: String) {
        note(line)
        let t = line.trimmingCharacters(in: .whitespaces)

        // "1/4 lyd…" … "4/4 transkriberer…"
        if t.count > 3, t.dropFirst(1).hasPrefix("/4 "), let n = Int(t.prefix(1)), (1...4).contains(n) {
            step = n
            stepLabel = Self.stepNames[n]
            detail = ""
            return
        }
        // "  509 segmenter, 3 talere"
        if let m = t.firstMatch(#"^(\d+) segmenter, (\d+) talere$"#) {
            total = Int(m[1]) ?? 0
            speakerCount = Int(m[2]) ?? 0
            detail = "\(total) segmenter, \(speakerCount) talere"
            return
        }
        // "  taler 1/3 SPEAKER_00: sv  ("...")"
        if let m = t.firstMatch(#"^taler (\d+)/(\d+) (\S+): (\S+)"#) {
            detail = "taler \(m[1])/\(m[2]) — \(m[3]): \(m[4])"
            return
        }
        if t.hasPrefix("Ferdig:") { detail = "" ; return }
        if t.hasPrefix("HF_TOKEN ikke satt") {
            state = .failed("HF_TOKEN mangler. Legg den inn i Innstillinger.")
            return
        }
        // Steg 2 er pyannotes rich-bar på stdout — vis rå, ikke parse.
        if step == 2, !t.isEmpty, !t.hasPrefix("2/4") { detail = t }
    }

    func parseStderr(_ line: String) {
        // "  transkriberer:  42%|████▏ | 214/509 [08:31<11:44,  2.39s/seg, SPEAKER_00 no]"
        // Desc-en må matches: huggingface skriver sin egen tqdm-bar hit
        // ("Fetching 4 files: 100%|██| 4/4 [...]"), som ellers leses som falsk fremdrift.
        if line.contains("transkriberer:"), let m = line.firstMatch(#"(\d+)/(\d+) \[[\d:]+<([\d:?]+)"#) {
            done = Int(m[1]) ?? done
            total = Int(m[2]) ?? total
            eta = m[3]
            if let s = line.firstMatch(#"(SPEAKER_\d+) (\w+)\]"#) {
                detail = "\(s[1]) (\(s[2]))"
            }
            return
        }
        note(line)
    }

    // MARK: - Avslutning

    private func finish(_ p: Process) {
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (p.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil

        if case .failed = state { return }

        guard p.terminationReason == .exit, p.terminationStatus == 0 else {
            if p.terminationReason == .uncaughtSignal {
                state = .failed("Avbrutt. Steg 1–3 er cachet og hoppes over ved ny start.")
            } else {
                state = .failed(lastMeaningfulError() ?? "Python avsluttet med kode \(p.terminationStatus).")
            }
            return
        }

        guard let dir = jobDir else { state = .failed("Mangler jobbmappe."); return }
        let json = dir.appending(path: "output/\(base).json")
        do {
            segments = try JSONDecoder().decode([Segment].self, from: Data(contentsOf: json))
            state = .done
            step = 4
            detail = "\(segments.count) segmenter"
        } catch {
            state = .failed("Kjøringen fullførte, men \(json.lastPathComponent) kunne ikke leses: \(error.localizedDescription)")
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
            .appending(path: "MacTranscribe/jobs/\(hash)")
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
