"""Every speech model the local provider can run, whichever engine runs it.

Whisper sizes come from `whisper_models` (and so from faster-whisper). Other models run on
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


# Parakeet TDT v3 (NVIDIA): the 25 European languages it was trained on.
_PARAKEET_V3_LANGUAGES = frozenset(
    "bg hr cs da nl en et fi fr de el hu it lv lt mt pl pt ro ru sk sl es sv uk".split()  # noqa: SIM905
)

_SHERPA_MODELS: tuple[AsrModelInfo, ...] = (
    AsrModelInfo(
        id="parakeet-tdt-0.6b-v3",
        label="Parakeet v3 (fast)",
        note=(
            "About 2.5x faster than Large v3 Turbo on CPU, somewhat less accurate; "
            "25 European languages only; ~0.65 GB download."
        ),
        engine="sherpa-onnx",
        languages=_PARAKEET_V3_LANGUAGES,
        repo="csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8",
    ),
)

# Where the models other than Whisper sit in the list, which is in ascending size:
# after the Whisper size they are closest to.
_AFTER = {"parakeet-tdt-0.6b-v3": "small"}


def _build() -> list[AsrModelInfo]:
    models = [
        AsrModelInfo(id=m.id, label=m.label, note=m.note, engine="faster-whisper")
        for m in WHISPER_MODELS
    ]
    for extra in _SHERPA_MODELS:
        anchor = next((i for i, m in enumerate(models) if m.id == _AFTER.get(extra.id)), None)
        models.insert(len(models) if anchor is None else anchor + 1, extra)
    return models


ASR_MODELS: list[AsrModelInfo] = _build()


def all_models() -> list[AsrModelInfo]:
    """All selectable local models, in ascending-size order."""
    return ASR_MODELS


def find(model_id: str | None) -> AsrModelInfo | None:
    """The model with this id; None for an id nothing lists (faster-whisper may still take it)."""
    return next((m for m in ASR_MODELS if m.id == model_id), None)
