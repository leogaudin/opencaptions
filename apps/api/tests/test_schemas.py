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
    assert s.animation == "highlight_slide"
    assert s.words_per_line == 3


def test_style_config_color_pattern_enforced() -> None:
    with pytest.raises(ValidationError):
        StyleConfig(text_color="not-a-color")


def test_style_config_shadow_supports_alpha() -> None:
    s = StyleConfig(shadow_color="#FF000080")
    assert s.shadow_color == "#FF000080"


def test_style_config_effects_default_to_off_and_are_bounded() -> None:
    s = StyleConfig()
    assert (s.shadow_offset_x, s.shadow_offset_y, s.glow_blur) == (0, 0, 0)
    assert (s.text_case, s.italic) == ("none", False)
    for animation in (
        "word_sweep",
        "word_underline",
        "typewriter",
        "none",
        "word_bounce",
        "lyric_focus",
        "highlight_slide",
        "line_bar",
        "stickers",
    ):
        assert StyleConfig(animation=animation).animation == animation  # type: ignore[arg-type]
    for bad in ({"shadow_offset_x": 21}, {"glow_blur": 41}, {"text_case": "lower"}):
        with pytest.raises(ValidationError):
            StyleConfig(**bad)  # type: ignore[arg-type]


def test_style_config_colour_lists_default_to_off_and_are_validated() -> None:
    s = StyleConfig()
    assert (s.palette, s.highlight_color_end) == ([], None)
    ok = StyleConfig(palette=["#FFE600", "#22E06B"], highlight_color_end="#A855F7")
    assert ok.palette == ["#FFE600", "#22E06B"]
    for bad in (
        {"palette": ["yellow"]},
        {"palette": ["#FFFFFF"] * 9},
        {"highlight_color_end": "red"},
    ):
        with pytest.raises(ValidationError):
            StyleConfig(**bad)  # type: ignore[arg-type]


def test_error_response_shape() -> None:
    e = ErrorResponse(error="not_found", detail="missing", code=404)
    payload = e.model_dump()
    assert payload == {"error": "not_found", "detail": "missing", "code": 404, "field": None}
