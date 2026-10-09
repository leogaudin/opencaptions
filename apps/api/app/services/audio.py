"""Audio extraction via ffmpeg.

Extracts a 16 kHz mono WAV optimized for Whisper input.
"""

from __future__ import annotations

import logging
import subprocess
from pathlib import Path
from typing import Any, TypedDict

logger = logging.getLogger(__name__)

# A file that makes a tool hang must not hold a worker for good. Probing reads headers; a
# long video's audio is extracted in a minute or two, so these are loose bounds.
PROBE_TIMEOUT_S = 60
EXTRACT_TIMEOUT_S = 30 * 60


class VideoMetadata(TypedDict):
    """Typed container for ffprobe video metadata.

    All values are optional (None) because ffprobe may not be able to extract
    every field from every container/codec combination.
    """

    width: int | None
    height: int | None
    fps: float | None
    duration: float | None


class AudioExtractionError(Exception):
    """ffmpeg returned a non-zero exit code."""


def extract_audio(
    video_path: str | Path, output_path: str | Path, *, sample_rate: int = 16000
) -> Path:
    """Extract mono 16 kHz WAV from a video file.

    Uses subprocess directly (not ffmpeg-python) for clearer error handling and
    fewer dependencies in the runtime path.
    """
    video_path = Path(video_path)
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    cmd = [
        "ffmpeg",
        "-y",
        "-loglevel",
        "warning",
        "-i",
        str(video_path),
        "-vn",  # no video
        "-acodec",
        "pcm_s16le",  # 16-bit PCM
        "-ar",
        str(sample_rate),
        "-ac",
        "1",  # mono
        str(output_path),
    ]
    logger.info("ffmpeg extract: %s -> %s", video_path.name, output_path.name)
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, check=True, timeout=EXTRACT_TIMEOUT_S
        )
    except FileNotFoundError as e:
        raise AudioExtractionError(
            "ffmpeg binary not found in PATH. Install ffmpeg in the worker image."
        ) from e
    except subprocess.TimeoutExpired as e:
        raise AudioExtractionError(f"ffmpeg took longer than {EXTRACT_TIMEOUT_S} s") from e
    except subprocess.CalledProcessError as e:
        raise AudioExtractionError(
            f"ffmpeg failed (exit {e.returncode}): {e.stderr.strip()[:500]}"
        ) from e

    if result.stderr:
        logger.debug("ffmpeg stderr: %s", result.stderr.strip())
    return output_path


def probe_duration(video_path: str | Path) -> float:
    """Return media duration in seconds via ffprobe."""
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        str(video_path),
    ]
    try:
        out = subprocess.check_output(cmd, text=True, timeout=PROBE_TIMEOUT_S).strip()
        return float(out)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError):
        return 0.0


def _display_rotation(stream: dict[str, Any]) -> int:
    """Rotation a player applies before showing the frames, in degrees.

    A phone records portrait video as landscape frames plus a rotation, so the
    stored dimensions are not the displayed ones. The rotation lives in a Display
    Matrix side-data entry on modern files and in a ``rotate`` tag on older ones;
    read both, since a user's library spans years.
    """
    for entry in stream.get("side_data_list") or []:
        if entry.get("side_data_type") == "Display Matrix":
            value = _to_float(entry.get("rotation"))
            if value is not None:
                return int(value) % 360
    tag = _to_float((stream.get("tags") or {}).get("rotate"))
    return int(tag) % 360 if tag is not None else 0


def probe_video_metadata(video_path: str | Path) -> VideoMetadata:
    """Return source-video metadata via ffprobe, as it will be displayed.

    Keys: width (int|None), height (int|None), fps (float|None), duration (float|None).
    Any missing field is None, the caller should accept partial data.
    """
    import json as _json

    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-print_format",
        "json",
        "-show_streams",
        "-show_format",
        "-select_streams",
        "v:0",
        str(video_path),
    ]
    try:
        raw = subprocess.check_output(cmd, text=True, timeout=PROBE_TIMEOUT_S)
        data = _json.loads(raw)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError):
        return {"width": None, "height": None, "fps": None, "duration": None}

    streams = data.get("streams") or []
    fmt = data.get("format") or {}
    s0 = streams[0] if streams else {}

    width = _to_int(s0.get("width"))
    height = _to_int(s0.get("height"))
    # A quarter-turn swaps the axes. Report what will be on screen, because these
    # dimensions drive the preview, the render geometry and the render hash, and
    # getting them from the stream alone shows a portrait phone clip as landscape.
    if _display_rotation(s0) in {90, 270}:
        width, height = height, width
    fps = _parse_rate(s0.get("avg_frame_rate")) or _parse_rate(s0.get("r_frame_rate"))
    duration = _to_float(s0.get("duration")) or _to_float(fmt.get("duration"))

    return {"width": width, "height": height, "fps": fps, "duration": duration}


def _to_int(v: str | int | float | None) -> int | None:
    try:
        return int(v) if v is not None else None
    except (TypeError, ValueError):
        return None


def _to_float(v: str | int | float | None) -> float | None:
    try:
        return float(v) if v is not None else None
    except (TypeError, ValueError):
        return None


def _parse_rate(rate: object) -> float | None:
    """Parse ffprobe rates like '30/1', '30000/1001', '24', or None."""
    if not rate:
        return None
    s = str(rate)
    if "/" in s:
        num, _, denom = s.partition("/")
        try:
            n = float(num)
            d = float(denom)
            if d <= 0:
                return None
            return n / d
        except ValueError:
            return None
    try:
        f = float(s)
        return f if f > 0 else None
    except ValueError:
        return None
