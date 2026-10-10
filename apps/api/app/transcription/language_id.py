"""Which language a recording is in, for the models that cannot say.

Whisper names the language itself. A model that does not (Parakeet) is asked about a
language only after this has answered, so it is never handed speech it was not trained on.
"""

from __future__ import annotations

import logging
from threading import Lock
from typing import Any

import numpy as np

from app.transcription.chunking import SAMPLE_RATE

logger = logging.getLogger(__name__)

# Small enough to load in a second and to fetch in seconds; language identification is the
# easy part of what Whisper does.
LID_MODEL = "base"

# Whisper judges 30 seconds at a time. Judge a few spread through the recording, not the
# first minute, which is often music or a title card.
_WINDOW_S = 30
_WINDOWS = 3

_lock = Lock()
_model: Any | None = None


def _load(model_dir: str) -> Any:
    global _model
    with _lock:
        if _model is None:
            from faster_whisper import WhisperModel

            _model = WhisperModel(
                LID_MODEL, device="cpu", compute_type="int8", download_root=model_dir
            )
        return _model


def sampled_windows(samples: np.ndarray, count: int = _WINDOWS) -> list[np.ndarray]:
    """The audio itself if it is short, else `count` 30 s windows spread evenly through it."""
    size = _WINDOW_S * SAMPLE_RATE
    if len(samples) <= size:
        return [samples]
    centres = [len(samples) * (2 * i + 1) // (2 * count) for i in range(count)]
    return [samples[max(0, c - size // 2) : max(0, c - size // 2) + size] for c in centres]


def detect(samples: np.ndarray, model_dir: str) -> tuple[str, float] | None:
    """The most likely language and its probability, or None if nothing could be heard."""
    model = _load(model_dir)
    totals: dict[str, float] = {}
    windows = sampled_windows(samples)
    for window in windows:
        _, _, probs = model.detect_language(audio=window)
        for code, p in probs:
            totals[code] = totals.get(code, 0.0) + float(p)
    if not totals:
        return None
    code = max(totals, key=lambda c: totals[c])
    logger.info(
        "language identified as %s (%.2f over %d window(s))",
        code,
        totals[code] / len(windows),
        len(windows),
    )
    return code, totals[code] / len(windows)
