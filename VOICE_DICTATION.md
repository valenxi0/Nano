# Quill (Voice Dictation)

Local, push-to-talk dictation for Nano, shown to users as **Quill**. Hold the
hotkey, speak, release; the final text is pasted into the field you started in
and kept on the clipboard. Nothing leaves the Mac, no audio is kept.

Code, settings keys and file names still say `VoiceDictation`; only
user-facing strings say Quill, so existing preferences carry over.

## Where things live

| Piece | Path |
| --- | --- |
| Feature code | `Nano/Core/VoiceDictation/` |
| Settings pane | `Nano/Views/VoiceDictationSettingsPane.swift` |
| Island views | `Nano/Views/VoiceDictationIslandViews.swift` |
| Runtime wrappers (whisper.cpp, llama.cpp) | `Nano/Packages/NanoSpeechRuntimes/` |
| Parakeet runtime (FluidAudio, vendored) | `Nano/Packages/FluidAudio/` |
| Tests | `NanoTests/VoiceDictation*.swift` |
| Downloaded models | `~/Library/Application Support/Nano/VoiceDictation/Models/` |
| Transcript history (opt-in) | `~/Library/Application Support/Nano/VoiceDictation/history.json` |

## Engines

| Engine | Recognition | Cleanup | Runtime | Accelerator |
| --- | --- | --- | --- | --- |
| Parakeet + S1-mini (default) | Parakeet TDT 0.6B v3, optional CTC 110M vocabulary booster | S1-mini by Superwhisper (Q4_K_M), English only | FluidAudio (Core ML) + llama.cpp | Neural Engine + Metal |
| Cohere Transcribe | Cohere Transcribe 03-2026, INT8 encoder (14 languages, language chosen up front) | none | FluidAudio (Core ML) | Neural Engine |
| Whisper Turbo | whisper large-v3-turbo Q5_0 (99 languages, auto-detect) | none | whisper.cpp | Metal |
| Whisper Base | whisper base.en (ggml) | none | whisper.cpp | Metal |
| Whisper Tiny | whisper tiny.en (ggml) | none | whisper.cpp | Metal |

Nothing downloads until the user picks an engine in Settings. Every file is
pinned by Hugging Face revision, byte size and SHA-256
(`VoiceDictationModelManifest+Files.swift`); a mismatch fails the download
rather than installing the file. Directories are swapped in atomically, so a
model is either complete or absent.

The raw transcript is always available (Settings and the island module show
it next to the final text). S1-mini only ever sees speech: snippet expansions
are cut out before cleanup and spliced back afterwards, and vocabulary
replacements run after cleanup so S1 cannot re-case them.

## Text pipeline (per segment)

`VoiceDictationController.processSegment` runs, in order:

1. Recognition with a `VoiceDictationRecognitionRequest`: the dictionary's
   terms (Whisper's prompt; Parakeet's CTC booster when downloaded) and the
   language (`VoiceDictationEngine.recognitionLanguage`). Cohere cannot detect
   a language, so "Automatic" follows the Mac's preferred languages.
2. Language gate (`VoiceDictationLanguageGuess`): S1-mini and number
   formatting run on English only. Parakeet reports no language, so a
   confident NaturalLanguage reading of the transcript decides.
3. Snippets and spoken layout cues ("new line", "new paragraph") are cut
   out, then each speech piece is cleaned by S1-mini, or, without a cleaner,
   gets Developer Mode formatting (terminals) and numbers as figures
   (`VoiceDictationNumberFormatter`: span by span through NeMo ITN; one to
   nine stay words in prose).
4. Emoji names ("thumbs up emoji"), when spoken line breaks are on and the
   app isn't a terminal. Then vocabulary, last.

On the whole joined text (`VoiceDictationController.finish`): a trailing
"press enter" is stripped when that setting is on, chat apps drop a
one-sentence message's full stop, and the text is fitted to the caret
(`VoiceDictationCursorFit`, from the 300 characters before it and 40 after,
read at the start): lowercase in the middle of a sentence, a missing space
added, an unneeded full stop dropped. Terminal pastes over 600 characters or
two line breaks go in pieces (`VoiceDictationSpokenCommands.pasteChunks`).

Silero VAD (`VoiceDictationVAD`, bundled in `Resources/Models`) classifies the
recording in 256 ms chunks while the user talks. On release, a recording with
no chunk at 0.3 or more ends as "Nothing to transcribe" without running the
recognizer; the last piece is cropped to its speech, padded 300 ms before and
450 ms after; silent early segments are skipped.

