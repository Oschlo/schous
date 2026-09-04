import SwiftUI

/// De fire trinnene i oppgaven, slik brukeren ser dem. Ikke en wizard: linja
/// viser hvor du er, og ferdige trinn kan trykkes for å gå tilbake.
enum WorkflowStep: Int, CaseIterable, Identifiable {
    case file = 1, transcription, speakers, summary
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .file: "Fil"
        case .transcription: "Transkribering"
        case .speakers: "Talere"
        case .summary: "Referat og eksport"
        }
    }
}

struct WorkflowStepper: View {
    let current: WorkflowStep
    var completed: Set<WorkflowStep> = []
    var onSelect: ((WorkflowStep) -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            ForEach(WorkflowStep.allCases) { step in
                if step != .file {
                    Rectangle().fill(.quaternary).frame(width: 24, height: 1)
                }
                item(step)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Arbeidsflyt")
    }

    private func item(_ step: WorkflowStep) -> some View {
        let done = completed.contains(step)
        let active = step == current
        let clickable = onSelect != nil && (done || active)
        let status = active ? "aktivt" : done ? "ferdig" : "gjenstår"
        return Button { onSelect?(step) } label: {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(active ? Color.accentColor : done ? Color.accentColor.opacity(0.18) : Color.clear)
                        .overlay(Circle().strokeBorder(.tertiary, lineWidth: active || done ? 0 : 1))
                        .frame(width: 20, height: 20)
                    if done && !active {
                        Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(Color.accentColor)
                    } else {
                        Text("\(step.rawValue)").font(.caption.bold())
                            .foregroundStyle(active ? Color.white : Color.secondary)
                    }
                }
                Text(step.title)
                    .fontWeight(active ? .semibold : .regular)
                    .foregroundStyle(active ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .allowsHitTesting(clickable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Steg \(step.rawValue) av 4, \(step.title), \(status)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Slippsonen. Hele vinduet tar imot slipp (ContentView); boksen er hintet.
private struct DropZone<Content: View>: View {
    let dropping: Bool
    var minHeight: CGFloat = 140
    @ViewBuilder let content: Content

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
            .foregroundStyle(dropping ? Color.accentColor : Color.secondary.opacity(0.4))
            .background(dropping ? Color.accentColor.opacity(0.07) : .clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .frame(minHeight: minHeight)
            .animation(.easeOut(duration: 0.15), value: dropping)
            .overlay { content.padding(16) }
    }
}

/// Uten fil: si hva Schous gjør, ta imot en fil, og vis om oppsettet er klart.
struct EmptyStateView: View {
    let dropping: Bool
    let pickFile: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var recorder = Recorder.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 44)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Transkriber lyd og møter lokalt").font(.title2.weight(.semibold))
            Text("Dra inn en lyd- eller videofil, eller ta opp fra menylinja. "
                 + "Talerne skilles fra hverandre, og du kan lage referat etterpå.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            DropZone(dropping: dropping) {
                VStack(spacing: 10) {
                    Text("Dra en fil hit").foregroundStyle(.secondary)
                    Button("Velg fil…", action: pickFile).buttonStyle(.bordered)
                }
            }
            .padding(.top, 8)

            if !recorder.isRecording {
                Button("Start opptak", systemImage: "record.circle") { recorder.start() }
                    .buttonStyle(.borderless)
                    .help("Tar opp systemlyd og mikrofon fra menylinja. ⌃⌥R fra hvilken som helst app.")
            }

            Divider().frame(maxWidth: 360).padding(.top, 8)
            setupStatus
            Text("Lyd og transkripsjon behandles lokalt på denne Macen.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 460)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Førstegangssjekken. Én tydelig vei til oppsettet når backend mangler;
    /// modellene sies fra om fordi første jobb ellers ser ut som den henger
    /// mens den laster ned 3 GB (README).
    private var setupStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if settings.isConfigured {
                Label("Backend klar", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else {
                SettingsLink {
                    Label("Fullfør oppsett — velg backend-mappen", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
            }
            if AppSettings.modelsCached {
                Label("Modeller klare", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else {
                Label("Modeller lastes ned ved første kjøring (~3 GB)", systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

/// Fil valgt, ikke startet: fila, hvor resultatet skal, antall talere, og
/// handlingen. Finnes et ferdig resultat, er «Åpne resultat» det blå valget.
struct JobSetupView: View {
    @ObservedObject var job: TranscriptionJob
    let input: URL
    let duration: Double?
    let dropping: Bool
    @Binding var speakers: Int
    let pickInput: () -> Void
    let pickOutput: () -> Void
    let start: () -> Void
    let openResult: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    @State private var info: TranscriptionJob.FinishedInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            DropZone(dropping: dropping, minHeight: 88) {
                HStack(spacing: 12) {
                    FileHeader(input: input, duration: duration)
                    Spacer()
                    Button("Bytt fil…", action: pickInput).buttonStyle(.borderless)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Lagre i") {
                    HStack(spacing: 8) {
                        Text(outputDir.lastPathComponent)
                            .lineLimit(1).truncationMode(.head)
                            .help(outputDir.path)
                        Button("Velg…", action: pickOutput)
                        Button("Vis i Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([outputDir])
                        }
                        .buttonStyle(.borderless)
                    }
                }
                LabeledContent("Antall talere") {
                    Picker("Antall talere", selection: $speakers) {
                        Text("Automatisk").tag(0)
                        ForEach(1...12, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .help("Oppgi antallet hvis du vet det. Automatisk lar backend anslå.")
                }
            }

            messages

            HStack {
                Spacer()
                if info != nil {
                    Button("Transkriber på nytt…", action: start)
                        .disabled(!settings.isConfigured)
                        .help("Lyd, talere og språk er cachet; bare transkriberingen kjøres på nytt. "
                              + "Navn og referat må lages på nytt.")
                    Button("Åpne resultat", action: openResult)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Start transkribering", action: start)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!settings.isConfigured)
                }
            }
        }
        .frame(maxWidth: 520)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: input) { info = TranscriptionJob.finishedInfo(for: input) }
        // Etter «Stopp» ligger partial-fila der, og da er resultatet ikke ferdig.
        .onChange(of: job.state) { _, _ in info = TranscriptionJob.finishedInfo(for: input) }
    }

    private var outputDir: URL { URL(fileURLWithPath: settings.outputPath) }

    @ViewBuilder private var messages: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let info {
                Label("Ferdig · \(info.segments) segmenter · sist endret "
                      + info.modified.formatted(.relative(presentation: .named)),
                      systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            switch job.state {
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            case .stopped(let n):
                Label("Stoppet. \(n) segmenter er skrevet — «Start transkribering» fortsetter der den slapp.",
                      systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
            default:
                EmptyView()
            }
            if !settings.isConfigured {
                // En lenke, ikke en beskjed om å trykke ⌘, — knappen er slått
                // av, så dette er den eneste veien videre herfra.
                SettingsLink {
                    Label("Backend er ikke satt opp — åpne Innstillinger", systemImage: "gearshape")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.link)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Filnavn med varighet og mappe. Deles mellom oppsett og fremdrift.
private struct FileHeader: View {
    let input: URL
    let duration: Double?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.title).foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(input.lastPathComponent).font(.headline).lineLimit(1)
                Text(meta).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
        }
    }

    private var meta: String {
        let folder = input.deletingLastPathComponent().path
        guard let duration, duration > 0 else { return folder }
        let pattern: Duration.TimeFormatStyle.Pattern = duration >= 3600 ? .hourMinuteSecond : .minuteSecond
        return "\(Duration.seconds(duration).formatted(.time(pattern: pattern))) · \(folder)"
    }
}

/// Jobben som kjører, som hovedinnhold: fire trinn, ett nå-signal, fremdrift,
/// og Pause/Stopp rett under. Detaljer (backendens ord og loggen) kan foldes ut.
struct JobProgressView: View {
    @ObservedObject var job: TranscriptionJob
    let input: URL
    let duration: Double?
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FileHeader(input: input, duration: duration)
            WorkflowStepper(current: .transcription, completed: [.file])
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(1...4, id: \.self) { s in
                    HStack(spacing: 10) {
                        stepSymbol(s).frame(width: 16)
                        Text(TranscriptionJob.stepNames[s])
                            .fontWeight(s == job.step ? .semibold : .regular)
                            .foregroundStyle(s <= job.step ? .primary : .secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Steg \(s), \(TranscriptionJob.stepNames[s]), "
                                        + (s < job.step ? "ferdig" : s == job.step ? "pågår" : "gjenstår"))
                }
            }
            .font(.callout)

            VStack(alignment: .leading, spacing: 8) {
                Text(headline).font(.headline)
                    .foregroundStyle(job.state == .paused ? .orange : .primary)
                if let f = job.fraction {
                    ProgressView(value: f)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(remaining)
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Steg \(job.step) av 4, \(job.stepLabel)")
            .accessibilityValue(job.fraction.map { "\(Int($0 * 100)) prosent" } ?? "pågår")

            if !AppSettings.modelsCached, job.step == 2 || job.step == 4 {
                Label("Første kjøring laster ned modeller (opptil 3 GB). "
                      + "Det kan ta en stund før fremdriften beveger seg.",
                      systemImage: "arrow.down.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if job.state == .running {
                    Button("Pause", systemImage: "pause.fill") { job.pause() }
                        .keyboardShortcut("p", modifiers: [.command, .shift])
                } else {
                    Button("Fortsett", systemImage: "play.fill") { job.resume() }
                        .keyboardShortcut("p", modifiers: [.command, .shift])
                }
                // Ingen bekreftelsesdialog: backend skriver hvert ferdige segment
                // til disk og gjenopptar der den slapp, så Stopp koster ingenting.
                Button("Stopp", systemImage: "stop.fill") { job.stop() }
                    .keyboardShortcut(".")
                    .help("Skriver det som er ferdig. En ny start fortsetter der den slapp.")
            }

            DisclosureGroup("Detaljer", isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Steg \(job.step) av 4: \(TranscriptionJob.technicalNames[(1...4).contains(job.step) ? job.step : 0])")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        Text(job.log.suffix(40).joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                .padding(.top, 6)
            }
            .font(.callout)
        }
        .frame(maxWidth: 520)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.default, value: job.step)
    }

    @ViewBuilder private func stepSymbol(_ s: Int) -> some View {
        if s < job.step {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
        } else if s == job.step {
            if job.state == .paused {
                Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
            } else {
                ProgressView().controlSize(.small)
            }
        } else {
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    /// «Finner talere · segmentation», eller «Pauset — Finner talere».
    private var headline: String {
        if job.state == .paused { return "Pauset — \(job.stepLabel)" }
        return job.detail.isEmpty ? job.stepLabel : "\(job.stepLabel) · \(job.detail)"
    }

    /// Steg 4 har et ekte anslag fra segmenttellingen; de andre bruker raten
    /// fra forrige kjøring, når den finnes. Aldri tomt under kjøring — en
    /// linje som forsvinner ser ut som noe som har stoppet.
    private var remaining: String {
        if job.step == 4, job.total > 0 {
            return "\(job.done) av \(job.total) segmenter" + (job.eta.isEmpty ? "" : " · \(job.eta) igjen")
        }
        var parts: [String] = []
        if let f = job.fraction { parts.append("\(Int(f * 100)) %") }
        if let left = job.stepEstimate { parts.append("\(Estimates.describe(left)) igjen") }
        return parts.isEmpty ? "Pågår …" : parts.joined(separator: " · ")
    }
}
