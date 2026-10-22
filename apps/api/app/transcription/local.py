"""LocalProvider: the one local provider, running whichever engine the chosen model needs.

The engines (faster-whisper, sherpa-onnx) are not providers anyone picks: they are what this one
runs, kept in `ENGINES` by the name `asr_models` gives them.

A model is looked up in `asr_models`; an id nothing lists goes to faster-whisper, as it
always has. A model that covers only some languages is never handed audio in another: the
language is identified first when it was not given, and a recording the model cannot
transcribe is refused, saying which language it is: the person chooses a model that covers it.
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from app.core.config import settings
from app.models.schemas import Transcript
from app.services import asr_models
from app.transcription import language_id
from app.transcription.base import ProgressCallback, TranscriptionProvider
from app.transcription.chunking import read_wav
from app.transcription.sherpa import SherpaEngine, model_dir
from app.transcription.whisper import WhisperEngine

if TYPE_CHECKING:
    from app.transcription.fetch_progress import FetchPlan

logger = logging.getLogger(__name__)


# The engines a model can name (`asr_models.AsrModelInfo.engine`). Each loads its library on first use.
ENGINES: dict[str, TranscriptionProvider] = {
    "faster-whisper": WhisperEngine(),
    "sherpa-onnx": SherpaEngine(),
}


class LanguageNotCoveredError(ValueError):
    """The chosen model does not transcribe the language of the recording."""


class LocalProvider(TranscriptionProvider):
    """Transcription on this machine with the engine of the chosen model."""

    name = "local"

    @staticmethod
    def _engine(model: str | None) -> TranscriptionProvider:
        info = asr_models.find(model)
        return ENGINES[info.engine if info else "faster-whisper"]

    def prepare(self, model: str | None = None) -> None:
        model = model or settings.default_model
        self._engine(model).prepare(model)

    def is_model_cached(self, model: str | None = None) -> bool:
        model = model or settings.default_model
        return self._engine(model).is_model_cached(model)

    def fetch_plan(self, model: str | None = None) -> FetchPlan | None:
        model = model or settings.default_model
        return self._engine(model).fetch_plan(model)

    def transcribe(
        self,
        audio_path: str,
        *,
        language: str = "auto",
        model: str | None = None,
        on_progress: ProgressCallback | None = None,
    ) -> Transcript:
        model = model or settings.default_model
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
        # A language nobody could name is the model's to try; one it is known not to cover is not.
        if spoken and spoken not in info.languages:
            raise LanguageNotCoveredError(
                f"{info.label} does not cover this language ({spoken}). Choose another model."
            )
        transcript = self._engine(model).transcribe(
            audio_path, language=spoken or "auto", model=model, on_progress=on_progress
        )
        if asked_auto:
            transcript = transcript.model_copy(update={"language_detection": "auto"})
        return transcript
