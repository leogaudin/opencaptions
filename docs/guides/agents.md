---
title: "From Claude and other agents"
description: "Caption videos from Claude Code, Claude Desktop, Cursor or any MCP client, or from the command line: the opencaptions package runs on your computer, or on your own OpenCaptions server."
sidebar:
  order: 6
---

# From Claude and other agents

Ask an agent "caption `reel.mp4` with the Bold look, in French", and it does: the `opencaptions` package
gives Claude Code, Claude Desktop, Cursor and any other [MCP](https://modelcontextprotocol.io) client the
tools to transcribe a video, style it, fix a word and save it. The same package is a command line, for
scripts and video pipelines such as one built on Remotion.

It runs on your computer, with no server and no account: the speech model and the caption engine run
locally, and the video stays where it is. The captions are drawn by the same engine as the web editor's,
so they look the same.

## What you need

- **Node.js 20.10** or later, which runs the package (`npx` fetches it).
- **[FFmpeg](https://ffmpeg.org/download.html)**, which reads and writes the video: `brew install ffmpeg` on a
  Mac, `sudo apt install ffmpeg` on Debian or Ubuntu, `winget install ffmpeg` on Windows.

The first caption downloads the speech model, Parakeet Ultra, about 700 MB, into `~/.cache/opencaptions`
(`OPENCAPTIONS_CACHE` moves it). On a recent laptop it transcribes about ten times faster than real time.

### On your OpenCaptions server instead

On the computer the speech model covers 25 European languages, on the processor. Your
[OpenCaptions server](../getting-started/quick-start.md) adds every language, the Whisper models, a GPU, and
the web editor to finish a video by hand. Create an API key on its **Account** page
([API keys](../self-hosting/accounts.md#api-keys)) and set it:

| Variable | What it is |
|---|---|
| `OPENCAPTIONS_KEY` | The API key. With it, the package uses the server. |
| `OPENCAPTIONS_URL` | The server's address, as your browser opens it. Leave it out for `http://localhost:5173`. |

## Set it up

### Claude Code

Install the plugin, which adds the tools and teaches Claude when to use them:

```text
/plugin install opencaptions --marketplace leogaudin/opencaptions
```

On a Claude Code older than 2.1.275, add the marketplace first: `/plugin marketplace add
leogaudin/opencaptions`, then `/plugin install opencaptions@opencaptions`.

For a server, set `OPENCAPTIONS_KEY` (and `OPENCAPTIONS_URL`) in the shell you start Claude Code from, or
in its settings' `env`. Or add the tools alone, without the plugin:

```bash
claude mcp add opencaptions -- npx -y opencaptions mcp
```

### Claude Desktop, Cursor and other clients

Add the server to the client's MCP configuration (`claude_desktop_config.json` for Claude Desktop,
`.cursor/mcp.json` for Cursor):

```json
{
  "mcpServers": {
    "opencaptions": {
      "command": "npx",
      "args": ["-y", "opencaptions", "mcp"]
    }
  }
}
```

For a server, add `"env": { "OPENCAPTIONS_KEY": "oc_...", "OPENCAPTIONS_URL": "http://localhost:5173" }`.

## What an agent can do

| Tool | What it does |
|---|---|
| `caption_video` | Transcribes a video (a file, or with a server a direct link), gives it a look and saves the captioned video next to it. |
| `check_progress` | With a server, carries on with a long video: past about 45 seconds a tool returns a ticket rather than outlast the client's patience. |
| `list_looks` | The built-in looks. |
| `describe_style` | Every style setting, with its range and meaning. |
| `set_style` | A look, or any settings over it: "higher up", "yellow", "bigger". |
| `get_transcript` | The captions as they show, and every word with its index. |
| `fix_words` | Corrects, removes or joins words, keeping their timing: two words heard for one become one word spoken across both. |
| `save_video` | Saves again after a change, or in another format, size or frame rate. |
| `export_subtitles` | SRT, VTT, or the transcript as JSON. |

A video is saved as `<name>.captioned.mp4` beside the source, unless the agent is told where.
`captions_only` saves the captions alone over green, with no sound, to key out in Remotion or a video
editor: see [Exporting](./exporting.md).

## The command line

```bash
npx opencaptions caption reel.mp4 --look Bold --language fr
npx opencaptions caption talk.mp4 --style '{"position_y": 0.7, "font_size": 90}' --subtitles srt
npx opencaptions caption intro.mp4 --captions-only --format mov -o intro-captions.mov
npx opencaptions looks     # the looks
npx opencaptions style     # every style setting
```

It prints the path of what it saved, so a script can pick it up. `--transcript words.json` uses captions
you already have (the API's transcript JSON) instead of transcribing. `npx opencaptions help` lists every
option.

## Good to know

- **The project:** on the computer, `reel.opencaptions.json` beside the video holds its captions and style,
  so `fix_words`, `set_style` and `save_video` carry on from it. On a server, each video is a project you can
  open in the web editor.
- **Long videos:** on a server, transcription runs at the server's speed. A client that gives a tool little
  time gets a ticket back and `check_progress` finishes the job, so nothing is lost.
- **What it fetches:** on the computer, the speech model from Hugging Face the first time, and a font from
  Google Fonts when a style uses one that is not built in. The video and its sound are never sent anywhere.
- **Names and jargon** are where transcription slips. Ask the agent to check the transcript before saving
  when they matter.
- **The source** is the [`apps/agent`](https://github.com/leogaudin/opencaptions/tree/main/apps/agent) folder
  of the repository. With a server it uses only the [HTTP API](../reference/api.md), so anything it does, a
  script can do too.
