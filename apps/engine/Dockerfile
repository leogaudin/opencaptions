# OpenCaptions engine, the render server.
# Builder: a static release binary. Runtime: Debian with FFmpeg, nothing else.

FROM rust:1.99-slim-bookworm AS builder
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY src src
COPY fonts fonts
RUN cargo build --release --locked --bin opencaptions-engine

FROM debian:bookworm-slim AS runtime
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 engine
COPY --from=builder /src/target/release/opencaptions-engine /usr/local/bin/
COPY fonts /app/fonts
USER engine
EXPOSE 3001
HEALTHCHECK --interval=10s --timeout=5s --retries=10 CMD ["opencaptions-engine", "health"]
CMD ["opencaptions-engine"]
