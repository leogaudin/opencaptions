---
title: "Contributing"
description: "How to set up OpenCaptions for development, the acceptance gate every change passes, and how to add a look, a speech model, a language or a page of these docs."
sidebar:
  order: 1
---

# Contributing

OpenCaptions is Docker-first and has one maintainer. Contributions are welcome, and the one rule that decides
whether a change is finished is that **`make ci` passes**.

The repository's [CONTRIBUTING.md](https://github.com/leogaudin/opencaptions/blob/main/CONTRIBUTING.md) is the
authoritative short guide, and [AGENTS.md](https://github.com/leogaudin/opencaptions/blob/main/AGENTS.md) lists the
invariants that are easy to break (it is written for AI agents but applies to everyone). This page is the tour.

## Set up

You need Docker with Compose v2.24 or newer. Everything else runs in containers.

```bash
git clone https://github.com/leogaudin/opencaptions.git
cd opencaptions
docker compose up -d --build   # http://localhost:5173 (or: make up)
docker compose watch           # live reload (or: make watch)
```

## The acceptance gate

```bash
make ci          # everything GitHub CI runs, except publishing, against committed HEAD
make ci-staged   # the same, including staged changes (use it before committing)
make ci-static   # a fast subset: no image builds, no end-to-end tests
```

It validates a clean snapshot in pinned containers, on throwaway volumes and off-default ports, so it is safe to
run while your own stack is up. A green run means the push is expected to be green. Run `make` for the
other targets (`lint`, `test-backend`, `typecheck`, and more).

## Where things are

| Path | What it owns |
|---|---|
| `apps/api/` | The FastAPI app and the Celery workers. |
| `apps/web/` | The Vite and React web app, and the public demo site. |
| `apps/engine/` | The Rust caption engine, for the browser (WebAssembly), the render server and iOS. |
| `apps/ios/` | The SwiftUI app, and the Swift package behind it. |
| `apps/docs/` | This documentation site (Starlight). The pages are the Markdown files in `docs/`. |
| `docs/` | The documentation pages. |

The [architecture](./architecture.md) page explains how they fit together.

## Common contributions

### A caption look

A look is an entry in
[`presets.json`](https://github.com/leogaudin/opencaptions/blob/main/apps/web/src/lib/presets.json): a name and a
complete [style](../reference/style.md). The web app, the API tests and the iPhone app all read that one file, and
a test checks that every entry is valid.

### A speech model

A model is added by describing it in `apps/api/app/services/asr_models.py`: its id, label, languages and where
its files are. An engine that runs it is needed only if no existing one does. Nothing above the provider changes.
Please measure it first; [how the current choices were made](./speech-model-benchmarks.md) shows the method.

### An interface language

The interface is in 13 languages. On the web, the English text in the code is the key (`t("Download")`), and each
`apps/web/src/locales/*.json` file holds the translations. On iOS, the string catalogs hold them. The tests fail on
a missing translation, so a new string needs all of them.

### These docs

The pages are Markdown in the `docs/` folder, and every page has an **Edit this page** link. A page starts with
its own `# Title`, and links another page with a relative `.md` link, so GitHub shows it too. To work on them
with a live preview:

```bash
make docs         # http://localhost:3000, reloads as you save
make docs-build   # the check: a broken link or anchor fails the build
```

## Before you open a pull request

Use [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`,
`ci:`, `test:`). Add or update tests for what you touch, and update the docs that your change makes untrue.

## The licence agreement

Contributions are published under AGPL-3.0, and also need the
[CLA](https://github.com/leogaudin/opencaptions/blob/main/CLA.md): you keep your copyright, and the maintainer may
also distribute your code under other terms, which is what lets the iPhone app ship on the App Store. A bot asks you
to accept it with one comment on your first pull request.
