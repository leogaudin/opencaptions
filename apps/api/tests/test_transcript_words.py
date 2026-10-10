"""Segments are ended at a pause."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.models.schemas import Transcript, TranscriptSegment, Word
from app.transcription.words import clean_transcript, pauses


def _words(*texts: str) -> list[Word]:
    return [Word(text=t, start=i * 0.5, end=i * 0.5 + 0.4) for i, t in enumerate(texts)]


def _texts(words: list[Word]) -> list[str]:
    return [w.text for w in words]


def test_a_segment_that_spans_a_long_silence_is_split_there() -> None:
    # Said at 0-1s and again at 120s: voice detection stripped the minutes between.
    words = [
        Word(text="un", start=0.0, end=0.5),
        Word(text="deux", start=0.6, end=1.0),
        Word(text="trois", start=120.0, end=120.5),
        Word(text="quatre", start=120.6, end=121.0),
    ]
    transcript = Transcript(
        duration=130.0,
        segments=[TranscriptSegment(id="a", words=words, start=0.0, end=121.0, text="x")],
    )
    first, second = clean_transcript(transcript).segments
    assert (first.id, first.text, first.start, first.end) == ("a", "un deux", 0.0, 1.0)
    assert (second.text, second.start, second.end) == ("trois quatre", 120.0, 121.0)
    assert second.id != first.id


def test_a_short_pause_does_not_split_a_segment() -> None:
    words = [Word(text="un", start=0.0, end=0.5), Word(text="deux", start=1.9, end=2.4)]
    segment = TranscriptSegment(id="a", words=words, start=0.0, end=2.4, text="un deux")
    cleaned = clean_transcript(Transcript(duration=3.0, segments=[segment]))
    assert cleaned.segments == [segment]


_CASES = Path(__file__).resolve().parents[2] / "engine" / "testdata" / "pauses.json"


@pytest.mark.skipif(not _CASES.is_file(), reason="needs the engine's sources (a full checkout)")
def test_the_pause_rule_agrees_with_the_engines() -> None:
    """Both are held to apps/engine/testdata/pauses.json: a case added there must pass in both."""
    cases = json.loads(_CASES.read_text())
    assert len(cases) >= 8
    for case in cases:
        words = [Word(text="w", start=s, end=e) for s, e in case["words"]]
        assert pauses(words) == case["breaks"], case["name"]


def test_a_pause_is_judged_against_the_speakers_own_tempo() -> None:
    def talk(period: float, gap: float) -> Transcript:
        starts = [i * period for i in range(5)]
        starts += [starts[-1] + period * 0.9 + gap + i * period for i in range(5)]
        words = [Word(text="w", start=s, end=s + period * 0.9) for s in starts]
        segment = TranscriptSegment(id="a", words=words, start=0.0, end=words[-1].end, text="w")
        return Transcript(duration=100.0, segments=[segment])

    # The same 0.8 s of quiet: a pause between fast words, not between slow ones.
    assert len(clean_transcript(talk(0.2, 0.8)).segments) == 2
    assert len(clean_transcript(talk(0.6, 0.8)).segments) == 1
