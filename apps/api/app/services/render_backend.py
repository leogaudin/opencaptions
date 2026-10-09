"""Pluggable render backend: where a render actually runs.

Only the local engine ships here; the seam is what lets a deployment register
another (a remote fleet, a queue in another region) without touching the task.

Mirrors the transcription-provider and entitlement-policy registries rather than
inventing a third mechanism: implementations are keyed by ``name`` and the active
one is selected by configuration.
"""

from __future__ import annotations

import logging
from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Any

import httpx

from app.core.config import settings
from app.core.task_limits import RENDER_REQUEST_TIMEOUT_S
from app.storage import s3

logger = logging.getLogger(__name__)

# Rendering a long video takes minutes; the ceiling is generous on purpose.
RENDER_TIMEOUT = httpx.Timeout(float(RENDER_REQUEST_TIMEOUT_S), connect=30.0)
# The upload happens at the end of the render, so the grant outlives the ceiling.
UPLOAD_GRANT_S = 60 * 60 * 2


@dataclass(frozen=True)
class RenderResult:
    """What a backend reports once the file is in object storage."""

    output_key: str
    frames_rendered: int
    duration_ms: int


class RenderBackend(ABC):
    """Renders captions onto a video and stores the result."""

    name: str

    @abstractmethod
    def render(self, request: dict[str, Any]) -> RenderResult:
        """Render synchronously, raising RuntimeError on failure.

        ``request`` carries the transcript, style, geometry, codec settings, output
        key, and the callback URL and token the backend uses to report progress.
        """
        ...


class EngineRenderBackend(RenderBackend):
    """Posts to the OpenCaptions engine over the compose network.

    The engine holds no storage credentials: it is granted one presigned upload
    for this render's output, alongside the presigned read of the source.
    """

    name = "local"

    def render(self, request: dict[str, Any]) -> RenderResult:
        url = f"{settings.engine_url}/render"
        output_url = s3.presigned_url(
            request["output_key"], expires_in=UPLOAD_GRANT_S, method="put_object"
        )
        try:
            with httpx.Client(timeout=RENDER_TIMEOUT) as client:
                resp = client.post(
                    url,
                    json={**request, "output_url": output_url},
                    headers={"x-engine-token": settings.engine_token},
                )
        except httpx.RequestError as e:
            raise RuntimeError(f"Engine unreachable at {settings.engine_url}: {e}") from e

        if resp.status_code != 200:
            raise RuntimeError(f"Engine returned {resp.status_code}: {resp.text[:500]}")

        data = resp.json()
        return RenderResult(
            output_key=data.get("output_key", request["output_key"]),
            frames_rendered=int(data.get("frames_rendered", 0)),
            duration_ms=int(data.get("duration_ms", 0)),
        )


_REGISTRY: dict[str, RenderBackend] = {}


def register(backend: RenderBackend) -> RenderBackend:
    """Register a backend instance for runtime lookup."""
    _REGISTRY[backend.name] = backend
    return backend


def get_backend(name: str | None = None) -> RenderBackend:
    """Resolve the configured backend, defaulting to the local engine."""
    key = name or settings.render_backend
    if key not in _REGISTRY:
        raise ValueError(f"Unknown render backend: {key!r}. Registered: {list(_REGISTRY)}")
    return _REGISTRY[key]


register(EngineRenderBackend())
