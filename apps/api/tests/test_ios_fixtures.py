"""The iOS app's models mirror the API's schemas; this is the guard that runs everywhere.

The Swift tests decode `transcript.json` into their `Transcript` and round-trip it.
Here the same file must validate as the API's `Transcript`, so a schema change that
the Swift models have not followed fails for contributors without a Mac too.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.models.schemas import Transcript

_IOS = Path(__file__).resolve().parents[2] / "ios"
_FIXTURE = (
    _IOS / "OpenCaptionsKit" / "Tests" / "OpenCaptionsKitTests" / "Fixtures" / "transcript.json"
)

pytestmark = pytest.mark.skipif(not _IOS.is_dir(), reason="needs the iOS app's sources")


def test_the_ios_transcript_fixture_is_a_valid_api_transcript() -> None:
    raw = json.loads(_FIXTURE.read_text())
    assert Transcript.model_validate(raw).model_dump() == raw


def test_the_transcription_api_fixtures_are_what_the_server_sends() -> None:
    """The app's `ServerTranscriber` decodes these same files, so the two ends of the
    transcription API cannot drift apart without one of the suites failing."""
    from app.models.schemas import JobStatus, TranscriptionCapabilities

    fixtures = _FIXTURE.parent
    caps = json.loads((fixtures / "transcription_capabilities.json").read_text())
    assert TranscriptionCapabilities.model_validate(caps).model_dump(mode="json") == caps
    job = json.loads((fixtures / "transcription_job.json").read_text())
    shown = JobStatus.model_validate(job).model_dump(mode="json")
    assert {k: shown[k] for k in job} == {
        **job,
        "created_at": shown["created_at"],
        "updated_at": shown["updated_at"],
    }
    assert shown["project_id"] is None
