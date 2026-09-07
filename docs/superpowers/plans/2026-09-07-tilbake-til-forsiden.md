# Tilbake til forsiden (#48) — implementasjonsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gi en vei tilbake til tomtilstanden etter at en fil er valgt, og la oppsettet starte et opptak selv: «Fjern» på filkortet, «Ny» ⌘N i Fil-menyen, «Start opptak» i oppsettet ([#48](https://github.com/Oschlo/schous/issues/48)).

**Architecture:** Én tilstandsendring, `input = nil` i `ContentView`, nådd fra to steder som deler samme funksjon (`open(nil)`). Menyen følger mønsteret som alt står: den poster `.newFile`, `ContentView` handler, og en kjørende jobb ignorerer den stille som «Åpne…». «Start opptak» i oppsettet er nøyaktig knappen fra tomtilstanden, ingen ny tilstand; det ferdige opptaket forhåndsvelges av `lastRecording` som før.

**Tech Stack:** Swift 6 / SwiftUI, SwiftPM uten Xcode, macOS 14.2+. Test = `--selfcheck` i `Sources/Schous/Selfcheck.swift` (uendret her), pluss én målt runde gjennom bundlen med System Events. Bundle = `./bundle.sh`.

**Spec:** issue #48 (kopieres inn i PR-beskrivelsen).

## Global Constraints

- Gren `forsiden`, én PR mot `main` med `Closes #48` i body (engelsk nøkkelord, resten norsk). Ingen commits på main.
- `swift build` og `.build/debug/Schous --selfcheck` → `selfcheck ok` etter hver task. `./bundle.sh` før noe kjøres som app (TCC, se CLAUDE.md «Signering»).
- Layoutskjemaet fra #40: systemkontroller, `.borderless` for sekundærhandlinger i kortet, «…» bare på knapper som åpner et panel, én etikett per kontroll (ingen `.accessibilityLabel` oppå en knapp med tekst), ingen ny `@State` i visningene.
- Menyene sier fra, de handler ikke: nytt menyelement poster en `Notification.Name` i `SchousApp.swift`, `ContentView` lytter med `.onReceive`.
- Steg 1 «Fil» i `WorkflowStepper` røres ikke.
- Snarveien er ⌘N. Ingen `[`/`]` (⌥8/⌥9 på norsk tastatur).
- Norsk bokmål i UI. Hjelpetekster er hele setninger med punktum, som de som finnes.
- Ingen media eller transkripsjoner i `git status` etter målingen.
- Commit-meldinger på norsk, avsluttet med
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` og
  `Claude-Session: https://claude.ai/code/session_01FUwaX5aFDndj91ExNtrxjL`.

## Filstruktur

| Fil | Endring |
|---|---|
| `Sources/Schous/ContentView.swift` | `open(_:)` tar `URL?`; `nil` er forsiden. Lytter på `.newFile`. Sender `clear` til `JobSetupView`. |
| `Sources/Schous/SetupViews.swift` | `JobSetupView`: «Fjern» ved siden av «Bytt fil…», «Start opptak» under kortet. |
| `Sources/Schous/SchousApp.swift` | «Ny» ⌘N i Fil-menyen, `Notification.Name.newFile`. |
| `README.md` | ⌘N i punkt 1 og i snarveitabellen. |
| `CLAUDE.md` | «Menyene sier fra»: fem meldinger. |

---

### Task 1: «Fjern» og «Start opptak» i oppsettet

**Files:**
- Modify: `Sources/Schous/ContentView.swift:30-38` (kall til `JobSetupView`) og `:132-140` (`open`)
- Modify: `Sources/Schous/SetupViews.swift:184-205` (`JobSetupView` felt og filkort)

**Interfaces:**
- Produces: `ContentView.open(_ url: URL?)` — `nil` setter `input = nil` og forlater editoren hvis den står der. Task 2 kaller `open(nil)` fra menymeldingen.
- Produces: `JobSetupView.clear: () -> Void`, nytt påkrevd felt.

- [ ] **Step 1: Gren**

```zsh
git switch -c forsiden
```

- [ ] **Step 2: `open` tar `URL?`**

I `Sources/Schous/ContentView.swift`, erstatt funksjonen og kommentaren over den:

```swift
    /// Ny fil valgt med vilje, eller `nil` for forsiden («Fjern», ⌘N): body
    /// velges på job.state, ikke på input, så editoren må forlates eksplisitt.
    /// Et ferdig opptak (`lastRecording`) går ikke hit — det bare
    /// forhåndsvelges, ellers rev opptaksstoppet ned editoren midt i talernavn
    /// som ikke var lagret, og avbrøt et referat.
    private func open(_ url: URL?) {
        input = url
        if job.state == .done { leaveEditor() }
    }
```

De eksisterende kallene (`dropDestination`, `onOpenURL`, `pickInput`) sender en `URL` og kompilerer uendret.

- [ ] **Step 3: Send `clear` inn i `JobSetupView`**

Samme fil, kallet i `body`:

```swift
                    JobSetupView(job: job, input: input, duration: duration, dropping: dropping,
                                 speakers: $speakers, pickInput: pickInput, pickOutput: settings.pickOutputFolder,
                                 clear: { open(nil) },
                                 start: start, openResult: { job.loadFinished(input: input) })
```

