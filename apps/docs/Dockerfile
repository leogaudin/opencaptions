# The documentation site as static files. The pages are not in this folder: they are the Markdown
# files of docs/ at the repository root, passed as a named build context:
#   docker build --build-context docs=docs --target docs-site -o apps/docs/dist apps/docs
FROM node:24-bookworm-slim AS deps
WORKDIR /repo/apps/docs
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

FROM deps AS build
# Nothing leaves the build: no telemetry.
ENV ASTRO_TELEMETRY_DISABLED=1
COPY . .
COPY --from=docs . src/content/docs
RUN npm run build

# Only the static files (what the CI job uploads and the Worker serves).
FROM scratch AS docs-site
COPY --from=build /repo/apps/docs/dist /
