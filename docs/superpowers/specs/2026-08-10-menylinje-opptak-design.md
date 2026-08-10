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
CATap (global, stereo) ─→ privat aggregat-enhet ─→ IOProc ─→ mixDown() ─→ system.m4a ─┐
                              (default-utgang                                          ├─→ ffmpeg amix ─→ Opptak-….m4a
                               som klokke)                                             │
mikrofon ─→ AVAudioRecorder ─────────────────────────────────────────────→ mic.m4a ────┘
```

> **Rettet under implementasjon.** Designet under var opprinnelig å legge
> mikrofonen inn som sub-enhet i *samme* aggregat. Det virker ikke — se
> «Mikrofonen kan ikke ligge i aggregatet» lenger ned. Diagrammet over viser den
> løsningen som faktisk står i koden.

Mikrofonen tas opp for seg med `AVAudioRecorder`, og de to filene mikses med
ffmpeg ved stopp:

```
ffmpeg -y -i system.m4a -i mic.m4a \
  -filter_complex "[0:a][1:a]amix=inputs=2:duration=longest:normalize=0" \
  -ac 1 -c:a aac -b:a 128k Opptak-....m4a
```

`normalize=0` er ikke pynt: amix halverer som standard hver kilde etter antall
input, så et opptak der bare én part snakker av gangen ville blitt 6 dB for lavt.
ffmpeg er allerede et krav for backend, så dette koster ingen ny avhengighet.

### Mikrofonen kan ikke ligge i aggregatet

Målt, ikke antatt. Aggregat med bare utgangsenheten, to sekunder med lyd
spillende:

```
bare utgang (referanse)   create=0 start=0 bufs=[2]    calls= 129 peaks=[0.3589]
utgang+mik, main=utgang   create=0 start=0 bufs=[1, 2] calls=   3 peaks=[0.0000, 0.0000]
utgang+mik, main=mik      create=0 start=0 bufs=[1, 2] calls=   0 peaks=[0.0000, 0.0000]
utgang+mik, ingen main    create=0 start=0 bufs=[1, 2] calls=   0 peaks=[0.0000, 0.0000]
utgang+mik, uten drift    create=0 start=0 bufs=[1, 2] calls=   0 peaks=[0.0000, 0.0000]
bare mik                  create=0 start=0 bufs=[1, 2] calls=   0 peaks=[0.0000, 0.0000]
```

Kanallayouten ble altså akkurat som planlagt — `bufs=[1, 2]`, mikrofon mono og
tap stereo som separate buffere — men strømmen står stille. `create` og `start`
returnerer begge `noErr`; feilen er stum.

Gjentatt fra en ad-hoc signert `.app` med `NSMicrophoneUsageDescription` og
innvilget mikrofontilgang, for å utelukke at det var en TCC-effekt av å kjøre et
løst `swift`-skript:

```
mikrofontilgang: true
uten mikrofon: calls=175 peaks=[0.3589, ...]
med mikrofon : calls=3   peaks=[0.0000, ...]
```

Samme resultat. Reserveløsningen i «Risiko» ble derfor tatt.

### `Recorder`

`@MainActor final class Recorder: ObservableObject`, singleton `.shared`.

| Medlem | Type | Rolle |
|---|---|---|
| `isRecording` | `@Published Bool` | driver menylinje-ikonet |
| `elapsed` | `@Published TimeInterval` | teller i menytittelen, oppdateres hvert sekund |
| `lastRecording` | `@Published URL?` | signalet `ContentView` lytter på |
| `errorMessage` | `@Published String?` | vises i menyen, tømmes ved neste `start()` |
| `start()` | | ber om mikrofontilgang, rigger tap, aggregat, IOProc, filer |
| `stop()` | | river ned i motsatt rekkefølge, mikser, publiserer `lastRecording` |

Tilstanden som ikke skal ut i UI-et — `tapID`, `aggregateID`, `procID`,
`AVAudioFile` — er private felt.

### Oppstartssekvens i `start()`

1. `AVCaptureDevice.requestAccess(for: .audio)`. Nektet gir systemlyd alene.
2. Finn default utgangsenhet og dens UID (aggregatet trenger en klokkekilde).
3. `CATapDescription(stereoGlobalTapButExcludeProcesses: [])`, `isPrivate = true`,
   egen `uuid`.
4. `AudioHardwareCreateProcessTap`.
5. `AudioHardwareCreateAggregateDevice` med utgangsenheten alene i
   `kAudioAggregateDeviceSubDeviceListKey`, og tappen i
   `kAudioAggregateDeviceTapListKey`. `kAudioAggregateDeviceIsPrivateKey = true`
   så enheten aldri dukker opp i Lydinnstillinger.
6. Les `kAudioDevicePropertyStreamConfiguration` på aggregatet for å vite hvor
   mange buffere og kanaler callbacken kommer til å få.
7. Opprett `AVAudioFile` på en temp-fil. Sluttnavnet i «Lagre i»-mappa reserveres
   nå, men skrives først av miksesteget.
8. `AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart`.
9. `AVAudioRecorder` på mikrofonen, sist — feiler den, går systemlyden uansett.

Hvert steg returnerer `OSStatus`. En liten `check(_ status: OSStatus, _ what: String) throws`
kaster ved alt annet enn `noErr`. `start()` fanger, legger meldingen i
`errorMessage` og kaller `stop()` for å rydde det som allerede er opprettet.

### Miksing

```swift
func mixDown(_ list: UnsafeMutableAudioBufferListPointer,
             into out: UnsafeMutablePointer<Float>,
             capacity: Int) -> Int
