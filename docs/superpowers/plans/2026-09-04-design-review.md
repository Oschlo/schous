# Design review (#40) — implementasjonsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gjennomføre alt [#40](https://github.com/Oschlo/schous/issues/40) foreslår: den aktive jobben som hovedinnhold, synlig arbeidsflyt, inspektør delt i Talere/Referat, nyttig tomtilstand, «Åpne resultat» som primærhandling, Innstillinger som paneler, transkripsjonen som dokument (søk, bredde, rendret Markdown, #41), fremdrift som ikke kan forveksles med en hengende app (#39), tittelfelt for filnavn (#42), norsk mikrocopy og en tilgjengelighetsrunde.

**Architecture:** Ingen nye avhengigheter, ingen `@Observable`-migrering (spec sier eksplisitt nei). `ContentView.setup` deles i tre visninger i en ny fil; inspektøren får en segmentert kontroll og en fast bunn; Innstillinger blir en `TabView`. Estimatene i #39 er lagrede rater fra forrige kjøring i `UserDefaults` (sekunder per lydsekund per steg, og per prompt-tegn per modell), ikke noe backend rapporterer. Markdown rendres linje for linje uten pakke, rått mens det strømmer.

**Tech Stack:** Swift 6 / SwiftUI, SwiftPM uten Xcode, macOS 14.2+. Test = `--selfcheck` i `Sources/Schous/Selfcheck.swift`. Bundle = `./bundle.sh`.

**Spec:** issue #40 (kopiert inn i PR-beskrivelsen), med #39, #41 og #42 der #40 peker på dem.

## Global Constraints

- Gren `design-review`, én PR mot `main`. Ingen commits på main.
- `swift build` og `.build/debug/Schous --selfcheck` → `selfcheck ok` etter hver task. `./bundle.sh` før noe kjøres som app (TCC, se CLAUDE.md «Signering»).
- `writeOutputs`/`transcriptText` i `Segment.swift` er byte-eksakte porter. Innholdet i TXT/SRT/JSON endres aldri; #42 endrer bare *filnavn*.
- Jobbmappa (`~/Library/Application Support/Schous/jobs/<hash>/`) røres ikke av tittel eller navn. `output/` der er fasit.
- Ingen egendefinerte glasskort eller gradienter: systemmaterialer, systemkontroller, én aksentfarge. 8 pt-grid. Talerfarger kun til identitet.
- Norsk bokmål i UI. `Diarization` vises som **Finner talere**; den tekniske termen står i Detaljer.
- `UserDefaults`-nøkler som legges til: `stepRates`, `summaryRates`. `outputPath` finnes fra før og flyttes til `AppSettings`.
- Snarveier som finnes på norsk tastatur (CLAUDE.md): ⌘F søk, ⌘⌥T inspektør, ⌘↑ tilbake, ⌘S eksport, ⌘⇧R referat, ⌘⇧P pause, ⌘. stopp.
- `think: false`, stillhetsfrist 600 s og struping i `Summarizer` står urørt.
- Ikke commit media. `git status` etter hver kjøring som transkriberer eller tar opp.
- Commit-meldinger på norsk, avsluttet med
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` og
  `Claude-Session: https://claude.ai/code/session_019TT6uXYtYBf9CpDHxaysdn`.
- Etter hver leveransefase i #40 (fem stykker) postes en kommentar på #40 med hva som er gjort og hva som er målt.

## Filstruktur

