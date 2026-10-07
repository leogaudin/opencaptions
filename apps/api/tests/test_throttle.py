"""Throttling of failed logins: the ceiling fires, it is keyed per identifier,
a success clears it, and registration rejections never feed it."""

from __future__ import annotations

from typing import Any

import pytest
from httpx import AsyncClient

from app.core.config import settings

WRONG = {"email": "admin@example.com", "password": "definitely-wrong-pw"}


async def _login(c: AsyncClient, email: str, password: str) -> int:
    r = await c.post("/api/v1/auth/login", json={"email": email, "password": password})
    return r.status_code


@pytest.mark.asyncio
async def test_login_throttled_after_limit(
    first_client: AsyncClient, make_client: Any, monkeypatch: Any
) -> None:
    monkeypatch.setattr(settings, "auth_throttle_max_attempts", 3)
    attacker = await make_client()
    for _ in range(3):
        assert await _login(attacker, "admin@example.com", "wrong-pw") == 401
    # The budget is spent, further attempts are refused generically with 429,
    # even a would-be correct one.
    r = await attacker.post("/api/v1/auth/login", json=WRONG)
    assert r.status_code == 429
    assert r.json()["error"] == "rate_limited"
    correct = await attacker.post(
        "/api/v1/auth/login",
        json={"email": "admin@example.com", "password": "adminpassword123"},
    )
    assert correct.status_code == 429


@pytest.mark.asyncio
async def test_throttle_is_generic_for_unknown_email(
    first_client: AsyncClient, make_client: Any, monkeypatch: Any
) -> None:
    # An email that names no account throttles on the SAME schedule and with the
    # SAME status codes as a real one, so the throttle reveals nothing about
    # whether the account exists.
    monkeypatch.setattr(settings, "auth_throttle_max_attempts", 3)
    c = await make_client()
    for _ in range(3):
        assert await _login(c, "ghost@example.com", "whatever12345") == 401
    r = await c.post(
        "/api/v1/auth/login",
        json={"email": "ghost@example.com", "password": "whatever12345"},
    )
    assert r.status_code == 429
    assert r.json()["error"] == "rate_limited"


@pytest.mark.asyncio
async def test_throttle_is_per_identifier(
    first_client: AsyncClient, make_client: Any, monkeypatch: Any
) -> None:
    monkeypatch.setattr(settings, "auth_throttle_max_attempts", 3)
    c = await make_client()
    # Exhaust email A.
    for _ in range(3):
        assert await _login(c, "victim@example.com", "wrong") == 401
    assert await _login(c, "victim@example.com", "wrong") == 429
    # A DIFFERENT identifier is unaffected, one user's failures can't lock out
    # everyone.
    assert await _login(c, "someone-else@example.com", "wrong") == 401


@pytest.mark.asyncio
async def test_successful_login_resets_counter(
    first_client: AsyncClient, make_client: Any, monkeypatch: Any
) -> None:
    monkeypatch.setattr(settings, "auth_throttle_max_attempts", 3)
    c = await make_client()
    # Two failures, still under the limit.
    for _ in range(2):
        assert await _login(c, "admin@example.com", "wrong-pw") == 401
    # A success clears the counter.
    assert await _login(c, "admin@example.com", "adminpassword123") == 200
    # Now the budget is full again: three more failures are allowed before 429.
    for _ in range(3):
        assert await _login(c, "admin@example.com", "wrong-pw") == 401
    assert await _login(c, "admin@example.com", "wrong-pw") == 429


@pytest.mark.asyncio
async def test_registration_rejections_do_not_throttle(
    first_client: AsyncClient, make_client: Any, monkeypatch: Any
) -> None:
    # Policy signals, not credential guessing: they must never feed the counter.
    monkeypatch.setattr(settings, "auth_throttle_max_attempts", 3)
    monkeypatch.setattr(settings, "registration_enabled", False)
    c = await make_client()
    for _ in range(6):  # well past the limit of 3
        r = await c.post(
            "/api/v1/auth/register",
            json={"email": "probe@example.com", "password": "password123"},
        )
        assert r.status_code == 403
        assert r.json()["error"] == "registration_disabled"


@pytest.mark.asyncio
async def test_duplicate_registration_does_not_throttle(
    first_client: AsyncClient, make_client: Any, monkeypatch: Any
) -> None:
    # A taken email is not an attack; registration stays enabled here on purpose.
    monkeypatch.setattr(settings, "auth_throttle_max_attempts", 3)
    monkeypatch.setattr(settings, "registration_enabled", True)
    for _ in range(5):  # past the limit of 3
        dup = await make_client()
        r = await dup.post(
            "/api/v1/auth/register",
            json={"email": "admin@example.com", "password": "adminpassword123"},
        )
        assert r.status_code == 409
        assert r.json()["error"] == "email_taken"
    login = await make_client()
    r = await login.post(
        "/api/v1/auth/login",
        json={"email": "admin@example.com", "password": "adminpassword123"},
    )
    assert r.status_code == 200


# ----- Atomic TTL: a counter can never be left without an expiry -----


