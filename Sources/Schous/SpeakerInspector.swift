import SwiftUI

/// «Talere»-fanen i inspektøren: én kompakt rad per ID — farge, navn, antall
/// segmenter og sammenslåing. Eksempelutsagnet står på én linje under, med
/// hele teksten i tooltip, så fem talere får plass uten at «Referat»
/// forsvinner under folden.
struct SpeakerInspector: View {
    let ids: [String]
    let roots: [String]
    @Binding var names: [String: String]
    @Binding var mergedInto: [String: String]
    let count: (String) -> Int
    let label: (String) -> String
    let root: (String) -> String
    let color: (String) -> Color
    let quote: (String) -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(ids, id: \.self) { id in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Circle().fill(color(root(id))).frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                        if mergedInto[id] == nil {
                            TextField(id, text: nameBinding(id))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Navn for \(id)")
                        } else {
                            Text("\(id) → \(label(id))")
                                .font(.body).foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityLabel("\(id), slått sammen med \(label(id))")
                        }
                        Text("\(count(id))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .help("\(count(id)) segmenter")
                            .accessibilityLabel("\(count(id)) segmenter")
                        mergeMenu(id)
                    }
                    if let q = quote(id) {
                        Text("„\(q)“")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(q)
                    }
                }
            }
            Text("Én person kan ha fått flere ID-er. Slå dem sammen med personmenyen på raden.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    private func mergeMenu(_ id: String) -> some View {
        Menu {
            Button("Egen person") { mergedInto[id] = nil }
            ForEach(roots.filter { $0 != id }, id: \.self) { other in
                Button("Samme som \(label(other))") { merge(id, into: other) }
            }
        } label: {
            Image(systemName: mergedInto[id] == nil ? "person" : "person.2.fill")
                .accessibilityHidden(true)   // ellers leser VoiceOver «person» foran etiketten
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Slå sammen med en annen taler")
        .accessibilityLabel("Slå sammen \(id)")
    }

    private func nameBinding(_ id: String) -> Binding<String> {
        Binding(get: { names[id] ?? "" }, set: { names[id] = $0 })
    }

    /// Ikke la en merge peke tilbake på noe som allerede peker på id.
    private func merge(_ id: String, into target: String) {
        if root(target) == id { mergedInto[id] = nil } else { mergedInto[id] = target }
    }
}
