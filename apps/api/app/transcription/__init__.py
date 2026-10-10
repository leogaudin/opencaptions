"""Transcription package: providers self-register on import.

Importing this module pulls in every concrete provider so that
`get_provider("local")` / `get_provider("openai")` / `get_provider("opencaptions")` resolve.

`local` runs the engine of the chosen model: faster-whisper, or sherpa-onnx for the others.
Both import their libraries lazily so this module is cheap.
The openai provider imports httpx (already a dep).
"""

from app.transcription import local as _local  # noqa: F401, registers
from app.transcription import openai as _openai  # noqa: F401, registers
from app.transcription import remote as _remote  # noqa: F401, registers
from app.transcription import router as _router  # noqa: F401, registers "local"
from app.transcription import sherpa as _sherpa  # noqa: F401, registers
from app.transcription.base import TranscriptionProvider, get_provider, register

__all__ = ["TranscriptionProvider", "get_provider", "register"]
