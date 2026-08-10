import AVFoundation
import Foundation

/// `Schous --selfcheck` — verifiserer at parserne matcher ekte backend-output.
/// Linjene under er kopiert verbatim fra transcribe.py sine print/tqdm-kall.
@MainActor
func runSelfcheckAndExit() -> Never {
    segmentSelfcheck()
    recorderSelfcheck()

    let job = TranscriptionJob()

    job.parseStdout("1/4 lyd…")
    check(job.step == 1, "steg 1, fikk \(job.step)")

    job.parseStdout("2/4 diarization…")
    job.parseStdout("  509 segmenter, 3 talere")
    check(job.step == 2 && job.total == 509 && job.speakerCount == 3,
          "steg 2: \(job.step) \(job.total) \(job.speakerCount)")

    job.parseStdout("3/4 språk per taler…")
    job.parseStdout("  taler 1/3 SPEAKER_00: sv  (\"Väldigt många människor...\")")
    check(job.step == 3 && job.detail == "taler 1/3 — SPEAKER_00: sv", "steg 3: \(job.detail)")

    job.parseStdout("4/4 transkriberer…")
    check(job.step == 4, "steg 4, fikk \(job.step)")

    // tqdm på stderr, non-tty-varianten
    job.parseStderr("  transkriberer:  42%|████▏     | 214/509 [08:31<11:44,  2.39s/seg, SPEAKER_00 no]")
    check(job.done == 214 && job.total == 509 && job.eta == "11:44",
          "tqdm: \(job.done)/\(job.total) eta=\(job.eta)")
    check(job.detail == "SPEAKER_00 (no)", "tqdm postfix: \(job.detail)")
    check(job.fraction.map { abs($0 - 214.0 / 509.0) < 1e-9 } == true, "fraction")

    // tqdm helt i starten: ukjent ETA
    job.parseStderr("  transkriberer:   0%|          | 0/509 [00:00<?, ?seg/s]")
    check(job.done == 0 && job.eta == "?", "tqdm start: done=\(job.done) eta=\(job.eta)")

    // huggingface sin egen tqdm-bar på stderr må ignoreres, ikke leses som fremdrift
    job.parseStderr("Fetching 4 files: 100%|██████████| 4/4 [00:00<00:00, 2035.58it/s]")
    check(job.done == 0 && job.total == 509, "hf-bar forurenset: \(job.done)/\(job.total)")

    job.parseStdout("HF_TOKEN ikke satt. export HF_TOKEN=hf_...")
    check(job.state == .failed("HF_TOKEN mangler. Legg den inn i Innstillinger."), "hf-token-feil")

    // Output-formatering mot backendens write_outputs
    let segs = [Segment(start: 4.216, end: 7.905, speaker: "SPEAKER_00", language: "sv", text: "Hei.")]
    let dir = URL.temporaryDirectory.appending(path: "schous-selfcheck-\(getpid())")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try! writeOutputs(segs, to: dir, base: "t", names: ["SPEAKER_00": "Hans Martin"])

    let txt = try! String(contentsOf: dir.appending(path: "t.txt"), encoding: .utf8)
    check(txt == "[00:00:04] Hans Martin (sv): Hei.\n", "txt: \(txt.debugDescription)")
    let srt = try! String(contentsOf: dir.appending(path: "t.srt"), encoding: .utf8)
    check(srt == "1\n00:00:04,216 --> 00:00:07,905\nHans Martin (sv): Hei.\n\n",
          "srt: \(srt.debugDescription)")

    // Valgfritt: sammenlign porten mot ekte backend-output.
    // Schous --selfcheck <jobbmappe>/output/<base>
    if let base = CommandLine.arguments.last, base != "--selfcheck" {
        verifyAgainstBackend(base: URL(fileURLWithPath: base))
    }

    print("selfcheck ok")
    exit(0)
}

