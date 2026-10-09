"""Poster-frame thumbnail extraction via ffmpeg.

Extracts a single small JPEG poster frame from a source video. Uses the ffmpeg
binary already present in the image (same approach as app.services.audio), no
extra dependency, while the uploaded file is still local on disk.
"""

from __future__ import annotations

import logging
import subprocess
from pathlib import Path

from app.services.audio import PROBE_TIMEOUT_S

logger = logging.getLogger(__name__)

# Home-screen list tiles, not hero images: keep the frame small and cheap.
# Height is derived from the source aspect ratio (see the scale filter below).
THUMBNAIL_WIDTH = 320

# JPEG quality on ffmpeg's -q:v scale (2 = best/largest, 31 = worst/smallest).
# 4 is visibly clean at tile size while staying a few KB per frame.
THUMBNAIL_QUALITY = 4


class ThumbnailError(Exception):
    """ffmpeg failed to extract a poster frame."""


def _poster_timestamp(duration: float | None) -> float:
    """Choose a seek offset that avoids the frequently-black opening frame.

    Frame zero is often a black or fade-in frame, so never use it. For clips
    long enough to have one, seek ~10% in (bounded to a small cap so long
    videos still seek cheaply); for very short clips fall back to the midpoint,
    which is guaranteed to be within bounds.
    """
    if not duration or duration <= 0:
        return 1.0
    if duration <= 2.0:
        return duration / 2.0
    return min(max(duration * 0.1, 1.0), 10.0)


def extract_thumbnail(
    video_path: str | Path,
    output_path: str | Path,
    duration: float | None = None,
    *,
    width: int = THUMBNAIL_WIDTH,
) -> Path:
    """Extract a single JPEG poster frame from a video.

    Seeks to a sensible, non-zero offset (see _poster_timestamp) and writes one
    downscaled frame. Raises ThumbnailError on any ffmpeg failure or if the
    output is empty, so callers can treat thumbnailing as strictly best-effort.
    """
    video_path = Path(video_path)
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    timestamp = _poster_timestamp(duration)

    cmd = [
        "ffmpeg",
        "-y",
        "-loglevel",
        "warning",
        "-ss",
        f"{timestamp:.3f}",  # input seek (before -i), fast even on long files
        "-i",
        str(video_path),
        "-frames:v",
        "1",  # a single frame
        "-vf",
        f"scale={width}:-2",  # preserve aspect ratio, round height to even
        "-q:v",
        str(THUMBNAIL_QUALITY),
        str(output_path),
    ]
    logger.info("ffmpeg thumbnail: %s -> %s @ %.3fs", video_path.name, output_path.name, timestamp)
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, check=True, timeout=PROBE_TIMEOUT_S
        )
    except FileNotFoundError as e:
        raise ThumbnailError(
            "ffmpeg binary not found in PATH. Install ffmpeg in the API image."
        ) from e
    except subprocess.TimeoutExpired as e:
        raise ThumbnailError(f"ffmpeg took longer than {PROBE_TIMEOUT_S} s") from e
    except subprocess.CalledProcessError as e:
        raise ThumbnailError(
            f"ffmpeg failed (exit {e.returncode}): {e.stderr.strip()[:500]}"
        ) from e

    if not output_path.exists() or output_path.stat().st_size == 0:
        raise ThumbnailError("ffmpeg produced no thumbnail output")

    if result.stderr:
        logger.debug("ffmpeg stderr: %s", result.stderr.strip())
    return output_path
