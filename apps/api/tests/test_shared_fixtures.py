"""The Python and the Swift transcript logic are held to the same sample data.

`sherpa.words_from_tokens` and `chunking.agreed_in_gap` here, `TokenMapping.words` and
`TranscriptGaps.kept` in the iOS app, each read the files in the iOS tests' `Fixtures`: a case
added there must pass in both languages.
"""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any

import pytest

from app.models.schemas import Word
from app.transcription.chunking import agreed_in_gap
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


@pytest.mark.parametrize("case", _cases("second-look.json"), ids=lambda c: c["name"])
def test_two_readings_of_a_gap_agree_as_the_shared_cases_say(case: dict[str, Any]) -> None:
    def words(readings: list[dict[str, Any]]) -> list[tuple[str, float, float, float]]:
        return [(w["text"], w["start"], w["start"] + 0.5, 1.0) for w in readings]

    start, end = case["gap"]
    kept = agreed_in_gap(words(case["first"]), words(case["second"]), start, end)
    assert [w[0] for w in kept] == case["kept"]
