import AVFoundation
import CoreAudio

/// Opptak av systemlyd + mikrofon via Core Audio process tap (macOS 14.2+).
///
/// Tappen gir global systemlyd uten ScreenCaptureKit — altså uten
/// Skjermopptak-tillatelse.
///
/// **Mikrofonen kan ikke ligge i samme aggregat-enhet som tappen.** Det var
/// første design, og det ville gitt sample-synkrone kilder gratis. Målt:
/// aggregat med bare utgangsenheten gir 175 callbacks på to sekunder med signal
/// i; legger man inngangsenheten inn som sub-enhet, stopper det på 3 callbacks
/// og bare nuller — uavhengig av `mainSubDevice`, driftskompensasjon og av om
/// prosessen er en signert bundle med innvilget mikrofontilgang. Mikrofonen tas
/// derfor opp for seg med AVAudioRecorder, og de to filene mikses med ffmpeg
/// ved stopp.
@MainActor
final class Recorder: ObservableObject {
    static let shared = Recorder()

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    /// Settes når et opptak er ferdig skrevet. ContentView lytter og forhåndsvelger fila.
    @Published var lastRecording: URL?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var sink: Sink?
    private var mic: AVAudioRecorder?
    private var destination: URL?
    private var ticker: Task<Void, Never>?
    private var heardSystemSound = false

    private init() {}

    func toggle() { isRecording ? stop() : start() }

    func start() {
        guard !isRecording else { return }
        errorMessage = nil
        Task {
            // Første gang gir dette systemets mikrofon-prompt. Nektes den, tas
            // systemlyden opp alene — det er fortsatt et brukbart opptak.
            let microphone = await AVCaptureDevice.requestAccess(for: .audio)
            do {
                try begin(microphone: microphone)
                isRecording = true
                let startedAt = Date()
                ticker = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        guard let self, !Task.isCancelled else { return }
                        elapsed = Date().timeIntervalSince(startedAt)
                    }
                }
            } catch {
                errorMessage = "\(error)"
                // Mikrofonen starter nå før tappen (se `begin`), så et hvilket som
                // helst kast etter den linja etterlater et ferdigskrevet opptak av
                // brukerens stemme i temp. `teardown` stopper opptakeren, men sletter
                // ikke — den brukes også av `stop()`, der filene skal overleve til
                // miksingen. Rydd derfor her, og bare her.
                let orphans = [mic?.url, sink?.url].compactMap { $0 }
                teardown()
                for url in orphans { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    func stop() {
        let system = sink?.url
        let microphone = mic?.url
        let destination = destination
        teardown()
        isRecording = false
        elapsed = 0
        // Info.plist-nøkkelen utløser spørsmålet, men svaret kan bli nei — og da er
        // tappen like taus som før nøkkelen fantes, uten en eneste feilkode.
        if !heardSystemSound {
            errorMessage = "systemlyden var helt stille — gi Schous tilgang under "
                + "Personvern og sikkerhet → Lydopptak, ellers tas bare mikrofonen opp"
        }
        guard let system, let destination else { return }

        // Miksingen kan ta noen sekunder på lange opptak; ikke blokker menyen.
        Task {
            let result = await Self.merge(system: system, microphone: microphone, into: destination)
            switch result {
            case .success(let url): lastRecording = url
            case .failure(let error):
                // Begge råfilene er beholdt — pek brukeren på systemlyden framfor
                // å miste opptaket. `rescued` er der `merge` fikk berget den;
                // slo bergingen også feil, ligger den fortsatt i temp.
                let kept = error.rescued ?? system
                let alsoMic = microphone == nil ? "" : "; mikrofonsporet er beholdt"
                errorMessage = "miksing feilet (\(error)) — systemlyden ligger som "
                    + "\(kept.lastPathComponent) i "
                    + "\(kept.deletingLastPathComponent().lastPathComponent)\(alsoMic)"
                lastRecording = kept
            }
        }
    }

    // MARK: - Oppsett

    private func begin(microphone: Bool) throws {
        // **Mikrofonen må startes før tappen, ikke etter.** AVAudioRecorder.record()
        // starter en AudioQueue, som ender i AudioDeviceStart på HAL-ens inngangsenhet.
        // Skjer det rett etter at vi har startet aggregatet, kolliderer den med
        // HAL-ens egen RebuildIOContext for endringen aggregatet nettopp utløste, og
        // de to låser hverandre i HALB_Mutex — appen henger for godt, uten feilkode.
        // Målt med sample(1): hovedtråden i HALC_ProxyIOContext::_StartIO, lyttekøen
        // i RebuildIOContext → PauseIO, begge i __psynch_mutexwait. Med mikrofonen
        // først går tre runder på rad rent. Ikke bytt om på dette igjen.
        //
        // Egen samplerate på mikrofonen som følge: aggregatet finnes ikke ennå.
        // Sporene mikses av ffmpeg uansett, så de trenger ikke samme rate.
        if microphone {
            let rate = (try? defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice))
                .flatMap { nominalSampleRate(of: $0) } ?? 48_000
            mic = try? AVAudioRecorder(url: scratch("mic"), settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
            ])
            // Feiler mikrofonen, tas systemlyden opp alene — fortsatt et brukbart opptak.
            if mic?.record() != true { mic = nil }
        }

        // Aggregatet trenger en klokkekilde; utgangsenheten er den naturlige.
        // Den skal være alene her — se klassekommentaren.
        let outputUID = try defaultDeviceUID(kAudioHardwarePropertyDefaultOutputDevice)

        let tapUUID = UUID()
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "Schous"
        desc.uuid = tapUUID
        desc.isPrivate = true
        try ck(AudioHardwareCreateProcessTap(desc, &tapID), "kunne ikke opprette lydtapp")

        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Schous Opptak",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            // Privat: enheten dukker ikke opp i Lydinnstillinger og dør med prosessen.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUUID.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try ck(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID),
               "kunne ikke opprette aggregat-enhet")

