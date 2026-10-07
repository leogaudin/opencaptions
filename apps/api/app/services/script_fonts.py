"""Which fonts a transcript needs beyond the engine's bundled ones.

The engine bundles Latin, Greek, Cyrillic, Arabic, Hebrew, Devanagari and Thai. Chinese, Japanese,
Korean and the other Asian scripts need fonts too large to ship, so a render fetches the families
named here, as it does the style's own font. This is the Python copy of the engine's rule
(`apps/engine/src/scripts.rs`, used by the preview and the phone); both are held to the same
cases in `apps/engine/testdata/script_fonts.json`.
"""

from __future__ import annotations

from collections.abc import Iterable
from typing import Any

_Range = tuple[int, int]

# A script's letters, and the family that draws them.
_SCRIPTS: tuple[tuple[str, _Range], ...] = (
    ("Noto Sans Bengali", (0x0980, 0x09FF)),
    ("Noto Sans Gurmukhi", (0x0A00, 0x0A7F)),
    ("Noto Sans Gujarati", (0x0A80, 0x0AFF)),
    ("Noto Sans Tamil", (0x0B80, 0x0BFF)),
    ("Noto Sans Telugu", (0x0C00, 0x0C7F)),
    ("Noto Sans Kannada", (0x0C80, 0x0CFF)),
    ("Noto Sans Malayalam", (0x0D00, 0x0D7F)),
    ("Noto Sans Sinhala", (0x0D80, 0x0DFF)),
    ("Noto Sans Lao", (0x0E80, 0x0EFF)),
    ("Noto Sans Myanmar", (0x1000, 0x109F)),
    ("Noto Sans Georgian", (0x10A0, 0x10FF)),
    ("Noto Sans Ethiopic", (0x1200, 0x137F)),
    ("Noto Sans Khmer", (0x1780, 0x17FF)),
    ("Noto Sans Armenian", (0x0530, 0x058F)),
)
_KANA: tuple[_Range, ...] = ((0x3040, 0x30FF), (0x31F0, 0x31FF), (0xFF66, 0xFF9F))
_HANGUL: tuple[_Range, ...] = ((0x1100, 0x11FF), (0x3130, 0x318F), (0xAC00, 0xD7AF))
_HAN: tuple[_Range, ...] = (
    (0x3400, 0x4DBF),
    (0x4E00, 0x9FFF),
    (0xF900, 0xFAFF),
    (0x20000, 0x2A6DF),
)
_TRADITIONAL = ("zh-tw", "zh-hk", "zh-hant", "zh_tw", "zh_hk")


def _within(char: str, ranges: Iterable[_Range]) -> bool:
    code = ord(char)
    return any(a <= code <= b for a, b in ranges)


def _han_family(language: str, kana: bool, hangul: bool) -> str:
    if kana or language.startswith("ja"):
        return "Noto Sans JP"
    if hangul or language.startswith("ko"):
        return "Noto Sans KR"
    if language.startswith(_TRADITIONAL):
        return "Noto Sans TC"
    return "Noto Sans SC"


def _family_of(char: str, language: str, kana: bool, hangul: bool) -> str | None:
    if _within(char, _KANA):
        return "Noto Sans JP"
    if _within(char, _HANGUL):
        return "Noto Sans KR"
    if _within(char, _HAN):
        return _han_family(language, kana, hangul)
    return next((family for family, rng in _SCRIPTS if _within(char, (rng,))), None)


def fallback_families(words: Iterable[str], language: str) -> list[str]:
    """The families whose letters appear in `words`, in order of first appearance."""
    chars = [c for word in words for c in word if not c.isascii()]
    language = language.lower()
    kana = any(_within(c, _KANA) for c in chars)
    hangul = any(_within(c, _HANGUL) for c in chars)
    out: list[str] = []
    for char in chars:
        family = _family_of(char, language, kana, hangul)
        if family and family not in out:
            out.append(family)
    return out


def transcript_words(transcript: dict[str, Any]) -> list[str]:
    """Every word's text, in reading order."""
    return [
        str(w.get("text", ""))
        for segment in transcript.get("segments") or []
        for w in segment.get("words") or []
    ]
