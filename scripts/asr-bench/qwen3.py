#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "transformers>=5.13",
#   "torch>=2.8",
#   "huggingface-hub>=1.0",
#   "numpy>=2",
#   "pyarrow",
#   "soundfile",
# ]
# ///
"""Qwen3-ASR (0.6B or 1.7B, PyTorch on the CPU) on the same FLEURS clips and scoring as fleurs.py.

    uv run scripts/asr-bench/qwen3.py 1.7b                     # every language, 20 clips, bf16
    uv run scripts/asr-bench/qwen3.py 0.6b en,fr,pl 20 --no-hint
    uv run scripts/asr-bench/qwen3.py 1.7b en 4 --fp32

It is a separate script because it needs PyTorch (about 3 GB with the CUDA wheels PyPI serves), which
the sherpa-onnx and faster-whisper engines of fleurs.py do not. By default the clip's language is given
to the model, which is what the server does once it has identified the language; `--no-hint` lets the
model find it. bf16 is fast only on a CPU with AMX or AVX512-BF16: on plain AVX2 it is slower than real
time (try it with ONEDNN_MAX_CPU_ISA=AVX2).
"""

from __future__ import annotations

import argparse
import resource
import sys
import time

from fleurs import CHARACTER_SCORED, LANGS, SR, clips, edits, normalise

NAMES = {
    "en": "English", "fr": "French", "de": "German", "es": "Spanish", "it": "Italian", "pt": "Portuguese",
    "pl": "Polish", "ru": "Russian", "tr": "Turkish", "id": "Indonesian", "ja": "Japanese", "ko": "Korean",
    "zh": "Chinese",
}  # fmt: skip


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("size", choices=["0.6b", "1.7b"])
    parser.add_argument("languages", nargs="?", default="all", help="comma-separated codes, or all")
    parser.add_argument("count", nargs="?", type=int, default=20, help="clips per language")
    parser.add_argument("--no-hint", action="store_true", help="do not tell the model the language")
    parser.add_argument("--fp32", action="store_true", help="float32 instead of bfloat16 (twice the memory)")
    parser.add_argument("--threads", type=int, default=4)
    args = parser.parse_args()

    import torch
    from transformers import AutoModelForMultimodalLM, AutoProcessor

    torch.set_num_threads(args.threads)
    repo = f"Qwen/Qwen3-ASR-{args.size.upper()}-hf"
    started = time.time()
    processor = AutoProcessor.from_pretrained(repo)
    model = AutoModelForMultimodalLM.from_pretrained(
        repo, dtype=torch.float32 if args.fp32 else torch.bfloat16
    ).eval()
    load = time.time() - started

    def decode(audio, lang: str) -> str:
        hint = {} if args.no_hint else {"language": NAMES[lang]}
        inputs = processor.apply_transcription_request(audio=audio, **hint).to(model.device, model.dtype)
        with torch.inference_mode():
            out = model.generate(**inputs, max_new_tokens=400, do_sample=False)
        return processor.decode(out[:, inputs["input_ids"].shape[1]:], return_format="transcription_only")[0]

    wanted = list(LANGS) if args.languages == "all" else args.languages.split(",")
    total_audio = total_decode = 0.0
    for lang in wanted:
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
        print(f"qwen3-asr-{args.size:5s} {lang}: {100.0 * errors / max(1, units):5.1f}% "
              f"{'CER' if lang in CHARACTER_SCORED else 'WER'}", flush=True)
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss // (1024 * (1024 if sys.platform == "darwin" else 1))
    print(f"qwen3-asr-{args.size}: load {load:.1f}s  {total_audio / max(total_decode, 1e-9):.1f}x real time  peak {rss} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
