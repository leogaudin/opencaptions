---
sidebar_position: 4
title: "GPU acceleration"
description: "Run OpenCaptions transcription on an NVIDIA GPU with the gpu Compose profile."
---

# GPU acceleration

An NVIDIA GPU makes transcription much faster. It is an addition, not a different install: the same
compose file, with the GPU worker switched on.

## Requirements

- An **NVIDIA GPU** with a driver that supports **CUDA 12** (`nvidia-smi` works on the host).
- The [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
  installed, so Docker can give a container the GPU.
- Room for a larger image: about 4 GB, against about 600 MB for the CPU one, because it bundles the CUDA
  runtime libraries.

## Turn it on

GPU mode is not a separate command. Two Compose variables choose which services run, so they are given on
the command line, not in the compose file:

```bash
COMPOSE_PROFILES=gpu OC_CPU_TRANSCRIBERS=0 docker compose up -d
```

- `COMPOSE_PROFILES=gpu` starts the GPU transcription worker.
- `OC_CPU_TRANSCRIBERS=0` stops the default CPU worker, so jobs only go to the faster GPU path.

Export them in your shell to make this the default for the machine. To go back to the CPU, run
`docker compose up -d` without them.

:::note Why a profile
A GPU reservation makes Compose fail on a host that has no NVIDIA runtime, even at a count of zero, so
the GPU worker is behind a profile instead of being in the default set.
:::

## If the GPU is not found

If the GPU cannot be used at run time, the worker falls back to the CPU and reports the reason in the
health endpoint, `http://localhost:5173/api/v1/health`. Under `transcription`, the `device` shows what
was resolved. (A server in `HOSTED_MODE` hides this.)

## What it speeds up

The speech models. The making of captioned videos is separate, on the `worker-rendering` and `engine`
services, and this profile does not change it.
