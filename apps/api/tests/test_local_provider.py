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


def _transcribe_with(
    monkeypatch: Any,
    segments: list[Any],
    duration: float = 100.0,
    captured: dict[str, Any] | None = None,
) -> Any:
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
                captured.update(kwargs) if captured is not None else None,
                iter(segments),
                SimpleNamespace(language="en", duration=duration),
            )[1:]
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


def test_a_long_stretch_with_no_words_is_named_in_the_log(monkeypatch: Any, caplog: Any) -> None:
    spoken = [
        _segment("hello", 0.0, 1.0, [_fake_word(" hello", 0.0, 1.0)]),
        _segment("again", 60.0, 61.0, [_fake_word(" again", 60.0, 61.0)]),
    ]
    with caplog.at_level("WARNING", logger="app.transcription.local"):
        _transcribe_with(monkeypatch, spoken, duration=61.0)
    assert "1s-60s" in caplog.text
    # Nothing was filtered out, so the log does not send anyone to tune a filter.
    assert "Everything was decoded" in caplog.text
    assert "WHISPER_VAD_THRESHOLD" not in caplog.text


def test_a_long_stretch_names_the_voice_filter_when_it_is_on(monkeypatch: Any, caplog: Any) -> None:
    monkeypatch.setattr("app.transcription.local.settings.whisper_vad_filter", True)
    spoken = [
        _segment("hello", 0.0, 1.0, [_fake_word(" hello", 0.0, 1.0)]),
        _segment("again", 60.0, 61.0, [_fake_word(" again", 60.0, 61.0)]),
    ]
    with caplog.at_level("WARNING", logger="app.transcription.local"):
        _transcribe_with(monkeypatch, spoken, duration=61.0)
    assert "WHISPER_VAD_FILTER=false" in caplog.text


def test_everything_is_decoded_by_default(monkeypatch: Any) -> None:
    """The voice filter drops shouting and speech under loud music before Whisper sees it."""
    captured: dict[str, Any] = {}
    spoken = [_segment("hi", 0.0, 1.0, [_fake_word(" hi", 0.0, 1.0)])]
    _transcribe_with(monkeypatch, spoken, captured=captured)
    assert captured["vad_filter"] is False
    assert captured["vad_parameters"] is None
    # What replaces it against Whisper inventing words over silence.
    assert captured["hallucination_silence_threshold"] == 2.0
    assert captured["word_timestamps"] is True


def test_continuous_speech_logs_no_stretch(monkeypatch: Any, caplog: Any) -> None:
    spoken = [
        _segment("a", 0.0, 10.0, [_fake_word(" a", 0.0, 10.0)]),
        _segment("b", 12.0, 20.0, [_fake_word(" b", 12.0, 20.0)]),
    ]
    with caplog.at_level("WARNING", logger="app.transcription.local"):
        _transcribe_with(monkeypatch, spoken, duration=20.0)
    assert "no words for" not in caplog.text