        let sampleRate = nominalSampleRate(of: aggregateID) ?? 48_000
        // Rikelig margin over enhetens bufferstørrelse, så mixDown aldri må kappe.
        let capacity = AVAudioFrameCount(max(4096, bufferFrameSize(of: aggregateID) * 4))
        destination = try outputURL()
        sink = try Sink(url: scratch("system"), sampleRate: sampleRate, capacity: capacity)

        guard let sink else { return }
        procID = try Self.makeIOProc(sink, on: aggregateID)
        try ck(AudioDeviceStart(aggregateID, procID), "kunne ikke starte opptaket")
    }

    private func teardown() {
        ticker?.cancel()
        ticker = nil
        mic?.stop()
        mic = nil
        if let procID {
            if aggregateID != kAudioObjectUnknown {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            self.procID = nil
        }
        // Etter AudioDeviceStop kommer ingen flere callbacks, så fila kan lukkes trygt
        // og fasiten om systemlyden hentes ut.
        heardSystemSound = sink?.heardSound ?? false
        sink = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        destination = nil
    }

    /// **Må være `nonisolated`.** Lages blokka i en `@MainActor`-metode, arver den
    /// MainActor-isolasjon, og Swift 6 feller prosessen med SIGTRAP
    /// (`_dispatch_assert_queue_fail`) i det Core Audio kaller den fra lydtråden.
    nonisolated private static func makeIOProc(
        _ sink: Sink, on device: AudioObjectID
    ) throws -> AudioDeviceIOProcID {
        var procID: AudioDeviceIOProcID?
        try ck(AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, input, _, _, _ in
            sink.render(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)))
        }, "kunne ikke koble på lydstrømmen")
        guard let procID else { throw RecorderError("fikk ingen IOProc") }
        return procID
    }

    private func scratch(_ kind: String) -> URL {
        URL.temporaryDirectory.appending(path: "schous-\(kind)-\(UUID().uuidString).m4a")
    }

    /// Mikser systemlyd og mikrofon til én fil. Uten mikrofon flyttes systemlyden bare på plass.
    ///
    /// `normalize=0` er ikke pynt: amix halverer som standard hver kilde etter antall
    /// input, så et opptak der bare én part snakker av gangen ville blitt 6 dB for lavt.
    nonisolated private static func merge(
        system: URL, microphone: URL?, into destination: URL
    ) async -> Result<URL, RecorderError> {
        guard let microphone else {
            do {
                try FileManager.default.moveItem(at: system, to: destination)
                return .success(destination)
            } catch {
                return .failure(RecorderError(
                    error.localizedDescription,
                    rescued: rescue(system: system, microphone: nil, into: destination)))
            }
        }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "ffmpeg", "-y", "-i", system.path, "-i", microphone.path,
                "-filter_complex", "[0:a][1:a]amix=inputs=2:duration=longest:normalize=0",
                "-ac", "1", "-c:a", "aac", "-b:a", "128k", destination.path,
            ]
            // Samme grunn som i TranscriptionJob: en .app fra Finder arver ikke Homebrew-PATH.
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let status = finished.terminationStatus
                for url in Self.scratchToRemove(exit: status, system: system, microphone: microphone) {
                    try? FileManager.default.removeItem(at: url)
                }
                guard status == 0 else {
                    // env svarer 127 når det ikke finner kommandoen. Det er den ene
                    // statusen vi kan oversette — og den vanligste her, siden ffmpeg
                    // er en separat Homebrew-installasjon menylinjeopptak ikke krever.
                    let why = status == 127
                        ? "ffmpeg er ikke installert"
                        : "ffmpeg avsluttet med \(status)"
                    continuation.resume(returning: .failure(RecorderError(
                        why,
                        rescued: Self.rescue(system: system, microphone: microphone, into: destination))))
                    return
                }
                continuation.resume(returning: .success(destination))
            }
            do { try process.run() } catch {
                // Ikke «fant ikke ffmpeg»: executableURL er /usr/bin/env, som alltid
                // finnes — mangler ffmpeg, får vi exit 127 over. Kaster run(), er det
                // spawn som feilet (prosesstabell full, fd-tak, policy), og den ekte
                // feilen er det eneste som kan skille dem.
                continuation.resume(returning: .failure(RecorderError(
                    "kunne ikke starte ffmpeg: \(error.localizedDescription)",
                    rescued: Self.rescue(system: system, microphone: microphone, into: destination))))
            }
        }
    }

    /// Hvilke råfiler som skal slettes etter en miks — tom liste hvis den feilet.
    ///
    /// Egen ren funksjon fordi nettopp denne avgjørelsen er hele poenget med
    /// feilhåndteringen: **ingen input slettes når miksingen feiler.** Inne i
    /// Process-callbacken kan ingenting nå den, og `--selfcheck` fanger derfor
    /// at noen fjerner regelen igjen.
    nonisolated static func scratchToRemove(
        exit status: Int32, system: URL, microphone: URL?
    ) -> [URL] {
        guard status == 0 else { return [] }
        return [system, microphone].compactMap { $0 }
    }

    /// Berger råopptaket når miksingen feiler, og returnerer stien systemlyden endte på.
    ///
    /// Filene ligger i `URL.temporaryDirectory` — `/var/folders/…/T/`, som macOS
    /// rydder på eget initiativ og som brukeren ikke finner fram til fra et
    /// UUID-filnavn. De flyttes derfor ved siden av destinasjonen, i mappa
    /// `outputURL()` allerede har sjekket at er skrivbar.
    ///
    /// Mikrofonsporet blir med. Det er brukerens egen stemme og finnes ingen
    /// andre steder, og feilet miksingen på noe annet enn innholdet — ffmpeg
    /// mangler, disken full — er en manuell kjøring fortsatt mulig med begge.
    nonisolated static func rescue(
        system: URL, microphone: URL?, into destination: URL
    ) -> URL {
        let fm = FileManager.default
        // ffmpeg skriver med -y, så en miks som feilet etter at muxeren kom i gang
        // ligger igjen på riktig navn i riktig mappe, i plausibel størrelse, og er
        // uspillbar. Den ser ut som opptaket i Finder — og `recordingURL` teller
        // den som navnekollisjon, så neste opptak blir «-2». Fjern den.
        try? fm.removeItem(at: destination)

        let dir = destination.deletingLastPathComponent()
        let base = destination.deletingPathExtension().lastPathComponent
        func salvage(_ url: URL, _ kind: String) -> URL? {
            let target = dir.appending(path: "\(base)-\(kind).m4a")
            try? fm.removeItem(at: target)
            do { try fm.moveItem(at: url, to: target); return target } catch { return nil }
        }
        if let microphone { _ = salvage(microphone, "mikrofon") }
        // Feiler flyttingen, ligger fila fortsatt i temp — ikke verre enn før.
        return salvage(system, "systemlyd") ?? system
    }

    private func outputURL() throws -> URL {
        let dir = UserDefaults.standard.string(forKey: "outputPath")
            .map { URL(fileURLWithPath: $0) } ?? URL.downloadsDirectory
        guard FileManager.default.isWritableFile(atPath: dir.path) else {
            throw RecorderError("kan ikke skrive til \(dir.lastPathComponent)")
        }
        return recordingURL(in: dir, at: Date()) {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
}

// MARK: - Fila

/// Eier AVAudioFile og mikse-bufferet. Lever utenfor MainActor fordi IOProc-callbacken
/// kjører på en sanntidstråd.
private final class Sink: @unchecked Sendable {
    let url: URL
    /// Nektes lydopptakstillatelsen leverer tappen bare nuller, og alt returnerer
    /// `noErr` — dette er eneste måten å oppdage det på. Skrives fra sanntidstråden,
    /// leses først etter `AudioDeviceStop`, så det er ingen samtidig tilgang.
    private(set) var heardSound = false
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer

    init(url: URL, sampleRate: Double, capacity: AVAudioFrameCount) throws {
        self.url = url
        file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
            throw RecorderError("kunne ikke lage lydbuffer")
        }
        self.buffer = buffer
    }

    func render(_ list: UnsafeMutableAudioBufferListPointer) {
        guard let out = buffer.floatChannelData?[0] else { return }
        let frames = mixDown(list, into: out, capacity: Int(buffer.frameCapacity))
        guard frames > 0 else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        if !heardSound, (0..<frames).contains(where: { out[$0] != 0 }) { heardSound = true }
        // ponytail: skriver til fil fra sanntidstråden. Verste utfall er et klikk i
        // opptaket, ikke tap av det. Hører du klikk i lange opptak, er oppgraderingen
        // ring-buffer + egen skrivetråd.
        try? file.write(from: buffer)
    }
}