## From Quill for Windows (October 2026)

Ported from Quill for Windows 0.2.2 and 0.3.0: styles for specific apps,
vocabulary and snippets for one app (an app entry overrides an all-apps entry
with the same phrase; learned corrections keep their app), fitting to the
cursor, emoji by name, "press enter", chunked terminal pastes, live preview (a
caption under the island, decoding the newest 15 s), history that keeps what
was heard and can redo it in another style, paste the last transcript again
(island, `nano://quill/paste-last`), Esc twice within a second to cancel, the
Silero VAD above, and the chat full-stop rule only counting `.`/`!`/`?`
followed by a space.

## Release review changes (October 2026)

From an outside review of Quill before release:

- Agent prompts: a terminal tab whose window title names a coding agent
  (Claude Code's "✳", "codex", "claude" and others) or a project with a live
  agent session in that terminal app is the `.agent` context. It is cleaned in
  the user's style like prose, pastes in pieces like any terminal, and gets
  no command formatting. Plain shell prompts stay Verbatim.
- Engines offered: Parakeet + S1-mini ("English, best quality"), Whisper
  Turbo ("Many languages"), Whisper Base ("Small download"). Cohere and
  Whisper Tiny stay in code for tests and benchmarks only; a saved choice of
  either moves to Turbo or Base. First setup of Parakeet also downloads Base
  and uses it until Parakeet is ready (`downloadForFirstUse`).
- Styles: Verbatim, Casual, Polished, plus "Spoken lists become lists" for
  Polished. Compose became Polished with that switch on; Formal wording was
  removed. Older settings, app styles and history load through
  `VoiceDictationCleanupLevel.saved`.
- Settings tabs: Insights (opens first), Setup, Writing, Vocabulary, Sketch. A banner says
  when Quill can copy but not paste. Live preview is on by default. Terminal
  pastes always go in pieces.
- Vocabulary: a term is one field with an optional "Also heard as"; learned
  corrections are remembered everywhere unless asked otherwise; the booster
  downloads once, by itself, when the first term is added; JSON export and
  import match Quill for Windows. The island offers "Redo as" on the last
  transcript.
- Sketch output for agents: every screenshot full size plus a zoomed crop
  around each marked one, the app, window and clicked element on each line,
  the display size in the header, and a one-line explanation for the agent.
  Recordings are kept 24 hours.

## Sketch

Talk while marking up the screen, then paste the screenshots and the
transcript together. The idea and its interaction (hold ⇧ and move to draw,
clicks pass through, numbered marks, paste images then text) come from
[Scrawl](https://github.com/kitlangton/scrawl) by Kit Langton (MIT). Nano's
version is its own, smaller implementation: screenshots instead of a screen
recording, and Quill's engines for the words.

- ⌃⌥S (Settings → Quill → Sketch) starts and finishes. Needs Screen Recording;
  without it the shortcut opens that pane of System Settings.
- While recording, a soft red glow breathes along the edges of the display
  being recorded, and a bar at the bottom (clear of the island) shows the
  time, Draw, Undo, Cancel and Finish. Hold the draw key (Shift by default,
  or Option, Control, Command, fn) and move the pointer to draw, or turn on
  Draw and drag. Clicks otherwise pass through.
- `VoiceDictationSketchRecorder` records the whole display with
  ScreenCaptureKit, without Nano's windows, to an H.264 .mp4 at 15 fps (long
  edge at most 2560 px). It keeps a 32 × 20 brightness grid per frame: when
  4% of the grid has changed from the last settled screen and nothing has
  moved for 0.5 s, that screen is a change.
- Moments: the screen 0.6 s in, every click (the frame at the click, with a
  white ring where it landed), every group of marks (marks share a
  screenshot until a click, scroll, app switch or settled change), and every
  settled change. `VoiceDictationSketchPicker` drops a moment that looks like
  its neighbour (under 3% of the grid changed) unless both carry marks, then
  keeps marks, clicks, changes, start in that order within a budget of 6
  screenshots up to 40 s, one more per 20 s, at most 10.
- Ink is red only, drawn with Core Animation shape layers from pointer events
  (no polling, no full-screen redraws), and fades 1.4 s after each mark with
  its time. ⌘Z removes the last mark.
- On finish, the recording is cut at each screenshot's moment (and each mark
  when a screenshot has several), at the quietest pause from 1.5 s before to
  0.3 s after (`VoiceDictationSketchText.cuts`); each piece goes through the
  normal per-segment pipeline; the text is one line per screenshot:
  `- #2 (0:09) [clicked] “…”`, `[screen changed]` for changes, `[1] [2]` for
  several marks. Screenshots get their ink, click ring and a "#N 0:15" badge
  and go out as one contact sheet (two per row), saved with the full-size
  frames and `recording.mp4` in `~/Library/Caches/Nano/Sketches/` for 24 hours.
