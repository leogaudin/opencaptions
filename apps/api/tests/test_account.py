"""Account self-service: usage, email change, password change.

The properties under test are the ones a session alone must not buy: changing an
address or a password requires proving the current password, because a hijacked
session could otherwise take the account outright via password reset.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

import pytest
from httpx import AsyncClient


@pytest.mark.asyncio
async def test_usage_starts_at_zero_and_counts_own_projects(
    user_a: tuple[AsyncClient, UUID],
    seed_project: Any,
) -> None:
    client, owner_id = user_a
    r = await client.get("/api/v1/auth/me/usage")
    assert r.status_code == 200, r.text
    assert r.json() == {"transcription_seconds": 0.0, "render_frames": 0.0, "projects": 0}

    await seed_project(owner_id)
    assert (await client.get("/api/v1/auth/me/usage")).json()["projects"] == 1


@pytest.mark.asyncio
async def test_usage_requires_a_session(client: AsyncClient) -> None:
    assert (await client.get("/api/v1/auth/me/usage")).status_code == 401


@pytest.mark.asyncio
async def test_email_change_needs_the_current_password(
    user_a: tuple[AsyncClient, UUID],
) -> None:
    client, _ = user_a
    wrong = await client.patch(
        "/api/v1/auth/me/email",
        json={"email": "moved@example.com", "current_password": "not-the-password"},
    )
    assert wrong.status_code == 401
    assert wrong.json()["error"] == "invalid_credentials"
    # The address must be unchanged after a refused attempt.
    assert (await client.get("/api/v1/auth/me")).json()["user"]["email"] != "moved@example.com"


@pytest.mark.asyncio
async def test_email_change_normalises_and_rejects_a_taken_address(
    user_a: tuple[AsyncClient, UUID],
    user_b_client: AsyncClient,
) -> None:
    client, _ = user_a
    other = (await user_b_client.get("/api/v1/auth/me")).json()["user"]["email"]

    taken = await client.patch(
        "/api/v1/auth/me/email",
        json={"email": other.upper(), "current_password": "adminpassword123"},
    )
    assert taken.status_code == 409, taken.text
    assert taken.json()["error"] == "email_taken"

    ok = await client.patch(
        "/api/v1/auth/me/email",
        json={"email": "  MOVED@Example.COM  ", "current_password": "adminpassword123"},
    )
    assert ok.status_code == 200, ok.text
    # Stored lowercase, like registration, or the account stops matching its own login.
    assert ok.json()["email"] == "moved@example.com"


@pytest.mark.asyncio
async def test_password_change_needs_the_current_password_and_then_works(
    user_a: tuple[AsyncClient, UUID],
) -> None:
    client, _ = user_a
    wrong = await client.patch(
        "/api/v1/auth/me/password",
        json={"current_password": "not-it", "new_password": "a-brand-new-password"},
    )
    assert wrong.status_code == 401

    ok = await client.patch(
        "/api/v1/auth/me/password",
        json={"current_password": "adminpassword123", "new_password": "a-brand-new-password"},
    )
    assert ok.status_code == 204, ok.text

    # The session that made the change survives it.
    assert (await client.get("/api/v1/auth/me")).status_code == 200

    # And the new password is the one that works now.
    fresh = await client.post(
        "/api/v1/auth/login",
        json={"email": "admin@example.com", "password": "a-brand-new-password"},
    )
    assert fresh.status_code == 200, fresh.text


@pytest.mark.asyncio
async def test_password_change_is_held_to_the_registration_minimum(
    user_a: tuple[AsyncClient, UUID],
) -> None:
    """A change must not be able to weaken an account below the bar it was made under."""
    client, _ = user_a
    r = await client.patch(
        "/api/v1/auth/me/password",
        json={"current_password": "adminpassword123", "new_password": "short"},
    )
    assert r.status_code == 422
