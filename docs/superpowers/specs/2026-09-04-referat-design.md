# Møtereferat fra ollama

Når et møte er transkribert og talerne har fått navn, lag et referat etter en
valgt mal, med en valgt lokal modell, på et valgt språk. Referatet skrives til
output-mappa og vises i editoren.

Erstatter skissen i [#30](https://github.com/Oschlo/schous/issues/30) på to
punkter: maler i stedet for én fast prompt, og referat *kun etter* navngiving,
ikke som avkryssing før transkriberingen starter. Målingene i #30 står.

## Bakgrunn

Referatene er i dag laget for hånd med pi og en lokal Qwen-modell, med
maler av Notion-typen (Context / Summary format / Summary style) som prompt.
Det virker. Appen skal gjøre det samme, uten pi.

**Hvorfor ikke pi.** Oppsummering er ett kall uten verktøy. pi er Node fra
nvm, som en app startet fra Finder ikke har på PATH; den laster sine egne
pakker, sesjonslagring og `models.json` med skynøkler i klartekst. En app som
skaller ut til pi arver alt det uten å eie noe av det. Det appen trenger er ett
`POST` mot `localhost:11434`.

**Hvorfor ikke `--summarize` i transcribe.py.** Se
[backend#15](https://github.com/Oschlo/mac-local-transcribe-with-diarization/issues/15).
Talernavnene finnes bare i appen.

**Målt i #30 (macOS 26.6.1, M5), som er krav her:**

```
lengste ekte transkripsjon         10 015 ord ≈ 26k tokens
kontekst, gemma4:26b / qwen3.8:27b 262 144
prompt_eval_count uten num_ctx     25 953        → ingen chunking
think på, num_predict=32           svar: (tomt)  → think må av
think av                           svar: ok, 13 tokens
referat av 26k tokens              57 s          → må strømme, må ikke blokkere
```

**Målt i #32, gjelder her også:** ollamas mlx-runner ignorerer `format` stille;
thinking-modeller gir tomme svar uten `think: false`; gemma4:12b kan gå i
tenkesløyfe over 900 s. Referatet er fritekst, så `format` brukes ikke, men
fristen og `think` er ikke valgfrie.

## Arkitektur

Én ny fil, `Sources/Schous/Summarizer.swift`. Tre seedmaler i
`Resources/templates/`. Småendringer i Settings, SpeakerEditorView,
ContentView, TranscriptionJob, Segment og Selfcheck.

```
SpeakerEditorView ──「Lag referat」──▶ sidefelt: mal · modell · språk · kontekst
        │                                        │
        │ resolved (SPEAKER_00 → navn)           ▼
        └──────────────────────────────▶ Summarizer.run(...)
                                            │  POST /api/chat, stream: true, think: false
                                            │  NDJSON ─▶ @Published text (vokser)
                                            ▼
                              <output>/<base>.<slug>.md
                              <jobdir>/summary.<slug>.md
                              <jobdir>/context.txt
```

## Summarizer

```swift
@MainActor final class Summarizer: ObservableObject {
    @Published var text = ""
    @Published var state: State = .idle      // idle, running, done(URL), failed(String)
    func run(prompt: String, model: String, baseURL: URL,
             writeTo: [URL]) async
    func cancel()
}
```

**Kallet.** `POST {baseURL}/api/chat` med
`{"model", "messages": [{"role": "user", "content": prompt}], "stream": true, "think": false}`.
Én user-melding, ikke system + user: det som står i Innstillinger skal være
nøyaktig det som sendes, og en delt prompt gjør den påstanden usann.

**Strømming.** `URLSession.bytes(for:)`, én JSON-linje per bit. Feltet
`message.content` legges til `text` etter hvert; `message.thinking` ignoreres.
Sluttobjektet har `done: true` og `prompt_eval_count`, som logges. Teksten som
vokser i vinduet *er* fremdriften. Ingen ProgressView.

**`think: false` sendes alltid, også til modeller uten kapabiliteten.** Målt
2026-09-04 på ollama 0.33.3 mot `NbAiLab/borealis-instruct-preview:4b`
(`capabilities: [completion, vision]`): HTTP 200, normalt svar. Ingen
retry-gren uten `think`; den ville vært kode for et problem som ikke finnes.

**Frist.** `URLSessionConfiguration.timeoutIntervalForRequest = 120`. Det er
tid *mellom* to datapakker, ikke total tid, så et to timers møte får ta tiden
det tar, mens en modell i tenkesløyfe stoppes etter 120 s stillhet. Samme
argument som «Sjekkene i Innstillinger har en frist»: en frist som aldri er
sett utløse, er en frist man tror på. Selfcheck skal se den utløse.

*(Fristen ble 600 s i beb7a83: kald prefill på `qwen3.8:27b-mlx` med 18k tokens
målt til 117 s uten en pakke, så 120 s slo til før første token. Tabellen under
står som den var; CLAUDE.md er gjeldende.)*

**Feil som skal kunne skilles fra hverandre**, fordi #30 målte at de ellers
ser like ut:

| Symptom | Melding |
|---|---|
| forbindelse nektet | «ollama svarer ikke på {url} — kjør `ollama serve`» |
| HTTP 404 / «model not found» | «Modellen {m} finnes ikke — `ollama pull {m}`» |
| `done: true` og `text` tom | «Modellen svarte tomt. Den brukte trolig hele budsjettet på tenking; prøv en annen modell.» |
| ingen data på 120 s | «Ingen svar på 120 s — modellen henger, eller maskinen er full. Kjøringen er stoppet.» |
| kansellert | tilbake til `.idle`, ingen fil skrevet |

**Skriving.** Ved `done` skrives `text` til alle URL-ene i `writeTo`, én etter
én, samme «kan være delvis oppdatert»-melding som `save` i editoren hvis den
andre feiler.

## Prompt

Én redigerbar tekst i Innstillinger, lagret i `UserDefaults` under
`summaryPrompt`. Fire plassholdere byttes ut før sending, ren
strengerstatning:

| Plassholder | Verdi |
|---|---|
| `{template}` | malfila ordrett |
| `{language}` | `Norwegian` eller `English` |
| `{context}` | kontekstfeltet, eller `(none)` når tomt |
| `{transcript}` | transkripsjonen i TXT-form med oppløste navn |

Standardteksten er engelsk. Modellene følger engelske instrukser mest
pålitelig, og språket på selve referatet styres av `{language}` uansett:

```
You are writing a meeting summary. Follow the template below exactly:
its sections, its order and its style notes.

{template}

Additional context from the user:
{context}

Write the summary in {language}. Use the timestamps in the transcript
when citing what was said. Do not invent names or facts that are not
in the transcript.

Transcript:
{transcript}
```

«Tilbakestill» i Innstillinger setter standarden tilbake. Selfcheck bytter
plassholderne mot faste verdier og krever at ingen `{…}` står igjen, og at
`{transcript}` fikk nøyaktig TXT-renderingen.

**Transkripsjonen** er `[HH:MM:SS] Navn (no): tekst`, én linje per segment,
altså det TXT-eksporten allerede skriver. Tidsstemplene er det «cite your
sources» i malene peker på. Renderingen trekkes ut av `writeOutputs` til en
delt `transcriptText(_:names:)` i `Segment.swift`, så eksport og prompt ikke
kan drive fra hverandre. Byte-diffen mot backend i `--selfcheck` vokter den
som før.

## Maler

Mappe: `~/Library/Application Support/Schous/templates/`. Appen lister
`*.md` der, sortert på navn. Malnavnet er filnavnet uten `.md`. Slug er
malnavnet i små bokstaver med mellomrom byttet til `-`:
`Customer Call` → `customer-call`.

**Seeding.** `Resources/templates/` i repoet inneholder `Customer Call.md`,
`Discovery interview.md` og `Stand-Up.md`, kopiert inn av `bundle.sh`. Ved
første behov (editoren åpnes, eller Innstillinger) kopieres de til mappa over
*hvis mappa ikke finnes*. En tom mappe seedes ikke: den som sletter alle
malene har ment det.

Malene parses ikke. Notion-tipset øverst i to av dem går til modellen som
alt annet; den som vil ha det bort, sletter det i fila.

## Filer

| Fil | Hvor | Innhold |
|---|---|---|
| `<base>.<slug>.md` | output-mappa | referatet |
| `summary.<slug>.md` | jobbmappa | kopi, så en gjenåpnet jobb viser det |
| `context.txt` | jobbmappa | kontekstfeltet |

Én fil per mal, samme mal overskriver. `context.txt` er egen fil, ikke et
felt i `speakers.json`: den dekodes som `[String: [String: String]]`, og et
strengfelt ville knekket lesingen av gamle filer. Referatet er ikke et fjerde
`OutputFormat`; `writeOutputs` er en byte-eksakt port og skal ikke lære noe
backend ikke skriver.

## Innstillinger

Ny seksjon «Referat»:

- **ollama-URL**, tekstfelt, default `http://localhost:11434`.
- **Standardmodell**, Picker fylt fra `GET {url}/api/tags` når vinduet
  åpnes. Svarer ikke ollama, står det der som tekst, og den lagrede
  modellstrengen står urørt. Hentingen har 5 s frist.
- **Standardspråk**, Picker: Norsk / Engelsk.
- **Prompt**, `TextEditor` med teksten over, og «Tilbakestill».
- **«Åpne malmappe»**, `NSWorkspace.open` på mappa, seeder først om nødvendig.

Alt i `UserDefaults`: `ollamaURL`, `summaryModel`, `summaryLanguage`,
`summaryPrompt`.

## Editoren

Editoren har allerede riktig grunnform: innhold til venstre, handlinger til
høyre. Referatet legges inn i den forma i stedet for ved siden av den.
Høyrekolonnen er hele arbeidsflyten ovenfra og ned, venstrekolonnen viser det
steget produserer.

```
┌ Schous — Opptak-2026-08-26-1301 ─────────────────────────────────────────────┐
│ ‹ Tilbake            Lagret TXT, SRT i meeting notes            [ Lagre ▾ ]  │
├────────────────────────────────────┬─────────────────────────────────────────┤
│  ( Transkripsjon | Referat )       │  Talere                                 │
│                                    │   ● SPEAKER_00   [ Hans Martin      ]   │
│  00:00:07  Hans Martin  en         │     Egen person ▾                       │
│  Mm-hmm.                           │                                         │
│                                    │  Referat                                │
│                                    │   Mal      [ Stand-Up          ▾ ]      │
│                                    │   Modell   [ qwen3.8:27b-mlx   ▾ ]      │
│                                    │   Språk    [ Norsk             ▾ ]      │
│                                    │   Kontekst [                     ]      │
│                                    │            [ Lag referat ]              │
│                                    │   Referat lagret · Vis i Finder         │
└────────────────────────────────────┴─────────────────────────────────────────┘
```

**Sidefeltet får seksjonen «Referat» under «Talere»**, ikke et ark. Mal
(Picker over mappa), modell (Picker fra `/api/tags`, forhåndsvalgt fra
Innstillinger), språk (forhåndsvalgt), kontekst (`TextEditor`, lastet fra
`context.txt` hvis den finnes), og knappen «Lag referat». Et ark ville skjult
transkripsjonen i det øyeblikket du skal skrive hvem som var med, og
rekkefølgen «navngi, så lag referat» må da forklares i stedet for å stå der.

Ingen maler i mappa: seksjonen sier det og tilbyr «Åpne malmappe».
Modellista tom: seksjonen sier at ollama ikke svarer, og knappen er
deaktivert.

**«Lag referat» lagrer først.** Navnene fryses i det øyeblikket kjøringen
starter, så det er det naturlige punktet å skrive TXT/SRT/JSON til
utdatamappa, samme `save(AppSettings.shared.formats)` som «Lagre». Feiler
lagringen, starter ikke referatet. «Lagre» står igjen for den som vil lagre
uten referat, eller lagre på nytt etter en navneendring. Endrer du et navn
etter at referatet er laget, er det en ny kjøring.

**Referatet er en fane i venstrekolonnen**, ikke en `VSplitView`. En
segmentert `Picker` «Transkripsjon | Referat» øverst i kolonnen; Referat-fanen
finnes bare når det er tekst å vise. Når kjøringen starter, byttes til
Referat og `summarizer.text` strømmer inn i full høyde, markerbar. To
scrollfelt som deler høyden ville gitt to små vinduer på én lang
transkripsjon og ett langt referat.

Mens det kjører er knappen «Stopp», og under den står «Referat … {sek} s».
Etterpå «Referat lagret som {fil}» med «Vis i Finder». Feil vises samme sted,
rødt. Verktøylinjas status brukes bare til «Lagret …» som i dag.

Fanen viser et tidligere `summary.<slug>.md` fra jobbmappa når editoren
åpnes med en jobb som har ett. Finnes flere, vises det nyeste.

**Verktøylinja**: «Ny fil» blir «‹ Tilbake» i leading-posisjon. Det er det
knappen allerede gjør: jobben settes til idle, fila står fortsatt valgt i
oppsettet, og bytte fil skjer der. Vinduet får `navigationTitle(job.base)`,
så hva du ser på står i tittelen i stedet for ingen steder.

## Gammel jobb uten ny transkribering

I dag kjører `start()` alltid backend, og steg 4 går i sin helhet på nytt
(målt 1m17s for 10m54s lyd i #30). Uten dette kan ingen lage referat av et
møte fra forrige uke.

Når en fil er valgt og `jobDirectory(for:)` har `output/<base>.json` og
*ikke* `work/<base>.partial.jsonl`, viser hovedvinduet linja «Denne fila er
transkribert tidligere» og knappen **«Åpne resultat»** ved siden av «Start
transkribering». Knappen kaller `job.loadFinished(input:)`, som setter
`base`, `jobDir`, `segments` og `state = .done`.

Ikke en stille snarvei inne i `start()`, som #30 foreslo: den som endrer
«Talere» og trykker Start skal få en ny kjøring, ikke forrige svar.

## Selfcheck

- NDJSON-parseren mot ordrette ollama-linjer: en bit med bare `thinking`, en
  med `content`, og sluttobjektet med `done: true` og `prompt_eval_count`.
  Tekst skal være summen av `content`, aldri `thinking`.
- Fristen: `Summarizer` mot en lokal `URLProtocol`-stubb som svarer én bit og
  så tier, med fristen satt til 1 s. Kravet er at `state` blir `.failed` med
  stillhetsmeldingen *og* at det tok under 2 s. Meldingen alene beviser
  ingenting; se «Sjekkene i Innstillinger har en frist».
- Tomt svar: stubb som sender `done: true` uten `content` → den egne
  meldingen, ikke nettverksfeil.
- Plassholderne: alle fire byttet, ingen `{` igjen, `{transcript}` lik
  `transcriptText`.
- Slug: `Customer Call` → `customer-call`, `Stand-Up` → `stand-up`.
- `transcriptText` dekkes av den eksisterende byte-diffen: `writeOutputs`
  kaller den.

## Utenfor denne

- Chunking og map-reduce. 26k av 262k; ta det opp ved et fire timers opptak.
- Skymodeller.
- Referat-valg før transkribering starter. Navnene finnes ikke da.
- Editor for `.stopped(n)`. Egen sak.
- `md` som `OutputFormat`.
- Talernavn fra modell (#32, avsluttet) eller deltakerliste (#34).
  Kontekstfeltet er det feltet #34 vil trenge; det noteres der.
- Kø (#31). `Summarizer.run` tar prompt, modell og målfiler som argumenter,
  ikke visningen, så en auto-modus kan kalle den senere.

## Issues

- #30 oppdateres: maler, kun etterpå, redigerbar prompt, språk. Lukkes av
  PR-en.
- #34 får en kommentar om `context.txt`.
