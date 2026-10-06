"""Download options: size, quality and frame rate, resolved in one place for every caller."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any
from urllib.parse import parse_qs, urlparse
from uuid import UUID

import pytest
from httpx import AsyncClient

from app.models.schemas import RenderOptions
from app.services.render_formats import (
    available_frame_rates,
    available_resolutions,
    get_format,
    resolve_render_inputs,
)
from tests.conftest import _MINIMAL_TRANSCRIPT

_TRANSCRIPT = {"schema_version": 1, "language": "en", "duration": 1.0, "segments": []}


@dataclass
class _Project:
    video_width: int | None = 3840
    video_height: int | None = 2160
    video_fps: float | None = 59.94
    transcript: Any = None
    style_config: Any = None
    caption_offset_ms: Any = 0

    def __post_init__(self) -> None:
        self.transcript = self.transcript or _TRANSCRIPT


def test_the_size_is_the_short_side_and_never_larger_than_the_source() -> None:
    p = _Project()
    out = resolve_render_inputs(p, RenderOptions(resolution="1080"))
    assert (out.width, out.height) == (1920, 1080)
    vertical = _Project(video_width=1080, video_height=1920)
    assert (resolve_render_inputs(vertical, RenderOptions(resolution="720")).width) == 720
    same = resolve_render_inputs(vertical, RenderOptions(resolution="2160"))
    assert (same.width, same.height) == (1080, 1920), "asking for more never upscales"
    odd = resolve_render_inputs(
        _Project(video_width=1001, video_height=1335), RenderOptions(resolution="720")
    )
    assert odd.width % 2 == 0 and odd.height % 2 == 0


def test_the_frame_rate_is_only_ever_lowered() -> None:
    assert resolve_render_inputs(_Project(), RenderOptions(frame_rate="30")).fps == 30
    assert resolve_render_inputs(_Project(video_fps=25), RenderOptions(frame_rate="30")).fps == 25
    assert available_frame_rates(_Project(video_fps=29.97)) == ["original", "24"]
    assert available_frame_rates(_Project(video_fps=24)) == ["original"]
    assert available_resolutions(_Project()) == ["original", "1080", "720"]
    assert available_resolutions(_Project(video_width=640, video_height=360)) == ["original"]


def test_each_codec_has_its_own_crf_per_quality_and_prores_has_none() -> None:
    mp4, webm, mov = get_format("mp4"), get_format("webm"), get_format("mov")
    assert mp4 and webm and mov
    assert mp4.crf("smaller") > mp4.crf("balanced") > mp4.crf("best")  # type: ignore[operator]
    assert webm.crf("balanced") == 28 and mp4.crf("balanced") == 18
    assert mov.crf("best") is None and not mov.has_quality


def test_every_option_changes_the_hash_except_quality_for_prores() -> None:
    p = _Project()
    base = resolve_render_inputs(p)
    hashes = {
        resolve_render_inputs(p, RenderOptions.model_validate(kw)).hash_for("mp4")
        for kw in ({}, {"resolution": "720"}, {"quality": "best"}, {"frame_rate": "24"})
    }
    assert len(hashes) == 4
    best = resolve_render_inputs(p, RenderOptions(quality="best"))
    assert best.hash_for("mov") == base.hash_for("mov"), "the same ProRes file either way"


@pytest.mark.asyncio
async def test_a_download_is_requested_and_fetched_with_its_options(
    user_a: tuple[AsyncClient, UUID], seed_project: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    from app.storage import s3
    from app.tasks import render as render_task

    sent: list[tuple[Any, ...]] = []

    class _Result:
        id = "fake-task-id"

    def delay(*args: Any) -> _Result:
        sent.append(args)
        return _Result()

    stored: set[str] = set()
    monkeypatch.setattr(s3, "object_exists", lambda key: key in stored)
    monkeypatch.setattr(render_task.render_video, "delay", delay)
    client, owner = user_a
    project_id = await seed_project(owner)  # no probed size: 1080 × 1920 at 30 fps
    base = f"/api/v1/projects/{project_id}"

    choices = (await client.get(f"{base}/exports")).json()["choices"]
    assert choices == {
        "resolutions": ["original", "720"],
        "frame_rates": ["original", "24"],
        "source_fps": None,
    }

    options = {"resolution": "720", "quality": "smaller", "frame_rate": "24"}
    r = await client.post(f"{base}/download", json={"format": "mp4", **options})
    assert r.status_code == 202, r.text
    assert sent[0][2:] == ("mp4", options), "the worker gets the options"
    again = await client.post(f"{base}/download", json={"format": "mp4", **options})
    assert again.json()["job_id"] == r.json()["job_id"], "the same output is not queued twice"
    other = await client.post(f"{base}/download", json={"format": "mp4"})
    assert other.json()["job_id"] != r.json()["job_id"], "other options are another file"

    assert (await client.get(f"{base}/download/mp4", params=options)).status_code == 404
    stored.add(resolve_render_key(project_id, options))
    ready = (await client.post(f"{base}/download", json={"format": "mp4", **options})).json()
    assert ready["ready"] is True
    query = parse_qs(urlparse(ready["download_url"]).query)
    assert {k: v[0] for k, v in query.items()} == options, "the link names the same file"
    bad = await client.post(f"{base}/download", json={"format": "mp4", "resolution": "999"})
    assert bad.status_code == 422


def resolve_render_key(project_id: UUID, options: dict[str, str]) -> str:
    """The key the seeded project's render with ``options`` is stored under."""
    seeded = _Project(
        video_width=None, video_height=None, video_fps=None, transcript=_MINIMAL_TRANSCRIPT
    )
    fmt = get_format("mp4")
    assert fmt
    return resolve_render_inputs(seeded, RenderOptions.model_validate(options)).object_key_for(
        str(project_id), fmt
    )
