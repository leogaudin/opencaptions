"""A model download reports how much of it has arrived."""

from __future__ import annotations

import threading
from pathlib import Path

import pytest

from app.transcription import fetch_progress
from app.transcription.fetch_progress import FetchPlan


def _blobs(tmp_path: Path, repo: str) -> Path:
    blobs = tmp_path / f"models--{repo.replace('/', '--')}" / "blobs"
    blobs.mkdir(parents=True)
    return blobs


def test_the_bytes_on_disk_count_finished_files_and_partial_ones(tmp_path: Path) -> None:
    blobs = _blobs(tmp_path, "org/model")
    (blobs / "aaa").write_bytes(b"x" * 100)
    (blobs / "bbb.incomplete").write_bytes(b"x" * 50)
    assert fetch_progress.bytes_on_disk(FetchPlan("org/model", str(tmp_path))) == 150


def test_nothing_on_disk_yet_is_zero(tmp_path: Path) -> None:
    assert fetch_progress.bytes_on_disk(FetchPlan("org/model", str(tmp_path))) == 0


def test_the_fraction_follows_the_bytes_and_stops_short_of_done(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    plan = FetchPlan("org/model", str(tmp_path))
    sizes = iter([250, 500, 1000, 1000])
    monkeypatch.setattr(fetch_progress, "expected_bytes", lambda _: 1000)
    monkeypatch.setattr(fetch_progress, "bytes_on_disk", lambda _: next(sizes))
    monkeypatch.setattr(fetch_progress, "_POLL_S", 0.01)
    seen: list[float] = []
    enough = threading.Event()

    def report(fraction: float) -> None:
        seen.append(fraction)
        if len(seen) == 3:
            enough.set()

    with fetch_progress.watching(plan, report):
        assert enough.wait(5)
    assert seen[:3] == [0.25, 0.5, 0.99], "a finished download is the stage's to end, not 100%"


def test_a_download_the_hub_cannot_size_reports_nothing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(fetch_progress, "expected_bytes", lambda _: None)
    seen: list[float] = []
    with fetch_progress.watching(FetchPlan("org/model", str(tmp_path)), seen.append):
        pass
    assert seen == []


def test_no_plan_is_no_watching() -> None:
    with fetch_progress.watching(None, lambda _: None):
        pass
