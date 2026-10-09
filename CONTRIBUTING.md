# Contributing to OpenCaptions

Docker-first and single-maintainer. You need Docker and Docker Compose v2.24+;
everything else runs in containers.

```bash
git clone https://github.com/leogaudin/opencaptions.git
cd opencaptions
docker compose up -d --build   # → http://localhost:5173 (or: make up)
docker compose watch           # live reload (or: make watch)
```

`make logs` tails everything, `make down` stops it, `make rebuild` forces a
no-cache rebuild without touching your data, and `make clean` is the destructive
reset. Migrations run automatically on API boot, never add a manual step.

## A change is done when `make ci` passes

That is the whole acceptance criterion. It runs everything GitHub CI runs except
publishing, so a green run means your push is expected to be green.

```bash
make ci          # acceptance gate, against committed HEAD
make ci-staged   # same, including staged changes (use before committing)
make ci-static   # fast subset: no image builds, no e2e
```

It is safe to run while your own stack is up: it validates a clean snapshot of
committed source in pinned containers, on throwaway volumes and off-default
ports, so it never touches your stack's volumes.

`make lint`, `make test-backend`, `make typecheck` and `make format` are there
for fast iteration. Run `make` for the full target list.

There is deliberately no Make target that runs Playwright against your own
stack, because doing so registers accounts in your real database. To iterate on
a single spec, call Playwright directly and know that it writes to whatever
stack you point it at:

```bash
cd apps/web && npx playwright test -g "your spec" --ui
```

## Working on one app

Outside Docker, from `apps/api` (Python, `uv`) or `apps/web` (Node):

```bash
uv sync --extra dev && uv run uvicorn app.main:app --reload   # api
uv run pytest                                                         # api tests
uv run alembic revision --autogenerate -m "add foo"                   # a migration (applied on boot)
npm install && npm run dev                                            # web, http://localhost:5173
bash scripts/generate-api-types.sh                                    # after changing api schemas
```

The web preview is the engine's WebAssembly build: `make engine-wasm` once for `npm run dev`.
The iOS app has its own [README](apps/ios/README.md).

## Before you open a pull request

Use [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`,
`fix:`, `docs:`, `refactor:`, `chore:`, `ci:`, `test:`), scoped where it helps.

`AGENTS.md` lists the invariants that are easy to break and expensive to debug,
generated files you must not hand-edit, the one engine that draws both the
preview and the export, the content-addressed render cache. Read it before a first
non-trivial change. It is written for AI agents but applies to everyone.

Be decent to other people in issues and pull requests.

## Contributor License Agreement

Contributions are published under [AGPL-3.0-only](LICENSE), and also need the
[CLA](CLA.md): you keep your copyright, and the maintainer may additionally
distribute your code under other terms. That is what lets the iOS app ship on
the App Store, whose terms the AGPL does not allow, and keeps a hosted version
possible. On your first pull request a bot asks you to accept it with one
comment; that covers all your later contributions.
