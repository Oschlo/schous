import SwiftUI

enum InspectorTab: String, CaseIterable { case speakers = "Talere", summary = "Referat" }

/// Vises når jobben er ferdig: gi talerne navn, slå sammen ID-er som er samme person,
/// og skriv txt/srt/json til brukerens output-mappe. Fasit-JSON i jobbmappen røres aldri.
struct SpeakerEditorView: View {
    @ObservedObject var job: TranscriptionJob
    let outputDir: URL
    var onNewJob: () -> Void

    @State private var names: [String: String] = [:]      // SPEAKER_00 → visningsnavn
    @State private var mergedInto: [String: String] = [:]  // SPEAKER_03 → SPEAKER_01
    @State private var status: String?
    @State private var failed = false
    /// Det «Eksporter» sist skrev, så «Vis i Finder» har noe å peke på.
    @State private var written: [URL] = []

    /// Inspektøren viser ett arbeidstrinn om gangen. `wantsInspector` er
    /// brukerens valg; `narrow` er vinduets. Under 760 pt (620 minimum +
    /// 240 inspektør, minus luft) ville to kolonner klemt transkripsjonen.
    @State private var tab: InspectorTab = .speakers
    @State private var wantsInspector = true
    @State private var narrow = false
    @State private var summarySelection = SummarySelection()
    /// Tittelen som blir filnavnet (#42). Lagres som title.txt i jobbmappa;
    /// tom = kildefilas navn.
    @State private var title = ""
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    @StateObject private var summarizer = Summarizer()
    enum Pane: String, CaseIterable { case transcript = "Transkripsjon", summary = "Referat" }
    @State private var pane: Pane = .transcript
    /// Referat-fanen i dokumentkolonnen finnes bare når det er noe å vise i den.
    private var hasSummary: Bool { !summarizer.text.isEmpty || summarizer.state == .running }

    /// Alle taler-ID-er backend fant, i rekkefølgen de først dukker opp.
    private var ids: [String] {
        var seen = Set<String>()
        return job.segments.map(\.speaker).filter { seen.insert($0).inserted }
    }
    private var roots: [String] { ids.filter { mergedInto[$0] == nil } }

