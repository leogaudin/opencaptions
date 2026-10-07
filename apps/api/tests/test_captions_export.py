"""Unit tests for caption export formatters."""

from __future__ import annotations

import json

from app.models.schemas import Transcript, TranscriptSegment, Word
from app.services.captions_export import to_json, to_srt, to_vtt


def _sample_transcript() -> Transcript:
    return Transcript(
        schema_version=1,
        language="en",
        language_detection="auto",
        duration=4.5,
        segments=[
            TranscriptSegment(
                id="seg-1",
                words=[
                    Word(text="Hello", start=0.0, end=0.5, confidence=1.0),
                    Word(text="world", start=0.5, end=1.0, confidence=1.0),
                ],
                start=0.0,
                end=1.0,
                text="Hello world",
            ),
            TranscriptSegment(
                id="seg-2",
                words=[
                    Word(text="this", start=2.0, end=2.2, confidence=1.0),
                    Word(text="is", start=2.2, end=2.3, confidence=1.0),
                    Word(text="OpenCaptions.", start=2.3, end=3.5, confidence=1.0),
                ],
                start=2.0,
                end=3.5,
                text="this is OpenCaptions.",
            ),
        ],
    )


def test_to_srt_format() -> None:
    out = to_srt(_sample_transcript())
    expected = (
        "1\n"
        "00:00:00,000 --> 00:00:01,000\n"
        "Hello world\n"
        "\n"
        "2\n"
        "00:00:02,000 --> 00:00:03,500\n"
        "this is OpenCaptions.\n"
    )
    assert out == expected


def test_to_vtt_starts_with_header() -> None:
    out = to_vtt(_sample_transcript())
    assert out.startswith("WEBVTT\n\n")
    assert "00:00:00.000 --> 00:00:01.000" in out
    # Word-level cue tags
    assert "<00:00:00.500>world" in out
    assert "<00:00:02.300>OpenCaptions." in out


def test_to_json_round_trips() -> None:
    t = _sample_transcript()
    out = to_json(t)
    parsed = json.loads(out)
    assert parsed["language"] == "en"
    assert parsed["duration"] == 4.5
    assert len(parsed["segments"]) == 2


def test_srt_handles_empty_transcript() -> None:
    empty = Transcript(
        schema_version=1,
        language="en",
        language_detection="auto",
        duration=0.0,
        segments=[],
    )
    assert to_srt(empty).strip() == ""
    out = to_vtt(empty)
    assert out.startswith("WEBVTT")


def test_srt_timestamp_rounding() -> None:
    """Confirm 999.5 ms rounds correctly without overflowing into seconds."""
    t = Transcript(
        schema_version=1,
        language="en",
        language_detection="auto",
        duration=2.0,
        segments=[
            TranscriptSegment(
                id="x",
                words=[Word(text="hi", start=0.9995, end=2.0, confidence=1.0)],
                start=0.9995,
                end=2.0,
                text="hi",
            )
        ],
    )
    out = to_srt(t)
    # 0.9995 -> 1000 ms -> rolls over to 1.000s
    assert "00:00:01,000 --> 00:00:02,000" in out


def test_srt_timestamp_carries_past_minutes_and_hours() -> None:
    """A rounded-up millisecond must carry all the way, not leave 60 in a field.

    Splitting into h/m/s before rounding the milliseconds let the carry stop at
    seconds, emitting `00:00:60,000`, which is not a valid SRT timestamp.
    """
    t = Transcript(
        schema_version=1,
        language="en",
        language_detection="auto",
        duration=3600.0,
        segments=[
            TranscriptSegment(
                id="x",
                words=[Word(text="hi", start=59.9999, end=3599.9999, confidence=1.0)],
                start=59.9999,
                end=3599.9999,
                text="hi",
            )
        ],
    )
    assert "00:01:00,000 --> 01:00:00,000" in to_srt(t)
    assert "00:01:00.000 --> 01:00:00.000" in to_vtt(t)
