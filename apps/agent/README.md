# opencaptions

Animated word-by-word captions for your videos, from Claude Code, Claude Desktop, Cursor or any MCP
client, or from the command line. It runs on your computer, with nothing to sign up for: the speech
model and the caption engine of [OpenCaptions](https://github.com/leogaudin/opencaptions) run locally,
and your video stays where it is.

```bash
npx opencaptions caption reel.mp4 --look Bold --language fr
```

It needs [FFmpeg](https://ffmpeg.org/download.html), and downloads the speech model (about 700 MB)
the first time. It transcribes 25 European languages. To use an OpenCaptions server instead (other
languages, Whisper models, a GPU, the web editor), set `OPENCAPTIONS_KEY` to an API key from its
Account page, and `OPENCAPTIONS_URL` if it is not at `http://localhost:5173`.

As an MCP server:

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

In Claude Code: `/plugin install opencaptions --marketplace leogaudin/opencaptions`.

The tools caption a video, list the looks, change any style setting, read and fix the transcript, save
again in another format or as captions alone over green, and export SRT or VTT. Setup, every tool and
every option: [docs.opencaptions.app/guides/agents](https://docs.opencaptions.app/guides/agents/).

Needs Node.js 20.10 or later. AGPL-3.0-only.
