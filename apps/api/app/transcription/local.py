"""LocalWhisperProvider: runs faster-whisper in-process on CPU or GPU (the "faster-whisper" engine).

Loads the model lazily, once per worker process, and keeps it for as long as that process
lives. The compose file ends the process after every job (--max-tasks-per-child=1, see why
there), so in that setup a job loads the model itself; reuse across jobs is for a worker
started without that flag. Reports progress via the supplied callback as segments stream in.
"""

from __future__ import annotations

import logging
import wave
from threading import Lock
from typing import Any

from app.core.config import settings
from app.models.schemas import Transcript, TranscriptSegment, Word
from app.transcription import chunking
from app.transcription.base import ProgressCallback, TranscriptionProvider, register
from app.transcription.device import resolve_compute_type, resolve_device
from app.transcription.fetch_progress import FetchPlan
from app.transcription.words import segment_of

logger = logging.getLogger(__name__)

# Voice-activity filtering is off: it decides what is speech with a model that takes shouting or speech over
# loud music for non-speech, and what it drops is never decoded, so whole lines go missing (on a test film it
# lost five of six lines that decoding everything found, whatever the threshold). Decoding everything costs
# more CPU on content with long silences, which is the price of finding all the speech.
VAD_FILTER = False
# faster-whisper moves on from a 30 s window when the model says "no speech after here", and never decodes
# what the window still holds: shouting or singing over music can come back as a long empty stretch. The
# second look decodes each empty stretch of FILL_GAP_S seconds that is not quiet again alone, twice with the
# window shifted, and keeps only the words both readings give (text invented over music differs between the
# two). Off: on a 10-minute film it costs about five times the transcription time for a dozen words.
FILL_GAPS = False
# What the transcription is tuned to, measured (docs/project/speech-model-benchmarks.md) and not
# something an operator should have to guess at: the defaults find all the speech, not the fastest run.
# The voice-activity threshold, when VAD_FILTER is on.
VAD_THRESHOLD = 0.5
# A window whose no-speech probability exceeds this, and whose average log probability is below the
# floor, is treated as silence and skipped. Raising it makes the decoder keep more marginal audio.
NO_SPEECH_THRESHOLD = 0.6
# With word timings on, Whisper looping over silence or music is cut where a silence this long
# (seconds) follows a suspect segment: what keeps invented text out of the quiet stretches.
HALLUCINATION_SILENCE_S = 2.0
# The second look (FILL_GAPS): an empty stretch at least this long (seconds) that is not
# quiet is decoded again, and the second look examines at most FILL_BUDGET of the recording.
FILL_GAP_S = 5.0
FILL_BUDGET = 0.5


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
            vad_filter=VAD_FILTER,
            vad_parameters={"threshold": VAD_THRESHOLD}
            if VAD_FILTER
            else None,
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

        # The first pass reports up to this share; the second look, when it runs, the rest.
        first_pass_share = _first_pass_share()
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
                fraction = min(1.0, max(0.0, seg_obj.end / duration)) * first_pass_share
                on_progress(fraction, f"Transcribed {seg_obj.end:.1f}s / {duration:.1f}s")

        if dropped_alignments:
            logger.warning(
                "word alignment failed on %d segment(s); timings interpolated across each span",
                dropped_alignments,
            )

        segments = self._second_look(
            whisper, audio_path, segments, detected_lang, duration, on_progress
        )

        # A transcript that covers only the start of a video is the one failure
        # users actually report, and it is invisible from the output alone. Say how
        # far the words reach and how much of the audio they cover, so a thin
        # result names its own cause instead of prompting a guess.
        last_word_end = segments[-1].end if segments else 0.0
        spoken = sum(seg.end - seg.start for seg in segments)
        logger.info(
            "transcribed %.1fs of audio: %d segments, %d words, last word at %.1fs "
            "(%.0f%% of duration covered, vad_filter=%s threshold=%.2f model=%s)",
            duration,
            len(segments),
            sum(len(seg.words) for seg in segments),
            last_word_end,
            100.0 * spoken / duration if duration else 0.0,
            VAD_FILTER,
            VAD_THRESHOLD,
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

    @staticmethod
    def _second_look(
        whisper: Any,
        audio_path: str,
        segments: list[TranscriptSegment],
        language: str,
        duration: float,
        on_progress: ProgressCallback | None,
    ) -> list[TranscriptSegment]:
        """The segments, plus whatever a second look finds in the long stretches with no words.

        See `chunking.second_look` for why a stretch can be empty though someone speaks in it.
        A recording that cannot be read again is returned as it was, and so is any when the
        second look is off.
        """
        if not FILL_GAPS or duration <= 0:
            return segments
        gaps = chunking.long_gaps(
            [(w.start, w.end) for seg in segments for w in seg.words],
            duration,
            FILL_GAP_S,
        )
        if not gaps:
            return segments
        try:
            samples = chunking.read_wav(audio_path)
        except (OSError, EOFError, wave.Error):
            logger.warning(
                "second look skipped: %s could not be read again as a WAV file", audio_path
            )
            return segments
        if on_progress:
            on_progress(0.9, "Looking again at long stretches with no words")

        def decode(window: Any) -> chunking.Words:
            found, _ = whisper.transcribe(
                window,
                language=language,
                word_timestamps=True,
                vad_filter=False,
                no_speech_threshold=NO_SPEECH_THRESHOLD,
                hallucination_silence_threshold=HALLUCINATION_SILENCE_S,
                beam_size=5,
                condition_on_previous_text=False,
            )
            return [
                (
                    (w.word or "").strip(),
                    float(w.start or 0.0),
                    float(w.end or 0.0),
                    float(getattr(w, "probability", 1.0) or 1.0),
                )
                for seg in found
                for w in seg.words or []
                if (w.word or "").strip()
            ]

        kept = chunking.second_look(
            decode, samples, gaps, budget_s=duration * FILL_BUDGET
        )
        logger.info(
            "second look at %d stretch(es) with no words: %d word(s) found", len(gaps), len(kept)
        )
        added: list[TranscriptSegment] = []
        for gap_start, gap_end in gaps:
            words = [
                Word(
                    text=text,
                    start=max(gap_start, start),
                    end=min(gap_end, max(end, start)),
                    confidence=min(1.0, max(0.0, confidence)),
                )
                for text, start, end, confidence in kept
                if gap_start - 0.05 <= start < gap_end
            ]
            if words:
                added.append(segment_of(words))
        return sorted(segments + added, key=lambda seg: seg.start)


def _first_pass_share() -> float:
    """The share of the progress bar the first pass fills; the second look has the rest."""
    return 0.9 if FILL_GAPS else 1.0


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
    if VAD_FILTER:
        return (
            "Real speech there was skipped by voice detection or by the no-speech check; music or noise under it is the usual cause"
        )
    return (
        "Everything was decoded, so Whisper heard no speech there; if there is some, music or "
        "noise under it is the usual cause (or try a larger model)"
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
