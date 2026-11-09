# opencaptions

Animated word-by-word captions for your videos, from Claude Code, Claude Desktop, Cursor or any MCP
client, or from the command line. It runs on your own [OpenCaptions](https://github.com/leogaudin/opencaptions)
server: your video goes there and back, and nowhere else.

```bash
export OPENCAPTIONS_KEY=oc_...          # an API key from your server's Account page
npx opencaptions caption reel.mp4 --look Bold --language fr
```

As an MCP server:

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

In Claude Code: `/plugin install opencaptions --marketplace leogaudin/opencaptions`.

The tools caption a video, list the looks, change any style setting, read and fix the transcript, save
again in another format or as captions alone over green, and export SRT or VTT. Setup, every tool and
every option: [docs.opencaptions.app/guides/agents](https://docs.opencaptions.app/guides/agents/).

Needs Node.js 20.10 or later and a running OpenCaptions server
([quick start](https://docs.opencaptions.app/getting-started/quick-start/)). AGPL-3.0-only.
