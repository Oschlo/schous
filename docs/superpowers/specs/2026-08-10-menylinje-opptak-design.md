# Menylinje-opptak av systemlyd

Ta opp systemlyd (video, telefon, møter) pluss mikrofon fra menylinja, og send
opptaket videre til transkribering når du vil.

## Bakgrunn

Appen tar i dag bare imot ferdige filer. Skal du transkribere et Teams-møte eller
en podkast, må du skaffe lydfila på egen hånd først. Denne funksjonen fjerner det
steget.

To funn fra utforskingen styrer designet:

**Backend mikser ned til mono.** `transcribe.py:31` kjører
`ffmpeg -ar 16000 -ac 1`. Flerkanals opptak gir derfor null gevinst gjennom dagens
pipeline. Verre: `ffmpeg -i src` plukker bare *første* lydspor i en fil, så et
opptak med systemlyd og mikrofon på hvert sitt spor ville stille droppe
mikrofonen. Vi mikser derfor selv, til ett spor.

**Systemlyd krever ikke skjermopptak.** Core Audio process taps
(`AudioHardwareCreateProcessTap`, macOS 14.2+) gir global systemlyd uten
ScreenCaptureKit. Verifisert med to prober før designet ble skrevet:

```
CreateProcessTap status: 0 tapID: 136
format status: 0 sr: 48000.0 ch: 2
...
tap: 0   aggregate: 0   ioproc: 0   start: 0
frames: 95744 peak: 0.011422167
```

95 744 frames på 2 sekunder ved 48 kHz, med signal i. ScreenCaptureKit ble vurdert
og forkastet: det ville krevd Skjermopptak-tillatelse og en falsk 2×2 px
videostrøm for å ta opp ren lyd.

## Arkitektur

Én ny fil, `Sources/Schous/Recorder.swift`. Alt annet er småendringer i
eksisterende filer.

```
CATap (global, stereo) ─┐
                        ├─→ privat aggregat-enhet ─→ IOProc ─→ mixDown() ─→ AVAudioFile
mikrofon (sub-enhet) ───┘         (default-utgang                            (mono AAC)
                                   som klokke)
```

Mikrofonen legges inn som sub-enhet i *samme* aggregat, med
`kAudioSubDeviceDriftCompensationKey`. Da leverer Core Audio begge kildene
sample-synkront i samme IOProc-callback, som separate buffere i én
`AudioBufferList`. Miksing blir da ren aritmetikk — ingen ring-buffere, ingen
tidsstempel-fletting, ingen ffmpeg-etterbehandling.

### `Recorder`

`@MainActor final class Recorder: ObservableObject`, singleton `.shared`.

| Medlem | Type | Rolle |
|---|---|---|
| `isRecording` | `@Published Bool` | driver menylinje-ikonet |
| `elapsed` | `@Published TimeInterval` | teller i menytittelen, oppdateres hvert sekund |
| `lastRecording` | `@Published URL?` | signalet `ContentView` lytter på |
| `errorMessage` | `@Published String?` | vises i menyen, tømmes ved neste `start()` |
| `start()` | | rigger tap, aggregat, IOProc, fil |
| `stop()` | | river ned i motsatt rekkefølge, publiserer `lastRecording` |

Tilstanden som ikke skal ut i UI-et — `tapID`, `aggregateID`, `procID`,
`AVAudioFile` — er private felt.

### Oppstartssekvens i `start()`

1. Finn default utgangsenhet og dens UID (aggregatet trenger en klokkekilde).
2. Finn default inngangsenhet og dens UID. Feiler dette, fortsett uten mikrofon.
3. `CATapDescription(stereoGlobalTapButExcludeProcesses: [])`, `isPrivate = true`,
   egen `uuid`.
4. `AudioHardwareCreateProcessTap`.
5. `AudioHardwareCreateAggregateDevice` med utgangsenheten og mikrofonen i
   `kAudioAggregateDeviceSubDeviceListKey`, og tappen i
   `kAudioAggregateDeviceTapListKey`. `kAudioAggregateDeviceIsPrivateKey = true`
   så enheten aldri dukker opp i Lydinnstillinger.
6. Les `kAudioDevicePropertyStreamConfiguration` på aggregatet for å vite hvor
   mange buffere og kanaler callbacken kommer til å få.
7. Opprett `AVAudioFile` i «Lagre i»-mappa.
8. `AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart`.

Hvert steg returnerer `OSStatus`. En liten `check(_ status: OSStatus, _ what: String) throws`
kaster ved alt annet enn `noErr`. `start()` fanger, legger meldingen i
`errorMessage` og kaller `stop()` for å rydde det som allerede er opprettet.

### Miksing

```swift
/// Summerer alle kanaler i alle buffere til ett mono-signal.
/// Summering, ikke gjennomsnitt: gjennomsnitt ville halvert både mikrofon og
/// systemlyd når begge er til stede, og gjort stille kilder utydelige.
/// Klippes hardt til [-1, 1] — sum av to høye kilder kan gå over.
func mixDown(_ buffers: [[Float]], frames: Int) -> [Float]
```

