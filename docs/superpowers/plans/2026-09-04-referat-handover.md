# Referat — status ved avslutning 2026-09-04 ca. 15:30

Grenen `referat`, pushet til origin (uten PR). Alle sju tasks i
`docs/superpowers/plans/2026-09-04-referat.md` er implementert, hver med
task-review (spec + kvalitet) og fikserunder der reviewen fant noe.
Selfcheck er grønn på HEAD (beb7a83). Det som IKKE er gjort: sluttreview av
hele grenen, push, PR, kommentar på #34.

## Commits på grenen (over d294f2b)

```
b9102bf  T1  transcriptText ut av writeOutputs (byte-diff mot ekte jobb grønn)
cd54925  T2  prompt, maler i App Support, slug
b92a26a  T2  fiks: ett gjennomløp av prompten (ikke kjedet erstatning)
1d1bd57  T3  strømmende ollama-klient, frist, fire feil
6c4a025  T3  fiks: cancel() eier .idle, kansellerings-selfcheck, think:false målt på ledningen
0df2b43  T4  Innstillinger «Referat»
1d22c31  T5  editoren: sidefelt, fane, Tilbake
1a4be47  T6  «Åpne resultat»
1d1cc74  T7  seedmaler, bundle.sh, CLAUDE.md, README
beb7a83  fiksbølge: strupet publisering (≤10 Hz), frist 600 s, README med tallene, isCancelled-guard først
```

## Målt i dag

- Selfcheck: `timeoutIntervalForRequest` utløste på halvåpen respons etter
  1,08 s. `nc -z` som readiness-probe spiste `nc -l` sin ene forbindelse;
  proben er `lsof -sTCP:LISTEN`.
- Ekte kjøring, 10 015 ord, qwen3.8:27b-mlx: `prompt_eval_count=18279`
  av context 32768 → `num_ctx` trengs ikke.
- **Kald kjøring feilet**: 117 s prefill uten en eneste pakke, 120 s-fristen
  slo til før første token.
- Varm kjøring: ollama ~6 min, deretter appen ~7 min på 100 % CPU
  (re-render av hele editoren per token, `SpeakerEditorView.sidebar` varm i
  `sample`). Total 13 min 38 s.
- Referatet: norsk, alle seksjoner, ekte navn (null `SPEAKER_`). Modellen
  gjengir malens egen «Context»-instruks øverst → #36.

## Oppsett det ble testet på (for å gjenta et annet sted)

Maskin: Apple M5, 32 GB, macOS 26.6.2. ollama 0.33.3 på `http://localhost:11434`
(Ollama.app, ikke brew). Modeller som lå installert (`ollama list`):

```
qwen3.8:27b-mlx                                 nvfp4    18.2 GB   ← ekte referat-kjøring (Discovery interview, norsk)
NbAiLab/borealis-instruct-preview:12b           Q4_K_M    8.7 GB   ← ble standardmodell i Innstillinger (første i lista), kun vist i picker, ikke kjørt
NbAiLab/borealis-instruct-preview:4b            Q4_K_M    3.3 GB   ← think:false-målingen i spec-en (modell uten thinking → HTTP 200)
gemma4:26b-mlx                                  nvfp4    17.6 GB
gemma4:12b                                      Q4_K_M    7.6 GB   ← tenkesløyfe > 900 s i #32, grunnen til fristen
qwen3.5:9b                                      Q4_K_M    6.6 GB
hf.co/BobTheShoplifter/borealis2-26b-a4b-preview-GGUF:Q4_K_M    18.0 GB
```

Minste oppsett som reproduserer dagens måling: `ollama pull qwen3.8:27b-mlx`
(krever Apple Silicon med nok minne til 18 GB modell + 18k tokens kontekst;
32 GB holdt). `--selfcheck` trenger ingen modell og ingen ollama; den bruker
`nc -l` på 127.0.0.1:11501–11506.

Innstillinger-verdier som ble brukt: `ollamaURL` = standard, `summaryModel` =
`qwen3.8:27b-mlx` valgt i editoren for kjøringen, `summaryLanguage` = Norsk,
`summaryPrompt` = standard. Kontekstfeltet stod tomt.

## Neste steg, i rekkefølge

1. Fiksbølgen er committet (beb7a83) men ikke reviewet — sluttreviewen
   under må lese den med.
2. Sluttreview av hele grenen (`git diff d294f2b..HEAD`).
3. PR mot main med body fra
   «PR-body» nederst her,
   `Closes #30`. Ikke merge.
4. Kommentar på #34 (teksten står i plan Task 7 steg 7).

## Utsatt (fra reviewene), ikke blokkerende

- Selfcheck legger fake-jobb under ekte `~/Library/Application Support/Schous/jobs/`
  og rydder bare ved suksess (check() exiter). Pid-fritt navn + removeItem
  ved start er billigste mitigering.
- `SummaryControls.task` setter `model = settings.summaryModel` uten å
  sjekke at den finnes i `models` → blank Picker, «ollama pull»-feil.
  Innstillinger har «(ikke installert)»-mønsteret.
- `Templates.slug` stripper ikke `/` `:` eller doble mellomrom.
- `write(to:)` stopper ved første feil; «delvis oppdatert»-teksten lover mer.
- `state = .done(writeTo[0])` trapper på tom liste. `URLSession` invalideres
  aldri. `terminate()` i selfcheck dreper bare `sh`, sub-shell lever til
  `hold` går ut.
