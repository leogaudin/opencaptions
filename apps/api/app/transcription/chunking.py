"""Cutting audio into the pieces a model that decodes in windows can take.

Nothing is thrown away: a stretch is never skipped because a model judged it "not speech",
since that judgement fails exactly where captions matter most (shouting, or speech over a
loud music bed). Windows are cut at the quietest moment near their end so a word is not
split, and a window that comes back empty though the audio in it is not quiet is decoded
again in halves, which models that drop a whole window do not repeat.
"""

from __future__ import annotations

import wave
from collections.abc import Callable
from pathlib import Path

import numpy as np

SAMPLE_RATE = 16_000

# Loudness is judged on 50 ms frames.
_FRAME = SAMPLE_RATE // 20

# The part of a window, from its start, in which the cut is looked for: a cut near the end
# keeps windows long, a cut anywhere before it keeps the window's end intact.
_CUT_FROM = 0.6

# Below this mean level (dBFS) a window is silence for the retry's purposes. Sound this
# quiet is not worth decoding twice.
_QUIET_DB = -55.0

# The shortest piece an empty window is split into.
_MIN_RETRY_S = 4.0

Words = list[tuple[str, float, float, float]]
"""What a decode yields for a window: (text, start, end, confidence), times from its start."""


def read_wav(path: str | Path) -> np.ndarray:
    """A 16 kHz mono 16-bit WAV (what `extract_audio` writes) as float32 in [-1, 1]."""
    with wave.open(str(path), "rb") as wav:
        if wav.getframerate() != SAMPLE_RATE or wav.getnchannels() != 1 or wav.getsampwidth() != 2:
            raise ValueError("expected 16 kHz mono 16-bit PCM audio")
        pcm = np.frombuffer(wav.readframes(wav.getnframes()), dtype=np.int16)
    return pcm.astype(np.float32) / 32768.0


def frame_levels(samples: np.ndarray) -> np.ndarray:
    """The level of every 50 ms frame, in dBFS."""
    count = len(samples) // _FRAME
    if count == 0:
        return np.zeros(0, dtype=np.float64)
    frames = samples[: count * _FRAME].reshape(count, _FRAME).astype(np.float64)
    return 10.0 * np.log10((frames**2).mean(axis=1) + 1e-12)


def _quietest_cut(levels: np.ndarray, first: int, last: int) -> int:
    """The frame in [first, last) with the lowest level; the latest one if several tie."""
    span = levels[first:last]
    return first + int(len(span) - 1 - np.argmin(span[::-1]))


def windows(samples: np.ndarray, max_s: float) -> list[tuple[int, int]]:
    """Consecutive (start, end) sample ranges covering the audio, none longer than `max_s`."""
    longest = int(max_s * SAMPLE_RATE) // _FRAME
    levels = frame_levels(samples)
    total = len(samples)
    out: list[tuple[int, int]] = []
    start = 0
    while start < total:
        end_frame = start // _FRAME + longest
        if end_frame * _FRAME >= total:
            out.append((start, total))
            break
        first = start // _FRAME + max(1, int(longest * _CUT_FROM))
        cut = _quietest_cut(levels, first, end_frame) * _FRAME
        out.append((start, cut))
        start = cut
    return out


def is_quiet(samples: np.ndarray) -> bool:
    """Whether the audio is so quiet that an empty decode of it is expected."""
    levels = frame_levels(samples)
    return bool(len(levels) == 0 or levels.mean() < _QUIET_DB)


def decode_window(
    decode: Callable[[np.ndarray], Words],
    samples: np.ndarray,
    offset_s: float = 0.0,
    *,
    retry: bool = True,
) -> list[tuple[str, float, float, float]]:
    """Words for a window with times from the start of the whole audio.

    A window that yields nothing though it is not quiet is split near its middle (at the
    quietest point) and each half decoded alone, down to `_MIN_RETRY_S`.
    """
    words = [
        (text, offset_s + start, offset_s + end, confidence)
        for text, start, end, confidence in decode(samples)
    ]
    if words or not retry or len(samples) < 2 * _MIN_RETRY_S * SAMPLE_RATE or is_quiet(samples):
        return words
    levels = frame_levels(samples)
    middle = len(levels) // 2
    spread = max(1, len(levels) // 5)
    cut = _quietest_cut(levels, middle - spread, middle + spread) * _FRAME
    return decode_window(decode, samples[:cut], offset_s) + decode_window(
        decode, samples[cut:], offset_s + cut / SAMPLE_RATE
    )
