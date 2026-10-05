# OpenCaptions web

Vite + React 18 + TypeScript + Tailwind CSS 3 frontend, with Radix primitives for accessible overlays.

## Local dev

```bash
npm install
npm run dev          # http://localhost:5173
```

## Build for production

```bash
npm run build        # output: dist/
npm run preview      # serve dist locally
```

## Generate types from backend OpenAPI spec

```bash
npm run generate-types
```

No running stack is needed: the script imports the FastAPI app and dumps its
schema offline.

This regenerates `src/types/api.generated.ts` from the FastAPI OpenAPI spec. CI fails if the file is out of sync.

## Tests

```bash
# Headless Playwright e2e (requires the full compose stack running)
npm run test:e2e
```

## Project structure

```
src/
├── App.tsx                    # app shell, routing, header
├── main.tsx                   # entrypoint
├── index.css                  # Tailwind theme tokens
├── lib/engine.ts              # the caption engine's WebAssembly build, drawing the preview
├── types/                     # generated types (.gitignore'd)
└── store/                     # Zustand stores
```

The preview is drawn by the same Rust engine that renders the export ([`apps/engine`](../engine)), compiled to WebAssembly. The image build compiles it and copies the fonts into `public/engine/`; for `npm run dev`, run `make engine-wasm` once.

## State management

[Zustand](https://zustand-demo.pmnd.rs/) is used for shared state in the editor.
