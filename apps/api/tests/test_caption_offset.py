"""Tests for the global caption timing offset.

Covers the three things the offset must guarantee:
  1. The pure transform shifts/clamps correctly and is byte-identical at 0.
  2. The content-addressed render cache key changes with the offset (so a
     changed offset never serves a stale render) and is unchanged at 0.
  3. The offset reaches the actual engine request body + output key, and the
     API round-trips + range-validates the field.
"""

from __future__ import annotations

import copy
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.models import Base, Job, Project, User
from app.models.schemas import StyleConfig
from app.services.caption_offset import (
    CAPTION_OFFSET_MAX_MS,
    CAPTION_OFFSET_MIN_MS,
    apply_caption_offset,
    clamp_caption_offset_ms,
)
from app.services.render_backend import RenderResult
from app.services.render_formats import compute_render_hash

_TRANSCRIPT: dict[str, Any] = {
    "schema_version": 1,
    "language": "fr",
    "language_detection": "auto",
    "duration": 5.0,
    "segments": [
        {
            "id": "s1",
            "words": [
                {"text": "bonjour", "start": 1.0, "end": 1.5, "confidence": 1.0},
                {"text": "monde", "start": 1.5, "end": 2.0, "confidence": 1.0},
            ],
            "start": 1.0,
            "end": 2.0,
            "text": "bonjour monde",
        }
    ],
}


# 1. Pure transform


class TestApplyCaptionOffset:
    def test_zero_offset_returns_same_object(self) -> None:
        """offset 0 is the identity — same object, so hashing is byte-identical."""
        assert apply_caption_offset(_TRANSCRIPT, 0) is _TRANSCRIPT

    def test_positive_offset_delays_captions(self) -> None:
        shifted = apply_caption_offset(_TRANSCRIPT, 1000)
        w0, w1 = shifted["segments"][0]["words"]
        assert (w0["start"], w0["end"]) == (2.0, 2.5)
        assert (w1["start"], w1["end"]) == (2.5, 3.0)
        assert shifted["segments"][0]["start"] == 2.0
        assert shifted["segments"][0]["end"] == 3.0

    def test_negative_offset_advances_and_clamps_at_zero(self) -> None:
        shifted = apply_caption_offset(_TRANSCRIPT, -1200)
        w0 = shifted["segments"][0]["words"][0]
        # 1.0 - 1.2 = -0.2 -> clamped to 0.0
        assert w0["start"] == 0.0
        # 1.5 - 1.2 = 0.3 (not clamped)
        assert w0["end"] == pytest.approx(0.3)

    def test_duration_and_text_preserved(self) -> None:
        shifted = apply_caption_offset(_TRANSCRIPT, 500)
        assert shifted["duration"] == 5.0
        assert shifted["language"] == "fr"
        assert shifted["segments"][0]["text"] == "bonjour monde"
        assert shifted["segments"][0]["words"][0]["text"] == "bonjour"

    def test_input_not_mutated(self) -> None:
        before = copy.deepcopy(_TRANSCRIPT)
        apply_caption_offset(_TRANSCRIPT, 1000)
        assert before == _TRANSCRIPT

    def test_clamp_range(self) -> None:
        assert clamp_caption_offset_ms(9999) == CAPTION_OFFSET_MAX_MS
        assert clamp_caption_offset_ms(-9999) == CAPTION_OFFSET_MIN_MS
        assert clamp_caption_offset_ms(250) == 250


# 2. Cache key invalidation


class TestOffsetChangesRenderHash:
    _STYLE = StyleConfig().model_dump()

    def _hash(self, offset_ms: int) -> str:
        return compute_render_hash(
            transcript=apply_caption_offset(_TRANSCRIPT, offset_ms),
            style_config=self._STYLE,
            format_id="mp4",
            width=1080,
            height=1920,
            fps=30,
        )

    def test_zero_offset_matches_unshifted_hash(self) -> None:
        """offset 0 must produce the SAME hash as no offset at all, so existing
        cached renders stay valid and 'reset to 0' serves the original."""
        baseline = compute_render_hash(
            transcript=_TRANSCRIPT,
            style_config=self._STYLE,
            format_id="mp4",
            width=1080,
            height=1920,
            fps=30,
        )
        assert self._hash(0) == baseline

    def test_nonzero_offset_changes_hash(self) -> None:
        assert self._hash(1000) != self._hash(0)

    def test_distinct_offsets_distinct_hashes(self) -> None:
        assert self._hash(1000) != self._hash(-1000)
        assert self._hash(500) != self._hash(1000)


# 3a. Offset reaches the engine request body + output key


