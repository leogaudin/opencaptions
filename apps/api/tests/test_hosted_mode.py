"""Tests for HOSTED_MODE.

One boolean separates the self-hosted edition from a hosted one, and the API is
where it is enforced: the SPA only mirrors what these endpoints say. Each test
pins both the hosted behaviour and the self-hosted default, so flipping the
default by accident fails loudly.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

import pytest
from httpx import AsyncClient

from app.core.config import settings


class _FakeAsyncResult:
    id = "fake-task-id"


def _stub_celery(monkeypatch: pytest.MonkeyPatch) -> list[dict[str, Any]]:
    """Capture what would be enqueued instead of talking to a broker."""
    from app.tasks import transcribe as transcribe_task

    calls: list[dict[str, Any]] = []

    def _delay(*args: Any, **kwargs: Any) -> _FakeAsyncResult:
        calls.append(kwargs)
        return _FakeAsyncResult()

    monkeypatch.setattr(transcribe_task.transcribe_video, "delay", _delay)
    return calls


@pytest.mark.asyncio
async def test_status_reports_self_hosted_by_default(client: AsyncClient) -> None:
    r = await client.get("/api/v1/auth/status")
    assert r.status_code == 200
    assert r.json()["hosted_mode"] is False


@pytest.mark.asyncio
async def test_status_reports_hosted_mode(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The flag is public: the SPA needs it before anyone signs in."""
    monkeypatch.setattr(settings, "hosted_mode", True)
    r = await client.get("/api/v1/auth/status")
    assert r.status_code == 200
    assert r.json()["hosted_mode"] is True


@pytest.mark.asyncio
async def test_settings_hide_model_list_in_hosted_mode(
    first_client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """No list to choose from, and no hardware or model details either."""
    monkeypatch.setattr(settings, "hosted_mode", True)
    r = await first_client.get("/api/v1/settings")
    assert r.status_code == 200
    body = r.json()
    assert body["hosted_mode"] is True
    assert body["transcription"]["available_models"] == []
    assert body["transcription"]["model"] is None
    assert body["transcription"]["device"] is None
    assert body["transcription"]["openai_configured"] is False


@pytest.mark.asyncio
async def test_settings_expose_model_list_when_self_hosted(first_client: AsyncClient) -> None:
    r = await first_client.get("/api/v1/settings")
    assert r.status_code == 200
    body = r.json()
    assert body["hosted_mode"] is False
    assert len(body["transcription"]["available_models"]) > 0


@pytest.mark.asyncio
async def test_health_withholds_infrastructure_in_hosted_mode(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Still a usable probe (200, status, version) but no per-service or
    runtime breakdown: that is the operator's business, not the user's."""
    monkeypatch.setattr(settings, "hosted_mode", True)
    r = await client.get("/api/v1/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] in {"ok", "degraded"}
    assert body["version"]
    assert body["services"] is None
    assert body["transcription"] is None


@pytest.mark.asyncio
async def test_health_reports_infrastructure_when_self_hosted(client: AsyncClient) -> None:
    r = await client.get("/api/v1/health")
    assert r.status_code == 200
    body = r.json()
    assert set(body["services"].keys()) == {"database", "redis", "storage"}
    assert body["transcription"]["default_model"] == settings.whisper_model


@pytest.mark.asyncio
async def test_transcribe_rejects_model_override_in_hosted_mode(
    user_a: tuple[AsyncClient, UUID],
    seed_project: Any,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A client that sends another model is told no, before anything is enqueued."""
    calls = _stub_celery(monkeypatch)
    monkeypatch.setattr(settings, "hosted_mode", True)
    monkeypatch.setattr(settings, "whisper_model", "large-v3-turbo")
    client_a, owner_a = user_a
    project_id = await seed_project(owner_a)

    r = await client_a.post(
        f"/api/v1/projects/{project_id}/transcribe",
        json={"provider": "local", "model": "tiny"},
    )
    assert r.status_code == 403, r.text
    assert r.json()["error"] == "transcription_choice_disabled"
    assert calls == []


@pytest.mark.asyncio
async def test_transcribe_rejects_provider_override_in_hosted_mode(
    user_a: tuple[AsyncClient, UUID],
    seed_project: Any,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The provider decides whose compute runs and where the audio goes, so it
    is gated exactly like the model, even with no model in the request."""
    calls = _stub_celery(monkeypatch)
    monkeypatch.setattr(settings, "hosted_mode", True)
    monkeypatch.setattr(settings, "transcription_provider", "local")
    client_a, owner_a = user_a
    project_id = await seed_project(owner_a)

    r = await client_a.post(
        f"/api/v1/projects/{project_id}/transcribe", json={"provider": "openai"}
    )
    assert r.status_code == 403, r.text
    assert r.json()["error"] == "transcription_choice_disabled"
    assert calls == []


@pytest.mark.asyncio
async def test_transcribe_allows_default_model_and_no_model_in_hosted_mode(
    user_a: tuple[AsyncClient, UUID],
    seed_project: Any,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Naming the configured default changes nothing, so it is not an override."""
    calls = _stub_celery(monkeypatch)
    monkeypatch.setattr(settings, "hosted_mode", True)
    monkeypatch.setattr(settings, "whisper_model", "large-v3-turbo")
    monkeypatch.setattr(settings, "transcription_provider", "local")
    client_a, owner_a = user_a

    r = await client_a.post(f"/api/v1/projects/{await seed_project(owner_a)}/transcribe", json={})
    assert r.status_code == 202, r.text
    r = await client_a.post(
        f"/api/v1/projects/{await seed_project(owner_a)}/transcribe",
        json={"model": "large-v3-turbo"},
    )
    assert r.status_code == 202, r.text
    assert [c["model"] for c in calls] == ["large-v3-turbo", "large-v3-turbo"]


@pytest.mark.asyncio
async def test_transcribe_honours_model_override_when_self_hosted(
    user_a: tuple[AsyncClient, UUID],
    seed_project: Any,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls = _stub_celery(monkeypatch)
    monkeypatch.setattr(settings, "whisper_model", "large-v3-turbo")
    client_a, owner_a = user_a
    project_id = await seed_project(owner_a)

    r = await client_a.post(
        f"/api/v1/projects/{project_id}/transcribe",
        json={"provider": "local", "model": "tiny"},
    )
    assert r.status_code == 202, r.text
    assert [c["model"] for c in calls] == ["tiny"]
