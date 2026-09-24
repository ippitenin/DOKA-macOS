<p align="center">
  <img src="media/doka-icon.png" alt="DOKA" width="160">
</p>

<h1 align="center">DOKA for macOS</h1>

<p align="center">
  <b>D</b>ock <b>O</b>perations <b>K</b>it for <b>A</b>pple — menu-bar voice dictation
  and audio/video transcription for macOS.
</p>

<p align="center">
  <b>English</b> · <a href="README.ru.md">Русский</a>
</p>

<p align="center">
  <sub>This repository is the macOS app. The iOS version is developed separately in <code>DOKA-iOS</code>.</sub>
</p>

<p align="center">
  <a href="https://github.com/ippitenin/DOKA-macOS/actions/workflows/build.yml"><img alt="Build" src="https://github.com/ippitenin/DOKA-macOS/actions/workflows/build.yml/badge.svg"></a>
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2015%2B-lightgrey">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5.9%2B-orange">
  <img alt="License" src="https://img.shields.io/badge/license-GPL--3.0-blue">
</p>

Press a global hotkey, speak, and the recognised text lands in whatever app you were
using. Recognition runs either **entirely on your Mac** — Whisper or Parakeet through
the Neural Engine, no internet and no API key — or through any OpenAI-compatible
service. DOKA lives in the menu bar and keeps no icon in the Dock.

The interface is localised in English and Russian; the code and its comments are
written in Russian.

## Features

- **Voice dictation** — global hotkey (or push-to-talk, or a mouse button) → recording →
  transcription → dictionary replacements → text pasted into the active app through the
  clipboard and a synthetic ⌘V.
- **Recording panel** — six styles. `aurora` and `mini` are a glowing droplet built on Metal
  shaders in the spirit of Liquid Glass: the wave inside answers your voice in both amplitude
  and speed, the glass refracts light at the rim, and while transcribing the droplet springs
  into a ring of pulsing dots. `aurora` is the wide warm droplet with a halo and a soft glow
  along the bottom edge of the screen; `mini` is half as wide, painted in a cold palette (ice,
  turquoise, blue-violet) and wearing a live rim: the light of the wave bleeds onto the
  outline, runs along it in tides and splits into chromatic aberration. Plus `studio`,
  `classic`, `notch` (a strip that grows out of the camera cutout) and `hidden`.
- **Transcribe Audio** — drop in an audio or video file and get timestamped segments,
  subtitles (SRT/VTT) and optional speaker diarization. With the built-in service the job
  runs asynchronously: it survives network loss, sleep, and even an app restart — the
  result is collected without re-uploading the file or paying twice.
- **Speaker diarization, on-device** — with a local model (or your own OpenAI-compatible
  service, which has no diarization of its own) DOKA separates speakers on your Mac: a
  22 MB model downloaded once, no internet and no billing. Roughly 12× faster than
  real time on Apple silicon.
- **Transcription library** — every transcribed file is kept together with its audio:
  search by title and text, groups by date, renaming, batch export (one Markdown or .txt
  file, or separate TXT/SRT/VTT files per record). A record opens with a player: click a
  timestamp to jump there, the segment being played is highlighted and followed; space,
  ←/→ and playback speed. Running jobs show their progress; records are kept forever
  unless you choose a retention period.
- **Retry and re-transcribe** — a job that failed or was cancelled is resumed from the record
  itself: when the server has already finished (and charged for) the result, it is collected
  without uploading anything again; otherwise the file is sent once more, and a paid service
  asks for confirmation first. Any record can also be re-transcribed by another service — the
  new result appears next to the original, which stays untouched. A failed dictation gets its
  own menu-bar entry, so fixing the network still lands the text in the app you were in. If a
  transcription finishes while you are looking elsewhere, a notification opens the record.
- **Speakers and text editing** — rename speakers ("Speaker 1" → "Anna"), merge two
  speakers into one and split them back, reassign a line (or part of a long one) to
  another speaker, fix the text of a line with a double click. Edits survive any timestamp
  detail level, reach copying and every export format, and can be undone line by line or
  all at once; the original recognition result is never overwritten.
