import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var job = TranscriptionJob()
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var recorder = Recorder.shared

    // --input <sti>: forhåndsvelger fil ved oppstart (Finder «Åpne med», og gjør appen testbar).
    @State private var input: URL? = CommandLine.arguments.firstIndex(of: "--input")
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
        .map { URL(fileURLWithPath: $0) }
    @State private var outputPath = UserDefaults.standard.string(forKey: "outputPath")
        ?? URL.downloadsDirectory.path
    @State private var speakers = ""
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 0) {
            if job.state == .done {
                SpeakerEditorView(job: job, outputDir: URL(fileURLWithPath: outputPath)) {
                    job.state = .idle
                    job.step = 0
                }
            } else {
                setup
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        // Et ferdig menylinje-opptak forhåndsvelges, klart til å transkriberes.
        .onReceive(Recorder.shared.$lastRecording.compactMap { $0 }) { input = $0 }
    }

    // MARK: - Oppsett + kjøring

    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            dropZone

            // Menylinjemenyen lukkes av selve stopp-klikket, og miksingen blir
            // ferdig først etterpå — sto feilen bare der, ville ingen sett den.
            // Varselet under opptak vises begge steder: menyen er der man ser
            // det raskest, vinduet er der det fortsatt står hvis menyen var lukket.
            if let warning = recorder.liveWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = recorder.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Lagre i").frame(width: 70, alignment: .leading)
                Text(URL(fileURLWithPath: outputPath).lastPathComponent)
                    .lineLimit(1).truncationMode(.head)
                    .foregroundStyle(.secondary)
                Button("Velg…", action: pickOutput)
                Spacer()
                Text("Talere").foregroundStyle(.secondary)
                TextField("auto", text: $speakers)
                    .frame(width: 52).textFieldStyle(.roundedBorder)
                    .help("Antall talere hvis kjent. Tomt = automatisk.")
            }
            .disabled(isBusy)

            progress
            Spacer(minLength: 0)
            controls
        }
        .padding(20)
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
            .foregroundStyle(dropping ? Color.accentColor : Color.secondary.opacity(0.4))
            .background(dropping ? Color.accentColor.opacity(0.07) : .clear)
            .frame(height: 110)
            .overlay {
                VStack(spacing: 6) {
                    if let input {
                        Text(input.lastPathComponent).font(.headline).lineLimit(1)
                        Text(input.deletingLastPathComponent().path)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    } else {
                        Image(systemName: "waveform").font(.title).foregroundStyle(.secondary)
                        Text("Dra en lyd- eller videofil hit").foregroundStyle(.secondary)
                    }
                    Button(input == nil ? "Velg fil…" : "Bytt fil…", action: pickInput)
                        .buttonStyle(.link)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, !isBusy else { return false }
                input = url
                return true
            } isTargeted: { dropping = $0 && !isBusy }
    }

    @ViewBuilder private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch job.state {
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            case .stopped(let n):
                Label("Stoppet. \(n) segmenter er skrevet — «Start transkribering» "
                      + "fortsetter der den slapp.", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            case .running, .paused:
                HStack {
                    Text("\(job.step)/4 \(job.stepLabel)").font(.callout.weight(.medium))
                    if job.state == .paused {
                        Text("— pauset").foregroundStyle(.orange).font(.callout)
                    }
                    Spacer()
                    if job.step == 4, job.total > 0 {
                        Text("\(job.done)/\(job.total)\(job.eta.isEmpty ? "" : " · \(job.eta) igjen")")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if let f = job.fraction {
                    ProgressView(value: f)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(job.detail.isEmpty ? " " : job.detail)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            default:
                if let input, TranscriptionJob.finishedOutput(for: input) != nil {
                    Label("Denne fila er transkribert tidligere.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary).font(.callout)
                }
                if !settings.isConfigured {
                    Label("Backend er ikke satt opp — åpne Innstillinger (⌘,)",
                          systemImage: "gearshape")
                        .foregroundStyle(.orange).font(.callout)
                }
            }
        }
        .frame(height: 64, alignment: .top)
    }

    private var controls: some View {
        HStack {
            if case .running = job.state {
                Button("Pause", systemImage: "pause.fill") { job.pause() }
            } else if case .paused = job.state {
                Button("Fortsett", systemImage: "play.fill") { job.resume() }
            }
            Spacer()
            if isBusy {
                // Ingen bekreftelsesdialog: backend skriver hvert ferdige segment
                // til disk og gjenopptar der den slapp, så Stopp koster ingenting.
                Button("Stopp") { job.stop() }
                    .help("Skriver det som er ferdig. En ny start fortsetter der den slapp.")
            } else {
                if let input, TranscriptionJob.finishedOutput(for: input) != nil {
                    Button("Åpne resultat") { job.loadFinished(input: input) }
                }
                Button("Start transkribering") { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(input == nil || !settings.isConfigured)
            }
        }
    }

    private var isBusy: Bool { job.state == .running || job.state == .paused }

    // MARK: - Handlinger

    private func start() {
        guard let input else { return }
        job.start(input: input, speakers: Int(speakers.trimmingCharacters(in: .whitespaces)))
    }

    private func pickInput() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie]
        panel.prompt = "Velg"
        if panel.runModal() == .OK { input = panel.url }
    }

    private func pickOutput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Velg"
        if panel.runModal() == .OK, let url = panel.url {
            // ⌘⇧G kan returnere en fil selv med canChooseFiles = false — bruk mappen den ligger i.
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let dir = (exists && isDir.boolValue) ? url : url.deletingLastPathComponent()
            outputPath = dir.path
            UserDefaults.standard.set(dir.path, forKey: "outputPath")
        }
    }
}