- Delivery goes back to the field the Sketch was started in: the sheet as PNG
  data in GUI apps, as a path in terminals (Claude Code turns it into an
  image), then the text. Without a field the text is copied.

## Learning, history, launchers

- `VoiceDictationCorrectionWatcher` rereads the pasted field at 12 s and 45 s,
  anchored on the text around the dictation; `VoiceDictationCorrectionDiff`
  learns three things: misheard-word substitutions, one to three words the
  user deletes (leave out), and a stretch deleted before a restatement with a
  cue such as "actually" in it (change of mind). Seen twice, it becomes a
  suggestion. By default Nano offers one on the island at most once a day
  (Remember, Not now, Ignore); with "Apply what Quill learns automatically"
  on, suggestions are added without asking. Settings → Quill → Your voice
  lists and removes them (`corrections.json`, word pairs only).
- History entries record the app, seconds spoken and release-to-paste time.
- `nano://quill/start|stop|toggle|cancel|sketch|paste-last` (Info.plist `CFBundleURLTypes`, handled
  in `NanoAppDelegate`) and Start/Stop/Toggle Dictation App Intents.

## Accuracy on real voices

`NanoTests/VoiceDictationAccuracyBenchmark.swift`: put `name.wav` + `name.txt`
pairs in `~/Library/Application Support/Nano/VoiceDictation/Eval/` and run

```sh
TEST_RUNNER_NANO_VD_ACCURACY=1 xcodebuild -project Nano.xcodeproj -scheme Nano \
  -destination 'platform=macOS' test -only-testing:NanoTests/VoiceDictationAccuracyBenchmark
```

Raw and final WER per installed engine land in `/tmp/nano-vd/accuracy/results.json`.

## Licenses and attribution

| Component | Version pinned | License | Obligations |
| --- | --- | --- | --- |
| whisper.cpp (`whisper.xcframework`) | v1.9.2 | MIT | Keep the notice. |
| llama.cpp (`llama.xcframework`) | b10775 | MIT | Keep the notice. |
| FluidAudio | 0.15.6 | Apache 2.0 | Keep `LICENSE` and `ThirdPartyLicenses/` (fastcluster, vbx, NemoTextProcessing). |
| NemoTextProcessing.xcframework (text-processing-rs) | v0.3.0 | Apache 2.0 | As above. |
| Parakeet TDT 0.6B v3 (NVIDIA; Core ML conversion by Fluid Inference) | HF rev `7dd20fe…` | CC BY 4.0 | Attribute NVIDIA. Commercial use is permitted by CC BY 4.0; the weights are downloaded by the user, not bundled. |
| S1-mini (Superwhisper; derivative of Qwen3-0.6B) | HF rev pinned in manifest | Apache 2.0 with an additional naming term | Must always be called “S1-mini” by “Superwhisper”, exact capitalization. `LICENSE` and `NOTICE` are downloaded with the weights and kept. UI strings comply. |
| Whisper base.en / tiny.en / large-v3-turbo Q5_0 (OpenAI; ggml conversion) | HF rev pinned in manifest | MIT | Keep the notice. |
| Cohere Transcribe 03-2026 (Cohere Labs; Core ML conversion by Fluid Inference) | HF rev `fccec19…` | Apache 2.0 | README kept with the weights. |
| Parakeet CTC 110M vocabulary booster (NVIDIA; Core ML conversion by Fluid Inference) | HF rev `accdafd…` | CC BY 4.0 | Attribute NVIDIA. Optional download. |
| Silero VAD unified 256 ms v6.2.1 (Silero Team; Core ML conversion by Fluid Inference) | HF rev `b419383…` | MIT | Keep the notice. Bundled in the app (1 MB). |
| Scrawl by Kit Langton (idea and interaction for Sketch; no code copied) | n/a | MIT | Credited in Settings → Quill → Sketch. |

All of the above permit commercial distribution. Nano ships the runtimes; the
model weights are fetched by the user on demand, with license text shown in
Settings before download.

## Benchmark (Mac mini, recorded 2026-09-02)

