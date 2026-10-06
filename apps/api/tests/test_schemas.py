"""Schema sanity tests."""

import pytest
from pydantic import ValidationError

from app.models.schemas import (
    ErrorResponse,
    StyleConfig,
    Transcript,
    TranscriptSegment,
    Word,
)


def test_word_validates_timestamps() -> None:
    w = Word(text="hello", start=0.0, end=0.5, confidence=0.99)
    assert w.text == "hello"


def test_negative_timestamp_rejected() -> None:
    with pytest.raises(ValidationError):
        Word(text="x", start=-1.0, end=0.0)


def test_transcript_default_schema_version() -> None:
    t = Transcript(
        duration=5.0,
        segments=[
            TranscriptSegment(
                id="s1",
                words=[Word(text="hi", start=0.0, end=0.5)],
                start=0.0,
                end=0.5,
                text="hi",
            )
        ],
    )
    assert t.schema_version == 1
    assert t.language == "en"


def test_style_config_defaults() -> None:
    s = StyleConfig()
    assert s.font == "Poppins"
    assert s.position_x == 0.5
    assert s.position_y == 0.84
    assert s.animation == "highlight_box"
    assert s.words_per_line == 3


def test_style_config_color_pattern_enforced() -> None:
    with pytest.raises(ValidationError):
        StyleConfig(text_color="not-a-color")


def test_style_config_shadow_supports_alpha() -> None:
    s = StyleConfig(shadow_color="#FF000080")
    assert s.shadow_color == "#FF000080"


def test_error_response_shape() -> None:
    e = ErrorResponse(error="not_found", detail="missing", code=404)
    payload = e.model_dump()
    assert payload == {"error": "not_found", "detail": "missing", "code": 404, "field": None}
