"""The transcription providers a request can name, registered in one place.

`local` runs a model on this machine (faster-whisper or sherpa-onnx, by the model), `openai` sends the
audio to OpenAI's transcription API and `opencaptions` to another OpenCaptions instance.
"""

from __future__ import annotations

from app.transcription.base import register
from app.transcription.local import LocalProvider
from app.transcription.openai import OpenAIWhisperProvider
from app.transcription.remote import OpenCaptionsRemoteProvider


def register_defaults() -> None:
    """Make the three providers resolvable by name (`get_provider`). Safe to call again."""
    for provider in (LocalProvider(), OpenAIWhisperProvider(), OpenCaptionsRemoteProvider()):
        register(provider)
