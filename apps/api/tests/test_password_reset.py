"""Self-service password reset.

Covers the whole flow against the real auth/session logic (the conftest fixtures
swap only the backing stores): availability gating on SMTP, the no-enumeration
guarantee, single-use and expiring tokens, all-sessions revocation on success,
the server-side password policy, and the shared per-IP rate ceiling.
"""

from __future__ import annotations

import re
from typing import Any

import pytest
from httpx import AsyncClient

from app.core.config import settings
from app.services import mailer


class _RecordingMailer:
    """Captures outbound mail instead of talking to SMTP, so a test can read the
    reset link back out of the message body."""

    name = "recording"

    def __init__(self) -> None:
        self.sent: list[dict[str, str]] = []

    def send(self, *, to: str, subject: str, body: str) -> None:
        self.sent.append({"to": to, "subject": subject, "body": body})


@pytest.fixture
def smtp_enabled(monkeypatch: Any) -> _RecordingMailer:
    """Turn SMTP on (so the flow is available) and capture outbound mail."""
    monkeypatch.setattr(settings, "smtp_host", "smtp.test")
    monkeypatch.setattr(settings, "public_base_url", "http://testserver")
    recorder = _RecordingMailer()
    monkeypatch.setattr(mailer, "resolve_mailer", lambda: recorder)
    return recorder


def _token_from(body: str) -> str:
    match = re.search(r"token=(\S+)", body)
    assert match, f"no reset token found in email body: {body!r}"
    return match.group(1)


@pytest.mark.asyncio
async def test_status_reports_reset_unavailable_without_smtp(client: AsyncClient) -> None:
    r = await client.get("/api/v1/auth/status")
    assert r.status_code == 200
    assert r.json()["reset_available"] is False


@pytest.mark.asyncio
async def test_status_reports_reset_available_with_smtp(
    client: AsyncClient, smtp_enabled: _RecordingMailer
) -> None:
    r = await client.get("/api/v1/auth/status")
    assert r.status_code == 200
    # The boolean is all that leaks — never the host, port, or credentials.
    body = r.json()
    assert body["reset_available"] is True
    assert not any("smtp" in k.lower() for k in body)


@pytest.mark.asyncio
async def test_endpoints_unavailable_without_smtp(client: AsyncClient) -> None:
    # With SMTP unset the flow does not exist: both endpoints refuse uniformly.
    r1 = await client.post("/api/v1/auth/password-reset", json={"email": "a@example.com"})
    assert r1.status_code == 404
    assert r1.json()["error"] == "reset_unavailable"

    r2 = await client.post(
        "/api/v1/auth/password-reset/confirm",
        json={"token": "sel.ver", "password": "irrelevant123"},
    )
    assert r2.status_code == 404
    assert r2.json()["error"] == "reset_unavailable"


@pytest.mark.asyncio
async def test_request_response_identical_for_known_and_unknown_email(
    first_client: AsyncClient, make_client: Any, smtp_enabled: _RecordingMailer
) -> None:
    # No enumeration oracle: the same status and empty body whether or not the
    # email names an account — but a link is sent ONLY for the real account.
    c = await make_client()
    known = await c.post("/api/v1/auth/password-reset", json={"email": "admin@example.com"})
    unknown = await c.post("/api/v1/auth/password-reset", json={"email": "nobody@example.com"})

    assert known.status_code == unknown.status_code == 204
    assert known.content == unknown.content == b""
    assert [m["to"] for m in smtp_enabled.sent] == ["admin@example.com"]


@pytest.mark.asyncio
async def test_token_is_single_use(
    first_client: AsyncClient, make_client: Any, smtp_enabled: _RecordingMailer
) -> None:
    c = await make_client()
    await c.post("/api/v1/auth/password-reset", json={"email": "admin@example.com"})
    token = _token_from(smtp_enabled.sent[0]["body"])

    first = await c.post(
        "/api/v1/auth/password-reset/confirm",
        json={"token": token, "password": "new-password-123"},
    )
    assert first.status_code == 204

    # The same token cannot be redeemed a second time.
    replay = await c.post(
        "/api/v1/auth/password-reset/confirm",
        json={"token": token, "password": "another-password-123"},
    )
    assert replay.status_code == 400
    assert replay.json()["error"] == "invalid_reset_token"


