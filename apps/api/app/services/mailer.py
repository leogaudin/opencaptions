"""Mailer seam: a one-method interface, a no-op default, and an SMTP sender.

Password reset needs exactly one kind of email, and only when the operator has
configured SMTP — so this is a registry and two implementations rather than a
notification framework. Mirrors the transcription and entitlement registries.
"""

from __future__ import annotations

import logging
import smtplib
from abc import ABC, abstractmethod
from email.message import EmailMessage

from app.core.config import settings

logger = logging.getLogger(__name__)


class Mailer(ABC):
    """Sends one email. The whole seam is this single method."""

    name: str

    @abstractmethod
    def send(self, *, to: str, subject: str, body: str) -> None: ...


class NoOpMailer(Mailer):
    """The default when SMTP is unconfigured: sends nothing.

    Not dead code — it is what lets the reset call site exist unchanged on a
    stock install. Logs no recipient or content.
    """

    name = "noop"

    def send(self, *, to: str, subject: str, body: str) -> None:
        return None


class SMTPMailer(Mailer):
    """Send via SMTP, reading configuration at send time.

    Raises on failure; the caller runs this off the request path so a broken
    relay never changes the user-visible response.
    """

    name = "smtp"

    def send(self, *, to: str, subject: str, body: str) -> None:
        message = EmailMessage()
        message["From"] = settings.smtp_from or settings.smtp_username
        message["To"] = to
        message["Subject"] = subject
        message.set_content(body)
        with smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=10) as client:
            if settings.smtp_use_tls:
                client.starttls()
            if settings.smtp_username:
                client.login(settings.smtp_username, settings.smtp_password)
            client.send_message(message)


_REGISTRY: dict[str, Mailer] = {}


def register(mailer: Mailer) -> Mailer:
    """Register a mailer instance for runtime lookup by name."""
    _REGISTRY[mailer.name] = mailer
    return mailer


def get_mailer(name: str) -> Mailer:
    """Resolve a registered mailer by name."""
    if name not in _REGISTRY:
        raise ValueError(f"Unknown mailer: {name!r}. Registered: {list(_REGISTRY)}")
    return _REGISTRY[name]


def resolve_mailer() -> Mailer:
    """Return the configured mailer: SMTP when SMTP is configured, else the
    no-op. Resolving through configuration — rather than importing a concrete
    mailer at the call site — keeps the reset endpoint agnostic to whether email
    is set up."""
    return get_mailer("smtp" if settings.smtp_configured else "noop")


# Register the two implementations the core ships. See module docstring.
register(NoOpMailer())
register(SMTPMailer())