```

Kanalene *innenfor* én kilde snittes — vanlig stereo→mono-nedmiks. Kildene *seg
imellom* summeres, og summen klippes til [-1, 1]. Etter at mikrofonen flyttet ut
av aggregatet ser denne funksjonen som regel bare tappen, men logikken for flere
kilder blir stående: den koster ingenting og er dekket av selfcheck.

Funksjonen tar `AudioBufferList` direkte, ikke Swift-arrays, fordi den kjører på
sanntidstråden og ikke får allokere. `capacity` er takhøyden i målbufferet; er en
kilde kortere enn de andre, styrer den korteste. Returnerer antall frames skrevet.

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

- Ikon: mikrofon-silhuetten fra appikonet, bytter til `record.circle.fill` under
  opptak. Menylinjen tegner ikonet som template-bilde og farger det selv etter
  lys/mørk meny, så det er formen, ikke fargen, som bærer tilstanden.
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
| ffmpeg mangler eller feiler | Behold systemlyd-fila og velg den. Feilmelding i menyen — opptaket går aldri tapt. |
| Tap eller aggregat feiler | `errorMessage` i menyen, rydd opp, `isRecording = false`. |
| Kan ikke skrive til «Lagre i»-mappa | Feilmelding før opptaket starter, ikke etter. |
| Utgangsenhet byttes underveis | Opptaket går videre. Målt: 338/376/375 callbacks og identisk peak før byttet, etter byttet og etter byttet tilbake. Tappen er global og uavhengig av hvilken enhet som er default; utgangsenheten er bare klokkekilde. |
| Appen avsluttes under opptak | Tap og aggregat er private og dør med prosessen. Filen blir stående med det som rakk å bli skrevet. |

## Endringer i eksisterende filer

- `Sources/Schous/SchousApp.swift` — `MenuBarExtra`, og `Window(id: "main")` i
  stedet for `WindowGroup`: `openWindow(id:)` mot en WindowGroup åpner et nytt
  vindu per opptak i stedet for å løfte det som finnes.
- `Sources/Schous/ContentView.swift` — `.onReceive` som setter `input`.
- `Sources/Schous/Selfcheck.swift` — assertions for `mixDown` og filnavn-generering.
- `Resources/Info.plist` — `NSMicrophoneUsageDescription`,
  `LSMinimumSystemVersion` 14.0 → 14.2.
- `Package.swift` — `.macOS("14.2")`. Strengformen finnes, så minstekravet kan
  uttrykkes presist; `.v14` ville sluppet gjennom kall som ikke finnes før 14.2.
- `icon.py` og `bundle.sh` — menylinje-ikonet, se under.
- `README.md` og `CLAUDE.md` — bruk og fallgruver.

### Menylinje-ikonet

Samme 16x16-sprite som appikonet, uten flisen bak, skrevet av `icon.py` som
`Resources/MenuBarIcon.png` (32 px = @2x for 16 pt) og lastet som template-bilde.
Hele appikonet krympet til menylinje-størrelse ble uleselig — flisen tok plassen.
PNG-en er et byggeartefakt på linje med `.icns` og er gitignorert; `bundle.sh`
kopierer den inn. `swift build` alene har ingen bundle å laste fra og faller
tilbake på et SF-symbol.

## Testing

`--selfcheck` utvides, samme mønster som resten av appen:

- `mixDown` med to kjente buffere → forventet sum.
- Stereo → mono nedmiks.
- Klipping over 1.0 og under −1.0.
- Ulik bufferlengde → korteste vinner, ingen lesing utenfor.
- Filnavn-kollisjon → `-2`.

Manuell verifikasjon, utført på ekte maskinvare:

- Opptak startet og stoppet fra menylinjen, fil skrevet til «Lagre i»-mappa som
  mono 48 kHz AAC og forhåndsvalgt i vinduet.
- Begge kildene bekreftet i miksen: et vindu der ingen systemlyd spilte målte
  `max_volume: -17.5 dB`, altså mikrofonen alene.
- Bytte av utgangsenhet midt i opptak påvirker ikke opptaket (se feiltabellen).
- Ett vindu etter gjentatte opptak, ikke ett per opptak.

## Utenfor omfang

- Separate spor per kilde og to backend-kjøringer for feilfri «meg vs. dem». Reell
  gevinst, men vesentlig større jobb — egen spec hvis diarization viser seg for
  upresis i praksis.
- Pause under opptak.
- Global hurtigtast.
- Valg av lydenhet i appen. Bruk systemets default.
- Nivåmåler i menyen.

## Risiko

Punktet som var ubevist da spec-en ble skrevet — mikrofonen som sub-enhet i
aggregatet — falt. Reserveløsningen ble tatt, med `AVAudioRecorder` i stedet for
`AVAudioEngine` fordi den skriver fila selv.

Det som står igjen: mikrofonen og systemlyden starter noen millisekunder fra
hverandre, og `amix` justerer ikke for det. For møtetranskribering er det uten
betydning. Skulle det vise seg å ha noe å si, er neste steg å stemple begge
strømmene med vertsklokka og legge inn forsinkelsen som `adelay`.
