# Schous

Minimal native macOS frontend for
[mac-local-transcribe-with-diarization](https://github.com/Oschlo/mac-local-transcribe-with-diarization).

Drop in a file — or record system audio straight from the menu bar — pick where
the result goes, watch the progress, and name the speakers afterwards. SwiftUI,
no third-party dependencies, no Xcode.

The name comes from Schous plass in Oslo. Since that gives away nothing about
what the app does, `bundle.sh` puts Spotlight keywords on the bundle — searching
for "transkribering" or "transcribe" finds it.

> **The interface is in Norwegian.** Every string in the app is hard-coded
> Norwegian; there is no localization. That is a deliberate choice for now — the
> tool exists for Norwegian and Swedish recordings — but it is worth knowing
> before you download 4 GB.

## Requirements

- **Apple Silicon** Mac
- **macOS 14.2 or later** — menu-bar recording uses a Core Audio process tap,
  which does not exist before that
- **`ffmpeg`** (`brew install ffmpeg`)
- **`uv`** (`brew install uv`) — for the backend's Python environment
- **A Hugging Face account** and a read token
- **~4.2 GB of disk**, downloaded the first time you transcribe anything:

  | What | Size |
  |---|---|
  | `mlx-community/whisper-large-v3-mlx` | **2.9 GB** |
  | `pyannote/speaker-diarization-community-1` | 31 MB |
  | the backend's `.venv` (torch is nearly all of it) | **1.3 GB** |
  | total | **~4.2 GB** |

  The weights do **not** arrive during install — they come down during the
  first run, in the middle of steps 2 and 4. The first job therefore looks like
  it has hung when it is in fact downloading 2.9 GB.

### How long a job takes

Measured on an **Apple M5, macOS 26.6.1**, weights already downloaded, a 10m54s
two-speaker Norwegian recording:

```
lyd 0s · diarization 4m37s · språk 5s · transkribering 1m17s
```

**6m02s for 10m54s of audio** — about 0.55× the length of the recording, and
**76 % of it is diarization**. Don't extrapolate from transcription speed:
diarization runs on CPU on purpose, so the ratio is not the one you'd guess.

Running the same file again is much faster. Steps 1–3 are cached, so only
transcription runs — 1m17s of the 6m02s above.

## Install

Download `Schous.zip` from
[Releases](https://github.com/Oschlo/schous/releases), unzip, and put
`Schous.app` in `/Applications`.

The app is signed with a local certificate, not notarized with Apple. Download
it in a browser and it gets quarantined and Gatekeeper refuses to open it —
**right-click → Open** lets it through with the signature checked.

`xattr -d com.apple.quarantine Schous.app` works too, but it turns the
signature check off entirely, not just the notarization requirement. If you use
it, check first that you have the app you think you have:

```zsh
codesign --verify --strict -R \
  '=identifier "co.oschlo.schous" and certificate leaf = H"b300de7a202552c6323463dc139682eee3f704cb"' \
  Schous.app && echo ok
```

No output other than `ok` means the bundle is intact and signed with the same
certificate as last time — which is also what the microphone, audio-capture and
`HF_TOKEN` permissions hang on, so an app that fails this would have asked for
all of them again anyway.

(That hash is ours. Build it yourself and you get a different one — see
[CLAUDE.md](CLAUDE.md) under "Signering".)

The menu bar has **Se etter oppdateringer…**, and the app also checks quietly
once a day at startup. If it finds a newer release, the menu offers to open the
release page. It does not install anything itself; you replace the app in
/Applications.

## Setup

The app does not transcribe anything itself — it drives
[mac-local-transcribe-with-diarization](https://github.com/Oschlo/mac-local-transcribe-with-diarization)
as a subprocess. That has to be installed and working from a terminal first:

```zsh
git clone https://github.com/Oschlo/mac-local-transcribe-with-diarization.git
cd mac-local-transcribe-with-diarization
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -r requirements.txt
```

**Accept the licenses for `pyannote/speaker-diarization-community-1` and
`pyannote/segmentation-3.0` on Hugging Face before the first run, with the same
account the token belongs to.** Skip it and the token is still valid, so the
job starts normally and then fails in step 2 with a download error that never
mentions licenses. It is the most likely first failure anyone hits.

Then, in the app — open Settings (⌘,) and fill in:

- **Backend** — the folder holding `transcribe.py` and `.venv/`.
- **HF_TOKEN** — Hugging Face token for pyannote diarization. Stored in Keychain.

Two buttons check the two halves:

- **Test backend** runs `transcribe.py --selfcheck`: `ffmpeg` on `PATH`, and
  that `torch`, `pyannote.audio` and `mlx_whisper` actually import. Local, no
  network, a few seconds.
- **Test modelltilgang** asks Hugging Face whether the token is alive and
  whether the model licenses are accepted by the account it belongs to. This is
  the only check that uses the network.

## Use

1. Drop an audio or video file into the window, or pick one.
2. Choose the output folder. Give the speaker count if you know it (blank = automatic).
3. **Start transkribering.** Progress shows steps 1–4, with a segment counter in
   step 4 and per-substep progress in step 2.
4. **Pause** freezes the process (SIGSTOP) and keeps the models in memory.
   **Stopp** ends it — the segments transcribed so far are written out, and
   starting again continues where it left off.
5. When it finishes: name the speakers, merge IDs that are the same person, and
   **Lagre**.

Writes `<name>.txt`, `<name>.srt` and `<name>.json` to the folder you chose.

## Recording from the menu bar

The microphone icon in the menu bar records **system audio and the microphone at
the same time** — everything you hear from video, web meetings and phone calls,
plus your own voice.

1. **Start opptak.** The icon becomes a recording ring and the menu shows a timer.
2. **Stopp opptak.** The two sources are mixed to one mono file,
   `Opptak-2026-08-10-1432.m4a`, in the same folder chosen under "Lagre i".
3. The window comes forward with the recording preselected. From there it is
   ordinary transcription — you decide whether and when.

The menu shows which microphone the recording will hit — "Mikrofon: `<name>`" —
so you see it before you start rather than afterwards. If access is denied, the
row says so, with the way to fix it.

The first time, macOS asks for microphone access. Say no and system audio is
recorded on its own, which is still a usable recording of a meeting you are only
listening to. **Screen Recording permission is not needed** — system audio comes
from a Core Audio tap, not from ScreenCaptureKit.

You can change audio output device mid-recording; the tap takes audio from the
processes, not from the device, so the recording carries on undisturbed.

A file can also be preselected at launch, which is handy for testing:

```zsh
open Schous.app --args --input ~/Movies/recording.mp4
```

`open` only passes arguments to a *fresh* launch — if the app is already
running, it is merely activated and `--input` is ignored.

## How it fits together

The app runs the backend as a subprocess with the working directory set to a job
folder under `~/Library/Application Support/Schous/jobs/<hash of input path>/`.
The backend writes `work/` (intermediates) and `output/` (ground truth, with
`SPEAKER_00` labels) there.

That ground truth is never touched by naming — renames and merges are read from
`speakers.json` in the job folder and applied only when files are written to
your output folder. You can rename as many times as you like without losing the
original labels.

The job folder is keyed on the input path, so the `work/` cache survives you
changing output folder. An interrupted run resumes: steps 1–3 are cached, and
step 4 keeps every finished segment in `work/<name>.partial.jsonl` as it goes.

Progress is read from the backend's `--progress json` stream — one JSON object
per line — rather than scraped out of human-readable output.

## Limitations

- No model or language choice — the backend does not expose them as flags.
- One file at a time.
- Diarization sometimes splits one person into several `SPEAKER_xx` IDs. That is
  why the speaker editor has "merge" and not just renaming.

## Build

```zsh
./bundle.sh          # → Schous.app
open Schous.app
```

Only Command Line Tools are required (`xcode-select --install`). `swift build`
alone is fine during development; `bundle.sh` produces the .app bundle needed
for the Dock icon and window focus.

`./release.sh 0.2.0` tags, builds and uploads a release. It has to run on the
machine holding the "Schous Dev" signing identity — see [CLAUDE.md](CLAUDE.md).
Without that certificate `bundle.sh` falls back to an ad-hoc signature and warns;
the app runs perfectly well that way, the only cost being that TCC permissions
reset on every rebuild, which CLAUDE.md explains in detail.

## Self-check

```zsh
.build/debug/Schous --selfcheck
```

Runs the parsers against real backend output lines and checks timestamp and SRT
formatting. Given a path to a finished run, it compares output byte for byte
against the backend's own files:

```zsh
.build/debug/Schous --selfcheck \
  ~/Library/Application\ Support/Schous/jobs/<hash>/output/<name>
```

## License

MIT — see [LICENSE](LICENSE).

The app bundles no third-party code: `Package.swift` has no dependencies, and
everything comes from SwiftUI, AppKit and Core Audio in the Command Line Tools
SDK. It does not bundle `ffmpeg` or the backend either — both are called as
subprocesses against what you installed yourself.
