"""A request's changes are committed before its response is sent.

The session commits when its dependency exits. By default FastAPI exits a dependency only after the
response has gone out, so a client could be told a change was saved and, on its very next request,
read the row from before it (the agent package saw a transcript it had just sent come back missing).
"""

from typing import Any

from fastapi.dependencies.models import Dependant
from fastapi.routing import APIRoute, APIWebSocketRoute

from app.api.deps import db_session
from app.main import app


def _sessions(dependant: Dependant, path: list[str]) -> list[tuple[str, str | None]]:
    found: list[tuple[str, str | None]] = []
    for sub in dependant.dependencies:
        here = [*path, getattr(sub.call, "__name__", "?")]
        if sub.call is db_session:
            found.append((" > ".join(here), sub.scope))
        found += _sessions(sub, here)
    return found


def _routes(routes: list[Any]) -> list[APIRoute | APIWebSocketRoute]:
    """Every endpoint, through included routers (kept nested, not flattened, by FastAPI)."""
    found: list[APIRoute | APIWebSocketRoute] = []
    for route in routes:
        if isinstance(route, APIRoute | APIWebSocketRoute):
            found.append(route)
        elif (nested := getattr(route, "original_router", route)) is not route or hasattr(
            route, "routes"
        ):
            found += _routes(list(nested.routes))
    return found


def test_every_session_commits_before_the_response() -> None:
    routes = _routes(list(app.routes))
    uses = [
        (f"{route.path}: {where}", scope)
        for route in routes
        for where, scope in _sessions(route.dependant, [])
    ]
    assert uses, "no route uses the session: the walk is wrong"
    late = [where for where, scope in uses if scope != "function"]
    assert not late, f'Depends(db_session, scope="function") is needed in: {late}'
