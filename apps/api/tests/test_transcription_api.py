"""The transcription API: audio in, a Transcript out, no project in between."""

from __future__ import annotations

import json
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from typing import Any
from unittest.mock import MagicMock, patch
from uuid import UUID

import pytest
from httpx import AsyncClient
from sqlalchemy import select

from app.api.transcriptions import TRANSCRIPTION_API_VERSION
from app.core.config import settings
from app.models import Job

_TRANSCRIPT = {
    "schema_version": 1,
    "language": "en",
    "language_detection": "auto",
    "duration": 1.0,
    "segments": [
        {
            "id": "s1",
            "words": [{"text": "hi", "start": 0.0, "end": 0.5, "confidence": 1.0}],
            "start": 0.0,
            "end": 0.5,
            "text": "hi",
        }
    ],
}


async def _post(c: AsyncClient, **form: str) -> Any:
    return await c.post(
        "/api/v1/transcriptions",
        data={"language": "auto", **form},
        files={"audio": ("a.m4a", b"not really audio", "audio/mp4")},
    )


@pytest.fixture
def queued() -> Any:
    """The storage, the duration probe and the queue, replaced; yields the task mock."""
    task = MagicMock()
    task.delay.return_value = MagicMock(id="celery-1")
    with (
        patch("app.api.transcriptions.s3.upload_file") as upload,
        patch("app.api.transcriptions.s3.delete_prefix"),
        patch("app.services.audio.probe_duration", return_value=30.0),
        patch("app.tasks.transcribe.transcribe_upload", task),
    ):
        task.upload = upload
        yield task


@pytest.mark.asyncio
async def test_capabilities_need_a_key_and_describe_the_instance(
    client: AsyncClient, first_client: AsyncClient
) -> None:
    assert (await client.get("/api/v1/transcription/capabilities")).status_code == 401
    r = await first_client.get("/api/v1/transcription/capabilities")
    assert r.status_code == 200
    caps = r.json()
    assert caps["api_version"] == TRANSCRIPTION_API_VERSION
    assert caps["instance_name"] == settings.instance_name
    assert caps["default_model"] == settings.whisper_model
    assert any(m["id"] == settings.whisper_model for m in caps["models"])
    assert caps["max_upload_mb"] == settings.max_upload_size_mb
    assert caps["result_ttl_h"] == settings.transcription_result_ttl_h


@pytest.mark.asyncio
async def test_hosted_mode_does_not_offer_models(
    first_client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "hosted_mode", True)
    caps = (await first_client.get("/api/v1/transcription/capabilities")).json()
    assert caps["models"] == [] and caps["default_model"] is None and caps["hosted_mode"]


@pytest.mark.asyncio
async def test_a_transcription_is_a_projectless_job_the_owner_can_follow(
    first_client: AsyncClient, user_a: tuple[AsyncClient, UUID], queued: Any, db_factory: Any
) -> None:
    r = await _post(first_client, language="fr", model="small")
    assert r.status_code == 202, r.text
    job_id = r.json()["job_id"]
    queued.upload.assert_called_once()
    args, kwargs = queued.delay.call_args
    assert args[0] == job_id and args[1] == f"transcriptions/{job_id}/audio.bin"
    assert args[2] == f"transcriptions/{job_id}/transcript.json"
    assert kwargs["language"] == "fr" and kwargs["model"] == "small"
    async with db_factory() as s:
        job = await s.get(Job, UUID(job_id))
    assert job is not None and job.project_id is None and job.user_id == user_a[1]
    status = await first_client.get(f"/api/v1/jobs/{job_id}")
    assert status.status_code == 200
    assert status.json()["project_id"] is None and status.json()["type"] == "transcription"


@pytest.mark.asyncio
async def test_another_user_cannot_see_the_job_or_its_result(
    first_client: AsyncClient, user_b_client: AsyncClient, queued: Any
) -> None:
    job_id = (await _post(first_client)).json()["job_id"]
    assert (await user_b_client.get(f"/api/v1/jobs/{job_id}")).status_code == 404
    assert (await user_b_client.get(f"/api/v1/transcriptions/{job_id}")).status_code == 404
    assert (await user_b_client.delete(f"/api/v1/transcriptions/{job_id}")).status_code == 404


