---
title: "Speech model benchmarks"
description: "Which speech models OpenCaptions measured, how they compare on accuracy and speed across 13 languages, and why Whisper Large v3 Turbo is the default with Parakeet as the fast option."
sidebar:
  order: 3
---

# Speech model benchmarks

The local provider runs Whisper (faster-whisper) and, as an option, Parakeet v3 (sherpa-onnx). This page
holds the measurements behind that choice and behind the transcription settings, so the next model is
judged the same way.

Everything ran on **4 vCPU of an Intel Xeon @ 2.3 GHz (with AMX and AVX512-BF16), no GPU, no Apple
hardware**: the case for Docker without a GPU. The models are int8 (ONNX Runtime or CTranslate2), except
Qwen3-ASR, which is bf16 PyTorch and depends on that CPU's instruction set. Two kinds of audio were used:

- **FLEURS**, the public multilingual test set, for accuracy per language.
- **A 10-minute animated short** (dialogue shouted over fights and music, long silences, a sung chant) for
  what a long recording does to a model. Six of its spoken lines were known in advance.

## Accuracy (FLEURS test, 20 clips per language)

Error rate in percent, lower is better: words, except Japanese and Chinese (characters). The
language of each clip is given to the model, so this is recognition alone. Twenty clips is about
four minutes per language: differences under two points are noise.

| Model | en | fr | de | es | it | pt | pl | ru | tr | id | ja | ko | zh |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Whisper large-v3-turbo** | 5.2 | 7.4 | 3.6 | 1.9 | 2.4 | 4.4 | 6.2 | 5.9 | 8.5 | 8.8 | 3.5 | 12.7 | 7.5 |
| Whisper small | 7.0 | 15.2 | 9.1 | 5.2 | 7.3 | 6.6 | 15.7 | 11.6 | 19.9 | 14.6 | 11.0 | 25.4 | 17.1 |
| Whisper distil-large-v3.5 | 5.5 | | | | | | | | | | | | |
| Parakeet v3 (int8) | 7.0 | 9.0 | 4.7 | 2.3 | 3.9 | 4.2 | 9.5 | 10.3 | | | | | |
| Cohere Transcribe (int8) | 7.0 | 6.7 | 4.4 | 2.9 | 3.2 | 6.8 | 9.2 | | | | 5.4 | 13.7 | 23.8 |
| Qwen3-ASR 1.7B (bf16, PyTorch) | **3.0** | **4.6** | 3.6 | 2.5 | **1.8** | 4.2 | 14.8 | 5.4 | 11.1 | **5.0** | 3.5 | 14.1 | 7.9 |
| Qwen3-ASR 0.6B (bf16, PyTorch) | 3.9 | 9.0 | 4.9 | 5.2 | 5.7 | 7.1 | 27.4 | 9.5 | 12.7 | 8.8 | 8.0 | 13.7 | 7.8 |
| Qwen3-ASR 0.6B (sherpa-onnx int8 build) | 5.7 | 14.3 | 17.8 | 4.8 | 9.5 | 11.9 | 45.2 | 20.6 | 34.0 | 14.6 | 11.8 | 19.2 | 8.4 |
| Canary 180M flash (int8) | 15.0 | 9.0 | 5.8 | 5.2 | | | | | | | | | |

Whisper large-v3-turbo is the most accurate on most languages. The exception is Qwen3-ASR 1.7B,
which beats it on English (3.0 against 5.2), French (4.6 against 7.4) and Indonesian (5.0 against
8.8), is level on German, Italian, Portuguese, Russian and Japanese, and is worse on Polish (14.8
against 6.2), Turkish and Korean; Cohere is level with Whisper on French. Parakeet makes 1.2 to 1.8
times Whisper's errors on the languages it covers (Portuguese is level); the leaderboard figures put
them level, which these int8 builds do not reproduce. Parakeet covers 25 European languages, not
Turkish, Indonesian, Japanese, Korean or Chinese.

## Speed and memory (CPU)

Seconds of audio per second of decoding, on slices of the short film (225 s), models loaded from
a warm disk, via sherpa-onnx unless noted.

| Model | Speed | Peak RAM |
|---|---|---|
| SenseVoice small | 35x | 0.5 GB |
| Moonshine base (English) | 28x | 0.5 GB |
| Parakeet v3 | 15.5x | 1.2 GB |
| Canary 180M flash | 12x | 0.6 GB |
| Whisper distil-large-v3.5 | 5.4x | 2.1 GB |
| Whisper small | 4.8x | 1.1 GB |
| Whisper large-v3-turbo | 4.7x (CTranslate2: 4.2x on the whole film) | 2.2 GB |
| Whisper large-v3 | 0.4x | 4.3 GB |
| Qwen3-ASR 0.6B (sherpa int8 build) | 4x | 3.5 GB |
| Cohere Transcribe | 2x | 3.7 GB |

