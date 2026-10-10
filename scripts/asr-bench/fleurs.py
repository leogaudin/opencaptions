#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "faster-whisper>=1.2",
#   "sherpa-onnx>=1.13.8",
#   "sherpa-onnx-core>=1.13.8",
#   "huggingface-hub>=1.0",
#   "numpy>=2",
#   "pyarrow",
#   "soundfile",
# ]
# ///
"""Word (character) error rate and speed of the local models, on Google's FLEURS test clips.

    uv run scripts/asr-bench/fleurs.py turbo               # one engine, every language, 20 clips
    uv run scripts/asr-bench/fleurs.py parakeet en,fr,de 30
    uv run scripts/asr-bench/fleurs.py turbo,small,parakeet all 20 --threads 4

An engine is a faster-whisper size (tiny, small, large-v3-turbo, ..., as `faster-whisper` names
it) or one of the sherpa-onnx models below. Each clip is decoded alone, in the language the
clip is in, so this measures recognition, not language identification. Japanese and Chinese
are scored by character, every other language by word. Text is NFKC-normalised, lowercased and
stripped of punctuation before comparing; the same on both sides for every engine.

Speed is audio seconds per second of decoding. FLEURS clips are short (about 12 s) and Whisper
always works on 30 s, so Whisper is slower here than on a long recording, where it is not
padded; read the speed column as a ranking, not as what a long video takes.
"""

from __future__ import annotations

import argparse
import io
import resource
import sys
import time
import unicodedata
from pathlib import Path

import numpy as np

SR = 16_000
CACHE = Path.home() / ".cache" / "opencaptions-asr-bench"
LANGS = {
    "en": "en_us", "fr": "fr_fr", "de": "de_de", "es": "es_419", "it": "it_it", "pt": "pt_br",
    "pl": "pl_pl", "ru": "ru_ru", "tr": "tr_tr", "id": "id_id", "ja": "ja_jp", "ko": "ko_kr",
    "zh": "cmn_hans_cn",
}  # fmt: skip
CHARACTER_SCORED = {"ja", "zh"}

# sherpa-onnx models: Hugging Face repo, the languages they cover.
SHERPA = {
    "parakeet": ("csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8",
                 {"en", "fr", "de", "es", "it", "pt", "pl", "ru"}),
    "qwen3-0.6b": ("csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25", set(LANGS)),
    "cohere": ("csukuangfj2/sherpa-onnx-cohere-transcribe-14-lang-int8-2026-04-01",
               {"en", "fr", "de", "es", "it", "pt", "pl", "ja", "ko", "zh"}),
}  # fmt: skip


def clips(code: str, count: int) -> list[tuple[np.ndarray, str]]:
    """The first `count` test clips of a language (downloaded once, then cached)."""
    import pyarrow.parquet as pq
    import soundfile as sf
    from huggingface_hub import hf_hub_download

    path = hf_hub_download("google/fleurs", f"{LANGS[code]}/test/0000.parquet",
                           repo_type="dataset", revision="refs/convert/parquet")
    out = []
    for row in pq.read_table(path).to_pylist()[:count]:
        audio, rate = sf.read(io.BytesIO(row["audio"]["bytes"]), dtype="float32")
        if audio.ndim > 1:
            audio = audio.mean(axis=1)
        if rate != SR:
            audio = np.interp(np.linspace(0, len(audio) - 1, int(len(audio) * SR / rate)),
                              np.arange(len(audio)), audio).astype("float32")
        out.append((audio, row.get("raw_transcription") or row["transcription"]))
    return out


def normalise(text: str, lang: str) -> str:
    text = unicodedata.normalize("NFKC", text).lower()
    text = "".join(" " if unicodedata.category(c)[0] in "PS" else c for c in text)
    text = " ".join(text.split())
    return text.replace(" ", "") if lang in CHARACTER_SCORED else text


def edits(ref: list[str], hyp: list[str]) -> int:
    row = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        prev, row[0] = row[:], i
        for j, h in enumerate(hyp, 1):
            row[j] = min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + (r != h))
    return row[-1]


