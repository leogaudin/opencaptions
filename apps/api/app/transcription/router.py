"""LocalProvider: the one local provider, running whichever engine the chosen model needs.

A model is looked up in `asr_models`; an id nothing lists goes to faster-whisper, as it
always has. A model that covers only some languages is never handed audio in another: the
language is identified first when it was not given, and a recording the model cannot
transcribe goes to the deployment's default Whisper model instead, saying so.
"""

from __future__ import annotations

import logging

from app.core.config import settings
from app.models.schemas import Transcript
from app.services import asr_models
from app.transcription import language_id
from app.transcription.base import (
    ProgressCallback,
    TranscriptionProvider,
    get_provider,
    register,
)
from app.transcription.chunking import read_wav
from app.transcription.sherpa import model_dir

logger = logging.getLogger(__name__)


class LocalProvider(TranscriptionProvider):
    """Transcription on this machine with the engine of the chosen model."""

    name = "local"

    @staticmethod
    def _engine(model: str | None) -> TranscriptionProvider:
        info = asr_models.find(model)
        return get_provider(info.engine if info else "faster-whisper")

    def prepare(self, model: str | None = None) -> None:
        self._engine(model).prepare(model)

    def is_model_cached(self, model: str | None = None) -> bool:
        return self._engine(model).is_model_cached(model)

    def transcribe(
        self,
        audio_path: str,
        *,
        language: str = "auto",
        model: str | None = None,
        on_progress: ProgressCallback | None = None,
    ) -> Transcript:
        info = asr_models.find(model)
        if info is None or info.languages is None:
            return self._engine(model).transcribe(
                audio_path, language=language, model=model, on_progress=on_progress
            )

        asked_auto = language in {"auto", ""}
        spoken = language
        if asked_auto:
            found = language_id.detect(read_wav(audio_path), model_dir())
            spoken = found[0] if found else ""
        if spoken in info.languages:
            transcript = self._engine(model).transcribe(
                audio_path, language=spoken, model=model, on_progress=on_progress
            )
            if asked_auto:
                transcript = transcript.model_copy(update={"language_detection": "auto"})
            return transcript

        fallback = settings.whisper_model
        message = (
            f"{info.label} does not cover this language"
            f"{f' ({spoken})' if spoken else ''}, using {fallback} instead"
        )
        logger.info(message)
        if on_progress:
            on_progress(0.0, message)
        whisper = get_provider("faster-whisper")
        whisper.prepare(fallback)
        return whisper.transcribe(
            audio_path, language=language, model=fallback, on_progress=on_progress
        )


register(LocalProvider())
