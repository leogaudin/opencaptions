"""GPU/CPU device resolution for transcription workers.

Detection goes through ctranslate2, the library faster-whisper actually infers
with, so the answer matches what inference will do and torch is never pulled in.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from functools import lru_cache

import ctranslate2

from app.core.config import settings

logger = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class DeviceResolution:
    """Result of device resolution with provenance for diagnostics."""

    requested: str
    resolved: str
    reason: str | None = None


@dataclass(frozen=True, slots=True)
class ComputeTypeResolution:
    """Result of compute type resolution with provenance for diagnostics."""

    requested: str
    resolved: str
    reason: str | None = None


def _cuda_device_count() -> int:
    """Wrapper around ctranslate2 for testability."""
    return int(ctranslate2.get_cuda_device_count())


def _supported_compute_types(device: str) -> set[str]:
    """Get compute types ctranslate2 supports for a device.

    For 'cuda', this RAISES RuntimeError when CUDA is unusable — callers must
    guard accordingly.
    """
    return set(ctranslate2.get_supported_compute_types(device))


@lru_cache(maxsize=1)
def resolve_device() -> DeviceResolution:
    """Resolve the configured device to 'cpu' or 'cuda:N'.

    An explicit cuda request that cannot be honoured falls back to cpu and logs
    at ERROR, which surfaces in /health rather than failing the worker.
    """
    requested = settings.whisper_device.strip().lower()

    if requested == "cpu":
        return DeviceResolution(requested=requested, resolved="cpu")

    if requested == "auto":
        count = _cuda_device_count()
        if count > 0:
            logger.info("WHISPER_DEVICE=auto resolved to cuda:0 (%d device(s) visible)", count)
            return DeviceResolution(requested="auto", resolved="cuda:0")
        logger.info("WHISPER_DEVICE=auto resolved to cpu (no CUDA devices visible)")
        return DeviceResolution(requested="auto", resolved="cpu")

    # Explicit cuda or cuda:N — validate that the device actually exists.
    if requested.startswith("cuda"):
        count = _cuda_device_count()
        if count == 0:
            reason = (
                "No CUDA devices visible to ctranslate2. "
                "Likely causes: container not given GPU access (--gpus / deploy.resources), "
                "or the image lacks CUDA runtime libraries (use the GPU image target)."
            )
            logger.error(
                "WHISPER_DEVICE=%s requested but no CUDA device available — falling back to cpu. %s",
                requested,
                reason,
            )
            return DeviceResolution(requested=requested, resolved="cpu", reason=reason)
        logger.info("WHISPER_DEVICE=%s honoured (%d device(s) visible)", requested, count)
        return DeviceResolution(requested=requested, resolved=requested)

    logger.warning("Unknown WHISPER_DEVICE=%r, falling back to cpu", requested)
    return DeviceResolution(
        requested=requested,
        resolved="cpu",
        reason=f"Unrecognized device value '{requested}'",
    )


@lru_cache(maxsize=1)
def resolve_compute_type() -> ComputeTypeResolution:
    """Resolve and validate compute type against the resolved device.

    When the requested compute type is not supported by the resolved device
    (e.g. float16 on CPU), falls back to a supported default with a WARNING.
    """
    explicit = settings.whisper_compute_type.strip().lower()
    device_result = resolve_device()
    # Normalize device for ctranslate2 query: 'cuda:0' → 'cuda', 'cpu' → 'cpu'
    ct2_device = "cuda" if device_result.resolved.startswith("cuda") else "cpu"

    # Get supported types for the resolved device.
    try:
        supported = _supported_compute_types(ct2_device)
    except RuntimeError:
        # CUDA query failed — device resolved to cuda but libs are broken.
        # Fall back to safe CPU defaults.
        supported = _supported_compute_types("cpu")

    if explicit in supported:
        return ComputeTypeResolution(requested=explicit, resolved=explicit)

    # Requested type not supported — pick a safe default.
    fallback = "int8" if ct2_device == "cpu" else "float16"
    if fallback not in supported:
        # Last resort: pick any supported type.
        fallback = next(iter(supported))

    reason = (
        f"Compute type '{explicit}' is not supported on device '{device_result.resolved}' "
        f"(supported: {sorted(supported)}). Falling back to '{fallback}'."
    )
    logger.warning(reason)
    return ComputeTypeResolution(requested=explicit, resolved=fallback, reason=reason)
