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
