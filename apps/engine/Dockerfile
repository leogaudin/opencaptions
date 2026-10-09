# OpenCaptions engine, the render server.
# Builder: a release binary. Runtime: Debian with FFmpeg, nothing else.

FROM rust:1.99-slim-bookworm AS builder
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
# The dependencies come first, built against an empty crate: they are the slow part and change
# rarely, so a change to src/ does not compile them again.
RUN mkdir src && echo 'fn main() {}' > src/main.rs && touch src/lib.rs \
 && cargo build --release --locked --bin opencaptions-engine \
 && rm -rf src
COPY src src
COPY fonts fonts
# Copied files can be older than the stub's build; touched, cargo builds the crate itself.
RUN touch src/main.rs src/lib.rs && cargo build --release --locked --bin opencaptions-engine

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
