"""Marks that come back as words of their own are joined to the word they belong to."""

from __future__ import annotations

from app.models.schemas import Transcript, TranscriptSegment, Word
from app.transcription.words import attach_stray_marks, clean_transcript


def _words(*texts: str) -> list[Word]:
    return [Word(text=t, start=i * 0.5, end=i * 0.5 + 0.4) for i, t in enumerate(texts)]


def _texts(words: list[Word]) -> list[str]:
    return [w.text for w in words]


def test_a_closing_star_rejoins_the_word_it_closes() -> None:
    joined = attach_stray_marks(_words("Ah", "*rires", "*", "oui"))
    assert _texts(joined) == ["Ah", "*rires*", "oui"]
    # The joined word spans both pieces.
    assert (joined[1].start, joined[1].end) == (0.5, 1.4)


def test_an_opening_star_on_its_own_goes_to_the_next_word() -> None:
    assert _texts(attach_stray_marks(_words("*", "rires", "*", "oui"))) == ["*rires*", "oui"]
    joined = attach_stray_marks(_words("*", "rires"))
    assert (joined[0].start, joined[0].end) == (0.0, 0.9)


def test_a_balanced_word_does_not_take_the_next_star() -> None:
    assert _texts(attach_stray_marks(_words("*rires*", "*", "toux", "*"))) == [
        "*rires*",
        "*toux*",
    ]


def test_sentence_punctuation_and_brackets_join_by_their_kind() -> None:
    assert _texts(attach_stray_marks(_words("Quoi", "?!", "Non", "…"))) == ["Quoi?!", "Non…"]
    assert _texts(attach_stray_marks(_words("(", "rires", ")"))) == ["(rires)"]
    assert _texts(attach_stray_marks(_words("«", "Bonjour", "»"))) == ["«Bonjour»"]


def test_anything_that_is_not_plainly_a_mark_stays_a_word() -> None:
    for text in ("♪", "-", "—", "🙂", "&"):
        assert _texts(attach_stray_marks(_words("a", text, "b"))) == ["a", text, "b"]


def test_a_mark_with_nothing_to_join_is_kept() -> None:
    assert _texts(attach_stray_marks(_words("*"))) == ["*"]
    assert _texts(attach_stray_marks(_words(".", "Bonjour"))) == [".", "Bonjour"]
    assert _texts(attach_stray_marks(_words("Bonjour", "("))) == ["Bonjour", "("]


def test_words_without_marks_are_returned_unchanged() -> None:
    words = _words("un", "deux", "trois")
    assert attach_stray_marks(words) == words


def test_a_transcript_gets_its_segment_span_and_text_refreshed() -> None:
    words = _words("*rires", "*", "oui")
    transcript = Transcript(
        duration=3.0,
        segments=[
            TranscriptSegment(id="a", words=words, start=0.0, end=1.4, text="*rires * oui"),
            TranscriptSegment(id="b", words=_words("fin"), start=0.0, end=0.4, text="fin"),
        ],
    )
    cleaned = clean_transcript(transcript)
    first, second = cleaned.segments
    assert _texts(first.words) == ["*rires*", "oui"]
    assert first.text == "*rires* oui"
    assert (first.start, first.end) == (0.0, 1.4)
    assert second is transcript.segments[1], "an untouched segment is passed through"


def test_a_segment_that_spans_a_long_silence_is_split_there() -> None:
    # Said at 0-1s and again at 120s: voice detection stripped the minutes between.
    words = [
        Word(text="un", start=0.0, end=0.5),
        Word(text="deux", start=0.6, end=1.0),
        Word(text="trois", start=120.0, end=120.5),
        Word(text="quatre", start=120.6, end=121.0),
    ]
    transcript = Transcript(
        duration=130.0,
        segments=[TranscriptSegment(id="a", words=words, start=0.0, end=121.0, text="x")],
    )
    first, second = clean_transcript(transcript).segments
    assert (first.id, first.text, first.start, first.end) == ("a", "un deux", 0.0, 1.0)
    assert (second.text, second.start, second.end) == ("trois quatre", 120.0, 121.0)
    assert second.id != first.id


def test_a_short_pause_does_not_split_a_segment() -> None:
    words = [Word(text="un", start=0.0, end=0.5), Word(text="deux", start=1.9, end=2.4)]
    segment = TranscriptSegment(id="a", words=words, start=0.0, end=2.4, text="un deux")
    cleaned = clean_transcript(Transcript(duration=3.0, segments=[segment]))
    assert cleaned.segments == [segment]
