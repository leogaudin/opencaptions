"""Cutting audio into the pieces a model that decodes in windows can take.

Nothing is thrown away: a stretch is never skipped because a model judged it "not speech",
since that judgement fails exactly where captions matter most (shouting, or speech over a
loud music bed). Windows are cut at the quietest moment near their end so a word is not
split, and a window that comes back empty though the audio in it is not quiet is decoded
again in halves, which models that drop a whole window do not repeat.
"""

from __future__ import annotations

import logging
import re
import wave
from collections.abc import Callable, Sequence
from pathlib import Path

import numpy as np

logger = logging.getLogger(__name__)

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


def long_gaps(
    spans: Sequence[tuple[float, float]], duration: float, min_gap_s: float
) -> list[tuple[float, float]]:
    """Every stretch of `min_gap_s` or more, from the start to `duration`, that no (start, end) covers."""
    gaps: list[tuple[float, float]] = []
    reached = 0.0
    for start, end in sorted(spans):
        if start - reached >= min_gap_s:
            gaps.append((reached, start))
        reached = max(reached, end)
    if duration - reached >= min_gap_s:
        gaps.append((reached, duration))
    return gaps


def _same_word(text: str) -> str:
    return re.sub(r"[\W_]+", "", text.casefold())


def agreed_in_gap(
    first: Words, second: Words, start: float, end: float, tolerance_s: float = 1.5
) -> Words:
    """The words of `first` that begin in the gap `start`..`end` (a little early is allowed) and
    that `second` has too: the same word, at about the same time. Times are from the same origin
    in both. Held to `Fixtures/second-look.json` in the iOS tests, which `TranscriptGaps.kept`
    passes as well.
    """
    kept: Words = []
    for word in first:
        if not (start - 0.05 <= word[1] < end):
            continue
        text = _same_word(word[0])
        if text and any(
            _same_word(other[0]) == text and abs(other[1] - word[1]) <= tolerance_s
            for other in second
        ):
            kept.append(word)
    return kept


def second_look(
    decode: Callable[[np.ndarray], Words],
    samples: np.ndarray,
    gaps: Sequence[tuple[float, float]],
    *,
    budget_s: float | None = None,
    pad_s: float = 0.3,
    shift_s: float = 0.9,
    tolerance_s: float = 1.5,
) -> list[tuple[str, float, float, float]]:
    """Words found by looking again at stretches where a first pass found none.

    A decoder that moves on from a window ("no speech after here") never decodes what the
    window still holds, so loud stretches can come back empty though someone speaks in
    them. Each stretch that is not quiet is decoded alone, twice, the second window shifted
    a little. Real speech comes out of both; text invented over music or noise does not
    (it differs from one window to the next), so only the words both readings give, at
    about the same time, are kept. Times are from the start of the whole recording.

    `budget_s` bounds the audio examined, so a recording that is mostly gaps costs a bounded
    amount more; gaps are taken in order and the rest are left as they were.
    """
    total = len(samples) / SAMPLE_RATE
    kept: list[tuple[str, float, float, float]] = []
    examined = 0.0
    for index, (start, end) in enumerate(gaps):
        if is_quiet(samples[int(start * SAMPLE_RATE) : int(end * SAMPLE_RATE)]):
            continue
        if budget_s is not None and examined + (end - start) > budget_s:
            logger.info(
                "second look stopped at gap %d of %d (budget %.0fs)", index + 1, len(gaps), budget_s
            )
            break
        examined += end - start
        lo = max(0.0, start - pad_s)
        hi = min(total, end + pad_s)
        first = decode_window(
            decode, samples[int(lo * SAMPLE_RATE) : int(hi * SAMPLE_RATE)], lo, retry=False
        )
        if not first:
            continue
        lo2 = min(start + shift_s, max(0.0, end - 2.0))
        hi2 = min(total, end + pad_s + 1.0)
        second = decode_window(
            decode, samples[int(lo2 * SAMPLE_RATE) : int(hi2 * SAMPLE_RATE)], lo2, retry=False
        )
        kept.extend(agreed_in_gap(first, second, start, end, tolerance_s))
    return sorted(kept, key=lambda w: w[1])
