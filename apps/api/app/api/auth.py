"""/api/v1/auth — registration, login, logout, current user, bootstrap status.

Sessions are server-side and opaque; the cookie holds only a random id. Login
rotates that id (session fixation) and rehashes the password if Argon2
parameters have moved on. Nothing here logs a password, session id or address.
"""

from __future__ import annotations

import ipaddress
import logging
from typing import Annotated
from uuid import uuid4

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request, Response, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import SESSION_COOKIE_NAME, db_session, get_session_user, http_error
from app.core import reset_tokens, security, sessions, throttle
from app.core.config import settings
from app.core.sessions import ABSOLUTE_TTL_SECONDS
from app.models import Project, User
from app.models.schemas import (
    _400_INVALID_RESET_TOKEN,
    _401_UNAUTHENTICATED,
    _403_FORBIDDEN,
    _404_RESET_UNAVAILABLE,
    _409_EMAIL_TAKEN,
    _429_RATE_LIMITED,
    AuthResponse,
    AuthStatus,
    ChangeEmailRequest,
    ChangePasswordRequest,
    LoginRequest,
    PasswordResetConfirm,
    PasswordResetRequest,
    RegisterRequest,
    UsageRead,
    UserRead,
)
from app.services import mailer
from app.services.usage import (
    UNIT_RENDER_FRAMES,
    UNIT_TRANSCRIPTION_SECONDS,
    sum_usage_for_user,
)

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/auth", tags=["auth"])


def _set_session_cookie(response: Response, session_id: str) -> None:
    # max_age is the ABSOLUTE cap; the server also enforces a sliding idle TTL
    # in Redis, so an idle session dies server-side even while the cookie lives.
    response.set_cookie(
        key=SESSION_COOKIE_NAME,
        value=session_id,
        max_age=ABSOLUTE_TTL_SECONDS,
        httponly=True,
        samesite="lax",
        secure=settings.session_cookie_secure,
        path="/",
    )


def _clear_session_cookie(response: Response) -> None:
    response.delete_cookie(
        key=SESSION_COOKIE_NAME,
        httponly=True,
        samesite="lax",
        secure=settings.session_cookie_secure,
        path="/",
    )


async def _user_count(session: AsyncSession) -> int:
    return int((await session.scalar(select(func.count()).select_from(User))) or 0)


def _invalid_credentials() -> HTTPException:
    return http_error(
        status.HTTP_401_UNAUTHORIZED, "invalid_credentials", "Invalid email or password"
    )


# Only genuine credential-guessing feeds the failure counter, and that lives
# solely at /login — so there is a single throttle scope. See register() for
# why registration rejections deliberately do not count.
_LOGIN_SCOPE = "login"


def _rate_limited() -> HTTPException:
    # Applied identically whether or not the email names an account, and checked
    # before the lookup, so it is no existence or throttle oracle.
    return http_error(
        status.HTTP_429_TOO_MANY_REQUESTS,
        "rate_limited",
        "Too many attempts. Please try again later.",
    )


# Separate from _LOGIN_SCOPE: a per-source ceiling on the two endpoints that each
# run an Argon2id hash (~19 MiB) per request, so one address cannot amplify cheap
# requests into a hashing DoS. It counts every attempt rather than only failures
# and is never cleared by a success, which is why it cannot be merged with the
# per-email throttle.
_AUTH_IP_SCOPE = "auth_ip"


def _is_trusted_proxy_peer(peer: str) -> bool:
    """Whether the socket peer is an in-network proxy allowed to set X-Real-IP.

    A public peer means the request arrived directly, with no proxy to overwrite
    a client-supplied header, so it must not be trusted.
    """
    try:
        addr = ipaddress.ip_address(peer)
    except ValueError:
        return False
    return addr.is_loopback or addr.is_private


def _client_ip(request: Request) -> str:
    """Best-effort source address for the per-source ceiling.

    uvicorn does not run with --proxy-headers, so request.client.host is the
    socket peer — nginx, identical for every caller. nginx sets X-Real-IP with
    proxy_set_header, which REPLACES any client-supplied value, so the header is
    trustworthy through the proxy and only through it.
    """
    client = request.client
    peer = client.host if client else None
    if peer is not None and _is_trusted_proxy_peer(peer):
        real_ip = request.headers.get("x-real-ip")
        if real_ip:
            return real_ip.strip()
    return peer or "unknown"


