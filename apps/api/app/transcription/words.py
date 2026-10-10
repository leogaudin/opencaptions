"""Cleaning up the words a provider returns, whichever provider it was.

Whisper's tokenizer can split a mark off the word it belongs to: "*rires*" comes back as
"*rires" and "*", and each piece is timed and drawn as a word of its own. The decoders only
re-attach the punctuation they know of, and not every mark Whisper writes is among it, so
this does it again for all of them, after the fact.
"""

from __future__ import annotations

from uuid import uuid4

from app.models.schemas import Transcript, TranscriptSegment, Word

# A silence is a pause when it is this many times the usual time from one word's start to the next's,
# so it is judged against how fast the speaker talks, not against a clock. The engine holds the same
# rule (`model::pauses`), and both are held to apps/engine/testdata/pauses.json.
PAUSE_PERIODS = 3.0

# A mark on its own belongs to the word before it, or to the word after it, by its kind.
_TRAILING = frozenset(".,;:!?…。、，！？：；)]}»›”’")
_LEADING = frozenset("([{«‹“‘¿¡")
# One mark opens and closes ("*rires*"), so which it is depends on whether the word before it is
# still open. Quotes and apostrophes are left out: the decoders already attach them.
_PAIRED = frozenset("*_~")


def _is_mark(text: str, kinds: frozenset[str]) -> bool:
    return bool(text) and all(c in kinds for c in text)


def _joins_previous(mark: str, previous: Word | None) -> bool:
    """Whether a mark on its own closes the word before it rather than opening the next."""
    if previous is None:
        return False
    if _is_mark(mark, _TRAILING):
        return True
    return _is_mark(mark, _PAIRED) and previous.text.count(mark[0]) % 2 == 1


def attach_stray_marks(words: list[Word]) -> list[Word]:
    """The same words with every mark that came back on its own joined to its neighbour.

    A mark with no neighbour to join, or one that is not clearly punctuation (a music note,
    a dash, an emoji), stays a word of its own. A joined word keeps the span of both pieces.
    """
    out: list[Word] = []
    opening: Word | None = None  # a mark waiting for the word it opens
    for word in words:
        text = word.text.strip()
        is_mark = _is_mark(text, _TRAILING | _LEADING | _PAIRED)
        if is_mark and _joins_previous(text, out[-1] if out else None):
            joined = out[-1]
            out[-1] = joined.model_copy(
                update={"text": joined.text + text, "end": max(joined.end, word.end)}
            )
        elif is_mark and (_is_mark(text, _LEADING) or _is_mark(text, _PAIRED)):
            if opening is not None:
                out.append(opening)
            opening = word
        else:
            if opening is not None:
                word = word.model_copy(
                    update={
                        "text": opening.text.strip() + text,
                        "start": min(opening.start, word.start),
                    }
                )
                opening = None
            out.append(word)
    if opening is not None:
        out.append(opening)
    return out


def pauses(words: list[Word]) -> list[int]:
    """The index of every word that comes after a pause.

    The usual time between words is the median start-to-start gap, which pauses (being few) do
    not move. With voice detection on, Whisper decodes the speech with the silence cut out, so
    one segment can hold the last words before a minute of quiet and the first after it; the
    times are restored afterwards, the segment is not.
    """
    periods = sorted(
        d for a, b in zip(words, words[1:], strict=False) if (d := b.start - a.start) > 0
    )
    if not periods:
        return []
    limit = PAUSE_PERIODS * periods[len(periods) // 2]
    return [i for i in range(1, len(words)) if words[i].start - words[i - 1].end > limit]


def _split_at(words: list[Word], first: int, breaks: set[int]) -> list[list[Word]]:
    """`words` cut before each index in `breaks`, `first` being the index of the first of them."""
    pieces: list[list[Word]] = [[]]
    for offset, word in enumerate(words):
        if pieces[-1] and first + offset in breaks:
            pieces.append([])
        pieces[-1].append(word)
    return pieces


def _segment_of(
    segment: TranscriptSegment, words: list[Word], segment_id: str
) -> TranscriptSegment:
    return segment.model_copy(
        update={
            "id": segment_id,
            "words": words,
            "start": words[0].start,
            "end": words[-1].end,
            "text": " ".join(w.text for w in words).strip(),
        }
    )


def clean_transcript(transcript: Transcript) -> Transcript:
    """The transcript with stray marks joined and every segment ended at a pause.

    A segment that needs neither is passed through as it came.
    """
    joined = [attach_stray_marks(segment.words) for segment in transcript.segments]
    breaks = set(pauses([word for words in joined for word in words]))
    segments: list[TranscriptSegment] = []
    first = 0
    for segment, words in zip(transcript.segments, joined, strict=True):
        pieces = _split_at(words, first, breaks)
        first += len(words)
        if not words or (len(pieces) == 1 and len(words) == len(segment.words)):
            segments.append(segment)
            continue
        segments.extend(
            _segment_of(segment, piece, segment.id if n == 0 else str(uuid4()))
            for n, piece in enumerate(pieces)
        )
    return transcript.model_copy(update={"segments": segments})
