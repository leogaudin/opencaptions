"""LocalWhisperProvider: runs faster-whisper in-process on CPU or GPU (the "faster-whisper" engine).

Loads the model lazily, once per worker process, and keeps it for as long as that process
lives. The compose file ends the process after every job (--max-tasks-per-child=1, see why
there), so in that setup a job loads the model itself; reuse across jobs is for a worker
started without that flag. Reports progress via the supplied callback as segments stream in.
"""

from __future__ import annotations

import logging
from threading import Lock
from typing import Any

from app.core.config import settings
from app.models.schemas import Transcript, TranscriptSegment, Word
from app.transcription.base import ProgressCallback, TranscriptionProvider, register
from app.transcription.device import resolve_compute_type, resolve_device
from app.transcription.fetch_progress import FetchPlan
from app.transcription.words import segment_of

logger = logging.getLogger(__name__)

# What the transcription is tuned to, measured (docs/project/speech-model-benchmarks.md) and not
# something an operator should have to guess at: the defaults find all the speech, not the fastest run.
# Everything is decoded: Whisper's own voice-activity filter is never used, because it takes shouting or
# speech over loud music for non-speech and what it drops is never decoded (whole lines go missing).
# A window whose no-speech probability exceeds this, and whose average log probability is below the
# floor, is treated as silence and skipped. Raising it makes the decoder keep more marginal audio.
NO_SPEECH_THRESHOLD = 0.6
# With word timings on, Whisper looping over silence or music is cut where a silence this long
# (seconds) follows a suspect segment: what keeps invented text out of the quiet stretches.
HALLUCINATION_SILENCE_S = 2.0


class LocalWhisperProvider(TranscriptionProvider):
    """faster-whisper backed local transcription."""

    name = "faster-whisper"

    def __init__(self) -> None:
        self._model: Any | None = None
        self._model_name: str | None = None
        self._lock = Lock()

    def _load_model(self, model_name: str) -> Any:
        """Lazy-load and memoize the whisper model."""
        with self._lock:
            if self._model is not None and self._model_name == model_name:
                return self._model
            from faster_whisper import WhisperModel

            device_result = resolve_device()
            compute_result = resolve_compute_type()
            device = device_result.resolved
            compute_type = compute_result.resolved
            # faster-whisper expects 'cuda' or 'cpu', not 'cuda:0', normalize.
            fw_device = "cuda" if device.startswith("cuda") else "cpu"
            device_index = 0
            if device.startswith("cuda:"):
                device_index = int(device.split(":", 1)[1])
            logger.info(
                "Loading faster-whisper model=%s device=%s compute_type=%s",
                model_name,
                device,
                compute_type,
            )
            self._model = WhisperModel(
                model_name,
                device=fw_device,
                device_index=device_index,
                compute_type=compute_type,
                download_root=settings_resolve_model_dir(),
            )
            self._model_name = model_name
            return self._model

    def prepare(self, model: str | None = None) -> None:
        self._load_model(model or settings.default_model)

    def fetch_plan(self, model: str | None = None) -> FetchPlan | None:
        from faster_whisper.utils import _MODELS

        name = model or settings.default_model
        repo = name if "/" in name else _MODELS.get(name)
        if repo is None:
            return None
        return FetchPlan(repo, settings_resolve_model_dir(), patterns=_WEIGHT_FILES)

    def is_model_cached(self, model: str | None = None) -> bool:
        """Whether the weights are on disk, so a caller can say which is about to happen.

        Loading a cached model takes a moment; fetching one takes minutes and several
        gigabytes, and the two are indistinguishable from outside.
        """
        from faster_whisper.utils import download_model

        try:
            download_model(
                model or settings.default_model,
                local_files_only=True,
                cache_dir=settings_resolve_model_dir(),
            )
        except Exception:  # noqa: BLE001, any failure to resolve locally means not cached
            return False
        return True

    def transcribe(
        self,
        audio_path: str,
        *,
        language: str = "auto",
        model: str | None = None,
        on_progress: ProgressCallback | None = None,
    ) -> Transcript:
        model_name = model or settings.default_model
        whisper = self._load_model(model_name)

        whisper_lang = None if language in {"auto", ""} else language
        segments_iter, info = whisper.transcribe(
            audio_path,
            language=whisper_lang,
            word_timestamps=True,
            vad_filter=False,
            no_speech_threshold=NO_SPEECH_THRESHOLD,
            hallucination_silence_threshold=HALLUCINATION_SILENCE_S,
            beam_size=5,
            # Whisper otherwise feeds its own previous output back as context, and
            # once that drifts it can stay drifted, emitting near-empty output for
            # the rest of a long file. Off costs a little cross-sentence coherence
            # and buys back the second half of the video.
            condition_on_previous_text=False,
        )

        detected_lang: str = info.language or "en"
        duration: float = float(info.duration or 0.0)
        was_auto = whisper_lang is None

        segments: list[TranscriptSegment] = []
        dropped_alignments = 0
        for seg in segments_iter:
            words = [
                Word(
                    text=(w.word or "").strip(),
                    start=float(w.start or 0.0),
                    end=float(w.end or 0.0),
                    confidence=float(getattr(w, "probability", 1.0) or 1.0),
                )
                for w in seg.words or []
                if (w.word or "").strip()
            ]
            if not words:
                # Word alignment can fail on a segment Whisper did transcribe. The
                # text is real, so keep it and spread it across the segment's own
                # span rather than discarding speech that was recognised.
                words = _words_from_segment_text(seg)
                if words:
                    dropped_alignments += 1
            if not words:
                continue
            seg_obj = segment_of(words)
            segments.append(seg_obj)
            if on_progress and duration > 0:
                fraction = min(1.0, max(0.0, seg_obj.end / duration))
                on_progress(fraction, f"Transcribed {seg_obj.end:.1f}s / {duration:.1f}s")

        if dropped_alignments:
            logger.warning(
                "word alignment failed on %d segment(s); timings interpolated across each span",
                dropped_alignments,
            )

        # A transcript that covers only the start of a video is the one failure
        # users actually report, and it is invisible from the output alone. Say how
        # far the words reach and how much of the audio they cover, so a thin
        # result names its own cause instead of prompting a guess.
        last_word_end = segments[-1].end if segments else 0.0
        spoken = sum(seg.end - seg.start for seg in segments)
        logger.info(
            "transcribed %.1fs of audio: %d segments, %d words, last word at %.1fs "
            "(%.0f%% of duration covered, model=%s)",
            duration,
            len(segments),
            sum(len(seg.words) for seg in segments),
            last_word_end,
            100.0 * spoken / duration if duration else 0.0,
            model_name,
        )
        silent = _silent_stretches(segments, duration)
        if silent:
            logger.warning(
                "no words for %d stretch(es) of %.0fs or more: %s. %s",
                len(silent),
                SILENT_STRETCH_S,
                ", ".join(f"{a:.0f}s-{b:.0f}s" for a, b in silent[:5]),
                _skipped_hint(),
            )
        if duration > 0 and last_word_end < duration * 0.75:
            logger.warning(
                "transcript stops at %.1fs of %.1fs, the tail produced no words. If there is "
                "speech there, try a larger model",
                last_word_end,
                duration,
            )

        if on_progress:
            on_progress(1.0, "Transcription complete")

        return Transcript(
            schema_version=1,
            language=detected_lang,
            language_detection="auto" if was_auto else "manual",
            duration=duration,
            segments=segments,
        )