@pytest.mark.asyncio
async def test_a_bad_language_a_long_clip_and_a_big_upload_are_refused(
    first_client: AsyncClient, queued: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    assert (await _post(first_client, language="klingon")).json()["error"] == "unsupported_language"
    monkeypatch.setattr(settings, "max_video_duration_s", 10)
    r = await _post(first_client)
    assert r.status_code == 400 and r.json()["error"] == "video_too_long"
    monkeypatch.setattr(settings, "max_video_duration_s", 3600)
    monkeypatch.setattr(settings, "max_upload_size_mb", 0)
    assert (await _post(first_client)).status_code == 413
    queued.delay.assert_not_called()


@pytest.mark.asyncio
async def test_only_so_many_run_at_once(
    first_client: AsyncClient, queued: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "transcription_max_concurrent", 2)
    assert (await _post(first_client)).status_code == 202
    assert (await _post(first_client)).status_code == 202
    r = await _post(first_client)
    assert r.status_code == 429 and r.json()["error"] == "too_many_transcriptions"


@pytest.mark.asyncio
async def test_an_instance_that_forwards_refuses_a_forwarded_request(
    first_client: AsyncClient, queued: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "transcription_provider", "opencaptions")
    r = await first_client.post(
        "/api/v1/transcriptions",
        data={"language": "auto"},
        files={"audio": ("a.m4a", b"x", "audio/mp4")},
        headers={"X-OpenCaptions-Hop": "1"},
    )
    assert r.status_code == 508 and r.json()["error"] == "transcription_loop"
    assert (await _post(first_client)).status_code == 202, "a direct request is fine"


@pytest.mark.asyncio
async def test_hosted_mode_pins_the_model(
    first_client: AsyncClient, queued: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "hosted_mode", True)
    assert (await _post(first_client, model="tiny")).status_code == 403
    assert (await _post(first_client, model=settings.whisper_model)).status_code == 202


async def _finish(
    db_factory: Any, job_id: str, status: str, age_h: float = 0, error: str | None = None
) -> None:
    async with db_factory() as s:
        job = (await s.execute(select(Job).where(Job.id == UUID(job_id)))).scalar_one()
        job.status = status
        job.error = error
        job.updated_at = datetime.now(UTC) - timedelta(hours=age_h)
        await s.commit()


@pytest.mark.asyncio
async def test_the_result_is_served_when_done_and_not_before(
    first_client: AsyncClient, queued: Any, db_factory: Any
) -> None:
    job_id = (await _post(first_client)).json()["job_id"]
    r = await first_client.get(f"/api/v1/transcriptions/{job_id}")
    assert r.status_code == 409 and r.json()["error"] == "transcription_not_ready"
    await _finish(db_factory, job_id, "completed")
    with patch(
        "app.api.transcriptions.s3.get_object_bytes", return_value=json.dumps(_TRANSCRIPT).encode()
    ):
        r = await first_client.get(f"/api/v1/transcriptions/{job_id}")
    assert r.status_code == 200 and r.json() == _TRANSCRIPT


@pytest.mark.asyncio
async def test_a_failed_job_says_why(
    first_client: AsyncClient, queued: Any, db_factory: Any
) -> None:
    job_id = (await _post(first_client)).json()["job_id"]
    await _finish(db_factory, job_id, "failed", error="ffmpeg could not read it")
    r = await first_client.get(f"/api/v1/transcriptions/{job_id}")
    assert r.status_code == 409 and r.json()["error"] == "transcription_failed"
    assert "ffmpeg" in r.json()["detail"]


@pytest.mark.asyncio
async def test_a_result_past_its_time_is_gone_and_deleted(
    first_client: AsyncClient, queued: Any, db_factory: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "transcription_result_ttl_h", 24)
    job_id = (await _post(first_client)).json()["job_id"]
    await _finish(db_factory, job_id, "completed", age_h=25)
    with patch("app.api.transcriptions.s3.delete_prefix") as gone:
        r = await first_client.get(f"/api/v1/transcriptions/{job_id}")
    assert r.status_code == 404 and r.json()["error"] == "transcription_expired"
    gone.assert_called_once_with(f"transcriptions/{job_id}/")
    assert (await first_client.get(f"/api/v1/jobs/{job_id}")).status_code == 404


@pytest.mark.asyncio
async def test_a_new_request_sweeps_what_has_expired(
    first_client: AsyncClient, queued: Any, db_factory: Any
) -> None:
    old = (await _post(first_client)).json()["job_id"]
    await _finish(db_factory, old, "completed", age_h=48)
    assert (await _post(first_client)).status_code == 202
    assert (await first_client.get(f"/api/v1/jobs/{old}")).status_code == 404


@pytest.mark.asyncio
async def test_delete_removes_the_audio_and_the_result(
    first_client: AsyncClient, queued: Any
) -> None:
    job_id = (await _post(first_client)).json()["job_id"]
    with (
        patch("app.api.transcriptions.s3.delete_prefix") as gone,
        patch("app.api.transcriptions.celery_app") as celery,
    ):
        r = await first_client.delete(f"/api/v1/transcriptions/{job_id}")
    assert r.status_code == 204
    gone.assert_called_once_with(f"transcriptions/{job_id}/")
    celery.control.revoke.assert_called_once()
    assert (await first_client.get(f"/api/v1/jobs/{job_id}")).status_code == 404


@pytest.mark.asyncio
async def test_deleting_a_job_that_did_work_keeps_its_usage(
    user_a: tuple[AsyncClient, UUID], db_factory: Any
) -> None:
    """A phone deletes its job the moment it has the transcript; the account still counts it."""
    from app.services.usage import UNIT_TRANSCRIPTION_SECONDS, merge_usage_into_metadata

    client, user_id = user_a
    async with db_factory() as s:
        job = Job(
            user_id=user_id,
            type="transcription",
            status="completed",
            metadata_json=merge_usage_into_metadata(None, UNIT_TRANSCRIPTION_SECONDS, 15.4),
        )
        s.add(job)
        await s.commit()
        job_id = job.id
    with patch("app.api.transcriptions.s3.delete_prefix"):
        assert (await client.delete(f"/api/v1/transcriptions/{job_id}")).status_code == 204
    assert (await client.get(f"/api/v1/transcriptions/{job_id}")).status_code == 404
    assert (await client.get(f"/api/v1/jobs/{job_id}")).status_code == 404
    assert (await client.get("/api/v1/auth/me/usage")).json()["transcription_seconds"] == 15.4


@pytest.mark.asyncio
async def test_a_project_job_is_not_reachable_as_a_transcription(
    user_a: tuple[AsyncClient, UUID], seed_project: Callable[..., Any], db_factory: Any
) -> None:
    client, user_id = user_a
    project_id = await seed_project(user_id)
    async with db_factory() as s:
        job = Job(project_id=project_id, user_id=user_id, type="transcription", status="completed")
        s.add(job)
        await s.commit()
        job_id = job.id
    r = await client.get(f"/api/v1/transcriptions/{job_id}")
    assert r.status_code == 404, "that job has a project: its transcript is on the project"


@pytest.mark.asyncio
async def test_usage_counts_projectless_jobs(
    user_a: tuple[AsyncClient, UUID], db_factory: Any
) -> None:
    from app.services.usage import UNIT_TRANSCRIPTION_SECONDS, sum_usage_for_user

    _, user_id = user_a
    async with db_factory() as s:
        s.add(
            Job(
                user_id=user_id,
                type="transcription",
                status="completed",
                metadata_json={"usage": {"unit": UNIT_TRANSCRIPTION_SECONDS, "amount": 42.0}},
            )
        )
        await s.commit()
        assert await sum_usage_for_user(s, user_id, UNIT_TRANSCRIPTION_SECONDS) == 42.0
