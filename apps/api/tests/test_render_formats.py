"""Unit tests for the format registry and content-addressed render hash."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

from app.services import render_formats
from app.services.render_formats import (
    ENGINE_RENDER_REVISION,
    FORMATS,
    RenderInputs,
    all_formats,
    compute_render_hash,
    get_format,
    render_object_key,
)

# === Format Registry Tests ===


class TestFormatRegistry:
    def test_all_four_formats_registered(self) -> None:
        assert len(FORMATS) == 4
        assert set(FORMATS.keys()) == {"mp4", "mp4-hevc", "webm", "mov"}

    def test_get_format_known(self) -> None:
        fmt = get_format("mp4")
        assert fmt is not None
        assert fmt.codec == "h264"
        assert fmt.crf == 15
        assert fmt.extension == ".mp4"

    def test_get_format_unknown_returns_none(self) -> None:
        assert get_format("bogus") is None
        assert get_format("") is None

    def test_prores_has_no_crf(self) -> None:
        fmt = get_format("mov")
        assert fmt is not None
        assert fmt.crf is None
        assert fmt.pro_res_profile == "hq"

    def test_vp9_extension_is_webm(self) -> None:
        fmt = get_format("webm")
        assert fmt is not None
        assert fmt.extension == ".webm"
        assert fmt.codec == "vp9"

    def test_all_formats_returns_list(self) -> None:
        fmts = all_formats()
        assert len(fmts) == 4
        assert fmts[0].id == "mp4"

    def test_formats_have_correct_mime_types(self) -> None:
        assert get_format("mp4").mime == "video/mp4"
        assert get_format("mp4-hevc").mime == "video/mp4"
        assert get_format("webm").mime == "video/webm"
        assert get_format("mov").mime == "video/quicktime"


# === Render Hash Tests ===


_BASE_INPUTS = {
    "transcript": {"schema_version": 1, "language": "fr", "duration": 10.5, "segments": []},
    "style_config": {"font": "Inter", "font_size": 48},
    "caption_offset_ms": 0,
    "format_id": "mp4",
    "width": 1920,
    "height": 1080,
    "fps": 30,
}


class TestRenderHash:
    def test_same_inputs_same_hash(self) -> None:
        """Identical inputs must produce the same digest across calls."""
        h1 = compute_render_hash(**_BASE_INPUTS)
        h2 = compute_render_hash(**_BASE_INPUTS)
        assert h1 == h2

    def test_hash_is_16_hex_chars(self) -> None:
        h = compute_render_hash(**_BASE_INPUTS)
        assert len(h) == 16
        assert all(c in "0123456789abcdef" for c in h)

    def test_dict_key_order_does_not_affect_hash(self) -> None:
        """Reordering dict keys in transcript/style must NOT change the digest."""
        inputs_a = {**_BASE_INPUTS, "style_config": {"font": "Inter", "font_size": 48}}
        inputs_b = {**_BASE_INPUTS, "style_config": {"font_size": 48, "font": "Inter"}}
        assert compute_render_hash(**inputs_a) == compute_render_hash(**inputs_b)

    def test_changing_format_changes_hash(self) -> None:
        h1 = compute_render_hash(**_BASE_INPUTS)
        h2 = compute_render_hash(**{**_BASE_INPUTS, "format_id": "webm"})
        assert h1 != h2

    def test_changing_transcript_changes_hash(self) -> None:
        h1 = compute_render_hash(**_BASE_INPUTS)
        modified = {**_BASE_INPUTS["transcript"], "duration": 20.0}
        h2 = compute_render_hash(**{**_BASE_INPUTS, "transcript": modified})
        assert h1 != h2

    def test_changing_a_words_look_changes_hash(self) -> None:
        """A word given a look, or another one, is another file."""

        def with_word(**extra: object) -> dict[str, object]:
            word = {"text": "hi", "start": 0.0, "end": 0.5, **extra}
            segment = {"id": "a", "start": 0.0, "end": 0.5, "text": "hi", "words": [word]}
            transcript = {**_BASE_INPUTS["transcript"], "segments": [segment]}
            return {**_BASE_INPUTS, "transcript": transcript}

        plain = compute_render_hash(**with_word())
        assert compute_render_hash(**with_word(variant=1)) != plain
        first = compute_render_hash(**with_word(variant=1))
        assert first != compute_render_hash(**with_word(variant=2))

    def test_changing_style_changes_hash(self) -> None:
        h1 = compute_render_hash(**_BASE_INPUTS)
        h2 = compute_render_hash(
            **{**_BASE_INPUTS, "style_config": {"font": "Arial", "font_size": 48}}
        )
        assert h1 != h2

    def test_changing_width_changes_hash(self) -> None:
        h1 = compute_render_hash(**_BASE_INPUTS)
        h2 = compute_render_hash(**{**_BASE_INPUTS, "width": 1280})
        assert h1 != h2

    def test_changing_height_changes_hash(self) -> None:
        h1 = compute_render_hash(**_BASE_INPUTS)
        h2 = compute_render_hash(**{**_BASE_INPUTS, "height": 720})
        assert h1 != h2

    def test_changing_fps_changes_hash(self) -> None:
        h1 = compute_render_hash(**_BASE_INPUTS)
        h2 = compute_render_hash(**{**_BASE_INPUTS, "fps": 60})
        assert h1 != h2

    def test_changing_the_caption_offset_changes_hash(self) -> None:
        h1 = compute_render_hash(**_BASE_INPUTS)
        h2 = compute_render_hash(**{**_BASE_INPUTS, "caption_offset_ms": 250})
        assert h1 != h2


# === Object Key Tests ===


class TestRenderObjectKey:
    def test_key_format(self) -> None:
        key = render_object_key("abc-123", "mp4", "deadbeef01234567", ".mp4")
        assert key == "projects/abc-123/renders/mp4/deadbeef01234567.mp4"

    def test_webm_extension(self) -> None:
        key = render_object_key("proj-1", "webm", "1234567890abcdef", ".webm")
        assert key == "projects/proj-1/renders/webm/1234567890abcdef.webm"

    def test_formats_sharing_an_extension_have_different_keys(self) -> None:
        assert render_object_key("p", "mp4", "h", ".mp4") != render_object_key(
            "p", "mp4-hevc", "h", ".mp4"
        )

    def test_a_new_render_prunes_only_its_own_format(self) -> None:
        p = "projects/p/renders/"
        keys = [
            f"{p}mp4/old.mp4",
            f"{p}mp4/new.mp4",
            f"{p}mp4-hevc/other.mp4",
            f"{p}webm/other.webm",
            f"{p}loose.mp4",
            f"{p}loose.webm",
        ]
        from app.services.render_formats import stale_render_keys

        assert stale_render_keys("p", "mp4", ".mp4", keys, f"{p}mp4/new.mp4") == [
            f"{p}mp4/old.mp4",
            f"{p}loose.mp4",
        ]
        assert stale_render_keys("p", "mp4-hevc", ".mp4", keys, f"{p}mp4-hevc/other.mp4") == [
            f"{p}loose.mp4"
        ]


def _expected_hash(**inputs: Any) -> str:
    """The hash written out by hand: one JSON object with sorted keys, hashed."""
    import hashlib
    import json

    fmt = get_format(inputs["format_id"])
    encoder = {"crf": fmt.crf, "pro_res_profile": fmt.pro_res_profile} if fmt else {}
    canonical = json.dumps(
        {**inputs, "encoder": encoder, "engine_revision": ENGINE_RENDER_REVISION},
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(canonical.encode()).hexdigest()[:16]


def test_the_hash_is_the_digest_of_one_sorted_json_object() -> None:
    transcript = {
        "language": "fr",
        "segments": [
            {"id": "s1", "words": [{"text": "déjà", "start": 0.1, "end": 0.5, "confidence": 0.9}]},
            {"id": "s2", "words": [{"text": '日本語 "quoted"\n', "start": 1, "end": 2.25}]},
        ],
    }
    style = {"font": "Inter", "font_size": 48.5, "outline": {"width": 2, "color": "#000"}}
    for format_id in ("mp4", "mp4-hevc", "webm", "mov", "not-a-format"):
        for green_screen in (False, True):
            inputs = {
                "transcript": transcript,
                "style_config": style,
                "caption_offset_ms": -250,
                "format_id": format_id,
                "width": 1080,
                "height": 1920,
                "fps": 30,
                "green_screen": green_screen,
            }
            expected = _expected_hash(**inputs)
            assert compute_render_hash(**inputs) == expected
            shared = RenderInputs(
                transcript=transcript,
                style_config=style,
                caption_offset_ms=-250,
                width=1080,
                height=1920,
                fps=30,
                green_screen=green_screen,
            )
            assert shared.hash_for(format_id) == expected


def test_a_different_engine_revision_gives_a_different_hash(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    before = compute_render_hash(**_BASE_INPUTS)
    monkeypatch.setattr(render_formats, "ENGINE_RENDER_REVISION", "another")
    assert compute_render_hash(**_BASE_INPUTS) != before


_REVISION = Path(__file__).resolve().parents[2] / "engine" / "testdata" / "render_revision.txt"


@pytest.mark.skipif(not _REVISION.is_file(), reason="needs the engine's sources (a full checkout)")
def test_the_revision_is_the_engines() -> None:
    assert _REVISION.read_text().strip() == ENGINE_RENDER_REVISION
