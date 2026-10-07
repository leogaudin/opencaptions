"""Model registry for local transcription.

Sizes come from faster_whisper.available_models() so GET /settings advertises
what the library really offers, with our own metadata for each.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

logger = logging.getLogger(__name__)

# Curated label + size/speed note for every faster-whisper model size.
# Keys mirror faster_whisper.available_models(); insertion order is the
# fallback order used when the library is not importable.
_ID_TO_META: dict[str, tuple[str, str]] = {
    "tiny.en": ("Tiny (English-only)", "Fastest, lowest accuracy; ~75 MB download. English-only."),
    "tiny": ("Tiny", "Fastest, lowest accuracy; ~75 MB download."),
    "base.en": (
        "Base (English-only)",
        "Very fast, basic accuracy; ~145 MB download. English-only.",
    ),
    "base": ("Base", "Very fast, basic accuracy; ~145 MB download."),
    "small.en": ("Small (English-only)", "Fast, decent accuracy; ~480 MB download. English-only."),
    "small": ("Small", "Fast, decent accuracy; ~480 MB download."),
    "medium.en": (
        "Medium (English-only)",
        "Moderate speed, good accuracy; ~1.5 GB download. English-only.",
    ),
    "medium": ("Medium", "Moderate speed, good accuracy; ~1.5 GB download."),
    "large-v1": ("Large v1", "Slow on CPU, high accuracy; ~3 GB download."),
    "large-v2": ("Large v2", "Slow on CPU, high accuracy; ~3 GB download."),
    "large-v3": ("Large v3", "Slow on CPU, highest accuracy; ~3 GB download."),
    "large": ("Large (latest)", "Alias for the newest large model; slow on CPU; ~3 GB download."),
    "distil-large-v2": (
        "Distil-Large v2",
        "Distilled large-v2: near-large accuracy, roughly 2x faster; ~1.5 GB download.",
    ),
    "distil-medium.en": (
        "Distil-Medium (English-only)",
        "Distilled medium: fast, good accuracy; ~800 MB download. English-only.",
    ),
    "distil-small.en": (
        "Distil-Small (English-only)",
        "Distilled small: very fast, basic accuracy; ~330 MB download. English-only.",
    ),
    "distil-large-v3": (
        "Distil-Large v3",
        "Distilled large-v3: near-large accuracy, roughly 2x faster; ~1.5 GB download.",
    ),
    "distil-large-v3.5": (
        "Distil-Large v3.5",
        "Distilled large-v3.5: near-large accuracy, roughly 2x faster; ~1.5 GB download.",
    ),
    "large-v3-turbo": (
        "Large v3 Turbo",
        "Large-v3 accuracy at a fraction of the runtime; ~1.6 GB download.",
    ),
    "turbo": ("Turbo (Large v3)", "Alias for large-v3-turbo; ~1.6 GB download."),
}


@dataclass(frozen=True, slots=True)
class WhisperModelInfo:
    """Immutable descriptor for a selectable local Whisper model size."""

    id: str
    label: str
    note: str


def _build_registry() -> list[WhisperModelInfo]:
    """Build the list from faster-whisper, falling back to the metadata keys."""
    try:
        from faster_whisper import available_models

        ids: tuple[str, ...] = tuple(available_models())
    except ImportError:
        logger.warning("faster-whisper not importable, falling back to hardcoded model ids")
        ids = tuple(_ID_TO_META.keys())

    models: list[WhisperModelInfo] = []
    for model_id in ids:
        meta = _ID_TO_META.get(model_id)
        if meta is None:
            # Defensive fallback: new model added upstream but not in our table.
            label, note = model_id, ""
            logger.warning(
                "Whisper model %r has no metadata in the registry, using %r. "
                "Please update _ID_TO_META in app/services/whisper_models.py.",
                model_id,
                label,
            )
        else:
            label, note = meta
        models.append(WhisperModelInfo(id=model_id, label=label, note=note))

    return models


# Module-level singleton, built once at import time.
WHISPER_MODELS: list[WhisperModelInfo] = _build_registry()


def all_models() -> list[WhisperModelInfo]:
    """Return all selectable local Whisper models, in ascending-size order."""
    return WHISPER_MODELS
