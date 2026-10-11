# The documentation site, built to static files.
#
#   docker build --build-context docs=docs --target docs-site -o dist-docs apps/docs
#
# The pages are the Markdown files of `docs/` at the repository root, outside this build's context,
# so they come in as a named context (`--build-context docs=docs`), as the web image gets the engine.
FROM node:24-bookworm-slim AS deps
WORKDIR /repo/apps/docs
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

FROM deps AS build
COPY . .
COPY --from=docs . /repo/docs
ENV DOCS_PATH=/repo/docs
RUN npm run build

# Only the files to serve, so `-o` exports them and nothing else.
FROM scratch AS docs-site
COPY --from=build /repo/apps/docs/build /
