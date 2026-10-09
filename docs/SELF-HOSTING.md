# Self-hosting

Everything beyond the quick start: configuration, the API, security, GPU and backups.

## Configuration

There is no env file. Every application setting has its default in
[`apps/api/app/core/config.py`](apps/api/app/core/config.py), written for this
topology, so the stack boots with no configuration at all. The compose file names
only what a container cannot infer: the credentials Postgres and the object store
share with the app, the service topology, and per-service overrides.

To change a setting, add it to the `environment:` block of the services that read
it, committed, visible in a diff, and impossible for an untracked file to shadow.

## API

Everything the app does is an HTTP API, documented interactively at
`/api/v1/docs` on your instance. Create a key on the **Account** page, then:

```bash
API=http://localhost:5173/api/v1
AUTH="Authorization: Bearer oc_…"

# Upload a video (or pass -F video_url=https://… instead of a file)
PROJECT=$(curl -s -H "$AUTH" -F title=episode -F video=@episode.mp4 "$API/projects" | jq -r .id)

# Transcribe, then poll the job until it completes
JOB=$(curl -s -H "$AUTH" -X POST "$API/projects/$PROJECT/transcribe" \
  -H 'Content-Type: application/json' -d '{"language":"auto"}' | jq -r .id)
curl -s -H "$AUTH" "$API/jobs/$JOB" | jq .status

# Render: returns ready=true with a URL, or a job to poll first
curl -s -H "$AUTH" -X POST "$API/projects/$PROJECT/download" \
  -H 'Content-Type: application/json' -d '{"format":"mp4"}'
curl -s -H "$AUTH" -o captioned.mp4 "$API/projects/$PROJECT/download/mp4"
```

A key reaches every endpoint except account management (`/auth`, `/api-keys`),
which needs a signed-in browser, so a leaked key cannot mint more keys or take
over the account. Only a hash of each key is stored; revoke one from the same
page.

## Security

> ⚠️ **The web UI listens on every interface, and signup is open.** Anyone who can reach port 5173 on this machine can create an account and spend its CPU/GPU on transcription and rendering. On a shared network or a public host, close registration by adding `REGISTRATION_ENABLED: "false"` to the `api` service's `environment:` block, firewall the port, or bind it to `127.0.0.1` on the `web` service's `ports:` line.

The shipped defaults are development credentials, not secrets: Postgres is `opencaptions` / `opencaptions` the bundled Garage object store uses the `S3_ACCESS_KEY` / `S3_SECRET_KEY` written in the compose file, and the render server accepts requests that carry `ENGINE_TOKEN`. Change them before running anywhere that matters, in every service that names them, which `scripts/check-compose.sh` verifies.

The stack publishes exactly one host port, the web UI, on `0.0.0.0:5173`, so
other devices on your network can use it. Everything else (database, cache, object
store, API, engine) is reachable only over the compose network, because nginx
proxies `/api`, `/ws` and the OpenAPI docs through that single origin.

For anything beyond a trusted network, put a reverse proxy in front to terminate
TLS, and bind the port to `127.0.0.1` so only the proxy can reach it.

See [SECURITY.md](../SECURITY.md) for the threat model and how to report a vulnerability.

## GPU Acceleration

GPU mode is not a separate command. Both switches are Compose variables, they
choose which services run, so they are set on the command line rather than in the
compose file:

```bash
COMPOSE_PROFILES=gpu OC_CPU_TRANSCRIBERS=0 docker compose up -d
```

Export them in your shell to make it the default for that machine.

`COMPOSE_PROFILES=gpu` brings up the GPU transcription worker.
`OC_CPU_TRANSCRIBERS=0` suppresses the default CPU worker so jobs only land on
the faster GPU path.

**Requirements:**
- NVIDIA GPU with a CUDA 12-capable driver (`nvidia-smi` should work on the host)
- [nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) installed
- The GPU image is substantially larger (~4 GB vs ~600 MB) because it bundles CUDA runtime wheels

The GPU profile builds/pulls a separate image with CUDA libraries and reserves your NVIDIA device for the transcription worker. If GPU detection fails at runtime, the worker falls back to CPU and reports the reason in the health endpoint.

To switch back to CPU, run `docker compose up -d` without them.

## Backups

Backup: `make backup` snapshots Postgres + Garage data to `./backups/`.
Restore: `make restore TS=YYYYMMDD-HHMMSS`.

