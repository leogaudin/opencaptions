"""Tests for the advertised upload limits.

MAX_VIDEO_DURATION_S was surfaced by GET /settings long before anything enforced
it. These pin that it is now enforced, that the advertised value is what gets
enforced, and that an unprobeable video is still admitted rather than guessed at.
"""

from __future__ import annotations

from typing import Any
from unittest.mock import patch

import pytest
from httpx import AsyncClient

from app.core.config import settings


def _probe(duration: float | None) -> dict[str, Any]:
    return {"width": 1080, "height": 1920, "fps": 30.0, "duration": duration}


async def _upload(client: AsyncClient, title: str = "clip") -> Any:
    return await client.post(
        "/api/v1/projects",
        data={"title": title},
        files={"video": ("clip.mp4", b"not a real video", "video/mp4")},
    )


@pytest.mark.asyncio
async def test_settings_advertise_the_duration_limit(first_client: AsyncClient) -> None:
    r = await first_client.get("/api/v1/settings")
    assert r.status_code == 200
    assert r.json()["limits"]["max_video_duration_s"] == settings.max_video_duration_s


@pytest.mark.asyncio
async def test_the_list_shows_what_each_upload_weighs(first_client: AsyncClient) -> None:
    with (
        patch("app.services.audio.probe_video_metadata", return_value=_probe(5.0)),
        patch("app.storage.s3.upload_file"),
        patch("app.api.ingest.generate_and_store_thumbnail"),
    ):
        r = await _upload(first_client)
    assert r.status_code == 201, r.text
    listed = (await first_client.get("/api/v1/projects")).json()["items"]
    assert [p["video_size_bytes"] for p in listed] == [len(b"not a real video")]


@pytest.mark.asyncio
async def test_video_longer_than_the_limit_is_rejected(
    first_client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "max_video_duration_s", 60)
    with patch("app.services.audio.probe_video_metadata", return_value=_probe(61.0)):
        r = await _upload(first_client)
    assert r.status_code == 400, r.text
    assert r.json()["error"] == "video_too_long"


@pytest.mark.asyncio
async def test_video_at_the_limit_is_accepted(
    first_client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The limit is inclusive: exactly the advertised maximum is allowed."""
    monkeypatch.setattr(settings, "max_video_duration_s", 60)
    with (
        patch("app.services.audio.probe_video_metadata", return_value=_probe(60.0)),
        patch("app.storage.s3.upload_file"),
        patch("app.api.ingest.generate_and_store_thumbnail"),
    ):
        r = await _upload(first_client)
    assert r.status_code == 201, r.text


@pytest.mark.asyncio
async def test_unprobeable_video_is_admitted(
    first_client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A duration we could not measure must not be treated as over the limit."""
    monkeypatch.setattr(settings, "max_video_duration_s", 60)
    with (
        patch("app.services.audio.probe_video_metadata", side_effect=RuntimeError("no ffprobe")),
        patch("app.storage.s3.upload_file"),
        patch("app.api.ingest.generate_and_store_thumbnail"),
    ):
        r = await _upload(first_client)
    assert r.status_code == 201, r.text


@pytest.mark.asyncio
async def test_preset_endpoints_are_gone(first_client: AsyncClient) -> None:
    """The preset table was never written to; the surface was removed with it."""
    assert (await first_client.get("/api/v1/presets")).status_code == 404