def _run_render_video(monkeypatch: pytest.MonkeyPatch, offset_ms: int) -> dict[str, Any]:
    """Run render_video against an in-memory SQLite DB with all I/O stubbed, and
    return the JSON body POSTed to the engine."""
    from app.tasks import render as render_task

    engine = create_engine(
        "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool
    )
    Base.metadata.create_all(engine)
    factory = sessionmaker(engine, expire_on_commit=False)

    with factory() as s:
        owner = User(email="o@example.com", password_hash="x", is_active=True)
        s.add(owner)
        s.flush()
        proj = Project(
            title="fr",
            owner_id=owner.id,
            status="transcribed",
            video_storage_key="projects/x/source.mp4",
            transcript=copy.deepcopy(_TRANSCRIPT),
            style_config=None,
            video_width=1080,
            video_height=1920,
            video_fps=30.0,
            video_duration=5.0,
            caption_offset_ms=offset_ms,
        )
        s.add(proj)
        s.flush()
        job = Job(project_id=proj.id, type="rendering", status="pending")
        s.add(job)
        s.commit()
        pid, jid = str(proj.id), str(job.id)

    captured: dict[str, Any] = {}

    class _FakeBackend:
        """Captures the request the task hands the backend, without any HTTP."""

        name = "fake"

        def render(self, request: dict[str, Any]) -> RenderResult:
            captured["body"] = request
            return RenderResult(
                output_key=request["output_key"], frames_rendered=10, duration_ms=100
            )

    monkeypatch.setattr(render_task, "_sync_session_factory", lambda: factory)
    monkeypatch.setattr(render_task, "get_backend", lambda *_a, **_k: _FakeBackend())
    monkeypatch.setattr(render_task, "mint_job_token", lambda _job_id: "tok")
    monkeypatch.setattr(render_task, "delete_job_token", lambda _job_id: None)
    monkeypatch.setattr(render_task, "_font_url", lambda _family: None)
    monkeypatch.setattr("app.api.websocket.publish_to_project", lambda *_a, **_k: None)
    monkeypatch.setattr("app.storage.s3.presigned_url", lambda _key, expires_in=3600: "http://v")
    monkeypatch.setattr("app.storage.s3.list_prefix", lambda _prefix: [])

    result = render_task.render_video.apply(args=[jid, pid, "mp4"]).get()
    assert result["status"] == "completed", result
    return captured["body"]


def test_render_request_carries_shifted_transcript(monkeypatch: pytest.MonkeyPatch) -> None:
    body = _run_render_video(monkeypatch, 1000)
    w0 = body["transcript"]["segments"][0]["words"][0]
    assert (w0["start"], w0["end"]) == (2.0, 2.5)
    assert body["transcript"]["duration"] == 5.0  # video length unchanged

    style = StyleConfig().model_dump()
    expected = compute_render_hash(
        transcript=apply_caption_offset(_TRANSCRIPT, 1000),
        style_config=style,
        format_id="mp4",
        width=1080,
        height=1920,
        fps=30,
    )
    baseline = compute_render_hash(
        transcript=_TRANSCRIPT,
        style_config=style,
        format_id="mp4",
        width=1080,
        height=1920,
        fps=30,
    )
    assert body["output_key"].endswith(f"{expected}.mp4")
    assert expected != baseline


def test_render_request_zero_offset_is_original(monkeypatch: pytest.MonkeyPatch) -> None:
    body = _run_render_video(monkeypatch, 0)
    w0 = body["transcript"]["segments"][0]["words"][0]
    assert (w0["start"], w0["end"]) == (1.0, 1.5)  # untouched

    style = StyleConfig().model_dump()
    baseline = compute_render_hash(
        transcript=_TRANSCRIPT,
        style_config=style,
        format_id="mp4",
        width=1080,
        height=1920,
        fps=30,
    )
    assert body["output_key"].endswith(f"{baseline}.mp4")


# 3b. API round-trip + validation + readiness key


@pytest.mark.asyncio
async def test_patch_persists_and_get_returns_offset(
    user_a: tuple[AsyncClient, Any],
    seed_project: Any,
) -> None:
    client, owner = user_a
    pid = await seed_project(owner)

    # Defaults to 0.
    g0 = await client.get(f"/api/v1/projects/{pid}")
    assert g0.json()["caption_offset_ms"] == 0

    r = await client.patch(f"/api/v1/projects/{pid}", json={"caption_offset_ms": 750})
    assert r.status_code == 200, r.text
    assert r.json()["caption_offset_ms"] == 750

    g1 = await client.get(f"/api/v1/projects/{pid}")
    assert g1.json()["caption_offset_ms"] == 750


@pytest.mark.asyncio
@pytest.mark.parametrize("bad", [5000, -5000])
async def test_patch_rejects_out_of_range_offset(
    user_a: tuple[AsyncClient, Any],
    seed_project: Any,
    bad: int,
) -> None:
    client, owner = user_a
    pid = await seed_project(owner)
    r = await client.patch(f"/api/v1/projects/{pid}", json={"caption_offset_ms": bad})
    assert r.status_code == 422


@pytest.mark.asyncio
async def test_offset_changes_export_readiness_key(
    user_a: tuple[AsyncClient, Any],
    seed_project: Any,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Every format's content-addressed readiness key must change with the
    offset — proving the offset reaches the readiness/cache path, not just the
    render task."""
    from app.storage import s3

    client, owner = user_a
    pid = await seed_project(owner)

    seen: list[str] = []

    def _record(key: str) -> bool:
        seen.append(key)
        return False

    monkeypatch.setattr(s3, "object_exists", _record)

    await client.get(f"/api/v1/projects/{pid}/exports")
    keys_at_zero = set(seen)
    seen.clear()

    await client.patch(f"/api/v1/projects/{pid}", json={"caption_offset_ms": 1000})
    await client.get(f"/api/v1/projects/{pid}/exports")
    keys_at_offset = set(seen)

    assert keys_at_zero and keys_at_offset
    assert keys_at_zero.isdisjoint(keys_at_offset)
