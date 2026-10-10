"""How audio is cut for the models that decode in windows, and what happens to an empty one."""

from __future__ import annotations

import numpy as np

from app.transcription.chunking import SAMPLE_RATE, Words, decode_window, is_quiet, windows


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
