"""The stage a transcription is in is the stage it says: the load, then the work."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

from app.models.schemas import Transcript, TranscriptSegment, Word
from app.services import progress
from app.tasks import transcribe
from app.transcription.base import ProgressCallback, TranscriptionProvider


class _Task:
    """Records what a job would have written down or broadcast."""

    def __init__(self, events: list[tuple[Any, ...]]) -> None:
        self.events = events

    def enter_stage(self, stage: progress.Stage, source: str, **_: object) -> None:
        self.events.append(("stage", stage.message))

    def report_progress(self, fraction: float, message: str, source: str, **_: object) -> None:
        self.events.append(("broadcast", fraction, message))

    def set_job_status(self, status: str, **fields: object) -> None:
        self.events.append(("saved", status, fields))


class _Provider(TranscriptionProvider):
    name = "fake"

    def __init__(self, events: list[tuple[Any, ...]], cached: bool = True) -> None:
        self.events = events
        self.cached = cached

    def is_model_cached(self, model: str | None = None) -> bool:
        return self.cached

    def prepare(self, model: str | None = None) -> None:
        self.events.append(("prepare", model))

    def transcribe(
        self,
        audio_path: str,
        *,
        language: str = "auto",
        model: str | None = None,
        on_progress: ProgressCallback | None = None,
    ) -> Transcript:
        self.events.append(("transcribe",))
        assert on_progress is not None
        on_progress(0.4, "Transcribed 4.0s / 10.0s")
        words = [
            Word(text="*rires", start=0.0, end=0.5),
            Word(text="*", start=0.5, end=0.6),
        ]
        return Transcript(
            duration=10.0,
            segments=[TranscriptSegment(id="a", words=words, start=0.0, end=0.6, text="*rires *")],
        )


@pytest.fixture
def run(monkeypatch: pytest.MonkeyPatch) -> Any:
    def go(
        provider: _Provider, saved_every: float = 0.0
    ) -> tuple[list[tuple[Any, ...]], Transcript]:
        monkeypatch.setattr(transcribe, "PROGRESS_SAVE_EVERY_S", saved_every)
        monkeypatch.setattr("app.transcription.base.get_provider", lambda name: provider)
        task: Any = _Task(provider.events)
        result = transcribe._transcribe_audio(
            task,
            Path("audio.wav"),
            provider="fake",
            model="m",
            language="fr",
        )
        return provider.events, result

    return go


def test_the_stage_moves_from_loading_to_transcribing_once_the_model_is_in(run: Any) -> None:
    events, _ = run(_Provider([]))
    stages = [e for e in events if e[0] in {"stage", "prepare", "transcribe"}]
    assert stages == [
        ("stage", progress.TRANSCRIBE_LOADING_MODEL.message),
        ("prepare", "m"),
        ("stage", progress.TRANSCRIBING.message),
        ("transcribe",),
    ]


def test_a_model_that_must_be_fetched_says_so_before_the_load(run: Any) -> None:
    events, _ = run(_Provider([], cached=False))
    assert events[0] == ("stage", progress.TRANSCRIBE_FETCHING_MODEL.message)


def test_progress_is_written_down_so_a_refreshed_page_reads_it(run: Any) -> None:
    events, _ = run(_Provider([]))
    assert ("broadcast", 0.4, "Transcribed 4.0s / 10.0s") in events
    assert (
        "saved",
        "running",
        {"progress": 0.4, "message": "Transcribed 4.0s / 10.0s"},
    ) in events


def test_progress_is_not_written_more_often_than_it_needs_to_be(run: Any) -> None:
    events, _ = run(_Provider([]), saved_every=3600.0)
    assert not [e for e in events if e[0] == "saved" and "progress" in e[2] and e[2]["progress"]]


def test_the_transcript_comes_back_cleaned(run: Any) -> None:
    _, transcript = run(_Provider([]))
    assert [w.text for w in transcript.segments[0].words] == ["*rires*"]
