# Third-party notices

ThumbFree for Mac runs these libraries and downloads these models (each once, checked against a fixed SHA-256). Each
keeps its own license.

## Libraries

The speech engines are linked into the app as static libraries: `CSherpaOnnx.xcframework` and `CWhisper.xcframework`,
built by [`.github/workflows/engines.yml`](.github/workflows/engines.yml) from the pinned sources in
[`scripts/engines`](scripts/engines) and published as the
[`engines-sherpa-onnx-2.0.1-3`](https://github.com/shivam098/thumbfree-mac/releases/tag/engines-sherpa-onnx-2.0.1-3) and
[`engines-whisper-1.9.5-3`](https://github.com/shivam098/thumbfree-mac/releases/tag/engines-whisper-1.9.5-3) releases.
Each engine's zip has its notice next to the xcframework, `CSherpaOnnx-NOTICE.txt` and `CWhisper-NOTICE.txt` (also
attached to the releases): the license texts of everything below that it links in, with ONNX Runtime's own third-party
notices. The app carries this file and both notices in `ThumbFree.app/Contents/Resources` (`scripts/make-app.sh`).

What the build checks (`scripts/engines/check-notice.py`): it sorts every global symbol an engine's library defines,
in both architectures, into groups, by a C++ symbol's outermost namespace or class (or the function itself, outside
any namespace; for `google::`, which protobuf shares with glog and gflags, the next one too) and by a C symbol's
prefix, and fails unless a line of `scripts/engines/<engine>.claims` assigns every group to a library, and the notice
has, word for word, the license files that line names: the library's own, or for what ONNX Runtime builds in, ONNX
Runtime's third-party notices, with a section for that library. Only the C++ standard library's groups and compiler
helpers need no notice. Code that only appears inside another library's functions (inlined, or as a template argument)
has no symbols of its own, so the other library's line covers it: Boost inside ONNX Runtime, for example.

The code is used unmodified, with two marks for Xcode's linker, which no instruction or data depends on: ONNX
Runtime's MLAS assembly kernels have the `MH_SUBSECTIONS_VIA_SYMBOLS` flag, with their inner labels as alternate
entries, and the assembly that embeds ggml's Metal source has the same, with one zero byte after its end label.
Without them, Xcode's build system can't link the engines into a Swift package target
([`scripts/engines/subsections.py`](scripts/engines/subsections.py)).