def make_decoder(engine: str, threads: int):
    """A function (audio, language) -> text, and the languages the engine covers (None: all)."""
    if engine in SHERPA:
        import sherpa_onnx
        from huggingface_hub import snapshot_download

        repo, covers = SHERPA[engine]
        folder = snapshot_download(repo, allow_patterns=["*.onnx", "*.onnx.data", "tokens.txt", "tokenizer/*"])
        cache: dict[str, object] = {}

        def recognizer(lang: str):
            if engine == "parakeet":
                key = "all"
                if key not in cache:
                    cache[key] = sherpa_onnx.OfflineRecognizer.from_transducer(
                        encoder=f"{folder}/encoder.int8.onnx", decoder=f"{folder}/decoder.int8.onnx",
                        joiner=f"{folder}/joiner.int8.onnx", tokens=f"{folder}/tokens.txt",
                        model_type="nemo_transducer", num_threads=threads)
                return cache[key]
            if engine == "qwen3-0.6b":
                if "all" not in cache:
                    cache["all"] = sherpa_onnx.OfflineRecognizer.from_qwen3_asr(
                        conv_frontend=f"{folder}/conv_frontend.onnx", encoder=f"{folder}/encoder.int8.onnx",
                        decoder=f"{folder}/decoder.int8.onnx", tokenizer=f"{folder}/tokenizer", num_threads=threads)
                return cache["all"]
            # Cohere takes the language when it is built; keep one at a time (it is 2.7 GB).
            if lang not in cache:
                cache.clear()
                cache[lang] = sherpa_onnx.OfflineRecognizer.from_cohere_transcribe(
                    encoder=f"{folder}/encoder.int8.onnx", decoder=f"{folder}/decoder.int8.onnx",
                    tokens=f"{folder}/tokens.txt", num_threads=threads, language=lang)
            return cache[lang]

        def decode(audio: np.ndarray, lang: str) -> str:
            rec = recognizer(lang)
            stream = rec.create_stream()
            stream.accept_waveform(SR, audio)
            rec.decode_stream(stream)
            return stream.result.text

        return decode, covers

    from faster_whisper import WhisperModel

    model = WhisperModel(engine, device="cpu", compute_type="int8", cpu_threads=threads)

    def decode(audio: np.ndarray, lang: str) -> str:
        segments, _ = model.transcribe(audio, language=lang, vad_filter=False, beam_size=5,
                                       condition_on_previous_text=False)
        return " ".join(s.text for s in segments)

    return decode, None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("engine", help="comma-separated: a faster-whisper size or " + ", ".join(SHERPA))
    parser.add_argument("languages", nargs="?", default="all", help="comma-separated codes, or all")
    parser.add_argument("count", nargs="?", type=int, default=20, help="clips per language")
    parser.add_argument("--threads", type=int, default=0, help="CPU threads (0: all)")
    args = parser.parse_args()

    wanted = list(LANGS) if args.languages == "all" else args.languages.split(",")
    for engine in args.engine.split(","):
        started = time.time()
        decode, covers = make_decoder(engine, args.threads)
        load = time.time() - started
        total_audio = total_decode = 0.0
        scores = {}
        for lang in wanted:
            if covers is not None and lang not in covers:
                continue
            errors = units = 0
            for audio, reference in clips(lang, args.count):
                began = time.time()
                hypothesis = decode(audio, lang)
                total_decode += time.time() - began
                total_audio += len(audio) / SR
                ref, hyp = normalise(reference, lang), normalise(hypothesis, lang)
                ref_units, hyp_units = (list(ref), list(hyp)) if lang in CHARACTER_SCORED else (ref.split(), hyp.split())
                errors += edits(ref_units, hyp_units)
                units += len(ref_units)
            scores[lang] = 100.0 * errors / max(1, units)
            print(f"{engine:18s} {lang}: {scores[lang]:5.1f}% {'CER' if lang in CHARACTER_SCORED else 'WER'}", flush=True)
        rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss // (1024 * (1024 if sys.platform == "darwin" else 1))
        print(f"{engine:18s} load {load:.1f}s  {total_audio / max(total_decode, 1e-9):.1f}x real time  peak {rss} MB\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
