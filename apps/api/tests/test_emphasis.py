"""A word the user marks as a key word survives a save: the schema declares it, because Pydantic
drops what it does not know."""

from __future__ import annotations

from typing import Any

import pytest
from httpx import AsyncClient

from app.models.schemas import Word

_TRANSCRIPT: dict[str, Any] = {
    "schema_version": 1,
    "language": "en",
    "language_detection": "auto",
    "duration": 2.0,
    "segments": [
        {
            "id": "s1",
            "start": 0.0,
            "end": 1.5,
            "text": "we grew 40",
            "words": [
                {"text": "we", "start": 0.0, "end": 0.5, "confidence": 1.0, "emphasis": True},
                {"text": "grew", "start": 0.5, "end": 1.0, "confidence": 1.0},
                {"text": "40", "start": 1.0, "end": 1.5, "confidence": 1.0, "emphasis": False},
            ],
        }
    ],
}


def test_a_word_decodes_with_or_without_the_mark() -> None:
    assert Word.model_validate({"text": "a", "start": 0, "end": 1}).emphasis is None
    assert (
        Word.model_validate({"text": "a", "start": 0, "end": 1, "emphasis": None}).emphasis is None
    )
    assert (
        Word.model_validate({"text": "a", "start": 0, "end": 1, "emphasis": True}).emphasis is True
    )


@pytest.mark.asyncio
async def test_the_marks_survive_a_save(user_a: tuple[AsyncClient, Any], seed_project: Any) -> None:
    client, owner = user_a
    pid = await seed_project(owner)
    r = await client.patch(f"/api/v1/projects/{pid}", json={"transcript": _TRANSCRIPT})
    assert r.status_code == 200, r.text
    words = (await client.get(f"/api/v1/projects/{pid}")).json()["transcript"]["segments"][0][
        "words"
    ]
    assert [w.get("emphasis") for w in words] == [True, None, False]