| Component | Used for | License |
|---|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 2.0.1 (C API, its universal2 static libraries without text-to-speech) | Running the Kroko and Parakeet models | Apache-2.0 |
| [kaldi-native-fbank](https://github.com/csukuangfj/kaldi-native-fbank) 1.22.4, [kaldi-decoder](https://github.com/k2-fsa/kaldi-decoder) 0.3.0, [kaldifst](https://github.com/k2-fsa/kaldifst) 1.8.0, [OpenFst](https://github.com/csukuangfj/openfst) 1.8.5, [simple-sentencepiece](https://github.com/pkufool/simple-sentencepiece) 0.7 (inside sherpa-onnx) | Audio features, decoding, tokens | Apache-2.0 |
| [KISS FFT](https://github.com/mborgerding/kissfft) (inside kaldi-native-fbank) | Audio features | BSD-3-Clause |
| [darts-clone](https://github.com/s-yata/darts-clone) (inside simple-sentencepiece) | Tokens for the punctuation model | BSD-2-Clause |
| [ThreadPool](https://github.com/progschj/ThreadPool) by Jakob Progsch and Václav Zeman (inside simple-sentencepiece) | Parallel tokenizing | Zlib |
| [hclust-cpp](https://github.com/csukuangfj/hclust-cpp) with fastcluster (inside sherpa-onnx) | Speaker clustering (not used by ThumbFree) | BSD-2-Clause |
| [utf8proc](https://github.com/JuliaStrings/utf8proc) 2.12.0 (inside sherpa-onnx) | Unicode text handling | MIT, and the Unicode data license |
| [nlohmann/json](https://github.com/nlohmann/json) 3.12.0 (inside sherpa-onnx and ONNX Runtime) | Reading JSON | MIT |
| [Eigen](https://gitlab.com/libeigen/eigen) 5.0.1 (inside kaldi-decoder) and Eigen 3.4.90 at commit [`1d8b82b0`](https://gitlab.com/libeigen/eigen/-/commit/1d8b82b0740839c0de7f1242a3585e3390ff5f33) (inside ONNX Runtime) | Linear algebra | MPL-2.0; used unmodified, source code: [5.0.1](https://gitlab.com/libeigen/eigen/-/archive/5.0.1/eigen-5.0.1.tar.gz), [1d8b82b0](https://gitlab.com/libeigen/eigen/-/archive/1d8b82b0740839c0de7f1242a3585e3390ff5f33/eigen-1d8b82b0740839c0de7f1242a3585e3390ff5f33.tar.gz) |
| [ONNX Runtime](https://onnxruntime.ai) 1.28.2, with its MLAS kernels (inside sherpa-onnx: the static build in [onnxruntime-libs v1.28.2](https://github.com/csukuangfj/onnxruntime-libs/releases/tag/v1.28.2)) | Neural network inference | MIT |
| [protobuf](https://github.com/protocolbuffers/protobuf), [re2](https://github.com/google/re2) (inside ONNX Runtime) | Reading models, text patterns | BSD-3-Clause |
| [abseil](https://github.com/abseil/abseil-cpp), [flatbuffers](https://github.com/google/flatbuffers), [ONNX](https://github.com/onnx/onnx) (inside ONNX Runtime) | Containers, the model format | Apache-2.0 |
| [SafeInt](https://github.com/dcleblanc/SafeInt), [GSL](https://github.com/microsoft/GSL), [date](https://github.com/HowardHinnant/date) (inside ONNX Runtime) | Checked arithmetic, spans, times | MIT |
| [Boost](https://www.boost.org), header-only parts (inside ONNX Runtime) | Type lists | BSL-1.0 |
| MurmurHash3 by Austin Appleby (inside ONNX Runtime) | Hashing | Public domain (ONNX Runtime's notices list it as MIT) |
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) 1.9.5 with [ggml](https://github.com/ggml-org/ggml) (Metal and Accelerate) | Running the Hindi + English models and Silero | MIT |

## Models

| Model | Used for | License |
|---|---|---|
| [Kroko ASR](https://huggingface.co/Banafo/Kroko-ASR) English streaming Zipformer, by Banafo (community model) | English, Live | CC BY-SA 4.0 |
| [Edge-Punct-Casing](https://huggingface.co/frankyoujian/Edge-Punct-Casing) | Punctuation for English, Live | Apache-2.0 |
| [NVIDIA Parakeet TDT CTC 110M](https://huggingface.co/nvidia/parakeet-tdt_ctc-110m), TDT head, int8 ONNX from sherpa-onnx | English, Standard | CC BY 4.0 |
| [NVIDIA Parakeet TDT 0.6B v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2), [int8 ONNX from sherpa-onnx](https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8) | English, Accurate | CC BY 4.0 |
| [Oriserve/Whisper-Hindi2Hinglish-Swift](https://huggingface.co/Oriserve/Whisper-Hindi2Hinglish-Swift), fine-tuned from [openai/whisper-base](https://huggingface.co/openai/whisper-base) | Hindi + English, Standard | Apache-2.0 (fine-tune); MIT (OpenAI Whisper base model, mel filters, vocabulary) |
| [Oriserve/Whisper-Hindi2Hinglish-Apex](https://huggingface.co/Oriserve/Whisper-Hindi2Hinglish-Apex), fine-tuned from [openai/whisper-large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo) | Hindi + English, Accurate | Apache-2.0 (fine-tune); MIT (OpenAI Whisper base model, mel filters, vocabulary) |
| [Silero VAD](https://github.com/snakers4/silero-vad) (ggml from [ggml-org/whisper-vad](https://huggingface.co/ggml-org/whisper-vad)) | Finding pauses in speech | MIT |

## Kroko ASR and Edge-Punct-Casing

The Kroko model files (encoder, decoder, joiner, tokens) and the Edge-Punct-Casing punctuation model are used
unmodified. They are downloaded separately from the app, from the
[`models-kroko-en-live-1`](https://github.com/shivam098/thumbfree-mac/releases/tag/models-kroko-en-live-1) release, which
has a `NOTICE.txt`. Kroko ASR is by [Banafo](https://huggingface.co/Banafo) and licensed under Creative Commons
Attribution-ShareAlike 4.0 (<https://creativecommons.org/licenses/by-sa/4.0/>). Edge-Punct-Casing is licensed under the
Apache License, Version 2.0 (<https://www.apache.org/licenses/LICENSE-2.0>).

## NVIDIA Parakeet

The Parakeet models are by NVIDIA, licensed under Creative Commons Attribution 4.0
(<https://creativecommons.org/licenses/by/4.0/>). ThumbFree uses the int8 ONNX exports made for sherpa-onnx. The 110M
model is mirrored in the [`models-parakeet-110m-1`](https://github.com/shivam098/thumbfree-mac/releases/tag/models-parakeet-110m-1)
release; the 0.6B model is downloaded from Hugging Face.

## Oriserve/Whisper-Hindi2Hinglish-Swift and Apex

Models by [Oriserve](https://oriserve.com). Licensed under the Apache License, Version 2.0
(<https://www.apache.org/licenses/LICENSE-2.0>); a copy of the license is attached to the
[`models-hinglish-swift-1`](https://github.com/shivam098/windows-voice-assistant/releases/tag/models-hinglish-swift-1) and
[`models-hinglish-apex-1`](https://github.com/shivam098/windows-voice-assistant/releases/tag/models-hinglish-apex-1)
releases, which the app downloads them from.

They are fine-tuned from OpenAI's `whisper-base` and `whisper-large-v3-turbo`, and the converted files also contain
OpenAI Whisper's mel filter bank and tokenizer vocabulary. Those are Copyright (c) 2022 OpenAI under the MIT License;
OpenAI's license text is attached to the same releases.

**Changes made:** the original Hugging Face weights were converted to the ggml format and quantized to 8-bit (q8_0) so
whisper.cpp can run them; the models themselves were not retrained. The steps are in
[tools/ModelConvert/README.md](https://github.com/shivam098/windows-voice-assistant/blob/main/tools/ModelConvert/README.md)
in the Voice Assistant repository. The models are distributed "AS IS", without warranties or conditions of any kind.
