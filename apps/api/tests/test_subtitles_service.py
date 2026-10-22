"""The subtitle service asks the engine, and says so when it cannot answer."""

from __future__ import annotations

from typing import Any

import httpx
import pytest

from app.services import subtitles


class _Client:
    def __init__(self, response: httpx.Response | Exception) -> None:
        self.response, self.sent = response, {}

    async def __aenter__(self) -> _Client:
        return self

    async def __aexit__(self, *_: Any) -> None:
        return None

    async def post(self, url: str, **kw: Any) -> httpx.Response:
        self.sent = {"url": url, **kw}
        if isinstance(self.response, Exception):
            raise self.response
        return self.response


def _use(monkeypatch: pytest.MonkeyPatch, response: httpx.Response | Exception) -> _Client:
    client = _Client(response)
    monkeypatch.setattr(subtitles.httpx, "AsyncClient", lambda **_: client)
    return client


@pytest.mark.asyncio
async def test_it_posts_the_transcript_to_the_engine_with_its_token(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client = _use(monkeypatch, httpx.Response(200, json={"text": "1\n..."}))
    out = await subtitles.subtitles(
        {"segments": []}, words_per_line=2, caption_offset_ms=-250, format="vtt"
    )
    assert out == "1\n..."
    assert client.sent["url"].endswith("/subtitles")
    assert client.sent["json"] == {
        "transcript": {"segments": []},
        "words_per_line": 2,
        "caption_offset_ms": -250,
        "format": "vtt",
    }
    assert "x-engine-token" in client.sent["headers"]


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "failure", [httpx.ConnectError("down"), httpx.Response(500, json={"error": "x"})]
)
async def test_an_engine_that_cannot_answer_is_reported(
    monkeypatch: pytest.MonkeyPatch, failure: httpx.Response | Exception
) -> None:
    _use(monkeypatch, failure)
    with pytest.raises(subtitles.EngineUnavailableError):
        await subtitles.subtitles({}, words_per_line=3, caption_offset_ms=0, format="srt")
