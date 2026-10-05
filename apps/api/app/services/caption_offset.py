"""Global caption timing offset.

One alignment nudge applied to every caption timing, positive to delay. Applied
to a COPY, and an offset of 0 returns the SAME object — the render hash depends
on transcript bytes, so a no-op offset must not invalidate a cached render.
"""

from __future__ import annotations

from typing import Any

# Modest range that covers real alignment drift while rejecting nonsensical
# values. Human-perceptible A/V desync from a smaller/faster Whisper model is
# well under a second in practice; +/-2s comfortably covers even bad drift.
CAPTION_OFFSET_MIN_MS = -2000
CAPTION_OFFSET_MAX_MS = 2000


def clamp_caption_offset_ms(offset_ms: int) -> int:
    """Clamp an offset to the supported range."""
    return max(CAPTION_OFFSET_MIN_MS, min(CAPTION_OFFSET_MAX_MS, offset_ms))


def apply_caption_offset(transcript: dict[str, Any], offset_ms: int) -> dict[str, Any]:
    """Return a copy with every start/end shifted, clamped at zero.

    An offset of 0 returns the original object unchanged.
    """
    if offset_ms == 0:
        return transcript

    shift = offset_ms / 1000.0

    def _shift(value: float) -> float:
        return max(0.0, value + shift)

    segments: list[dict[str, Any]] = []
    for seg in transcript.get("segments", []):
        words = [
            {**word, "start": _shift(word["start"]), "end": _shift(word["end"])}
            for word in seg.get("words", [])
        ]
        segments.append(
            {**seg, "start": _shift(seg["start"]), "end": _shift(seg["end"]), "words": words}
        )

    return {**transcript, "segments": segments}
