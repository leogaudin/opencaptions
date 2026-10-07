#!/usr/bin/env python3
r"""Reset a password directly against a running stack, no HTTP, no session.

The recovery path when SMTP is unconfigured and nobody can sign in. Hashes with
the same Argon2 parameters the API uses, so the result is indistinguishable from
a hash the app wrote.

Run it inside the api container, which has the venv and reaches Postgres. The
image does not ship scripts/, so copy the file in first:

    docker compose cp \
        scripts/reset_password.py api:/tmp/reset_password.py
    docker compose exec api \
        /app/.venv/bin/python /tmp/reset_password.py you@example.com
"""
from __future__ import annotations

import getpass
import os
import sys

# Add the app root to sys.path: only the script directory is there by default.
sys.path.insert(0, os.getcwd())

from sqlalchemy import create_engine, select  # noqa: E402
from sqlalchemy.orm import Session  # noqa: E402

from app.core.config import settings  # noqa: E402
from app.core.security import hash_password  # noqa: E402
from app.models import User  # noqa: E402

MIN_PASSWORD_LENGTH = 8


def _die(message: str, code: int = 1) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(code)


def _read_new_password() -> str:
    """Resolve the new password from OC_NEW_PASSWORD, an interactive prompt, or a
    piped stdin line, in that order, so the tool works for both a human at a
    terminal and an automated invocation."""
    env_password = os.environ.get("OC_NEW_PASSWORD")
    if env_password:
        return env_password
    if sys.stdin.isatty():
        first = getpass.getpass("New password: ")
        second = getpass.getpass("Confirm new password: ")
        if first != second:
            _die("passwords did not match")
        return first
    # Non-interactive with no env var: take a single piped line.
    piped = sys.stdin.readline().rstrip("\n")
    if not piped:
        _die("no password supplied (set OC_NEW_PASSWORD, use a TTY, or pipe one line)")
    return piped


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        _die(f"usage: {argv[0] if argv else 'reset_password.py'} <email>", code=2)

    # Emails are stored normalised to lowercase (see schemas.RegisterRequest), so
    # normalise the lookup the same way.
    email = argv[1].strip().lower()
    new_password = _read_new_password()
    if len(new_password) < MIN_PASSWORD_LENGTH:
        _die(f"password must be at least {MIN_PASSWORD_LENGTH} characters")

    engine = create_engine(settings.database_url_sync)
    try:
        with Session(engine) as session:
            user = session.scalar(select(User).where(User.email == email))
            if user is None:
                _die(f"no user with email {email!r}")
            assert user is not None  # for type-checkers; _die raised otherwise
            user.password_hash = hash_password(new_password)
            session.commit()
    finally:
        engine.dispose()

    print(f"Password updated for {email}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