Harness: `NanoTests/VoiceDictationBenchmark.swift`, run with

```sh
TEST_RUNNER_NANO_VD_BENCHMARK=1 xcodebuild -project Nano.xcodeproj -scheme Nano \
  -destination 'platform=macOS' test -only-testing:NanoTests/VoiceDictationBenchmark
```

`TEST_RUNNER_NANO_VD_BENCHMARK_ENGINES=cohereTranscribe,whisperTurbo` limits
the engines and the downloads.

It drives `VoiceDictationController.processCapturedAudio`, the same path a
hotkey release takes, so the numbers include model inference, S1 cleanup,
vocabulary/snippets and the clipboard write. Raw output:
`/tmp/nano-vd/benchmark/results.json` (runs 2 and 3 kept alongside).

**Machine:** Mac mini `Mac16,10`, Apple M4 (4 performance + 6 efficiency
cores), 16 GB, macOS 26.6.2 (25G83). Inference threads: 4 (performance cores).
Thermal state nominal before and after; memory pressure level 1 (normal)
before and after; swap 668 MB used of 2 GB before and after (unchanged).

**Audio:** eight fixtures synthesized with the system voice (`say`, 16 kHz
mono) covering a short command (1 s), fillers and self-corrections (7.9 s),
numbers/dates/email (9.4 s), proper names and technical terms (7.8 s), a
vocabulary + snippet trigger (4.1 s), numbers under added Gaussian noise at
12 dB SNR (4.7 s), a 45 s natural dictation, and 2 s of silence. Synthetic
speech is deterministic across runs; it is not a substitute for a WER study
on real voices, and none is claimed.

### Warm stop-to-clipboard (21 runs per engine: 7 utterances × 3 passes)

| Engine | Typical (≤ 10 s clips, n=18) p50 / p95 / max | 45 s dictation (n=3) p50 / max | Target p50 ≤ 0.7 s, p95 ≤ 1.5 s |
| --- | --- | --- | --- |
| Parakeet + S1-mini | **0.245 s / 0.373 s / 0.374 s** | 1.486 s / 1.488 s | met (p95 over all 21 runs: 1.486 s) |
| Whisper Base | **0.121 s / 0.133 s / 0.133 s** | 0.501 s / 0.501 s | met |
| Whisper Tiny | **0.077 s / 0.083 s / 0.090 s** | 0.330 s / 0.331 s | met |

### Breakdown (means over warm runs)

| Engine | Transcription, typical | Cleanup, typical | Transcription, 45 s | Cleanup, 45 s | Post-processing |
| --- | --- | --- | --- | --- | --- |
| Parakeet + S1-mini | 0.089 s | 0.158 s | 0.296 s | 1.189 s | < 1 ms |
| Whisper Base | 0.102 s | – | 0.499 s | – | < 1 ms |
| Whisper Tiny | 0.062 s | – | 0.328 s | – | < 1 ms |

For Parakeet + S1-mini on the long clip, S1 generation is 80 % of the time:
llama.cpp decodes ~150 output tokens at about 130 tok/s on the M4 GPU.

### Cold path (model load, measured separately)

| Engine | Load, first ever on this Mac | Load, subsequent launches | First transcription after load |
| --- | --- | --- | --- |
| Parakeet + S1-mini | 26.4 s (Core ML compiles Parakeet for the Neural Engine once; the OS caches the result) | 0.33 s | 0.08 s + 0.05 s cleanup |
| Whisper Base | 6.6 s (Metal shader compile, once) | 0.10–0.13 s | 0.07 s |
| Whisper Tiny | 0.08 s | 0.08 s | 0.04 s |

The controller warms the selected engine when recording starts (overlapping
the load with speech) and, after a download finishes, loads it once so the
one-time compile happens while the user is still in Settings. Engines unload
after 10 minutes idle.

### Resources

| Engine | Footprint added by loading | Peak process footprint during runs | Peak CPU during a run | CPU 1–4 s after a run |
| --- | --- | --- | --- | --- |
| Parakeet + S1-mini | 627 MB | 704 MB | 5.9 cores (brief, S1 prefill) | 0.008 cores |
| Whisper Base | 283 MB | 419 MB | 0.95 cores | 0.009 cores |
| Whisper Tiny | 131 MB | 339 MB | 0.96 cores | 0.009 cores |

Process lifetime peak footprint across the whole benchmark: 713 MB. No
first-to-last pass degradation (−3.8 % to +0.3 %, noise).

