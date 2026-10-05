# AGENTS.md

> For AI agents working on this repo. Not user-facing documentation.

## Definition of Done

**A change is done when `make ci` passes.** That is the acceptance criterion —
it runs every validation GitHub CI runs except publishing, so a green run means
the push is expected to be green. Before that:

- [ ] Added or updated tests covering what you touched
- [ ] `make ci` passes (or `make ci-staged` before committing)
- [ ] Checked whether your change invalidates anything in `docs/DESIGN.md`, the app READMEs, or this file — and updated it

`make ci` is safe to run while your own stack is up: it validates a clean
snapshot of committed source in pinned containers, and its end-to-end stack runs
under its own project name on an off-default port, so none of your volumes are
reachable from it.

| Command | Use |
|---------|-----|
| `make ci` | Acceptance gate. Full local CI against committed `HEAD`. |
| `make ci-staged` | Same, but validates `HEAD` + staged changes (pre-commit). |
| `make ci-static` | Fast subset: skips image builds and e2e. |

## Verification Commands

`make ci` runs all of these. Reach for an individual one only to iterate quickly.

```bash
make lint             # ruff + mypy (api), biome (web)
make test-backend     # pytest
make typecheck        # tsc -b project references (web)
make test-engine      # the engine's Rust tests (in a pinned toolchain container)
make typegen-check    # regenerate API types and fail if the committed file is stale
make check-versions   # the manifests agree on the version
make check-compose    # docker-compose.yml fallbacks agree with each other and config.py
```

Two things that are easy to get wrong:

- **`npx tsc --noEmit` is not a valid web typecheck.** The web project
  references a composite Node config, so a clean checkout fails `TS6305`. Use
  `make typecheck`, which runs `tsc -b`.
- **Backend tooling runs through `uv run`** from `apps/api/` (what CI and the
  Makefile use). There is no host virtualenv to source.

**Stack up:** `docker compose up -d --build` (`make up`); `docker compose watch`
(`make watch`) for live reload. Plain `up` without `--build` pulls the published
images, which is what an end user does.

## Non-Obvious Invariants

1. **Migrations run automatically on API boot** (in the FastAPI lifespan hook via Alembic `upgrade head`). Never add a manual migration step or tell users to run one. The lifespan handles it.

2. **`apps/web/src/types/api.generated.ts` is generated — never hand-edit it.** After changing `apps/api/app/models/schemas.py`, regenerate with `bash scripts/generate-api-types.sh` from the repo root. CI runs `git diff --exit-code` on this file. The hand-written types in `apps/web/src/types/index.ts` deliberately derive from the generated file so `tsc` catches API drift at compile time.

3. **The preview and the export are the same code.** `apps/engine` builds natively for the render server and to WebAssembly for the editor preview. Never draw captions anywhere else (CSS, a second canvas implementation): a second renderer is how preview and export drift. Caption edits live there too (`edit.rs`: lines, retiming, editing a word), called by the web through WASM and by the iOS app through `include/opencaptions_engine.h`; editors only draw and handle gestures. The engine is deterministic — integer blur, no platform maths — so both builds produce byte-identical frames. See `docs/DESIGN.md`.

4. **Rendered-output cache is content-addressed.** A sha256 hash of (transcript + timing offset + style + format + dimensions + fps) names the S3 object (`apps/api/app/services/render_formats.py::compute_render_hash`). Readiness is answered by a storage existence check. Do not reintroduce render-state columns on the projects table.

5. **Per-codec encoding facts live only in `apps/api/app/services/render_formats.py`.** Never hardcode a CRF at a call site. CRF defaults differ per codec (H.264=18, H.265=23, VP9=28), and ProRes accepts no CRF at all (uses a profile). Codec and container are coupled: VP9→.webm, ProRes→.mov. The engine maps each codec to its encoder and audio codec.

6. **"Rendering" is not a user-facing concept.** The UI has a single Download button. No user-visible string may mention rendering. `render` remains correct in backend code and logs.

7. **Containers must not invoke `uv`** — it exists only in the builder stage of `apps/api/Dockerfile`. The dev overlay uses `/app/.venv/bin/` binaries directly (`uvicorn`, `celery`, `watchmedo`, `pytest`). If you break this, the dev overlay fails at runtime.

8. **`POST /projects` accepts a user-supplied `video_url` — the SSRF guard in `apps/api/app/services/video_fetch.py` is load-bearing.** It validates scheme, resolves DNS, blocks private/link-local IPs, and re-validates on every redirect hop. Do not weaken it to simplify a test.

9. **Editor autosaves on debounce.** There is no Save button. Do not reintroduce one.

10. **There is no env file, and reintroducing one is a regression.** Application
    defaults live in `apps/api/app/core/config.py`; the compose files name only
    the credentials two services must agree on, the service topology, and
    per-service overrides. Compose auto-loads a `.env` on top of anything, so an
    env file lets an untracked copy silently pin settings. `check-compose.sh`
    holds every copy of a fallback equal to the others and to the code default.

11. **`docker-compose.yml` is the only compose file, and alone it runs the
    product.** An end user copies it and nothing else. Repository paths may
    appear only under `build:` and `develop:`, which Compose reads solely when
    building or watching. Never add a volume or config that needs a checkout.

12. **Exactly one host port is published: the web UI, on `0.0.0.0:5173`.**
    nginx proxies `/api`, `/ws` and the OpenAPI docs, so no other service needs a
    host port — do not add one back for convenience. Reach a service with
    `docker compose exec`, and the API through the web origin
    (`localhost:5173/api/v1/...`). The bind address is a documented security
    property (README, SECURITY.md); changing it is an edit to that line, not a variable.

## Layout

| Path | Owns |
|------|------|
| `apps/api/` | FastAPI + Celery workers. Pydantic models, Alembic migrations, services, tasks. |
| `apps/web/` | Vite + React frontend. The preview is the engine's WebAssembly build drawing over a `<video>`. Zustand state. |
| `apps/engine/` | Rust caption engine. The library draws frames and makes caption edits behind one C ABI (`include/`); the binary serves `POST /render` (FFmpeg decode, composite, encode, presigned upload). Fonts in `fonts/` are discovered, not listed. |
| `docker-compose.yml` | The whole stack (invariant 11). The GPU worker is a `gpu` profile in it; the acceptance gate adds a small inline override. |
| `scripts/` | `ci-local.sh` (acceptance gate), `check-ci-parity.sh`, `check-compose.sh`, `check-version-sync.sh`, `generate-api-types.sh`, plus `reset_password.py` (recovery without SMTP). |
| `docs/DESIGN.md` | The design: services, the job flow, the engine, data, security, configuration, the iOS app. Keep it current. |
| `Makefile` | All lifecycle targets (`up`, `watch`, `test`, `lint`, `generate-types`, etc). |

## Conventions

- **Commits:** Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`).
- **Python:** ruff, 100-char line length, target py312, strict mypy, and an enforced mccabe complexity budget (`max-complexity = 10`). See `apps/api/pyproject.toml [tool.ruff]`.
- **TypeScript/JS:** biome (formatter + linter), 100-char line width, 2-space indent, double quotes, semicolons. See `apps/web/biome.json`.
- **Rust:** `cargo fmt`, `clippy -D warnings` for the server, `wasm32-unknown-unknown` and `aarch64-apple-ios`, edition 2024.
- **Strict TypeScript:** `tsconfig.json` sets `"strict": true`. No `as any`, `@ts-ignore`, or `@ts-expect-error`.
- **License:** AGPL-3.0-only, and contributors accept `CLA.md`.