- [ ] **Step 4: Knappene i `JobSetupView`**

I `Sources/Schous/SetupViews.swift`, legg feltet til etter `pickOutput` og hent `Recorder` slik `EmptyStateView` gjør:

```swift
    let pickInput: () -> Void
    let pickOutput: () -> Void
    let clear: () -> Void
    let start: () -> Void
    let openResult: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var recorder = Recorder.shared
```

Erstatt `DropZone`-blokken øverst i `body` med kortet pluss opptaksknappen:

```swift
            DropZone(dropping: dropping, height: 88) {
                HStack(spacing: 12) {
                    FileHeader(input: input, duration: duration)
                    Spacer()
                    Button("Bytt fil…", action: pickInput).buttonStyle(.borderless)
                    Button("Fjern", action: clear).buttonStyle(.borderless)
                        .help("Legger bort fila og går tilbake til forsiden.")
                }
            }

            // Samme knapp som i tomtilstanden, på samme sted i forhold til
            // slippsonen. Det ferdige opptaket forhåndsvelges av lastRecording.
            if !recorder.isRecording {
                Button("Start opptak", systemImage: "record.circle") { recorder.start() }
                    .buttonStyle(.borderless)
                    .help("Tar opp systemlyd og mikrofon fra menylinja. ⌃⌥R fra hvilken som helst app.")
            }
```

- [ ] **Step 5: Bygg og selfcheck**

```zsh
swift build 2>&1 | tail -3 && .build/debug/Schous --selfcheck | tail -1
```

Forventet: ingen feil, siste linje `selfcheck ok`.

- [ ] **Step 6: Commit**

```zsh
git add Sources/Schous/ContentView.swift Sources/Schous/SetupViews.swift
git commit -m "«Fjern» og «Start opptak» i oppsettet: forsiden er nåbar igjen (#48)

input i ContentView ble aldri satt tilbake til nil, så tomtilstanden var
uoppnåelig etter første fil. open(_:) tar nå URL?, og nil er forsiden.
Start opptak er knappen fra tomtilstanden, ikke en ny tilstand.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01FUwaX5aFDndj91ExNtrxjL"
```

---

### Task 2: «Ny» ⌘N i Fil-menyen

**Files:**
- Modify: `Sources/Schous/SchousApp.swift:31-34` (`CommandGroup(replacing: .newItem)`) og `:80-85` (`Notification.Name`)
- Modify: `Sources/Schous/ContentView.swift:61-63` (`.onReceive` for `.openFile`)

**Interfaces:**
- Consumes: `ContentView.open(_ url: URL?)` fra Task 1.
- Produces: `Notification.Name.newFile` = `"co.oschlo.schous.newFile"`.

- [ ] **Step 1: Meldingen**

I `Sources/Schous/SchousApp.swift`, `extension Notification.Name`, først i lista:

```swift
extension Notification.Name {
    static let newFile = Notification.Name("co.oschlo.schous.newFile")
    static let openFile = Notification.Name("co.oschlo.schous.openFile")
```

- [ ] **Step 2: Menyelementet**

Samme fil, `CommandGroup(replacing: .newItem)`. «Ny» først, som i Finder og TextEdit:

```swift
            CommandGroup(replacing: .newItem) {
                // ⌘N er blankt ark: tilbake til forsiden, også fra editoren.
                Button("Ny") { NotificationCenter.default.post(name: .newFile, object: nil) }
                    .keyboardShortcut("n")
                Button("Åpne…") { NotificationCenter.default.post(name: .openFile, object: nil) }
                    .keyboardShortcut("o")
            }
```

- [ ] **Step 3: Lytteren**

I `Sources/Schous/ContentView.swift`, rett etter `.onReceive` for `.openFile`:

```swift
        .onReceive(NotificationCenter.default.publisher(for: .newFile)) { _ in
            if !isBusy { open(nil) }
        }
```

- [ ] **Step 4: Bygg og selfcheck**

```zsh
swift build 2>&1 | tail -3 && .build/debug/Schous --selfcheck | tail -1
```

Forventet: `selfcheck ok`.

- [ ] **Step 5: Commit**

```zsh
git add Sources/Schous/SchousApp.swift Sources/Schous/ContentView.swift
git commit -m "«Ny» ⌘N i Fil-menyen poster .newFile; ContentView går til forsiden (#48)

Samme mønster som «Åpne…»: menyen sier fra, visningen handler, og en
kjørende jobb ignorerer den stille.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01FUwaX5aFDndj91ExNtrxjL"
```

---

### Task 3: Måling gjennom bundlen

Ingen ny selfcheck: logikken er to tilordninger og en vakt som alt står. Det som *kan* gå galt er at knappen ikke kommer fram i layouten eller at ⌘N ikke når menyen, og det ser bare en kjørende app.

**Files:** ingen endringer. Trenger én lydfil som alt er transkribert (oppsettet viser «Åpne resultat»). Bruk en som finnes lokalt; ikke ta opp noe nytt.