// MARK: - Miksing

/// Mikser alle kildene i `list` ned til ett mono-signal i `out`, og returnerer
/// antall frames skrevet.
///
/// Kanalene *innenfor* én kilde snittes — det er en vanlig stereo→mono-nedmiks.
/// Kildene *seg imellom* summeres: et snitt ville dempet hver kilde etter hvor
/// mange andre som tilfeldigvis er til stede, og én kilde alene skal komme
/// uendret ut. Summen klippes til [-1, 1].
///
/// **Én buffer = én kilde.** Tappen leverer stereo *interleaved* — målt
/// `bufs=[2]`, altså én buffer med to kanaler (menylinje-opptak-design.md,
/// referanseraden) — så kanalsnittet skjer innenfor bufferet. Leverte Core Audio
/// den *non-interleaved* (to buffere à én kanal), ville kanalene blitt lest som
/// to kilder og summert i stedet for snittet: nøyaktig 2x nivå, hver frame,
/// klipping på alt over 0.5.
///
/// Med dagens oppsett ser funksjonen som regel bare tappen — mikken tas opp for
/// seg, og utgangsenheten i aggregatet er bare klokke. «Som regel», ikke
/// «alltid»: er default-utgang en enhet med egne inngangsstrømmer (lydkort,
/// BlackHole), kan `list` få flere buffere. Flerkilde-summingen står derfor, og
/// `--selfcheck` dekker den.
func mixDown(_ list: UnsafeMutableAudioBufferListPointer,
             into out: UnsafeMutablePointer<Float>,
             capacity: Int) -> Int {
    var frames = capacity
    for buf in list {
        guard buf.mData != nil, buf.mNumberChannels > 0 else { return 0 }
        let stride = MemoryLayout<Float>.size * Int(buf.mNumberChannels)
        frames = min(frames, Int(buf.mDataByteSize) / stride)
    }
    guard frames > 0 else { return 0 }

    out.update(repeating: 0, count: frames)
    for buf in list {
        guard let raw = buf.mData else { continue }
        let src = raw.assumingMemoryBound(to: Float.self)
        let channels = Int(buf.mNumberChannels)
        for f in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += src[f * channels + c] }
            out[f] += sum / Float(channels)
        }
    }
    for f in 0..<frames { out[f] = min(1, max(-1, out[f])) }
    return frames
}

