"""Transcription package — providers self-register on import.

Importing this module pulls in every concrete provider so that
`get_provider("local")` / `get_provider("openai")` resolve.

The local provider lazily imports faster-whisper so this module is cheap.
The openai provider imports httpx (already a dep).
"""

from app.transcription import local as _local  # noqa: F401 — registers
from app.transcription import openai as _openai  # noqa: F401 — registers
from app.transcription.base import TranscriptionProvider, get_provider, register

__all__ = ["TranscriptionProvider", "get_provider", "register"]
