# Speech models: what we measured and what we chose

The local provider runs Whisper (faster-whisper) and, as an option, Parakeet v3 (sherpa-onnx).
This is how that was decided, so the next model is judged the same way.

Everything here ran on **4 vCPU of an Intel Xeon @ 2.3 GHz (with AMX and AVX512-BF16), no GPU, no
Apple hardware**: the case for Docker without a GPU. int8 models, ONNX Runtime or CTranslate2, except
Qwen3-ASR, which is bf16 PyTorch and depends on that CPU's instruction set (see its section). Nothing
was measured on a GPU or on the Neural Engine; see the end.

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

## Qwen3-ASR 1.7B and 0.6B (PyTorch, bf16)

The most accurate model on English, French and Indonesian, and the one with the most caveats. Weights
3.8 GB (1.7B) and 1.5 GB (0.6B), transformers 5.13 or newer, `scripts/asr-bench/qwen3.py`.

**The int8 build misled an earlier reading.** The sherpa-onnx int8 build of the 0.6B (rows above) is
not the model: the same 0.6B in bf16 makes 4.9% on German, 27.4% on Polish and 12.7% on Turkish, against
17.8, 45.2 and 34.0 as int8. Giving it the language makes no difference (4.9, 27.7 and 12.5 without),
so the loss is the int8 export, which is also the only CPU-friendly route there is for it.

**Dialogue gaps: none.** The whole film in the server's 20 s windows, no voice filter: 6 of 6 lines
and no empty window, the shouted one included ("I don't want to hurt you. Just keep your distance.
All right then, eat salty little green bastard!").

**It can loop.** On 3 of the 40 windows (screams in the fight: "Oh, oh, oh, oh, …") the decoder
ran to its 500-token limit, 71 to 75 s each, more than half of the run. Outside them the film ran at
3.2x; with them, 1.6x. Capping the tokens at 8 per second of audio bounds a loop to 28 s;
`repetition_penalty` 1.1 fixed two of the three, and 1.2 invented words; `no_repeat_ngram_size=3` ended
all three in 2 to 4 s but forbids real repetition ("no, no, no"). A loop would need detecting and
decoding again with that setting, which only the retried window pays for.

**No timestamps.** Captions need the time of every word, which this model does not give. Alignment
is a second model, Qwen3-ForcedAligner-0.6B (1.8 GB), and it covers 11 languages (Chinese, English,
Cantonese, French, German, Italian, Japanese, Korean, Portuguese, Russian, Spanish): not Polish,
Turkish or Indonesian, and Indonesian is where Qwen gains most on Whisper. It is quick (0.4 to 0.6 s for a 20 s
window; the film's 714 words in 17 s). Against Whisper's own word times on the same film: median
difference 0.07 s, 90th percentile 0.54 s, 6% over a second. The failure is the first word after
non-speech: when a window opens on music or fighting, the aligner puts that word at the window's
start. "Hello" came out at 12.7 s when it is said at 17.0 s, "I" 10.8 s early, "Guys", "We" and "Danger"
2 to 3 s early (8 of the 24 window-opening words matched differ by over a second, two of those
probably wrong matches). Visible as a caption on screen long before its word.

**Its speed depends on the CPU.** bf16 is fast only with AMX or AVX512-BF16 (Sapphire Rapids and newer
Xeons, Zen 4). English, same clips, `ONEDNN_MAX_CPU_ISA` capping what oneDNN may use (an
approximation of those CPUs, not a measurement on them):

| CPU instruction set | Qwen3-ASR 1.7B (bf16) | Whisper turbo (int8) |
|---|---|---|
| AMX and AVX-512 (this machine, 20 clips) | 2.2x | 2.55x |
| AVX-512, no AMX (4 clips) | 1.2x | 2.1x |
| AVX2 only (4 clips) | 0.6x, slower than real time | 2.1x |

Parakeet did not change either (16.4x, 17.8x with AVX-512 off). float32 is 1.5x and needs 12.5 GB.
Memory in bf16: 6.0 GB (1.7B), 3.3 GB (0.6B), before the aligner. These are FLEURS clips of about 12 s,
which Whisper pads to 30 s: on the whole film turbo runs 4.2x, and the 1.7B 3.2x outside its loops. On
these same clips the 0.6B runs 4.2x, twice turbo.

**Packaging.** PyTorch and transformers go in the API image. PyPI's torch wheel pulls the CUDA
libraries (3.2 GB of `nvidia`, 5.4 GB for the environment); the CPU-only wheel is on PyTorch's own
index, which the machine this was measured on could not reach, so no lockfile was produced.

**Verdict: not offered yet.** It is the best model for English and French by 2 to 3 points of error, and
for those languages the sync defect, the 6 to 9 GB, the CPU dependence and the extra dependencies
outweigh that for most self-hosters. What shipping it would take: an optional engine in the registry
that is listed only on a CPU with AMX or AVX512-BF16 (or a GPU); the token cap and the loop retry; the
aligner with the first-word defect handled; a decision for the languages the aligner lacks
(Indonesian, where Qwen wins, would have no word times); a CPU-only torch in the lock.

## What was chosen

- **Default stays Whisper large-v3-turbo**: the most accurate or level on most languages measured, 99
  languages, 1.6 GB, and its speed does not depend on the CPU.
- **Parakeet v3 is offered as the fast model** for its 25 languages, about 2.6x faster and half the
  memory. A recording in another language goes to Whisper, and the job says so.
- Not offered: Qwen3-ASR (above), Cohere Transcribe (no better than Whisper here, 2.7 GB on disk, 2x
  real time), Canary 180M and SenseVoice (too inaccurate), Moonshine (English only).

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
load time. Granite Speech 4.1, Voxtral, Canary 1B. Qwen3-ASR through llama.cpp (ggml-org publishes
Q8_0 GGUFs of the 1.7B) or from a better int8 export than the 0.6B one, which might make it fit a CPU
without AMX. Noisy or accented speech beyond the one film, for every model.

## Reproducing

```sh
uv run scripts/asr-bench/fleurs.py large-v3-turbo,small all 20   # a faster-whisper size
uv run scripts/asr-bench/fleurs.py parakeet,qwen3-0.6b,cohere en,fr,de 20   # the sherpa-onnx int8 builds
uv run scripts/asr-bench/qwen3.py 1.7b en,fr,id 20                          # PyTorch bf16; 0.6b too, --no-hint
ONEDNN_MAX_CPU_ISA=AVX2 uv run scripts/asr-bench/qwen3.py 1.7b en 4         # a CPU without AVX-512 or AMX
```

One engine per process if the memory column matters: the peak is the process's.