Ren funksjon, tar imot allerede utpakkede kanaler. `frames` er antallet callbacken
ber om; er et buffer kortere, klippes lesingen til det korteste. Ulik lengde skal
ikke kunne skje med driftskompensasjon på, men funksjonen skal ikke kunne lese
utenfor.

### Skriving

`AVAudioFile` med `AVFormatIDKey: kAudioFormatMPEG4AAC`, 48 kHz, 1 kanal, skrevet
direkte fra IOProc-blokka. Én `AVAudioPCMBuffer` allokeres ved `start()` og
gjenbrukes for hver callback, så miksingen ikke allokerer på sanntidstråden.

Det er en bevisst forenkling: IOProc kjører på en sanntidstråd, og filskriving der
kan i prinsippet gi et dropout. Konsekvensen er et klikk i opptaket, ikke tap av
opptaket. Merkes i koden:

```swift
// ponytail: skriver til fil fra RT-tråden. Hører du klikk i lange opptak,
// er oppgraderingen ring-buffer + egen skrivetråd.
```

### Filnavn og plassering

`Opptak-YYYY-MM-DD-HHmm.m4a` i mappa fra `UserDefaults` `"outputPath"`, med
`URL.downloadsDirectory` som fallback — samme kilde `ContentView` allerede bruker.
Finnes filen (to opptak innen samme minutt), legges `-2`, `-3` … på til navnet er
ledig.

### Menylinje

`MenuBarExtra` i `SchousApp`, ved siden av `WindowGroup` og `Settings`:

- Ikon: `waveform`, bytter til `record.circle.fill` i rødt under opptak.
- «Start opptak» / «Stopp opptak — 12:34».
- «Åpne Schous».
- `errorMessage` som deaktivert menyelement når den er satt.

`WindowGroup` får `id: "main"` så menyen kan bruke `@Environment(\.openWindow)`.

### Fra opptak til transkribering

`stop()` publiserer `lastRecording`. `ContentView` plukker den opp:

```swift
.onReceive(Recorder.shared.$lastRecording.compactMap { $0 }) { input = $0 }
```

og menyen kaller `openWindow(id: "main")` pluss `NSApp.activate()`. Du velger
talerantall og trykker «Start transkribering» selv. Ingen nytt UI, ingen endring i
`TranscriptionJob`.

## Feilhåndtering

| Situasjon | Oppførsel |
|---|---|
| Mikrofon nektet eller mangler | Ta opp systemlyd alene. Ingen feilmelding — det er et gyldig opptak. |
| Tap eller aggregat feiler | `errorMessage` i menyen, rydd opp, `isRecording = false`. |
| Kan ikke skrive til «Lagre i»-mappa | Feilmelding før opptaket starter, ikke etter. |
| Utgangsenhet byttes underveis | Aggregatet mister klokka og stopper. Kjent begrensning, dokumenteres i README. |
| Appen avsluttes under opptak | Tap og aggregat er private og dør med prosessen. Filen blir stående med det som rakk å bli skrevet. |

## Endringer i eksisterende filer

- `Sources/Schous/SchousApp.swift` — `MenuBarExtra`, `id: "main"` på `WindowGroup`.
- `Sources/Schous/ContentView.swift` — `.onReceive` som setter `input`.
- `Sources/Schous/Selfcheck.swift` — assertions for `mixDown` og filnavn-generering.
- `Resources/Info.plist` — `NSMicrophoneUsageDescription`,
  `LSMinimumSystemVersion` 14.0 → 14.2.
- `Package.swift` — `.macOS(.v14)` står; taps krever 14.2, som SwiftPM ikke kan
  uttrykke finere. Info.plist er den bindende grensa.
- `README.md` og `CLAUDE.md` — bruk og fallgruver.

## Testing

`--selfcheck` utvides, samme mønster som resten av appen:

- `mixDown` med to kjente buffere → forventet sum.
- Stereo → mono nedmiks.
- Klipping over 1.0 og under −1.0.
- Ulik bufferlengde → korteste vinner, ingen lesing utenfor.
- Filnavn-kollisjon → `-2`.

Manuell verifikasjon som ikke lar seg automatisere: ta opp et par minutter med
video spillende og egen tale samtidig, bekreft at begge kildene er hørbare i
resultatfila, og at den transkriberer.

## Utenfor omfang

- Separate spor per kilde og to backend-kjøringer for feilfri «meg vs. dem». Reell
  gevinst, men vesentlig større jobb — egen spec hvis diarization viser seg for
  upresis i praksis.
- Pause under opptak.
- Global hurtigtast.
- Valg av lydenhet i appen. Bruk systemets default.
- Nivåmåler i menyen.

## Risiko

Det ene ubeviste punktet: at mikrofonen som sub-enhet i aggregatet dukker opp som
eget buffer med forventet kanaltelling. Verifiseres først i implementasjonen, siden
proben utløser mikrofon-prompt. Faller den, er reserveløsningen `AVAudioEngine` på
mikrofonen separat og ffmpeg `amix=inputs=2:normalize=0` ved stopp — mer kode, men
samme brukeropplevelse.
