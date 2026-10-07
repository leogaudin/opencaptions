# OpenCaptions API, multi-stage Dockerfile
# Builder + runtime separation; final image ~600 MB with ffmpeg + Python deps.
# GPU target adds CUDA runtime wheels (~4 GB).

# ===== Builder (CPU) =====
FROM python:3.14-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

# Install uv
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    mv /root/.local/bin/uv /usr/local/bin/uv

WORKDIR /app

# Copy lockfile + readme first for cacheable dep install
# (uv sync validates pyproject metadata, which references README.md)
COPY pyproject.toml ./
COPY uv.lock ./
COPY README.md ./

# Sync dependencies from the committed lockfile (dev extra for tests; NOT the
# gpu extra). --locked fails the build loudly if uv.lock is missing or out of
# sync with pyproject.toml, so a build can never silently resolve fresh,
# non-reproducible versions. Regenerate the lock with `uv lock` after editing
# dependencies in pyproject.toml.
RUN uv sync --extra dev --locked

# Copy application code
COPY app ./app
COPY alembic.ini ./
COPY tests ./tests

# ===== GPU Builder =====
# Installs CUDA runtime wheels on top of the base builder layer.
FROM builder AS builder-gpu

RUN uv pip install --python /app/.venv/bin/python \
    "nvidia-cublas-cu12>=12.4" \
    "nvidia-cudnn-cu12>=9.1"

# ===== Runtime (GPU), named target for docker-compose.gpu.yml =====
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
