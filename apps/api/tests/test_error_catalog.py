"""The API's errors are one catalog: what a route documents is what it raises."""

from __future__ import annotations

import re
from pathlib import Path

import pytest
from httpx import AsyncClient

from app.api.errors import ApiError
from app.main import app

_API = Path(__file__).resolve().parents[1] / "app"


def test_every_entry_is_used() -> None:
    source = "\n".join(p.read_text() for p in (_API / "api").glob("*.py") if p.name != "errors.py")
    unused = [e.name for e in ApiError if f"ApiError.{e.name}" not in source]
    assert not unused, f"in the catalog but never raised or documented: {unused}"


def test_no_route_builds_an_error_by_hand() -> None:
    for path in (_API / "api").glob("*.py"):
        if path.name != "errors.py":
            assert "HTTPException(" not in path.read_text(), path.name
            assert "http_error(" not in path.read_text(), path.name


def test_the_schema_documents_each_error_under_the_status_the_catalog_gives_it() -> None:
    by_code: dict[str, set[int]] = {}
    for e in ApiError:
        by_code.setdefault(e.code, set()).add(e.status)
    documented = 0
    for path, methods in app.openapi()["paths"].items():
        for method, op in methods.items():
            for status, response in op.get("responses", {}).items():
                for code in re.findall(r"`error: (\w+)`", response.get("description", "")):
                    assert code in by_code, f"{method} {path}: {code} is not in the catalog"
                    assert int(status) in by_code[code], f"{method} {path}: {code} under {status}"
                    documented += 1
    assert documented > 30


@pytest.mark.asyncio
async def test_the_documented_errors_are_what_the_routes_answer(client: AsyncClient) -> None:
    response = await client.get("/api/v1/projects/00000000-0000-0000-0000-000000000000")
    assert response.status_code == ApiError.NOT_AUTHENTICATED.status
    assert response.json()["error"] == ApiError.NOT_AUTHENTICATED.code
    assert response.json()["code"] == ApiError.NOT_AUTHENTICATED.status
