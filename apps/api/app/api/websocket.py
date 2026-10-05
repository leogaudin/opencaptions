"""/ws/v1/projects/{project_id} — multiplexed WebSocket for job progress.

Celery workers publish progress events to Redis; this router relays them to the
browser over a WebSocket.
"""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Any
from uuid import UUID

import redis.asyncio as redis_async
from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from app.api.deps import SESSION_COOKIE_NAME
from app.core import sessions
from app.core.config import settings
from app.core.db import SessionFactory
from app.models import Project

logger = logging.getLogger(__name__)
router = APIRouter()

# Keepalive cadence, also used to re-validate the session (see project_ws).
_KEEPALIVE_INTERVAL_SECONDS = 20


def _channel_for_project(project_id: UUID) -> str:
    return f"opencaptions:project:{project_id}"


async def _authorize_handshake(websocket: WebSocket, project_id: UUID) -> str | None:
    """Return the validated session id, or close the socket and return None.

    Authenticates and authorizes BEFORE accepting. Cookies ARE sent on the WS
    handshake, so this reuses the same opaque server-side session as the HTTP
    API. A rejected handshake (close before accept) leaks nothing — no data
    frame is ever sent to an unauthenticated or non-owning client.
    """
    session_id = websocket.cookies.get(SESSION_COOKIE_NAME)
    session_data = await sessions.get_session(session_id) if session_id else None
    if session_id is None or session_data is None:
        await websocket.close(code=4401)  # unauthenticated
        return None

    async with SessionFactory() as db:
        proj = await db.get(Project, project_id)
        # 4403, and identical treatment for "missing" and "not yours", so a
        # non-owner cannot probe which project ids exist over the socket.
        if proj is None or proj.owner_id != session_data.user_id:
            await websocket.close(code=4403)
            return None
    return session_id


async def _forward_events(websocket: WebSocket, pubsub: Any, channel: str) -> None:
    """Relay project pub/sub events to the client until the socket closes."""
    async for message in pubsub.listen():
        if message["type"] != "message":
            continue
        try:
            data = json.loads(message["data"])
        except (TypeError, ValueError):
            logger.warning("Non-JSON message on %s", channel)
            continue
        await websocket.send_json(data)


async def _keepalive_and_revalidate(websocket: WebSocket, session_id: str) -> None:
    """Ping periodically, and RE-VALIDATE the session on every tick.

    A socket authenticated once at handshake must not keep streaming after the
    session is revoked (logout) or expires. When it is gone, close and stop --
    4401 (the same code that rejects an unauthenticated handshake) with no
    reason string, so nothing about the session leaks.
    """
    while True:
        await asyncio.sleep(_KEEPALIVE_INTERVAL_SECONDS)
        if await sessions.get_session(session_id) is None:
            await websocket.close(code=4401)
            return
        try:
            await websocket.send_json({"type": "ping", "payload": {}})
        except Exception:  # noqa: BLE001
            return


@router.websocket("/ws/v1/projects/{project_id}")
async def project_ws(websocket: WebSocket, project_id: UUID) -> None:
    """Stream job_progress / job_succeeded / job_failed / transcript_updated for a project.

    Workers publish to Redis channel `opencaptions:project:{project_id}`.
    """
    session_id = await _authorize_handshake(websocket, project_id)
    if session_id is None:
        return

    await websocket.accept()
    client: redis_async.Redis = redis_async.from_url(settings.redis_url)
    pubsub = client.pubsub()
    channel = _channel_for_project(project_id)

    try:
        await pubsub.subscribe(channel)
        await websocket.send_json({"type": "connected", "payload": {"project_id": str(project_id)}})
        # Forward pub/sub messages and re-check the session concurrently;
        # whichever finishes first (client disconnect, or a revoked session)
        # tears the other down.
        forward = asyncio.create_task(_forward_events(websocket, pubsub, channel))
        keepalive = asyncio.create_task(_keepalive_and_revalidate(websocket, session_id))
        try:
            await asyncio.wait({forward, keepalive}, return_when=asyncio.FIRST_COMPLETED)
        except WebSocketDisconnect:
            pass
        finally:
            forward.cancel()
            keepalive.cancel()
            await asyncio.gather(forward, keepalive, return_exceptions=True)
    finally:
        await pubsub.unsubscribe(channel)
        await pubsub.aclose()
        await client.aclose()


def publish_to_project(project_id: UUID, message: dict[str, Any]) -> None:
    """Sync helper used by Celery workers (which run blocking code).

    Tasks call this with {"type": "job_progress", "payload": {...}}.
    """
    import redis  # sync client

    r = redis.Redis.from_url(settings.redis_url)
    try:
        r.publish(_channel_for_project(project_id), json.dumps(message, default=str))
    finally:
        r.close()
