---
title: "Transcript format"
description: "The JSON format OpenCaptions uses for a transcript, with a start and end time for every word. It is what the API returns, what you can edit as text, and what the JSON export contains."
sidebar:
  order: 2
---

# Transcript format

A transcript is one JSON document, the same everywhere: in a project, returned by the
[transcription service](./api.md#transcription-service), downloaded as **JSON** from the editor, and
stored in the iPhone app's project files. A project can move between the phone and a server unchanged.

```json
{
  "schema_version": 1,
  "language": "en",
  "language_detection": "manual",
  "duration": 4.0,
  "segments": [
    {
      "id": "a",
      "start": 0.0,
      "end": 2.0,
      "text": "alpha beta",
      "words": [
        { "text": "alpha", "start": 0.0, "end": 1.0, "confidence": 1.0 },
        { "text": "beta", "start": 1.0, "end": 2.0, "confidence": 1.0 }
      ]
    }
  ]
}
```

## Fields

**Transcript**

| Field | |
|---|---|
| `schema_version` | `1`. |
| `language` | The ISO 639-1 code of the spoken language (`en`, `fr`, `ja`…). |
| `language_detection` | `manual` if the language was chosen, `auto` if it was detected. |
| `duration` | The length of the audio, in seconds. |
| `segments` | A list of segments, in order. |

**Segment**: a run of speech that ends at a pause.

| Field | |
|---|---|
| `id` | A string that identifies the segment. |
| `start`, `end` | Seconds from the start. |
| `text` | The segment's words as one string. |
| `words` | The words, in order. |

**Word**

| Field | |
|---|---|
| `text` | The word as written, with its punctuation. |
| `start`, `end` | Seconds from the start of the audio, at least `0`. |
| `confidence` | `0` to `1`, how sure the model was. Defaults to `1`. |
| `emphasis` | Optional. `true` or `false` is the user's choice of whether the word is a key word (see `emphasis_scale` in the [style reference](./style.md)); absent or `null` leaves it to the rule. Transcription never writes it. |

## Rules

- Times are seconds, as numbers, and never negative.
- Words are in reading order, and a word does not start before the word that comes before it. The editor's text
  dialog names the segment and the word where this fails.
- The captions on screen are made from the words, not from the `text` of a segment: lines are cut every
  *words per line* words, or sooner where the speaker paused.
- The format has no place for styling. A caption's look is a separate [style](./style.md).

## Editing and importing

In the editor, **Edit transcript as text** shows this JSON with a word to a line, and applies a change as
one undoable step. The same dialog **imports** SRT and WebVTT files (with or without per-word times) and
OpenCaptions JSON. An SRT cue has no word times, so its words are spread over the cue, longer words taking longer.
