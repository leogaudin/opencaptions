"""The Python and the Swift transcript logic are held to the same sample data.

`sherpa.words_from_tokens` here and `TokenMapping.words` in the iOS app each read the files in the iOS tests'
`Fixtures`: a case added there must pass in both languages. (`second-look.json` is the iPhone's alone: the
server does not take a second look.)
"""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any

import pytest

from app.models.schemas import Word
from app.transcription.sherpa import _separate, words_from_tokens

_FIXTURES = (
    Path(__file__).resolve().parents[2]
    / "ios"
    / "OpenCaptionsKit"
    / "Tests"
    / "OpenCaptionsKitTests"
    / "Fixtures"
)

pytestmark = pytest.mark.skipif(not _FIXTURES.is_dir(), reason="needs the iOS app's sources")


def _cases(name: str) -> list[dict[str, Any]]:
    if not _FIXTURES.is_dir():
        return []
    cases: list[dict[str, Any]] = json.loads((_FIXTURES / name).read_text())["cases"]
    return cases


@pytest.mark.parametrize("case", _cases("token-words.json"), ids=lambda c: c["name"])
def test_tokens_make_the_words_the_shared_cases_say(case: dict[str, Any]) -> None:
    tokens = case["tokens"]
    made = words_from_tokens(
        [t["text"] for t in tokens],
        [t["start"] for t in tokens],
        [t["end"] - t["start"] for t in tokens],
        [math.log(t["confidence"]) for t in tokens],
    )
    words = [Word(text=text, start=s, end=e, confidence=c) for text, s, e, c in made]
    _separate(words)
    want = case["words"]
    assert [w.text for w in words] == [w["text"] for w in want]
    for got, expected in zip(words, want, strict=True):
        assert got.start == pytest.approx(expected["start"], abs=1e-4)
        assert got.end == pytest.approx(expected["end"], abs=1e-4)
        assert got.confidence == pytest.approx(expected["confidence"], abs=1e-4)
