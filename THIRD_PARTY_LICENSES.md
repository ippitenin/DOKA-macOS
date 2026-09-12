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
| llama.cpp (prebuilt xcframework) | b10909 | MIT | https://github.com/ggml-org/llama.cpp |

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
| KeyboardShortcuts | 2.4.0 | MIT | https://github.com/sindresorhus/KeyboardShortcuts |
| WhisperKit (argmax-oss-swift) | 0.18.0 | MIT | https://github.com/argmaxinc/argmax-oss-swift |
| FluidAudio | 0.15.5 | Apache-2.0 | https://github.com/FluidInference/FluidAudio |
| swift-argument-parser | 1.8.2 | Apache-2.0 | https://github.com/apple/swift-argument-parser |
| swift-asn1 | 1.7.1 | Apache-2.0 | https://github.com/apple/swift-asn1 |
| swift-collections | 1.6.0 | Apache-2.0 | https://github.com/apple/swift-collections |
| swift-crypto | 4.5.1 | Apache-2.0 | https://github.com/apple/swift-crypto |
| swift-jinja | 2.4.2 | Apache-2.0 | https://github.com/huggingface/swift-jinja |
| swift-transformers | 1.1.9 | Apache-2.0 | https://github.com/huggingface/swift-transformers |
| yyjson | 0.12.0 | MIT | https://github.com/ibireme/yyjson |

FluidAudio bundles its own third-party components (`fastcluster`, `vbx`); their licenses
ship with the package in `ThirdPartyLicenses/`.

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

Two dependencies ship a `NOTICE` file whose contents must travel with any distribution that
includes them.

### swift-crypto

```
                            The SwiftCrypto Project
                            =======================

Please visit the SwiftCrypto web site for more information:

  * https://github.com/apple/swift-crypto

Copyright 2019 The SwiftCrypto Project

The SwiftCrypto Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

  https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations
under the License.

Also, please refer to each LICENSE.<component>.txt file, which is located in
the 'license' directory of the distribution file, for the license terms of the
components that this product depends on.
```

### swift-asn1

```
                            The SwiftASN1 Project
                            =====================

Please visit the SwiftASN1 web site for more information:

  * https://github.com/apple/swift-asn1

Copyright 2022 The SwiftASN1 Project

The SwiftASN1 Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

  https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations
under the License.

Also, please refer to each LICENSE.txt file, which is located in
the 'license' directory of the distribution file, for the license terms of the
components that this product depends on.

---

This product contains derivations of various scripts from SwiftNIO.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-nio

---

This product contains derivations of various scripts from Swift OpenAPI Generator.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-openapi-generator
```
