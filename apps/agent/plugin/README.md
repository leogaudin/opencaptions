# OpenCaptions for Claude

Ask Claude to caption a video, and it transcribes the speech, styles it with one of the looks, and saves the
captioned video next to the original. It can also read the captions back, fix a misheard word, and export SRT or
VTT subtitles. The captions are animated word by word, drawn by the same open-source engine as the OpenCaptions
app and web editor.

## Install

In Claude Code (2.1.275 or later):

```text
/plugin install opencaptions --marketplace leogaudin/opencaptions
```

## What it runs

The plugin starts one MCP server: the [`opencaptions`](https://www.npmjs.com/package/opencaptions) npm package,
pinned to an exact version in `.mcp.json` and started with `npx`. It needs Node.js 20.10 or later and
[FFmpeg](https://ffmpeg.org/download.html) installed. A skill, `caption-videos`, tells Claude when and how to use
the tools.

## What it reads and writes

It reads the video file you name. Next to it, it writes `<name>.captioned.mp4`, a project file
`<name>.opencaptions.json` (the captions and style, for fixing words and saving again), and subtitle files when you
ask. What it downloads is kept in `~/.cache/opencaptions` (`OPENCAPTIONS_CACHE` moves it).

## What it fetches, and what it sends

By default it works on your computer, and the video, its sound and the captions never leave it. It fetches two
things, over HTTPS, and nothing else:

- **The speech model**, Parakeet Ultra (about 700 MB, once), from Hugging Face, at the first caption.
- **A font**, only when a look uses a font that is not bundled: the font's file from Google Fonts, once. The
  request names the font family and nothing else.

There is no account, no telemetry, and nothing is sent to the plugin's author.

If you set `OPENCAPTIONS_URL` and `OPENCAPTIONS_KEY` in the environment Claude starts from, the work happens on
that [OpenCaptions server](https://docs.opencaptions.app/self-hosting/installation/) instead, which you run
yourself: the video and the requests go to it, and nothing is done on your computer. Without them, nothing is sent
to any server.

If FFmpeg is installed but not found, `OPENCAPTIONS_FFMPEG` names the folder holding `ffmpeg` and `ffprobe`.

## More

- Setup and every tool: <https://docs.opencaptions.app/guides/agents/>
- Source and issues: <https://github.com/leogaudin/opencaptions>
- License: AGPL-3.0-only.
