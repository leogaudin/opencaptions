"""OpenAIWhisperProvider: calls api.openai.com /v1/audio/transcriptions (BYOA path).

The API enforces a 25 MB file ceiling, so we expect the audio service layer to
have already produced a 16 kHz mono WAV. If that is still over the limit, we
re-encode to opus@32 kbps in a temp file (~10× smaller for speech) before upload.

Privacy: audio leaves the machine, so the UI MUST display a disclosure when this provider
is selected. The provider itself does not enforce that, the UI is responsible.
"""

from __future__ import annotations

import contextlib
import logging
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any
from uuid import uuid4

import httpx

from app.core.config import settings
from app.models.schemas import Transcript, TranscriptSegment, Word
from app.transcription.base import ProgressCallback, TranscriptionProvider, register

logger = logging.getLogger(__name__)

OPENAI_AUDIO_ENDPOINT = "https://api.openai.com/v1/audio/transcriptions"
OPENAI_FILE_LIMIT_BYTES = 25 * 1024 * 1024


class OpenAIProviderError(RuntimeError):
    """Wrapped OpenAI API error surfaced to the caller."""


class OpenAIWhisperProvider(TranscriptionProvider):
    """Cloud transcription via OpenAI's hosted Whisper API."""

    name = "openai"

    def transcribe(
        self,
        audio_path: str,
        *,
        language: str = "auto",
        model: str | None = None,
        on_progress: ProgressCallback | None = None,
    ) -> Transcript:
        api_key = settings.openai_api_key or os.environ.get("OPENAI_API_KEY", "")
        if not api_key:
            raise OpenAIProviderError(
                "OpenAI provider selected but no OPENAI_API_KEY configured. "
                "Set it via env or PATCH /api/v1/settings."
            )

        model_name = model or "whisper-1"
        send_path = self._compress_if_needed(audio_path, on_progress)

        if on_progress:
            on_progress(0.1, "Uploading audio to OpenAI")

        try:
            with open(send_path, "rb") as fh:
                data: dict[str, Any] = {
                    "model": model_name,
                    "response_format": "verbose_json",
                    "timestamp_granularities[]": "word",
                }
                if language not in {"auto", ""}:
                    data["language"] = language
                files = {
                    "file": (Path(send_path).name, fh, "audio/wav"),
                }
                with httpx.Client(timeout=httpx.Timeout(600.0, connect=30.0)) as client:
                    resp = client.post(
                        OPENAI_AUDIO_ENDPOINT,
                        headers={"Authorization": f"Bearer {api_key}"},
                        data=data,
                        files=files,
                    )
        finally:
            # Clean up our re-encoded temp file if we created one.
            if send_path != audio_path and os.path.exists(send_path):
                with contextlib.suppress(OSError):
                    os.unlink(send_path)

        if resp.status_code != 200:
            raise OpenAIProviderError(f"OpenAI API returned {resp.status_code}: {resp.text[:500]}")

        payload = resp.json()
        transcript = self._parse_response(payload, language)

        if on_progress:
            on_progress(1.0, f"Transcribed {len(transcript.segments)} segments via OpenAI")

        return transcript

    # --- helpers ---------------------------------------------------------

    def _compress_if_needed(self, audio_path: str, on_progress: ProgressCallback | None) -> str:
        """Re-encode to ogg/opus@32k if the file exceeds OpenAI's 25 MB ceiling."""
        size = os.path.getsize(audio_path)
        if size <= OPENAI_FILE_LIMIT_BYTES:
            return audio_path

        if on_progress:
            on_progress(0.05, f"Audio is {size / 1024 / 1024:.1f} MB, re-encoding for OpenAI limit")
        out_path = str(Path(tempfile.gettempdir()) / f"opencaptions-{uuid4().hex}.ogg")
        cmd = [
            "ffmpeg",
            "-y",
            "-loglevel",
            "warning",
            "-i",
            audio_path,
            "-c:a",
            "libopus",
            "-b:a",
            "32k",
            "-ac",
            "1",
            "-ar",
            "16000",
            out_path,
        ]
        try:
            subprocess.run(cmd, check=True, capture_output=True, text=True)
        except (FileNotFoundError, subprocess.CalledProcessError) as e:
            stderr = getattr(e, "stderr", "") or str(e)
            raise OpenAIProviderError(
                f"Could not re-encode oversized audio for OpenAI: {stderr[:500]}"
            ) from e
        new_size = os.path.getsize(out_path)
        if new_size > OPENAI_FILE_LIMIT_BYTES:
            os.unlink(out_path)
            raise OpenAIProviderError(
                f"Even after re-encoding, audio is {new_size / 1024 / 1024:.1f} MB "
                f"(> {OPENAI_FILE_LIMIT_BYTES / 1024 / 1024:.0f} MB OpenAI ceiling). "
                "Trim or split the source video."
            )
        return out_path

    def _parse_response(self, payload: dict[str, Any], requested_language: str) -> Transcript:
        """Transform verbose_json word-timestamp response into our Transcript schema."""
        words_raw: list[dict[str, Any]] = payload.get("words") or []
        segments_raw: list[dict[str, Any]] = payload.get("segments") or []
        duration = float(payload.get("duration") or 0.0)
        detected_lang = payload.get("language") or "en"
        # OpenAI returns "english", collapse to ISO 639-1 best-effort.
        detected_lang = _normalize_language(detected_lang)

        # Build Word objects from the flat word list.
        all_words = [
            Word(
                text=(w.get("word") or "").strip(),
                start=float(w.get("start") or 0.0),
                end=float(w.get("end") or 0.0),
                confidence=1.0,  # OpenAI doesn't expose word-level confidence
            )
            for w in words_raw
            if (w.get("word") or "").strip()
        ]

        if not all_words:
            # Fallback: treat the whole transcript as one segment with no word timestamps.
            full_text = (payload.get("text") or "").strip()
            return Transcript(
                schema_version=1,
                language=detected_lang,
                language_detection="auto" if requested_language in {"auto", ""} else "manual",
                duration=duration,
                segments=[
                    TranscriptSegment(
                        id=str(uuid4()),
                        words=[Word(text=full_text, start=0.0, end=duration, confidence=1.0)],
                        start=0.0,
                        end=duration,
                        text=full_text,
                    )
                ]
                if full_text
                else [],
            )

        # Group words into segments based on the segments array (preferred) or split on time gaps.
        segments: list[TranscriptSegment] = []
        if segments_raw:
            wi = 0
            for seg in segments_raw:
                seg_start = float(seg.get("start") or 0.0)
                seg_end = float(seg.get("end") or 0.0)
                seg_words: list[Word] = []
                while wi < len(all_words) and all_words[wi].end <= seg_end + 0.05:
                    if all_words[wi].start >= seg_start - 0.05:
                        seg_words.append(all_words[wi])
                    wi += 1
                if not seg_words:
                    continue
                segments.append(
                    TranscriptSegment(
                        id=str(uuid4()),
                        words=seg_words,
                        start=seg_words[0].start,
                        end=seg_words[-1].end,
                        text=(seg.get("text") or " ".join(w.text for w in seg_words)).strip(),
                    )
                )
        else:
            # Group every ~6 words into a segment if no segment metadata.
            chunk = 6
            for i in range(0, len(all_words), chunk):
                grp = all_words[i : i + chunk]
                segments.append(
                    TranscriptSegment(
                        id=str(uuid4()),
                        words=grp,
                        start=grp[0].start,
                        end=grp[-1].end,
                        text=" ".join(w.text for w in grp),
                    )
                )

        return Transcript(
            schema_version=1,
            language=detected_lang,
            language_detection="auto" if requested_language in {"auto", ""} else "manual",
            duration=duration,
            segments=segments,
        )


def _normalize_language(raw: str) -> str:
    """OpenAI returns full English language names; map common ones to ISO 639-1."""
    if not raw:
        return "en"
    raw = raw.lower().strip()
    if len(raw) == 2:
        return raw
    return _LANG_MAP.get(raw, raw[:2])


_LANG_MAP = {
    "english": "en",
    "spanish": "es",
    "french": "fr",
    "german": "de",
    "italian": "it",
    "portuguese": "pt",
    "japanese": "ja",
    "chinese": "zh",
    "korean": "ko",
    "arabic": "ar",
    "russian": "ru",
    "dutch": "nl",
    "polish": "pl",
    "turkish": "tr",
    "hindi": "hi",
    "ukrainian": "uk",
    "swedish": "sv",
    "norwegian": "no",
    "danish": "da",
    "finnish": "fi",
}


# Register at import time.
register(OpenAIWhisperProvider())
