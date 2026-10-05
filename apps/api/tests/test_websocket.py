"""WebSocket session-revocation behaviour.

A socket is authenticated once at the handshake; the keepalive loop must then
re-validate the session and CLOSE the socket when it is revoked (logout) or
expires, so a logged-out client cannot keep streaming a project's job progress.

Driving the ASGI app directly (rather than via a threaded test client) keeps the
in-memory SQLite + fakeredis stores on the SAME event loop as the handler.
"""

from __future__ import annotations

import asyncio
import json
from typing import Any
from uuid import UUID

import fakeredis.aioredis
import pytest
from httpx import AsyncClient

import app.api.websocket as ws_module
from app.core import sessions
from app.main import app


@pytest.mark.asyncio
async def test_websocket_closes_when_session_revoked(
    first_client: AsyncClient,
    user_a: tuple[AsyncClient, UUID],
    seed_project: Any,
    db_factory: Any,
    fake_redis: Any,
    monkeypatch: Any,
) -> None:
    _client, owner_id = user_a
    project_id = await seed_project(owner_id)
    session_id = first_client.cookies.get("oc_session")
    assert session_id

    # The handler loads the project via SessionFactory (not the db_session
    # dependency) and opens its OWN Redis pub/sub; point both at the test's
    # in-memory stores, and shrink the keepalive so revocation is seen quickly.
    monkeypatch.setattr(ws_module, "SessionFactory", db_factory)
    monkeypatch.setattr(
        ws_module.redis_async, "from_url", lambda *a, **k: fakeredis.aioredis.FakeRedis()
    )
    monkeypatch.setattr(ws_module, "_KEEPALIVE_INTERVAL_SECONDS", 0.05)

    to_app: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
    from_app: asyncio.Queue[dict[str, Any]] = asyncio.Queue()

    async def receive() -> dict[str, Any]:
        return await to_app.get()

    async def send(message: dict[str, Any]) -> None:
        await from_app.put(message)

    path = f"/ws/v1/projects/{project_id}"
    scope = {
        "type": "websocket",
        "path": path,
        "raw_path": path.encode(),
        "headers": [(b"cookie", f"oc_session={session_id}".encode())],
        "query_string": b"",
        "subprotocols": [],
        "client": ("testclient", 0),
        "server": ("testserver", 80),
        "scheme": "ws",
        "asgi": {"version": "3.0", "spec_version": "2.3"},
    }

    await to_app.put({"type": "websocket.connect"})
    task = asyncio.create_task(app(scope, receive, send))
    try:
        accept = await asyncio.wait_for(from_app.get(), timeout=2)
        assert accept["type"] == "websocket.accept"

        connected = await asyncio.wait_for(from_app.get(), timeout=2)
        assert connected["type"] == "websocket.send"
        assert json.loads(connected["text"])["type"] == "connected"

        # Revoke the session server-side, exactly as logout does.
        await sessions.delete_session(session_id)

        # The next keepalive tick must re-validate, find it gone, and close 4401.
        # Interleaved ping frames (also "websocket.send") are skipped.
        while True:
            msg = await asyncio.wait_for(from_app.get(), timeout=2)
            if msg["type"] == "websocket.close":
                assert msg["code"] == 4401
                break

        await asyncio.wait_for(task, timeout=2)
    finally:
        if not task.done():
            task.cancel()
