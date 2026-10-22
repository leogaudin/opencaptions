"""Subtitle files, written by the engine.

A cue is a caption line as the video and the timeline show it, and the times carry the caption
offset: the engine owns both rules (`apps/engine/src/subtitles.rs`), so a file lines up with the
captions on the picture and the iPhone app writes the same one. This only asks it.
"""

from __future__ import annotations

from typing import Any, Literal

import httpx

from app.core.config import settings
from app.services.render_backend import ENGINE_URL

SubtitleFormat = Literal["srt", "vtt"]

# A file is made in milliseconds; the ceiling only stops a hung connection.
_TIMEOUT = httpx.Timeout(30.0, connect=10.0)


class EngineUnavailableError(RuntimeError):
    """The engine did not answer, or refused the request."""


async def subtitles(
    transcript: dict[str, Any],
    *,
    words_per_line: int,
    caption_offset_ms: int,
    format: SubtitleFormat,
) -> str:
    """The transcript as an SRT or VTT file, cut into `words_per_line` words a cue."""
    try:
        async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
            resp = await client.post(
                f"{ENGINE_URL}/subtitles",
                json={
                    "transcript": transcript,
                    "words_per_line": words_per_line,
                    "caption_offset_ms": caption_offset_ms,
                    "format": format,
                },
                headers={"x-engine-token": settings.engine_token},
            )
    except httpx.RequestError as e:
        raise EngineUnavailableError(f"Engine unreachable at {ENGINE_URL}: {e}") from e
    if resp.status_code != 200:
        raise EngineUnavailableError(f"Engine returned {resp.status_code}: {resp.text[:300]}")
    text = resp.json()["text"]
    assert isinstance(text, str)
    return text
