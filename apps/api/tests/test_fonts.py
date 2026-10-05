"""Google Fonts are fetched once, stored, and resolved at caption weight."""

from __future__ import annotations

import json
from typing import Any

import httpx
import pytest

from app.services import fonts

CATALOG = ")]}'" + json.dumps(
    {
        "familyMetadataList": [
            {"family": "Lobster", "category": "Display", "popularity": 9, "fonts": {"400": {}}},
            {
                "family": "Inter",
                "category": "Sans Serif",
                "popularity": 1,
                "fonts": {"700": {}, "900": {}, "800i": {}},
            },
        ]
    }
)
TTF = b"\x00\x01\x00\x00 a font"
CSS = "@font-face { src: url(https://fonts.gstatic.com/s/x.ttf) format('truetype'); }"


@pytest.fixture
def world(monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
    """In-memory storage and a fake Google that counts what it was asked."""
    store: dict[str, bytes] = {}
    calls: list[tuple[str, dict[str, str]]] = []

    def get(url: str, params: dict[str, str] | None = None, **_: Any) -> httpx.Response:
        calls.append((url, params or {}))
        request = httpx.Request("GET", url)
        if url == fonts.CATALOG_URL:
            return httpx.Response(200, text=CATALOG, request=request)
        if url == fonts.CSS_URL:
            return httpx.Response(200, text=CSS, request=request)
        return httpx.Response(200, content=TTF, request=request)

    monkeypatch.setattr(fonts.httpx, "get", get)
    monkeypatch.setattr(fonts.s3, "object_exists", lambda k: k in store)
    monkeypatch.setattr(fonts.s3, "get_object_bytes", lambda k: store[k])
    monkeypatch.setattr(fonts.s3, "put_object_bytes", lambda k, b, _t: store.__setitem__(k, b))
    fonts.catalog.cache_clear()
    yield {"store": store, "calls": calls}
    fonts.catalog.cache_clear()


def test_catalog_is_most_popular_first_at_the_nearest_upright_weight(world: dict[str, Any]) -> None:
    assert [(f.family, f.weight) for f in fonts.catalog()] == [("Inter", 900), ("Lobster", 400)]
    assert fonts.CATALOG_KEY in world["store"]


def test_a_font_is_fetched_once_then_served_from_storage(world: dict[str, Any]) -> None:
    key = fonts.file_key("Inter")
    assert world["store"][key] == TTF
    fonts.catalog.cache_clear()
    assert fonts.file_key("Inter") == key
    css_calls = [p for u, p in world["calls"] if u == fonts.CSS_URL]
    assert css_calls == [{"family": "Inter:wght@900"}], "fetched once, at the weight it has"


def test_a_sample_asks_only_for_the_family_name(world: dict[str, Any]) -> None:
    fonts.sample_key("Lobster")
    assert {"family": "Lobster:wght@400", "text": "Lobster"} in [p for _, p in world["calls"]]


def test_an_unknown_family_is_refused_without_asking_for_a_file(world: dict[str, Any]) -> None:
    with pytest.raises(fonts.FontUnavailableError):
        fonts.file_key("Not A Font")
    assert all(u != fonts.CSS_URL for u, _ in world["calls"])


def test_something_that_is_not_truetype_is_refused(
    world: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    real = fonts.httpx.get
    woff2 = lambda url, **kw: (  # noqa: E731
        httpx.Response(200, content=b"wOF2...", request=httpx.Request("GET", url))
        if url.startswith("https://fonts.gstatic.com")
        else real(url, **kw)
    )
    monkeypatch.setattr(fonts.httpx, "get", woff2)
    with pytest.raises(fonts.FontUnavailableError, match="TrueType"):
        fonts.file_key("Inter")
    assert not any(k.startswith("fonts/files/") for k in world["store"])


def test_keys_of_families_that_slug_alike_differ() -> None:
    assert fonts._key("files", "A B") != fonts._key("files", "A-B")


async def test_font_endpoints_require_a_session(client: Any) -> None:
    for path in ("/api/v1/fonts", "/api/v1/fonts/Inter/file", "/api/v1/fonts/Inter/sample"):
        assert (await client.get(path)).status_code == 401, path


async def test_a_font_file_is_served_as_immutable_truetype(
    world: dict[str, Any], first_client: Any
) -> None:
    r = await first_client.get("/api/v1/fonts/Inter/file")
    assert r.status_code == 200
    assert r.headers["content-type"] == fonts.FONT_TYPE
    assert "immutable" in r.headers["cache-control"]
    assert r.content == TTF


async def test_an_unknown_family_is_a_404(world: dict[str, Any], first_client: Any) -> None:
    r = await first_client.get("/api/v1/fonts/Not%20A%20Font/file")
    assert r.status_code == 404
    assert r.json()["error"] == "font_unavailable"