Qwen3-ASR in bf16 under PyTorch is in its own section below: its speed depends on the CPU.

On the whole film through the provider, Parakeet took 58 s against Whisper's 150 s (2.6x
faster, language identification included).

Language identification (Whisper base, three 30 s windows spread through the recording) named
the language correctly for all 13 FLEURS languages, 0.91 to 1.00 sure; it decides whether Parakeet
or Whisper gets a recording when the language was not chosen.

## Long recordings: what Whisper skips

On the short film, six known spoken lines were missing from faster-whisper's output. One setting changed
at a time, large-v3-turbo:

| Setting | Lines found (of 6) | Speed |
|---|---|---|
| Voice filter on, threshold 0.5 | 1 | 8.0x |
| Voice filter on, threshold 0.3 to 0.1, longer padding | 3 to 4 | 5.7 to 10.9x |
| Voice detection spans, then Whisper on each | 3 | 3.6x |
| **Voice filter off** | **6** | 4.3x |
| **Voice filter off + hallucination guard (the default)** | **6** | 4.2x |

The voice filter (Silero) takes shouting and speech over a loud music bed for non-speech, and what it
drops is never decoded, whatever the threshold. So it is off by default. Decoding everything costs about
twice the CPU on this clip (less on talking-head recordings with long silences), and
`WHISPER_VAD_FILTER=true` switches the filter back on. Beam 5 stays: greedy decoding triggers more
temperature fallbacks and was slower (2.8x against 4.2x), with repeated words.

Parakeet, given the same audio in 20 s windows, found four of the six lines. A window that comes back
empty though it is not quiet is decoded again in halves (`chunking.py`).

### Stretches Whisper still leaves empty

With the filter off, Whisper still prints nothing for 19 stretches of over 4 s (297 s in all) on the
film. It is not a token limit (the busiest window used 137 of its 448 tokens) and not a threshold: with
the hallucination, no-speech, log-probability and compression-ratio checks all off, the same stretches stay
empty. It is how faster-whisper's long-form loop moves on: when a 30 s window's output ends in a single
timestamp ("no speech after the last timestamp"), it advances the whole window, so audio the model judged
not to be speech after that point is never decoded.

### The second look (off by default)

`chunking.second_look` (`WHISPER_FILL_GAPS=true`) decodes each long empty stretch that is not quiet again
alone, twice with the window shifted 0.9 s, and keeps only the words both readings give within 1.5 s.
Invented text differs between the two readings; speech comes out of both. Listening to the film's 18 long
empty stretches gave the reference (12 held real words or interjections, 5 held nothing):

| Reading | Real words | Fake words |
|---|---|---|
| Whisper, first window | 32 | 28 |
| Whisper, either window | 55 | 51 |
| Whisper, only words both windows give (the rule) | 12 | 1 |
| Qwen3-ASR 1.7B | 29 | 40 |
| Parakeet v3 | 2 | 6 |

It stays opt-in because of what it costs and what it cannot do:

- **Cost.** The film went from 188 s to 976 s (3.4x to 0.6x real time): Whisper's temperature fallback
  retries hard over music and noise, 15 to 20 s per stretch.
- **No cheap version.** Without the fallback the decode loops ("Oh my God" over and over) and both readings
  loop identically, so the agreement test passes them.
- **It reads what Whisper reads.** Some stretches hold words only Qwen or Parakeet hear.
- **It loses interjections** ("Oh", "Ah") that Whisper reads in only one window.
- Word confidence does not separate real from invented text (real 0.03 to 0.92, invented 0.16 to 0.74).
- Whisper is not reproducible on this content: two runs of the same first pass differ by about 170 of 734
  words, because the fallback samples above temperature 0.

## Qwen3-ASR 1.7B and 0.6B (PyTorch, bf16)

The most accurate model on English, French and Indonesian, with the most caveats. Weights 3.8 GB (1.7B)
and 1.5 GB (0.6B); `scripts/asr-bench/qwen3.py`.

