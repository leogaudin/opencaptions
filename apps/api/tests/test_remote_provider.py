"""The `opencaptions` provider: transcription on another OpenCaptions backend."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any
from unittest.mock import patch

import httpx
import pytest

from app.core.config import settings
from app.transcription import remote
from app.transcription.base import get_provider

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
_CAPS = {
    "api_version": 1,
    "instance_name": "Home GPU",
    "models": [{"id": "large-v3", "label": "Large v3", "note": ""}],
    "default_model": "large-v3",
}


class Remote:
    """A stand-in for the other instance; records what it was sent."""

    def __init__(
        self, *, states: list[dict[str, Any]] | None = None, caps: dict[str, Any] | None = None
    ):
        self.calls: list[tuple[str, str]] = []
        self.posted: dict[str, Any] = {}
        self.headers: dict[str, str] = {}
        self.caps = caps or _CAPS
        self.states = states or [{"status": "completed", "progress": 1.0}]
        self.polls = 0
        self.status_for = {"caps": 200, "post": 202, "result": 200}

    def handler(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        self.calls.append((request.method, path))
        self.headers = dict(request.headers)
        if path.endswith("/transcription/capabilities"):
            return httpx.Response(self.status_for["caps"], json=self.caps)
        if request.method == "POST" and path.endswith("/transcriptions"):
            self.posted = {"body": request.content}
            return httpx.Response(self.status_for["post"], json={"job_id": "job-1"})
        if path.endswith("/jobs/job-1"):
            state = self.states[min(self.polls, len(self.states) - 1)]
            self.polls += 1
            return httpx.Response(200, json=state)
        if request.method == "GET" and path.endswith("/transcriptions/job-1"):
            return httpx.Response(self.status_for["result"], json=_TRANSCRIPT)
        if request.method == "DELETE":
            return httpx.Response(204)
        return httpx.Response(404, json={})


@pytest.fixture
def configured(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(settings, "transcription_remote_url", "https://gpu.example.org")
    monkeypatch.setattr(settings, "transcription_remote_key", "oc_secret")
    monkeypatch.setattr(remote, "POLL_SECONDS", 0)
    monkeypatch.setattr(remote, "validate_url", lambda url: url)


def _use(stub: Remote) -> Any:
    def client() -> httpx.Client:
        return httpx.Client(
            transport=httpx.MockTransport(stub.handler),
            headers={
                "Authorization": f"Bearer {settings.transcription_remote_key}",
                remote.HOP_HEADER: "1",
            },
        )

    return patch.object(remote, "_client", client)


def _audio(tmp_path: Path) -> str:
    path = tmp_path / "a.wav"
    path.write_bytes(b"RIFF....")
    return str(path)


def test_it_is_registered_and_never_needs_a_download() -> None:
    provider = get_provider("opencaptions")
    assert provider.name == "opencaptions" and provider.is_model_cached("anything")


def test_a_transcription_goes_up_is_followed_fetched_and_deleted(
    configured: None, tmp_path: Path
) -> None:
    stub = Remote(
        states=[
            {"status": "running", "progress": 0.5, "message": "Transcribing"},
            {"status": "completed", "progress": 1.0},
        ]
    )
    seen: list[tuple[float, str]] = []
    with _use(stub):
        transcript = get_provider("opencaptions").transcribe(
            _audio(tmp_path),
            language="fr",
            model="large-v3",
            on_progress=lambda f, m: seen.append((f, m)),
        )
    assert transcript.segments[0].text == "hi" and transcript.language == "en"
    methods = [m for m, _ in stub.calls]
    assert methods[-1] == "DELETE", "the remote is told to forget it"
    assert b'name="language"' in stub.posted["body"] and b"fr" in stub.posted["body"]
    assert b'name="model"' in stub.posted["body"], "an offered model is forwarded"
    assert stub.headers[remote.HOP_HEADER.lower()] == "1", "so a forwarding loop is caught"
    assert stub.headers["authorization"] == "Bearer oc_secret"
    fractions = [f for f, _ in seen]
    assert fractions == sorted(fractions) and fractions[-1] == 1.0
    assert any(abs(f - (0.05 + 0.9 * 0.5)) < 1e-6 for f in fractions), "mapped from the remote's"


def test_a_model_the_remote_does_not_offer_is_left_to_it(configured: None, tmp_path: Path) -> None:
    stub = Remote()
    with _use(stub):
        get_provider("opencaptions").transcribe(_audio(tmp_path), language="auto", model="tiny")
    assert b'name="model"' not in stub.posted["body"]


def test_it_says_what_went_wrong(configured: None, tmp_path: Path) -> None:
    provider = get_provider("opencaptions")
    stub = Remote()
    stub.status_for["caps"] = 401
    with _use(stub), pytest.raises(remote.RemoteTranscriptionError, match="rejected the key"):
        provider.transcribe(_audio(tmp_path))
    with (
        _use(Remote(caps={**_CAPS, "api_version": 2})),
        pytest.raises(remote.RemoteTranscriptionError, match="version 2"),
    ):
        provider.transcribe(_audio(tmp_path))
    with (
        _use(Remote(states=[{"status": "failed", "error": "ffmpeg broke"}])),
        pytest.raises(remote.RemoteTranscriptionError, match="ffmpeg broke"),
    ):
        provider.transcribe(_audio(tmp_path))
    refused = Remote()
    refused.status_for["post"] = 429
    with _use(refused), pytest.raises(remote.RemoteTranscriptionError, match="refused it"):
        provider.transcribe(_audio(tmp_path))


def test_it_needs_a_url_and_a_key_and_checks_the_address(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    provider = get_provider("opencaptions")
    monkeypatch.setattr(settings, "transcription_remote_url", "")
    monkeypatch.setattr(settings, "transcription_remote_key", "")
    with pytest.raises(remote.RemoteTranscriptionError, match="TRANSCRIPTION_REMOTE_URL"):
        provider.transcribe(_audio(tmp_path))
    monkeypatch.setattr(settings, "transcription_remote_url", "http://127.0.0.1:5173")
    monkeypatch.setattr(settings, "transcription_remote_key", "oc_x")
    with pytest.raises(remote.RemoteTranscriptionError, match="not allowed"):
        provider.transcribe(_audio(tmp_path))
    # A host named in SSRF_ALLOWED_HOSTS (a GPU box on the LAN) is allowed.
    monkeypatch.setattr(settings, "ssrf_allowed_hosts", "127.0.0.1")
    assert remote._base_url() == "http://127.0.0.1:5173"


@pytest.mark.asyncio
async def test_settings_report_the_remote_and_test_it(first_client: Any, configured: None) -> None:
    body = (await first_client.get("/api/v1/settings")).json()["transcription"]
    assert body["remote_configured"] is True
    assert body["remote_url"] == "https://gpu.example.org"
    assert "oc_secret" not in json.dumps(body), "the key is never returned"
    with _use(Remote()):
        ok = (await first_client.post("/api/v1/settings/transcription/test")).json()
    assert ok["ok"] is True and ok["instance_name"] == "Home GPU"
    assert ok["models"][0]["id"] == "large-v3"
    bad = Remote()
    bad.status_for["caps"] = 401
    with _use(bad):
        failed = (await first_client.post("/api/v1/settings/transcription/test")).json()
    assert failed["ok"] is False and "rejected the key" in failed["error"]


@pytest.mark.asyncio
async def test_hosted_mode_hides_and_refuses_the_remote(
    first_client: Any, configured: None, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "hosted_mode", True)
    body = (await first_client.get("/api/v1/settings")).json()["transcription"]
    assert body["remote_url"] is None and body["remote_configured"] is False
    r = (await first_client.post("/api/v1/settings/transcription/test")).json()
    assert r["ok"] is False
