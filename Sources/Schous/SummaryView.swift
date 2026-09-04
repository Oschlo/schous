import SwiftUI

/// Det som er valgt i Referat-fanen. Ligger hos editoren, så bunnen (knappen)
/// og skjemaet over kan være to visninger uten å dele tilstand via
/// summarizer.
struct SummarySelection {
    var template: URL?
    var model = ""
    var language: SummaryLanguage = .norwegian
    var context = ""
}

/// Valgene før et referat: mal, modell, språk, kontekst. Kontekst lagres i
/// jobbmappa som context.txt, så den henger med hvis du kjører en annen mal.
/// Handlingen og statusen står i `SummaryFooter`, festet under skjemaet, så
/// de er synlige uansett hvor langt skjemaet er.
struct SummaryControls: View {
    let jobDir: URL?
    @ObservedObject var summarizer: Summarizer
    @Binding var selection: SummarySelection
    @ObservedObject private var settings = AppSettings.shared

    @State private var templates: [URL] = []

    private var running: Bool { summarizer.state == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if templates.isEmpty {
                Text("Ingen maler i malmappa.").foregroundStyle(.orange).font(.callout)
                Button("Åpne malmappe") { Templates.open() }
            } else {
                Picker("Mal", selection: $selection.template) {
                    ForEach(templates, id: \.self) { Text(Templates.name($0)).tag(Optional($0)) }
                }
            }
            if let models = settings.models {
                Picker("Modell", selection: $selection.model) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
            } else {
                Text("ollama svarer ikke på \(settings.ollamaURL) — kjør `ollama serve`.")
                    .foregroundStyle(.orange).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Språk", selection: $selection.language) {
                ForEach(SummaryLanguage.allCases) { Text($0.label).tag($0) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Kontekst").font(.callout)
                TextEditor(text: $selection.context)
                    .font(.body)
                    .frame(minHeight: 60)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Kontekst")
                    .accessibilityHint("Hvem var med og hva møtet gjaldt. Valgfritt.")
                Text("Valgfritt: hvem var med, hva gjaldt møtet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(running)
        .task {
            Templates.seedIfMissing()
            rescanTemplates()
            selection.language = settings.summaryLanguage
            // Alt som kan skrives i må stå klart *før* ventingen på ollama:
            // den kan ta 5 s, og feltet er ikke sperret imens.
            if let dir = jobDir,
               let saved = try? String(contentsOf: dir.appending(path: "context.txt"), encoding: .utf8) {
                selection.context = saved
            }
            if settings.models == nil { await settings.refreshModels() }
            pickModel(settings.summaryModel)
        }
        // Lista byttes ut fra Innstillinger (ny URL, «Hent modeller»); et valg
        // som ikke finnes der lenger ville sendt et 404.
        .onChange(of: settings.models) { _, _ in pickModel(selection.model) }
        // «Åpne malmappe» går til Finder; når vi får fokus igjen er mappa
        // kanskje ikke tom lenger.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            rescanTemplates()
        }
    }

    /// Standardmodellen kan være avinstallert siden sist; da har den ingen
    /// tag i Picker-en, og knappen ville sendt et 404.
    private func pickModel(_ wanted: String) {
        let models = settings.models ?? []
        selection.model = models.contains(wanted) ? wanted : (models.first ?? "")
    }

    private func rescanTemplates() {
        templates = Templates.list()
        if let t = selection.template, templates.contains(t) { return }
        selection.template = templates.first
    }
}

/// Handlingen og statusen, alltid synlig nederst i inspektøren. Statusen står
/// her og ikke i verktøylinja: det er her blikket er når knappen trykkes, og
/// verktøylinja har «Lagret …» fra før.
struct SummaryFooter: View {
    @ObservedObject var summarizer: Summarizer
    let canStart: Bool
    let start: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            status
            HStack {
                Spacer()
                if summarizer.state == .running {
                    Button("Stopp") { summarizer.cancel() }
                } else {
                    Button("Lag referat", action: start)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                        .disabled(!canStart)
                }
            }
        }
        // Et referat tar minutter; Dock-ikonet sier fra når det er ferdig,
        // og VoiceOver får en setning, ikke bare en fargeendring.
        .onChange(of: summarizer.state) { _, new in
            switch new {
            case .running: return
            case .done: AccessibilityNotification.Announcement("Referatet er lagret").post()
            case .failed: AccessibilityNotification.Announcement("Referatet feilet").post()
            case .idle: break
            }
            NSApplication.shared.requestUserAttention(.informationalRequest)
        }
    }

    @ViewBuilder private var status: some View {
        switch summarizer.state {
        case .running:
            // Fasen, ikke bare en klokke: fem minutter med en teller er ikke
            // til å skille fra en app som henger (#39).
            switch summarizer.phase {
            case .waiting(let estimate):
                ProgressView().progressViewStyle(.linear)
                    .accessibilityLabel("Modellen leser transkripsjonen")
                Text("Modellen leser transkripsjonen (\(summarizer.promptWords) ord)"
                     + (estimate.map { " · tar vanligvis \(Estimates.describe($0)) på denne maskinen" }
                        ?? " · ingenting vises før den er ferdig"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                if let t0 = summarizer.started {
                    (Text("Skriver referat … ") + Text(t0, style: .timer))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        case .done(let url):
            Text("Referat lagret som \(url.lastPathComponent)")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Vis i Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.link)
        case .failed(let msg):
            Text(msg).font(.callout).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .idle:
            EmptyView()
        }
    }
}

/// Teksten mens den strømmer inn, og etterpå. Full høyde i dokumentkolonnen;
/// fanen over velger mellom denne og transkripsjonen.
struct SummaryPanel: View {
    @ObservedObject var summarizer: Summarizer

    var body: some View {
        ScrollView {
            Text(summarizer.text)
                .textSelection(.enabled)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24).padding(.vertical, 20)
        }
    }
}
