"""Every speech model the local provider can run, whichever engine runs it.

Whisper sizes are described in `whisper_models` (the offered ones are named below). Other models run on
sherpa-onnx (ONNX Runtime, CPU), each fetched from the Hugging Face repository named here on
first use. A model is added by describing it here; the provider seam above it does not change.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

from app.services.whisper_models import WHISPER_MODELS

Engine = Literal["faster-whisper", "sherpa-onnx"]


@dataclass(frozen=True, slots=True)
class AsrModelInfo:
    """A selectable local model."""

    id: str
    label: str
    note: str
    engine: Engine
    # ISO 639-1 codes the model transcribes; None when it takes any language Whisper does.
    languages: frozenset[str] | None = None
    # Hugging Face repository holding the files (engines other than faster-whisper).
    repo: str | None = None
    # The commit of that repository to fetch: a repository's latest files can change under us.
    revision: str | None = None

    @property
    def language_codes(self) -> list[str] | None:
        """`languages` as a sorted list for the API; None when the model takes any language."""
        return None if self.languages is None else sorted(self.languages)


# Parakeet TDT v3 (NVIDIA) and Ultra (Moondream, trained from it): the 25 European languages.
_PARAKEET_LANGUAGES = frozenset(
    "bg hr cs da nl en et fi fr de el hu it lv lt mt pl pt ro ru sk sl es sv uk".split()  # noqa: SIM905
)

_SHERPA_MODELS: tuple[AsrModelInfo, ...] = (
    AsrModelInfo(
        id="parakeet-ultra",
        label="Parakeet Ultra (fast)",
        note=(
            "About 2.5x faster than Large v3 on CPU, a little less accurate; "
            "25 European languages only; ~0.65 GB download."
        ),
        engine="sherpa-onnx",
        languages=_PARAKEET_LANGUAGES,
        repo="leogaudin/sherpa-onnx-nemo-parakeet-ultra-int8",
        revision="f7bc472677ff70be95cdb0ef9df509fee6f5ec0b",
    ),
)

# What is offered: the iPhone app's list, so a person has the same choice on either. Other
# faster-whisper sizes still run (an API client may name one, and so may `DEFAULT_MODEL`); they
# are only not listed, because a longer ladder is noise to choose from.
_OFFERED_WHISPER = ("small", "large-v3-turbo")

# Where the models other than Whisper sit in the list, which is in ascending size:
# after the Whisper size they are closest to.
_AFTER = {"parakeet-ultra": "small"}


def _build() -> list[AsrModelInfo]:
    by_id = {m.id: m for m in WHISPER_MODELS}
    models = [
        AsrModelInfo(id=m.id, label=m.label, note=m.note, engine="faster-whisper")
        for m in (by_id[i] for i in _OFFERED_WHISPER if i in by_id)
    ]
    for extra in _SHERPA_MODELS:
        anchor = next((i for i, m in enumerate(models) if m.id == _AFTER.get(extra.id)), None)
        models.insert(len(models) if anchor is None else anchor + 1, extra)
    return models


ASR_MODELS: list[AsrModelInfo] = _build()


def all_models() -> list[AsrModelInfo]:
    """All selectable local models, in ascending-size order."""
    return ASR_MODELS


def is_listed(model_id: str) -> bool:
    """Whether the local provider may be asked for this model: one of the offered models or a
    faster-whisper size. Anything else (a `repo/name`, a path) would be fetched or read by
    faster-whisper as the name of a Hugging Face repository or a directory."""
    return model_id in {m.id for m in ASR_MODELS} or model_id in {m.id for m in WHISPER_MODELS}


def find(model_id: str | None) -> AsrModelInfo | None:
    """The model with this id; None for an id nothing lists (faster-whisper may still take it)."""
    return next((m for m in ASR_MODELS if m.id == model_id), None)