/// `Opptak-2026-08-10-1432.m4a`, med `-2`, `-3` … hvis navnet er opptatt.
func recordingURL(in dir: URL, at date: Date, exists: (URL) -> Bool) -> URL {
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyy-MM-dd-HHmm"
    let base = "Opptak-\(stamp.string(from: date))"
    var url = dir.appending(path: "\(base).m4a")
    var n = 2
    while exists(url) {
        url = dir.appending(path: "\(base)-\(n).m4a")
        n += 1
    }
    return url
}

// MARK: - Core Audio-hjelpere

struct RecorderError: Error, CustomStringConvertible {
    let description: String
    /// Satt når en feilet miks fikk råopptaket berget til brukerens utmappe.
    /// `stop()` peker `lastRecording` hit, så forhåndsvalget treffer en fil som finnes.
    let rescued: URL?
    init(_ description: String, rescued: URL? = nil) {
        self.description = description
        self.rescued = rescued
    }
}

private func ck(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw RecorderError("\(what) (\(status))") }
}

private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector,
                               mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

private func defaultDeviceID(_ selector: AudioObjectPropertySelector) throws -> AudioObjectID {
    var addr = address(selector)
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try ck(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                      &addr, 0, nil, &size, &deviceID), "fant ingen lydenhet")
    guard deviceID != kAudioObjectUnknown else { throw RecorderError("fant ingen lydenhet") }
    return deviceID
}

private func defaultDeviceUID(_ selector: AudioObjectPropertySelector) throws -> String {
    let deviceID = try defaultDeviceID(selector)
    var addr = address(kAudioDevicePropertyDeviceUID)
    var ref: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try ck(AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &ref), "fant ikke enhets-UID")
    guard let uid = ref?.takeRetainedValue() else { throw RecorderError("fant ikke enhets-UID") }
    return uid as String
}

private func nominalSampleRate(of device: AudioObjectID) -> Double? {
    var addr = address(kAudioDevicePropertyNominalSampleRate)
    var rate = Double(0)
    var size = UInt32(MemoryLayout<Double>.size)
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate) == noErr, rate > 0 else {
        return nil
    }
    return rate
}

private func bufferFrameSize(of device: AudioObjectID) -> Int {
    var addr = address(kAudioDevicePropertyBufferFrameSize)
    var frames = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &frames) == noErr else { return 0 }
    return Int(frames)
}