- **AI analysis on your own Mac** — meeting minutes, a short summary, action items, lecture
  notes, an interview breakdown, chapters, or your own prompt. The report is written by a
  language model running right on the machine (llama.cpp + Qwen3.5 4B): no internet, no key,
  no billing; the 2.7 GB model is downloaded once. A long recording is processed in parts
  and combined into a single report. Template sections can be rewritten, or you can build
  your own template. The result renders as formatted text with headings, lists and tables,
  its timestamps are clickable and seek the player; copying puts both plain and rich text
  on the clipboard, so tables paste as tables into Telegram, Notes or Word. Analysis can
  be ordered right when transcribing a file — with any template or your own prompt: by
  default it runs on this Mac after recognition, and with the built-in service you can pick
  “In the cloud” (the Nexara language model) instead, so the analysis rides in the same
  request as the transcription.
- **History** — a journal of dictations with metadata, playback, export (CSV or plain text)
  and a performance analysis screen.
- **Dashboard** — words dictated, time saved, and how much faster this is than your own
  typing (measured by a built-in typing test), plus a daily chart.
- **Sound processing** — microphone volume boost while recording, silence removal before
  upload, and system sounds on key transitions.
- **Dictionary** — case-insensitive replacement rules applied to every transcript. Rules match whole words: “doka” → “DOKA” no longer touches “document”; the per-rule “Inside words” switch brings back substring matching (e.g. “ё” → “е”). Optionally applied to file transcripts as well.

## Privacy

The three recognition modes differ in what leaves your Mac:

| Mode | What leaves your Mac |
|---|---|
| Local models (Whisper, Parakeet) | **Nothing.** Audio never leaves the device, and no key is needed — speaker diarization and AI analysis of the transcript included |
| Built-in service (Nexara) | Audio is uploaded to `api.nexara.ru` for recognition |
| Custom OpenAI-compatible service | Audio is uploaded to the endpoint you configure |

Everything else stays local. Transcript history, statistics and the transcription library
(with compressed audio of transcribed files — can be turned off in General → Advanced)
live in `~/Library/Application Support/DOKA`. Storing dictation audio is **off by default**;
when enabled, recordings are kept locally as m4a and pruned on a schedule you choose. API
keys live in the macOS Keychain, never in config files.

## Requirements

- A Mac with Apple silicon (M1 or newer). Intel Macs are not supported.
- macOS 15 (Sequoia) or newer.
- For local AI analysis — about 2.7 GB of disk space for the model and up to 5 GB of memory
  while it runs.
- **Xcode 26 or newer** to build from source. The package itself declares
  `swift-tools-version: 5.9` and targets macOS 15, but one of its dependencies
  requires Swift 6.2, and the Liquid Glass APIs need the macOS 26 SDK to compile.
  The built app still runs on macOS 15 — this requirement applies to the build machine only.
- An API key only if you pick a cloud service — local models need none.

## Installation

No signed release is published yet, so build from source:

```bash
git clone https://github.com/ippitenin/DOKA-macOS.git
cd DOKA-macOS/DOKA-app
./build.sh
```

The app is installed to `~/Applications/DOKA.app`. First launch walks you through three
steps: **Microphone** and **Accessibility** permissions — the first records your voice, the
second pastes the text — and then the recognition service. Pick a cloud service and paste
its key, or pick a local model and download it right there: it runs on your Mac, with no
internet and no key.

## Building and signing

All commands run from `DOKA-app/`:

```bash
swift build        # quick debug compile check
scripts/build-shaders.sh   # Metal shaders of the recording panel → default.metallib
./build.sh         # release (arm64), signed, installed to ~/Applications
./build.sh --dmg   # the same, plus DOKA.dmg in the repository root
./run.sh           # build.sh + launch
```

SwiftPM does not compile `.metal`, so the recording panel's shaders are built by a separate
script. `build.sh` runs it for you; before a bare `swift build` run it by hand — otherwise the
app builds without the panel effects.

Release builds are signed with a self-signed **“DOKA Dev”** certificate — see
[`DOKA-app/scripts/make-dev-cert.md`](DOKA-app/scripts/make-dev-cert.md). Both the
certificate name and the install directory can be overridden with `DOKA_SIGN_ID` and
`DOKA_INSTALL_DIR`.

