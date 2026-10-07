"""Audio extraction smoke test. Generates a 1-second silent WAV with ffmpeg
and round-trips it through extract_audio. Skipped if ffmpeg is unavailable.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

from app.services import audio
from app.services.audio import AudioExtractionError, extract_audio, probe_duration


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg not installed")
def test_extract_audio_round_trip(tmp_path: Path) -> None:
    src = tmp_path / "silent.mp4"
    out = tmp_path / "audio.wav"

    # Generate a 1-second silent MP4 via ffmpeg's lavfi source.
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "anullsrc=channel_layout=mono:sample_rate=16000",
            "-f",
            "lavfi",
            "-i",
            "color=c=black:s=64x64:d=1",
            "-shortest",
            "-c:v",
            "libx264",
            "-c:a",
            "aac",
            str(src),
        ],
        check=True,
        capture_output=True,
    )

    extract_audio(src, out)
    assert out.exists()
    assert out.stat().st_size > 0
    duration = probe_duration(out)
    assert 0.5 <= duration <= 2.0


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg not installed")
def test_extract_audio_missing_input_raises(tmp_path: Path) -> None:
    with pytest.raises(AudioExtractionError):
        extract_audio(tmp_path / "nope.mp4", tmp_path / "out.wav")


def _probe_with_stream(
    monkeypatch: pytest.MonkeyPatch, stream: dict[str, object]
) -> dict[str, object]:
    """Run probe_video_metadata against a synthetic ffprobe payload."""
    payload = json.dumps({"streams": [stream], "format": {"duration": "3.0"}})
    monkeypatch.setattr(audio.subprocess, "check_output", lambda *_a, **_k: payload)
    return dict(audio.probe_video_metadata("/tmp/whatever.mov"))


def test_display_rotation_swaps_the_reported_dimensions(monkeypatch: pytest.MonkeyPatch) -> None:
    """A phone records portrait as landscape frames plus a rotation.

    Reading the stream dimensions alone shows such a clip as landscape, which then
    drives the preview, the render geometry and the render hash, so the video is
    letterboxed into the wrong aspect and overflows its container.
    """
    landscape_frames = {
        "width": 1920,
        "height": 1080,
        "avg_frame_rate": "30/1",
        "duration": "3.0",
    }

    upright = _probe_with_stream(monkeypatch, landscape_frames)
    assert (upright["width"], upright["height"]) == (1920, 1080)

    # Modern files carry it as Display Matrix side data.
    quarter_turn = _probe_with_stream(
        monkeypatch,
        {
            **landscape_frames,
            "side_data_list": [{"side_data_type": "Display Matrix", "rotation": -90}],
        },
    )
    assert (quarter_turn["width"], quarter_turn["height"]) == (1080, 1920)

    # Older files carry it as a rotate tag; both must be honoured.
    tagged = _probe_with_stream(monkeypatch, {**landscape_frames, "tags": {"rotate": "270"}})
    assert (tagged["width"], tagged["height"]) == (1080, 1920)

    # A half turn keeps the axes, so the dimensions must not move.
    half_turn = _probe_with_stream(
        monkeypatch,
        {
            **landscape_frames,
            "side_data_list": [{"side_data_type": "Display Matrix", "rotation": 180}],
        },
    )
    assert (half_turn["width"], half_turn["height"]) == (1920, 1080)
