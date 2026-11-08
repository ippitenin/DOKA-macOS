# Third-party licenses

DOKA itself is licensed under [GPL-3.0](LICENSE). The components listed below are **not**
covered by that license — they are used under their own terms. All of them are permissive
(MIT, Apache-2.0, or BSD-style and similar notices bundled with Sparkle) and one-way compatible
with GPL-3.0, so distributing DOKA under the GPL carries no conflicting obligations.

Versions are taken from `DOKA-app/Package.resolved`, except for the binary target, which is
pinned in `DOKA-app/Package.swift`.

## Binary frameworks

Two prebuilt binaries are shipped inside `DOKA.app` (`Contents/Frameworks`):
`llama.framework` powers on-device AI analysis of transcripts, and `Sparkle.framework`
(with its `Autoupdate` helper and `Updater.app`) installs app updates.

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

| Component | Version | License | Source |
|---|---|---|---|
| Sparkle (prebuilt xcframework) | 2.10.1 | MIT, plus the external licenses below | https://github.com/sparkle-project/Sparkle |

Sparkle's license file, reproduced in full (it includes the notices of the components
Sparkle itself bundles):

```
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=================
EXTERNAL LICENSES
=================

bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions 
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

--

sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

The sais-lite copyright is as follows:

Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

--

Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

This software is provided 'as-is', without any express or implied warranty. In no event will the
authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial
applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the
   original software. If you use this software in a product, an acknowledgment in the product
   documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be misrepresented as
   being the original software.

3. This notice may not be removed or altered from any source distribution.

--

SUSignatureVerifier.m:

Copyright (c) 2011 Mark Hamlin.

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
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
| Speaker diarization with an exact speaker count (pyannote community-1), Core ML (FluidInference) | CC-BY-4.0 | https://huggingface.co/FluidInference/speaker-diarization-coreml |
| Nemotron 3 Diarization (NVIDIA), Core ML (FluidInference) | OpenMDW-1.1 | https://huggingface.co/FluidInference/nemotron-3-diarization-coreml |
| Qwen3.5-4B, GGUF Q4_K_M (Alibaba Cloud) | Apache-2.0 | https://huggingface.co/lmstudio-community/Qwen3.5-4B-GGUF |

*nemotron-3-diarization-coreml* by FluidInference is a Core ML conversion of
[nvidia/Nemotron-3-Diarization](https://huggingface.co/nvidia/Nemotron-3-Diarization) by NVIDIA.
Use of the model is governed by the
[OpenMDW License Agreement, version 1.1](https://openmdw.ai/license/1-1/).

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
