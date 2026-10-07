"""Tests for GET /settings.

Settings are read-only and sourced from environment configuration. These cover
the auth gate, the `registration_enabled` field, and the transcription block's
`available_models` surface (selectable local Whisper models + which is the
configured default).
"""

from __future__ import annotations

import pytest
from httpx import AsyncClient


@pytest.mark.asyncio
async def test_get_settings_exposes_registration_enabled_default(
    first_client: AsyncClient,
) -> None:
    """The field is present and reflects the env default (True)."""
    r = await first_client.get("/api/v1/settings")
    assert r.status_code == 200
    assert r.json()["registration_enabled"] is True


@pytest.mark.asyncio
async def test_get_settings_requires_authentication(client: AsyncClient) -> None:
    """Settings are not public."""
    r = await client.get("/api/v1/settings")
    assert r.status_code == 401


@pytest.mark.asyncio
async def test_get_settings_exposes_available_models(first_client: AsyncClient) -> None:
    """The transcription block advertises selectable local Whisper models,
    each with an id, label and tradeoff note, mirroring supported_languages."""
    r = await first_client.get("/api/v1/settings")
    assert r.status_code == 200
    models = r.json()["transcription"]["available_models"]
    assert isinstance(models, list) and len(models) > 0
    for m in models:
        assert m["id"]
        assert m["label"]
        assert "note" in m
    ids = {m["id"] for m in models}
    assert "large-v3-turbo" in ids


@pytest.mark.asyncio
async def test_get_settings_default_model_is_in_available_models(
    first_client: AsyncClient,
) -> None:
    """The `model` field is the configured default and must identify one of the
    advertised models, so a UI can flag it as selected."""
    r = await first_client.get("/api/v1/settings")
    assert r.status_code == 200
    transcription = r.json()["transcription"]
    ids = {m["id"] for m in transcription["available_models"]}
    assert transcription["model"] in ids
