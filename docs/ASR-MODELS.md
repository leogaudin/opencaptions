# Speech models: what we measured and what we chose

The local provider runs Whisper (faster-whisper) and, as an option, Parakeet v3 (sherpa-onnx).
This is how that was decided, so the next model is judged the same way.

Everything here ran on **4 vCPU of an Intel Xeon @ 2.3 GHz, no GPU, no Apple hardware**: the
case for Docker without a GPU. int8 models, ONNX Runtime or CTranslate2. Nothing was measured on
a GPU or on the Neural Engine; see the end.

## Whisper was not skipping dialogue; the voice filter was

A 10-minute animated short had six known spoken lines that faster-whisper's output lacked
(one was "Don't want to hurt you! Just keep your distance! Alright then! Eat salt you little green
bastards!", shouted over a fight). The same audio, large-v3-turbo, one setting changed at a time:

| Setting | Lines found (of 6) | Speed |
|---|---|---|
| Previous defaults (voice filter on, threshold 0.5) | 1 | 8.0x |
| Same, no-speech check off | 1 | 9.3x |
| Voice filter, threshold 0.3, 0.5 s silences | 3 | 10.9x |
| Voice filter, threshold 0.2 or 0.1, longer padding | 4 | 5.7–10.3x |
| Our own voice-detection spans, then Whisper on each | 3 | 3.6x |
| **Voice filter off** | **6** | 4.3x |
| Voice filter off + hallucination guard (the default now) | **6** | 4.2x |

The voice filter (Silero) takes shouting and speech over a loud music bed for non-speech, and
what it drops is never decoded, whatever the threshold. Decoding everything costs about twice the
CPU on this clip; on talking-head recordings with long silences it costs less, and the filter can be
switched back on (`WHISPER_VAD_FILTER=true`). Greedy decoding (`beam_size=1`) was not faster: the
temperature fallbacks it triggers made it 2.8x against 4.2x, with repeated words. Beam 5 stays.

Parakeet, given the same audio in 20 s windows, found four of the six lines: it heard "Eat salt"
as "Eat call", and missed "It's incredible, it's a new species" however the window was shifted. A
different model does not fix this either; a window that comes back empty though it is not quiet is
decoded again in halves (`chunking.py`).

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
| Qwen3-ASR 0.6B (int8) | 5.7 | 14.3 | 17.8 | 4.8 | 9.5 | 11.9 | 45.2 | 20.6 | 34.0 | 14.6 | 11.8 | 19.2 | 8.4 |
| Canary 180M flash (int8) | 15.0 | 9.0 | 5.8 | 5.2 | | | | | | | | | |

Whisper large-v3-turbo is the most accurate everywhere except French, where Cohere is within noise.
Parakeet makes 1.2 to 1.8 times its errors on the languages it covers (Portuguese is level); the
leaderboard figures put them level, which these int8 builds do not reproduce. Parakeet covers 25 European
languages, not Turkish, Indonesian, Japanese, Korean or Chinese.

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
| Qwen3-ASR 0.6B | 4x | 3.5 GB |
| Cohere Transcribe | 2x | 3.7 GB |

On the whole film through the provider, Parakeet took 58 s against Whisper's 150 s (2.6x
faster, language identification included).

## What was chosen

- **Default stays Whisper large-v3-turbo**: the most accurate on every language measured, 99
  languages, 1.6 GB.
- **Parakeet v3 is offered as the fast model** for its 25 languages, about 2.6x faster and half the
  memory. A recording in another language goes to Whisper, and the job says so.
- Not offered: Qwen3-ASR 0.6B int8 (large errors outside English, Chinese and Japanese, 3.5 GB),
  Cohere Transcribe (no better than Whisper here, 2.7 GB on disk, 2x real time), Canary 180M and
  SenseVoice (too inaccurate), Moonshine (English only).

## On the phone

Not measured: written from FluidAudio's own benchmarks and its source, and not compiled or run (no
Mac). Parakeet v3 runs through FluidAudio on the Neural Engine, 480 MB; its first load on a given chip
compiles the model once and the system keeps the result, which for Whisper takes minutes on an
iPhone 14, and FluidAudio publishes no figure for it. Apple's `SpeechTranscriber` is offered on iOS 26 as
a proof of concept: Apple's forums report time ranges missing on many results, so the app spreads a
result's words over the time it has and logs how many words got a time of their own. Both are there to be
measured on a phone against Whisper before anyone decides which should be the default.

## Not measured

GPU speed (the published leaderboard figures put Parakeet far ahead, 1719x against 111 to 176x
for Whisper, and say nothing of accuracy on this content). The Neural Engine and iPhone speed and
load time. Qwen3-ASR 1.7B, Granite Speech 4.1, Voxtral, Canary 1B. Unquantised builds. Noisy or
accented speech beyond the one film.

## Reproducing

```sh
uv run scripts/asr-bench/fleurs.py large-v3-turbo,small all 20   # a faster-whisper size
uv run scripts/asr-bench/fleurs.py parakeet,qwen3-0.6b,cohere en,fr,de 20
```

One engine per process if the memory column matters: the peak is the process's.