@pytest.mark.asyncio
async def test_expired_token_is_refused(
    first_client: AsyncClient, make_client: Any, smtp_enabled: _RecordingMailer, fake_redis: Any
) -> None:
    c = await make_client()
    await c.post("/api/v1/auth/password-reset", json={"email": "admin@example.com"})
    token = _token_from(smtp_enabled.sent[0]["body"])

    # Simulate the TTL lapsing: Redis drops an expired key, so redemption misses.
    # This proves expiry is enforced AT REDEMPTION, not merely stamped at issue.
    async for key in fake_redis.scan_iter(match="opencaptions:reset:*"):
        await fake_redis.delete(key)

    r = await c.post(
        "/api/v1/auth/password-reset/confirm",
        json={"token": token, "password": "new-password-123"},
    )
    assert r.status_code == 400
    assert r.json()["error"] == "invalid_reset_token"


@pytest.mark.asyncio
async def test_reset_revokes_sessions_and_rotates_password(
    first_client: AsyncClient, make_client: Any, smtp_enabled: _RecordingMailer
) -> None:
    # first_client is admin@example.com (password adminpassword123) with a live
    # session. Capture that session id before the reset.
    assert (await first_client.get("/api/v1/auth/me")).status_code == 200
    pre_reset_session = first_client.cookies.get("oc_session")
    assert pre_reset_session

    requester = await make_client()
    await requester.post("/api/v1/auth/password-reset", json={"email": "admin@example.com"})
    token = _token_from(smtp_enabled.sent[0]["body"])
    confirm = await requester.post(
        "/api/v1/auth/password-reset/confirm",
        json={"token": token, "password": "brand-new-password-123"},
    )
    assert confirm.status_code == 204

    # The session that existed BEFORE the reset is now dead server-side.
    replay = await make_client()
    replay.cookies.set("oc_session", pre_reset_session)
    assert (await replay.get("/api/v1/auth/me")).status_code == 401

    # The new password logs in; the old one no longer does.
    login_new = await make_client()
    assert (
        await login_new.post(
            "/api/v1/auth/login",
            json={"email": "admin@example.com", "password": "brand-new-password-123"},
        )
    ).status_code == 200
    login_old = await make_client()
    assert (
        await login_old.post(
            "/api/v1/auth/login",
            json={"email": "admin@example.com", "password": "adminpassword123"},
        )
    ).status_code == 401


@pytest.mark.asyncio
async def test_confirm_enforces_registration_password_policy(
    first_client: AsyncClient, make_client: Any, smtp_enabled: _RecordingMailer
) -> None:
    c = await make_client()
    await c.post("/api/v1/auth/password-reset", json={"email": "admin@example.com"})
    token = _token_from(smtp_enabled.sent[0]["body"])

    # Below the 8-char registration minimum — rejected server-side (422) before
    # the handler runs, so a client-side check is never the only control.
    too_short = await c.post(
        "/api/v1/auth/password-reset/confirm",
        json={"token": token, "password": "short"},
    )
    assert too_short.status_code == 422

    # The rejected attempt did not consume the token: a compliant password works.
    ok = await c.post(
        "/api/v1/auth/password-reset/confirm",
        json={"token": token, "password": "long-enough-123"},
    )
    assert ok.status_code == 204


@pytest.mark.asyncio
async def test_reset_endpoints_share_the_per_ip_ceiling(
    client: AsyncClient, smtp_enabled: _RecordingMailer, monkeypatch: Any
) -> None:
    # Both new endpoints extend the SAME coarse per-source-IP ceiling that already
    # guards register/login, rather than inventing a second mechanism.
    monkeypatch.setattr(settings, "auth_ip_throttle_max_attempts", 2)
    assert (
        await client.post("/api/v1/auth/password-reset", json={"email": "n@example.com"})
    ).status_code == 204
    assert (
        await client.post("/api/v1/auth/password-reset", json={"email": "n@example.com"})
    ).status_code == 204

    # The third call across either reset endpoint is refused generically.
    blocked = await client.post(
        "/api/v1/auth/password-reset/confirm",
        json={"token": "sel.ver", "password": "irrelevant123"},
    )
    assert blocked.status_code == 429
    assert blocked.json()["error"] == "rate_limited"
