# Testing the GPU image end to end on AWS

A maintainer's runbook: one short-lived GPU instance, the stack from this repository, the iOS
app pairing with it over a QR code and transcribing on it. It costs well under a dollar if the
instance is terminated afterwards. **Untested as written**: the first run is its test, so fix
this page where reality differs.

## What it proves

The `-gpu` image runs on a real NVIDIA GPU with CUDA 12, the worker falls back to nothing, the
iOS app lists the server's models, and asking for a model the server does not have makes the
server fetch its weights from Hugging Face on first use (faster-whisper's `download_root` is
`/models`; the job reports "fetching the model" until they are there). Nothing else about the
app is checked.

## Pick the machine

| | |
|-|-|
| Type | `g4dn.xlarge` (NVIDIA T4 16 GB, 4 vCPU, 16 GB RAM). About $0.53 per hour on demand in us-east-1; spot is a third of that and fine for this. |
| Image | AWS "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)": the driver, Docker and the NVIDIA container toolkit are already there. |
| Disk | 80 GB gp3. The GPU image is about 4 GB, `large-v3` about 3 GB, Docker needs room to unpack. |
| Network | No inbound rule at all. The instance is reached with SSM Session Manager (or SSH from your IP), and the phone through an HTTPS tunnel (below). |
| Quota | A new account usually has **0 vCPUs** for "Running On-Demand G and VT instances". Ask for 4 first (Service Quotas, EC2), it can take a few hours. |

The iOS app only allows plain HTTP to the local network (`NSAllowsLocalNetworking`), so a public
IP over HTTP will not connect. A Cloudflare quick tunnel gives an HTTPS address with no account,
no domain and no open port.

## Run it

Launch (console or CLI), with the instance's shutdown behaviour set to **terminate**, then:

```bash
# a dead man's switch, so a forgotten instance ends itself in three hours
sudo shutdown -h +180

nvidia-smi                       # the T4 shows up, or stop here
git clone https://github.com/leogaudin/opencaptions.git && cd opencaptions

# the published image (once publishing works), else add --build to build it here (about 15 minutes)
COMPOSE_PROFILES=gpu OC_CPU_TRANSCRIBERS=0 docker compose up -d
docker compose ps                # everything healthy
docker compose logs worker-transcription-gpu | head   # "device=cuda compute_type=float16"

# an HTTPS address for the web UI
curl -L -o cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x cloudflared && ./cloudflared tunnel --url http://localhost:5173
# prints https://<random>.trycloudflare.com
```

Then, on the phone:

1. Open the printed address in a browser on the computer, create an account.
2. In the web UI's API keys (account menu), create a key for the phone: it shows a QR code. Point the phone's Camera at it and tap the banner, which opens the app already paired.
3. In the app, Transcribe: choose the remote server and a model the server has not downloaded
   yet (`large-v3`), start. The first job is slow while the weights download; watch
   `docker compose logs -f worker-transcription-gpu` and the app's progress text.
4. Run it again: it should take seconds for a short clip.

Tear down: terminate the instance (stopping leaves the disk billing). Check the console shows
no instance and no volume left.

## Cost

About an hour of `g4dn.xlarge` on demand is $0.53, the disk a cent or two, the data in a few
cents. The things that cost real money are a forgotten instance (hence the shutdown line and
terminate-on-shutdown) and an Elastic IP or volume left behind (this uses neither).