### Main thread

A 16 ms ticker on the main actor ran throughout. Worst overshoot: 2.4 ms
during warm runs, 6.4 ms during Parakeet's cold load, 0 ms during the model
downloads (run 3; run 2's 43 ms came from the directory swap, which now runs
off the main actor). Nothing a user can see.

### Failure and edge cases exercised

| Case | Result |
| --- | --- |
| 2 s of silence | All three engines: `noSpeech`, nothing copied. Whisper's reflex output for silence (“you”) is caught by `isLikelyHallucination` (known phrase + clip under −40 dBFS). In the live path `containsSpeech` rejects pure silence before any model runs. |
| Cancel 150 ms into the 45 s clip | Phase returns to idle immediately; nothing copied. In-flight inference cannot be interrupted mid-call and drains in the background: 1.32 s (Parakeet + S1), 0.34 s (Base), 0.17 s (Tiny). |
| Vocabulary + snippet | All engines: “Mac Island” → “Nano”, “insert sign off” → the two-line signature; both reported in `appliedReplacements`. S1 never saw the expansion. |
| Missing model | Covered by unit tests: fails with `modelMissing` naming the engine and files, no recording starts. |
| Downloads | 4 models, 1.19 GB, all SHA-256 verified; Parakeet 224 s, S1-mini 32 s, Base 4.9 s, Tiny 2.9 s on this connection. Cancellation and retry at file granularity are implemented; a download failure surfaces as a `failed` state with a Retry button. |

### Transcript quality notes (synthetic voice, not WER)

- S1-mini removed fillers and self-corrections as intended (“Um, so I think we
  should, uh, ship it on Tuesday. No, Thursday…” → “So I think we should ship
  it on Thursday, and let the team know before the stand-up.”), formatted
  “4:30pm”, misspelled the name in the spoken email address, and split
  the 45 s dictation into paragraphs.
- S1-mini dropped the hyphen in a phone number under noise (“555-0198” →
  “5550198”). Raw stays available; a vocabulary entry can pin a preferred form.
- Whisper Tiny dropped a clause on the noisy clip and mangled a proper name
  more than Base; Base kept fillers verbatim (no cleanup by design).
- The synthetic voice's pronunciation of “Alex Rivera” is not recognizable by
  any engine; expect a real voice to do better, and vocabulary to fix the rest.

## Quill 1.1 measurements (Mac mini M4, 2026-09-24/25)

Same harness, one engine per process (`NANO_VD_BENCHMARK_ENGINES`).

| Engine | Typical p50 / p95 | 45 s dictation p50 | Notes |
| --- | --- | --- | --- |
| Parakeet + S1-mini, booster on | 0.40 s / 0.52 s | 2.39 s | The booster loads and warms with the engine and its CTC pass runs alongside recognition (was 0.54 s, and ~15 s on the first dictation after a load, when it loaded lazily). |
| Whisper Turbo | 2.14 s / 2.27 s | 3.65 s | whisper.cpp always encodes a 30 s window. Shrinking `audio_ctx` made turbo output garbage ("and to the"); do not. |
| Cohere Transcribe (`.all`) | ~5–20 s per clip | ~27–45 s | `.cpuAndNeuralEngine` is ~2 s but exits the process on some inputs. Labelled experimental. |

Booster: FluidAudio's default rescorer (acoustic "rescue" on) replaced "Open
the" with "Nano" and "Um, so" with "Kubernetes". `spotterRescueEnabled:
false` plus a short-term taper fixed every case in the benchmark.

Multilingual (synthetic `say` voices, German, Spanish, English): Parakeet
and Whisper Turbo both 0 % WER; Whisper Turbo reported `de`/`es`/`en`
correctly; S1-mini was skipped for German and Spanish. Cohere on
"Automatic" (English on this Mac) translated the German and Spanish clips
into English, hence the warning in its language note.

Cohere pieces are cut at 20 s: at 25 s the 108-token decoder cache ran out
mid-word.

## Not done / needs the user

- `/Applications/Nano.app` was not touched. The Debug build lives in
  `/tmp/nano-vd/DerivedData/Build/Products/Debug/Nano.app`.
- Models were downloaded to the real model directory as part of the
  benchmark; remove any of them from Settings → Voice Dictation if unwanted.
- The first ever Parakeet load on a Mac takes tens of seconds (Core ML
  compile). Settings shows “Loading engine…” for it and the island shows the
  processing state; the wait is one-time per Mac.
