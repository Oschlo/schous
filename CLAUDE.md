# CLAUDE.md

SwiftUI frontend that drives
[mac-local-transcribe-with-diarization](https://github.com/Oschlo/mac-local-transcribe-with-diarization)
as a subprocess. Read the README for usage; this file is the non-obvious stuff.

The backend has its own CLAUDE.md worth reading — the constraints there
(pyannote 4.x, CPU-only diarization, per-speaker language locking) are why this
app looks the way it does.

## Build

```zsh
swift build              # development
./bundle.sh              # → Schous.app
.build/debug/Schous --selfcheck
```

### Signering — «Schous Dev», ikke ad-hoc

`bundle.sh` signerer med en lokal selvsignert identitet ved navn **Schous Dev**,
og faller tilbake til ad-hoc med en advarsel hvis den mangler.

Grunnen er at ad-hoc-signatur gir

```
designated => cdhash H"8c421e16…"          # ny for hver eneste build
```

og både TCC (mikrofon, `kTCCServiceAudioCapture`) og Keychain-ACL-en på
`HF_TOKEN` er nøklet på nøyaktig den strengen. Ad-hoc betyr derfor at **hver
rebuild nullstiller alle tillatelser**: nytt mikrofon-spørsmål, nytt
lydopptak-spørsmål, nytt Keychain-passord — midt i en test, og de må skrives inn
for hånd. Med sertifikatet blir kravet

```
designated => identifier "co.oschlo.schous" and certificate leaf = H"b300de7a…"
```

som er identisk før og etter at binæren endrer seg. Godkjent én gang, og det står.

Oppsettet er engangs, og sertifikatet trenger **ikke** å være trust'et — codesign
tar det som det er:

```zsh
cd "$(mktemp -d)"
cat > ext.cnf <<'EOF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = Schous Dev
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem \
  -days 3650 -config ext.cnf -extensions v3
# -macalg/-certpbe/-keypbe er ikke valgfrie: OpenSSL 3 lager som standard en
# PKCS#12 macOS' `security` ikke får verifisert («MAC verification failed»).
openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:schous \
  -name "Schous Dev" -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES
# -T /usr/bin/codesign forhåndsgodkjenner codesign i nøkkelens ACL, ellers spør
# Keychain om passord ved hver signering — altså akkurat det vi ble kvitt.
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P schous \
  -T /usr/bin/codesign
rm -f key.pem id.p12                       # privatnøkkelen ligger i Keychain nå
```

`security find-identity -v -p codesigning` viser fortsatt `0 valid identities` —
det er forventet og betyr bare at rota ikke er trust'et. `codesign --sign "Schous
Dev"` virker likevel, og **uten `-v` listes identiteten**, som er derfor
`bundle.sh` sjekker akkurat den formen. Angre: `security delete-identity -c
"Schous Dev"`.

**Prisen for at det er stille: alt som kjører som deg kan signere som Schous.**
Nøkkelen ligger i login-nøkkelringen, som er ulåst hele økta, og
`-T /usr/bin/codesign` gjør at codesign får den uten å spørre. Da kan hvilken som
helst lokal prosess signere en vilkårlig binær med `-i co.oschlo.schous` og få
nøyaktig samme designated requirement — og dermed appens mikrofon-, lydopptak- og
`HF_TOKEN`-tilganger. Ad-hoc hadde ikke det hullet, fordi cdhash-en flyttet seg
ved hver build. Byttet er altså en bevisst avveining: én manuell godkjenning spart
per build, mot en TCC-grant som ikke lenger er bundet til én binær. Greit på en
utviklermaskin, ikke greit å ta med i noe som distribueres. Vil du ha begge deler,
er veien en egen låst nøkkelring som `bundle.sh` låser opp og igjen rundt
signeringen — det koster ett passordspørsmål per build.

**Byttet fra ad-hoc til sertifikat er selv et identitetsbytte**, så det koster én
siste runde med spørsmål. Deretter er det stille.

**No Xcode project, on purpose.** This machine has only Command Line Tools, and
SwiftUI/AppKit/UniformTypeIdentifiers all ship in the CLT SDK. `bundle.sh`
assembles the `.app` by hand (binary + Info.plist + codesign). Don't
"upgrade" this to an `.xcodeproj` without a reason — it would add a 5 GB
dependency for nothing.

## The backend contract

The backend takes a positional source path, `--speakers N`, `--work-dir`,
`--output-dir` and `--progress {text,json}`. There is still no `--model` or
`--language`. Everything else is controlled indirectly:

- **Output location is the working directory** — still, because that is what
  this app does. `--work-dir`/`--output-dir` exist as of 2026-08-14 and default
  to the relative literals `"work"`/`"output"`, so `Process.currentDirectoryURL`
  keeps working unchanged. See `TranscriptionJob.jobDirectory(for:)`. Switching
  to the flags would be a wash; the job dir has to exist either way.
- **Steps 1–3 are cached in `work/`, and step 4 checkpoints.** Each finished
  segment is appended to `work/<base>.partial.jsonl`, so a killed or stopped run
  resumes rather than restarting. The file's presence means the last run did not
  finish; it is deleted on success.
- **Job dir is keyed on SHA-256 of the input path**, under
  `~/Library/Application Support/Schous/jobs/<hash>/`. Two reasons: the
  `work/` cache survives the user changing output folder, and the pristine
  `SPEAKER_00`-labelled output stays as ground truth so renaming is always
  reversible. **Never write renamed output back into the job dir.**
- **`-u` is mandatory.** Without it Python block-buffers stdout under a pipe and
  every step marker arrives at once, at the end. `PYTHONUNBUFFERED=1` is set too.
- **`PATH` must be set explicitly.** `transcribe.py:31` calls `ffmpeg` with no
  path resolution, and an `.app` launched from Finder does not inherit
  `/opt/homebrew/bin`.
- **`HF_TOKEN` comes from Keychain**, service `co.oschlo.schous`, account
  `HF_TOKEN`. The app cannot read `~/.zshenv` — no shell environment from Finder.
  Note the backend only checks the token when `work/<base>.diar.json` is absent,
  so a cached job runs fine with a dead token. Test token changes on a fresh
  job dir or you are testing nothing.

## Progress is a JSON protocol now, not text-scraping

The app runs the backend with `--progress json`, and `TranscriptionJob.apply`
switches on `event`. One object per line on stdout, nothing else there. Seven
events, all observed from real runs: `step`, `progress` (steps 2 and 4),
`diarized`, `language`, `resume`, `done`, `interrupted`.

`Event` is a `Decodable` with all-optional fields, so **unknown keys and unknown
events are ignored rather than fatal** — that is what lets the backend add
fields without breaking an already-released app. `--selfcheck` asserts it.

Three things that are true of this protocol and cost time to find:

1. **`completed` can exceed `total`.** pyannote's segmentation hook counts in
   `batch_size` steps and overshoots the last chunk — measured `completed: 64`
   of `total: 36`. `fraction` clamps to 1; don't remove that.
2. **pyannote counts with numpy scalars, not Python ints**, and `json.dumps`
   raises `TypeError` on `int64`. That killed a whole diarization run once. The
   backend coerces at the hook and has `default=str` as a net under it — a
   progress line must never be able to kill a job that has run for minutes.
3. **stderr is not progress.** `huggingface_hub` still prints
   `Fetching 4 files: 100%|██| 4/4 […]` there, and `sys.exit(message)` in the
   backend also goes to stderr — that is where the `HF_TOKEN ikke satt` check
   lives, not stdout. Anything non-JSON on stdout is logged, not parsed.

Both pipes are still split on `\n` **and** `\r`.

The old parser scraped `1/4 lyd…`, `  N segmenter, M talere` and a tqdm bar
whose `mininterval` was 10 s under a pipe. If you are reading a bug report older
than 2026-08-14, that is what it is describing.

## Signals

- **Pause is `SIGSTOP`, resume is `SIGCONT`.** Cheap and instant, but it holds
  the loaded models in RAM and does not survive quitting the app.
- **`SIGCONT` before `SIGTERM`.** A stopped process never handles the terminate
  signal — `stop()` resumes first, otherwise the job hangs forever in `T` state.
- **Stopping is cheap now, and there is no confirmation dialog.** The backend
  handles SIGTERM: it finishes the segment in flight, writes `.txt`/`.srt`/
  `.json` from everything done so far, keeps `work/<base>.partial.jsonl`, and
  exits **143** (130 for SIGINT). `finish()` treats those two codes as a normal
  exit and loads the partial output — that is the `.stopped(n)` state, which is
  deliberately not `.failed`. Don't re-add the "N of M segments will be lost"
  dialog; it stopped being true on 2026-08-14.
- **The signal lands at the end of the current segment, not immediately.**
  Python defers the handler until it is back from `mlx_whisper.transcribe`. A
  long segment is seconds. Don't add a timeout that assumes instant death.

## Menu bar recording (`Recorder.swift`)

System audio comes from a **Core Audio process tap** (macOS 14.2+), not
ScreenCaptureKit. That is why the app asks for no Screen Recording permission.
`CATapDescription(stereoGlobalTapButExcludeProcesses: [])` → a **private**
aggregate device whose only sub-device is the default output (it is there as a
clock) → an IOProc. Private tap and aggregate both die with the process, so a
crash leaves nothing behind in Audio MIDI Setup.

**The tap needs `NSAudioCaptureUsageDescription` in `Info.plist`.** It is its own
TCC service (`kTCCServiceAudioCapture`) — not the microphone one the app already
asks for. Without the key the tap fails *silently and only inside the app
bundle*: `AudioHardwareCreateProcessTap`, the aggregate, the IOProc and
`AudioDeviceStart` all return `noErr`, callbacks arrive in step with playback,
and every sample is zero. Measured on macOS 26.6.1, same tap code, only the
`Info.plist` differing ([#2](https://github.com/Oschlo/schous/issues/2)):

```
uten nøkkelen    calls=862 bufs=[1] channels=[2] peak=0.0
med nøkkelen     calls=849 bufs=[1] channels=[2] peak=0.198
```

The key only buys the *prompt*. Say no to it and the tap is exactly as silent,
still with no error code anywhere — so `Sink.heardSound` watches for a system
track that is all zeros and `stop()` points the user at Privacy & Security. That
flag is the only signal this failure has; don't drop it for looking redundant.

That is why the early probes looked fine: run from Terminal, the tap inherits
**Terminal's** audio-capture grant, and a loose `swiftc` binary gives signal even
with no key anywhere. Any measurement of the tap has to be `open`ed as a bundle,
never run from the shell, or it tests Terminal's permissions instead of the
app's.

Changing the default output device mid-recording is harmless — measured at
338/376/375 callbacks with identical peak before the switch, after it, and after
switching back. The tap captures process output, not a device; the output device
is only the clock. Don't add device-change handling for a problem that isn't.

**The two tracks are offset, and 21 ms is not worth fixing.** Because the mic
starts first (item 2 below), the system track is missing the setup interval at its
head, and `amix` aligns both files at zero — so system audio plays that much
*earlier* than the mic. Reviewers keep raising it; measure before agreeing.
Measured on macOS 26.6.1, six rounds of the exact `begin()` sequence:

```
Δ  min 19.6  median 21.0  maks 22.7 ms
   opprett aggregat 10.8 · lag IOProc 6.5 · opprett tapp 2.8 · åpne fil 0.8
   AudioDeviceStart og oppslag av utgangsenhet: under 0.05
```

That is an upper bound — `record()` returning is not the same instant the first
sample lands, and any AudioQueue startup latency eats into it. 21 ms is under the
precedence-effect threshold, it is less skew than two people sitting a chair apart
in the same room, and the tracks are mixed to mono before whisper resamples to
16 kHz anyway. Don't plumb `-itsoffset` through `merge` for it. The harness is
~150 lines and trivial to rewrite if the ordering ever changes; what matters is
that you re-measure rather than reason about it.

**A Bluetooth headset used as both mic and output halves the system track.**
Bluetooth Classic cannot carry good output and a microphone at once: the link runs
either A2DP (one-way, full quality, no mic) or HFP (two-way, so the mic exists,
but both directions drop to a speech profile). macOS switches the moment *any*
process opens the device's input — `AVAudioRecorder.record()` is enough, and Zoom
and FaceTime do the same thing. Measured here with AirPods Pro as both:

```
før mikrofonen åpnes:   utgang 48000 Hz    støtter [24000, 48000]
mikrofon på, +50 ms:    utgang 24000 Hz
mikrofon av, +3000 ms:  utgang 48000 Hz
```

Down within 50 ms, back only after ~3 s — macOS holds the HFP link in case another
app grabs the mic. The trap is that **the aggregate's clock is the output device**,
so the earbuds dropping to 24 kHz drags the *system* track down with it, even
though system audio never touches the radio: CoreAudio has already resampled the
whole mix to the device rate before the tap sees it. So the far end of a meeting is
captured at half bandwidth as a side effect of which mic you picked. Recordings
that come out at 24 kHz are this, not a bug in `Sink` or in `merge` — check the
output device before investigating anything else. Any other mic keeps the system
track at 48 kHz.

Five things that already cost time:

1. **The microphone cannot be a sub-device of that aggregate.** It was the first
   design — Core Audio would have delivered both sources sample-synced in one
   callback. Measured instead: output-only gives 129 callbacks in 2 s with
   signal; adding the input device gives 0–3 callbacks and pure zeros, with
   `create` and `start` both returning `noErr`. Silent failure. Independent of
   `mainSubDevice`, of drift compensation, and of whether the process is a signed
   bundle with granted microphone access. The mic is therefore recorded
   separately with `AVAudioRecorder` and merged with ffmpeg at stop. Don't
   "simplify" it back.
2. **The mic must be started *before* the tap, not after.**
   `AVAudioRecorder.record()` starts an AudioQueue that bottoms out in
   `AudioDeviceStart` on the HAL's *input* device. Called right after the
   aggregate has been started, it collides with the HAL's own
   `RebuildIOContext` for the change the aggregate just triggered, and the two
   deadlock on `HALB_Mutex`. The app hangs forever — no error code, no timeout,
   no callback. `sample(1)` on the hung process:

   ```
   main-thread   [AVAudioRecorder record] → AudioQueueStart → AudioDeviceStart
                 → HALC_ProxyIOContext::_StartIO → HALB_Mutex::Lock → __psynch_mutexwait
   ProxyNotif    ProxyObject_PropertiesChanged → HALC_ShellDevice::RebuildIOContext
                 → HALC_ProxyIOContext::PauseIO  → HALB_Mutex::Lock → __psynch_mutexwait
   ```

   Measured on macOS 26.6.1: hangs 2/2 with the mic last, 3/3 clean rounds with
   the mic first. It is a race, so a passing run proves nothing — only the
   ordering does. The consequence is that the mic's sample rate comes from the
   input device rather than the aggregate, which does not exist yet. Harmless:
   ffmpeg mixes the two tracks regardless, they never had to match.
3. **The IOProc block must be built in a `nonisolated` context.** Created inside
   a `@MainActor` method it inherits MainActor isolation, and Swift 6 kills the
   process with SIGTRAP (`_dispatch_assert_queue_fail` →
   `swift_task_checkIsolatedSwift`) the moment Core Audio calls it on the audio
   thread. `Recorder.makeIOProc` exists only for this.
4. **`amix` needs `normalize=0`.** Default amix divides each input by the number
   of inputs, so a meeting where only one party talks at a time comes out 6 dB
   low.
5. **`Window`, not `WindowGroup`.** `openWindow(id:)` against a WindowGroup opens
   a *new* window per recording instead of raising the existing one.

The menu bar icon is `Resources/MenuBarIcon.png` — the same 16x16 sprite as the
app icon, minus the background tile, emitted by `icon.py` alongside the `.icns`.
It is loaded as a **template** image so the menu bar tints it for light/dark.
`bundle.sh` must copy it; `swift build` alone has no bundle to load it from and
falls back to an SF Symbol. Edit the sprite in `icon.py` and both icons rebuild.

`mixDown` averages channels within a source and sums across sources, then clips.
It runs on the real-time thread, which is why it takes an `AudioBufferList`
rather than arrays. `--selfcheck` covers it.

## Output format is a byte-exact port

`writeOutputs` in `Segment.swift` reimplements the backend's `write_outputs`
(`transcribe.py:122-130`). It must stay byte-identical, or the app silently
produces different files than a terminal run. Two subtleties that already
caused a mismatch:

- Every SRT block ends with a **blank line, including the last one**.
- TXT timestamps are `ts(start, ".")[:-4]` — millisecond field chopped, so
  `HH:MM:SS`, while SRT keeps `HH:MM:SS,mmm`.

`--selfcheck` guards this. Given a path to a finished run it diffs the port
against the backend's own files:

```zsh
.build/debug/Schous --selfcheck \
  ~/Library/Application\ Support/Schous/jobs/<hash>/output/<base>
```

It also runs every parser against verbatim backend output lines. Run it after
touching `Segment.swift` or either parser.

## Speaker naming

Names and merges live only in `speakers.json` in the job dir and are applied
when writing to the user's folder. **Merge exists because diarization
over-splits one person into several IDs** — that's a documented backend
limitation, not a UI nicety. `root()` follows merge chains with a hop limit;
`mergeBinding` refuses a merge that would point back into its own chain.

## Testing gotchas

- **Første kjøring etter et identitetsbytte krever et menneske.** Er appen
  ad-hoc-signert (se «Signering»), gjelder det etter *hver* build: mikrofon,
  lydopptak og Keychain spør på nytt, og dialogene må klikkes og passordet
  skrives for hånd. En `open … && sleep 20 && sjekk resultatet` måler da bare en
  app som står og venter på en dialog. Bygg med «Schous Dev»-identiteten, og hvis
  et spørsmål likevel er ventet: si fra til brukeren og vent på svar før du
  måler, ikke gjett på en delay.
- **Stabil DR er ikke det samme som stille installasjon.** Et Keychain-element
  hvis ACL ble laget under en *tidligere* identitet — typisk fra ad-hoc-tida —
  spør på nytt selv om dagens designated requirement er uendret. Målt: fc6b1b4
  installert over forrige app med byte-identisk signatur kostet likevel ett
  `HF_TOKEN`-spørsmål ved første oppstart. Det er engangs, men det må klikkes
  **«Alltid tillat»**, ikke «Tillat»: den første skriver appen inn i ACL-en,
  den andre gjelder bare den ene gangen.
- **`prosess-status: S` beviser ingenting.** En app som står og venter på en
  TCC- eller Keychain-dialog ser ut som en app som kjører helt fint. Dialogen
  eies av `SecurityAgent`, så det er den som må sjekkes — og med
  `pgrep -x SecurityAgent`, ikke `-f`: mønsteret står i din egen kommandolinje,
  så `-f` matcher skallet som leter og gir alltid treff.
- `open Schous.app --args …` only passes arguments on a **fresh** launch.
  If the app is already running, `open` just activates it and `--input` is
  silently ignored. `pkill -x Schous` first.
- `defaults write` can race with `cfprefsd`. `killall cfprefsd` after writing if
  the app reads a stale value.
- Driving the UI via System Events works, but setting a SwiftUI `TextField`'s
  AXValue directly does **not** fire the binding — click the field and
  `keystroke` instead, with delays.
- Synthetic `say`-generated voices are useless for testing diarization; pyannote
  merges them into one speaker. Use a real recording to exercise merge/rename.

## Never do

- Don't print secrets. Presence checks use `[ -n "$TOKEN" ]` and `${#TOKEN}` —
  `${TOKEN:-fallback}` expands to the **value** when set and leaks it.
- Don't commit media or transcripts. `.gitignore` covers `*.wav`, `*.mp4`,
  `*.m4a`, `*.aiff` and `*.srt` — but that list is not the same as "safe". A
  recording saved as `.caf` or `.mov` would go straight in, so check
  `git status` after any test that records or transcribes.
- Don't commit generated icons. `Resources/AppIcon.icns` and
  `Resources/MenuBarIcon.png` are both built by `icon.py` and both gitignored.
  The sprite in `icon.py` is the source of truth.
