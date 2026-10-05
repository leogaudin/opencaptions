"""Format registry and content-addressed render hash.

Single source of truth for output formats. Per-codec values must not be
duplicated at a call site: CRF scales differ per codec and ProRes takes none.
Codec and container are coupled (VP9 to .webm, ProRes to .mov); the engine picks
the matching audio codec for each.
"""

from __future__ import annotations

import hashlib
import json
import logging
from dataclasses import dataclass
from typing import Any, Protocol

from app.models.schemas import StyleConfig
from app.services.caption_offset import apply_caption_offset

logger = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class RenderFormat:
    """Immutable descriptor for a supported output format."""

    id: str
    label: str
    codec: str
    extension: str
    mime: str
    crf: int | None
    pro_res_profile: str | None
    note: str | None


# === Format Registry ===
# The complete set of export formats.
# Do not hardcode codec/crf/extension at call sites — always go through this registry.

FORMATS: dict[str, RenderFormat] = {}

_FORMAT_DEFS: list[RenderFormat] = [
    RenderFormat(
        id="mp4",
        label="MP4 (H.264)",
        codec="h264",
        extension=".mp4",
        mime="video/mp4",
        crf=18,
        pro_res_profile=None,
        note=None,
    ),
    RenderFormat(
        id="mp4-hevc",
        label="MP4 (H.265)",
        codec="h265",
        extension=".mp4",
        mime="video/mp4",
        crf=23,
        pro_res_profile=None,
        note=None,
    ),
    RenderFormat(
        id="webm",
        label="WebM (VP9)",
        codec="vp9",
        extension=".webm",
        mime="video/webm",
        crf=28,
        pro_res_profile=None,
        note="VP9 encoding is very slow — expect 5-10x real-time on a modern CPU.",
    ),
    RenderFormat(
        id="mov",
        label="MOV (ProRes)",
        codec="prores",
        extension=".mov",
        mime="video/quicktime",
        # ProRes does NOT accept crf — quality is controlled by proResProfile.
        crf=None,
        pro_res_profile="hq",
        note="ProRes files are very large (~220 Mbps, roughly 1 GB per 40 seconds of video).",
    ),
]

for _fmt in _FORMAT_DEFS:
    FORMATS[_fmt.id] = _fmt


def get_format(format_id: str) -> RenderFormat | None:
    """Look up a format by id. Returns None for unknown ids."""
    return FORMATS.get(format_id)


def all_formats() -> list[RenderFormat]:
    """Return all registered formats in display order."""
    return list(FORMATS.values())


# === Content-Addressed Render Hash ===
# The hash encodes everything that affects the rendered bytes. Changing any
# input (transcript edit, style tweak, format switch, dimension change)
# produces a different hash, so the old cached object is automatically stale.
# This eliminates the need for `rendered_at` / `updated_at` comparisons.


def compute_render_hash(
    *,
    transcript: dict[str, object],
    style_config: dict[str, object],
    format_id: str,
    width: int,
    height: int,
    fps: int,
) -> str:
    """Digest of every render-affecting input, as 16 hex characters.

    Keys are sorted so the digest is stable across dict ordering; changing that
    invalidates every cached render.
    """
    canonical = json.dumps(
        {
            "transcript": transcript,
            "style_config": style_config,
            "format_id": format_id,
            "width": width,
            "height": height,
            "fps": fps,
        },
        sort_keys=True,
        separators=(",", ":"),
    )
    digest = hashlib.sha256(canonical.encode()).hexdigest()[:16]
    logger.debug("render hash: %s (format=%s, %dx%d@%dfps)", digest, format_id, width, height, fps)
    return digest


def render_object_key(project_id: str, render_hash: str, extension: str) -> str:
    """Build the content-addressed storage key for a render output.

    Pattern: projects/{project_id}/renders/{hash}{extension}
    """
    return f"projects/{project_id}/renders/{render_hash}{extension}"


# Every caller needing a render hash must derive the same geometry, style and
# offset-applied transcript, so the derivation lives here alone.

# Fallbacks for a source video whose metadata could not be probed. Vertical,
# because short-form captioned video is the common case.
DEFAULT_WIDTH = 1080
DEFAULT_HEIGHT = 1920
DEFAULT_FPS = 30

# Pathological frame rates would make a render take unbounded time.
_MIN_FPS = 1.0
_MAX_FPS = 60.0


class RenderableProject(Protocol):
    """The project fields that affect rendered bytes.

    A Protocol rather than the ORM model so this module stays free of database
    imports, and so tests can pass a plain stand-in.
    """

    transcript: Any
    style_config: Any
    caption_offset_ms: Any
    video_width: Any
    video_height: Any
    video_fps: Any


@dataclass(frozen=True, slots=True)
class RenderInputs:
    """Everything except the format that determines a render's content hash."""

    transcript: dict[str, Any]
    style_config: dict[str, Any]
    width: int
    height: int
    fps: int

    def hash_for(self, format_id: str) -> str:
        return compute_render_hash(
            transcript=self.transcript,
            style_config=self.style_config,
            format_id=format_id,
            width=self.width,
            height=self.height,
            fps=self.fps,
        )

    def object_key_for(self, project_id: str, fmt: RenderFormat) -> str:
        return render_object_key(project_id, self.hash_for(fmt.id), fmt.extension)


def resolve_render_inputs(project: RenderableProject) -> RenderInputs:
    """Hash inputs for a project, with the caption offset applied.

    The offset is applied to a copy, so changing it invalidates the cache while
    an offset of 0 leaves the transcript — and the hash — byte-identical.
    """
    fps = float(project.video_fps) if project.video_fps else float(DEFAULT_FPS)
    fps = max(_MIN_FPS, min(_MAX_FPS, fps))

    style_config = (
        dict(project.style_config) if project.style_config else StyleConfig().model_dump()
    )

    return RenderInputs(
        transcript=apply_caption_offset(
            dict(project.transcript), int(project.caption_offset_ms or 0)
        ),
        style_config=style_config,
        width=int(project.video_width) if project.video_width else DEFAULT_WIDTH,
        height=int(project.video_height) if project.video_height else DEFAULT_HEIGHT,
        fps=int(round(fps)),
    )
