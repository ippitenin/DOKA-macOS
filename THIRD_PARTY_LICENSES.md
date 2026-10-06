# Third-party licenses

DOKA itself is licensed under [GPL-3.0](LICENSE). The components listed below are **not**
covered by that license — they are used under their own terms. All of them are permissive
(MIT or Apache-2.0) and one-way compatible with GPL-3.0, so distributing DOKA under the GPL
carries no conflicting obligations.

Versions are taken from `DOKA-app/Package.resolved`, except for the binary target, which is
pinned in `DOKA-app/Package.swift`.

## Binary frameworks

`llama.framework` is the only prebuilt binary shipped inside `DOKA.app`
(`Contents/Frameworks`). It powers on-device AI analysis of transcripts.

| Component | Version | License | Source |
|---|---|---|---|
| llama.cpp (prebuilt xcframework) | b11429 (v0.6.0) | MIT | https://github.com/ggml-org/llama.cpp |

```
MIT License

Copyright (c) 2023-2024 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Swift packages

| Component | Version | License | Source |
|---|---|---|---|
| KeyboardShortcuts | 3.1.0 | MIT | https://github.com/sindresorhus/KeyboardShortcuts |
| WhisperKit (argmax-oss-swift) | 1.1.0 | MIT | https://github.com/argmaxinc/argmax-oss-swift |
| FluidAudio | 0.17.5 | Apache-2.0 | https://github.com/FluidInference/FluidAudio |
| swift-argument-parser | 1.8.2 | Apache-2.0 | https://github.com/apple/swift-argument-parser |

FluidAudio bundles its own third-party components (`fastcluster`, `vbx`); their licenses
ship with the package in `ThirdPartyLicenses/`. Its optional `NemoTextProcessing` engine
(a prebuilt static library from [text-processing-rs](https://github.com/FluidInference/text-processing-rs),
Apache-2.0) is disabled through the package trait and is not linked into DOKA.

Since 1.0, argmax-oss-swift no longer depends on swift-transformers: it incorporates Hub and
Tokenizers sources derived from it (see the attribution below and the `NOTICES` file shipped
with the package).

## Models

Models are downloaded by the user at runtime and are not part of this repository or of the
application bundle.

| Model | License | Source |
|---|---|---|
| Whisper large-v3-turbo (OpenAI) | MIT | https://huggingface.co/openai/whisper-large-v3-turbo |
| Parakeet TDT 0.6B v3 (NVIDIA) | CC-BY-4.0 | https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 |
| Speaker diarization, Core ML (FluidInference) | CC-BY-4.0 | https://huggingface.co/FluidInference/speaker-diarization-coreml |
| Qwen3.5-4B, GGUF Q4_K_M (Alibaba Cloud) | Apache-2.0 | https://huggingface.co/lmstudio-community/Qwen3.5-4B-GGUF |

The GGUF build of *Qwen3.5-4B* is a quantization by
[lmstudio-community](https://huggingface.co/lmstudio-community) of
[Qwen/Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B); both are Apache-2.0.

**Attribution required by CC-BY-4.0:**

- *Parakeet TDT 0.6B v3* by NVIDIA, used under
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
- *speaker-diarization-coreml* by FluidInference, used under
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). It is a Core ML conversion of
  [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1)
  by Hervé Bredin, also CC-BY-4.0.

## NOTICE files (Apache-2.0 §4(d))

None of the current dependencies ships an Apache `NOTICE` file. (swift-crypto and swift-asn1,
whose NOTICE files used to be reproduced here, left the dependency tree with WhisperKit 1.x.)

### Attribution: swift-transformers inside argmax-oss-swift

```
Portions of Argmax OSS (under Sources/ArgmaxCore/External) are derived from the
swift-transformers project:

  https://github.com/huggingface/swift-transformers

Copyright 2022 Hugging Face SAS.

These files have been modified by Argmax, Inc. Modifications are marked in the
source with "Argmax-modification:" comments, and each derived file retains its
original copyright notice in the file header.

Licensed under the Apache License, Version 2.0.
```
