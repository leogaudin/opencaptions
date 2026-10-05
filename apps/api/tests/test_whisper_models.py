"""Unit tests for the Whisper model registry."""

from __future__ import annotations

from app.core.config import settings
from app.services.whisper_models import (
    WHISPER_MODELS,
    WhisperModelInfo,
    all_models,
)


class TestWhisperModelRegistry:
    def test_registry_is_non_empty(self) -> None:
        """The registry must contain at least one model."""
        assert len(WHISPER_MODELS) > 0

    def test_ids_are_unique(self) -> None:
        """Every model id must appear exactly once."""
        ids = [m.id for m in WHISPER_MODELS]
        assert len(ids) == len(set(ids))

    def test_every_model_has_id_and_label(self) -> None:
        """id and label are always populated; note is present (may be empty for
        an upstream model we have not yet annotated)."""
        for m in WHISPER_MODELS:
            assert isinstance(m, WhisperModelInfo)
            assert m.id
            assert m.label
            assert isinstance(m.note, str)

    def test_default_model_is_present(self) -> None:
        """The configured default must be one of the advertised models."""
        ids = {m.id for m in WHISPER_MODELS}
        assert settings.whisper_model in ids
        assert "large-v3-turbo" in ids

    def test_common_models_present(self) -> None:
        """Smoke-check that well-known sizes are in the set."""
        ids = {m.id for m in WHISPER_MODELS}
        for model_id in ("tiny", "base", "small", "medium", "large-v3", "large-v3-turbo"):
            assert model_id in ids, f"{model_id} missing"

    def test_all_models_returns_same_list(self) -> None:
        """all_models() is just the module-level WHISPER_MODELS list."""
        assert all_models() is WHISPER_MODELS
