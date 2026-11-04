---
title: "A self-hosted alternative to caption subscriptions"
description: "OpenCaptions compared with hosted caption tools: what you get by running it yourself, what you pay, and where the hosted tools are ahead."
sidebar:
  order: 2
---

# A self-hosted alternative to caption subscriptions

Hosted caption tools such as Submagic and Captions do this job well, and they ask for a subscription and your footage
on their servers. OpenCaptions is the other kind of answer: open source, on your own server or your own phone.

| | OpenCaptions | Hosted caption tools |
|---|---|---|
| Where your video goes | Stays on your server or phone | Uploaded to their service |
| Cost | Free to self-host; on iPhone, free with an optional one-time Pro | Usually a subscription |
| Account | None on iPhone; local to your instance when self-hosted | Required |
| The code | Open source (AGPL-3.0): read it, change it, run it | Closed |
| Templates | Nineteen looks and a full style panel | Usually more |
| Emoji, B-roll, virality scores | No | Often yes |
| Android | No | Often yes |
| Setting it up | One compose file, on hardware you look after | Nothing to run |

**Choose a hosted tool** if you want the most templates and automation, and do not mind where the video goes.

**Choose OpenCaptions** if your footage should stay with you, you would rather not rent a tool you use now and then,
or you want to change how it works.

## Run it

You need Docker Compose and one file:

```bash
curl -O https://raw.githubusercontent.com/leogaudin/opencaptions/main/docker-compose.yml
docker compose up -d
```

Then open <http://localhost:5173>. [Installation](../self-hosting/installation.md) has the details, and
[security](../self-hosting/security.md) what to read before it is reachable by others.

## Questions

**Do I need a GPU?**
No. It runs on the CPU, and [a GPU](../self-hosting/gpu.md) is optional.

**Can I keep using a hosted speech model?**
Yes, if you want to: the OpenAI API with your own key is [one of the choices](../self-hosting/speech-models.md#the-openai-provider), and
the default runs on your machine.
