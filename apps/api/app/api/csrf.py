"""CSRF protection middleware (per-session token on unsafe methods).

SameSite=Lax on the session cookie is necessary but not sufficient: it does not
cover state-changing GETs and it treats sibling subdomains as same-site, which
matters for a future multi-tenant hosted deployment. So every unsafe method
(POST/PUT/PATCH/DELETE) must additionally carry an X-CSRF-Token header matching
the token bound to the caller's server-side session.

Implemented as a pure-ASGI middleware (not BaseHTTPMiddleware) so it never
buffers or wraps response bodies, the app streams video via HTTP Range
responses, and wrapping those would break seeking. WebSocket upgrades never pass
through here (the 'websocket' scope is skipped; WS does its own cookie auth).

Exemptions:
  * /auth/register, /auth/login: no session exists yet, so there is no token
    to present; these are what create the session.
  * /auth/password-reset, /auth/password-reset/confirm, the caller is logged
    out (they forgot their password), so there is no session token to present.
  * /jobs/{id}/progress: the engine's service callback, authorized by its
    per-job token instead (see app.core.job_tokens); browsers can't reach it.
"""

from __future__ import annotations

from hmac import compare_digest

from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

from app.api.deps import CSRF_HEADER_NAME, SESSION_COOKIE_NAME
from app.core import sessions
from app.models.schemas import ErrorResponse

_SAFE_METHODS = frozenset({"GET", "HEAD", "OPTIONS", "TRACE"})
_EXEMPT_PATHS = frozenset({"/api/v1/auth/register", "/api/v1/auth/login"})


def _is_exempt(path: str) -> bool:
    if path in _EXEMPT_PATHS:
        return True
    # Password reset request + confirm: the caller is logged out, so there is no
    # session and no CSRF token to present, like register/login. Covers both
    # /auth/password-reset and /auth/password-reset/confirm.
    if path.startswith("/api/v1/auth/password-reset"):
        return True
    # Engine progress callback: /api/v1/jobs/{job_id}/progress
    return path.startswith("/api/v1/jobs/") and path.endswith("/progress")


class CSRFMiddleware:
    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        method = scope.get("method", "GET")
        path = scope.get("path", "")
        if method in _SAFE_METHODS or _is_exempt(path):
            await self.app(scope, receive, send)
            return

        request = Request(scope)
        session_id = request.cookies.get(SESSION_COOKIE_NAME)
        # No session cookie → let the auth dependency answer with 401 rather than
        # a confusing CSRF 403. CSRF only defends an EXISTING authenticated
        # session (the cookie a browser would auto-attach on a forged request).
        if session_id:
            header_token = request.headers.get(CSRF_HEADER_NAME)
            session_data = await sessions.get_session(session_id)
            if (
                session_data is None
                or not header_token
                or not compare_digest(header_token, session_data.csrf_token)
            ):
                response = JSONResponse(
                    status_code=403,
                    content=ErrorResponse(
                        error="csrf_failed",
                        detail="Missing or invalid CSRF token",
                        code=403,
                    ).model_dump(),
                )
                await response(scope, receive, send)
                return

        await self.app(scope, receive, send)
