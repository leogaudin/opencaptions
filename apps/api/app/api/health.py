"""Healthcheck router. Reports DB/Redis/object storage + resolved transcription device."""

from __future__ import annotations

import asyncio
import logging

import redis.asyncio as redis_async
from fastapi import APIRouter
from sqlalchemy import text

from app import __version__
from app.core.config import settings
from app.core.db import engine
from app.models.schemas import HealthResponse, ServiceHealth, TranscriptionInfo
from app.storage import s3
from app.transcription.device import resolve_compute_type, resolve_device

logger = logging.getLogger(__name__)
router = APIRouter()


async def _check_db() -> bool:
    try:
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
        return True
    except Exception as e:
        logger.warning("DB health check failed: %s", e)
        return False


async def _check_redis() -> bool:
    try:
        client: redis_async.Redis = redis_async.from_url(settings.redis_url)
        try:
            return bool(await client.ping())
        finally:
            await client.aclose()
    except Exception as e:
        logger.warning("Redis health check failed: %s", e)
        return False


async def _check_storage() -> bool:
    try:
        # Run sync boto3 in thread to avoid blocking the event loop.
        return await asyncio.to_thread(s3.health_check)
    except Exception as e:
        logger.warning("Storage health check failed: %s", e)
        return False


@router.get("/health", response_model=HealthResponse, tags=["health"])
async def health() -> HealthResponse:
    """Liveness + readiness probe. 200 even if a service is degraded."""
    db, cache, store = await asyncio.gather(_check_db(), _check_redis(), _check_storage())
    status = "ok" if all((db, cache, store)) else "degraded"
    if settings.hosted_mode:
        return HealthResponse(status=status, version=__version__)
    device_result = resolve_device()
    compute_result = resolve_compute_type()
    return HealthResponse(
        status=status,
        # Single-sourced from installed package metadata via app.__version__.
        version=__version__,
        services=ServiceHealth(
            database="ok" if db else "down",
            redis="ok" if cache else "down",
            storage="ok" if store else "down",
        ),
        transcription=TranscriptionInfo(
            device=device_result.resolved,
            compute_type=compute_result.resolved,
            default_provider=settings.transcription_provider,
            default_model=settings.whisper_model,
            requested_device=device_result.requested,
            requested_compute_type=compute_result.requested,
            device_fallback_reason=device_result.reason,
            compute_type_fallback_reason=compute_result.reason,
        ),
    )