- **Dialogue gaps: none.** The whole film in 20 s windows, no voice filter: 6 of 6 lines, none empty.
- **The sherpa-onnx int8 build is not the model.** The 0.6B in bf16 makes 4.9% on German, 27.4% on Polish
  and 12.7% on Turkish, against 17.8, 45.2 and 34.0 as int8. A community mixed int8/FP32 export of the
  1.7B runs without PyTorch at 1.6 to 1.9x but makes 1.3 to 2 times the errors of bf16, and its 512-token
  context cuts a long clip short.
- **It can loop.** On 3 of 40 windows (screams) the decoder ran to its 500-token limit, 71 to 75 s each.
  A token cap of 8 per second of audio bounds a loop to 28 s; `no_repeat_ngram_size=3` ends it in 2 to 4 s
  but forbids real repetition ("no, no, no").
- **No timestamps.** Alignment is a second model, Qwen3-ForcedAligner-0.6B (1.8 GB), for 11 languages (not
  Polish, Turkish or Indonesian, where Qwen gains most). Against Whisper's word times the median difference
  is 0.07 s and the 90th percentile 0.54 s, but the first word after non-speech is put at the window's
  start, seconds early.
- **Its speed depends on the CPU.** bf16 is fast only with AMX or AVX512-BF16 (English, same clips,
  `ONEDNN_MAX_CPU_ISA` capping what oneDNN may use):

| CPU instruction set | Qwen3-ASR 1.7B (bf16) | Whisper turbo (int8) |
|---|---|---|
| AMX and AVX-512 (this machine) | 2.2x | 2.55x |
| AVX-512, no AMX | 1.2x | 2.1x |
| AVX2 only | 0.6x, slower than real time | 2.1x |

- **Size.** 6.0 GB (1.7B) and 3.3 GB (0.6B) in bf16, before the aligner. PyPI's torch wheel pulls the CUDA
  libraries (5.4 GB for the environment); the CPU-only wheel comes from PyTorch's own index.

**Not offered yet.** It beats Whisper by 2 to 3 points of error on English and French, which does not
outweigh the sync defect, the 6 to 9 GB, the CPU dependence and the extra dependencies for most
self-hosters. Shipping it would take an optional engine listed only on a CPU with AMX or AVX512-BF16 (or a
GPU), the token cap and loop retry, the aligner with the first-word defect handled, and a decision for the
languages the aligner lacks.

## Languages Whisper does not serve: Omnilingual ASR

Meta's [Omnilingual ASR](https://huggingface.co/facebook/omniASR-CTC-1B) (CTC, Apache 2.0, 1,600+
languages) has sherpa-onnx int8 builds. FLEURS, 15 clips per language, error % as WER (CER):

| Language | Whisper turbo | Omnilingual 1B int8 |
|---|---|---|
| Swahili | 29.3 (8.8) | **11.9 (3.0)** |
| Hausa | 98.9 (38.4) | **23.0 (5.3)** |
| Tamil | 76.2 (29.4) | **37.9 (10.3)** |
| Yoruba | 96.3 (41.1) | **52.0 (16.3)** |
| Amharic | 118.8 (97.2) | **58.3 (12.3)** |
| Speed | 0.6 to 3.6x | 4.3x |

The 1B loads in 7 s, peaks at 1.3 GB, needs no language, gives a time per character, and writes lowercase
text with no punctuation, so captions from it are cut at pauses and length, not at sentence ends. On the
languages Whisper does well it loses by about a factor of two (German 8.7 against 3.6, English 10.5 against
5.2), so it is for the languages Whisper cannot do, never a general default. It is not wired into the server:
that needs the segmentation, the CTC token times and a rule for which languages go to it.

## Other models

