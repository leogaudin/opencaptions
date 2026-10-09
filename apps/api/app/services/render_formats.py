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

from app.models.schemas import RenderOptions, StyleConfig

logger = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class RenderFormat:
    """Immutable descriptor for a supported output format."""

    id: str
    label: str
    codec: str
    extension: str
    mime: str
    # There is no quality choice: a download is a second encoding of the source, so it
    # is made as good as each codec does well, and its size is chosen with the
    # resolution and frame rate. The scale differs per codec; ProRes takes a profile.
    crf: int | None
    pro_res_profile: str | None
    note: str | None


# === Format Registry ===
# The complete set of export formats.
# Do not hardcode codec/crf/extension at call sites, always go through this registry.

FORMATS: dict[str, RenderFormat] = {}

_FORMAT_DEFS: list[RenderFormat] = [
    RenderFormat(
        id="mp4",
        label="MP4 (H.264)",
        codec="h264",
        extension=".mp4",
        mime="video/mp4",
        crf=15,
        pro_res_profile=None,
        note=None,
    ),
    RenderFormat(
        id="mp4-hevc",
        label="MP4 (H.265)",
        codec="h265",
        extension=".mp4",
        mime="video/mp4",
        crf=20,
        pro_res_profile=None,
        note=None,
    ),
    RenderFormat(
        id="webm",
        label="WebM (VP9)",
        codec="vp9",
        extension=".webm",
        mime="video/webm",
        crf=24,
        pro_res_profile=None,
        note="VP9 encoding is very slow, expect 5-10x real-time on a modern CPU.",
    ),
    RenderFormat(
        id="mov",
        label="MOV (ProRes)",
        codec="prores",
        extension=".mov",
        mime="video/quicktime",
        # ProRes does NOT accept crf, quality is controlled by proResProfile.
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
    caption_offset_ms: int,
    format_id: str,
    width: int,
    height: int,
    fps: int,
    green_screen: bool = False,
) -> str:
    """Digest of every render-affecting input, as 16 hex characters.

    Keys are sorted so the digest is stable across dict ordering; changing that
    invalidates every cached render. The format's encoder settings are part of it,
    so a changed CRF makes a new file rather than serving a stale one.
    """
    fmt = get_format(format_id)
    encoder = {"crf": fmt.crf, "pro_res_profile": fmt.pro_res_profile} if fmt else {}
    canonical = json.dumps(
        {
            "transcript": transcript,
            "style_config": style_config,
            "caption_offset_ms": caption_offset_ms,
            "format_id": format_id,
            "width": width,
            "height": height,
            "fps": fps,
            "green_screen": green_screen,
            "encoder": encoder,
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
    caption_offset_ms: int
    width: int
    height: int
    fps: int
    green_screen: bool = False

    def hash_for(self, format_id: str) -> str:
        return compute_render_hash(
            transcript=self.transcript,
            style_config=self.style_config,
            caption_offset_ms=self.caption_offset_ms,
            format_id=format_id,
            width=self.width,
            height=self.height,
            fps=self.fps,
            green_screen=self.green_screen,
        )

    def object_key_for(self, project_id: str, fmt: RenderFormat) -> str:
        return render_object_key(project_id, self.hash_for(fmt.id), fmt.extension)


_SHORT_SIDES = {"2160": 2160, "1080": 1080, "720": 720}
_FRAME_RATES = {"30": 30.0, "60": 60.0}


def _source_geometry(project: RenderableProject) -> tuple[int, int, float]:
    width = int(project.video_width) if project.video_width else DEFAULT_WIDTH
    height = int(project.video_height) if project.video_height else DEFAULT_HEIGHT
    fps = float(project.video_fps) if project.video_fps else float(DEFAULT_FPS)
    return width, height, max(_MIN_FPS, min(_MAX_FPS, fps))


def available_resolutions(project: RenderableProject) -> list[str]:
    """The sizes a project can be saved at: its own, and every other, larger ones too."""
    width, height, _ = _source_geometry(project)
    short = min(width, height)
    return ["original"] + [r for r, side in _SHORT_SIDES.items() if side != short]


def available_frame_rates(project: RenderableProject) -> list[str]:
    """Its own frame rate, and the others. A higher one repeats frames but draws the captions
    at each, so their animation is smoother; a lower one drops frames."""
    _, _, fps = _source_geometry(project)
    return ["original"] + [r for r, value in _FRAME_RATES.items() if abs(value - fps) > 0.5]


def _even(value: float) -> int:
    # Encoders need even dimensions in 4:2:0.
    return max(2, int(round(value)) & ~1)


def resolve_render_inputs(
    project: RenderableProject, options: RenderOptions | None = None
) -> RenderInputs:
    """Hash inputs for a project, saved with ``options``.

    The transcript stays as stored and the caption offset travels beside it: the
    engine applies the offset, so its draw and the hash see the same two inputs.
    The size and frame rate are those of the output. Either may be above the source's: the
    picture is scaled up, or its frames repeated while the captions are drawn at the higher rate.
    """
    options = options or RenderOptions()
    width, height, fps = _source_geometry(project)
    target = _SHORT_SIDES.get(options.resolution)
    if target and target != min(width, height):
        scale = target / min(width, height)
        width, height = _even(width * scale), _even(height * scale)
    fps = _FRAME_RATES.get(options.frame_rate, fps)

    style_config = (
        dict(project.style_config) if project.style_config else StyleConfig().model_dump()
    )

    return RenderInputs(
        transcript=dict(project.transcript),
        style_config=style_config,
        caption_offset_ms=int(project.caption_offset_ms or 0),
        width=width,
        height=height,
        fps=int(round(fps)),
        green_screen=options.green_screen,
    )
