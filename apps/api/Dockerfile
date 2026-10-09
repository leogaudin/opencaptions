# OpenCaptions API, multi-stage Dockerfile
# Builder + runtime separation; the runtime carries ffmpeg and the locked Python
# dependencies, not the test and lint tools. GPU target adds CUDA runtime wheels (~4 GB).

# ===== Builder (CPU) =====
FROM python:3.14-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# uv, copied from its own image (the one `make ci` uses): nothing is piped from the
# network into a shell, and the version is one image tag, not whatever is newest.
COPY --from=ghcr.io/astral-sh/uv:python3.14-bookworm-slim /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/

WORKDIR /app

# Copy the lockfile first for a cacheable dep install
COPY pyproject.toml ./
COPY uv.lock ./

# Sync dependencies from the committed lockfile (no dev tools, and not the gpu
# extra). --locked fails the build loudly if uv.lock is missing or out of
# sync with pyproject.toml, so a build can never silently resolve fresh,
# non-reproducible versions. Regenerate the lock with `uv lock` after editing
# dependencies in pyproject.toml. The cache mount keeps downloaded wheels between
# builds, so a changed dependency does not fetch them all again.
RUN --mount=type=cache,target=/root/.cache/uv uv sync --locked

# Copy application code
COPY app ./app
COPY alembic.ini ./

# ===== GPU Builder =====
# Adds the CUDA runtime wheels on top of the base builder layer: the `gpu` extra, from the
# same lockfile as everything else, not an unpinned install beside it.
FROM builder AS builder-gpu

RUN --mount=type=cache,target=/root/.cache/uv uv sync --locked --extra gpu

# ===== Runtime (GPU): the `gpu` profile of docker-compose.yml =====
# Inherits from the CPU runtime base but copies the venv from builder-gpu,
# which includes nvidia-cublas-cu12 and nvidia-cudnn-cu12 wheels.
# LD_LIBRARY_PATH points the dynamic linker at the nvidia wheel shared objects
# installed under site-packages/nvidia/{cublas,cudnn}/lib/.
FROM python:3.14-slim AS runtime-gpu

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/app/.venv/bin:$PATH" \
    LD_LIBRARY_PATH="/app/.venv/lib/python3.14/site-packages/nvidia/cublas/lib:/app/.venv/lib/python3.14/site-packages/nvidia/cudnn/lib"

RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
        libgomp1 \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder-gpu /app /app

# Models cache
RUN mkdir -p /models && chmod 777 /models
ENV HF_HOME=/models \
    HUGGINGFACE_HUB_CACHE=/models

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

# ===== Runtime (CPU, default) =====
# This is the LAST stage so `docker build` without --target produces the CPU image.
FROM python:3.14-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/app/.venv/bin:$PATH"

RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
        libgomp1 \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /app /app

# Models cache
RUN mkdir -p /models && chmod 777 /models
ENV HF_HOME=/models \
    HUGGINGFACE_HUB_CACHE=/models

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
