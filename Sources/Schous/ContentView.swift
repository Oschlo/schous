import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Velger mellom de fire tilstandene vinduet kan stå i — tom, fil valgt,
/// jobb i gang, ferdig — og eier det som er felles for dem: fila, slipp,
/// Fil-menyen og Dock-spretten. Selve visningene ligger i SetupViews.swift
/// og SpeakerEditorView.swift.
struct ContentView: View {
    @StateObject private var job = TranscriptionJob()
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var recorder = Recorder.shared

    // --input <sti>: forhåndsvelger fil ved oppstart (Finder «Åpne med», og gjør appen testbar).
    @State private var input: URL? = CommandLine.arguments.firstIndex(of: "--input")
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
        .map { URL(fileURLWithPath: $0) }
    /// Lydlengden i sekunder, til visning og til estimatene. nil til den er lest.
    @State private var duration: Double?
    /// 0 = automatisk.
    @State private var speakers = 0
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 0) {
            if job.state == .done {
                SpeakerEditorView(job: job, outputDir: URL(fileURLWithPath: settings.outputPath), onNewJob: leaveEditor)
            } else {
                warnings
                if let input, isBusy {
                    JobProgressView(job: job, input: input, duration: duration)
                } else if let input {
                    WorkflowStepper(current: .file)
                        .padding(.horizontal, 24).padding(.top, 16)
                    JobSetupView(job: job, input: input, duration: duration, dropping: dropping,
                                 speakers: $speakers, pickInput: pickInput, pickOutput: pickOutput,
                                 start: start, openResult: { job.loadFinished(input: input) })
                } else {
                    EmptyStateView(dropping: dropping, pickFile: pickInput)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        .animation(.default, value: job.state)
        .animation(.default, value: input)
        // Hele vinduet tar imot slipp; den stiplede boksen er bare hintet.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !isBusy else { return false }
            open(url)
            return true
        } isTargeted: { dropping = $0 && !isBusy }
        .task(id: input) {
            duration = nil
            guard let input else { return }
            duration = try? await AVURLAsset(url: input).load(.duration).seconds
        }
        // Et ferdig menylinje-opptak forhåndsvelges, klart til å transkriberes.
        .onReceive(Recorder.shared.$lastRecording.compactMap { $0 }) { input = $0 }
        // Finder «Åpne med» og fil sluppet på Dock-ikonet (CFBundleDocumentTypes).
        .onOpenURL { if !isBusy { open($0) } }
        .onReceive(NotificationCenter.default.publisher(for: .openFile)) { _ in
            if !isBusy { pickInput() }
        }
        // Dock-ikonet spretter når jobben er ferdig og appen ikke er fremst;
        // er den fremst, ignorerer macOS forespørselen selv. VoiceOver får
        // beskjed uansett — en fargeendring og et sprett er ikke en melding.
        .onChange(of: job.state) { _, new in
            switch new {
            case .done:
                NSApplication.shared.requestUserAttention(.informationalRequest)
                announce("Transkripsjonen er ferdig")
            case .stopped(let n):
                NSApplication.shared.requestUserAttention(.informationalRequest)
                announce("Stoppet. \(n) segmenter er skrevet")
            case .failed:
                NSApplication.shared.requestUserAttention(.informationalRequest)
                announce("Transkripsjonen feilet")
            case .paused:
                announce("Pauset")
            default: break
            }
        }
    }

    /// Menylinjemenyen lukkes av selve stopp-klikket, og miksingen blir ferdig
    /// først etterpå — sto feilen bare der, ville ingen sett den. Varselet
    /// under opptak vises begge steder: menyen er der man ser det raskest,
    /// vinduet er der det fortsatt står hvis menyen var lukket.
    @ViewBuilder private var warnings: some View {
        let lines = [recorder.liveWarning, recorder.errorMessage].compactMap { $0 }
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines, id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.top, 16)
        }
    }

    private var isBusy: Bool { job.state == .running || job.state == .paused }

    // MARK: - Handlinger

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    private func leaveEditor() {
        job.state = .idle
        job.step = 0
    }

    private func start() {
        guard let input else { return }
        job.start(input: input, speakers: speakers == 0 ? nil : speakers, audioSeconds: duration ?? 0)
    }

    private func pickInput() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie]
        panel.prompt = "Velg"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    /// Ny fil valgt med vilje: body velges på job.state, ikke på input, så
    /// editoren må forlates eksplisitt. Et ferdig opptak (`lastRecording`) går
    /// ikke hit — det bare forhåndsvelges, ellers rev opptaksstoppet ned
    /// editoren midt i talernavn som ikke var lagret, og avbrøt et referat.
    private func open(_ url: URL) {
        input = url
        if job.state == .done { leaveEditor() }
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
            settings.outputPath = ((exists && isDir.boolValue) ? url : url.deletingLastPathComponent()).path
        }
    }
}
