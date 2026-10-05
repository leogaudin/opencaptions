"""API keys: minted once, authorize everything but account management, revocable."""

from __future__ import annotations

from typing import Any

from httpx import AsyncClient


async def _mint(c: AsyncClient, name: str = "script") -> dict[str, Any]:
    r = await c.post("/api/v1/api-keys", json={"name": name})
    assert r.status_code == 201, r.text
    return r.json()


def _bearer(make: Any) -> Any:
    async def build(key: str) -> AsyncClient:
        c: AsyncClient = await make()
        c.headers["Authorization"] = f"Bearer {key}"
        return c

    return build


async def test_a_key_is_shown_once_and_listed_by_prefix_only(first_client: AsyncClient) -> None:
    created = await _mint(first_client)
    assert created["key"].startswith("oc_") and created["key"].startswith(created["prefix"])
    listed = (await first_client.get("/api/v1/api-keys")).json()
    assert [k["id"] for k in listed] == [created["id"]]
    assert "key" not in listed[0]


async def test_a_key_authorizes_api_calls_without_a_session_or_csrf(
    first_client: AsyncClient, make_client: Any
) -> None:
    key = (await _mint(first_client))["key"]
    script = await _bearer(make_client)(key)
    assert (await script.get("/api/v1/projects")).status_code == 200
    # An unsafe method with no cookie and no CSRF token: the key alone is enough.
    r = await script.post("/api/v1/projects", data={"title": "x", "video_url": "not a url"})
    assert r.status_code != 401 and r.status_code != 403, r.text
    used = (await first_client.get("/api/v1/api-keys")).json()[0]
    assert used["last_used_at"] is not None


async def test_a_key_cannot_manage_keys_or_the_account(
    first_client: AsyncClient, make_client: Any
) -> None:
    key = (await _mint(first_client))["key"]
    script = await _bearer(make_client)(key)
    assert (await script.get("/api/v1/api-keys")).status_code == 401
    assert (await script.post("/api/v1/api-keys", json={"name": "x"})).status_code == 401
    assert (await script.get("/api/v1/auth/me")).status_code == 401


async def test_unknown_and_revoked_keys_are_refused(
    first_client: AsyncClient, make_client: Any
) -> None:
    created = await _mint(first_client)
    bearer = _bearer(make_client)
    assert (await (await bearer("oc_not-a-key")).get("/api/v1/projects")).status_code == 401
    r = await first_client.delete(f"/api/v1/api-keys/{created['id']}")
    assert r.status_code == 204
    assert (await (await bearer(created["key"])).get("/api/v1/projects")).status_code == 401


async def test_one_user_cannot_see_or_revoke_anothers_key(
    first_client: AsyncClient, user_b_client: AsyncClient
) -> None:
    created = await _mint(first_client)
    assert (await user_b_client.get("/api/v1/api-keys")).json() == []
    r = await user_b_client.delete(f"/api/v1/api-keys/{created['id']}")
    assert r.status_code == 404
