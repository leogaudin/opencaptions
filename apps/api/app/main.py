"""OpenCaptions FastAPI application factory."""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import APIRouter, FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from app import __version__
from app.api import (
    auth,
    fonts,
    health,
    jobs,
    keys,
    project_files,
    projects,
    transcriptions,
)
from app.api import settings as settings_router
from app.api import websocket as ws_router
from app.api.csrf import CSRFMiddleware
from app.core.config import settings
from app.models.schemas import ErrorResponse

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
    """Application lifespan hook."""
    logging.basicConfig(
        level=settings.log_level,
        format="%(asctime)s %(levelname)-7s %(name)s :: %(message)s",
    )

    # Auto-migrate: run alembic upgrade head on every boot. Safe for single-
    # replica local dev (Docker Compose). In multi-replica prod, swap this for
    # a one-shot init container or a deploy-time step.
    try:
        import asyncio

        from alembic import command as alembic_cmd
        from alembic.config import Config as AlembicConfig

        def _run_migrations() -> None:
            cfg = AlembicConfig("/app/alembic.ini")
            alembic_cmd.upgrade(cfg, "head")

        await asyncio.to_thread(_run_migrations)
        logger.info("Alembic migrations applied (upgrade head)")
    except Exception as e:
        # Fail the boot LOUDLY rather than continue on a half-migrated schema.
        # Pre-auth a swallowed failure was merely annoying; now, booting without
        # the users table would 500 every authenticated route while the API
        # reports itself started. Re-raise so the container stops instead.
        logger.critical(
            "Auto-migrate FAILED (alembic upgrade head): %s -- the container will not start", e
        )
        raise

    # The shipped credentials are public: fine on a laptop, not on a host others can reach, and
    # the web port is published on every interface. Said once at start, not enforced.
    if settings.default_credentials_in_use:
        logger.warning(
            "Using the shipped development credentials (%s). Change them before exposing this "
            "instance beyond a trusted network; see docs/SELF-HOSTING.md.",
            ", ".join(c.upper() for c in settings.default_credentials_in_use),
        )

    # Best-effort: ensure storage bucket exists. Non-fatal if unreachable at startup,
    # a healthcheck will surface the issue.
    try:
        from app.storage import s3

        s3.ensure_bucket()
    except Exception as e:
        logger.warning("Bucket bootstrap skipped: %s", e)

    # Fail the jobs nothing could still be working on (see services/recovery.py).
    try:
        from app.core.db import SessionFactory
        from app.services.recovery import recover_orphan_jobs

        async with SessionFactory() as db:
            count = await recover_orphan_jobs(db)
            await db.commit()
        if count:
            logger.info("Failed %d abandoned job(s) at startup", count)
    except Exception as e:
        logger.warning("Orphan job recovery skipped: %s", e)

    yield


def create_app() -> FastAPI:
    app = FastAPI(
        title="OpenCaptions API",
        # Single-sourced from installed package metadata via app.__version__;
        # do not hardcode a literal here (see apps/api/pyproject.toml).
        version=__version__,
        description=(
            "Self-hosted video captioning API. The workflow is two-step: "
            "upload a video and run transcription (automatic speech recognition), "
            "then download the rendered video with burned-in animated captions in "
            "your choice of format (MP4/H.264, MP4/H.265, WebM/VP9, MOV/ProRes). "
            "Subtitle-only exports (SRT, VTT, JSON) are also available.\n\n"
            "**Authentication.** Scripts send an API key, created on the Account "
            "page, as `Authorization: Bearer oc_…`; use the Authorize button to "
            "try requests here. Keys reach every endpoint except `/auth` and "
            "`/api-keys`, which only a signed-in browser may call."
        ),
        openapi_url="/api/v1/openapi.json",
        docs_url="/api/v1/docs",
        redoc_url="/api/v1/redoc",
        openapi_tags=[
            {
                "name": "health",
                "description": "Liveness and readiness probes for infrastructure monitoring.",
            },
            {
                "name": "auth",
                "description": "Registration, login/logout, current user, and first-run bootstrap status.",
            },
            {
                "name": "projects",
                "description": "CRUD, transcription, rendering, and export operations on captioning projects.",
            },
            {
                "name": "jobs",
                "description": "Monitor and control asynchronous transcription/render jobs.",
            },
            {
                "name": "api-keys",
                "description": "Keys for calling the API from scripts. Managed from a signed-in browser.",
            },
            {
                "name": "fonts",
                "description": "Google Fonts, fetched once and served from this instance.",
            },
            {
                "name": "settings",
                "description": "Application configuration (transcription provider and limits).",
            },
        ],
        lifespan=lifespan,
    )

    origins = [o.strip() for o in settings.cors_origins.split(",") if o.strip()]
    # CSRF is added BEFORE CORS so that CORS ends up the OUTERMOST middleware:
    # a CSRF-rejected (403) response still receives CORS headers and the browser
    # can read it. See app/api/csrf.py.
    app.add_middleware(CSRFMiddleware)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    # ----- Exception handlers (RFC 9457 Problem Details) -----
    @app.exception_handler(StarletteHTTPException)
    async def _http_exc(_req: Request, exc: StarletteHTTPException) -> JSONResponse:
        # If the detail is already an ErrorResponse-shaped dict, pass through.
        if isinstance(exc.detail, dict) and "error" in exc.detail:
            return JSONResponse(status_code=exc.status_code, content=exc.detail)
        body = ErrorResponse(
            error="http_error",
            detail=str(exc.detail) if exc.detail else "",
            code=exc.status_code,
        )
        return JSONResponse(status_code=exc.status_code, content=body.model_dump())

    @app.exception_handler(RequestValidationError)
    async def _validation_exc(_req: Request, exc: RequestValidationError) -> JSONResponse:
        first = exc.errors()[0] if exc.errors() else {}
        field = ".".join(str(p) for p in first.get("loc", []))
        body = ErrorResponse(
            error="validation_error",
            detail=first.get("msg", "Invalid request"),
            code=422,
            field=field or None,
        )
        return JSONResponse(status_code=422, content=body.model_dump())

    # ----- Routers -----
    v1 = APIRouter(prefix="/api/v1")
    v1.include_router(health.router)
    v1.include_router(auth.router)
    v1.include_router(projects.router)
    v1.include_router(project_files.router)
    v1.include_router(jobs.router)
    v1.include_router(transcriptions.router)
    v1.include_router(fonts.router)
    v1.include_router(keys.router)
    v1.include_router(settings_router.router)
    app.include_router(v1)

    # WebSocket lives at /ws/v1/projects/{id}, outside the /api/v1 prefix.
    app.include_router(ws_router.router)

    return app


app = create_app()
