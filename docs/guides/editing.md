---
title: "Editing captions"
description: "Fix words, retime captions on the timeline, move the caption on the picture, shift all the timing at once, and undo anything in the OpenCaptions editor."
sidebar:
  order: 2
---

# Editing captions

The editor has the **preview** (the video with the captions drawn over it), the **style panel** beside
it, and the **timeline** underneath. Every edit is saved a moment after the last one, and every edit
can be undone.

## Play, pause and step

| Action | How |
|---|---|
| Play or pause | **Space**, the play button, or a tap on the picture |
| Step one frame | **←** and **→** (not while typing in a field) |
| Mute | The speaker button |
| Seek | Click or drag on the ruler or either track of the timeline |

## Fix a word

Pause the video and **double-click** a word in the preview. Type the correction and press **Enter**.
**Esc** cancels. A few rules:

- A word is edited one at a time and keeps its timing.
- Spaces inside it stay, and it is still one word.
- Clearing the word and pressing Enter **deletes** it.
- With a preset that has several looks (**Editorial**), a row of tiles under the word shows it in each look. Applying such a preset gives words their looks at random (**Shuffle looks** in the Presets tab deals again). Pick a look on the card to change that word; pick the first to put it back. The look is saved with the word and survives renaming it.

## Move the caption

While the video is paused, drag the caption block in the preview. It is pulled towards the centre lines
of the picture, and towards a margin on each side, the top and the bottom (its edge goes to the margin, its
middle to the centre); a thin guide appears when it is on one. Where you drop it is the position
for every caption.

## Retime on the timeline

The timeline has a ruler, a video track and a caption track, with the playhead across them. Each block of
the caption track is one caption line.

- **Select** a block, then drag one of its **edges** to change when it starts or ends. If it touches the
  next caption, that caption's edge is pushed along, down to a minimum length.
- **Zoom** with Ctrl or ⌘ and the mouse wheel, or pinch on a trackpad. The zoom buttons centre on the
  playhead, and **Fit** shows the whole video.

How many words share a line is the **Words per line** setting in the Text tab. A line also breaks where
the speaker paused, so words said minutes apart never share a caption.

## Shift all the captions

If the captions are all a little early or late against the audio, use **Timing** in the style panel.
One setting moves every caption together, in milliseconds (positive is later), and both the preview and
the export use it.

## Undo and redo

**Ctrl or ⌘ + Z** undoes, **Shift + Ctrl or ⌘ + Z** redoes. The buttons beside the zoom do the same. Each
step puts back the transcript, the style and the timing offset together, and a run of the same
change made close together (a slider, a drag of an edge) counts as one step.

## Edit as text, and import subtitles

For what the controls do not do yet, such as splitting or merging captions or retiming many words
at once, **Edit transcript as text** opens the transcript as JSON, one word to a line. Applying it
checks the text first and names the segment and word that are wrong.

The same dialog **imports subtitles**: pick an SRT or WebVTT file (with or without per-word times) or an
OpenCaptions JSON export. It is turned into the transcript text for you to look over before you apply it,
as one undoable step. This is how to caption a video whose subtitles you already have. The format is
described in [Transcript format](../reference/transcript-format.md).

## Autosave

There is no Save button. A change is saved 800 ms after the last one, and the indicator in the editor
shows when it has landed.
