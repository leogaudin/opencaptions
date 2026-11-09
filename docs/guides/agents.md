---
title: "From Claude and other agents"
description: "Caption videos from Claude Code, Claude Desktop, Cursor or any MCP client, or from the command line: the opencaptions package talks to your own OpenCaptions server."
sidebar:
  order: 6
---

# From Claude and other agents

Ask an agent "caption `reel.mp4` with the Bold look, in French", and it does: the `opencaptions` package
gives Claude Code, Claude Desktop, Cursor and any other [MCP](https://modelcontextprotocol.io) client the
tools to transcribe a video, style it, fix a word and save it. The same package is a command line, for
scripts and video pipelines such as one built on Remotion.

It runs on your own server: the video goes from your computer to your OpenCaptions server and back, and
nowhere else. The captions are drawn by the same engine as the web editor's, so they look the same.

## What you need

- **An OpenCaptions server**, running: see the [quick start](../getting-started/quick-start.md). One compose
  file, no GPU needed.
- **An API key:** on the server, open **Account** and create one under
  [API keys](../self-hosting/accounts.md#api-keys).
- **Node.js 20.10** or later, which runs the package (`npx` fetches it).

The package reads two settings:

| Variable | What it is |
|---|---|
| `OPENCAPTIONS_KEY` | The API key. |
| `OPENCAPTIONS_URL` | The server's address, as your browser opens it. Leave it out for `http://localhost:5173`. |

## Set it up

### Claude Code

Install the plugin, which adds the tools and teaches Claude when to use them:

```text
/plugin install opencaptions --marketplace leogaudin/opencaptions
```

On a Claude Code older than 2.1.275, add the marketplace first: `/plugin marketplace add
leogaudin/opencaptions`, then `/plugin install opencaptions@opencaptions`.

Set `OPENCAPTIONS_KEY` (and `OPENCAPTIONS_URL`) in the shell you start Claude Code from, or in its
settings' `env`. Or add the server alone, without the plugin:

```bash
claude mcp add opencaptions -e OPENCAPTIONS_KEY=oc_... -- npx -y opencaptions mcp
```

### Claude Desktop, Cursor and other clients

Add the server to the client's MCP configuration (`claude_desktop_config.json` for Claude Desktop,
`.cursor/mcp.json` for Cursor):

```json
{
  "mcpServers": {
    "opencaptions": {
      "command": "npx",
      "args": ["-y", "opencaptions", "mcp"],
      "env": { "OPENCAPTIONS_KEY": "oc_...", "OPENCAPTIONS_URL": "http://localhost:5173" }
    }
  }
}
```

## What an agent can do

| Tool | What it does |
|---|---|
| `caption_video` | Transcribes a video (a file, or a direct link), gives it a look and saves the captioned video next to it. |
| `check_progress` | Carries on with a long video: past about 45 seconds a tool returns a ticket rather than outlast the client's patience. |
| `list_looks` | The built-in looks. |
| `describe_style` | Every style setting, with its range and meaning. |
| `set_style` | A look, or any settings over it: "higher up", "yellow", "bigger". |
| `get_transcript` | The captions as they show, and every word with its index. |
| `fix_words` | Corrects or removes words, keeping their timing. |
| `save_video` | Saves again after a change, or in another format, size or frame rate. |
| `export_subtitles` | SRT, VTT, or the transcript as JSON. |

A video is saved as `<name>.captioned.mp4` beside the source, unless the agent is told where.
`captions_only` saves the captions alone over green, with no sound, to key out in Remotion or a video
editor: see [Exporting](./exporting.md).

## The command line

```bash
export OPENCAPTIONS_KEY=oc_...
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

- **Long videos:** transcription runs at the server's speed. A client that gives a tool little time gets a
  ticket back and `check_progress` finishes the job, so nothing is lost.
- **Names and jargon** are where transcription slips. Ask the agent to check the transcript before saving
  when they matter.
- **Each captioned video is a project** on your server, which you can open in the web editor to finish by hand.
- **The source** is the [`apps/agent`](https://github.com/leogaudin/opencaptions/tree/main/apps/agent) folder
  of the repository. It uses only the [HTTP API](../reference/api.md), so anything it does, a script can do too.
