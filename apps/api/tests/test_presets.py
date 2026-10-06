"""The built-in style presets are data shared with the clients (web and iOS).

They live in apps/web/src/lib/presets.json. The API's `StyleConfig` is the source
of truth for what a style may hold, so this is where a preset that drifts from it,
or a default changed on one side only, is caught on every platform.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.models.schemas import StyleConfig

_PRESETS = Path(__file__).resolve().parents[2] / "web" / "src" / "lib" / "presets.json"

pytestmark = pytest.mark.skipif(
    not _PRESETS.parent.is_dir(), reason="needs the web app's sources (a full checkout)"
)


def _presets() -> list[dict[str, object]]:
    return json.loads(_PRESETS.read_text())  # type: ignore[no-any-return]


def test_every_preset_is_a_valid_style() -> None:
    presets = _presets()
    assert [p["id"] for p in presets][0] == "builtin:purple-punch"
    assert len({p["id"] for p in presets}) == len(presets)
    for p in presets:
        assert StyleConfig.model_validate(p["config"]).model_dump() == p["config"], p["id"]


def test_the_cheap_looking_presets_are_gone_and_purple_punch_stays() -> None:
    ids = {p["id"] for p in _presets()}
    assert "builtin:purple-punch" in ids
    assert not ids & {"builtin:soft-pill", "builtin:hot-take", "builtin:classic"}
    assert len(ids) >= 7


def test_the_default_preset_is_the_apis_default_style() -> None:
    first = _presets()[0]["config"]
    assert first == StyleConfig().model_dump()


def test_the_default_font_ships_with_the_engine() -> None:
    # A new project must draw without fetching a font: the phone app works offline.
    fonts = _PRESETS.parents[3] / "engine" / "fonts"
    assert (fonts / "Poppins-ExtraBold.ttf").is_file() and (fonts / "Poppins-OFL.txt").is_file()
