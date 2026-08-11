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
Dev"` virker likevel. Angre: `security delete-identity -c "Schous Dev"`.

**Byttet fra ad-hoc til sertifikat er selv et identitetsbytte**, så det koster én
siste runde med spørsmål. Deretter er det stille.

**No Xcode project, on purpose.** This machine has only Command Line Tools, and
SwiftUI/AppKit/UniformTypeIdentifiers all ship in the CLT SDK. `bundle.sh`
assembles the `.app` by hand (binary + Info.plist + ad-hoc codesign). Don't
"upgrade" this to an `.xcodeproj` without a reason — it would add a 5 GB
dependency for nothing.

## The backend contract

The backend takes **exactly two arguments** (`transcribe.py:134-137`): a
positional source path and `--speakers N`. There is no `--output`, `--model`,
`--language`. Everything else is controlled indirectly:

- **Output location is the working directory.** `WORK_DIR`/`OUTPUT_DIR` are the
  relative literals `"work"`/`"output"`, so `Process.currentDirectoryURL` *is*
  the output-path API. See `TranscriptionJob.jobDirectory(for:)`.
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

## Progress parsing is text-scraping, and it is fragile

There is no machine-readable protocol
([backend #4](https://github.com/Oschlo/mac-local-transcribe-with-diarization/issues/4)).
Two streams, parsed in `TranscriptionJob.parseStdout` / `parseStderr`:

- **stdout:** `1/4 lyd…` … `4/4 transkriberer…`, `  N segmenter, M talere`,
  `  taler i/n SPEAKER_xx: no`.
- **stdout also:** pyannote's `ProgressHook()` is `rich`-based, and `rich` writes
  to **stdout**, not stderr. Don't try to parse it — step 2 shows the raw line.
- **stderr:** the tqdm bar from `transcribe_segments`.

Two traps that already bit:

1. **huggingface_hub prints its own tqdm bar to stderr**
   (`Fetching 4 files: 100%|██| 4/4 [00:00<00:00, …]`). It matches any naive
   `N/M [` regex and shows up as bogus 100% transcription progress. The parser
   requires the literal `transkriberer:` desc — keep that guard.
2. **tqdm uses `mininterval=10` when stderr is not a TTY** (`transcribe.py:96`),
   so progress updates every 10 seconds under a `Pipe`. Not a bug in this app.
   Don't add pty handling to work around it; fix backend #4 instead.

Both pipes are split on `\n` **and** `\r` — tqdm repaints with `\r`.

## Signals

- **Pause is `SIGSTOP`, resume is `SIGCONT`.** Cheap and instant, but it holds
  the loaded models in RAM and does not survive quitting the app.
- **`SIGCONT` before `SIGTERM`.** A stopped process never handles the terminate
  signal — `stop()` resumes first, otherwise the job hangs forever in `T` state.
- **Stopping during step 4 destroys all transcribed work.** The backend has no
  signal handling and writes nothing until the very end
  ([#3](https://github.com/Oschlo/mac-local-transcribe-with-diarization/issues/3),
  [#5](https://github.com/Oschlo/mac-local-transcribe-with-diarization/issues/5)).
  Steps 1–3 are disk-cached and resume free. The confirmation dialog exists
  because of this; remove it only when those issues are fixed.

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
