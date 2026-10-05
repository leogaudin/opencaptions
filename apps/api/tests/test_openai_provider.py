"""Tests for the OpenAI transcription provider (response parsing only — no API calls)."""

from __future__ import annotations

import pytest

from app.transcription.openai import OpenAIWhisperProvider, _normalize_language


def test_normalize_language_iso() -> None:
    assert _normalize_language("en") == "en"
    assert _normalize_language("EN") == "en"


def test_normalize_language_full_name() -> None:
    assert _normalize_language("English") == "en"
    assert _normalize_language("french") == "fr"
    assert _normalize_language("Japanese") == "ja"


def test_normalize_language_unknown_falls_back_to_first_two() -> None:
    assert _normalize_language("klingonese") == "kl"


def test_normalize_language_empty() -> None:
    assert _normalize_language("") == "en"


def test_parse_response_with_word_timestamps() -> None:
    provider = OpenAIWhisperProvider()
    payload = {
        "text": "Hello world this is a test.",
        "language": "english",
        "duration": 3.0,
        "words": [
            {"word": "Hello", "start": 0.0, "end": 0.5},
            {"word": "world", "start": 0.5, "end": 1.0},
            {"word": "this", "start": 1.1, "end": 1.3},
            {"word": "is", "start": 1.3, "end": 1.4},
            {"word": "a", "start": 1.4, "end": 1.5},
            {"word": "test.", "start": 1.5, "end": 2.0},
        ],
        "segments": [
            {"start": 0.0, "end": 1.0, "text": "Hello world"},
            {"start": 1.1, "end": 2.0, "text": "this is a test."},
        ],
    }
    transcript = provider._parse_response(payload, requested_language="auto")
    assert transcript.language == "en"
    assert transcript.language_detection == "auto"
    assert transcript.duration == pytest.approx(3.0)
    assert len(transcript.segments) == 2
    assert transcript.segments[0].text == "Hello world"
    assert len(transcript.segments[0].words) == 2
    assert transcript.segments[1].text == "this is a test."
    assert len(transcript.segments[1].words) == 4


def test_parse_response_no_segments_falls_back_to_chunking() -> None:
    provider = OpenAIWhisperProvider()
    payload = {
        "text": "one two three four five six seven eight",
        "language": "en",
        "duration": 4.0,
        "words": [
            {"word": w, "start": i * 0.5, "end": i * 0.5 + 0.4}
            for i, w in enumerate(["one", "two", "three", "four", "five", "six", "seven", "eight"])
        ],
    }
    transcript = provider._parse_response(payload, requested_language="auto")
    # Default chunk=6 → 8 words → 2 segments (6+2)
    assert len(transcript.segments) == 2
    assert len(transcript.segments[0].words) == 6
    assert len(transcript.segments[1].words) == 2


def test_parse_response_empty_words_uses_text_fallback() -> None:
    provider = OpenAIWhisperProvider()
    payload = {"text": "Plain transcript with no word timing.", "duration": 2.0}
    transcript = provider._parse_response(payload, requested_language="en")
    assert transcript.language_detection == "manual"
    assert len(transcript.segments) == 1
    assert transcript.segments[0].text == "Plain transcript with no word timing."


def test_parse_response_completely_empty() -> None:
    provider = OpenAIWhisperProvider()
    transcript = provider._parse_response({}, requested_language="auto")
    assert transcript.segments == []
    assert transcript.duration == 0.0
