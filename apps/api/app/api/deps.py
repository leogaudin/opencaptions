"""FastAPI dependency providers: DB session, authentication, ownership.

get_owned_project and get_owned_job are the only sanctioned way to load either
in a request path. That is what keeps every id-addressed route from being an IDOR.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from datetime import UTC, datetime
from typing import Annotated
from uuid import UUID

from fastapi import Depends, Header, HTTPException, Path, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core import sessions
from app.core.db import get_db
from app.core.job_tokens import verify_job_token
from app.models import ApiKey, Job, Project, User
from app.models.schemas import ErrorResponse
from app.services.api_keys import hash_key

# httpOnly session cookie; the Secure attribute is config-driven (see auth.py)
# so one code path serves http://localhost and HTTPS deployments alike.
SESSION_COOKIE_NAME = "oc_session"
CSRF_HEADER_NAME = "X-CSRF-Token"


async def db_session() -> AsyncIterator[AsyncSession]:
    """Re-export of get_db for clearer router imports."""
    async for session in get_db():
        yield session


def http_error(
    status_code: int, error: str, detail: str, *, field: str | None = None
) -> HTTPException:
    """Build a response in the standard error shape.

    ``code`` is derived from ``status_code`` so the two cannot drift apart.
    """
    return HTTPException(
        status_code=status_code,
        detail=ErrorResponse(
            error=error, detail=detail, code=status_code, field=field
        ).model_dump(),
    )


def _unauthenticated() -> HTTPException:
    return http_error(status.HTTP_401_UNAUTHORIZED, "not_authenticated", "Authentication required")


def _project_not_found() -> HTTPException:
    # 404 (not 403) for a project the caller does not own: a 403 would confirm
    # the id names a real project, leaking which project ids exist across users.
    return http_error(status.HTTP_404_NOT_FOUND, "project_not_found", "No such project")


def _job_not_found() -> HTTPException:
    return http_error(status.HTTP_404_NOT_FOUND, "job_not_found", "No such job")


async def get_session_user(
    request: Request,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> User:
    """Resolve the caller from the session cookie, or raise 401.

    For what only the signed-in browser may do, the account itself and its API
    keys, so a leaked key can neither mint keys nor take over the account.
    Stashes SessionData on request.state so routes needing the CSRF token do not
    repeat the Redis lookup.
    """
    session_id = request.cookies.get(SESSION_COOKIE_NAME)
    if not session_id:
        raise _unauthenticated()
    session_data = await sessions.get_session(session_id)
    if session_data is None:
        raise _unauthenticated()
    user = await session.get(User, session_data.user_id)
    if user is None or not user.is_active:
        raise _unauthenticated()
    request.state.oc_session = session_data
    return user


_bearer = HTTPBearer(
    auto_error=False,
    description="An API key from the Account page: `Authorization: Bearer oc_…`",
)


async def get_current_user(
    request: Request,
    session: Annotated[AsyncSession, Depends(db_session)],
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
) -> User:
    """Resolve the caller from an API key when one is sent, else the session.

    A key request carries no cookie, so the CSRF middleware has nothing to
    defend and lets it through; a browser cannot attach this header cross-site.
    """
    if credentials is None:
        return await get_session_user(request, session)
    key = await session.scalar(
        select(ApiKey).where(ApiKey.key_hash == hash_key(credentials.credentials))
    )
    user = await session.get(User, key.user_id) if key else None
    if key is None or user is None or not user.is_active:
        raise _unauthenticated()
    # Committed with the request, like every other write.
    key.last_used_at = datetime.now(UTC)
    return user


async def get_owned_project(
    project_id: Annotated[UUID, Path()],
    user: Annotated[User, Depends(get_current_user)],
    session: Annotated[AsyncSession, Depends(db_session)],
) -> Project:
    """Load a project and enforce ownership, else 404.

    Missing and not-owned are indistinguishable to the caller, so no route can
    disclose existence.
    """
    proj = await session.get(Project, project_id)
    if proj is None or proj.owner_id != user.id:
        raise _project_not_found()
    return proj


async def get_owned_job(
    job_id: Annotated[UUID, Path()],
    user: Annotated[User, Depends(get_current_user)],
    session: Annotated[AsyncSession, Depends(db_session)],
) -> Job:
    """Load a job only if the caller owns it, else 404.

    A job's owner is the user it was made for, or, for one made before jobs had an
    owner of their own, the owner of its project.
    """
    job = await session.get(Job, job_id)
    # "deleted": its data is gone and the row is kept only for the account's usage.
    if job is None or job.status == "deleted":
        raise _job_not_found()
    owner = job.user_id
    if owner is None and job.project_id is not None:
        proj = await session.get(Project, job.project_id)
        owner = proj.owner_id if proj is not None else None
    if owner != user.id:
        raise _job_not_found()
    return job


async def require_job_token(
    job_id: Annotated[UUID, Path()],
    x_job_token: Annotated[str | None, Header()] = None,
) -> None:
    """Authorize the engine's progress callback via its per-job token.

    A service, not a user session: the token is scoped to one job and
    short-lived, so there is no shared secret to configure.
    """
    if not await verify_job_token(str(job_id), x_job_token):
        raise http_error(
            status.HTTP_401_UNAUTHORIZED, "not_authenticated", "Invalid or missing job token"
        )


__all__ = [
    "CSRF_HEADER_NAME",
    "SESSION_COOKIE_NAME",
    "Depends",
    "db_session",
    "get_current_user",
    "get_owned_job",
    "get_owned_project",
    "require_job_token",
]
