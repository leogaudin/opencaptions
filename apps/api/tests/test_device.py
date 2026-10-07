"""Unit tests for GPU/CPU device and compute type resolution.

Monkeypatches ctranslate2 functions to simulate GPU presence/absence without
needing actual hardware. Tests the resolution dataclasses, fallback logic,
logging, and compute type validation.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest

from app.transcription.device import (
    ComputeTypeResolution,
    DeviceResolution,
    resolve_compute_type,
    resolve_device,
)


@pytest.fixture(autouse=True)
def _clear_caches() -> None:
    """Clear lru_cache between tests so results don't bleed."""
    resolve_device.cache_clear()
    resolve_compute_type.cache_clear()
    yield
    resolve_device.cache_clear()
    resolve_compute_type.cache_clear()


# === Device Resolution ===


class TestResolveDeviceExplicitCpu:
    def test_explicit_cpu_returns_cpu(self, monkeypatch) -> None:  # noqa: ANN001
        from app.core import config as cfg

        monkeypatch.setattr(cfg.settings, "whisper_device", "cpu")
        result = resolve_device()
        assert isinstance(result, DeviceResolution)
        assert result.resolved == "cpu"
        assert result.requested == "cpu"
        assert result.reason is None


class TestResolveDeviceAuto:
    def test_auto_with_gpu_resolves_to_cuda(self, monkeypatch) -> None:  # noqa: ANN001
        from app.core import config as cfg

        monkeypatch.setattr(cfg.settings, "whisper_device", "auto")
        with patch("app.transcription.device._cuda_device_count", return_value=1):
            result = resolve_device()
        assert result.resolved == "cuda:0"
        assert result.requested == "auto"
        assert result.reason is None

    def test_auto_with_no_gpu_resolves_to_cpu(self, monkeypatch) -> None:  # noqa: ANN001
        from app.core import config as cfg

        monkeypatch.setattr(cfg.settings, "whisper_device", "auto")
        with patch("app.transcription.device._cuda_device_count", return_value=0):
            result = resolve_device()
        assert result.resolved == "cpu"
        assert result.requested == "auto"
        assert result.reason is None

    def test_auto_with_multiple_gpus_uses_first(self, monkeypatch) -> None:  # noqa: ANN001
        from app.core import config as cfg

        monkeypatch.setattr(cfg.settings, "whisper_device", "auto")
        with patch("app.transcription.device._cuda_device_count", return_value=4):
            result = resolve_device()
        assert result.resolved == "cuda:0"


class TestResolveDeviceExplicitCuda:
    def test_explicit_cuda_with_gpu_honoured(self, monkeypatch) -> None:  # noqa: ANN001
        from app.core import config as cfg

        monkeypatch.setattr(cfg.settings, "whisper_device", "cuda")
        with patch("app.transcription.device._cuda_device_count", return_value=1):
            result = resolve_device()
        assert result.resolved == "cuda"
        assert result.requested == "cuda"
        assert result.reason is None

    def test_explicit_cuda_index_with_gpu_honoured(self, monkeypatch) -> None:  # noqa: ANN001
        from app.core import config as cfg

        monkeypatch.setattr(cfg.settings, "whisper_device", "cuda:1")
        with patch("app.transcription.device._cuda_device_count", return_value=2):
            result = resolve_device()
        assert result.resolved == "cuda:1"
        assert result.requested == "cuda:1"
        assert result.reason is None

    def test_explicit_cuda_no_gpu_falls_back_to_cpu(self, monkeypatch) -> None:  # noqa: ANN001
        """The critical bug fix: explicit cuda without a device must not crash."""
        from app.core import config as cfg

        monkeypatch.setattr(cfg.settings, "whisper_device", "cuda")
        with patch("app.transcription.device._cuda_device_count", return_value=0):
            result = resolve_device()
        assert result.resolved == "cpu"
        assert result.requested == "cuda"
        assert result.reason is not None
        assert "No CUDA devices visible" in result.reason

    def test_explicit_cuda_index_no_gpu_falls_back(self, monkeypatch) -> None:  # noqa: ANN001
        from app.core import config as cfg

        monkeypatch.setattr(cfg.settings, "whisper_device", "cuda:0")
        with patch("app.transcription.device._cuda_device_count", return_value=0):
            result = resolve_device()
        assert result.resolved == "cpu"
        assert result.reason is not None


