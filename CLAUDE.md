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
./bundle.sh              # → MacTranscribe.app
.build/debug/MacTranscribe --selfcheck
```

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
  `~/Library/Application Support/MacTranscribe/jobs/<hash>/`. Two reasons: the
  `work/` cache survives the user changing output folder, and the pristine
  `SPEAKER_00`-labelled output stays as ground truth so renaming is always
  reversible. **Never write renamed output back into the job dir.**
- **`-u` is mandatory.** Without it Python block-buffers stdout under a pipe and
  every step marker arrives at once, at the end. `PYTHONUNBUFFERED=1` is set too.
- **`PATH` must be set explicitly.** `transcribe.py:31` calls `ffmpeg` with no
  path resolution, and an `.app` launched from Finder does not inherit
  `/opt/homebrew/bin`.
- **`HF_TOKEN` comes from Keychain**, service `co.oschlo.mactranscribe`, account
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
.build/debug/MacTranscribe --selfcheck \
  ~/Library/Application\ Support/MacTranscribe/jobs/<hash>/output/<base>
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

- `open MacTranscribe.app --args …` only passes arguments on a **fresh** launch.
  If the app is already running, `open` just activates it and `--input` is
  silently ignored. `pkill -x MacTranscribe` first.
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
- Don't commit media or transcripts. Only `.build/` and `MacTranscribe.app/` are
  ignored; a stray `.wav` would go straight in.