    /// Følger merge-kjeder til rot-ID-en, med syklusvern.
    private func root(_ id: String) -> String {
        var cur = id, hops = 0
        while let next = mergedInto[cur], hops < ids.count { cur = next; hops += 1 }
        return cur
    }
    private func label(_ id: String) -> String {
        let r = root(id)
        let n = names[r] ?? ""
        return n.isEmpty ? r : n
    }
    /// Flat mapping til writeOutputs: hver ID → sluttnavn.
    private var resolved: [String: String] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, label($0)) })
    }

    /// Segmentene som vises: alle, eller de som treffer søket.
    private var shown: [Segment] { job.segments.filter { matches($0, query: query) } }

    /// Datoen i filnavnet er inputfilas opprettelsesdato — det er når møtet
    /// var, ikke når det ble eksportert.
    private var inputDate: Date {
        (try? job.input?.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    }
    private var exportBase: String { outputBase(title: title, date: inputDate, fallback: job.base) }

    private var showInspector: Binding<Bool> {
        Binding(get: { wantsInspector && !narrow }, set: { wantsInspector = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkflowStepper(current: tab == .summary ? .summary : .speakers,
                            completed: [.file, .transcription]) { step in
                switch step {
                case .file, .transcription: onNewJob()
                case .speakers: tab = .speakers; wantsInspector = true
                case .summary: tab = .summary; wantsInspector = true
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
            // Eksportstatusen står her, ikke i verktøylinja: der ble den lagt
            // ved siden av søkefeltet, og ved 900 pt fløt hele linja over i «»».
            if let status {
                HStack(spacing: 6) {
                    Text(status).font(.callout).foregroundStyle(failed ? .red : .secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if !failed, let first = written.first {
                        Button("Vis i Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([first])
                        }
                        .buttonStyle(.link).font(.callout)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 8)
            }
            Divider()
            if hasSummary {
                // Navnet er for VoiceOver; labelsHidden skjuler det bare visuelt.
                Picker("Visning", selection: $pane) {
                    ForEach(Pane.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(8)
                Divider()
            }
            if pane == .summary, hasSummary {
                SummaryPanel(summarizer: summarizer)
            } else {
                transcript
            }
        }
        // Fyller alltid. Uten dette sto begge kolonnene forskjøvet oppover i
        // det referatet startet (tom tekst) og i det det ble ferdig (bytte
        // Text → MarkdownView) — målt 2026-09-04.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(minWidth: 340)
        // Talere er egenskaper ved innholdet, ikke navigasjon — altså en
        // inspektør, med systemets egen kant, bredde og av/på-knapp.
        .inspector(isPresented: showInspector) {
            inspector.inspectorColumnWidth(min: 240, ideal: 300, max: 420)
        }
        // Vinduets bredde, ikke kolonnens: 900 pt vindu med 300 pt inspektør
        // gir en kolonne på 600, og en måling der ville skjult inspektøren,
        // fått kolonnen til 900, vist den igjen — i sløyfe. Lest fra NSWindow
        // via en tom AppKit-visning, ikke en GeometryReader: den skrev
        // tilstand midt i layout.
        .background(WindowWidthReader { narrow = $0 < 760 })
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    // Egen TextField, ikke .searchable: fokus fra ⌘F kan
                    // ikke styres programmatisk før macOS 15.
                    TextField("Søk i transkripsjonen", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .focused($searchFocused)
                        .accessibilityLabel("Søk i transkripsjonen")
                    if !query.isEmpty {
                        Text("\(shown.count) treff").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            ToolbarItem(placement: .navigation) {
                // Det knappen alltid har gjort: tilbake til oppsettet, med fila
                // fortsatt valgt. «Ny fil» var feil navn på det.
                // ⌘↑ som Finders «Overordnet mappe», ikke ⌘[: «[» er ⌥8 på
                // norsk tastatur, og målt her nådde ⌘⌥8 aldri knappen.
                Button("Tilbake", systemImage: "chevron.left", action: onNewJob)
                    .keyboardShortcut(.upArrow)
            }
            ToolbarItem(placement: .primaryAction) {
                // Snarveien ⌘⌥T ligger i Vis-menyen (SchousApp), så verktøylinja
                // ikke er eneste inngang. «]» er ⌥9 på norsk tastatur.
                Button("Inspektør", systemImage: "sidebar.trailing") { wantsInspector.toggle() }
                    .help(narrow ? "Vinduet er for smalt for inspektøren" : "Vis eller skjul talere og referat")
                    .disabled(narrow)
            }
            ToolbarItem(placement: .primaryAction) {
                // Alltid til stede, ikke betinget: en verktøylinje som får et
                // nytt element midt i en kjøring legges ut på nytt.
                Button("Kopier referat", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summarizer.text, forType: .string)
                }
                .help("Kopierer referatet som Markdown")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                // Delt knapp: klikk skriver standardformatene fra Innstillinger,
                // pilen skriver ett enkelt format uten å endre standarden.
                Menu("Eksporter") {
                    ForEach(OutputFormat.allCases) { f in
                        Button("Bare \(f.label)") { save([f]) }
                    }
                } primaryAction: {
                    save(AppSettings.shared.formats)
                }
                .buttonStyle(.borderedProminent)
                .menuStyle(.button)
                .fixedSize()
                .help("Skriver TXT, SRT og JSON til «\(outputDir.lastPathComponent)». ⌘S")
            }
        }
        .onAppear(perform: loadMapping)
        .onReceive(NotificationCenter.default.publisher(for: .saveOutputs)) { _ in
            save(AppSettings.shared.formats)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleInspector)) { _ in
            wantsInspector.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            pane = .transcript
            searchFocused = true
        }
        .navigationTitle(job.base)
        // Når kjøringen starter er referatet det du venter på — vis det.
        .onChange(of: summarizer.state) { _, new in
            if new == .running { pane = .summary }
        }
        // «Tilbake» tar med seg Stopp-knappen. Uten dette holdt Task-en
        // Summarizer i live, og referatet ble skrevet etter at du hadde gått.
        .onDisappear { summarizer.cancel() }
    }

    /// Transkripsjonen som et dokument: rolig maksbredde, luft mellom
    /// replikkene, talernavn som token (farge + tekst, aldri farge alene),
    /// tidsstempel som kan kopieres.
    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if shown.isEmpty, !query.isEmpty {
                    Text("Ingen treff på «\(query)».").foregroundStyle(.secondary)
                }
                ForEach(shown) { s in
                    let stamp = String(ts(s.start, ".").dropLast(4))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Button(stamp) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(stamp, forType: .string)
                            }
                            .buttonStyle(.plain)
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .help("Kopier tidsstempel")
                            .accessibilityLabel("Tidsstempel \(stamp), kopier")
                            Text(label(s.speaker))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(color(for: root(s.speaker)))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(color(for: root(s.speaker)).opacity(0.12), in: Capsule())
                            Text(s.language).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(s.text).lineSpacing(3).textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// Ett arbeidstrinn om gangen: Talere eller Referat. Referatets handling
    /// står i en fast bunn, ikke nederst i et scrollfelt der vinduskanten
    /// kan skjule den.
    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $tab) {
                ForEach(InspectorTab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(10)
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .speakers:
                        SpeakerInspector(ids: ids, roots: roots, names: $names, mergedInto: $mergedInto,
                                         count: count, label: label, root: root, color: color(for:),
                                         quote: quote)
                    case .summary:
                        SummaryControls(jobDir: job.jobDir, summarizer: summarizer, selection: $summarySelection,
                                        title: $title, fallbackName: job.base, date: inputDate)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if tab == .summary {
                Divider()
                SummaryFooter(summarizer: summarizer,
                              canStart: summarySelection.template != nil && !summarySelection.model.isEmpty
                                        && AppSettings.shared.models != nil,
                              start: { startSummary(summarySelection) })
                    .padding(12)
            }
        }
    }

    // MARK: - Hjelpere

    private func count(_ id: String) -> Int { job.segments.count { $0.speaker == id } }

    private func quote(_ id: String) -> String? {
        job.segments.first(where: { $0.speaker == id }).map { String($0.text.prefix(120)) }
    }

    /// Etter posisjon, ikke `hashValue`: Swift såer Hasher på nytt per prosess,
    /// så samme taler var blå i dag og oransje etter omstart.
    private func color(for id: String) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]
        return palette[(ids.firstIndex(of: id) ?? 0) % palette.count]
    }

    // MARK: - Eksport

    private func save(_ formats: Set<OutputFormat>) {
        guard !formats.isEmpty else {
            failed = true
            status = "Ingen eksportformater valgt — velg minst ett i Innstillinger."
            return
        }
        do {
            written = try writeOutputs(job.segments, to: outputDir, base: exportBase,
                                       names: resolved, formats: formats)
            saveMapping()
            failed = false
            let list = written.map { $0.pathExtension.uppercased() }.joined(separator: ", ")
            status = "Lagret \(list) som «\(exportBase)» i \(outputDir.lastPathComponent)"
        } catch {
            failed = true
            // Skrivingene er separate: feiler den andre, ligger den første igjen på disk
            // med nye navn ved siden av en fil som fortsatt har de gamle.
            status = "Klarte ikke å lagre: \(error.localizedDescription). "
                + "Filene i \(outputDir.lastPathComponent) kan være delvis oppdatert."
        }
    }

    // MARK: - Referat

    /// Lagrer først: navnene fryses nå uansett, så dette er punktet TXT/SRT
    /// skal ut. Feiler lagringen, startes ikke referatet. Endrer du et navn
    /// etterpå, er det en ny kjøring.
    private func startSummary(_ sel: SummarySelection) {
        guard let template = sel.template else { return }
        save(AppSettings.shared.formats)
        guard !failed else { return }
        guard let body = try? String(contentsOf: template, encoding: .utf8) else {
            failed = true; status = "Kunne ikke lese \(template.lastPathComponent)."; return
        }
        let settings = AppSettings.shared
        let prompt = Summary.prompt(body, language: sel.language.promptValue, context: sel.context,
                                    transcript: transcriptText(job.segments, names: resolved),
                                    using: settings.summaryPrompt)
        let slug = Templates.slug(Templates.name(template))
        var targets = [outputDir.appending(path: "\(exportBase).\(slug).md")]
        if let dir = job.jobDir {
            targets.append(dir.appending(path: "summary.\(slug).md"))
            try? sel.context.write(to: dir.appending(path: "context.txt"), atomically: true, encoding: .utf8)
        }
        summarizer.run(prompt: prompt, model: sel.model, baseURL: settings.ollamaBaseURL, writeTo: targets)
    }

    private var mappingURL: URL? { job.jobDir?.appending(path: "speakers.json") }

    private func saveMapping() {
        guard let url = mappingURL, let dir = job.jobDir else { return }
        let payload = ["names": names, "mergedInto": mergedInto]
        try? JSONEncoder().encode(payload).write(to: url)
        try? title.write(to: dir.appending(path: "title.txt"), atomically: true, encoding: .utf8)
    }

    private func loadMapping() {
        if let url = mappingURL, let data = try? Data(contentsOf: url),
           let payload = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            names = payload["names"] ?? [:]
            mergedInto = payload["mergedInto"] ?? [:]
        }
        if let dir = job.jobDir,
           let saved = try? String(contentsOf: dir.appending(path: "title.txt"), encoding: .utf8) {
            title = saved
        }

        // Et tidligere referat fra denne jobben vises igjen. Nyeste hvis flere.
        if let dir = job.jobDir,
           let prior = ((try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter({ $0.lastPathComponent.hasPrefix("summary.") && $0.pathExtension == "md" })
                .max(by: { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast
                          < (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }),
           let text = try? String(contentsOf: prior, encoding: .utf8) {
            summarizer.text = text
        }
    }
}

/// Rapporterer bredden på vinduet visningen ligger i, ved innsetting og ved
/// hver endring av størrelse. Null i utstrekning, utenfor SwiftUI-layouten.
private struct WindowWidthReader: NSViewRepresentable {
    let onWidth: (CGFloat) -> Void

    func makeNSView(context: Context) -> Probe { Probe(onWidth: onWidth) }
    func updateNSView(_ view: Probe, context: Context) { view.onWidth = onWidth }

    final class Probe: NSView {
        var onWidth: (CGFloat) -> Void
        init(onWidth: @escaping (CGFloat) -> Void) {
            self.onWidth = onWidth
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        // Selector, ikke blokk: en selector-observer fjernes selv når visningen
        // dør, så det trengs verken token eller deinit.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(resized(_:)),
                                                   name: NSWindow.didResizeNotification, object: window)
            report(window.frame.width)
        }
        @objc private func resized(_ n: Notification) {
            if let w = (n.object as? NSWindow)?.frame.width { report(w) }
        }
        /// Utenfor layout-runden: dette kalles fra viewDidMoveToWindow, som
        /// er midt i den.
        private func report(_ width: CGFloat) {
            DispatchQueue.main.async { [weak self] in self?.onWidth(width) }
        }
    }
}
