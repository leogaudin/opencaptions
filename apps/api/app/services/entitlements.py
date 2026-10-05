"""Pluggable pre-flight check guarding expensive work.

Transcription and rendering both enqueue real cost, so a capped deployment needs
to refuse before the work starts. The policy belongs to whoever operates the
deployment; only the seam lives here.

``UnlimitedEntitlementPolicy`` is the default that keeps self-hosting unmetered.
It looks unused — it is not, and deleting it starts denying everything.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass

from app.models import User

# Stable work-kind identifiers passed to check(), shared across call sites.
KIND_TRANSCRIPTION = "transcription"
KIND_RENDER = "render"


@dataclass(frozen=True)
class EntitlementDecision:
    """Outcome of a check. ``reason`` is empty when allowed."""

    allowed: bool
    reason: str = ""

    @classmethod
    def allow(cls) -> EntitlementDecision:
        return cls(allowed=True)

    @classmethod
    def deny(cls, reason: str) -> EntitlementDecision:
        return cls(allowed=False, reason=reason)


class EntitlementPolicy(ABC):
    """Decides whether a user may begin a unit of expensive work.

    ``kind`` is a KIND_* constant; ``amount`` is in that kind's natural unit.
    """

    name: str

    @abstractmethod
    def check(self, user: User, kind: str, amount: float) -> EntitlementDecision: ...


class UnlimitedEntitlementPolicy(EntitlementPolicy):
    """The only policy in the core: never denies. See the module docstring."""

    name = "unlimited"

    def check(self, user: User, kind: str, amount: float) -> EntitlementDecision:
        return EntitlementDecision.allow()


_REGISTRY: dict[str, EntitlementPolicy] = {}


def register(policy: EntitlementPolicy) -> EntitlementPolicy:
    """Register a policy instance for runtime lookup by name."""
    _REGISTRY[policy.name] = policy
    return policy


def get_policy(name: str) -> EntitlementPolicy:
    """Resolve a registered policy by name."""
    if name not in _REGISTRY:
        raise ValueError(f"Unknown entitlement policy: {name!r}. Registered: {list(_REGISTRY)}")
    return _REGISTRY[name]


def available_policies() -> list[str]:
    return sorted(_REGISTRY.keys())


def resolve_policy() -> EntitlementPolicy:
    """Return the configured policy, falling back to 'unlimited'."""
    from app.core.config import settings

    return get_policy(settings.entitlement_provider)


# Register the core's only implementation, selected by default. See module docstring.
register(UnlimitedEntitlementPolicy())
