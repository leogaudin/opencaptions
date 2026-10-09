# OpenCaptions web, multi-stage Dockerfile producing a static-served SPA.
# Preview assets: the caption engine compiled to WebAssembly, plus its fonts.
# Builder: vite build. Runtime: nginx serving /usr/share/nginx/html.
#
# Needs the engine as a named build context:
#   docker build --build-context engine=apps/engine apps/web

# Both build stages run on the machine that builds, whatever the image is for: what they make
# (WebAssembly, a script bundle) is the same for every architecture, so a multi-arch build
# does not run them again under emulation.
FROM --platform=$BUILDPLATFORM rust:1.99-slim-bookworm AS wasm
RUN rustup target add wasm32-unknown-unknown
WORKDIR /src
COPY --from=engine Cargo.toml Cargo.lock ./
# Dependencies first, against an empty crate (they change rarely; the engine's code does).
RUN mkdir src && touch src/lib.rs \
 && cargo build --release --locked --lib --target wasm32-unknown-unknown \
 && rm -rf src
COPY --from=engine src src
COPY --from=engine fonts fonts
RUN touch src/lib.rs
# Same files in the same order as the server's load_fonts, so glyph fallback
# picks the same face in the preview as in the export.
RUN cargo build --release --locked --lib --target wasm32-unknown-unknown \
 && mkdir /out \
 && cp target/wasm32-unknown-unknown/release/opencaptions_engine.wasm /out/ \
 && cp -r fonts /out/fonts \
 && (cd fonts && printf '[%s]' "$(LC_ALL=C ls | grep -iE '\.(ttf|otf)$' | sed 's/.*/"&"/' | paste -sd,)") > /out/fonts.json

# `make engine-wasm` exports this stage into public/engine for `npm run dev`.
FROM scratch AS preview-assets
COPY --from=wasm /out /

FROM --platform=$BUILDPLATFORM node:26-bookworm-slim AS builder
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY . .
COPY --from=preview-assets / public/engine/
RUN npm run build

# The public demo (opencaptions.app): static files for Cloudflare Pages, not part of the image.
# `docker build --target demo-site -o apps/web/dist-demo ...` (make demo) exports them.
FROM builder AS demo-build
COPY --from=preview-assets / demo-public/engine/
RUN npm run build:demo

FROM scratch AS demo-site
COPY --from=demo-build /app/dist-demo /

FROM nginx:1.31-alpine AS runtime
# The image lags its own distro: it ships packages Alpine has already patched
# (libexpat 2.8.4 against CVE-2026-93990 at the time of writing). Upgrading here
# means a rebuild picks fixes up without waiting for a new nginx tag.
RUN apk upgrade --no-cache
COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 5173
CMD ["nginx", "-g", "daemon off;"]
