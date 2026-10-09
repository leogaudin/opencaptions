"""The local backend grants the engine exactly one upload and relays its result."""

from __future__ import annotations

from typing import Any

import httpx
import pytest

from app.services import render_backend
from app.services.render_backend import EngineRenderBackend, get_backend


class _Client:
    """Stands in for httpx.Client, recording the one POST the backend makes."""

    sent: dict[str, Any] = {}
    response: httpx.Response

    def __init__(self, **_: Any) -> None: ...

    def __enter__(self) -> _Client:
        return self

    def __exit__(self, *_: Any) -> None: ...

    def post(self, url: str, json: dict[str, Any], headers: dict[str, str]) -> httpx.Response:
        _Client.sent = {"url": url, "json": json, "headers": headers}
        return _Client.response


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch) -> type[_Client]:
    monkeypatch.setattr(render_backend.httpx, "Client", _Client)
    monkeypatch.setattr(
        render_backend.s3,
        "presigned_url",
        lambda key, expires_in, method: f"https://store/{key}?{method}&{expires_in}",
    )
    _Client.response = httpx.Response(
        200, json={"output_key": "k.mp4", "frames_rendered": 90, "duration_ms": 12}
    )
    return _Client


def test_local_is_the_engine() -> None:
    assert isinstance(get_backend("local"), EngineRenderBackend)


def test_engine_gets_a_presigned_upload_for_its_own_output(client: type[_Client]) -> None:
    result = EngineRenderBackend().render({"output_key": "k.mp4", "fps": 30})

    body = client.sent["json"]
    assert client.sent["url"].endswith("/render")
    assert body["output_url"] == f"https://store/k.mp4?put_object&{render_backend.UPLOAD_GRANT_S}"
    assert body["fps"] == 30
    assert (result.output_key, result.frames_rendered, result.duration_ms) == ("k.mp4", 90, 12)


def test_engine_is_shown_the_shared_token(client: type[_Client]) -> None:
    EngineRenderBackend().render({"output_key": "k.mp4"})

    assert client.sent["headers"] == {"x-engine-token": render_backend.settings.engine_token}


def test_an_engine_error_names_the_status_and_detail(client: type[_Client]) -> None:
    client.response = httpx.Response(500, json={"detail": "ffmpeg failed"})
    with pytest.raises(RuntimeError, match="500.*ffmpeg failed"):
        EngineRenderBackend().render({"output_key": "k.mp4"})
