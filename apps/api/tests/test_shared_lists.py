"""Lists every side holds, each written once in `apps/engine/testdata/` and tested on every side.

A side that drifts fails its own test: the engine's animations, the API's schema and Parakeet
languages, the web's lists and the iPhone app's.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import get_args

import pytest

from app.models.schemas import StyleConfig
from app.services.asr_models import _PARAKEET_LANGUAGES

_DATA = Path(__file__).resolve().parents[2] / "engine" / "testdata"
_DOCS = Path(__file__).resolve().parents[3] / "docs" / "reference" / "style.md"

pytestmark = pytest.mark.skipif(
    not (_DATA / "animations.json").is_file(), reason="needs the engine's sources (a full checkout)"
)


def test_the_animations_in_the_schema_are_the_shared_list() -> None:
    shared = json.loads((_DATA / "animations.json").read_text())
    assert list(get_args(StyleConfig.model_fields["animation"].annotation)) == shared


@pytest.mark.skipif(not _DOCS.is_file(), reason="needs the docs (a full checkout)")
def test_the_style_reference_documents_every_animation() -> None:
    documented = set(re.findall(r"^\| `(\w+)` \|", _DOCS.read_text(), re.M))
    assert set(json.loads((_DATA / "animations.json").read_text())) <= documented


def test_parakeets_languages_are_the_shared_list() -> None:
    assert sorted(_PARAKEET_LANGUAGES) == json.loads(
        (_DATA / "parakeet-languages.json").read_text()
    )
