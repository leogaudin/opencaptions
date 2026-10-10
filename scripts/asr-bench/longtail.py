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
"""Whisper large-v3-turbo against Omnilingual ASR (CTC, 1B int8, sherpa-onnx) on languages Whisper does badly.

    uv run scripts/asr-bench/longtail.py                  # Swahili, Hausa, Tamil, Yoruba, Amharic; 15 clips each
    uv run scripts/asr-bench/longtail.py sw_ke,ur_pk 20   # FLEURS configuration names

Same FLEURS clips and normalisation as fleurs.py. Prints word and character error rates: for languages
written without spaces between words, or with long agglutinated words, the character rate is the fairer.
Whisper is told the language; Omnilingual needs none.
"""

from __future__ import annotations

import sys
import time

from fleurs import SR, clips, edits, normalise

DEFAULT = "sw_ke,ha_ng,ta_in,yo_ng,am_et"
OMNILINGUAL = "csukuangfj2/sherpa-onnx-omnilingual-asr-1600-languages-1B-ctc-v2-int8-2026-02-05"


def main() -> int:
    from faster_whisper import WhisperModel
    from huggingface_hub import snapshot_download
    import sherpa_onnx

    configs = (sys.argv[1] if len(sys.argv) > 1 else DEFAULT).split(",")
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 15
    whisper = WhisperModel("large-v3-turbo", device="cpu", compute_type="int8", cpu_threads=4)
    folder = snapshot_download(OMNILINGUAL, allow_patterns=["model.int8.onnx", "tokens.txt"])
    omni = sherpa_onnx.OfflineRecognizer.from_omnilingual_asr_ctc(
        model=f"{folder}/model.int8.onnx", tokens=f"{folder}/tokens.txt", num_threads=4)

    def decode_whisper(audio, language: str) -> str:
        segments, _ = whisper.transcribe(audio, language=language, vad_filter=False, beam_size=5,
                                         condition_on_previous_text=False)
        return " ".join(s.text for s in segments)

    def decode_omnilingual(audio, language: str) -> str:
        stream = omni.create_stream()
        stream.accept_waveform(SR, audio)
        omni.decode_stream(stream)
        return stream.result.text

    for config in configs:
        language = config.split("_")[0]
        data = clips(config, count)
        for name, decode in (("whisper-turbo", decode_whisper), ("omnilingual-1b", decode_omnilingual)):
            word_errors = words = char_errors = chars = 0
            seconds = spent = 0.0
            for audio, reference in data:
                began = time.time()
                hypothesis = decode(audio, language)
                spent += time.time() - began
                seconds += len(audio) / SR
                ref, hyp = normalise(reference, "xx"), normalise(hypothesis, "xx")
                word_errors += edits(ref.split(), hyp.split())
                words += len(ref.split())
                char_errors += edits(list(ref), list(hyp))
                chars += len(ref)
            print(f"{config:6s} {name:15s} WER {100 * word_errors / max(1, words):5.1f}%  "
                  f"CER {100 * char_errors / max(1, chars):5.1f}%  {seconds / max(spent, 1e-9):4.1f}x", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
