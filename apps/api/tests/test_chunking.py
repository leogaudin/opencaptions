"""How audio is cut for the models that decode in windows, and what happens to an empty one."""

from __future__ import annotations

import numpy as np

from app.transcription.chunking import (
    SAMPLE_RATE,
    Words,
    decode_window,
    is_quiet,
    long_gaps,
    second_look,
    windows,
)


def _tone(seconds: float, level: float = 0.1) -> np.ndarray:
    t = np.arange(int(seconds * SAMPLE_RATE)) / SAMPLE_RATE
    return (level * np.sin(2 * np.pi * 220 * t)).astype(np.float32)


def _silence(seconds: float) -> np.ndarray:
    return np.zeros(int(seconds * SAMPLE_RATE), dtype=np.float32)


def test_windows_cover_the_audio_without_gaps_or_overlap() -> None:
    audio = np.concatenate([_tone(7), _silence(0.5), _tone(9), _silence(0.5), _tone(11)])
    cuts = windows(audio, max_s=10)
    assert cuts[0][0] == 0
    assert cuts[-1][1] == len(audio)
    assert all(a[1] == b[0] for a, b in zip(cuts, cuts[1:], strict=False))
    assert all((end - start) / SAMPLE_RATE <= 10 for start, end in cuts)


def test_windows_are_cut_in_the_quiet_between_words() -> None:
    # Loud audio with one short silence late in the first window: the cut belongs in it.
    audio = np.concatenate([_tone(8.0), _silence(0.4), _tone(8.0)])
    first = windows(audio, max_s=10)[0]
    silence = (int(8.0 * SAMPLE_RATE), int(8.4 * SAMPLE_RATE))
    assert silence[0] <= first[1] <= silence[1]


def test_short_audio_is_one_window() -> None:
    audio = _tone(3)
    assert windows(audio, max_s=20) == [(0, len(audio))]


def test_quiet_audio_is_recognised() -> None:
    assert is_quiet(_silence(5))
    assert not is_quiet(_tone(5))


def _fake_decoder(words_by_length: dict[int, Words]) -> tuple[list[int], object]:
    calls: list[int] = []

    def decode(samples: np.ndarray) -> Words:
        calls.append(len(samples))
        return words_by_length.get(len(samples) // SAMPLE_RATE, [])

    return calls, decode


def test_words_are_offset_to_the_whole_recording() -> None:
    audio = _tone(5)
    words = decode_window(lambda _s: [("hi", 0.5, 1.0, 0.9)], audio, offset_s=30.0)
    assert words == [("hi", 30.5, 31.0, 0.9)]


def test_an_empty_loud_window_is_decoded_again_in_halves() -> None:
    audio = _tone(16)
    calls: list[float] = []

    def decode(samples: np.ndarray) -> Words:
        calls.append(len(samples) / SAMPLE_RATE)
        # The whole window comes back empty, as models that drop a window do; a half does not.
        return [] if len(samples) / SAMPLE_RATE > 12 else [("found", 1.0, 2.0, 0.8)]

    words = decode_window(decode, audio)
    assert [w[0] for w in words] == ["found", "found"]
    # Second half's word is placed after the first half, not on top of it.
    assert words[1][1] > words[0][2]
    assert calls[0] == 16.0 and len(calls) == 3


def test_an_empty_quiet_window_is_not_decoded_again() -> None:
    calls: list[int] = []

    def decode(samples: np.ndarray) -> Words:
        calls.append(len(samples))
        return []

    assert decode_window(decode, _silence(16)) == []
    assert len(calls) == 1


def test_a_short_empty_window_is_not_split_further() -> None:
    calls: list[int] = []

    def decode(samples: np.ndarray) -> Words:
        calls.append(len(samples))
        return []

    decode_window(decode, _tone(6))
    assert len(calls) == 1


def test_retry_can_be_switched_off() -> None:
    calls: list[int] = []

    def decode(samples: np.ndarray) -> Words:
        calls.append(len(samples))
        return []

    decode_window(decode, _tone(16), retry=False)
    assert len(calls) == 1


def test_long_gaps_are_the_stretches_no_word_covers() -> None:
    spans = [(1.0, 2.0), (10.0, 11.0), (10.5, 12.0)]
    assert long_gaps(spans, 20.0, 5.0) == [(2.0, 10.0), (12.0, 20.0)]
    assert long_gaps(spans, 20.0, 9.0) == []
    assert long_gaps([], 20.0, 5.0) == [(0.0, 20.0)]
    assert long_gaps([(0.0, 20.0)], 20.0, 5.0) == []


def _readings(*readings: Words) -> tuple[list[int], object]:
    """A decoder that gives each reading in turn, and a list of the lengths it was shown."""
    shown: list[int] = []
    queue = list(readings)

    def decode(samples: np.ndarray) -> Words:
        shown.append(len(samples))
        return queue.pop(0) if queue else []

    return shown, decode


def test_only_words_both_readings_give_are_kept() -> None:
    audio = _tone(30.0)
    # The gap is 5 s to 25 s. The first reading's window starts 0.3 s before it (4.7 s), the second's
    # 0.9 s after it begins (5.9 s), so a word at 8.0 s is 3.3 s into the first and 2.1 s into the second.
    first: Words = [("hello", 3.3, 3.8, 0.9), ("zzz", 5.3, 5.8, 0.9)]
    second: Words = [("Hello!", 2.1, 2.6, 0.9)]
    shown, decode = _readings(first, second)
    kept = second_look(decode, audio, [(5.0, 25.0)])  # type: ignore[arg-type]
    assert [w[0] for w in kept] == ["hello"], (
        "the word both readings give, not the one only one gave"
    )
    assert abs(kept[0][1] - 8.0) < 1e-6, "its time is from the start of the recording"
    assert len(shown) == 2


def test_a_reading_that_differs_from_the_other_keeps_nothing() -> None:
    audio = _tone(30.0)
    _, decode = _readings([("boom", 0.7, 1.2, 0.9)], [("love", 0.0, 0.5, 0.9)])
    assert second_look(decode, audio, [(5.0, 25.0)]) == []  # type: ignore[arg-type]


def test_words_outside_the_gap_are_left_to_the_first_pass() -> None:
    audio = _tone(30.0)
    # 4.8 s is the word before the gap that the padded window also covers.
    _, decode = _readings([("before", 0.1, 0.4, 0.9)], [("before", 0.0, 0.3, 0.9)])
    assert second_look(decode, audio, [(5.0, 25.0)]) == []  # type: ignore[arg-type]


def test_a_quiet_gap_is_not_looked_at() -> None:
    audio = np.concatenate([_tone(5.0), _silence(20.0), _tone(5.0)])
    shown, decode = _readings([("x", 1.0, 1.5, 0.9)])
    assert second_look(decode, audio, [(5.0, 25.0)]) == []  # type: ignore[arg-type]
    assert shown == [], "silence is expected to be empty"


def test_the_budget_bounds_how_much_audio_is_looked_at() -> None:
    audio = _tone(80.0)
    shown, decode = _readings()
    second_look(decode, audio, [(5.0, 25.0), (30.0, 50.0), (55.0, 75.0)], budget_s=30.0)  # type: ignore[arg-type]
    assert len(shown) == 1, (
        "one gap fits the budget; each takes a single decode when nothing is found"
    )
