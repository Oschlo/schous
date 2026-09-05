import SwiftUI

/// Det malene faktisk produserer (#41): overskrifter, punkt- og
/// sjekklister, nummererte lister, avsnitt med inline-Markdown. Ingen pakke;
/// `AttributedString(markdown:)` tar fet, kursiv og lenker, men verken
/// overskrifter eller lister, så de deles ut linje for linje her.
/// `<aside>`-blokker fra Notion-eksporten hoppes over.
enum MarkdownBlock: Equatable {
    case heading(Int, String)
    case bullet(String)
    case task(Bool, String)
    case numbered(Int, String)
    case paragraph(String)
    case blank

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if blocks.last != nil, blocks.last != .blank { blocks.append(.blank) }
            } else if line.firstMatch(#"^</?aside\b"#) != nil {
                // Bare aside-taggene, ikke alt som begynner med «<»: en
                // autolenke som <https://…> er gyldig Markdown og skal med.
                continue
            } else if let m = line.firstMatch(#"^(#{1,6})\s+(.*)$"#) {
                blocks.append(.heading(m[1].count, m[2]))
            } else if let m = line.firstMatch(#"^[-*]\s+\[([ xX])\]\s+(.*)$"#) {
                blocks.append(.task(m[1] != " ", m[2]))
            } else if let m = line.firstMatch(#"^[-*]\s+(.*)$"#) {
                blocks.append(.bullet(m[1]))
            } else if let m = line.firstMatch(#"^(\d+)\.\s+(.*)$"#) {
                blocks.append(.numbered(Int(m[1]) ?? 0, m[2]))
            } else {
                blocks.append(.paragraph(line))
            }
        }
        while blocks.last == .blank { blocks.removeLast() }
        return blocks
    }
}

struct MarkdownView: View {
    let text: String

    var body: some View {
        let blocks = MarkdownBlock.parse(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                row(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func row(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let s):
            inline(s)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, level <= 2 ? 8 : 4)
                .accessibilityAddTraits(.isHeader)
        case .bullet(let s):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                inline(s)
            }
            .padding(.leading, 8)
        case .task(let done, let s):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: done ? "checkmark.square" : "square").foregroundStyle(.secondary)
                    .accessibilityLabel(done ? "Gjort" : "Ikke gjort")
                inline(s)
            }
            .padding(.leading, 8)
        case .numbered(let n, let s):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(n).").monospacedDigit().foregroundStyle(.secondary)
                inline(s)
            }
            .padding(.leading, 8)
        case .paragraph(let s):
            inline(s)
        case .blank:
            Spacer().frame(height: 4)
        }
    }

    private func inline(_ s: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s))
    }
}
