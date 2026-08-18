import SwiftUI

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

    var body: some View {
        HSplitView {
            transcript
            sidebar
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                if let status {
                    Text(status).font(.callout).foregroundStyle(failed ? .red : .secondary)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Ny fil", action: onNewJob)
                // Delt knapp: klikk lagrer standardformatene fra Innstillinger,
                // pilen skriver ett enkelt format uten å endre standarden.
                Menu("Lagre") {
                    ForEach(OutputFormat.allCases) { f in
                        Button("Bare \(f.label)") { save([f]) }
                    }
                } primaryAction: {
                    save(AppSettings.shared.formats)
                }
                .buttonStyle(.borderedProminent)
                .menuStyle(.button)
                .fixedSize()
            }
        }
        .onAppear(perform: loadMapping)
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(job.segments) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(String(ts(s.start, ".").dropLast(4)))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(label(s.speaker)).font(.caption.weight(.semibold))
                                .foregroundStyle(color(for: root(s.speaker)))
                            Text(s.language).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text(s.text).textSelection(.enabled)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 340)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Talere").font(.headline)
                Text("Diarization deler av og til én person i flere ID-er. Slå dem sammen her.")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(ids, id: \.self) { id in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle().fill(color(for: root(id))).frame(width: 8, height: 8)
                            Text(id).font(.caption.monospaced())
                            Spacer()
                            Text("\(count(id)) seg").font(.caption2).foregroundStyle(.secondary)
                        }
                        if mergedInto[id] == nil {
                            TextField(id, text: binding(id))
                                .textFieldStyle(.roundedBorder)
                        }
                        Picker("", selection: mergeBinding(id)) {
                            Text("Egen person").tag("")
                            ForEach(roots.filter { $0 != id }, id: \.self) { other in
                                Text("Samme som \(label(other))").tag(other)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        if let first = job.segments.first(where: { $0.speaker == id }) {
                            Text("„\(first.text.prefix(70))“")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Divider()
                }
            }
            .padding(16)
        }
        .frame(minWidth: 240, idealWidth: 280)
    }

    // MARK: - Bindings

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { names[id] ?? "" }, set: { names[id] = $0 })
    }

    private func mergeBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { mergedInto[id] ?? "" },
            set: { target in
                // Ikke la en merge peke tilbake på noe som allerede peker på id.
                if target.isEmpty || root(target) == id {
                    mergedInto[id] = nil
                } else {
                    mergedInto[id] = target
                }
            }
        )
    }

    private func count(_ id: String) -> Int { job.segments.count { $0.speaker == id } }

    private func color(for id: String) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]
        return palette[abs(id.hashValue) % palette.count]
    }

    // MARK: - Lagring

    private func save(_ formats: Set<OutputFormat>) {
        guard !formats.isEmpty else {
            failed = true
            status = "Ingen eksportformater valgt — velg minst ett i Innstillinger."
            return
        }
        do {
            let written = try writeOutputs(job.segments, to: outputDir, base: job.base,
                                           names: resolved, formats: formats)
            saveMapping()
            failed = false
            let list = written.map { $0.pathExtension.uppercased() }.joined(separator: ", ")
            status = "Lagret \(list) i \(outputDir.lastPathComponent)"
        } catch {
            failed = true
            // Skrivingene er separate: feiler den andre, ligger den første igjen på disk
            // med nye navn ved siden av en fil som fortsatt har de gamle.
            status = "Klarte ikke å lagre: \(error.localizedDescription). "
                + "Filene i \(outputDir.lastPathComponent) kan være delvis oppdatert."
        }
    }

    private var mappingURL: URL? { job.jobDir?.appending(path: "speakers.json") }

    private func saveMapping() {
        guard let url = mappingURL else { return }
        let payload = ["names": names, "mergedInto": mergedInto]
        try? JSONEncoder().encode(payload).write(to: url)
    }

    private func loadMapping() {
        guard let url = mappingURL, let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return }
        names = payload["names"] ?? [:]
        mergedInto = payload["mergedInto"] ?? [:]
    }
}
