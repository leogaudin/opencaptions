"""The server's copy of the script-to-font rule agrees with the engine's.

Both are held to `apps/engine/testdata/script_fonts.json`: a case added there must pass in Rust
and here.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.services.script_fonts import fallback_families, transcript_words

_CASES = Path(__file__).resolve().parents[2] / "engine" / "testdata" / "script_fonts.json"

pytestmark = pytest.mark.skipif(
    not _CASES.is_file(), reason="needs the engine's sources (a full checkout)"
)


def test_the_shared_cases_hold() -> None:
    cases = json.loads(_CASES.read_text())
    assert len(cases) >= 10
    for case in cases:
        got = fallback_families(case["words"], case["language"])
        assert got == case["families"], (case["words"], case["language"])


def test_the_words_of_a_transcript_are_read_in_order() -> None:
    transcript = {
        "language": "ja",
        "segments": [
            {"words": [{"text": "こん"}, {"text": "にちは"}]},
            {"words": [{"text": "世界"}]},
        ],
    }
    assert transcript_words(transcript) == ["こん", "にちは", "世界"]
    assert fallback_families(transcript_words(transcript), "ja") == ["Noto Sans JP"]
    assert transcript_words({}) == []


def test_a_render_asks_for_the_fonts_the_transcript_needs_and_skips_one_that_is_unavailable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from app.tasks import render

    monkeypatch.setattr(
        render, "_font_url", lambda family: None if "KR" in family else f"https://s3/{family}"
    )
    transcript = {
        "language": "auto",
        "segments": [{"words": [{"text": "こんにちは"}, {"text": "안녕"}, {"text": "hello"}]}],
    }
    assert render._fallback_fonts(transcript) == {"Noto Sans JP": "https://s3/Noto Sans JP"}
    assert render._fallback_fonts({"language": "en", "segments": []}) == {}