- `SummaryPanel` auto-scroller ikke under strømming. «Tilbake» er ikke
  deaktivert under kjøring (kjøringen fullfører likevel).
- `NSLog` fra `open`-startet bundle vises ikke i `log show`; bytt til
  `Logger` hvis tallet skal kunne leses etterpå.
- Stand-Up-kjøringen (to `.md` side om side) er ikke kjørt.

## Avgjørelser tatt uten deg

- Commit-trailere bruker denne øktas sesjonslenke, ikke planens.
- Selfcheck følger planen (nc, < 4 s), ikke spec-en (URLProtocol, < 2 s).
- `Summary.prompt` ble ett gjennomløp (regex) i stedet for kjedet
  `replacingOccurrences`; mal med bokstavelig `{transcript}` overlever.
- `cancel()` setter `.idle` selv; et kansellert Task rører ikke `state`.
- Etter «Stopp» blir Referat-fanen stående med delteksten (spec vinner over
  planens gjennomgangstekst).
- Frist 600 s (ikke 120): kald prefill målt til 117 s; think:false dekker
  tenkesløyfa fristen var til for; «Stopp» finnes.
- Fiksbølgen ble sendt før sluttreviewen for å rekke det i dag; den er
  ikke reviewet.

## PR-body (klar til `gh pr create --base main --head referat --body-file`)

```markdown
Etter navngiving i editoren: velg mal, ollama-modell og språk i sidefeltet under «Talere», trykk «Lag referat». TXT/SRT/JSON lagres først, så strømmes referatet inn i en fane «Transkripsjon | Referat» og skrives til `<base>.<mal>.md` i utdatamappa (og `summary.<mal>.md` + `context.txt` i jobbmappa). «Ny fil» ble «‹ Tilbake», vinduet fikk tittel. En fil som er transkribert før kan åpnes rett i editoren med «Åpne resultat» uten ny kjøring av backend.

Spec: `docs/superpowers/specs/2026-09-04-referat-design.md`. Plan: `docs/superpowers/plans/2026-09-04-referat.md`.

## Hva som endrer seg

- `Summarizer.swift` (ny): `POST /api/chat` med `stream: true, think: false`, NDJSON via `URLSession.bytes`, fire adskilte feil (nektet / 404 / tomt svar / stillhet), kansellering til `.idle` uten fil. Prompten er én redigerbar tekst i Innstillinger med `{template} {language} {context} {transcript}`; `{transcript}` er `transcriptText`, samme funksjon som TXT-eksporten.
- Maler er `*.md` i `~/Library/Application Support/Schous/templates/`, seedet fra `Resources/templates/` bare når mappa ikke finnes. Tre seedmaler følger med.
- Innstillinger: ollama-URL, standardmodell fra `/api/tags`, språk, prompt med «Tilbakestill», «Åpne malmappe».
- `TranscriptionJob.finishedOutput/loadFinished` + «Åpne resultat».
- `writeOutputs` er uendret i output; TXT-renderingen er trukket ut som `transcriptText` og byte-diffen i `--selfcheck` vokter begge.

## Målt (2026-09-04, ollama 0.33.3, M5)

```
selfcheck: frist mot nc -l med halvåpen respons     utløste etter 1,08 s (krav: melding OG < 4 s)
           nc -z som readiness-probe                spiste nc -l sin ene forbindelse → lsof -sTCP:LISTEN
ekte kjøring, 10 015 ord, qwen3.8:27b-mlx           prompt_eval_count=18279 av context 32768 → ingen num_ctx
  kald                                              117 s prefill uten en eneste pakke → 120 s-fristen slo til
  varm                                              ollama ~6 min · appen ~7 min på 100 % CPU (re-render per token)
```

De to siste linjene er grunnen til de to siste committene: fristen er 600 s, og `text` publiseres strupet (≤ 10 Hz), ikke per token.

Referatet: norsk, alle malens seksjoner, navnene fra editoren (null `SPEAKER_`). Modellen gjengir malens egen «Context»-instruks øverst — #36.

## Ikke gjort / kjent

- Stand-Up-kjøringen (to `.md` side om side) ble ikke kjørt i dag; koden er den samme sti.
- `NSLog` fra en `open`-startet bundle er ikke synlig i `log show`; `prompt_eval_count` ble lest av ledningen.
- Selfcheck legger en fake-jobb under den ekte `jobs/`-mappa og rydder bare ved suksess.
- #34 får kommentar om `context.txt` (feltet en deltakerliste vil trenge).

Closes #30

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01Vs67ouws2jsrGdcbj6Qouu
```

## Tillegg 2026-09-04 kveld (M1 Pro, 32 GB, ollama 0.33.3)

Punkt 1–4 under «Neste steg» er gjort: sluttreview (funn fikset i d6895aa),
PR opprettet mot main, kommentar på #34. Selfcheck var flaky på M1 Pro
(RST fra nc, a2ee689). Kald prefill her: 309 s til første pakke på 7 716
ord, under 600 s. Stand-Up-malen gjengir også sin egen instruks (#36).

Ekte kjøring gjennom appen på M1 Pro er gjort (System Events trengte
Accessibility-tilgang for terminalen først; da virker AXPress på knappene,
og popup-menyene velges med AXPress på menu item): 470 s, «Referat lagret»,
CPU-tallene står i CLAUDE.md. Nye issues fra runden: #38 (skymodell ble
standard), #39 (fremdrift), #40 (redesign).