async def _enforce_ip_ceiling(request: Request) -> None:
    """Apply the per-source ceiling before the expensive hash runs."""
    ip = _client_ip(request)
    if await throttle.is_rate_limited(
        _AUTH_IP_SCOPE, ip, limit=settings.auth_ip_throttle_max_attempts
    ):
        logger.warning("auth throttled: per-source-IP ceiling reached")
        raise _rate_limited()
    await throttle.record_attempt(_AUTH_IP_SCOPE, ip, window_s=settings.auth_ip_throttle_window_s)


@router.get("/status", response_model=AuthStatus, summary="Auth bootstrap status")
async def auth_status(
    session: Annotated[AsyncSession, Depends(db_session)],
) -> AuthStatus:
    """Public: lets the SPA offer first-run signup without probing a 401."""
    return AuthStatus(
        setup_required=(await _user_count(session)) == 0,
        registration_enabled=settings.registration_enabled,
        hosted_mode=settings.hosted_mode,
        reset_available=settings.smtp_configured,
    )


@router.post(
    "/register",
    response_model=AuthResponse,
    status_code=status.HTTP_201_CREATED,
    responses={**_403_FORBIDDEN, **_409_EMAIL_TAKEN, **_429_RATE_LIMITED},
    summary="Register an account",
)
async def register(
    body: RegisterRequest,
    request: Request,
    response: Response,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> AuthResponse:
    """Create an account.

    The first one is allowed even with registration off, so a closed instance
    can still be bootstrapped.
    """
    # The per-source ceiling is the only throttle register carries. It is not
    # throttled per email: every rejection here (403 disabled, 409 taken) is a
    # policy signal rather than credential guessing, and signup spam varies the
    # email anyway, so an email-keyed counter would deter nothing.
    await _enforce_ip_ceiling(request)

    is_first = (await _user_count(session)) == 0
    if not is_first and not settings.registration_enabled:
        raise http_error(
            status.HTTP_403_FORBIDDEN,
            "registration_disabled",
            "Self-service registration is disabled",
        )

    existing = await session.scalar(select(User).where(User.email == body.email))
    if existing is not None:
        raise http_error(status.HTTP_409_CONFLICT, "email_taken", "Email already registered")

    user = User(
        email=body.email,
        password_hash=security.hash_password(body.password),
        is_active=True,
    )
    session.add(user)
    await session.flush()

    # Session fixation: drop any pre-existing session id before issuing a new one.
    old = request.cookies.get(SESSION_COOKIE_NAME)
    if old:
        await sessions.delete_session(old)
    session_id, csrf_token = await sessions.create_session(user.id)
    _set_session_cookie(response, session_id)
    logger.info("account registered id=%s", user.id)
    return AuthResponse(user=UserRead.model_validate(user), csrf_token=csrf_token)


@router.post(
    "/login",
    response_model=AuthResponse,
    responses={**_401_UNAUTHENTICATED, **_429_RATE_LIMITED},
    summary="Log in",
)
async def login(
    body: LoginRequest,
    request: Request,
    response: Response,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> AuthResponse:
    # Coarse per-source-IP ceiling first (see _AUTH_IP_SCOPE): a blunt anti-DoS
    # cap on expensive hashing per address, SEPARATE from — and additive to — the
    # per-identifier failure throttle below, which is left fully intact.
    await _enforce_ip_ceiling(request)

    # Brute-force ceiling: refuse once this email has burned its failure budget.
    # Checked before the account lookup and applied identically to real and
    # unknown emails, so it never becomes an existence/throttle oracle.
    if await throttle.is_rate_limited(_LOGIN_SCOPE, body.email):
        logger.warning("login throttled for a submitted email")
        raise _rate_limited()

    user = await session.scalar(select(User).where(User.email == body.email))
    # Generic failure: never reveal whether the email exists. Verify against a
    # dummy hash when the account is missing so response time doesn't leak it.
    if user is None or not user.is_active:
        security.verify_password(security.DUMMY_HASH, body.password)
        await throttle.record_failure(_LOGIN_SCOPE, body.email)
        logger.warning("login failed: no active account for a submitted email")
        raise _invalid_credentials()
    if not security.verify_password(user.password_hash, body.password):
        await throttle.record_failure(_LOGIN_SCOPE, body.email)
        logger.warning("login failed: bad password for user id=%s", user.id)
        raise _invalid_credentials()
    # Transparent upgrade if the Argon2 parameters have strengthened since signup.
    if security.needs_rehash(user.password_hash):
        user.password_hash = security.hash_password(body.password)

    # Rotate the session id on login (session fixation).
    old = request.cookies.get(SESSION_COOKIE_NAME)
    if old:
        await sessions.delete_session(old)
    session_id, csrf_token = await sessions.create_session(user.id)
    _set_session_cookie(response, session_id)
    await throttle.reset(_LOGIN_SCOPE, body.email)
    logger.info("login ok user id=%s", user.id)
    return AuthResponse(user=UserRead.model_validate(user), csrf_token=csrf_token)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT, summary="Log out")
async def logout(
    request: Request,
    _user: Annotated[User, Depends(get_session_user)],
) -> Response:
    """Delete the server-side session so its id can never be used again."""
    session_id = request.cookies.get(SESSION_COOKIE_NAME)
    if session_id:
        await sessions.delete_session(session_id)
    response = Response(status_code=status.HTTP_204_NO_CONTENT)
    _clear_session_cookie(response)
    return response


@router.get(
    "/me",
    response_model=AuthResponse,
    responses={**_401_UNAUTHENTICATED},
    summary="Current user",
)
async def me(
    request: Request,
    user: Annotated[User, Depends(get_session_user)],
) -> AuthResponse:
    # get_session_user stashed the SessionData (incl. the csrf token) on state.
    session_data: sessions.SessionData = request.state.oc_session
    return AuthResponse(user=UserRead.model_validate(user), csrf_token=session_data.csrf_token)


@router.get(
    "/me/usage",
    response_model=UsageRead,
    summary="Work this account has had done",
    responses={**_401_UNAUTHENTICATED},
)
async def my_usage(
    user: Annotated[User, Depends(get_session_user)],
    session: Annotated[AsyncSession, Depends(db_session)],
) -> UsageRead:
    """Totals from the durable per-job usage records, scoped to this owner."""
    projects = await session.scalar(
        select(func.count()).select_from(Project).where(Project.owner_id == user.id)
    )
    return UsageRead(
        transcription_seconds=await sum_usage_for_user(
            session, user.id, UNIT_TRANSCRIPTION_SECONDS
        ),
        render_frames=await sum_usage_for_user(session, user.id, UNIT_RENDER_FRAMES),
        projects=int(projects or 0),
    )


@router.patch(
    "/me/email",
    response_model=UserRead,
    summary="Change the account's email",
    responses={**_401_UNAUTHENTICATED, **_409_EMAIL_TAKEN},
)
async def change_email(
    body: ChangeEmailRequest,
    user: Annotated[User, Depends(get_session_user)],
    session: Annotated[AsyncSession, Depends(db_session)],
) -> UserRead:
    """Move the account to a new address, confirming the current password first.

    A session alone is not enough: an attacker holding one could otherwise change
    the address and then use password reset to take the account outright.
    """
    if not security.verify_password(user.password_hash, body.current_password):
        raise _invalid_credentials()
    if body.email != user.email:
        taken = await session.scalar(select(User).where(User.email == body.email))
        if taken is not None:
            raise http_error(status.HTTP_409_CONFLICT, "email_taken", "Email already registered")
    user.email = body.email
    await session.flush()
    logger.info("email changed for user id=%s", user.id)
    return UserRead.model_validate(user)


@router.patch(
    "/me/password",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Change the account's password",
    responses={**_401_UNAUTHENTICATED},
)
async def change_password(
    body: ChangePasswordRequest,
    request: Request,
    user: Annotated[User, Depends(get_session_user)],
    session: Annotated[AsyncSession, Depends(db_session)],
) -> None:
    """Set a new password, keeping only the session that made the change.

    Every other session is revoked, as on a reset: a password change is often a
    response to suspicion, so sessions opened before it must not survive it.
    """
    if not security.verify_password(user.password_hash, body.current_password):
        raise _invalid_credentials()
    user.password_hash = security.hash_password(body.new_password)
    await session.flush()
    current = request.cookies.get(SESSION_COOKIE_NAME)
    revoked = await sessions.delete_user_sessions(user.id, keep=current)
    logger.info("password changed user id=%s (%d other session(s) revoked)", user.id, revoked)


# Available only when SMTP is configured; both endpoints return a uniform 404
# otherwise. Neither is an enumeration oracle: the request endpoint answers
# identically for unknown emails and every bad-token case collapses to one error.


def _reset_unavailable() -> HTTPException:
    # Uniform refusal when SMTP is unconfigured. Independent of any email, so it
    # is never an enumeration oracle.
    return http_error(
        status.HTTP_404_NOT_FOUND,
        "reset_unavailable",
        "Password reset is not available on this instance",
    )


def _invalid_reset_token() -> HTTPException:
    # One generic failure for every bad-token case (unknown, expired, already
    # used, malformed, or naming a vanished account) so none is distinguishable.
    return http_error(
        status.HTTP_400_BAD_REQUEST,
        "invalid_reset_token",
        "This password reset link is invalid or has expired",
    )


_RESET_EMAIL_SUBJECT = "Reset your OpenCaptions password"


def _reset_email_body(link: str) -> str:
    return (
        "Someone requested a password reset for your OpenCaptions account.\n\n"
        "To choose a new password, open this link (it expires in one hour):\n\n"
        f"{link}\n\n"
        "If you did not request this, you can ignore this email — your password "
        "will not change."
    )


def _send_reset_email(to: str, link: str) -> None:
    """Send the reset email. Runs in a background task, OFF the request path, so
    a slow or failing relay never changes the response the user already received.
    A failure is swallowed and logged by exception type only — never the
    recipient, the link, or the token."""
    try:
        mailer.resolve_mailer().send(
            to=to, subject=_RESET_EMAIL_SUBJECT, body=_reset_email_body(link)
        )
    except Exception as exc:  # noqa: BLE001 — a broken relay must not surface to the user
        logger.warning("password reset email failed to send: %s", type(exc).__name__)


@router.post(
    "/password-reset",
    status_code=status.HTTP_204_NO_CONTENT,
    responses={**_404_RESET_UNAVAILABLE, **_429_RATE_LIMITED},
    summary="Request a password reset link",
)
async def request_password_reset(
    body: PasswordResetRequest,
    request: Request,
    background_tasks: BackgroundTasks,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> Response:
    """Email a single-use reset link, when SMTP is configured.

    The response is identical whether or not the email names an account.
    """
    if not settings.smtp_configured:
        raise _reset_unavailable()
    await _enforce_ip_ceiling(request)

    user = await session.scalar(select(User).where(User.email == body.email))
    # Mint a token in both branches so the Redis write is not a signal, and defer
    # the SMTP send to a background task so its latency cannot be one either.
    is_active_account = user is not None and user.is_active
    token = await reset_tokens.issue(user.id if is_active_account and user else uuid4())
    if is_active_account and user is not None:
        link = f"{settings.reset_link_base_url}/reset-password?token={token}"
        background_tasks.add_task(_send_reset_email, user.email, link)
    logger.info("password reset requested")
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post(
    "/password-reset/confirm",
    status_code=status.HTTP_204_NO_CONTENT,
    responses={**_404_RESET_UNAVAILABLE, **_400_INVALID_RESET_TOKEN, **_429_RATE_LIMITED},
    summary="Set a new password from a reset token",
)
async def confirm_password_reset(
    body: PasswordResetConfirm,
    request: Request,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> Response:
    """Redeem a single-use reset token and set a new password.

    Expiry is enforced here, not only at issue, and every existing session is
    revoked: a reset is often a response to compromise.
    """
    if not settings.smtp_configured:
        raise _reset_unavailable()
    await _enforce_ip_ceiling(request)

    user_id = await reset_tokens.redeem(body.token)
    if user_id is None:
        raise _invalid_reset_token()
    user = await session.get(User, user_id)
    if user is None or not user.is_active:
        raise _invalid_reset_token()

    # Server-side policy is enforced by PasswordResetConfirm.password (identical
    # min/max to registration); by here the new password already satisfies it.
    user.password_hash = security.hash_password(body.password)
    await session.flush()
    # Revoke every live session for this user (reuses the helper introduced for
    # the deleted admin work): a compromised old password's sessions must not
    # survive the reset.
    revoked = await sessions.delete_user_sessions(user.id)
    logger.info("password reset completed user id=%s (%d session(s) revoked)", user.id, revoked)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
