import Foundation

/// Matcher backendens JSON eksakt (transcribe.py:105).
struct Segment: Codable, Identifiable {
    let start: Double
    let end: Double
    let speaker: String
    let language: String
    let text: String

    var id: String { "\(start)-\(speaker)" }
}

/// Port av transcribe.py:115-119. `,` for SRT, `.` for TXT.
func ts(_ sec: Double, _ sep: String = ",") -> String {
    let whole = Int(sec)
    let (h, rem) = (whole / 3600, whole % 3600)
    let (m, s) = (rem / 60, rem % 60)
    let ms = Int((sec - Double(whole)) * 1000)
    return String(format: "%02d:%02d:%02d\(sep)%03d", h, m, s, ms)
}

/// Port av write_outputs (transcribe.py:122-130). `names` mapper SPEAKER_00 → visningsnavn.
/// Skriver <base>.json / .txt / .srt og returnerer stiene som ble skrevet.
@discardableResult
func writeOutputs(_ segs: [Segment], to dir: URL, base: String, names: [String: String] = [:]) throws -> [URL] {
    func label(_ s: Segment) -> String { names[s.speaker] ?? s.speaker }

    let jsonURL = dir.appendingPathComponent(base + ".json")
    let txtURL = dir.appendingPathComponent(base + ".txt")
    let srtURL = dir.appendingPathComponent(base + ".srt")

    let renamed = segs.map {
        Segment(start: $0.start, end: $0.end, speaker: label($0), language: $0.language, text: $0.text)
    }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    try enc.encode(renamed).write(to: jsonURL)

    // ts(...)[:-4] i Python kutter ",mmm" → HH:MM:SS
    let txt = segs.map { s in
        "[\(String(ts(s.start, ".").dropLast(4)))] \(label(s)) (\(s.language)): \(s.text)"
    }.joined(separator: "\n") + "\n"
    try txt.write(to: txtURL, atomically: true, encoding: .utf8)

    // Hver blokk avsluttes med blank linje, også den siste — som backendens f-string.
    let srt = segs.enumerated().map { i, s in
        "\(i + 1)\n\(ts(s.start)) --> \(ts(s.end))\n\(label(s)) (\(s.language)): \(s.text)\n\n"
    }.joined()
    try srt.write(to: srtURL, atomically: true, encoding: .utf8)

    return [txtURL, srtURL, jsonURL]
}

/// Speiler backendens _selfcheck (transcribe.py:174-181). Kalles ved oppstart i debug.
func segmentSelfcheck() {
    assert(ts(3661.5) == "01:01:01,500", ts(3661.5))
    assert(String(ts(3661.5, ".").dropLast(4)) == "01:01:01", ts(3661.5, "."))
    assert(ts(0) == "00:00:00,000", ts(0))
}
