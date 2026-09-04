import AVFoundation
import Combine
import Foundation

/// `Schous --selfcheck` — verifiserer at parserne matcher ekte backend-output.
/// Linjene under er kopiert verbatim fra transcribe.py sine print/tqdm-kall.
@MainActor
func runSelfcheckAndExit() -> Never {
    segmentSelfcheck()
    recorderSelfcheck()
    updateSelfcheck()
    summarizerSelfcheck()
    summarizerNetworkSelfcheck()
    estimatesSelfcheck()
    documentSelfcheck()

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
    check(job.step == 3 && job.detail == "taler 1 av 3 · SPEAKER_00: sv", "steg 3: \(job.detail)")

    job.parseStdout(#"{"event": "step", "step": 4, "name": "transkriberer"}"#)
    check(job.step == 4, "steg 4, fikk \(job.step)")
    // Navnet i UI sier hva brukeren får; backendens ord står i Detaljer.
    check(TranscriptionJob.stepNames[2] == "Finner talere" && job.stepLabel == "Transkriberer",
          "stegnavn på norsk: \(job.stepLabel)")
    check(TranscriptionJob.technicalNames[2] == "diarization", "teknisk navn til Detaljer")

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
    check(job.state == .failed(AppSettings.hfTokenMissingMessage), "hf-token-feil")

    // Miljøet subprosessene får: PATH satt, alle arvede token-variabler borte.
    //
    // Sjekken setter variablene selv i stedet for å be om
    // `HF_TOKEN=x … --selfcheck`. Den betingede forma hoppet over seg selv i et
    // rent skall, og et grønt «selfcheck ok» skilte da ikke «verifisert» fra
    // «aldri kjørt» — samme falske grønt som strippingen finnes for å fjerne.
    // setenv er synlig for ProcessInfo på Darwin; målt: nil → satt → nil.
    for key in AppSettings.hfEnvKeys { setenv(key, "arvet-fra-skallet", 1) }
    let env = AppSettings.subprocessEnv
    check(env["PATH"] == AppSettings.subprocessPATH, "PATH i subprocessEnv: \(env["PATH"] ?? "nil")")
    // Hele lista, ikke bare den første: huggingface_hub faller tilbake fra
    // HF_TOKEN til HUGGING_FACE_HUB_TOKEN, og HF_TOKEN_PATH/HF_HOME flytter fila.
    for key in AppSettings.hfEnvKeys {
        check(env[key] == nil, "arvet \(key) fulgte med til subprosessen")
    }
    // Arver fortsatt resten: en «opprydding» til et eksplisitt minimalt miljø
    // ville tatt HOME med seg, og da finner get_token() aldri
    // ~/.cache/huggingface/token — den eneste token-kilden appen har igjen.
    check(env["HOME"] == ProcessInfo.processInfo.environment["HOME"],
          "subprocessEnv arver ikke lenger foreldremiljøet")
    for key in AppSettings.hfEnvKeys { unsetenv(key) }

    // Strippingen over og kommandoen appen anbefaler må være enige. Hver
    // variabel som flytter *fila* må også være unset i hfLoginCommand — ellers
    // skriver den dokumenterte kommandoen tokenet dit appen nettopp fjernet
    // veien til, og rådet virker ikke uansett hvor mange ganger det følges.
    // Måling bak formen (huggingface_hub.constants):
    //
    //     ingen satt              -> ~/.cache/huggingface/token
    //     HF_HOME=/tmp/hfhome     -> /tmp/hfhome/token
    //     HF_TOKEN_PATH=/tmp/tok  -> /tmp/tok
    for key in AppSettings.hfEnvKeys where key.hasSuffix("_HOME") || key.hasSuffix("_PATH") {
        check(AppSettings.hfLoginCommand.contains("-u \(key)"),
              "login-kommandoen lar \(key) stå: \(AppSettings.hfLoginCommand)")
    }

    // Rekkefølgen mellom stderr og prosess-slutt, kjørt mot en ekte prosess.
    //
    // To feil satt her. terminationHandler og readabilityHandler køer hver sin
    // Task { @MainActor } og ingenting rekkefølger dem, så tapte stderr
    // kappløpet var `log` tom når finish() spurte lastMeaningfulError(). Og
    // EOF-grenen i attach droppet det som lå igjen i bufferet, altså enhver
    // siste linje uten avsluttende linjeskift.
    //
    // `printf` uten \n treffer begge på én gang: linja finnes bare i bufferet
    // ved EOF, og den må ha nådd parseStderr før finish konkluderer. Kommer den
    // ikke fram, faller finish() tilbake på «Python avsluttet med kode 1».
    let raceJob = TranscriptionJob()
    let sh = Process()
    sh.executableURL = URL(fileURLWithPath: "/bin/sh")
    sh.arguments = ["-c", "printf 'Fant ikke noe Hugging Face-token.' >&2; exit 1"]
    raceJob.supervise(sh)
    let raceDeadline = Date().addingTimeInterval(10)
    var settled = false
    while !settled, Date() < raceDeadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        if case .failed = raceJob.state { settled = true }
    }
    check(raceJob.state == .failed(AppSettings.hfTokenMissingMessage),
          "kappløp/EOF: \(raceJob.state)")

    // Fristen i capture: en prosess som aldri svarer må gi opp, ikke henge.
    // Kontrollen er /bin/sleep, som med sikkerhet overlever fristen.
    //
    // Begge sjekkene trengs, og det er målt: med drepingen fjernet står
    // meldingen fortsatt «Ga opp etter 1 s» — forløpt tid har jo passert
    // fristen — mens prosessen i virkeligheten fikk sove ferdig. Bare
    // tidssjekken fanget det:
    //
    //     uten terminate()   FAILED: frist brukte 5.07 s — drepte ikke prosessen
    //     med terminate()    selfcheck ok, hele kjøringen på 1,56 s
    //
    // En sjekk på meldingen alene ville altså vært grønn på en frist som ikke
    // gjorde noen ting.
    let hangStart = Date()
    let hung = AppSettings.capture(URL(fileURLWithPath: "/bin/sleep"), args: ["5"],
                                   cwd: URL.temporaryDirectory, timeout: 1)
    let hangElapsed = Date().timeIntervalSince(hangStart)
    check(hung.hasPrefix("Ga opp etter 1 s"), "frist ga ikke opp: \(hung.prefix(60))")
    check(hangElapsed < 3, "frist brukte \(hangElapsed) s — drepte ikke prosessen")

    // Avbryt: en sjekk som står og venter må kunne stoppes fra knappen, ikke
    // bare av fristen. Samme kontroll som over — /bin/sleep overlever alt
    // annet enn å bli drept.
    final class Box: @unchecked Sendable { var p: Process? }
    let box = Box()
    let cancelStart = Date()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { box.p?.terminate() }
    let cancelled = AppSettings.capture(URL(fileURLWithPath: "/bin/sleep"), args: ["5"],
                                        cwd: URL.temporaryDirectory, timeout: 10) { box.p = $0 }
    check(Date().timeIntervalSince(cancelStart) < 3, "avbrudd drepte ikke prosessen")
    check(cancelled.hasPrefix("Prosessen ble drept"), "avbrudd: \(cancelled.prefix(40))")

    // Og den må ikke slå til på noe som svarer i tide, ellers er den bare en
    // ny måte å feile på.
    let quick = AppSettings.capture(URL(fileURLWithPath: "/bin/echo"), args: ["hei"],
                                    cwd: URL.temporaryDirectory, timeout: 10)
    check(quick == "hei", "rask kommando kom ikke rent gjennom: \(quick.debugDescription)")

    // Output-formatering mot backendens write_outputs
    let segs = [Segment(start: 4.216, end: 7.905, speaker: "SPEAKER_00", language: "sv", text: "Hei.")]
    let dir = URL.temporaryDirectory.appending(path: "schous-selfcheck-\(getpid())")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! writeOutputs(segs, to: dir, base: "t", names: ["SPEAKER_00": "Hans Martin"])

    let txt = try! String(contentsOf: dir.appending(path: "t.txt"), encoding: .utf8)
    check(txt == "[00:00:04] Hans Martin (sv): Hei.\n", "txt: \(txt.debugDescription)")

    // Prompten til referatet bruker samme rendering som TXT-eksporten. Én
    // funksjon, ellers driver de fra hverandre uten at noen merker det.
    check(transcriptText(segs, names: ["SPEAKER_00": "Hans Martin"]) == txt,
          "transcriptText avviker fra txt-eksporten")

    // «Åpne resultat»: ferdig output i jobbmappa uten partial-fil = kan lastes
    // uten å transkribere på nytt. Med partial-fil er forrige kjøring ikke
    // ferdig, og da skal Start få gjenoppta den.
    let fakeInput = dir.appending(path: "selfcheck-input.m4a")
    let fakeJob = TranscriptionJob.jobDirectory(for: fakeInput)
    try! FileManager.default.createDirectory(at: fakeJob.appending(path: "output"), withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: fakeJob.appending(path: "work"), withIntermediateDirectories: true)
    check(TranscriptionJob.finishedOutput(for: fakeInput) == nil, "ingen output skal gi nil")
    try! JSONEncoder().encode(segs).write(to: fakeJob.appending(path: "output/selfcheck-input.json"))
    check(TranscriptionJob.finishedOutput(for: fakeInput) != nil, "ferdig output ble ikke funnet")
    try! Data().write(to: fakeJob.appending(path: "work/selfcheck-input.partial.jsonl"))
    check(TranscriptionJob.finishedOutput(for: fakeInput) == nil, "partial-fil skal bety ikke ferdig")
    try! FileManager.default.removeItem(at: fakeJob.appending(path: "work/selfcheck-input.partial.jsonl"))
    let loaded = TranscriptionJob()
    loaded.loadFinished(input: fakeInput)
    check(loaded.state == .done && loaded.segments.count == 1 && loaded.base == "selfcheck-input",
          "loadFinished: \(loaded.state) \(loaded.segments.count) \(loaded.base)")
    let info = TranscriptionJob.finishedInfo(for: fakeInput)
    check(info?.segments == 1 && info.map { Date().timeIntervalSince($0.modified) < 60 } == true,
          "finishedInfo: \(String(describing: info))")
    try? FileManager.default.removeItem(at: fakeJob)

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

/// Dokumentet: søk (⌘F), Markdown-rendering (#41) og filnavn med tittel (#42).
private func documentSelfcheck() {
    let seg = Segment(start: 1, end: 2, speaker: "SPEAKER_00", language: "no", text: "Møtet begynte på tirsdag.")
    check(matches(seg, query: ""), "tom query treffer alt")
    check(matches(seg, query: "MØTET"), "søket er ufølsomt for store bokstaver")
    // «å» er a + ring og normaliseres; «ø» er en egen bokstav og gjør det ikke.
    check(matches(seg, query: "pa tirsdag"), "søket er ufølsomt for diakritika")
    check(!matches(seg, query: "onsdag"), "ikke-treff skal ikke treffe")

    // Det malene faktisk produserer. <aside> fra Notion-eksporten hoppes over,
    // og en avsluttende tomlinje blir ikke en .blank.
    let md = "# Tittel\n\n## Del\n- punkt\n- [ ] åpen\n- [x] gjort\n1. første\nVanlig **fet** tekst\n<aside>hopp</aside>\n"
    let blocks = MarkdownBlock.parse(md)
    check(blocks == [.heading(1, "Tittel"), .blank, .heading(2, "Del"), .bullet("punkt"), .task(false, "åpen"),
                     .task(true, "gjort"), .numbered(1, "første"), .paragraph("Vanlig **fet** tekst")],
          "markdown-blokker: \(blocks)")
    check(MarkdownBlock.parse("").isEmpty && MarkdownBlock.parse("\n\n").isEmpty, "tomt dokument gir ingen blokker")

    check(filenameSafe("Coast: intro / AI") == "Coast- intro - AI", filenameSafe("Coast: intro / AI"))
    check(filenameSafe("  ") == "", "bare mellomrom er tomt")
    var comps = DateComponents(year: 2026, month: 9, day: 3, hour: 12)
    comps.timeZone = .current
    let d = Calendar(identifier: .gregorian).date(from: comps)!
    check(outputBase(title: "Coast intro om AI-strategi", date: d, fallback: "Opptak-x") == "2026-09-03 Coast intro om AI-strategi",
          outputBase(title: "Coast intro om AI-strategi", date: d, fallback: "Opptak-x"))
    check(outputBase(title: " ", date: d, fallback: "Opptak-x") == "Opptak-x", "tom tittel = kildefilas navn")
}

/// Estimatene i #39: rater fra forrige kjøring, i en egen defaults-suite så
/// selfcheck aldri rører brukerens tall.
private func estimatesSelfcheck() {
    let suite = "co.oschlo.schous.selfcheck-\(getpid())"
    let d = UserDefaults(suiteName: suite)!
    defer { d.removePersistentDomain(forName: suite) }
    check(Estimates.stepEstimate(2, audioSeconds: 600, in: d) == nil, "uten historikk skal steg-estimatet være nil")
    // 10 min lyd tok 4 min i steg 2 → 0,4 s per lydsekund → 20 min lyd anslås til 8 min.
    Estimates.recordStep(2, seconds: 240, audioSeconds: 600, in: d)
    check(Estimates.stepEstimate(2, audioSeconds: 1200, in: d).map { abs($0 - 480) < 1e-6 } == true,
          "steg-estimat: \(String(describing: Estimates.stepEstimate(2, audioSeconds: 1200, in: d)))")
    check(Estimates.stepEstimate(4, audioSeconds: 1200, in: d) == nil, "steg 4 har ingen historikk ennå")
    // Uten lydlengde finnes ingen rate å lagre.
    Estimates.recordStep(3, seconds: 5, audioSeconds: 0, in: d)
    check(Estimates.stepEstimate(3, audioSeconds: 100, in: d) == nil, "rate uten lydlengde skal ikke lagres")

    check(Estimates.summaryEstimate(model: "m", promptChars: 1000, in: d) == nil,
          "uten historikk skal referat-estimatet være nil")
    // 11 s lasting + 297 s prefill på 40 000 tegn (målt i #39) → 20 000 tegn anslås til 11 + 148,5.
    Estimates.recordSummary(model: "m", loadSeconds: 11, promptSeconds: 297, promptChars: 40_000, in: d)
    check(Estimates.summaryEstimate(model: "m", promptChars: 20_000, in: d).map { abs($0 - 159.5) < 1e-6 } == true,
          "referat-estimat: \(String(describing: Estimates.summaryEstimate(model: "m", promptChars: 20_000, in: d)))")
    check(Estimates.summaryEstimate(model: "annen", promptChars: 20_000, in: d) == nil, "raten er per modell")

    check(Estimates.describe(20) == "under ett minutt", Estimates.describe(20))
    check(Estimates.describe(200) == "ca. 3 min", Estimates.describe(200))
    check(Estimates.describe(4200) == "ca. 1 t 10 min", Estimates.describe(4200))
}

/// Referat: plassholdere, slug og seeding. Selve nettkallet testes i
/// summarizerNetworkSelfcheck mot en ekte socket.
@MainActor
private func summarizerSelfcheck() {
    // Alle fire byttes, og ingen krøllparentes står igjen — en glemt
    // plassholder ville gått rett til modellen som tekst.
    let p = Summary.prompt("MAL", language: "Norwegian", context: "KTX",
                           transcript: "[00:00:04] A (no): Hei.\n", using: Summary.defaultPrompt)
    check(p.contains("MAL") && p.contains("Norwegian") && p.contains("KTX")
          && p.contains("[00:00:04] A (no): Hei.\n"), "prompt mangler en verdi:\n\(p)")
    check(!p.contains("{") && !p.contains("}"), "plassholder står igjen:\n\(p)")
    // En verdi som selv inneholder «{transcript}» (mulig i en brukerskrevet
    // mal) skal ikke skannes på nytt av et senere bytte — kjedede
    // .replacingOccurrences ville gjort nettopp det.
    let literal = Summary.prompt("x {transcript} y", language: "English", context: "c",
                                 transcript: "T", using: Summary.defaultPrompt)
    check(literal.contains("x {transcript} y"), "substituert innhold ble skannet på nytt:\n\(literal)")
    // Tom kontekst blir «(none)», ikke en tom linje modellen kan tolke som noe.
    check(Summary.prompt("m", language: "English", context: "", transcript: "t",
                         using: Summary.defaultPrompt).contains("(none)"),
          "tom kontekst skal bli (none)")
    check(SummaryLanguage.norwegian.promptValue == "Norwegian"
          && SummaryLanguage.english.promptValue == "English", "språkverdier")

    check(Templates.slug("Customer Call") == "customer-call", "slug: \(Templates.slug("Customer Call"))")
    check(Templates.slug("Stand-Up") == "stand-up", "slug: \(Templates.slug("Stand-Up"))")
    check(Templates.slug("Discovery interview") == "discovery-interview", "slug med små bokstaver")
    check(Templates.slug("A/B: test") == "a-b--test", "slug med tegn som ikke kan stå i filnavn: \(Templates.slug("A/B: test"))")

    // Seeding: kopierer bare når mappa ikke finnes. En tom mappe er et valg.
    let root = URL.temporaryDirectory.appending(path: "schous-templates-\(getpid())")
    let seeds = root.appending(path: "seeds")
    try! FileManager.default.createDirectory(at: seeds, withIntermediateDirectories: true)
    try! "# Stand-Up\n".write(to: seeds.appending(path: "Stand-Up.md"), atomically: true, encoding: .utf8)
    let dir = root.appending(path: "templates")
    Templates.seedIfMissing(into: dir, from: seeds)
    check(Templates.list(in: dir).map(\.lastPathComponent) == ["Stand-Up.md"],
          "seeding kopierte ikke: \(Templates.list(in: dir))")
    try! FileManager.default.removeItem(at: dir.appending(path: "Stand-Up.md"))
    Templates.seedIfMissing(into: dir, from: seeds)
    check(Templates.list(in: dir).isEmpty, "tom mappe ble seedet på nytt")
    try? FileManager.default.removeItem(at: root)
}

/// Referat: NDJSON-parseren mot ordrette ollama-linjer (0.33.3), og klienten
/// mot en ekte socket via `nc -l`. Stubb i prosess ville ikke bevist at
/// timeoutIntervalForRequest faktisk utløser.
@MainActor
private func summarizerNetworkSelfcheck() {
    let thinking = #"{"model":"qwen3.8:27b-mlx","created_at":"2026-09-04T09:17:09.179986Z","message":{"role":"assistant","content":"","thinking":"The"},"done":false}"#
    let content = #"{"model":"qwen3.8:27b-mlx","created_at":"2026-09-04T09:16:35.191059Z","message":{"role":"assistant","content":"hei"},"done":false}"#
    let done = #"{"model":"qwen3.8:27b-mlx","created_at":"2026-09-04T09:16:35.31501Z","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","total_duration":7144189292,"load_duration":6040992125,"prompt_eval_count":16,"prompt_eval_cached_count":0,"prompt_eval_duration":683572250,"eval_count":1,"eval_duration":417508667}"#

    // Tenking er ikke tekst. Slipper den inn, står modellens grubling i referatet.
    let t = Summarizer.parse(thinking)
    check(t?.content == "" && t?.done == false, "thinking-bit: \(String(describing: t))")
    let c = Summarizer.parse(content)
    check(c?.content == "hei" && c?.done == false, "content-bit: \(String(describing: c))")
    let d = Summarizer.parse(done)
    check(d?.done == true && d?.promptEvalCount == 16, "sluttobjekt: \(String(describing: d))")
    // Varighetene i sluttobjektet er nanosekunder; det er dem anslaget bygger på (#39).
    check(d?.loadSeconds.map { abs($0 - 6.040992125) < 1e-9 } == true
          && d?.promptEvalSeconds.map { abs($0 - 0.68357225) < 1e-9 } == true,
          "varigheter fra sluttobjektet: \(String(describing: d))")
    check(Summarizer.parse("ikke json") == nil, "støy skal gi nil, ikke krasj")

    // Klienten mot en ekte prosess. Én forbindelse per nc; hvert tilfelle får
    // sin egen port.
    let out = URL.temporaryDirectory.appending(path: "schous-summary-\(getpid()).md")
    defer { try? FileManager.default.removeItem(at: out) }

    // 1. Normal strøm: tekst = summen av content, aldri thinking; fila skrives.
    //    `reqFile` fanger requesten nc faktisk mottok, så think:false verifiseres
    //    på det som gikk over ledningen, ikke bare det klienten mente å sende.
    let reqFile = URL.temporaryDirectory.appending(path: "schous-req-\(getpid()).txt")
    defer { try? FileManager.default.removeItem(at: reqFile) }
    let suite = "co.oschlo.schous.selfcheck-summary-\(getpid())"
    let store = UserDefaults(suiteName: suite)!
    defer { store.removePersistentDomain(forName: suite) }
    let s1 = Summarizer(timeout: 10)
    s1.estimateStore = store
    var s = summarize(port: 11501, response: http(200, [thinking, content, done]), out: out, reqFile: reqFile,
                      summarizer: s1)
    check(s.text == "hei", "strøm: \(s.text.debugDescription) state=\(s.state)")
    check(s.state == .done(out), "strøm-state: \(s.state)")
    check(s.phase == .idle, "fase etter ferdig: \(s.phase)")
    // Neste kjøring mot samme modell har et anslag: 6,04 s lasting + 0,68 s på promptens ene tegn.
    check(Estimates.summaryEstimate(model: "m", promptChars: 1, in: store).map { abs($0 - 6.724564375) < 1e-6 } == true,
          "raten ble ikke lagret: \(String(describing: Estimates.summaryEstimate(model: "m", promptChars: 1, in: store)))")
    check((try? String(contentsOf: out, encoding: .utf8)) == "hei", "fila ble ikke skrevet")
    check((try? String(contentsOf: reqFile, encoding: .utf8))?.contains(#""think":false"#) == true,
          "think:false gikk ikke over ledningen")

    // 2. Tomt svar er sin egen feil — ikke «ollama nede». Det var feilslutningen
    //    målingen i #30 selv gjorde først.
    s = summarize(port: 11502, response: http(200, [done]), out: out)
    check({ if case .failed(let m) = s.state { return m.contains("svarte tomt") }; return false }(),
          "tomt svar: \(s.state)")

    // 3. Ukjent modell: 404 med ollamas egen feiltekst, og rådet er `ollama pull`.
    s = summarize(port: 11503, response: http(404, [#"{"error":"model 'finnes-ikke:1b' not found"}"#]), out: out)
    check({ if case .failed(let m) = s.state { return m.contains("ollama pull") }; return false }(),
          "404: \(s.state)")

    // 4. Ingen server: forbindelse nektet, rådet er `ollama serve`.
    s = summarize(port: 11504, response: nil, out: out)
    check({ if case .failed(let m) = s.state { return m.contains("ollama serve") }; return false }(),
          "nektet: \(s.state)")

    // 5. Fristen. Serveren sender én bit og tier. Begge sjekkene trengs:
    //    meldingen alene er grønn på en frist som aldri drepte noe, bare
    //    tidssjekken avslører at kallet fikk stå — se «Sjekkene i
    //    Innstillinger har en frist».
    let t0 = Date()
    s = summarize(port: 11505, response: http(200, [content]) , hold: 10, out: out, timeout: 1)
    let elapsed = Date().timeIntervalSince(t0)
    check({ if case .failed(let m) = s.state { return m.contains("Ingen svar på 1 s") }; return false }(),
          "frist: \(s.state)")
    check(elapsed < 4, "frist brukte \(elapsed) s — utløste ikke")

    // 6. Kansellering midt i en strøm: .idle, ingen fil skrevet. Går gjennom
    //    startServer direkte (ikke summarize) fordi vi må avbryte før den ellers
    //    ville ventet til done/failed/frist.
    let outCancel = URL.temporaryDirectory.appending(path: "schous-summary-cancel-\(getpid()).md")
    defer { try? FileManager.default.removeItem(at: outCancel) }
    let server6 = startServer(port: 11506, response: http(200, [content]), hold: 10, reqFile: nil)
    let s6 = Summarizer(timeout: 10)
    s6.estimateStore = store
    s6.run(prompt: "p q r", model: "m", baseURL: URL(string: "http://127.0.0.1:11506")!, writeTo: [outCancel])
    // Før noe er kommet: venter, med anslaget fra kjøring 1, og ordtallet fra prompten.
    check({ if case .waiting(let e) = s6.phase { return e != nil }; return false }(), "fase før første pakke: \(s6.phase)")
    check(s6.promptWords == 3, "ordtall: \(s6.promptWords)")
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    // Én content-bit er kommet: strømmer.
    check(s6.phase == .streaming, "fase etter første pakke: \(s6.phase)")
    s6.cancel()
    check(s6.phase == .idle, "fase etter avbrudd: \(s6.phase)")
    // Sjekkes uten å pumpe RunLoop igjen: cancel() skal sette .idle synkront,
    // ikke overlate det til den kansellerte Task-ens catch-gren, som først får
    // kjøre neste gang MainActor-køen tømmes.
    check(s6.state == .idle, "kansellert: \(s6.state)")
    check(!FileManager.default.fileExists(atPath: outCancel.path), "kansellert skrev likevel fil")
    // …og etter at den kansellerte Task-en har fått avvikle: fortsatt .idle,
    // fortsatt ingen fil, og defer-flushen i stream() la ikke rest i `text`.
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check(s6.state == .idle, "kansellert, etter avvikling: \(s6.state)")
    check(!FileManager.default.fileExists(atPath: outCancel.path), "kansellert skrev fil etter avvikling")
    server6.terminate()

    // 7. Strøm som slutter uten done: nc lukker pent etter én bit. Det er slik
    //    en runner som dør ser ut utenfra, og det må ikke bli «Referat lagret».
    try? FileManager.default.removeItem(at: out)
    s = summarize(port: 11507, response: http(200, [content]), out: out)
    check({ if case .failed(let m) = s.state { return m.contains("brutt") }; return false }(),
          "EOF uten done: \(s.state)")
    check(!FileManager.default.fileExists(atPath: out.path), "EOF uten done skrev fil")

    // 8. Feilen som egen NDJSON-linje midt i en 200-strøm — det ollama gjør
    //    når runneren dør etter at statuslinja er sendt.
    s = summarize(port: 11508, response: http(200, [content, #"{"error":"runner process has terminated"}"#]), out: out)
    check({ if case .failed(let m) = s.state { return m.contains("runner process") }; return false }(),
          "feil i strøm: \(s.state)")
    check(!FileManager.default.fileExists(atPath: out.path), "feil i strøm skrev fil")

    // 9. Strupet publisering: 200 linjer i én pakke skal gi en håndfull
    //    oppdateringer av `text`, ikke 200. Målt 2026-09-04 før strupingen:
    //    appen brukte ~7 min på 100 % CPU etter at ollama var ferdig, ett
    //    re-render av hele editoren per linje.
    var publishes = 0
    let s9 = Summarizer(timeout: 10)
    let sub = s9.$text.dropFirst().sink { _ in publishes += 1 }
    s = summarize(port: 11509, response: http(200, Array(repeating: content, count: 200) + [done]),
                  out: out, summarizer: s9)
    check(s.text == String(repeating: "hei", count: 200), "200 linjer: \(s.text.count) tegn")
    check(publishes < 10, "struping: \(publishes) publiseringer for 200 linjer")
    sub.cancel()
}

/// Rå HTTP-respons for nc. NDJSON-linjer, `\n`-terminert som ollama gjør.
private func http(_ status: Int, _ lines: [String]) -> String {
    let body = lines.joined(separator: "\n") + "\n"
    return "HTTP/1.1 \(status) OK\r\nContent-Type: application/x-ndjson\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
}

/// Starter `nc -l` på `port` som svarer med `response`. `hold` = sekunder nc
/// lever videre etter å ha skrevet, uten å lukke — det er slik en modell som
/// henger ser ut fra utsiden. `reqFile`, hvis satt, får requesten nc mottok
/// (nc ekko-er alt den leser til sin egen stdout); ellers går den til
/// /dev/null — unredirected ville en grønn kjøring spamme rå HTTP-requester.
private func startServer(port: Int, response: String, hold: Int, reqFile: URL?) -> Process {
    // Content-Length settes med vilje *høyere* enn body når vi holder: ellers
    // ser URLSession en komplett respons og fristen har ingenting å vente på.
    let padded = hold > 0
        ? response.replacingOccurrences(of: "Content-Length: ", with: "Content-Length: 9")
        : response
    // Uten `hold` lever nc et halvt sekund etter svaret likevel. Lukker den i
    // det stdin når EOF, ligger requesten ofte ulest i mottaksbufferet, og
    // close() på en socket med ulest data gir RST, ikke FIN — URLSession
    // kaster da responsen den alt har fått. Målt 2026-09-04 på M1 Pro med
    // `sleep 0`: 7/25 runder «The network connection was lost»; curl mot
    // samme nc ser det ikke (0/30), så testen må kjøres med appens klient.
    let script = "printf '%s' \"$1\" ; sleep \(hold > 0 ? "\(hold)" : "0.5")"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "(\(script)) | /usr/bin/nc -l 127.0.0.1 \(port)", "sh", padded]
    if let reqFile {
        FileManager.default.createFile(atPath: reqFile.path, contents: nil)
        p.standardOutput = try? FileHandle(forWritingTo: reqFile)
    } else {
        p.standardOutput = FileHandle.nullDevice
    }
    p.standardError = FileHandle.nullDevice
    try! p.run()
    // nc trenger et øyeblikk på å lytte. Poll i stedet for å gjette.
    let until = Date().addingTimeInterval(3)
    while Date() < until, !listening(port) { usleep(20_000) }
    return p
}

/// Starter en server via `startServer` (nil `response` = ingen server), kjører
/// Summarizer mot den og pumper RunLoop til den konkluderer.
@MainActor
private func summarize(port: Int, response: String?, hold: Int = 0, out: URL,
                       timeout: TimeInterval = 10, reqFile: URL? = nil,
                       summarizer: Summarizer? = nil) -> Summarizer {
    let server = response.map { startServer(port: port, response: $0, hold: hold, reqFile: reqFile) }
    let s = summarizer ?? Summarizer(timeout: timeout)
    s.run(prompt: "p", model: "m", baseURL: URL(string: "http://127.0.0.1:\(port)")!, writeTo: [out])
    let deadline = Date().addingTimeInterval(timeout + 8)
    while s.state == .running || s.state == .idle, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    server?.terminate()
    return s
}

/// `nc -z` would work as a probe too, but it completes a real TCP handshake —
/// against `nc -l` (no `-k`, one connection only) that handshake *is* the
/// one connection, so the harness's own poll steals the accept before the
/// real request ever gets one. Measured: with `nc -z` polling, `curl` right
/// after gets `Connection refused`. `lsof` inspects listen state without
/// connecting.
private func listening(_ port: Int) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus == 0
}

private func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok {
        FileHandle.standardError.write(Data("selfcheck FAILED: \(msg())\n".utf8))
        exit(1)
    }
}
