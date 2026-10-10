"""SherpaProvider: speech models other than Whisper, run with sherpa-onnx on the CPU.

The model sits behind `Recognizer`, which turns a window of audio into timed words. This
provider owns what every such model needs: fetching its files, cutting the audio into
windows (`chunking`), decoding them again when one comes back empty though it is not quiet,
and turning the words into a `Transcript`.
"""

from __future__ import annotations

import logging
import math
import os
from threading import Lock
from typing import Any
from uuid import uuid4

import numpy as np

from app.core.config import settings
from app.models.schemas import Transcript, TranscriptSegment, Word
from app.services import asr_models
from app.transcription.base import ProgressCallback, TranscriptionProvider, register
from app.transcription.chunking import SAMPLE_RATE, Words, decode_window, read_wav, windows

logger = logging.getLogger(__name__)

# The longest window handed to a model. The models here are happy well beyond it; shorter
# windows keep an empty or garbled one cheap to decode again.
WINDOW_S = 20.0

_SENTENCE_END = (".", "?", "!", "…", "。", "？", "！")


def model_dir() -> str:
    """Where model files are cached; shared with faster-whisper."""
    return "/models"


def threads() -> int:
    """Threads for a decode: the setting, else every core this process may run on."""
    if settings.asr_threads > 0:
        return settings.asr_threads
    try:
        return len(os.sched_getaffinity(0))
    except AttributeError:  # not Linux
        return os.cpu_count() or 1


def words_from_tokens(
    tokens: list[str], starts: list[float], durations: list[float], log_probs: list[float]
) -> Words:
    """SentencePiece tokens (a leading space starts a word) grouped into timed words."""
    words: list[list[Any]] = []  # [text, start, end, [log prob, ...]]
    for index, token in enumerate(tokens):
        start = float(starts[index])
        end = start + (float(durations[index]) if index < len(durations) else 0.0)
        log_prob = float(log_probs[index]) if index < len(log_probs) else 0.0
        if token.startswith(" ") or not words:
            words.append([token.strip(), start, end, [log_prob]])
        else:
            words[-1][0] += token
            words[-1][2] = end
            words[-1][3].append(log_prob)
    out: Words = []
    for text, start, end, probs in words:
        if not text:
            continue
        confidence = math.exp(sum(probs) / len(probs)) if probs else 1.0
        out.append((text, start, max(end, start), min(1.0, max(0.0, confidence))))
    return out


def segments_from_words(words: list[Word]) -> list[TranscriptSegment]:
    """Segments that end at a sentence's end; the rest of the words form the last one."""
    segments: list[TranscriptSegment] = []
    current: list[Word] = []
    for word in words:
        current.append(word)
        if word.text.endswith(_SENTENCE_END):
            segments.append(_segment(current))
            current = []
    if current:
        segments.append(_segment(current))
    return segments


def _segment(words: list[Word]) -> TranscriptSegment:
    return TranscriptSegment(
        id=str(uuid4()),
        words=words,
        start=words[0].start,
        end=words[-1].end,
        text=" ".join(w.text for w in words).strip(),
    )


def _snapshot(model: asr_models.AsrModelInfo, *, local_only: bool) -> str:
    from huggingface_hub import snapshot_download

    assert model.repo is not None
    return snapshot_download(
        model.repo,
        cache_dir=model_dir(),
        local_files_only=local_only,
        allow_patterns=["*.onnx", "tokens.txt"],
    )


class SherpaProvider(TranscriptionProvider):
    """sherpa-onnx backed local transcription for the models `asr_models` lists for it."""

    name = "sherpa-onnx"

    def __init__(self) -> None:
        self._recognizer: Any | None = None
        self._model_id: str | None = None
        self._lock = Lock()

    def _info(self, model: str | None) -> asr_models.AsrModelInfo:
        info = asr_models.find(model)
        if info is None or info.engine != "sherpa-onnx":
            raise ValueError(f"{model!r} is not a sherpa-onnx model")
        return info

    def is_model_cached(self, model: str | None = None) -> bool:
        try:
            _snapshot(self._info(model), local_only=True)
        except Exception:  # noqa: BLE001, any failure to resolve locally means not cached
            return False
        return True

    def _load(self, model: str | None) -> Any:
        info = self._info(model)
        with self._lock:
            if self._recognizer is not None and self._model_id == info.id:
                return self._recognizer
            import sherpa_onnx

            folder = _snapshot(info, local_only=False)
            logger.info("Loading %s (sherpa-onnx, %d threads)", info.id, threads())
            self._recognizer = sherpa_onnx.OfflineRecognizer.from_transducer(
                encoder=f"{folder}/encoder.int8.onnx",
                decoder=f"{folder}/decoder.int8.onnx",
                joiner=f"{folder}/joiner.int8.onnx",
                tokens=f"{folder}/tokens.txt",
                model_type="nemo_transducer",
                num_threads=threads(),
            )
            self._model_id = info.id
            return self._recognizer

    def prepare(self, model: str | None = None) -> None:
        self._load(model)

    def _decode(self, recognizer: Any, window: np.ndarray) -> Words:
        stream = recognizer.create_stream()
        stream.accept_waveform(SAMPLE_RATE, window)
        recognizer.decode_stream(stream)
        result = stream.result
        return words_from_tokens(
            list(result.tokens),
            list(result.timestamps),
            list(result.durations),
            list(result.ys_log_probs),
        )

    def transcribe(
        self,
        audio_path: str,
        *,
        language: str = "auto",
        model: str | None = None,
        on_progress: ProgressCallback | None = None,
    ) -> Transcript:
        info = self._info(model)
        recognizer = self._load(model)
        samples = read_wav(audio_path)
        duration = len(samples) / SAMPLE_RATE

        all_words: list[Word] = []
        pieces = windows(samples, WINDOW_S)
        for start, end in pieces:
            found = decode_window(
                lambda w: self._decode(recognizer, w), samples[start:end], start / SAMPLE_RATE
            )
            all_words.extend(
                Word(text=text, start=s, end=min(e, duration), confidence=c)
                for text, s, e, c in found
            )
            if on_progress:
                on_progress(
                    min(1.0, end / len(samples)),
                    f"Transcribed {end / SAMPLE_RATE:.1f}s / {duration:.1f}s",
                )

        _separate(all_words)
        logger.info(
            "transcribed %.1fs of audio with %s: %d windows, %d words, last word at %.1fs",
            duration,
            info.id,
            len(pieces),
            len(all_words),
            all_words[-1].end if all_words else 0.0,
        )
        if on_progress:
            on_progress(1.0, "Transcription complete")
        return Transcript(
            schema_version=1,
            language=language if language not in {"auto", ""} else "en",
            language_detection="auto" if language in {"auto", ""} else "manual",
            duration=duration,
            segments=segments_from_words(all_words),
        )


def _separate(words: list[Word]) -> None:
    """Make every word end before the next one starts (windows can overlap by a token)."""
    for word, following in zip(words, words[1:], strict=False):
        if word.end > following.start:
            word.end = max(word.start, following.start)


# Registered so the router can reach it by engine name; it is not a provider to pick.
register(SherpaProvider())