# A stretch of audio this long with no word in it is worth a line in the log: it is either
# silence or speech that was skipped, and from the transcript alone they look the same.
SILENT_STRETCH_S = 15.0


def _silent_stretches(
    segments: list[TranscriptSegment], duration: float
) -> list[tuple[float, float]]:
    """The (start, end) of every stretch of `SILENT_STRETCH_S` or more with no word in it."""
    edges = [(0.0, 0.0)] + [(s.start, s.end) for s in segments] + [(duration, duration)]
    return [
        (a_end, b_start)
        for (_, a_end), (b_start, _) in zip(edges, edges[1:], strict=False)
        if b_start - a_end >= SILENT_STRETCH_S
    ]


def _skipped_hint() -> str:
    """Where speech missing from a stretch usually went, for the log line naming the stretch."""
    return (
        "Whisper heard no speech there; if there is some, music or noise under it is the usual "
        "cause (or try a larger model)"
    )


def _words_from_segment_text(seg: Any) -> list[Word]:
    """Spread a segment's text evenly across its own span.

    A fallback for when Whisper transcribed a segment but its word-timestamp
    alignment produced nothing: captions need per-word timings to highlight, and
    even spacing reads far better than dropping the sentence.
    """
    text = (getattr(seg, "text", "") or "").strip()
    tokens = text.split()
    if not tokens:
        return []
    start = float(getattr(seg, "start", 0.0) or 0.0)
    end = float(getattr(seg, "end", 0.0) or 0.0)
    span = max(0.0, end - start) or float(len(tokens)) * 0.3
    step = span / len(tokens)
    return [
        Word(
            text=token,
            start=start + i * step,
            end=start + (i + 1) * step,
            confidence=1.0,
        )
        for i, token in enumerate(tokens)
    ]


# The files faster-whisper fetches for a model (its own `download_model` allow list).
_WEIGHT_FILES = (
    "config.json",
    "preprocessor_config.json",
    "model.bin",
    "tokenizer.json",
    "vocabulary.*",
)


def settings_resolve_model_dir() -> str:
    """Where faster-whisper caches downloaded model weights."""
    return "/models"


# Register at import time so the worker has it available.
register(LocalWhisperProvider())
