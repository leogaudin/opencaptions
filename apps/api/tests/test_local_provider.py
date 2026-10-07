"""The local provider's handling of what faster-whisper hands back.

Whisper can transcribe a segment and still fail to align word timestamps for it.
Dropping those segments loses real speech, and does it silently, which is how a
long video ends up transcribed for its first half only.
"""

from __future__ import annotations

from types import SimpleNamespace
from typing import Any

from app.transcription.local import LocalWhisperProvider


def _fake_word(word: str, start: float, end: float) -> Any:
    return SimpleNamespace(word=word, start=start, end=end, probability=0.9)


def _segment(text: str, start: float, end: float, words: list[Any] | None) -> Any:
    return SimpleNamespace(text=text, start=start, end=end, words=words)


def _transcribe_with(monkeypatch: Any, segments: list[Any], duration: float = 100.0) -> Any:
    provider = LocalWhisperProvider()
    monkeypatch.setattr(provider, "_load_model", lambda _name: object())

    def fake_transcribe(_self: Any, _audio: str, **_kwargs: Any) -> Any:
        return iter(segments), SimpleNamespace(language="en", duration=duration)

    monkeypatch.setattr(
        type(provider),
        "transcribe",
        LocalWhisperProvider.transcribe,
        raising=True,
    )
    monkeypatch.setattr(
        provider,
        "_load_model",
        lambda _name: SimpleNamespace(
            transcribe=lambda audio, **kwargs: (
                iter(segments),
                SimpleNamespace(language="en", duration=duration),
            )
        ),
    )
    return provider.transcribe("/tmp/whatever.wav")


def test_unaligned_segment_is_kept_with_interpolated_timings(monkeypatch: Any) -> None:
    aligned = _segment(
        "hello there",
        0.0,
        1.0,
        [_fake_word(" hello", 0.0, 0.5), _fake_word(" there", 0.5, 1.0)],
    )
    # Same shape faster-whisper returns when word alignment fails: text, no words.
    unaligned = _segment("the second half still matters", 60.0, 63.0, [])

    transcript = _transcribe_with(monkeypatch, [aligned, unaligned])

    assert len(transcript.segments) == 2, "the unaligned segment must not be dropped"
    recovered = transcript.segments[1]
    assert recovered.text == "the second half still matters"
    assert [w.text for w in recovered.words] == ["the", "second", "half", "still", "matters"]
    # Spread across the segment's own span, in order, without overrunning it.
    assert recovered.words[0].start == 60.0
    assert abs(recovered.words[-1].end - 63.0) < 1e-6
    assert all(
        a.end <= b.start + 1e-9 for a, b in zip(recovered.words, recovered.words[1:], strict=False)
    )


def test_segment_with_neither_words_nor_text_is_skipped(monkeypatch: Any) -> None:
    transcript = _transcribe_with(monkeypatch, [_segment("   ", 5.0, 6.0, [])])
    assert transcript.segments == []
