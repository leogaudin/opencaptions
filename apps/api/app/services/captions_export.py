"""Caption format generators: SRT, WebVTT, and a clean JSON dump.

Used by /api/v1/projects/{id}/exports to produce in-browser downloads.
"""

from __future__ import annotations

import json

from app.models.schemas import Transcript


def to_srt(transcript: Transcript) -> str:
    """Return a SubRip (.srt) document for the given transcript.

    One cue per segment. Word timing is dropped — most players don't honor
    word-level timestamps in SRT, and the rendered MP4 already has them baked in.
    """
    lines: list[str] = []
    for i, seg in enumerate(transcript.segments, start=1):
        lines.append(str(i))
        lines.append(f"{_srt_ts(seg.start)} --> {_srt_ts(seg.end)}")
        lines.append(seg.text.strip())
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def to_vtt(transcript: Transcript) -> str:
    """Return a WebVTT (.vtt) document with word-timestamp inline tags.

    Per-word timing is encoded with `<00:00:00.000>` cue tags so players that
    support it (e.g., recent Chrome/Safari) can highlight the active word.
    """
    parts: list[str] = ["WEBVTT", ""]
    for seg in transcript.segments:
        parts.append(f"{_vtt_ts(seg.start)} --> {_vtt_ts(seg.end)}")
        # Build the line with word-timestamp tags when we have words.
        if seg.words:
            chunks: list[str] = []
            for w in seg.words:
                chunks.append(f"<{_vtt_ts(w.start)}>{w.text}")
            parts.append(" ".join(chunks))
        else:
            parts.append(seg.text.strip())
        parts.append("")
    return "\n".join(parts).rstrip() + "\n"


def to_json(transcript: Transcript) -> str:
    """Return the transcript as pretty JSON. Identical to the API JSON shape."""
    return json.dumps(transcript.model_dump(), indent=2, ensure_ascii=False) + "\n"


def _timestamp(seconds: float, millis_separator: str) -> str:
    """``HH:MM:SS`` plus milliseconds, which SRT separates with a comma and VTT a dot."""
    total_ms = max(0, round(seconds * 1000))
    seconds_part, millis = divmod(total_ms, 1000)
    minutes, secs = divmod(seconds_part, 60)
    hours, mins = divmod(minutes, 60)
    return f"{hours:02d}:{mins:02d}:{secs:02d}{millis_separator}{millis:03d}"


def _srt_ts(seconds: float) -> str:
    return _timestamp(seconds, ",")


def _vtt_ts(seconds: float) -> str:
    return _timestamp(seconds, ".")


__all__: list[str] = ["to_srt", "to_vtt", "to_json"]
