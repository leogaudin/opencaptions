"""The voice's loudness for the pulse look: the engine's rule, measured from the audio."""

from __future__ import annotations

import base64
import json
import shutil
import subprocess
from pathlib import Path

import pytest

from app.models.schemas import Transcript
from app.services import loudness

_CASES = Path(__file__).resolve().parents[2] / "engine" / "testdata" / "loudness.json"


@pytest.mark.skipif(not _CASES.is_file(), reason="needs the engine's sources (a full checkout)")
def test_the_envelope_is_the_engines() -> None:
    for case in json.loads(_CASES.read_text()):
        words = [(s, e) for s, e in case["words"]]
        assert loudness.envelope(case["levels"], words) == case["values"]


def test_nothing_said_is_silence_and_music_between_words_moves_nothing() -> None:
    assert loudness.envelope([-5.0] * 30, []) == [0] * 30
    levels = [-5.0] * 60 + [-10.0] * 30 + [-5.0] * 60
    values = loudness.envelope(levels, [(1.0, 1.5)])
    # The word's own loudest frames (its edges, at -5 dB) are the top: -10 dB is 13 of 18 dB up.
    assert values[10] == 0 and abs(values[75] - 13 / 18 * 255) < 2 and values[140] < 3


def _transcript() -> Transcript:
    return Transcript.model_validate(
        {
            "duration": 2.0,
            "segments": [
                {
                    "id": "s",
                    "start": 0.2,
                    "end": 1.6,
                    "text": "a",
                    "words": [{"text": "a", "start": 0.2, "end": 1.6}],
                }
            ],
        }
    )


def test_a_transcript_without_loudness_is_stored_as_it_was() -> None:
    assert "loudness" not in _transcript().model_dump()


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg not installed")
def test_a_spoken_tone_is_measured_sixty_times_a_second(tmp_path: Path) -> None:
    audio = tmp_path / "a.wav"
    subprocess.run(
        [
            "ffmpeg",
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            "sine=f=1000:d=2",
            "-ar",
            "16000",
            "-ac",
            "1",
            str(audio),
        ],
        check=True,
    )
    out = loudness.with_loudness(audio, _transcript())
    assert out.loudness is not None and out.loudness.rate == 60
    values = base64.b64decode(out.loudness.values)
    assert len(values) == 120
    assert values[5] == 0 and max(values[20:90]) == 255
    assert "loudness" in out.model_dump()


def test_audio_that_cannot_be_measured_leaves_the_transcript(tmp_path: Path) -> None:
    out = loudness.with_loudness(tmp_path / "missing.wav", _transcript())
    assert out.loudness is None
