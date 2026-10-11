---
sidebar_position: 5
title: "Security"
description: "What to change before exposing OpenCaptions beyond your own machine: closing sign-up, the default credentials, the published port, HTTPS behind a reverse proxy, and what the server fetches."
---

# Security

OpenCaptions is built to run on a machine you control, for you and the people you trust. The stock setup
is **friendly, not hardened**, so read this page before you put it anywhere other people can reach.
The project's [security policy](https://github.com/leogaudin/opencaptions/blob/main/SECURITY.md) says how to
report a vulnerability.

:::warning The web app listens on every interface, and sign-up is open
Anyone who can reach port 5173 on the machine can create an account and spend its processor on
transcription and video making. On a shared network or a public host, do at least one of these:

- close registration with `REGISTRATION_ENABLED: "false"` (see [Configuration](./configuration.md#changing-a-setting)),
- firewall the port,
- or bind it to `127.0.0.1` on the `web` service's `ports:` line.
:::

## What the stack exposes

The stack publishes **exactly one port**: the web app, on `0.0.0.0:5173`, so other devices on your network,
such as a phone, can use it. Everything else (the database, the queue, the object store, the API and the
render engine) is reachable only over the Compose network, because nginx passes `/api`, `/ws` and the API
documentation through that one address. To reach a service yourself, use `docker compose exec`, and reach
the API through the web address (`http://localhost:5173/api/v1/…`).

## The default credentials

The defaults are **development credentials, not secrets**. They are public in this repository:

- Postgres is `opencaptions` / `opencaptions`.
- The bundled object store (Garage) uses the `S3_ACCESS_KEY` and `S3_SECRET_KEY` in the compose file.
- The render server accepts requests that carry `ENGINE_TOKEN`.

They are safe only because none of those services is published. Change them before running anywhere
that matters, **in every place the compose file names them**: each one is written once per service that needs
it, and a check in the repository fails if the copies disagree with each other or with the application's
defaults. Search the file for the value.

:::caution Changing a password after the first start
A database or storage password changed after the first start does not change the volume that already holds the
old one. Change it before first use, or change it inside the database too.
:::

## Behind HTTPS

For anything beyond a trusted network, put a reverse proxy (Caddy, nginx, Traefik) in front to end TLS, and
bind the port to `127.0.0.1` so only the proxy can reach it. Behind TLS, also set, in the
[configuration](./configuration.md#changing-a-setting):

```yaml
SESSION_COOKIE_SECURE: "true"
PUBLIC_BASE_URL: "https://captions.example.com"
CORS_ORIGINS: "https://captions.example.com"   # only if the page is served from another origin
```

`PUBLIC_BASE_URL` is the address people use: password-reset links are built from it. The defaults of all three
are for `http://localhost:5173`.

The proxy must pass WebSocket connections on `/ws/` (they carry job progress) and allow large uploads: set
its body limit at least as high as `MAX_UPLOAD_SIZE_MB` (2 GB by default), and a read timeout of several
minutes on `/api/`.

A minimal Caddyfile:

```text
captions.example.com {
    reverse_proxy 127.0.0.1:5173
}
```

## Fetching a video from a link

The upload page can take a video link, and the server downloads it. That makes the server fetch an address
chosen by a user, so the fetch is guarded: only `http` and `https`, the name is resolved first, and every
address it resolves to must be public. A private or link-local address is refused, and the check is repeated
on every redirect. This is what stops a user from making your server read from your internal network.

To pull from a machine on your own network, such as a NAS, list its host in `SSRF_ALLOWED_HOSTS`:

```yaml
SSRF_ALLOWED_HOSTS: "192.168.1.50,my-nas.local"
```

The same guard covers `TRANSCRIPTION_REMOTE_URL`.

## Accounts and keys

- **Sign-in** is an email and a password, with an `httpOnly` session cookie and a CSRF token. Attempts are
  throttled per account and per source address.
- **Isolation.** Every project and job is checked against its owner on every request.
- **API keys** reach everything except account management, which needs a signed-in browser, so a leaked key
  cannot mint more keys or take over the account. Only a hash of each key is stored.

See [Accounts](./accounts.md).

## Running it for other people

`HOSTED_MODE: "true"` is the switch between running it for yourself and running it for others. The API then
withholds details of the host (health, models, device) and refuses a per-job choice of provider or model.
Note that the AGPL asks anyone who runs a modified version for others to publish the changes.

## What the server connects to by itself

Nothing is sent to the project, and there is no telemetry. The server makes these requests on its own:

| When | To | What |
|---|---|---|
| A speech model is first used | Hugging Face | The model's files |
| A font that is not bundled (Inter, Poppins, Montserrat are) is first used | Google Fonts | The font file, then kept in your storage |
| A provider that sends audio away is chosen | OpenAI, or the OpenCaptions server you named | The audio of that video |
| A video link is given | The address given | The video |

On a server with no internet, the first two simply fail: a font that was never fetched falls back to Inter,
and a model has to be copied into the `models` folder from a machine that has downloaded it.