| Fil | Ansvar |
|---|---|
| `Sources/Schous/Estimates.swift` (ny) | Rater fra forrige kjøring: per steg (sek per lydsekund) og per modell (last + sek per prompt-tegn). Ren, injiserbar `UserDefaults`. |
| `Sources/Schous/SetupViews.swift` (ny) | `EmptyStateView`, `JobSetupView`, `JobProgressView`, `WorkflowStepper` |
| `Sources/Schous/ContentView.swift` | Tilstand og handlinger; velger mellom de tre oppsettsvisningene og editoren |
| `Sources/Schous/SpeakerEditorView.swift` | Editor: dokumentkolonne, søk, inspektør med Talere/Referat, adaptiv bredde |
| `Sources/Schous/SpeakerInspector.swift` (ny) | Talere-fanen: kompakte rader |
| `Sources/Schous/SummaryView.swift` | Referat-fanen (skjema + fast bunn), `SummaryPanel` |
| `Sources/Schous/Markdown.swift` (ny) | `MarkdownBlock.parse` + `MarkdownView` (#41) |
| `Sources/Schous/Summarizer.swift` | Faser (`venter`/`skriver`), `load_duration`/`prompt_eval_duration`, rater (#39) |
| `Sources/Schous/TranscriptionJob.swift` | Stegnavn på norsk, stegvarigheter, `input`, `audioSeconds`, `finishedInfo` |
| `Sources/Schous/Segment.swift` | `filenameSafe`, `outputBase(title:date:fallback:)` (#42) |
| `Sources/Schous/Settings.swift` | `AppSettings`: `outputPath`, `modelsCached`, avbrytbar sjekk |
| `Sources/Schous/SettingsView.swift` (ny) | `TabView` med Generelt / Transkribering / Referat / Avansert, `CopyButton` |
| `Sources/Schous/SchousApp.swift` | `defaultSize`, kommandoer for søk og inspektør, meter-tilgjengelighet |
| `Sources/Schous/Selfcheck.swift` | Nye sjekker: estimater, filnavn, markdown, søkefilter, `finishedInfo` |
| `README.md`, `CLAUDE.md`, `docs/*.png` | Dokumentasjon og skjermbilder |

---

## Fase 1 — Informasjonsarkitektur og adaptiv layout

### Task 1: Estimater fra forrige kjøring, og norske stegnavn

**Files:**
- Create: `Sources/Schous/Estimates.swift`
- Modify: `Sources/Schous/TranscriptionJob.swift`
- Test: `Sources/Schous/Selfcheck.swift`

**Interfaces:**
- Produces:
  ```swift
  enum Estimates {
      static func stepEstimate(_ step: Int, audioSeconds: Double, in d: UserDefaults = .standard) -> TimeInterval?
      static func recordStep(_ step: Int, seconds: TimeInterval, audioSeconds: Double, in d: UserDefaults = .standard)
      static func summaryEstimate(model: String, promptChars: Int, in d: UserDefaults = .standard) -> TimeInterval?
      static func recordSummary(model: String, loadSeconds: Double, promptSeconds: Double, promptChars: Int, in d: UserDefaults = .standard)
      static func describe(_ t: TimeInterval) -> String   // "under ett minutt" / "ca. 3 min" / "ca. 1 t 10 min"
  }
  ```
  `TranscriptionJob.stepNames == ["", "Forbereder lyd", "Finner talere", "Finner språk", "Transkriberer"]`,
  `TranscriptionJob.technicalNames == ["", "lyd", "diarization", "språk per taler", "transkriberer"]`,
  `TranscriptionJob.start(input:speakers:audioSeconds:)`, `job.input: URL?`, `job.audioSeconds: Double`,
  `job.stepStarted: Date?`, `job.stepEstimate: TimeInterval?` (gjenstående i gjeldende steg, fra raten).

- [ ] **Step 1: Skriv sjekkene**

I `Selfcheck.swift`, ny funksjon kalt fra `runSelfcheckAndExit()`:

```swift
/// Estimatene i #39: rater fra forrige kjøring, i en egen defaults-suite så
/// selfcheck aldri rører brukerens tall.
private func estimatesSelfcheck() {
    let d = UserDefaults(suiteName: "co.oschlo.schous.selfcheck-\(getpid())")!
    defer { d.removePersistentDomain(forName: "co.oschlo.schous.selfcheck-\(getpid())") }
    check(Estimates.stepEstimate(2, audioSeconds: 600, in: d) == nil, "uten historikk skal steg-estimatet være nil")
    // 10 min lyd tok 4 min i steg 2 → 0.4 s per lydsekund → 20 min lyd anslås til 8 min.
    Estimates.recordStep(2, seconds: 240, audioSeconds: 600, in: d)
    check(Estimates.stepEstimate(2, audioSeconds: 1200, in: d).map { abs($0 - 480) < 1e-6 } == true,
          "steg-estimat: \(String(describing: Estimates.stepEstimate(2, audioSeconds: 1200, in: d)))")
    check(Estimates.stepEstimate(4, audioSeconds: 1200, in: d) == nil, "steg 4 har ingen historikk ennå")
    // Uten lydlengde finnes ingen rate å lagre.
    Estimates.recordStep(3, seconds: 5, audioSeconds: 0, in: d)
    check(Estimates.stepEstimate(3, audioSeconds: 100, in: d) == nil, "rate uten lydlengde skal ikke lagres")

    check(Estimates.summaryEstimate(model: "m", promptChars: 1000, in: d) == nil, "uten historikk skal referat-estimatet være nil")
    // 11 s lasting + 297 s prefill på 40 000 tegn (målt i #39) → 20 000 tegn anslås til 11 + 148,5.
    Estimates.recordSummary(model: "m", loadSeconds: 11, promptSeconds: 297, promptChars: 40_000, in: d)
    check(Estimates.summaryEstimate(model: "m", promptChars: 20_000, in: d).map { abs($0 - 159.5) < 1e-6 } == true,
          "referat-estimat: \(String(describing: Estimates.summaryEstimate(model: "m", promptChars: 20_000, in: d)))")
    check(Estimates.summaryEstimate(model: "annen", promptChars: 20_000, in: d) == nil, "raten er per modell")

    check(Estimates.describe(20) == "under ett minutt", Estimates.describe(20))
    check(Estimates.describe(200) == "ca. 3 min", Estimates.describe(200))
    check(Estimates.describe(4200) == "ca. 1 t 10 min", Estimates.describe(4200))
}
```

Og i hovedløpet, etter `"step 4"`-sjekken:

```swift
check(TranscriptionJob.stepNames[2] == "Finner talere" && job.stepLabel == "Transkriberer",
      "stegnavn på norsk: \(job.stepLabel)")
check(TranscriptionJob.technicalNames[2] == "diarization", "teknisk navn til Detaljer")
```

- [ ] **Step 2: Kjør — skal feile på at `Estimates` ikke finnes**

Run: `swift build 2>&1 | tail -3`
Expected: `error: cannot find 'Estimates' in scope`

- [ ] **Step 3: Implementer `Estimates.swift`**

```swift
import Foundation

/// Estimater fra forrige kjøring (#39). Backend rapporterer ingen tid i steg
/// 1–3, og ollama sender ingenting under prefill — det eneste som finnes er
/// hvor lang tid det tok sist, på denne maskinen. Ratene er lineære i
/// lydlengde (steg) og promptlengde (referat); det er en tilnærming, og
/// teksten sier «ca.» og «vanligvis» av den grunn.
enum Estimates {
    static let stepKey = "stepRates"        // ["2": sek per lydsekund, …]
    static let summaryKey = "summaryRates"  // [modell: [lastSek, sekPerTegn]]

    static func stepEstimate(_ step: Int, audioSeconds: Double, in d: UserDefaults = .standard) -> TimeInterval? {
        guard audioSeconds > 0,
              let rate = (d.dictionary(forKey: stepKey) as? [String: Double])?[String(step)] else { return nil }
        return rate * audioSeconds
    }

    static func recordStep(_ step: Int, seconds: TimeInterval, audioSeconds: Double, in d: UserDefaults = .standard) {
        guard audioSeconds > 0, seconds > 0 else { return }
        var rates = (d.dictionary(forKey: stepKey) as? [String: Double]) ?? [:]
        rates[String(step)] = seconds / audioSeconds
        d.set(rates, forKey: stepKey)
    }

    static func summaryEstimate(model: String, promptChars: Int, in d: UserDefaults = .standard) -> TimeInterval? {
        guard let r = (d.dictionary(forKey: summaryKey) as? [String: [Double]])?[model], r.count == 2 else { return nil }
        return r[0] + r[1] * Double(promptChars)
    }

    static func recordSummary(model: String, loadSeconds: Double, promptSeconds: Double, promptChars: Int,
                              in d: UserDefaults = .standard) {
        guard promptChars > 0 else { return }
        var rates = (d.dictionary(forKey: summaryKey) as? [String: [Double]]) ?? [:]
        rates[model] = [loadSeconds, promptSeconds / Double(promptChars)]
        d.set(rates, forKey: summaryKey)
    }

    static func describe(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded())
        if m < 1 { return "under ett minutt" }
        if m < 60 { return "ca. \(m) min" }
        return "ca. \(m / 60) t \(m % 60) min"
    }
}
```

- [ ] **Step 4: `TranscriptionJob`: norske navn, input, lydlengde, stegvarigheter**

```swift
static let stepNames = ["", "Forbereder lyd", "Finner talere", "Finner språk", "Transkriberer"]
/// Backendens egne ord, til «Detaljer». UI-et sier hva brukeren får, ikke hva algoritmen heter.
static let technicalNames = ["", "lyd", "diarization", "språk per taler", "transkriberer"]

private(set) var input: URL?
private(set) var audioSeconds: Double = 0
@Published private(set) var stepStarted: Date?

/// Gjenstående i gjeldende steg fra forrige kjørings rate, eller nil.
/// Steg 4 har et ekte anslag (`eta`) fra segmenttellingen og bruker ikke dette.
var stepEstimate: TimeInterval? {
    guard let t0 = stepStarted, let total = Estimates.stepEstimate(step, audioSeconds: audioSeconds) else { return nil }
    return max(0, total - Date().timeIntervalSince(t0))
}
```

`start(input:speakers:audioSeconds:)` setter `self.input`, `self.audioSeconds`, `stepStarted = Date()`.
I `apply`, `case "step"`: før `step = …`, `closeStep()`; etter: `stepStarted = Date()`.
`case "done"`: `closeStep()`.

```swift
/// Skriver ned hvor lang tid steget tok, som rate mot lydlengden.
private func closeStep() {
    guard let t0 = stepStarted, (1...4).contains(step) else { return }
    Estimates.recordStep(step, seconds: Date().timeIntervalSince(t0), audioSeconds: audioSeconds)
    stepStarted = nil
}
```

`loadFinished` setter `input` også. `ContentView.start()` sender `audioSeconds` (kommer i Task 2).

- [ ] **Step 5: Bygg, selfcheck, commit**

Run: `swift build 2>&1 | grep -E "error|warning: unused" ; .build/debug/Schous --selfcheck`
Expected: `selfcheck ok`

```bash
git add Sources/Schous/Estimates.swift Sources/Schous/TranscriptionJob.swift Sources/Schous/Selfcheck.swift
git commit -m "Estimater fra forrige kjøring, og stegnavn som sier hva brukeren får"
```

### Task 2: Tre oppsettsvisninger og arbeidsflyten

**Files:**
- Create: `Sources/Schous/SetupViews.swift`
- Modify: `Sources/Schous/ContentView.swift`, `Sources/Schous/Settings.swift` (`outputPath`, `modelsCached`), `Sources/Schous/TranscriptionJob.swift` (`finishedInfo`)
- Test: `Sources/Schous/Selfcheck.swift`

**Interfaces:**
- Produces:
  ```swift
  enum WorkflowStep: Int, CaseIterable { case file = 1, transcription, speakers, summary
      var title: String }   // "Fil", "Transkribering", "Talere", "Referat og eksport"
  struct WorkflowStepper: View { let current: WorkflowStep; var completed: Set<WorkflowStep>; var onSelect: ((WorkflowStep) -> Void)? }
  struct EmptyStateView: View   // pickFile, startRecording
  struct JobSetupView: View     // input, duration, outputPath, speakers, finished info, actions
  struct JobProgressView: View  // job, pause/resume/stop, Detaljer
  struct FinishedInfo { let segments: Int; let modified: Date }
  static func TranscriptionJob.finishedInfo(for: URL) -> FinishedInfo?
  AppSettings.outputPath: String (@Published, UserDefaults "outputPath")
  AppSettings.modelsCached: Bool
  ```

- [ ] **Step 1: Sjekk for `finishedInfo`**

I selfcheck, etter `loadFinished`-sjekken (før `removeItem(at: fakeJob)`):

```swift
let info = TranscriptionJob.finishedInfo(for: fakeInput)
check(info?.segments == 1 && info.map { Date().timeIntervalSince($0.modified) < 60 } == true,
      "finishedInfo: \(String(describing: info))")
```

- [ ] **Step 2: Implementer `finishedInfo`, `outputPath`, `modelsCached`**

```swift
struct FinishedInfo { let segments: Int; let modified: Date }
/// Til «Ferdig · 5 segmenter · sist endret …» i oppsettet. Leser fila; den er liten.
static func finishedInfo(for input: URL) -> FinishedInfo? {
    guard let json = finishedOutput(for: input),
          let data = try? Data(contentsOf: json),
          let segs = try? JSONDecoder().decode([Segment].self, from: data),
          let date = try? json.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    else { return nil }
    return FinishedInfo(segments: segs.count, modified: date)
}
```

`AppSettings`:
```swift
@Published var outputPath: String { didSet { UserDefaults.standard.set(outputPath, forKey: "outputPath") } }
// init: outputPath = d.string(forKey: "outputPath") ?? URL.downloadsDirectory.path

/// Vektene ligger under ~/.cache/huggingface, og bare der: subprocessEnv fjerner
/// HF_HOME. Sjekken sier «klare» eller «lastes ned ved første kjøring (~3 GB)» i
/// tomtilstanden — README kaller det første jobbens mest sannsynlige «henger».
nonisolated static var modelsCached: Bool {
    let hub = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".cache/huggingface/hub")
    return ["models--mlx-community--whisper-large-v3-mlx", "models--pyannote--speaker-diarization-community-1"]
        .allSatisfy { FileManager.default.fileExists(atPath: hub.appending(path: $0).path) }
}
```

- [ ] **Step 3: `SetupViews.swift`**

`WorkflowStepper`: `HStack(spacing: 0)` med fire elementer. Hvert: nummersirkel (fylt aksent når aktiv, `checkmark` når fullført, sekundær ellers) + tittel. Klikkbart bare når `onSelect` gis og steget er fullført eller aktivt. `.accessibilityElement(children: .combine)`, `.accessibilityLabel("Steg \(n) av 4, \(title), \(status)")`. Høyde ~28 pt, `.font(.callout)`, separatorer som tynne `Rectangle` 1 pt i `.quaternary`.

`EmptyStateView`:
```
VStack(spacing: 16) {
  Image(systemName: "waveform").font(.system(size: 44)).foregroundStyle(.secondary)
  Text("Transkriber lyd og møter lokalt").font(.title2.weight(.semibold))
  Text("Dra inn en lyd- eller videofil, eller ta opp fra menylinja. Talere skilles fra hverandre, og du kan lage referat etterpå.").foregroundStyle(.secondary).multilineTextAlignment(.center)
  dropZone (RoundedRectangle dash, min 140 pt, «Dra en fil hit» + Button("Velg fil…") .bordered .keyboardShortcut("o"))
  if !recorder.isRecording { Button("Start opptak", systemImage: "record.circle") { Recorder.shared.start() } .buttonStyle(.borderless) }
  Divider().frame(maxWidth: 360)
  setupStatus  // se under
  Text("Lyd og transkripsjon behandles lokalt på denne Macen.").font(.caption).foregroundStyle(.secondary)
}
.frame(maxWidth: 460).padding(32)
```
`setupStatus`: to rader med `Label`:
- backend: `settings.isConfigured ? Label("Backend klar", systemImage: "checkmark.circle.fill").foregroundStyle(.green)` ellers `SettingsLink { Label("Fullfør oppsett — velg backend-mappen", systemImage: "gearshape") }.buttonStyle(.bordered)`.
- modeller: `AppSettings.modelsCached ? Label("Modeller klare", "checkmark.circle.fill")` ellers `Label("Modeller lastes ned ved første kjøring (~3 GB)", "arrow.down.circle")` sekundær.

`JobSetupView` (fil valgt, ikke kjørende): sentrert `maxWidth: 520`:
```
fil-rad: Image(systemName: "doc.fill") + navn (.headline) + «varighet · mappe» (.caption, .secondary)
Button("Bytt fil…") .borderless
Form-liknende LabeledContent:
  LabeledContent("Lagre i") { HStack { Text(mappenavn).help(hele stien); Button("Velg…"); Button("Vis i Finder") } }
  LabeledContent("Antall talere") { Picker("", selection: $speakers) { Text("Automatisk").tag(0); ForEach(1...12) { Text("\($0)").tag($0) } }.labelsHidden().fixedSize() }
if let info: Label("Ferdig · \(info.segments) segmenter · sist endret \(info.modified.formatted(.relative(presentation: .named)))", systemImage: "checkmark.circle").foregroundStyle(.secondary)
if !settings.isConfigured: SettingsLink { Label("Backend er ikke satt opp — åpne Innstillinger", "gearshape") } .orange
feil/stoppet-melding (fra job.state) med Label .red / .orange
Handlinger (HStack, trailing):
  if info != nil:  Button("Transkriber på nytt…").help("Steg 1–3 er cachet; bare transkriberingen kjøres. Nye navn og referat må lages på nytt.")  ·  Button("Åpne resultat").borderedProminent.keyboardShortcut(.defaultAction)
  else:            Button("Start transkribering").borderedProminent.keyboardShortcut(.defaultAction).disabled(!settings.isConfigured)
```
«Transkriber på nytt…» går til `start()`; et `.stopped(n)`-tilfelle viser fortsatt «Start transkribering» (gjenopptar) fordi `finishedOutput` er nil når partial-fila finnes.

`JobProgressView` (running/paused): sentrert `maxWidth: 520`:
```
fil-rad som over
WorkflowStepper(current: .transcription, completed: [.file])
firetrinns steg-liste: for s in 1...4: HStack { symbol (checkmark.circle.fill grønn / aktiv: ProgressView().controlSize(.small) / circle sekundær); Text(stepNames[s]) } — aktivt steg .semibold
Text(nåStatus).font(.headline)   // "Finner talere · segmentation" ; paused: "Pauset — Finner talere"
ProgressView(value: job.fraction) eller ubestemt, .progressViewStyle(.linear)
   .accessibilityLabel("Steg \(job.step) av 4, \(job.stepLabel)")
   .accessibilityValue(job.fraction.map { "\(Int($0 * 100)) prosent" } ?? "pågår")
Text(gjenstår).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
   // steg 4: "214 av 509 segmenter · 3m12s igjen"; steg 2 med fraction: "64 % · ca. 3 min igjen"; ellers Estimates.describe(stepEstimate) + " igjen", eller "" 
if !AppSettings.modelsCached && (job.step == 2 || job.step == 4): Label("Første kjøring laster ned modeller (opptil 3 GB). Det kan ta en stund før fremdriften beveger seg.", systemImage: "arrow.down.circle").font(.callout).foregroundStyle(.secondary)
HStack { Pause/Fortsett (⌘⇧P) · Stopp (⌘.) } — samlet, rett under fremdriften
DisclosureGroup("Detaljer") { Text("Steg \(step) av 4: \(technicalNames[step])") ; ScrollView { Text(job.log.suffix(40).joined("\n")).font(.caption.monospaced()).textSelection(.enabled) }.frame(maxHeight: 160) }
```
`ProgressView` uten fast høyde. `.animation(.default, value: job.step)`.

- [ ] **Step 4: `ContentView` velger visning**

```swift
var body: some View {
    VStack(spacing: 0) {
        if job.state == .done {
            SpeakerEditorView(job: job, outputDir: URL(fileURLWithPath: settings.outputPath), onNewJob: leaveEditor)
        } else if isBusy {
            JobProgressView(job: job, input: input!, duration: duration)
        } else if let input {
            VStack(spacing: 0) {
                WorkflowStepper(current: .file, completed: []).padding(.horizontal, 20).padding(.top, 12)
                JobSetupView(job: job, input: input, duration: duration, speakers: $speakers,
                             pickInput: pickInput, pickOutput: pickOutput, start: start,
                             openResult: { job.loadFinished(input: input) })
            }
        } else {
            EmptyStateView(pickFile: pickInput)
        }
    }
    .frame(minWidth: 620, minHeight: 460)
    …
}
```
Varsler fra `recorder.liveWarning`/`errorMessage` legges som en `Label` over innholdet i alle tre oppsettsvisningene (én `warnings`-view i ContentView, lagt i VStack-en over).
`@State private var speakers = 0` (0 = automatisk). `@State private var duration: Double?` settes i `.task(id: input) { duration = try? await AVURLAsset(url: input).load(.duration).seconds }`.
`start()`: `job.start(input:, speakers: speakers == 0 ? nil : speakers, audioSeconds: duration ?? 0)`.
Slipp-sonen (`dropDestination`) blir stående på hele VStack-en.

- [ ] **Step 5: Bygg, bundle, se på alle tre tilstandene**

Run: `swift build && .build/debug/Schous --selfcheck && ./bundle.sh && pkill -x Schous; open Schous.app`
Se: tom → velg fil (`~/Library/Application Support/Schous/jobs/*/` har ferdige jobber; input-stien står i `speakers.json`-mappa? Nei — bruk et opptak i Nedlastinger eller `open Schous.app --args --input <fil>`) → «Åpne resultat» er blå. Sjekk i lys og mørk modus, og ved 620×460.

- [ ] **Step 6: Commit**

```bash
git add Sources/Schous/SetupViews.swift Sources/Schous/ContentView.swift Sources/Schous/Settings.swift Sources/Schous/TranscriptionJob.swift Sources/Schous/Selfcheck.swift
git commit -m "Den aktive jobben er hovedinnholdet, og arbeidsflyten synes"
```

### Task 3: Inspektør delt i Talere og Referat, adaptiv bredde

**Files:**
- Create: `Sources/Schous/SpeakerInspector.swift`
- Modify: `Sources/Schous/SpeakerEditorView.swift`, `Sources/Schous/SummaryView.swift`

**Interfaces:**
- Produces:
  ```swift
  enum InspectorTab: String, CaseIterable { case speakers = "Talere", summary = "Referat" }
  struct SpeakerInspector: View  // ids, roots, names/mergedInto bindings, color(for:), count, label, firstQuote
  struct SummaryControls: View   // som før, men uten knapp/status
  struct SummaryFooter: View     // «Lag referat»/«Stopp» + status, alltid synlig
  ```
  `SummaryControls` får `@Binding var selection: SummarySelection` der
  `struct SummarySelection { var template: URL?; var model = ""; var language: SummaryLanguage = .norwegian; var context = "" }`,
  slik at footeren kan starte med det som er valgt.

- [ ] **Step 1: `SpeakerInspector`**

Én rad per ID:
```
HStack(spacing: 8) {
  Circle().fill(color).frame(width: 10, height: 10)
  if mergedInto[id] == nil {
    TextField(id, text: nameBinding).textFieldStyle(.roundedBorder)
      .accessibilityLabel("Navn for \(id)")
  } else {
    Text(id).font(.body.monospaced()).foregroundStyle(.secondary)
  }
  Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).help("\(count) segmenter")
  Menu { Button("Egen person") {…}; ForEach(roots.filter { $0 != id }) { Button("Samme som \(label($0))") } } label: { Image(systemName: mergedInto[id] == nil ? "person" : "person.2") }
    .menuStyle(.borderlessButton).fixedSize().help("Slå sammen med en annen taler")
    .accessibilityLabel("Slå sammen \(id)")
}
Text("„\(quote)“").font(.caption).foregroundStyle(.secondary).lineLimit(1).help(quote)
```
Under lista: `Text("Én person kan ha fått flere ID-er. Slå dem sammen med personmenyen.").font(.caption).foregroundStyle(.secondary)`.

- [ ] **Step 2: Inspektøren i `SpeakerEditorView`**

```swift
@State private var tab: InspectorTab = .speakers
@State private var wantsInspector = true
@State private var narrow = false
private var showInspector: Binding<Bool> {
    Binding(get: { wantsInspector && !narrow }, set: { wantsInspector = $0 })
}

private var inspector: some View {
    VStack(spacing: 0) {
        Picker("Panel", selection: $tab) { ForEach(InspectorTab.allCases, id: \.self) { Text($0.rawValue) } }
            .pickerStyle(.segmented).labelsHidden().padding(10)
        Divider()
        ScrollView {
            Group {
                switch tab {
                case .speakers: SpeakerInspector(…)
                case .summary: SummaryControls(jobDir: job.jobDir, summarizer: summarizer, selection: $summarySelection)
                }
            }.padding(16)
        }
        if tab == .summary {
            Divider()
            SummaryFooter(summarizer: summarizer, canStart: summarySelection.template != nil && !summarySelection.model.isEmpty,
                          start: { startSummary(summarySelection) }).padding(12)
        }
    }
}
```
`.inspector(isPresented: showInspector)`, og målingen:
```swift
.background(GeometryReader { g in
    Color.clear.onChange(of: g.size.width, initial: true) { _, w in narrow = w < 760 }
})
```
Toolbar-knappen togglar `wantsInspector`; er vinduet smalt, viser `.help` «Vinduet er for smalt for inspektøren».
`WorkflowStepper(current: tab == .summary ? .summary : .speakers, completed: [.file, .transcription], onSelect:)` øverst i dokumentkolonnen (under toolbar), `.file` → `onNewJob`, `.speakers`/`.summary` → bytt fane og vis inspektøren.

- [ ] **Step 3: `SummaryFooter`**

```swift
struct SummaryFooter: View {
    @ObservedObject var summarizer: Summarizer
    let canStart: Bool
    let start: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            status   // flyttet fra SummaryControls, samme innhold
            HStack {
                Spacer()
                if summarizer.state == .running { Button("Stopp") { summarizer.cancel() } }
                else { Button("Lag referat", action: start).buttonStyle(.borderedProminent)
                         .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(!canStart) }
            }
        }
    }
}
```
`SummaryControls` mister knapp og status, beholder `.task`/`onChange`-logikken, og skriver inn i `selection`. Kontekstfeltet: `TextEditor` med `.frame(minHeight: 60)`, `.accessibilityLabel("Kontekst")`, `.accessibilityHint("Hvem var med og hva møtet gjaldt. Valgfritt.")`.

- [ ] **Step 4: Bygg, bundle, mål**

Åpne et resultat med ≥ 3 talere. Sjekk: «Lag referat» er synlig uten å scrolle ved 460 pt høyde. Dra vinduet under 760 pt bredt: inspektøren forsvinner, over: kommer tilbake. `.build/debug/Schous --selfcheck` grønn.

- [ ] **Step 5: Commit**

```bash
git add Sources/Schous/SpeakerInspector.swift Sources/Schous/SpeakerEditorView.swift Sources/Schous/SummaryView.swift
git commit -m "Inspektøren viser ett arbeidstrinn om gangen, og gjemmer seg når vinduet er smalt"
```

- [ ] **Step 6: Kommentar på #40 — fase 1 ferdig**

`gh issue comment 40 --body-file …` med: hva som er endret, hva som er sett i appen (tilstander, bredder), og at fase 2 er neste.

---

## Fase 2 — Fremdrift og statuser (#39)

### Task 4: Referatets faser og estimat

**Files:**
- Modify: `Sources/Schous/Summarizer.swift`, `Sources/Schous/SummaryView.swift`
- Test: `Sources/Schous/Selfcheck.swift`

**Interfaces:**
- Produces: `Summarizer.Phase { case idle, waiting(estimate: TimeInterval?), streaming }`, `@Published var phase: Phase`,
  `Chunk.loadSeconds: Double?`, `Chunk.promptEvalSeconds: Double?`, `run(prompt:model:baseURL:writeTo:)` lagrer rate ved `done`.

- [ ] **Step 1: Sjekker**

I `summarizerNetworkSelfcheck`, etter parsing av `done`:
```swift
check(d?.loadSeconds.map { abs($0 - 6.040992125) < 1e-6 } == true
      && d?.promptEvalSeconds.map { abs($0 - 0.68357225) < 1e-6 } == true,
      "varigheter fra sluttobjektet: \(String(describing: d))")
```
I tilfelle 1 (normal strøm), etter `s.state == .done(out)`:
```swift
check(s.phase == .idle, "fase etter ferdig: \(s.phase)")
// Neste kjøring mot samme modell har et estimat: 6.04 s lasting + 0.68 s på promptens 1 tegn («p»).
check(Estimates.summaryEstimate(model: "m", promptChars: 1, in: .standard) != nil, "raten ble ikke lagret")
```
NB: den siste skriver i `.standard`; rydd med `UserDefaults.standard.removeObject(forKey: Estimates.summaryKey)` etterpå **bare hvis** nøkkelen ikke fantes før sjekken (les den først og legg tilbake).
Tilfelle 5 (frist): før `summarize` går inn, kan ikke fasen leses; i stedet: `Summarizer(timeout: 10)`, `run(...)` mot port med `hold`, pump 0.1 s, `check({ if case .waiting = s.phase { true } else { false } }())`, `cancel()`.

- [ ] **Step 2: Implementer**

`Line` får `load_duration: Int64?`, `prompt_eval_duration: Int64?`; `Chunk` får `loadSeconds`/`promptEvalSeconds` = ns / 1e9.
I `run`: `phase = .waiting(estimate: Estimates.summaryEstimate(model: model, promptChars: prompt.utf8.count))`.
I `stream`, første chunk med ikke-tom `content`: `phase = .streaming`. Ved `done`: `Estimates.recordSummary(model:loadSeconds:promptSeconds:promptChars:)` når begge finnes. I `run` etter ferdig/feil og i `cancel`: `phase = .idle`.

`SummaryFooter.status`:
```
case .running:
  switch phase {
  case .waiting(let est):
     ProgressView().progressViewStyle(.linear)  (ubestemt)
     Text("Modellen leser transkripsjonen (\(ord) ord)" + (est.map { " · tar vanligvis \(Estimates.describe($0)) på denne maskinen" } ?? " · ingen pakker kommer før den er ferdig"))
  case .streaming: Text("Skriver referat … ") + Text(t0, style: .timer)
  }
```
`ord` = `summarizer.promptWords` (settes i `run` fra `prompt.split(whereSeparator: \.isWhitespace).count`, `@Published private(set)`).

- [ ] **Step 3: Bygg, selfcheck, commit**

```bash
git commit -am "Referatet sier hvilken fase det er i, og hvor lang tid det pleier å ta"
```

### Task 5: Transkripsjonens tegn på liv

Det meste kom i Task 2 (`JobProgressView` viser estimat, prosent og førstegangsvarsel). Her:

- [ ] **Step 1:** `job.detail` i steg 3 vises som «taler 1/3 — SPEAKER_00: sv» — bytt formatet til `"taler \(n) av \(total) · \(speaker): \(lang)"` i `apply` og oppdater selfcheck-strengen tilsvarende.
- [ ] **Step 2:** Bekreft i `JobProgressView` at teksten under baren alltid har innhold under kjøring: fallback `"Pågår …"` når `detail` er tom og ingen estimat finnes, og at ubestemt `ProgressView(.linear)` brukes i steg 1 og 3.
- [ ] **Step 3:** Ekte kjøring: `./bundle.sh && pkill -x Schous; open Schous.app --args --input <et kort opptak>` — se at steg-lista og estimatet oppfører seg. Noter tallene til kommentaren.
- [ ] **Step 4:** Commit, og kommentar på #40 (fase 2, med #39 referert).

---

## Fase 3 — Innstillingspaneler og førstegangsoppsett

### Task 6: `SettingsView` som `TabView`

**Files:**
- Create: `Sources/Schous/SettingsView.swift`
- Modify: `Sources/Schous/Settings.swift` (flytt `SettingsView` ut; avbrytbar sjekk)
- Test: `Sources/Schous/Selfcheck.swift`

**Interfaces:**
- Produces: `AppSettings.cancelCheck()`, `AppSettings.capture(_:args:cwd:timeout:register:)` med `register: (@Sendable (Process) -> Void)? = nil`, `struct CopyButton: View { let text: String }`.

- [ ] **Step 1: Sjekk for avbrudd**

```swift
// Avbryt: en sjekk som står og venter må kunne stoppes fra knappen, ikke bare fristen.
var registered: Process?
let cancelStart = Date()
DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { registered?.terminate() }
let cancelled = AppSettings.capture(URL(fileURLWithPath: "/bin/sleep"), args: ["5"], cwd: URL.temporaryDirectory,
                                    timeout: 10, register: { registered = $0 })
check(Date().timeIntervalSince(cancelStart) < 3, "avbrudd drepte ikke prosessen")
check(cancelled.hasPrefix("Prosessen ble drept"), "avbrudd: \(cancelled.prefix(40))")
```
(`registered` må være en boks/`nonisolated(unsafe)`; bruk en liten `final class Box: @unchecked Sendable { var p: Process? }`.)

- [ ] **Step 2: Implementer avbrudd**

`capture` kaller `register?(p)` rett etter `try p.run()`. `AppSettings`: `private var checkProcess: Process?`, `private var cancelling = false`; `run` sender `register: { p in Task { @MainActor in self.checkProcess = p } }`; `cancelCheck()` setter `cancelling = true; checkProcess?.terminate()`; i resultatet: `cancelling ? "Avbrutt." : …`.

- [ ] **Step 3: `SettingsView.swift`**

```swift
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralPane().tabItem { Label("Generelt", systemImage: "gearshape") }
            TranscriptionPane().tabItem { Label("Transkribering", systemImage: "waveform") }
            SummaryPane().tabItem { Label("Referat", systemImage: "doc.text") }
            AdvancedPane().tabItem { Label("Avansert", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520)
    }
}
```
- **Generelt:** `LabeledContent("Standard målmappe") { Text(navn).help(sti); Button("Velg…") }`, seksjon «Eksportformater» (togglene), forklaringen.
- **Transkribering:** backend-felt + Velg… (`.disabled(settings.checking)` bare på disse), knappene «Test backend»/«Test modelltilgang», `if checking { ProgressView().controlSize(.small); Button("Avbryt") { settings.cancelCheck() } }`, resultat, forklaringen.
- **Referat:** ollama-URL, standardmodell + Hent modeller, standardspråk, «Åpne malmappe» + forklaring.
- **Avansert:** `DisclosureGroup("Modellinstruks (engelsk)")` med `TextEditor` `.frame(minHeight: 160)`, plassholderforklaring, Tilbakestill; seksjon «Hugging Face» med `HStack { Text(hfLoginCommand).monospaced; CopyButton(text: hfLoginCommand) }` og evt. nøkkelring-kommandoen med egen `CopyButton`.
Alle paneler: `Form { … }.formStyle(.grouped)`, ingen fast høyde — vinduet følger panelet.

```swift
struct CopyButton: View {
    let text: String
    @State private var copied = false
    var body: some View {
        Button(copied ? "Kopiert" : "Kopier", systemImage: copied ? "checkmark" : "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        }
        .controlSize(.small)
        .accessibilityLabel(copied ? "Kopiert" : "Kopier kommandoen")
    }
}
```

- [ ] **Step 4: Bygg, bundle, ⌘, — sjekk at tittelen følger fanen og at vinduet endrer størrelse. Selfcheck. Commit.**

```bash
git commit -m "Innstillinger som paneler: vanlige valg først, prompt og kommandoer under Avansert"
```

- [ ] **Step 5: Kommentar på #40 (fase 3). Tomtilstandens oppsettsjekk kom i Task 2; nevn den her.**

---

## Fase 4 — Dokumentpolish

### Task 7: Transkripsjonen som dokument, med søk

**Files:**
- Modify: `Sources/Schous/SpeakerEditorView.swift`, `Sources/Schous/SchousApp.swift`
- Test: `Sources/Schous/Selfcheck.swift`

**Interfaces:**
- Produces: `func matches(_ segment: Segment, query: String) -> Bool` (fri funksjon i `Segment.swift`; tom query = alle), `Notification.Name.focusSearch`, `.toggleInspector`.

- [ ] **Step 1: Sjekk**

```swift
let seg = Segment(start: 1, end: 2, speaker: "SPEAKER_00", language: "no", text: "Møtet begynte klokka ni.")
check(matches(seg, query: ""), "tom query treffer alt")
check(matches(seg, query: "MØTET"), "søket er ufølsomt for store bokstaver")
check(matches(seg, query: "motet"), "søket er ufølsomt for diakritika")
check(!matches(seg, query: "ti"), "ikke-treff")
```

- [ ] **Step 2: Implementer**

```swift
func matches(_ s: Segment, query: String) -> Bool {
    let q = query.trimmingCharacters(in: .whitespaces)
    return q.isEmpty || s.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
}
```
Dokumentkolonnen:
```
ScrollView {
  LazyVStack(alignment: .leading, spacing: 14) {
    ForEach(shown) { s in
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Button(tid) { kopier tid til pasteboard }.buttonStyle(.plain).font(.caption.monospacedDigit()).foregroundStyle(.secondary).help("Kopier tidsstempel")
          Text(label(s.speaker)).font(.caption.weight(.semibold)).foregroundStyle(color).padding(.horizontal, 6).padding(.vertical, 1).background(color.opacity(0.12), in: Capsule())
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
```
Søk: `@State private var query = ""`, `@FocusState private var searchFocused: Bool`. `ToolbarItem(placement: .principal) { TextField("Søk", text: $query).textFieldStyle(.roundedBorder).frame(width: 200).focused($searchFocused) }`. Trefftall ved siden av (`"\(shown.count) treff"` når query ikke er tom). `.onReceive(.focusSearch) { searchFocused = true }`, `.onReceive(.toggleInspector) { wantsInspector.toggle() }`.
`SchousApp.commands`: `CommandGroup(after: .sidebar) { Button("Søk i transkripsjonen") { post(.focusSearch) }.keyboardShortcut("f"); Button("Vis eller skjul inspektør") { post(.toggleInspector) }.keyboardShortcut("t", modifiers: [.command, .option]) }`. Fjern `.keyboardShortcut` fra toolbar-knappen. `.defaultSize(width: 900, height: 620)` på `Window`. «Lagre» → «Eksporter» både i toolbar (Menu-tittel) og i Fil-menyen; ⌘S beholdes.

- [ ] **Step 3: Bygg, bundle, prøv ⌘F og ⌘⌥T fra Vis-menyen. Selfcheck. Commit.**

```bash
git commit -m "Transkripsjonen leses som et dokument: bredde, rytme, søk og tidsstempler som kan kopieres"
```

### Task 8: Rendret Markdown (#41)

**Files:**
- Create: `Sources/Schous/Markdown.swift`
- Modify: `Sources/Schous/SummaryView.swift`
- Test: `Sources/Schous/Selfcheck.swift`

**Interfaces:**
- Produces:
  ```swift
  enum MarkdownBlock: Equatable { case heading(Int, String), bullet(String), task(Bool, String), numbered(Int, String), paragraph(String), blank
      static func parse(_ text: String) -> [MarkdownBlock] }
  struct MarkdownView: View { let text: String }
  ```

- [ ] **Step 1: Sjekk**

```swift
let md = "# Tittel\n\n## Del\n- punkt\n- [ ] åpen\n- [x] gjort\n1. første\nVanlig **fet** tekst\n<aside>hopp</aside>\n"
let blocks = MarkdownBlock.parse(md)
check(blocks == [.heading(1, "Tittel"), .blank, .heading(2, "Del"), .bullet("punkt"), .task(false, "åpen"),
                 .task(true, "gjort"), .numbered(1, "første"), .paragraph("Vanlig **fet** tekst")],
      "markdown-blokker: \(blocks)")
```
(`<aside>`-linjer hoppes over; avsluttende tomlinje gir ingen `.blank`.)

- [ ] **Step 2: Implementer**

`parse`: `text.split(separator: "\n", omittingEmptySubsequences: false)`, trim høyre; regler i rekkefølge: tom → `.blank` (men ikke aller siste), `<`-start → hopp, `#{1,6} ` → heading, `- [ ] `/`- [x] ` → task, `- `/`* ` → bullet, `^\d+\. ` → numbered, ellers paragraph. Fjern etterfølgende `.blank`.
`MarkdownView`: `VStack(alignment: .leading, spacing: 6)` med `ForEach(Array(blocks.enumerated()), id: \.offset)`: heading 1 → `.title2.bold()`, 2 → `.title3.semibold()`, 3+ → `.headline`; bullet → `HStack(alignment: .top) { Text("•"); inline(text) }`; task → `Image(systemName: done ? "checkmark.square" : "square")`; numbered → `Text("\(n).")`; paragraph → `inline(text)`; blank → `Spacer().frame(height: 4)`. `inline(_:)` = `Text((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s))`. Alle `.textSelection(.enabled)`.
`SummaryPanel`: rått (`Text`) mens `summarizer.state == .running`, `MarkdownView` ellers. Toolbar-knapp/`ToolbarItem` i editor når fanen er Referat: `Button("Kopier referat") { pasteboard ← summarizer.text }`.

- [ ] **Step 3: Bygg, bundle, åpne en jobb med referat. Selfcheck. Commit.**

```bash
git commit -m "Referatet rendres som tekst, ikke som Markdown-tegn"
```

### Task 9: Tittel og filnavn (#42)

**Files:**
- Modify: `Sources/Schous/Segment.swift`, `Sources/Schous/Summarizer.swift` (`Templates.slug`), `Sources/Schous/SpeakerEditorView.swift`, `Sources/Schous/SummaryView.swift`
- Test: `Sources/Schous/Selfcheck.swift`

**Interfaces:**
- Produces:
  ```swift
  func filenameSafe(_ s: String) -> String          // «/» og «:» → «-», trim, tomt → ""
  func outputBase(title: String, date: Date, fallback: String) -> String   // "2026-09-03 Tittel" eller fallback
  ```
  `SpeakerEditorView` har `@State private var title = ""` lagret som `title.txt` i jobbmappa, lest i `loadMapping`. `save` og `startSummary` bruker `outputBase(title:date:fallback: job.base)`. Datoen er inputfilas `creationDate`, ellers nå.

- [ ] **Step 1: Sjekker**

```swift
check(filenameSafe("Coast: intro / AI") == "Coast- intro - AI", filenameSafe("Coast: intro / AI"))
check(filenameSafe("  ") == "", "bare mellomrom er tomt")
let d = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .init(identifier: "Europe/Oslo"), year: 2026, month: 9, day: 3))!
check(outputBase(title: "Coast intro om AI-strategi", date: d, fallback: "Opptak-x") == "2026-09-03 Coast intro om AI-strategi",
      outputBase(title: "Coast intro om AI-strategi", date: d, fallback: "Opptak-x"))
check(outputBase(title: "", date: d, fallback: "Opptak-x") == "Opptak-x", "tom tittel = gammelt navn")
check(Templates.slug("A/B: test") == "a-b--test", Templates.slug("A/B: test"))
```

- [ ] **Step 2: Implementer**

```swift
func filenameSafe(_ s: String) -> String {
    s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
/// #42: dato først gir riktig sortering i Finder, tittelen sier hva møtet var.
func outputBase(title: String, date: Date, fallback: String) -> String {
    let t = filenameSafe(title)
    guard !t.isEmpty else { return fallback }
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
    return "\(f.string(from: date)) \(t)"
}
```
`Templates.slug` → `filenameSafe(name).lowercased().replacingOccurrences(of: " ", with: "-")`.
Tittelfeltet: øverst i Referat-fanen, `TextField("Tittel (blir filnavnet)", text: $title).accessibilityLabel("Tittel")`, med `Text("Tomt = \(job.base)").font(.caption)`. Flytt `@State title` til `SpeakerEditorView` og gi `SummaryControls` en `@Binding`. Lagres til `title.txt` ved `save`.
`save`: `written = try writeOutputs(job.segments, to: outputDir, base: exportBase, …)` der `exportBase = outputBase(title: title, date: inputDate, fallback: job.base)`. Statusen «Lagret TXT, SRT i Møtereferater» viser navnet: `"Lagret \(exportBase).{\(list)} i \(mappe)"` — nei, hold det lesbart: `"Lagret \(list) som «\(exportBase)» i \(mappe)"`.

- [ ] **Step 3: Bygg, selfcheck, bundle, lagre med og uten tittel — sjekk filnavnene i målmappa. Commit.**

```bash
git commit -m "Utdatafilene får dato og en tittel som sier hva møtet var"
```

- [ ] **Step 4: Kommentar på #40 (fase 4, med #41 og #42).**

---

## Fase 5 — Tilgjengelighet og mikrocopy

### Task 10: Etiketter, annonseringer, kontrast, høyder

**Files:**
- Modify: `Sources/Schous/SchousApp.swift`, `Sources/Schous/ContentView.swift`, `Sources/Schous/SetupViews.swift`, `Sources/Schous/SpeakerEditorView.swift`, `Sources/Schous/SummaryView.swift`

- [ ] **Step 1:** Menylinjas målere: `Text("System   \(meter(level))").accessibilityLabel("Systemlyd \(Int(level * 100)) prosent")`, tilsvarende «Mikrofon».
- [ ] **Step 2:** Annonseringer i `ContentView.onChange(of: job.state)`: `.done` → `AccessibilityNotification.Announcement("Transkripsjonen er ferdig").post()`, `.stopped(n)` → «Stoppet, \(n) segmenter er skrevet», `.failed` → «Transkripsjonen feilet», `.paused` → «Pauset», og i `SummaryControls.onChange(of: summarizer.state)`: `.done` → «Referatet er lagret», `.failed` → «Referatet feilet».
- [ ] **Step 3:** Grep etter `.caption2` og `.tertiary` i `Sources/` — erstatt med `.caption`/`.secondary`. Grep etter `.frame(height:` — bytt til `minHeight` der det er tekst (kontekst, prompt, logg).
- [ ] **Step 4:** Alle ikon-knapper har `.accessibilityLabel` eller tekst. `WorkflowStepper` leses som «Steg 3 av 4, Talere, aktivt».
- [ ] **Step 5:** Manuell runde med VoiceOver (⌘F5) gjennom tomtilstand → oppsett → editor + inspektør; Full Keyboard Access (Systemvalg → Tastatur) gjennom hovedflyten; «Øk kontrast» og «Reduser gjennomsiktighet» på. Noter det som ble sett i kommentaren. Det som ikke lar seg teste (låst skjerm, se CLAUDE.md) sies rett ut.
- [ ] **Step 6:** Bygg, selfcheck, commit:

```bash
git commit -m "Tilgjengelighet: etiketter på alt, statusendringer annonseres, ingen kritisk tekst i tertiær"
```

- [ ] **Step 7: Kommentar på #40 (fase 5) med akseptansekriteriene fra issuen avkrysset der de er oppfylt, og eksplisitt merket der de bare er delvis verifisert.**

---

## Dokumentasjon og PR

### Task 11: README, CLAUDE.md, skjermbilder, PR

- [ ] **Step 1: README.md** — «Use»: ny flyt (tomtilstand, stepper, «Åpne resultat» primær, Antall talere, Eksporter), snarveier (⌘F, ⌘⌥T, ⌘S = Eksporter), Innstillinger-paneler, «Meeting summary»: fasene og estimatet, tittelfeltet og filnavnet `<dato> <tittel>.<mal>.md`. Skjermbildenes alt-tekster.
- [ ] **Step 2: CLAUDE.md** — nytt avsnitt «Vinduet og inspektøren»: de tre oppsettsvisningene, hvorfor stepperen ikke er en wizard, `narrow`-terskelen 760 og hvorfor (620 minimum + 240 inspektør + luft), estimatene (`stepRates`/`summaryRates`, lineær tilnærming, «vanligvis»), Markdown-renderen (rått under strømming, hvorfor), søket (egen TextField, ikke `.searchable`, fordi fokus fra ⌘F ikke kan styres før macOS 15), `outputPath` i AppSettings, `Lagre` → `Eksporter` med ⌘S beholdt, tittel → `title.txt`, `finishedInfo`. Oppdater «Snarveier»-avsnittet og «Referat»-avsnittet der de nevner sidefeltet.
- [ ] **Step 3: Skjermbilder** — `./bundle.sh`, `open Schous.app --args --input <opptak med ferdig jobb>` → «Åpne resultat»; `screencapture -l $(osascript -e 'tell app "System Events" to id of window 1 of process "Schous"')` er ikke tilgjengelig — bruk `screencapture -w` interaktivt eller `-l <windowid>` fra `osascript -e 'tell application "System Events" to get id of first window of process "Schous"'`. Tre bilder: `docs/speakers.png` (editor med inspektør), `docs/progress.png` (aktiv jobb — krever en ekte kjøring; bruk et kort opptak), `docs/recording.png` (uendret hvis menyen er uendret). Låst skjerm gir «could not create image» — se CLAUDE.md.
- [ ] **Step 4: Alle sjekker:** `swift build`, `.build/debug/Schous --selfcheck`, `./bundle.sh`, `git status` (ingen media).
- [ ] **Step 5: Push og PR** mot `main` med `gh pr create`, tittel «En tydeligere, roligere og mer moderne Schous (#40)», body: sammendrag per fase, hva som er målt, hva som er manuelt verifisert og hva som ikke er, `Closes #40`, `Closes #39`, `Closes #41`, `Closes #42`. Avslutt med
  `🤖 Generated with [Claude Code](https://claude.com/claude-code)` og sesjonslenken.
- [ ] **Step 6: Siste kommentar på #40 med lenke til PR-en.**
