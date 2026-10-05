# OpenCaptions web

Vite + React 19 + TypeScript + Tailwind CSS 4 frontend, with Radix primitives for accessible overlays.

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
├── pages/                     # routes; EditorPage lays out the preview, style panel and timeline dock
├── components/
│   ├── CaptionPreview.tsx     # the video with the engine's frame over it; drag and word edit
│   ├── TimelineDock.tsx       # the dock: the timeline, or a note until there are captions
│   ├── timeline/              # Timeline (zoom, playhead, seeking), Ruler, CaptionTrack
│   └── Transport.tsx          # play/pause, timecode, mute, and the keys
├── lib/
│   ├── engine.ts              # the caption engine's WebAssembly build: drawing and edits
│   ├── playback.tsx           # the one <video>, shared by the preview, timeline and transport
│   ├── presets.json           # built-in style presets, shared with the iOS app
│   └── timelineScale.ts       # ruler ticks and the zoom limits
├── types/                     # api.generated.ts (generated, committed) and hand-written types
└── store/                     # Zustand stores
```

The preview is drawn by the same Rust engine that renders the export ([`apps/engine`](../engine)), compiled to WebAssembly. The image build compiles it and copies the fonts into `public/engine/`; for `npm run dev`, run `make engine-wasm` once. Every transcript edit (a word's text, a caption's edges) is also the engine's, through the same module; the editor only draws and handles gestures.

## State management

[Zustand](https://zustand-demo.pmnd.rs/) is used for shared state in the editor.