- [ ] **Step 1: Bundle og start med fila valgt**

```zsh
./bundle.sh 2>&1 | tail -2
pkill -x Schous; sleep 1
open Schous.app --args --input "<sti til transkribert fil>"
sleep 3
```

- [ ] **Step 2: «Fjern» finnes, og fører til forsiden**

```zsh
osascript -e 'tell application "System Events" to tell process "Schous" to name of every button of window 1'
```

Forventet: lista inneholder `Bytt fil…`, `Fjern`, `Start opptak`, `Åpne resultat`.

```zsh
osascript -e 'tell application "System Events" to tell process "Schous" to click button "Fjern" of window 1'
sleep 1
osascript -e 'tell application "System Events" to tell process "Schous" to name of every button of window 1'
```

Forventet: `Velg fil…` og `Start opptak` i lista, ingen `Fjern`. Treffer ikke `click`, send et CGEvent (CLAUDE.md «`click at {x, y}` … når ikke alle `.plain`-knapper»); «Åpne resultat» i samme kort traff med `click` 2026-09-05, så det er ventet å virke.

- [ ] **Step 3: ⌘N fra oppsettet**

```zsh
pkill -x Schous; sleep 1
open Schous.app --args --input "<samme fil>"
sleep 3
osascript -e 'tell application "System Events" to tell process "Schous" to keystroke "n" using command down'
sleep 1
osascript -e 'tell application "System Events" to tell process "Schous" to name of every button of window 1'
```

Forventet: `Velg fil…` i lista, ingen `Fjern`.

- [ ] **Step 4: ⌘N fra editoren**

```zsh
pkill -x Schous; sleep 1
open Schous.app --args --input "<samme fil>"
sleep 3
osascript -e 'tell application "System Events" to tell process "Schous" to click button "Åpne resultat" of window 1'
sleep 2
osascript -e 'tell application "System Events" to tell process "Schous" to keystroke "n" using command down'
sleep 1
osascript -e 'tell application "System Events" to tell process "Schous" to name of every button of window 1'
```

Forventet: `Velg fil…` i lista, ingen `Tilbake` og ingen `Eksporter`.

- [ ] **Step 5: Ingen media i status**

```zsh
git status --short
```

Forventet: bare `docs/superpowers/plans/2026-09-07-tilbake-til-forsiden.md` som ny fil (`bench/` var der fra før). Skriv tallene fra steg 2–4 (hvilke knapper som sto) i PR-beskrivelsen.

---

### Task 4: Dokumentasjon og PR

**Files:**
- Modify: `README.md:188` (punkt 1) og `:219` (snarveitabellen)
- Modify: `CLAUDE.md:773-779` («Menyene sier fra»)
- Add: `docs/superpowers/plans/2026-09-07-tilbake-til-forsiden.md` (denne)

- [ ] **Step 1: README punkt 1**

Erstatt setningen som begynner `**Velg fil…** (⌘O).` slik at punktet ender:

```markdown
1. Drop an audio or video file anywhere in the window, or pick one with
   **Velg fil…** (⌘O). Schous is also listed under **Open With** in Finder, and
   a file dropped on the Dock icon opens the same way. Before a file is
   chosen, the window says whether the backend and the models are ready.
   **Fjern** on the file card, or **Ny** (⌘N) in the File menu, goes back to
   that front page; **Start opptak** is available on both.
```

- [ ] **Step 2: README snarveitabellen**

Ny rad først i tabellen, over `| Open a file | ⌘O |`:

```markdown
| New — back to the front page | ⌘N |
```

- [ ] **Step 3: CLAUDE.md**

Erstatt avsnittet «Menyene sier fra, de handler ikke» med:

```markdown
- **Menyene sier fra, de handler ikke.** `.commands` bor på scenen og vet
  ikke om vinduet viser oppsettet eller editoren, og `FocusedValue` er mer
  kode enn det er verdt for fem elementer. «Ny», «Åpne…», «Eksporter», «Søk i
  transkripsjonen» og «Vis eller skjul inspektør» poster derfor
  `.newFile`/`.openFile`/`.saveOutputs`/`.focusSearch`/`.toggleInspector`, og
  visningen som er framme lytter. Prisen: ⌘S og ⌘F utenfor editoren gjør
  ingenting, stille, og ⌘N/⌘O under en kjørende jobb likeså. Det er kjent og
  godtatt.
```

- [ ] **Step 4: Commit og PR**

```zsh
git add README.md CLAUDE.md docs/superpowers/plans/2026-09-07-tilbake-til-forsiden.md
git commit -m "README og CLAUDE.md: ⌘N og «Fjern» er veien tilbake til forsiden (#48)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01FUwaX5aFDndj91ExNtrxjL"
git push -u origin forsiden
gh pr create --title "Tilbake til forsiden: «Fjern», «Ny» ⌘N og «Start opptak» i oppsettet" --body-file - <<'EOF'
Closes #48

<issue-teksten fra #48 kopiert inn her>

## Målt

<knappelistene fra Task 3, steg 2–4>

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01FUwaX5aFDndj91ExNtrxjL
EOF
```

PR-en åpnes; merging er Hans Martins avgjørelse.
