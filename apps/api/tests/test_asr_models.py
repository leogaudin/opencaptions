"""The local model registry and the router that picks an engine from it."""

from __future__ import annotations

from types import SimpleNamespace
from typing import Any

import numpy as np
import pytest

from app.models.schemas import Transcript, TranscriptSegment, Word
from app.services import asr_models
from app.transcription import language_id, router
from app.transcription.base import ProgressCallback, TranscriptionProvider
from app.transcription.sherpa import segments_from_words, words_from_tokens


class TestRegistry:
    def test_every_whisper_size_is_listed_for_faster_whisper(self) -> None:
        whisper = [m for m in asr_models.all_models() if m.engine == "faster-whisper"]
        assert {"tiny", "small", "large-v3-turbo"} <= {m.id for m in whisper}
        assert all(m.languages is None for m in whisper)

    def test_parakeet_is_listed_with_its_languages(self) -> None:
        parakeet = asr_models.find("parakeet-tdt-0.6b-v3")
        assert parakeet is not None
        assert parakeet.engine == "sherpa-onnx"
        assert parakeet.repo
        assert parakeet.languages is not None
        assert {"en", "fr", "de", "es", "ru"} <= parakeet.languages
        # What it was not trained on.
        assert not {"ja", "ko", "zh", "tr", "id"} & parakeet.languages

    def test_models_stay_in_ascending_size_order(self) -> None:
        ids = [m.id for m in asr_models.all_models()]
        assert ids.index("small") < ids.index("parakeet-tdt-0.6b-v3") < ids.index("medium")

    def test_ids_are_unique(self) -> None:
        ids = [m.id for m in asr_models.all_models()]
        assert len(ids) == len(set(ids))

    def test_an_unlisted_id_is_not_found(self) -> None:
        assert asr_models.find("not-a-model") is None
        assert asr_models.find(None) is None


class TestTokens:
    def test_sentencepiece_tokens_become_timed_words(self) -> None:
        words = words_from_tokens(
            [" C", "ute", " little", "."],
            [0.16, 0.24, 0.40, 0.72],
            [0.08, 0.16, 0.32, 0.08],
            [-0.1, -0.1, -0.2, -0.3],
        )
        assert [w[0] for w in words] == ["Cute", "little."]
        assert words[0][1] == pytest.approx(0.16)
        assert words[0][2] == pytest.approx(0.40)
        assert words[1][1] == pytest.approx(0.40)
        assert words[1][2] == pytest.approx(0.80)
        assert all(0.0 < w[3] <= 1.0 for w in words)

    def test_a_word_without_probabilities_is_fully_confident(self) -> None:
        assert words_from_tokens([" hi"], [1.0], [0.1], [])[0][3] == 1.0

    def test_empty_tokens_make_no_words(self) -> None:
        assert words_from_tokens([" "], [0.0], [0.1], [0.0]) == []

    def test_segments_end_at_sentences(self) -> None:
        words = [
            Word(text="Hello", start=0.0, end=0.4),
            Word(text="there.", start=0.4, end=0.9),
            Word(text="How", start=1.2, end=1.4),
            Word(text="are", start=1.4, end=1.6),
            Word(text="you?", start=1.6, end=2.0),
            Word(text="Fine", start=2.4, end=2.8),
        ]
        segments = segments_from_words(words)
        assert [s.text for s in segments] == ["Hello there.", "How are you?", "Fine"]
        assert segments[1].start == 1.2 and segments[1].end == 2.0


class _FakeEngine(TranscriptionProvider):
    def __init__(self, name: str, language: str = "fr") -> None:
        self.name = name
        self.language = language
        self.calls: list[dict[str, Any]] = []
        self.prepared: list[str | None] = []

    def prepare(self, model: str | None = None) -> None:
        self.prepared.append(model)

    def transcribe(
        self,
        audio_path: str,
        *,
        language: str = "auto",
        model: str | None = None,
        on_progress: ProgressCallback | None = None,
    ) -> Transcript:
        self.calls.append({"language": language, "model": model})
        word = Word(text="x", start=0.0, end=1.0)
        return Transcript(
            language=self.language if language in {"auto", ""} else language,
            language_detection="manual" if language not in {"auto", ""} else "auto",
            duration=1.0,
            segments=[TranscriptSegment(id="s", words=[word], start=0.0, end=1.0, text="x")],
        )


