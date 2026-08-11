# Schous

Minimal native macOS-frontend for
[mac-local-transcribe-with-diarization](https://github.com/Oschlo/mac-local-transcribe-with-diarization).

Dra inn en fil — eller ta opp systemlyden direkte fra menylinja — velg hvor
resultatet skal ligge, følg fremdriften, og gi talerne navn etterpå. SwiftUI,
ingen tredjepartsavhengigheter, ingen Xcode.

Navnet kommer fra Schous plass på Grünerløkka. Siden det ikke røper hva appen gjør,
setter `bundle.sh` Spotlight-søkeord på bundlen — søk på «transkribering» eller
«transcribe» finner den.

## Installere

Last ned `Schous.zip` fra [Releases](https://github.com/Oschlo/schous/releases),
pakk ut, og legg `Schous.app` i `/Applications`.

Appen er signert med et lokalt sertifikat, ikke notarisert hos Apple. Laster du
den ned i en nettleser, blir den satt i karantene og Gatekeeper nekter å åpne
den — **høyreklikk → Åpne** slipper den igjennom med signaturen sjekket.

`xattr -d com.apple.quarantine Schous.app` virker også, men slår av
signatursjekken helt, ikke bare notariseringskravet. Bruker du den, sjekk først
at du har den appen du tror:

```zsh
codesign --verify --strict -R \
  '=identifier "co.oschlo.schous" and certificate leaf = H"b300de7a202552c6323463dc139682eee3f704cb"' \
  Schous.app && echo ok
```

Ingen utskrift utenom `ok` betyr at bundlen er hel og signert med samme
sertifikat som forrige gang — som også er det mikrofon-, lydopptaks- og
`HF_TOKEN`-tilgangene henger på, så en app som ikke passerer ville spurt om alt
på nytt uansett.

Menylinja har **Se etter oppdateringer…**, og appen sjekker i tillegg stille én
gang i døgnet ved oppstart. Finner den en nyere utgivelse, tilbyr menyen å åpne
release-siden. Den installerer ikke selv; du bytter ut appen i /Applications.

## Bygge

```zsh
./bundle.sh          # → Schous.app
open Schous.app
```

Krever bare Command Line Tools (`xcode-select --install`). `swift build` alene holder
under utvikling; `bundle.sh` lager .app-bundlen som trengs for Dock-ikon og vindusfokus.

`./release.sh 0.2.0` tagger, bygger, og laster opp en release. Den må kjøres på
maskinen som har «Schous Dev»-signeringsidentiteten — se CLAUDE.md.

## Oppsett

Appen gjør ikke transkriberingen selv — den driver
[mac-local-transcribe-with-diarization](https://github.com/Oschlo/mac-local-transcribe-with-diarization)
som subprosess. Den må være installert og virke fra terminal først:

```zsh
git clone https://github.com/Oschlo/mac-local-transcribe-with-diarization.git
cd mac-local-transcribe-with-diarization
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -r requirements.txt
```

Du må også godta lisensene for `pyannote/speaker-diarization-community-1` og
`pyannote/segmentation-3.0` på Hugging Face med samme konto som tokenet tilhører.

Deretter, i appen — åpne Innstillinger (⌘,) og fyll inn:

- **Backend** — mappen der `transcribe.py` og `.venv/` ligger. «Test» kjører
  `transcribe.py --selfcheck` og bekrefter at venv-et fungerer.
- **HF_TOKEN** — Hugging Face-token for pyannote-diarization. Lagres i Keychain.

`ffmpeg` må være installert (`brew install ffmpeg`). Appen setter selv
`PATH=/opt/homebrew/bin:...`, siden en app startet fra Finder ikke arver Homebrew-PATH.

## Bruk

1. Dra en lyd- eller videofil inn i vinduet, eller velg den.
2. Velg output-mappe. Oppgi antall talere hvis du vet det (tomt = automatisk).
3. **Start transkribering.** Fremdriften viser steg 1–4 og segmentteller under steg 4.
4. **Pause** fryser prosessen (SIGSTOP) og holder modellene i minnet.
   **Stopp** avbryter — se advarselen under.
5. Når den er ferdig: gi talerne navn, slå sammen ID-er som er samme person, og **Lagre**.

Skriver `<navn>.txt`, `<navn>.srt` og `<navn>.json` til valgt mappe.

## Opptak fra menylinjen

Mikrofonikonet i menylinjen tar opp **systemlyd og mikrofon samtidig** — alt du
hører fra video, nettmøter og telefon, pluss din egen stemme.

1. **Start opptak.** Ikonet blir en opptaksring, og menyen viser en teller.
2. **Stopp opptak.** De to kildene mikses til én monofil,
   `Opptak-2026-08-10-1432.m4a`, i samme mappe som er valgt under «Lagre i».
3. Vinduet løftes med opptaket forhåndsvalgt. Derfra er det vanlig
   transkribering — du velger selv om og når.

Menyen viser hvilken mikrofon opptaket treffer — «Mikrofon: `<navn>`» — så du
ser det før du starter, ikke etterpå. Er tilgangen avslått, sier raden det, med
veien til å fikse det.

Første gang spør macOS om mikrofontilgang. Sier du nei, tas systemlyden opp
alene, som fortsatt er et brukbart opptak av et møte du bare lytter til.
**Skjermopptak-tillatelse trengs ikke** — systemlyden hentes med en Core
Audio-tapp, ikke med ScreenCaptureKit.

Du kan bytte lydutgang midt i et opptak — tappen henter lyden fra prosessene,
ikke fra enheten, så opptaket går uforstyrret videre.

En fil kan også forhåndsvelges ved oppstart, som er praktisk for testing:

```zsh
open Schous.app --args --input ~/Filmer/opptak.mp4
```

`open` sender bare argumenter til en *fersk* oppstart — er appen allerede i gang,
blir den bare aktivert og `--input` ignorert.

## Hvordan det henger sammen

Appen kjører backend-en som subprosess med arbeidsmappe satt til en jobbmappe under
`~/Library/Application Support/Schous/jobs/<hash av inputsti>/`. Backend skriver
`work/` (mellomresultater) og `output/` (fasit med `SPEAKER_00`-labels) dit.

Fasiten røres aldri av navngivingen — omdøping og sammenslåing leses fra `speakers.json`
i jobbmappen og påføres først når filene skrives til din output-mappe. Du kan endre navn
så mange ganger du vil uten å miste de opprinnelige labelene.

Jobbmappen er nøklet på inputstien, så `work/`-cachen overlever selv om du bytter
output-mappe. En avbrutt kjøring gjenopptas på steg 4 fordi lyduttrekk, diarization og
språkdeteksjon allerede ligger cachet.

## Begrensninger

Disse kommer fra backend-en og er filed som issues der:

- **Stopp under steg 4 mister alt transkribert arbeid.** Backend skriver ingenting før
  den er ferdig ([#3](https://github.com/Oschlo/mac-local-transcribe-with-diarization/issues/3),
  [#5](https://github.com/Oschlo/mac-local-transcribe-with-diarization/issues/5)).
  Appen advarer før den dreper prosessen.
- **Fremdrift oppdateres bare hvert 10. sekund under steg 4.** tqdm bruker
  `mininterval=10` når stderr ikke er en terminal
  ([#4](https://github.com/Oschlo/mac-local-transcribe-with-diarization/issues/4)).
- **Steg 2 viser rå tekst.** pyannotes fremdriftsbar skriver til stdout og lar seg ikke
  parse pålitelig — samme issue.
- **ffmpeg-feil er lite informative** ([#6](https://github.com/Oschlo/mac-local-transcribe-with-diarization/issues/6)).
- Ingen modell- eller språkvalg — backend eksponerer det ikke som flagg.
- Én fil om gangen.

Diarization deler av og til én person i flere `SPEAKER_xx`-ID-er. Det er derfor
taler-editoren har «slå sammen» og ikke bare omdøping.

## Egentest

```zsh
.build/debug/Schous --selfcheck
```

Kjører parserne mot ekte backend-output-linjer og sjekker tidsstempel- og SRT-format.
Med en sti til en ferdig kjøring sammenlignes output byte for byte mot backend-ens egne
filer:

```zsh
.build/debug/Schous --selfcheck \
  ~/Library/Application\ Support/Schous/jobs/<hash>/output/<navn>
```
