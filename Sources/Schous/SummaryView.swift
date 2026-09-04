import SwiftUI

/// Valgene før et referat: mal, modell, språk, kontekst. Ligger i sidefeltet
/// under «Talere», så rekkefølgen står der uten forklaring og transkripsjonen
/// er synlig mens konteksten skrives. Kontekst lagres i jobbmappa som
/// context.txt, så den henger med hvis du kjører en annen mal.
struct SummaryControls: View {
    let jobDir: URL?
    @ObservedObject var summarizer: Summarizer
    var onStart: (URL, String, SummaryLanguage, String) -> Void
    @ObservedObject private var settings = AppSettings.shared

    @State private var templates: [URL] = []
    @State private var template: URL?
    @State private var model = ""
    @State private var language: SummaryLanguage = .norwegian
    @State private var context = ""

    private var running: Bool { summarizer.state == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Referat").font(.headline)
            Group {
                if templates.isEmpty {
                    Text("Ingen maler i malmappa.").foregroundStyle(.orange).font(.callout)
                    Button("Åpne malmappe") { Templates.open() }
                } else {
                    Picker("Mal", selection: $template) {
                        ForEach(templates, id: \.self) { Text(Templates.name($0)).tag(Optional($0)) }
                    }
                }
                if let models = settings.models {
                    Picker("Modell", selection: $model) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    Text("ollama svarer ikke på \(settings.ollamaURL) — kjør `ollama serve`.")
                        .foregroundStyle(.orange).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Picker("Språk", selection: $language) {
                    ForEach(SummaryLanguage.allCases) { Text($0.label).tag($0) }
                }
                Text("Kontekst (valgfritt): hvem var med, hva gjaldt møtet")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $context)
                    .font(.body).frame(height: 60)
                    .border(Color.secondary.opacity(0.3))
            }
            .disabled(running)

            if running {
                Button("Stopp") { summarizer.cancel() }
            } else {
                Button("Lag referat") {
                    guard let template else { return }
                    onStart(template, model, language, context)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(template == nil || model.isEmpty || settings.models == nil)
            }
            status
        }
        .task {
            Templates.seedIfMissing()
            rescanTemplates()
            language = settings.summaryLanguage
            // Alt som kan skrives i må stå klart *før* ventingen på ollama:
            // den kan ta 5 s, og feltet er ikke sperret imens.
            if let dir = jobDir,
               let saved = try? String(contentsOf: dir.appending(path: "context.txt"), encoding: .utf8) {
                context = saved
            }
            if settings.models == nil { await settings.refreshModels() }
            pickModel(settings.summaryModel)
        }
        // Lista byttes ut fra Innstillinger (ny URL, «Hent modeller»); et valg
        // som ikke finnes der lenger ville sendt et 404.
        .onChange(of: settings.models) { _, _ in pickModel(model) }
        // Et referat tar minutter; Dock-ikonet sier fra når det er ferdig.
        .onChange(of: summarizer.state) { _, new in
            if case .running = new { return }
            NSApplication.shared.requestUserAttention(.informationalRequest)
        }
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
        model = models.contains(wanted) ? wanted : (models.first ?? "")
    }

    private func rescanTemplates() {
        templates = Templates.list()
        if let template, templates.contains(template) { return }
        template = templates.first
    }

    /// Statusen står under knappen, ikke i verktøylinja: det er her blikket
    /// er når den trykkes, og verktøylinja har «Lagret …» fra før.
    @ViewBuilder private var status: some View {
        switch summarizer.state {
        case .running:
            if let t0 = summarizer.started {
                (Text("Referat … ") + Text(t0, style: .timer))
                    .font(.callout).foregroundStyle(.secondary)
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

/// Teksten mens den strømmer inn, og etterpå. Full høyde i venstrekolonnen;
/// fanen over velger mellom denne og transkripsjonen.
struct SummaryPanel: View {
    @ObservedObject var summarizer: Summarizer

    var body: some View {
        ScrollView {
            Text(summarizer.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }
}