/// Leser backendens egne .json/.txt/.srt, kjører dem gjennom writeOutputs uten omdøping,
/// og krever byte-identisk resultat. Fanger enhver formatavvik i porten.
@MainActor
private func verifyAgainstBackend(base: URL) {
    let dir = base.deletingLastPathComponent()
    let name = base.lastPathComponent
    guard let data = try? Data(contentsOf: base.appendingPathExtension("json")) else {
        check(false, "fant ikke \(base.path).json"); return
    }
    let segs: [Segment]
    do { segs = try JSONDecoder().decode([Segment].self, from: data) }
    catch { check(false, "kunne ikke dekode backend-JSON: \(error)"); return }
    check(!segs.isEmpty, "backend-JSON er tom")

    let tmp = URL.temporaryDirectory.appending(path: "schous-verify-\(getpid())")
    try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    try! writeOutputs(segs, to: tmp, base: name)

    for ext in ["txt", "srt"] {
        let mine = try! String(contentsOf: tmp.appending(path: "\(name).\(ext)"), encoding: .utf8)
        let theirs = try! String(contentsOf: dir.appending(path: "\(name).\(ext)"), encoding: .utf8)
        check(mine == theirs, ".\(ext) avviker fra backend:\nmin:  \(mine.debugDescription)\nderes: \(theirs.debugDescription)")
    }
    print("  verifisert mot backend: \(segs.count) segmenter, .txt og .srt byte-identiske")
}

/// Miksingen i Recorder.swift: kanaler innenfor en kilde snittes, kilder summeres.
@MainActor
private func recorderSelfcheck() {
    // Stereo (snittes til 0.2, 0.4) + mono (0.1, 0.05) → 0.3, 0.45
    let both = mix([(2, [0.2, 0.2, 0.4, 0.4]), (1, [0.1, 0.05])])
    check(both ≈ [0.3, 0.45], "miks: \(both)")

    // Én kilde alene skal komme uendret ut — ingen halvering.
    let alone = mix([(1, [0.5, -0.5])])
    check(alone ≈ [0.5, -0.5], "enkeltkilde: \(alone)")

    // Summen går over taket når begge kildene er høye; da klippes den.
    let loud = mix([(1, [0.9, -0.9]), (1, [0.9, -0.9])])
    check(loud ≈ [1, -1], "klipping: \(loud)")

    // Ulik lengde skal ikke kunne skje med driftskompensasjon på, men skal
    // uansett aldri lese utenfor det korteste bufferet.
    let ragged = mix([(1, [0.3, 0.3, 0.3]), (1, [0.2])])
    check(ragged ≈ [0.5], "korteste buffer styrer: \(ragged)")

    // Navnekollisjon når to opptak stoppes innen samme minutt.
    let dir = URL(fileURLWithPath: "/tmp")
    let now = Date()
    var taken: Set<String> = []
    let first = recordingURL(in: dir, at: now) { taken.contains($0.lastPathComponent) }
    taken.insert(first.lastPathComponent)
    let second = recordingURL(in: dir, at: now) { taken.contains($0.lastPathComponent) }
    check(first.lastPathComponent.hasPrefix("Opptak-") && first.pathExtension == "m4a",
          "opptaksnavn: \(first.lastPathComponent)")
    check(second.lastPathComponent == first.lastPathComponent.dropLast(4) + "-2.m4a",
          "kollisjon: \(second.lastPathComponent)")
}

/// Kjører `mixDown` mot en ekte AudioBufferList, slik IOProc-callbacken gjør.
private func mix(_ sources: [(channels: Int, samples: [Float])], capacity: Int = 8) -> [Float] {
    let list = AudioBufferList.allocate(maximumBuffers: sources.count)
    defer {
        for buf in list { buf.mData?.deallocate() }
        free(list.unsafeMutablePointer)
    }
    for (i, source) in sources.enumerated() {
        let mem = UnsafeMutablePointer<Float>.allocate(capacity: source.samples.count)
        mem.update(from: source.samples, count: source.samples.count)
        list[i] = AudioBuffer(mNumberChannels: UInt32(source.channels),
                              mDataByteSize: UInt32(source.samples.count * MemoryLayout<Float>.size),
                              mData: UnsafeMutableRawPointer(mem))
    }
    var out = [Float](repeating: 0, count: capacity)
    let frames = out.withUnsafeMutableBufferPointer {
        mixDown(list, into: $0.baseAddress!, capacity: capacity)
    }
    return Array(out.prefix(frames))
}

infix operator ≈: ComparisonPrecedence
private func ≈ (a: [Float], b: [Float]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-6 }
}

private func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok {
        FileHandle.standardError.write(Data("selfcheck FAILED: \(msg())\n".utf8))
        exit(1)
    }
}
