"""TranscriptionProvider: what a provider implements, and the registry that finds one by name."""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import TYPE_CHECKING, Protocol

from app.models.schemas import Transcript

if TYPE_CHECKING:
    from app.transcription.fetch_progress import FetchPlan


class ProgressCallback(Protocol):
    """Optional callback for streaming progress updates back to the worker."""

    def __call__(self, fraction: float, message: str) -> None: ...


class TranscriptionProvider(ABC):
    """Abstract interface for any transcription backend.

    Implementations: `LocalProvider` (`local`: it runs a WhisperEngine or a SherpaEngine),
    `OpenAIWhisperProvider` (`openai`) and `OpenCaptionsRemoteProvider` (`opencaptions`).
    """

    name: str

    @abstractmethod
    def transcribe(
        self,
        audio_path: str,
        *,
        language: str = "auto",
        model: str | None = None,
        on_progress: ProgressCallback | None = None,
    ) -> Transcript:
        """Run transcription synchronously and return the structured Transcript.

        `audio_path` is a local path to an extracted audio file (16 kHz mono WAV preferred).
        `language` is 'auto' or an ISO 639-1 code.
        `model` is provider-specific (e.g., 'large-v3-turbo' for faster-whisper).
        `on_progress(fraction, message)` is called intermittently if provided.
        """
        ...

    def prepare(self, model: str | None = None) -> None:
        """Load whatever transcribing needs (the weights) before `transcribe` starts.

        Kept apart so a caller can say "Loading model" for the load and "Transcribing" for
        the rest. Nothing to do for a hosted API.
        """
        return None

    def fetch_plan(self, model: str | None = None) -> FetchPlan | None:
        """What `prepare` will download, so a caller can show how far it has got.

        None for a provider with nothing to fetch, or that cannot say.
        """
        return None

    def is_model_cached(self, model: str | None = None) -> bool:
        """Whether the model is ready locally, so a caller can warn before a download.

        True for a provider with nothing to fetch, such as a hosted API.
        """
        return True


_REGISTRY: dict[str, TranscriptionProvider] = {}


def register(provider: TranscriptionProvider) -> TranscriptionProvider:
    """Register a provider instance for runtime lookup."""
    _REGISTRY[provider.name] = provider
    return provider


def get_provider(name: str) -> TranscriptionProvider:
    """Resolve a registered provider by name."""
    if not _REGISTRY:
        from app.transcription.providers import register_defaults

        register_defaults()
    if name not in _REGISTRY:
        raise ValueError(f"Unknown transcription provider: {name!r}. Registered: {list(_REGISTRY)}")
    return _REGISTRY[name]