Installing from a DMG on another Mac means Gatekeeper does not know the certificate and
blocks the first launch: System Settings → Privacy & Security → **Open Anyway**, then grant
the microphone and accessibility permissions.

## Recognition services

Pick one on first launch, or later in the **Service** section:

| Service | API key | Notes |
|---|---|---|
| Whisper Large v3 Turbo (Local) | not needed | ~1.6 GB one-time download, runs through WhisperKit on the Neural Engine |
| Parakeet TDT 0.6B v3 (Local) | not needed | ~700 MB, runs through FluidAudio |
| Built-in (Nexara) | required | adds recording-type presets, speaker roles, analysis ordered with transcription, and async jobs |
| Custom service | required | any OpenAI-compatible `/audio/transcriptions` endpoint |

Local models are downloaded once — from the third step of the first launch or from the
Service section — prepared for your chip on first use, and unloaded from memory after five
minutes of inactivity.

Speaker diarization works with every service: the built-in one does it server-side, everyone
else gets the on-device diarizer. What stays exclusive to the built-in service — and is shown
greyed out elsewhere — is the recording-type preset, automatic speaker roles, and cloud analysis in the same
request, because its `prompt` means something entirely different in a plain OpenAI-compatible
API; analysis ordered while transcribing always runs on this Mac there.

AI analysis of a finished transcript does not depend on the service: it is written by a
language model on this Mac and is equally available to recordings of any origin. The model
(2.7 GB) is downloaded from the “AI analysis on this Mac” card in the Service section, or
straight from the “AI analysis” card of a record, and is unloaded from memory after three
minutes of inactivity.

## Repository layout

| Path | Purpose |
|---|---|
| `DOKA-app/` | The application itself (SPM executable, AppKit + SwiftUI) |
| `DOKA_LOGO/` | Brand logo sources |
| `media/` | Images used by this README |
| `CLAUDE.md` | Detailed architecture and project invariants |

## Development

Architecture, invariants, commands and verification gates are documented in
[`CLAUDE.md`](CLAUDE.md). The short version: `DictationController` is the central state
machine; file transcription is deliberately isolated from the dictation pipeline
(`FileTranscriptionController` plus `Network/FileTranscriptionClient.swift`); the design
system lives in `UI/DesignSystem/`.

Pure logic is covered by tests — `swift test` runs 531 checks in under a second, and
CI runs them on every pull request along with the build and a localisation check. Audio
capture, pasting, Keychain and the recorder panels need a real Mac with real permissions,
so those are verified by a manual smoke pass; `CLAUDE.md` lists what to check per area.

Two things worth knowing before you change dependencies or strings:

- **Dependency versions are pinned on purpose** — do not bump them with a blind
  `swift package update`; see [`CONTRIBUTING.md`](CONTRIBUTING.md) for why.
- **Every interface string goes through `L("key")`**, and every key must exist in both
  `ru.lproj` and `en.lproj`. `swift build` does not validate `.strings` syntax — run
  `plutil -lint` after editing them.

Contributions are welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Credits and third-party licenses

Full list with versions and required notices: [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).

- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) — MIT
- [llama.cpp](https://github.com/ggml-org/llama.cpp) — MIT (prebuilt xcframework, bundled
  in `DOKA.app/Contents/Frameworks`)
- [WhisperKit / argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift) — MIT
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — Apache-2.0
- [swift-transformers](https://github.com/huggingface/swift-transformers),
  [swift-jinja](https://github.com/huggingface/swift-jinja) and Apple’s `swift-*` packages — Apache-2.0
- [yyjson](https://github.com/ibireme/yyjson) — MIT

Models are downloaded by the user at runtime and are not part of this repository:

- [Whisper large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo) by OpenAI — MIT
- [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) by NVIDIA — CC-BY-4.0
- [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B) by Alibaba Cloud — Apache-2.0
  (GGUF quantization by [lmstudio-community](https://huggingface.co/lmstudio-community/Qwen3.5-4B-GGUF))

## License

[GPL-3.0](LICENSE) © Ilya Pitenin
