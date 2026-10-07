"""Tests for the entitlement seam.

The core ships only the Unlimited policy (never denies), selected by default, so
self-hosted behaviour is unchanged. A hosted deployment substitutes a policy via
ENTITLEMENT_PROVIDER; a denial must surface as a clean 403, not a 500, with its
reason. The deny tests substitute a denying policy the same way a hosted edition
would (register + config), never touching the running stack's default.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID, uuid4

import pytest
from httpx import AsyncClient

from app.models import User
from app.services.entitlements import (
    KIND_RENDER,
    KIND_TRANSCRIPTION,
    EntitlementDecision,
    EntitlementPolicy,
    UnlimitedEntitlementPolicy,
    available_policies,
    get_policy,
    register,
    resolve_policy,
)


def _dummy_user() -> User:
    return User(id=uuid4(), email="x@example.com", password_hash="x")


class _DenyAllPolicy(EntitlementPolicy):
    """A denying policy used only in tests: the hosted-edition shape."""

    name = "deny-all-test"

    def check(self, user: User, kind: str, amount: float) -> EntitlementDecision:
        return EntitlementDecision.deny(f"quota exceeded for {kind}")


def test_unlimited_registered_and_default() -> None:
    from app.core.config import settings

    assert "unlimited" in available_policies()
    assert settings.entitlement_provider == "unlimited"
    assert isinstance(resolve_policy(), UnlimitedEntitlementPolicy)


def test_unlimited_allows_every_kind() -> None:
    policy = get_policy("unlimited")
    for kind in (KIND_TRANSCRIPTION, KIND_RENDER):
        decision = policy.check(_dummy_user(), kind, 10_000.0)
        assert decision.allowed is True
        assert decision.reason == ""


def test_decision_helpers() -> None:
    assert EntitlementDecision.allow() == EntitlementDecision(allowed=True, reason="")
    denied = EntitlementDecision.deny("nope")
    assert denied.allowed is False
    assert denied.reason == "nope"


def test_get_policy_unknown_raises() -> None:
    with pytest.raises(ValueError, match="Unknown entitlement policy"):
        get_policy("does-not-exist")


@pytest.mark.asyncio
async def test_transcription_allowed_under_unlimited_default(
    user_a: tuple[AsyncClient, UUID],
    seed_project: Any,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The default policy lets the request through to enqueue (202).

    The Celery dispatch is stubbed so the test asserts the seam permits the work,
    not the worker.
    """
    from app.tasks import transcribe as transcribe_task

    class _FakeAsyncResult:
        id = "fake-task-id"

    monkeypatch.setattr(
        transcribe_task.transcribe_video, "delay", lambda *a, **k: _FakeAsyncResult()
    )

    client_a, owner_a = user_a
    project_id = await seed_project(owner_a)

    r = await client_a.post(f"/api/v1/projects/{project_id}/transcribe", json={})
    assert r.status_code == 202, r.text
    assert r.json()["type"] == "transcription"


@pytest.mark.asyncio
async def test_transcription_denied_surfaces_403_not_500(
    user_a: tuple[AsyncClient, UUID],
    seed_project: Any,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from app.core.config import settings

    register(_DenyAllPolicy())
    monkeypatch.setattr(settings, "entitlement_provider", "deny-all-test")

    client_a, owner_a = user_a
    project_id = await seed_project(owner_a)

    r = await client_a.post(f"/api/v1/projects/{project_id}/transcribe", json={})
    assert r.status_code == 403, r.text
    body = r.json()
    assert body["error"] == "not_entitled"
    assert "quota exceeded for transcription" in body["detail"]


@pytest.mark.asyncio
async def test_render_denied_surfaces_403_not_500(
    user_a: tuple[AsyncClient, UUID],
    seed_project: Any,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from app.core.config import settings
    from app.storage import s3

    # Force a cache MISS so the request reaches the enqueue path (and the check).
    monkeypatch.setattr(s3, "object_exists", lambda key: False)

    register(_DenyAllPolicy())
    monkeypatch.setattr(settings, "entitlement_provider", "deny-all-test")

    client_a, owner_a = user_a
    project_id = await seed_project(owner_a)  # has transcript + video

    r = await client_a.post(f"/api/v1/projects/{project_id}/download", json={"format": "mp4"})
    assert r.status_code == 403, r.text
    body = r.json()
    assert body["error"] == "not_entitled"
    assert "quota exceeded for render" in body["detail"]
