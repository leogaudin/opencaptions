"""How loud the voice is through a video, for the pulse look.

The engine's ``loudness.rs`` is the reference: the audio band-passed to the voice (250 to 3,500 Hz,
FFmpeg's second-order ``highpass`` and ``lowpass``, the filters the engine copies), its level taken
60 times a second in decibels, then ``envelope``: counted only while a word is said, against the
loudest words, with a quick rise and an eased fall. ``envelope`` is held to the engine's answers in
``apps/engine/testdata/loudness.json``.
"""

from __future__ import annotations

import base64
import logging
import math
import subprocess
from pathlib import Path

import numpy as np

from app.models.schemas import Loudness, Transcript

logger = logging.getLogger(__name__)

RATE = 60
SAMPLE_RATE = 16000
RANGE_DB = 18.0
PERCENTILE = 0.95
MARGIN_S = 0.03
RELEASE = 0.22
MEASURE_TIMEOUT_S = 30 * 60


def _frame_end(k: np.ndarray) -> np.ndarray:
    """Where frame ``k`` ends, in samples: a sixtieth of a second however the rate divides."""
    return (k + 1) * SAMPLE_RATE // RATE


def levels(audio_path: Path) -> list[float]:
    """The voice band's level of every sixtieth of a second, in decibels."""
    cmd = [
        "ffmpeg",
        "-loglevel",
        "error",
        "-i",
        str(audio_path),
        "-af",
        "highpass=f=250,lowpass=f=3500",
        "-ac",
        "1",
        "-ar",
        str(SAMPLE_RATE),
        "-f",
        "f32le",
        "pipe:1",
    ]
    out: list[float] = []
    carry = np.zeros(0, dtype=np.float64)
    taken = 0  # samples before `carry`
    with subprocess.Popen(cmd, stdout=subprocess.PIPE) as proc:
        assert proc.stdout is not None
        while chunk := proc.stdout.read(SAMPLE_RATE * 4 * 30):
            usable = len(chunk) // 4 * 4
            carry = np.concatenate([carry, np.frombuffer(chunk[:usable], "<f4").astype(np.float64)])
            k = np.arange(len(out), len(out) + len(carry) // (SAMPLE_RATE // RATE) + 2)
            ends = _frame_end(k) - taken
            ends = ends[ends <= len(carry)]
            if len(ends) == 0:
                continue
            starts = np.concatenate([[0], ends[:-1]])
            sq = carry * carry
            sums = np.add.reduceat(sq, starts)[: len(ends)]
            out.extend((10.0 * np.log10(sums / (ends - starts) + 1e-10)).tolist())
            taken += int(ends[-1])
            carry = carry[int(ends[-1]) :]
        proc.wait(timeout=MEASURE_TIMEOUT_S)
        if proc.returncode != 0:
            raise RuntimeError(f"ffmpeg exited {proc.returncode} measuring the audio")
    if len(carry):
        out.append(10.0 * math.log10(float(np.mean(carry * carry)) + 1e-10))
    return out


def envelope(levels: list[float], words: list[tuple[float, float]]) -> list[int]:
    """The levels made the voice's loudness for the words: 0 to 255 a frame (the engine's rule)."""
    spans = sorted((s - MARGIN_S, e + MARGIN_S) for s, e in words)
    inside: list[bool] = []
    nxt = 0
    for k in range(len(levels)):
        t = (k + 0.5) / RATE
        while nxt < len(spans) and spans[nxt][1] < t:
            nxt += 1
        hit = False
        for s, e in spans[nxt:]:
            if s > t:
                break
            if e >= t:
                hit = True
                break
        inside.append(hit)
    said = sorted(lv for lv, i in zip(levels, inside, strict=True) if i)
    if not said:
        return [0] * len(levels)
    loud = said[math.floor(PERCENTILE * (len(said) - 1))]
    floor = loud - RANGE_DB
    held = 0.0
    values = []
    for lv, i in zip(levels, inside, strict=True):
        level = min(1.0, max(0.0, (lv - floor) / RANGE_DB)) if i else 0.0
        held = level if level > held else held + (level - held) * RELEASE
        values.append(math.floor(held * 255.0 + 0.5))
    return values


def measure(audio_path: Path, transcript: Transcript) -> Loudness:
    """The transcript's loudness, from the audio it was transcribed from."""
    words = [(w.start, w.end) for seg in transcript.segments for w in seg.words]
    values = envelope(levels(audio_path), words)
    return Loudness(rate=RATE, values=base64.b64encode(bytes(values)).decode())


def with_loudness(audio_path: Path, transcript: Transcript) -> Transcript:
    """The transcript with its loudness, or as it was if the audio cannot be measured: the pulse
    look then swells on the words' timing alone, and nothing else needs it."""
    try:
        return transcript.model_copy(update={"loudness": measure(audio_path, transcript)})
    except Exception:
        logger.exception("could not measure the loudness of %s", audio_path)
        return transcript