@pytest.mark.asyncio
async def test_record_failure_key_always_has_ttl(fake_redis: Any) -> None:
    """The counter is created with its expiry, so it can never wedge forever."""
    from app.core import throttle

    key = throttle._key("login", "ttl@example.com")
    await throttle.record_failure("login", "ttl@example.com")
    assert await fake_redis.ttl(key) > 0
    await throttle.record_failure("login", "ttl@example.com")
    assert await fake_redis.ttl(key) > 0


@pytest.mark.asyncio
async def test_record_attempt_sets_ttl_from_window(fake_redis: Any) -> None:
    """The per-IP attempt counter also carries a TTL, bounded by its window."""
    from app.core import throttle

    key = throttle._key("auth_ip", "203.0.113.7")
    await throttle.record_attempt("auth_ip", "203.0.113.7", window_s=123)
    ttl = await fake_redis.ttl(key)
    assert 0 < ttl <= 123


# ----- Per-source-IP ceiling (separate from the per-identifier throttle) -----


@pytest.mark.asyncio
async def test_per_ip_ceiling_engages_regardless_of_identifier(
    first_client: AsyncClient, make_client: Any, monkeypatch: Any
) -> None:
    # A single address is capped even when it varies the email on every attempt,
    # proving it is the ADDRESS being throttled, not the identifier (so the
    # per-identifier throttle, which such an attacker sidesteps, never fires).
    monkeypatch.setattr(settings, "auth_ip_throttle_max_attempts", 3)
    c = await make_client()
    ip = {"X-Real-IP": "203.0.113.10"}
    for i in range(3):
        r = await c.post(
            "/api/v1/auth/login",
            json={"email": f"nobody{i}@example.com", "password": "whatever12345"},
            headers=ip,
        )
        assert r.status_code == 401
    r = await c.post(
        "/api/v1/auth/login",
        json={"email": "brandnew@example.com", "password": "whatever12345"},
        headers=ip,
    )
    assert r.status_code == 429
    assert r.json()["error"] == "rate_limited"


@pytest.mark.asyncio
async def test_per_ip_ceiling_is_isolated_across_addresses(
    first_client: AsyncClient, make_client: Any, monkeypatch: Any
) -> None:
    # One address hitting the ceiling must not affect a different address.
    monkeypatch.setattr(settings, "auth_ip_throttle_max_attempts", 3)
    c = await make_client()
    attacker = {"X-Real-IP": "203.0.113.20"}
    for _ in range(3):
        assert (
            await c.post(
                "/api/v1/auth/login",
                json={"email": "nobody@example.com", "password": "whatever12345"},
                headers=attacker,
            )
        ).status_code == 401
    assert (
        await c.post(
            "/api/v1/auth/login",
            json={"email": "nobody@example.com", "password": "whatever12345"},
            headers=attacker,
        )
    ).status_code == 429
    # A DIFFERENT source address is unaffected.
    other = {"X-Real-IP": "203.0.113.99"}
    assert (
        await c.post(
            "/api/v1/auth/login",
            json={"email": "nobody@example.com", "password": "whatever12345"},
            headers=other,
        )
    ).status_code == 401


@pytest.mark.asyncio
async def test_per_ip_ceiling_covers_register(
    first_client: AsyncClient, make_client: Any, monkeypatch: Any
) -> None:
    # register shares the same per-source scope as login.
    monkeypatch.setattr(settings, "auth_ip_throttle_max_attempts", 3)
    monkeypatch.setattr(settings, "registration_enabled", False)
    c = await make_client()
    ip = {"X-Real-IP": "198.51.100.5"}
    for _ in range(3):
        r = await c.post(
            "/api/v1/auth/register",
            json={"email": "probe@example.com", "password": "password123"},
            headers=ip,
        )
        assert r.status_code == 403
        assert r.json()["error"] == "registration_disabled"
    r = await c.post(
        "/api/v1/auth/register",
        json={"email": "probe@example.com", "password": "password123"},
        headers=ip,
    )
    assert r.status_code == 429
    assert r.json()["error"] == "rate_limited"


@pytest.mark.asyncio
async def test_per_ip_ceiling_counts_successful_logins_too(
    first_client: AsyncClient, make_client: Any, monkeypatch: Any
) -> None:
    # Unlike the per-identifier failure throttle, the per-IP ceiling caps
    # expensive WORK, so it counts successes and a success does not refund the
    # budget. Two good logins from one address then a third trips a limit of 2.
    monkeypatch.setattr(settings, "auth_ip_throttle_max_attempts", 2)
    ip = {"X-Real-IP": "203.0.113.30"}
    creds = {"email": "admin@example.com", "password": "adminpassword123"}
    c1 = await make_client()
    assert (await c1.post("/api/v1/auth/login", json=creds, headers=ip)).status_code == 200
    c2 = await make_client()
    assert (await c2.post("/api/v1/auth/login", json=creds, headers=ip)).status_code == 200
    c3 = await make_client()
    assert (await c3.post("/api/v1/auth/login", json=creds, headers=ip)).status_code == 429
