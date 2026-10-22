"""Transcription: providers (`local`, `openai`, `opencaptions`) and the engines `local` runs.

A provider is registered by `providers.register_defaults()`, which `get_provider` calls the first time
a name is asked for; nothing registers itself by being imported. `local` runs the engine of the chosen
model (`local.ENGINES`: faster-whisper, or sherpa-onnx for the others), and each imports its library
lazily, so importing this package is cheap.
"""

from app.transcription.base import TranscriptionProvider, get_provider, register

__all__ = ["TranscriptionProvider", "get_provider", "register"]