class TestResolveDeviceUnknown:
    def test_unknown_value_falls_back_to_cpu(self, monkeypatch) -> None:  # noqa: ANN001
        from app.core import config as cfg

        monkeypatch.setattr(cfg.settings, "whisper_device", "mps")
        result = resolve_device()
        assert result.resolved == "cpu"
        assert result.reason is not None
        assert "Unrecognized" in result.reason


# === Compute Type Resolution ===


class TestResolveComputeType:
    def test_valid_compute_type_on_cpu(self, monkeypatch) -> None:  # noqa: ANN001
        from app.core import config as cfg

        monkeypatch.setattr(cfg.settings, "whisper_device", "cpu")
        monkeypatch.setattr(cfg.settings, "whisper_compute_type", "int8")
        with (
            patch(
                "app.transcription.device._supported_compute_types",
                return_value={"int8", "float32", "int8_float32"},
            ),
            patch("app.transcription.device._cuda_device_count", return_value=0),
        ):
            result = resolve_compute_type()
        assert isinstance(result, ComputeTypeResolution)
        assert result.resolved == "int8"
        assert result.requested == "int8"
        assert result.reason is None

    def test_float16_on_cpu_falls_back(self, monkeypatch) -> None:  # noqa: ANN001
        """float16 is not supported on CPU: must fall back."""
        from app.core import config as cfg

        monkeypatch.setattr(cfg.settings, "whisper_device", "cpu")
        monkeypatch.setattr(cfg.settings, "whisper_compute_type", "float16")
        with (
            patch(
                "app.transcription.device._supported_compute_types",
                return_value={"int8", "float32", "int8_float32"},
            ),
            patch("app.transcription.device._cuda_device_count", return_value=0),
        ):
            result = resolve_compute_type()
        assert result.resolved == "int8"
        assert result.requested == "float16"
        assert result.reason is not None
        assert "not supported" in result.reason

    def test_valid_compute_type_on_cuda(self, monkeypatch) -> None:  # noqa: ANN001
        from app.core import config as cfg

        monkeypatch.setattr(cfg.settings, "whisper_device", "cuda")
        monkeypatch.setattr(cfg.settings, "whisper_compute_type", "float16")
        with (
            patch(
                "app.transcription.device._supported_compute_types",
                return_value={"int8", "float16", "float32", "int8_float16"},
            ),
            patch("app.transcription.device._cuda_device_count", return_value=1),
        ):
            result = resolve_compute_type()
        assert result.resolved == "float16"
        assert result.reason is None

    def test_unsupported_type_on_cuda_falls_back_to_float16(self, monkeypatch) -> None:  # noqa: ANN001
        from app.core import config as cfg

        monkeypatch.setattr(cfg.settings, "whisper_device", "cuda")
        monkeypatch.setattr(cfg.settings, "whisper_compute_type", "int8_bfloat16")
        with (
            patch(
                "app.transcription.device._supported_compute_types",
                return_value={"int8", "float16", "float32", "int8_float16"},
            ),
            patch("app.transcription.device._cuda_device_count", return_value=1),
        ):
            result = resolve_compute_type()
        assert result.resolved == "float16"
        assert result.requested == "int8_bfloat16"
        assert result.reason is not None

    def test_cuda_query_failure_falls_back_to_cpu_types(self, monkeypatch) -> None:  # noqa: ANN001
        """If CUDA type query raises (broken libs), use CPU types as safety net."""
        from app.core import config as cfg

        monkeypatch.setattr(cfg.settings, "whisper_device", "cpu")
        monkeypatch.setattr(cfg.settings, "whisper_compute_type", "float32")

        def side_effect(device: str) -> set[str]:
            if device == "cuda":
                raise RuntimeError("CUDA driver insufficient")
            return {"int8", "float32", "int8_float32"}

        with (
            patch(
                "app.transcription.device._supported_compute_types",
                side_effect=side_effect,
            ),
            patch("app.transcription.device._cuda_device_count", return_value=0),
        ):
            result = resolve_compute_type()
        assert result.resolved == "float32"
        assert result.reason is None
