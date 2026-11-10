---
name: caption-videos
description: Add animated word-by-word captions or subtitles to a video with OpenCaptions. Use when the user asks to caption, subtitle or transcribe a video, a reel or a short, or wants a captions layer for Remotion or a video editor.
---

# Captioning videos with OpenCaptions

The `opencaptions` MCP tools caption videos on the user's own OpenCaptions server. The server
transcribes and draws; the video and the captioned file stay on the user's machine and server.

## The usual path

1. `caption_video` with the file's path (or a direct link), a `look`, and the `language` when it is
   known. It saves `<name>.captioned.mp4` next to the source and returns a `project_id`.
2. If it returns a ticket instead, the server is still working: call `check_progress` with it until
   it says where the file was saved.
3. Tell the user where the file is.

## Getting it right

- Pick the look from what the user asked for (`list_looks`); with no preference, leave it out.
- Names, brands and jargon are where transcription slips. When they matter, read `get_transcript`,
  fix the words with `fix_words`, then `save_video`. Two words heard for one ("fun guys" for "fungi")
  are joined with `count`, so the word keeps the time both were spoken.
- For a change of style ("higher up", "yellow", "bigger"), use `set_style` with only the settings
  that change (`describe_style` lists them), then `save_video`. `position_y` is 0 at the top and 1
  at the bottom.
- For Remotion, After Effects or another editor, `captions_only` saves the captions over green
  with no sound, to key out; `format: "mov"` keeps the edges sharp.
- `export_subtitles` writes SRT or VTT for platforms that take a subtitle file.

## When it fails

- "OPENCAPTIONS_KEY is not set" or "refused the key": the user creates an API key on their
  server's Account page and sets `OPENCAPTIONS_KEY` (and `OPENCAPTIONS_URL` if the server is not at
  http://localhost:5173), then restarts Claude Code.
- "Cannot reach OpenCaptions": the server is not running. It starts with `docker compose up -d` in
  the folder holding its `docker-compose.yml` (https://docs.opencaptions.app/getting-started/quick-start/).
