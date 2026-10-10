"""Cleaning up the segments a provider returns, whichever provider it was."""

from __future__ import annotations

from uuid import uuid4

from app.models.schemas import Transcript, TranscriptSegment, Word

# A silence is a pause when it is this many times the usual time from one word's start to the next's,
# so it is judged against how fast the speaker talks, not against a clock. The engine holds the same
# rule (`model::pauses`), and both are held to apps/engine/testdata/pauses.json.
PAUSE_PERIODS = 3.0


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
    """The transcript with every segment ended at a pause.

    A segment with no pause inside it is passed through as it came.
    """
    breaks = set(pauses([word for segment in transcript.segments for word in segment.words]))
    segments: list[TranscriptSegment] = []
    first = 0
    for segment in transcript.segments:
        pieces = _split_at(segment.words, first, breaks)
        first += len(segment.words)
        if len(pieces) == 1:
            segments.append(segment)
            continue
        segments.extend(
            _segment_of(segment, piece, segment.id if n == 0 else str(uuid4()))
            for n, piece in enumerate(pieces)
        )
    return transcript.model_copy(update={"segments": segments})