@pytest.fixture
def engines(monkeypatch: pytest.MonkeyPatch) -> dict[str, _FakeEngine]:
    fakes = {
        "faster-whisper": _FakeEngine("faster-whisper"),
        "sherpa-onnx": _FakeEngine("sherpa-onnx"),
    }
    monkeypatch.setattr(router, "get_provider", lambda name: fakes[name])
    monkeypatch.setattr(router, "read_wav", lambda _p: np.zeros(16000, dtype=np.float32))
    return fakes


def _identify(monkeypatch: pytest.MonkeyPatch, answer: tuple[str, float] | None) -> None:
    monkeypatch.setattr(language_id, "detect", lambda _s, _d: answer)


class TestRouter:
    def test_a_whisper_model_goes_to_faster_whisper_untouched(
        self, engines: dict[str, _FakeEngine]
    ) -> None:
        router.LocalProvider().transcribe("a.wav", language="auto", model="small")
        assert engines["faster-whisper"].calls == [{"language": "auto", "model": "small"}]
        assert engines["sherpa-onnx"].calls == []

    def test_an_unlisted_model_still_goes_to_faster_whisper(
        self, engines: dict[str, _FakeEngine]
    ) -> None:
        router.LocalProvider().transcribe("a.wav", model="/models/my-finetune")
        assert len(engines["faster-whisper"].calls) == 1

    def test_a_covered_language_runs_on_the_model_and_stays_marked_auto(
        self, engines: dict[str, _FakeEngine], monkeypatch: pytest.MonkeyPatch
    ) -> None:
        _identify(monkeypatch, ("fr", 0.97))
        transcript = router.LocalProvider().transcribe(
            "a.wav", language="auto", model="parakeet-tdt-0.6b-v3"
        )
        assert engines["sherpa-onnx"].calls == [{"language": "fr", "model": "parakeet-tdt-0.6b-v3"}]
        assert transcript.language == "fr"
        assert transcript.language_detection == "auto"

    def test_a_given_language_is_not_identified(
        self, engines: dict[str, _FakeEngine], monkeypatch: pytest.MonkeyPatch
    ) -> None:
        def fail(*_a: Any) -> None:
            raise AssertionError("identification must not run when the language is given")

        monkeypatch.setattr(language_id, "detect", fail)
        transcript = router.LocalProvider().transcribe(
            "a.wav", language="de", model="parakeet-tdt-0.6b-v3"
        )
        assert transcript.language_detection == "manual"

    def test_an_uncovered_language_goes_to_the_default_whisper_model(
        self,
        engines: dict[str, _FakeEngine],
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        _identify(monkeypatch, ("ja", 0.9))
        monkeypatch.setattr(router, "settings", SimpleNamespace(whisper_model="large-v3-turbo"))
        told: list[str] = []
        router.LocalProvider().transcribe(
            "a.wav",
            language="auto",
            model="parakeet-tdt-0.6b-v3",
            on_progress=lambda _f, message: told.append(message),
        )
        assert engines["sherpa-onnx"].calls == []
        assert engines["faster-whisper"].calls == [{"language": "auto", "model": "large-v3-turbo"}]
        assert engines["faster-whisper"].prepared == ["large-v3-turbo"]
        assert any("does not cover" in m and "ja" in m for m in told)

    def test_an_unidentifiable_recording_goes_to_whisper_too(
        self, engines: dict[str, _FakeEngine], monkeypatch: pytest.MonkeyPatch
    ) -> None:
        _identify(monkeypatch, None)
        router.LocalProvider().transcribe("a.wav", language="auto", model="parakeet-tdt-0.6b-v3")
        assert engines["sherpa-onnx"].calls == []
        assert len(engines["faster-whisper"].calls) == 1

    def test_prepare_and_cache_checks_follow_the_model(
        self, engines: dict[str, _FakeEngine]
    ) -> None:
        provider = router.LocalProvider()
        provider.prepare("parakeet-tdt-0.6b-v3")
        provider.prepare("small")
        assert engines["sherpa-onnx"].prepared == ["parakeet-tdt-0.6b-v3"]
        assert engines["faster-whisper"].prepared == ["small"]


class TestLanguageWindows:
    def test_short_audio_is_judged_whole(self) -> None:
        audio = np.zeros(16000 * 10, dtype=np.float32)
        assert len(language_id.sampled_windows(audio)) == 1

    def test_long_audio_is_sampled_in_three_places_through_it(self) -> None:
        audio = np.arange(16000 * 600, dtype=np.float32)
        windows = language_id.sampled_windows(audio)
        assert len(windows) == 3
        assert all(len(w) == 16000 * 30 for w in windows)
        firsts = [w[0] for w in windows]
        assert firsts == sorted(firsts)
        assert firsts[0] > 16000 * 60  # not the opening minute
