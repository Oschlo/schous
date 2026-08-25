import AVFoundation
import Foundation

/// `Schous --selfcheck` — verifiserer at parserne matcher ekte backend-output.
/// Linjene under er kopiert verbatim fra transcribe.py sine print/tqdm-kall.
@MainActor
func runSelfcheckAndExit() -> Never {
    segmentSelfcheck()
    recorderSelfcheck()
    updateSelfcheck()

    let job = TranscriptionJob()

    job.parseStdout(#"{"event": "step", "step": 1, "name": "lyd"}"#)
    check(job.step == 1, "steg 1, fikk \(job.step)")

    job.parseStdout(#"{"event": "step", "step": 2, "name": "diarization"}"#)
    job.parseStdout(#"{"event": "progress", "step": 2, "sub": "segmentation", "completed": 9, "total": 36}"#)
    check(job.step == 2 && job.done == 9 && job.total == 36 && job.detail == "segmentation",
          "steg 2 understeg: \(job.done)/\(job.total) \(job.detail)")
    check(job.fraction.map { abs($0 - 9.0 / 36.0) < 1e-9 } == true, "fraction i steg 2")

    // pyannote teller forbi taket på siste chunk — målt, ikke hypotetisk.
    job.parseStdout(#"{"event": "progress", "step": 2, "sub": "segmentation", "completed": 64, "total": 36}"#)
    check(job.fraction == 1, "fraction over 1: \(String(describing: job.fraction))")

    job.parseStdout(#"{"event": "diarized", "segments": 509, "speakers": 3}"#)
    check(job.total == 509 && job.speakerCount == 3,
          "diarized: \(job.total) \(job.speakerCount)")

    job.parseStdout(#"{"event": "step", "step": 3, "name": "språk per taler"}"#)
    job.parseStdout(#"{"event": "language", "completed": 1, "total": 3, "speaker": "SPEAKER_00", "language": "sv"}"#)
    check(job.step == 3 && job.detail == "taler 1/3 — SPEAKER_00: sv", "steg 3: \(job.detail)")

    job.parseStdout(#"{"event": "step", "step": 4, "name": "transkriberer"}"#)
    check(job.step == 4, "steg 4, fikk \(job.step)")

    job.parseStdout(#"{"event": "progress", "step": 4, "completed": 214, "total": 509, "speaker": "SPEAKER_00", "language": "no"}"#)
    check(job.done == 214 && job.total == 509, "steg 4: \(job.done)/\(job.total)")
    check(job.detail == "SPEAKER_00 (no)", "steg 4 detalj: \(job.detail)")
    check(job.fraction.map { abs($0 - 214.0 / 509.0) < 1e-9 } == true, "fraction i steg 4")

    // Ukjente felt og ukjente hendelser skal ignoreres, ikke velte parseren —
    // ellers kan ikke backend legge til noe uten å knekke en utgitt app.
    job.parseStdout(#"{"event": "noe-nytt", "step": 4, "hva": 1}"#)
    job.parseStdout(#"{"event": "progress", "step": 4, "completed": 215, "total": 509, "speaker": "SPEAKER_00", "language": "no", "nytt_felt": true}"#)
    check(job.done == 215, "ukjent felt forstyrret: \(job.done)")

    // Gjenopptagelse etter et avbrudd.
    job.parseStdout(#"{"event": "resume", "completed": 18, "total": 116}"#)
    check(job.detail == "gjenopptar 18 ferdige segmenter", "resume: \(job.detail)")

    // Fremdrift kommer nå bare fra stdout. huggingface_hub skriver sin egen
    // tqdm-bar til stderr, og den skal ikke kunne bevege noe som helst.
    job.parseStderr("Fetching 4 files: 100%|██████████| 4/4 [00:00<00:00, 2035.58it/s]")
    check(job.done == 215 && job.total == 509, "stderr forurenset: \(job.done)/\(job.total)")

    // sys.exit(melding) i backend går til stderr, ikke stdout.
    job.parseStderr("Fant ikke noe Hugging Face-token.")
    check(job.state == .failed("Fant ikke noe Hugging Face-token. Kjør "
                               + "`.venv/bin/hf auth login` i backend-mappen."), "hf-token-feil")

    // Miljøet subprosessene får: PATH satt, arvet HF_TOKEN borte. Sjekken sier
    // ingenting uten en kontroll som må bevege seg, så den krever at forelderen
    // faktisk har variabelen: `HF_TOKEN=x .build/debug/Schous --selfcheck`.
    let env = AppSettings.subprocessEnv
    check(env["PATH"] == AppSettings.subprocessPATH, "PATH i subprocessEnv: \(env["PATH"] ?? "nil")")
    if ProcessInfo.processInfo.environment["HF_TOKEN"] != nil {
        check(env["HF_TOKEN"] == nil, "arvet HF_TOKEN fulgte med til subprosessen")
    }

    // Output-formatering mot backendens write_outputs
    let segs = [Segment(start: 4.216, end: 7.905, speaker: "SPEAKER_00", language: "sv", text: "Hei.")]
    let dir = URL.temporaryDirectory.appending(path: "schous-selfcheck-\(getpid())")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! writeOutputs(segs, to: dir, base: "t", names: ["SPEAKER_00": "Hans Martin"])

    let txt = try! String(contentsOf: dir.appending(path: "t.txt"), encoding: .utf8)
    check(txt == "[00:00:04] Hans Martin (sv): Hei.\n", "txt: \(txt.debugDescription)")
    let srt = try! String(contentsOf: dir.appending(path: "t.srt"), encoding: .utf8)
    check(srt == "1\n00:00:04,216 --> 00:00:07,905\nHans Martin (sv): Hei.\n\n",
          "srt: \(srt.debugDescription)")
    // Standarden skriver alle tre. Uten denne kan .json-grenen bindes til feil
    // format uten at noen sjekk over merker det — de leser bare txt og srt.
    let all = try! FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    check(all == ["t.json", "t.srt", "t.txt"], "standard skriver ikke alle tre: \(all)")
    // Formatvalg: kun det som er bedt om skrives, og bare det.
    let only = URL.temporaryDirectory.appending(path: "schous-selfcheck-srt-\(getpid())")
    try! FileManager.default.createDirectory(at: only, withIntermediateDirectories: true)
    let written = try! writeOutputs(segs, to: only, base: "t", formats: [.srt])
    check(written.map(\.lastPathComponent) == ["t.srt"], "formatvalg: \(written)")
    let left = try! FileManager.default.contentsOfDirectory(atPath: only.path).sorted()
    check(left == ["t.srt"], "formatvalg skrev mer enn bedt om: \(left)")
    try? FileManager.default.removeItem(at: only)

    // Ikke `defer`: funksjonen ender i exit(), som ikke kjører defer-blokker — da
    // ble katalogen liggende igjen i temp etter hver eneste kjøring. Ryddes her,
    // der `dir` er ferdig brukt, så en senere feil ikke lekker den heller.
    // Feiler sjekkene over, står den igjen med vilje: da vil man se innholdet.
    try? FileManager.default.removeItem(at: dir)

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

/// Versjonssammenligningen i Update.swift. Feiler den, maser appen enten om en
/// oppdatering som ikke finnes, eller tier om en som gjør det.
private func updateSelfcheck() {
    check(isNewer("0.2.0", than: "0.1.0"), "0.2.0 > 0.1.0")
    check(!isNewer("0.1.0", than: "0.2.0"), "0.1.0 er ikke nyere enn 0.2.0")
    check(!isNewer("0.1.0", than: "0.1.0"), "lik versjon er ikke nyere")
    // Leksikografisk ville «0.10.0» < «0.9.0», og oppdateringen aldri blitt tilbudt.
    check(isNewer("0.10.0", than: "0.9.0"), "0.10.0 > 0.9.0")
    // Ulik lengde: 1.1 er 1.1.0.
    check(isNewer("1.1", than: "1.0.9"), "1.1 > 1.0.9")
    check(!isNewer("1.0", than: "1.0.0"), "1.0 er ikke nyere enn 1.0.0")
    // git describe mellom to tagger: bygget er nyere enn taggen, ikke eldre.
    check(!isNewer("0.2.0", than: "0.2.0-3-gf84a688"), "dev-build etter taggen skal ikke mases om")
    check(isNewer("0.3.0", than: "0.2.0-3-gf84a688"), "ny tagg slår dev-build")
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

    // En tapp uten lydopptakstillatelse leverer nuller. Stillhetsvarselet i
    // `Sink.render` hviler på at de kommer uendret gjennom miksen — summeres de
    // til noe annet enn null, slutter varselet å utløses.
    let muted = mix([(2, [0, 0, 0, 0])])
    check(muted ≈ [0, 0], "digital stillhet: \(muted)")
    check(!muted.contains { $0 != 0 }, "stillhetsvarselet ville ikke utløst")

    // Stillhetsvarselet. Hele verdien ligger i at det *ikke* slår ut når
    // stillheten er forventet — et varsel som ofte tar feil blir ignorert den
    // dagen det gjelder.
    check(Recorder.systemWarning(silentFor: 30, outputIsRunning: false) == nil,
          "stille tapp uten en eneste utgang i gang skal tie")
    check(Recorder.systemWarning(silentFor: 30, outputIsRunning: true) != nil,
          "stille tapp mens en utgang er i gang er verdt å nevne")
    check(Recorder.systemWarning(silentFor: Recorder.systemGrace - 0.25,
                                 outputIsRunning: true) == nil,
          "ikke mas før nådetiden er ute")
    // `outputIsRunning` beviser ikke at det spilles av lyd — Chrome står på hele
    // tida. Varselet skal derfor stille spørsmålet, ikke felle dommen.
    check(Recorder.systemWarning(silentFor: 30, outputIsRunning: true)?
            .contains("Spilles det av lyd nå") == true,
          "systemvarselet skal ikke påstå at tillatelsen mangler")

    check(Recorder.micWarning(silentFor: 60, mic: .off) == nil,
          "uten mikrofon er stillhet på mikrofonsporet ikke en feil")
    check(Recorder.micWarning(silentFor: 60, mic: .live) != nil,
          "en mikrofon som ikke leverer noe skal si fra")
    check(Recorder.micWarning(silentFor: Recorder.micGrace - 0.25, mic: .live) == nil,
          "ikke mas før nådetiden er ute")
    // Tilgang gitt, men opptakeren startet ikke: før dette så det ut som `.off`,
    // og da tidde varselet resten av opptaket mens måleren sto på null.
    check(Recorder.micWarning(silentFor: 0, mic: .failed) != nil,
          "en mikrofon som ikke startet skal si fra med en gang")

    // Svikter begge, skal begge stå der — ikke bare den som kom først.
    let begge = Recorder.warning(systemSilentFor: 30, outputIsRunning: true,
                                 micSilentFor: 60, mic: .live) ?? ""
    check(begge.contains("Systemlyden") && begge.contains("Mikrofonen"),
          "to døde kilder skal gi to varsler: \(begge)")
    check(Recorder.warning(systemSilentFor: 30, outputIsRunning: false,
                           micSilentFor: 0, mic: .live) == nil,
          "ingen døde kilder, ingen varsel")

    // Måleren: gulvet er -60 dB, taket 0.
    check(Recorder.scale(db: -160) == 0, "digital stillhet er tomt utslag")
    check(Recorder.scale(db: -60) == 0, "gulvet er tomt utslag")
    check(Recorder.scale(db: 0) == 1, "0 dBFS er fullt utslag")
    check(abs(Recorder.scale(db: -30) - 0.5) < 1e-6, "midt på: \(Recorder.scale(db: -30))")
    check(Recorder.scale(db: 6) == 1, "over taket klemmes")

    // Rydding av råfiler etter miksing. Feiler miksingen, er scratchfilene det
    // eneste som er igjen av opptaket — da slettes ingen av dem.
    let sys = URL(fileURLWithPath: "/tmp/schous-system.m4a")
    let mic = URL(fileURLWithPath: "/tmp/schous-mic.m4a")
    check(Recorder.scratchToRemove(exit: 0, system: sys, microphone: mic) == [sys, mic],
          "vellykket miks rydder begge råfilene")
    check(Recorder.scratchToRemove(exit: 0, system: sys, microphone: nil) == [sys],
          "uten mikrofon ryddes bare systemlyden")
    // 127 = env fant ikke ffmpeg. Begge filene er intakte; ingen skal slettes.
    check(Recorder.scratchToRemove(exit: 127, system: sys, microphone: mic).isEmpty,
          "ffmpeg mangler: behold begge råfilene")
    check(Recorder.scratchToRemove(exit: 1, system: sys, microphone: mic).isEmpty,
          "feilet miks sletter ingen input")

    // Bergingen, med ekte filer: den halvskrevne miksen skal bort, og begge
    // råfilene skal ende i utmappa med navn brukeren kan finne igjen.
    let fm = FileManager.default
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "schous-selfcheck-\(UUID().uuidString)")
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }

    let rawSystem = tmp.appending(path: "schous-system-raa.m4a")
    let rawMic = tmp.appending(path: "schous-mic-raa.m4a")
    let dest = tmp.appending(path: "Opptak-2026-08-11-1432.m4a")
    for (url, body) in [(rawSystem, "sys"), (rawMic, "mic"), (dest, "halvskrevet miks")] {
        try? Data(body.utf8).write(to: url)
    }

    let kept = Recorder.rescue(system: rawSystem, microphone: rawMic, into: dest)
    check(!fm.fileExists(atPath: dest.path), "halvskrevet miks fjernet")
    check(kept == tmp.appending(path: "Opptak-2026-08-11-1432-systemlyd.m4a"),
          "systemlyden berget til utmappa: \(kept.lastPathComponent)")
    check((try? Data(contentsOf: kept)) == Data("sys".utf8), "berget fil har innholdet i behold")
    check(fm.fileExists(atPath: tmp.appending(path: "Opptak-2026-08-11-1432-mikrofon.m4a").path),
          "mikrofonsporet berget, ikke slettet")
    check(!fm.fileExists(atPath: rawSystem.path) && !fm.fileExists(atPath: rawMic.path),
          "råfilene flyttet ut av temp")

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
