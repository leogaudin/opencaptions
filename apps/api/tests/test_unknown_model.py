"""Only models the local provider lists are accepted from a client.

faster-whisper downloads a name with a `/` from Hugging Face and reads a path that exists, so an
unchecked model lets any account make the server fetch an arbitrary repository.
"""

from __future__ import annotations

from typing import Any
from unittest.mock import MagicMock, patch
from uuid import UUID

import pytest
from httpx import AsyncClient

from app.core.config import settings

_UNLISTED = ["openai/whisper-large", "Systran/faster-whisper-tiny", "/etc", "../models/x", "nope"]
_LISTED = ["tiny", "large-v3-turbo", "parakeet-ultra"]


@pytest.fixture
def queued_upload() -> Any:
    task = MagicMock()
    task.delay.return_value = MagicMock(id="celery-1")
    with (
        patch("app.api.transcriptions.s3.upload_file"),
        patch("app.api.transcriptions.s3.delete_prefix"),
        patch("app.services.audio.probe_duration", return_value=30.0),
        patch("app.tasks.transcribe.transcribe_upload", task),
    ):
        yield task


@pytest.fixture
def queued_project() -> Any:
    task = MagicMock()
    task.delay.return_value = MagicMock(id="celery-2")
    with patch("app.tasks.transcribe.transcribe_video", task):
        yield task


async def _upload(c: AsyncClient, model: str) -> Any:
    return await c.post(
        "/api/v1/transcriptions",
        data={"language": "auto", "model": model},
        files={"audio": ("a.m4a", b"not really audio", "audio/mp4")},
    )


@pytest.mark.asyncio
@pytest.mark.parametrize("model", _UNLISTED)
async def test_an_unlisted_model_is_refused_for_an_upload(
    first_client: AsyncClient, queued_upload: Any, model: str
) -> None:
    r = await _upload(first_client, model)
    assert r.status_code == 400, r.text
    assert r.json()["error"] == "unknown_model"
    queued_upload.delay.assert_not_called()


@pytest.mark.asyncio
@pytest.mark.parametrize("model", _LISTED)
async def test_a_listed_model_is_queued_for_an_upload(
    first_client: AsyncClient, queued_upload: Any, model: str
) -> None:
    assert (await _upload(first_client, model)).status_code == 202
    assert queued_upload.delay.call_args.kwargs["model"] == model


@pytest.mark.asyncio
@pytest.mark.parametrize("model", _UNLISTED)
async def test_an_unlisted_model_is_refused_for_a_project(
    user_a: tuple[AsyncClient, UUID], seed_project: Any, queued_project: Any, model: str
) -> None:
    client, owner = user_a
    project_id = await seed_project(owner)
    r = await client.post(f"/api/v1/projects/{project_id}/transcribe", json={"model": model})
    assert r.status_code == 400, r.text
    assert r.json()["error"] == "unknown_model"
    queued_project.delay.assert_not_called()


@pytest.mark.asyncio
@pytest.mark.parametrize("model", _LISTED)
async def test_a_listed_model_is_queued_for_a_project(
    user_a: tuple[AsyncClient, UUID], seed_project: Any, queued_project: Any, model: str
) -> None:
    client, owner = user_a
    project_id = await seed_project(owner)
    r = await client.post(f"/api/v1/projects/{project_id}/transcribe", json={"model": model})
    assert r.status_code == 202, r.text
    assert queued_project.delay.call_args.kwargs["model"] == model


@pytest.mark.asyncio
async def test_another_provider_names_its_own_models(
    user_a: tuple[AsyncClient, UUID], seed_project: Any, queued_project: Any
) -> None:
    client, owner = user_a
    project_id = await seed_project(owner)
    r = await client.post(
        f"/api/v1/projects/{project_id}/transcribe",
        json={"provider": "openai", "model": "gpt-4o-transcribe"},
    )
    assert r.status_code == 202, r.text


def test_the_instances_own_default_is_trusted(monkeypatch: pytest.MonkeyPatch) -> None:
    from app.api.deps import require_listed_model

    monkeypatch.setattr(settings, "default_model", "custom/default")
    require_listed_model("local", "custom/default")