Judged from model cards and the Open ASR Leaderboard (May 2026, [arXiv 2510.06961](https://arxiv.org/html/2510.06961v4)),
not measured here:

- **Granite Speech 4.1 2B** (IBM, Apache 2.0): top of the leaderboard (5.33%), but six languages and no word
  times in the base model.
- **Cohere Transcribe** (2B, 14 languages): gated, no timestamps or language detection. Measured only as an
  int8 build, which was no better than Whisper (2.7 GB, 2x real time).
- **Canary-Qwen 2.5B**: English only.
- **Canary-1B-v2** (25 European languages): the one community int8 export tried gave German 4.0 and French
  5.9 but English 38.6 and Spanish 52.4, so it is broken for some languages; an official export is needed.
- **Voxtral Mini 4B Realtime** (13 languages, streaming): 4B in bf16, so on-device depends on a quantized build.

## Quantization

Fewer bits per weight means smaller files and, because decoding mostly waits on memory, faster decoding; the
price is rounding error, which depends on the model more than on the format.

| Format | Bytes per parameter | Large-v3-turbo (0.81B) | Where it runs |
|---|---|---|---|
| float32 | 4 | 3.2 GB | Everywhere; the reference |
| float16 / bfloat16 | 2 | 1.6 GB | GPUs and the Neural Engine; on a CPU only with AMX or AVX512-BF16 |
| int8, weights | 1 | 0.8 GB | CPU (the main route) and GPU |
| 4-bit (GGUF Q4_K_M, palettization) | 0.5 | 0.4 GB | llama.cpp on CPU and Metal; Core ML on the Neural Engine |

Whisper (an encoder-decoder) takes int8 well. Qwen3-ASR (a language-model decoder) does not: plain int8
made the decoder repeat itself. Measure each model before trusting a build.

## What was chosen

- **Default: Whisper large-v3-turbo.** The most accurate or level on most languages measured, 99 languages,
  1.6 GB, and its speed does not depend on the CPU. Voice filter off, hallucination guard on, beam 5.
- **Parakeet v3 is offered as the fast model** for its 25 languages: about 2.6x faster and half the memory.
  A recording in another language goes to Whisper, and the job says so.
- **Candidate, not wired in:** Omnilingual ASR 1B, for the languages Whisper cannot do.
- **Not offered:** Qwen3-ASR (above), Cohere Transcribe, Canary 180M and SenseVoice (too inaccurate),
  Moonshine (English only).

## On the phone

Not measured here: written from FluidAudio's own benchmarks and its source. The phone offers two Parakeet
builds from Moondream, both trained from v3 (same 25 languages and vocabulary, CC-BY-4.0), through FluidAudio
on the Neural Engine. FluidAudio's figures, which are not ours:

| | v3 (before) | Ultra | Redux |
|---|---|---|---|
| What | NVIDIA's model | v3 trained further at full precision | v3 with a ternary encoder |
| Download | 480 MB | 632 MB | 220 MB |
| Librispeech clean / other (WER %) | 2.27 / 4.12 | 2.13 / 3.81 | 2.71 / 5.12 |
| FLEURS, mean of 24 languages (WER %) | 14.81 | 11.67 | 13.06 |
| Speed on the Neural Engine (test-clean) | 128.6x | 126.7x | 83.9x |

Ultra replaced v3 on the phone: more accurate on every FLEURS language FluidAudio lists, at the same speed.
Redux is the small download. Moondream's own table has it degrade in noise (MUSAN 6.72 to 9.04) and on some
languages (French 7.71 against 4.81), which is why it is the small option and not the recommendation. It
needs iOS 18, and its first load compiles it for the Neural Engine for several minutes (the screen says so;
the system keeps the result). The server keeps v3: Ultra has not been exported to sherpa-onnx and measured on
the CPU yet.

Redux is on the phone only. Moondream's own runtime for it (`photon`, the `moondream` package) depends on
`kestrel-kernels`, which is under a proprietary licence that grants no rights without a written agreement with
M87 Labs, and its client reads an API key and sends telemetry. That cannot go into an AGPL image that people
host themselves, so it is not evaluated further, and its kernels are not to be inspected or worked around.

Apple's `SpeechTranscriber` (iOS 26) is offered as a proof of concept: its results can lack time ranges, so
the app spreads a result's words over the time it has and logs how many got a time of their own. All of them
need measuring on a phone against Whisper before any is the default.

## Not measured

GPU speed (the leaderboard puts Parakeet far ahead, 1719x against 111 to 176x for Whisper, and says nothing
about accuracy on this content), the Neural Engine and iPhone speed and load time, Granite Speech, Voxtral,
Canary 1B, Qwen3-ASR through llama.cpp, and noisy or accented speech beyond the one film, for every model.

## Reproducing

```sh
uv run scripts/asr-bench/fleurs.py large-v3-turbo,small all 20   # a faster-whisper size
uv run scripts/asr-bench/fleurs.py parakeet,qwen3-0.6b,cohere en,fr,de 20   # the sherpa-onnx int8 builds
uv run scripts/asr-bench/qwen3.py 1.7b en,fr,id 20                          # PyTorch bf16; 0.6b too, --no-hint
ONEDNN_MAX_CPU_ISA=AVX2 uv run scripts/asr-bench/qwen3.py 1.7b en 4         # a CPU without AVX-512 or AMX
uv run scripts/asr-bench/longtail.py                                           # Whisper against Omnilingual, 5 languages
```

One engine per process if the memory column matters: the peak is the process's.
