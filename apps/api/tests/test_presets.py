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
        # A look lists only the fields it changes, so a variant's unset fields are left out.
        config = StyleConfig.model_validate(p["config"])
        assert config.model_dump(exclude_none=True) == p["config"], p["id"]


def test_the_cheap_looking_presets_are_gone_and_purple_punch_stays() -> None:
    ids = {p["id"] for p in _presets()}
    assert "builtin:purple-punch" in ids
    assert not ids & {"builtin:soft-pill", "builtin:hot-take", "builtin:classic"}
    assert len(ids) >= 7


def test_the_default_preset_is_the_apis_default_style() -> None:
    first = _presets()[0]["config"]
    assert first == StyleConfig().model_dump(exclude_none=True)


def test_the_default_font_ships_with_the_engine() -> None:
    # A new project must draw without fetching a font: the phone app works offline.
    fonts = _PRESETS.parents[3] / "engine" / "fonts"
    assert (fonts / "Poppins-ExtraBold.ttf").is_file() and (fonts / "Poppins-OFL.txt").is_file()


def test_the_title_cards_font_ships_with_the_engine() -> None:
    # Nimbus Roman Bold is not on Google Fonts: the preset only draws if the engine has the file.
    fonts = _PRESETS.parents[3] / "engine" / "fonts"
    card = next(p for p in _presets() if p["name"] == "Title Card")
    config = card["config"]
    assert isinstance(config, dict) and config["font"] == "Nimbus Roman"
    assert config["background"] == "square" and config["align"] == "left"
    assert (fonts / "NimbusRoman-Bold.ttf").is_file()
    assert (fonts / "NimbusRoman-LICENSE.txt").is_file()


def test_the_bold_presets_font_ships_with_the_engine() -> None:
    # Montserrat Black is the one weight Google's 800 lookup cannot reach.
    fonts = _PRESETS.parents[3] / "engine" / "fonts"
    bold = next(p for p in _presets() if p["name"] == "Bold")
    config = bold["config"]
    assert isinstance(config, dict) and config["font"] == "Montserrat"
    assert (fonts / "Montserrat-Black.ttf").is_file() and (fonts / "Montserrat-OFL.txt").is_file()


def test_the_editorial_preset_mixes_looks_with_fonts_the_engine_ships() -> None:
    fonts = _PRESETS.parents[3] / "engine" / "fonts"
    editorial = next(p for p in _presets() if p["name"] == "Editorial")
    config = editorial["config"]
    assert isinstance(config, dict) and config["animation"] == "blur_in"
    variants = config["variants"]
    assert isinstance(variants, list) and len(variants) == 5
    families = {config["font"], *(v["font"] for v in variants)}
    shipped = {"Instrument Serif", "Inter", "Poppins", "Barlow Condensed"}
    assert families == shipped
    for name in (
        "InstrumentSerif-Regular.ttf",
        "InstrumentSerif-Italic.ttf",
        "InstrumentSerif-OFL.txt",
        "BarlowCondensed-MediumItalic.ttf",
        "BarlowCondensed-OFL.txt",
    ):
        assert (fonts / name).is_file(), name
    # Its tile shows the base look and two of the looks, each an index the preset defines.
    tile = editorial["tile_variants"]
    assert isinstance(tile, list)
    assert all(v is None or 0 <= v < len(variants) for v in tile)
