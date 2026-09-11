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
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey">
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
- **Recent transcriptions** — a local journal of finished and running jobs. Finished ones
  reopen with every export and a switchable timestamp detail level.
- **AI analysis** — meeting minutes, a summary, action items or your own prompt. The result
  renders as formatted text with headings, lists and tables; copying puts both plain and
  rich text on the clipboard, so tables paste as tables into Telegram, Notes or Word.
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
| Local models (Whisper, Parakeet) | **Nothing.** Audio never leaves the device, and no key is needed — speaker diarization included |
| Built-in service (Nexara) | Audio is uploaded to `api.nexara.ru` for recognition |
| Custom OpenAI-compatible service | Audio is uploaded to the endpoint you configure |

Everything else stays local. Transcript history, statistics and the transcription journal
live in `~/Library/Application Support/DOKA`. Storing dictation audio is **off by default**;
when enabled, recordings are kept locally as m4a and pruned on a schedule you choose. API
keys live in the macOS Keychain, never in config files.

## Requirements

- macOS 14 (Sonoma) or newer.
- Apple Silicon for the local models. Whisper runs on Intel too, but much slower; Parakeet
  requires Apple Silicon.
- **Xcode 26 or newer** to build from source. The package itself declares
  `swift-tools-version: 5.9` and targets macOS 14, but one of its dependencies
  requires Swift 6.2, and the Liquid Glass APIs need the macOS 26 SDK to compile.
  The built app still runs on macOS 14 — this requirement applies to the build machine only.
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
./build.sh         # release (universal: arm64 + x86_64), signed, installed to ~/Applications
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
| Parakeet TDT 0.6B v3 (Local) | not needed | ~700 MB, runs through FluidAudio, Apple Silicon only |
| Built-in (Nexara) | required | adds recording-type presets, speaker roles, AI analysis and async jobs |
| Custom service | required | any OpenAI-compatible `/audio/transcriptions` endpoint |

Local models are downloaded once — from the third step of the first launch or from the
Service section — prepared for your chip on first use, and unloaded from memory after five
minutes of inactivity.

Speaker diarization works with every service: the built-in one does it server-side, everyone
else gets the on-device diarizer. Two things stay exclusive to the built-in service and are
shown greyed out elsewhere — the recording-type preset and automatic speaker roles (both
server features), and AI analysis, because its `prompt` means something entirely different
in a plain OpenAI-compatible API.

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

Pure logic is covered by tests — `swift test` runs about 140 checks in under a second, and
CI runs them on every pull request along with the build and a localisation check. Audio
capture, pasting, Keychain and the recorder panels need a real Mac with real permissions,
so those are verified by a manual smoke pass; `CLAUDE.md` lists what to check per area.

Two things worth knowing before you change dependencies or strings:

- **Do not move WhisperKit past the 0.18.x line** — in 1.x two executable products share a
  target and the universal build fails with “duplicate key found”.
- **Every interface string goes through `L("key")`**, and every key must exist in both
  `ru.lproj` and `en.lproj`. `swift build` does not validate `.strings` syntax — run
  `plutil -lint` after editing them.

Contributions are welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Credits and third-party licenses

Full list with versions and required notices: [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).

- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) — MIT
- [WhisperKit / argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift) — MIT
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — Apache-2.0
- [swift-transformers](https://github.com/huggingface/swift-transformers),
  [swift-jinja](https://github.com/huggingface/swift-jinja) and Apple’s `swift-*` packages — Apache-2.0
- [yyjson](https://github.com/ibireme/yyjson) — MIT

Speech models are downloaded by the user at runtime and are not part of this repository:

- [Whisper large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo) by OpenAI — MIT
- [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) by NVIDIA — CC-BY-4.0

## License

[GPL-3.0](LICENSE) © Ilya Pitenin
