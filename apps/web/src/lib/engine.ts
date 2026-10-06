/**
 * The caption engine in the browser: the same Rust library that draws the export,
 * compiled to WebAssembly, drawing the editor preview. Same code and same fonts,
 * so what the preview shows is what the export contains.
 *
 * The module and fonts are fetched once; each preview gets its own instance,
 * since an instance holds one scene and the editor mounts more than one preview.
 */
import { useEffect, useState } from "react";
import type { StyleConfig, Transcript } from "@/types";

const BASE = "/engine";

interface Exports {
  memory: WebAssembly.Memory;
  oc_alloc(len: number): number;
  oc_result_ptr(): number;
  oc_result_len(): number;
  oc_add_font(ptr: number, len: number): number;
  oc_has_font(ptr: number, len: number): number;
  oc_add_requested_font(namePtr: number, nameLen: number, ptr: number, len: number): number;
  oc_set_scene(ptr: number, len: number): number;
  oc_render(t: number): number;
  oc_frame_ptr(): number;
  oc_frame_width(): number;
  oc_frame_height(): number;
  oc_changed_top(): number;
  oc_changed_bottom(): number;
  oc_active_index(): number;
  oc_active_bounds(): number;
  oc_active_word_rects(): number;
  oc_snap_position(x: number, y: number, width: number, height: number, threshold: number): number;
  oc_caption_lines(ptr: number, len: number, wordsPerLine: number, offsetMs: number): number;
  oc_retime_word(
    ptr: number,
    len: number,
    index: number,
    edge: number,
    time: number,
    offsetMs: number,
  ): number;
  oc_set_word(ptr: number, len: number, index: number, textPtr: number, textLen: number): number;
}

/** The rows of the overlay that changed, from `top`, the frame's width. */
export interface FrameUpdate {
  image: ImageData;
  top: number;
}

export interface SceneInput {
  transcript: Transcript;
  style: StyleConfig;
  width: number;
  height: number;
  /** The global caption timing offset in ms (positive = later); the engine applies it. */
  caption_offset_ms: number;
}

/** A rectangle in frame pixels (the engine's own coordinates). */
export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** The caption showing at the last rendered time, for the editor to manipulate. */
export interface ActiveCaption {
  /** The block rectangle, for dragging the whole caption. */
  bounds: Rect;
  /** Index of this line among all lines: word N here is transcript word `index * wordsPerLine + N`. */
  index: number;
  /** Each word's rectangle in line order, for picking the word under a double-click. */
  words: Rect[];
}

/** One caption as the viewer sees it: words `from`..`from + count` in reading order. */
export interface CaptionLine {
  from: number;
  count: number;
  start: number;
  end: number;
  text: string;
}

/**
 * The engine's caption edits, the same code the phone app calls. Each is a pure
 * function of a transcript; words are addressed by their flat index across
 * segments, as captions are cut.
 */
/** A caption position after magnetism toward the video's centre lines. */
export interface SnappedPosition {
  x: number;
  y: number;
  /** Whether x was pulled to the vertical centre line, and y to the horizontal one. */
  onX: boolean;
  onY: boolean;
}

export interface CaptionEditor {
  /**
   * Magnetism for dragging the caption block: each axis snaps to the video's centre
   * when the block's centre is within `threshold` of it. `size` is the preview's size
   * in the unit of `threshold` (screen pixels), so the pull feels the same at any size.
   */
  snapPosition(
    position: { x: number; y: number },
    size: { width: number; height: number },
    threshold: number,
  ): SnappedPosition;
  /**
   * The captions, cut every `wordsPerLine` words as the export cuts them, with
   * times as shown (the caption offset applied).
   */
  lines(t: Transcript, wordsPerLine: number, offsetMs: number): CaptionLine[];
  /**
   * Moves one edge of a word to `time` as shown, stopping at its neighbours. The
   * returned transcript has unshifted times.
   */
  retimeWord(
    t: Transcript,
    index: number,
    edge: "start" | "end",
    time: number,
    offsetMs: number,
  ): Transcript;
  /**
   * Sets the text of one word, keeping its timing. Empty text removes the word;
   * spaces inside stay (collapsed to one), so it is still a single word.
   */
  setWord(t: Transcript, index: number, text: string): Transcript;
}

export interface CaptionRenderer {
  /**
   * Make `family` drawable: fetch it unless a bundled face has that name, the
   * rule the engine applies to an export, so both draw with the same file.
   */
  loadFont(family: string): Promise<void>;
  /** Lay out captions for a new transcript, style or size. */
  setScene(input: SceneInput): void;
  /**
   * What changed in the overlay at `t` seconds, or null when nothing did: the rows
   * from `top` as an image the frame's width (the whole frame after a new scene).
   * Drawing it at (0, top) over the last one gives the frame.
   */
  render(t: number): FrameUpdate | null;
  /** The caption showing now, in frame pixels, or null when none shows. */
  activeCaption(): ActiveCaption | null;
}

interface Assets {
  module: WebAssembly.Module;
  fonts: Uint8Array[];
}

let assets: Promise<Assets> | null = null;

function loadAssets(): Promise<Assets> {
  assets ??= (async () => {
    const [wasm, names] = await Promise.all([
      fetch(`${BASE}/opencaptions_engine.wasm`).then((r) => r.arrayBuffer()),
      fetch(`${BASE}/fonts.json`).then((r) => r.json() as Promise<string[]>),
    ]);
    const fonts = await Promise.all(
      names.map((n) =>
        fetch(`${BASE}/fonts/${encodeURIComponent(n)}`)
          .then((r) => r.arrayBuffer())
          .then((b) => new Uint8Array(b)),
      ),
    );
    return { module: await WebAssembly.compile(wasm), fonts };
  })();
  // A failed fetch must not poison every later preview.
  assets.catch(() => {
    assets = null;
  });
  return assets;
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function copyIn(x: Exports, bytes: Uint8Array): [number, number] {
  const ptr = x.oc_alloc(bytes.length);
  new Uint8Array(x.memory.buffer, ptr, bytes.length).set(bytes);
  return [ptr, bytes.length];
}

function result(x: Exports): string {
  return decoder.decode(new Uint8Array(x.memory.buffer, x.oc_result_ptr(), x.oc_result_len()));
}

/** The result buffer read as little-endian f32s (geometry calls leave bytes there). */
function resultFloats(x: Exports): number[] {
  const bytes = new Uint8Array(x.memory.buffer, x.oc_result_ptr(), x.oc_result_len()).slice();
  return Array.from(new Float32Array(bytes.buffer));
}

let families: Promise<string[]> | undefined;

async function instantiate(): Promise<{ x: Exports; families: string[] }> {
  const { module, fonts } = await loadAssets();
  const x = (await WebAssembly.instantiate(module)).exports as unknown as Exports;
  const names = fonts.flatMap((f) => (x.oc_add_font(...copyIn(x, f)) ? [result(x)] : []));
  families ??= Promise.resolve([...new Set(names)].sort());
  return { x, families: names };
}

/** A font file fetched through this instance, shared by every preview on the page. */
const requested = new Map<string, Promise<Uint8Array | null>>();

function requestedFont(family: string): Promise<Uint8Array | null> {
  let font = requested.get(family);
  if (!font) {
    // An unknown family is drawn in the default face, as the export would be.
    font = fetch(`/api/v1/fonts/${encodeURIComponent(family)}/file`)
      .then((r) => (r.ok ? r.arrayBuffer() : null))
      .then((b) => (b ? new Uint8Array(b) : null))
      .catch(() => null);
    requested.set(family, font);
  }
  return font;
}

export async function createCaptionRenderer(): Promise<CaptionRenderer> {
  const { x } = await instantiate();
  return {
    async loadFont(family) {
      const name = encoder.encode(family);
      if (x.oc_has_font(...copyIn(x, name))) return;
      const font = await requestedFont(family);
      // Checked again: another call may have added it while this one waited.
      if (font && !x.oc_has_font(...copyIn(x, name))) {
        x.oc_add_requested_font(...copyIn(x, name), ...copyIn(x, font));
      }
    },
    setScene(input) {
      if (!x.oc_set_scene(...copyIn(x, encoder.encode(JSON.stringify(input))))) {
        throw new Error(`caption engine rejected the scene: ${result(x)}`);
      }
    },
    render(t) {
      if (!x.oc_render(t)) return null;
      const w = x.oc_frame_width();
      const [top, bottom] = [x.oc_changed_top(), x.oc_changed_bottom()];
      if (bottom <= top) return null;
      // Copied out: the view would detach if the engine's memory grew. Only the changed
      // rows: a whole frame per screen refresh was most of what playing cost.
      const start = x.oc_frame_ptr() + top * w * 4;
      const pixels = new Uint8ClampedArray(x.memory.buffer, start, (bottom - top) * w * 4).slice();
      return { image: new ImageData(pixels, w, bottom - top), top };
    },
    activeCaption() {
      const index = x.oc_active_index();
      if (index < 0) return null;
      if (!x.oc_active_bounds()) return null;
      const [bx, by, bw, bh] = resultFloats(x);
      x.oc_active_word_rects();
      const flat = resultFloats(x);
      const words: Rect[] = [];
      for (let i = 0; i + 3 < flat.length; i += 4) {
        words.push({ x: flat[i]!, y: flat[i + 1]!, w: flat[i + 2]!, h: flat[i + 3]! });
      }
      return { bounds: { x: bx!, y: by!, w: bw!, h: bh! }, index, words };
    },
  };
}

/** The bundled families, as declared by the font files themselves. */
export function engineFamilies(): Promise<string[]> {
  families ??= instantiate().then((r) => [...new Set(r.families)].sort());
  return families;
}

let editor: Promise<CaptionEditor> | undefined;

/**
 * The caption editor, on an engine instance of its own shared by the page: edits
 * never disturb a preview's scene. It draws nothing, so it registers no fonts.
 */
export function loadCaptionEditor(): Promise<CaptionEditor> {
  editor ??= loadAssets().then(async ({ module }) => {
    const x = (await WebAssembly.instantiate(module)).exports as unknown as Exports;
    const json = (t: Transcript): [number, number] => copyIn(x, encoder.encode(JSON.stringify(t)));
    const parse = <T>(ok: number): T => {
      if (!ok) throw new Error(`caption engine rejected the edit: ${result(x)}`);
      return JSON.parse(result(x)) as T;
    };
    return {
      lines: (t, wordsPerLine, offsetMs) =>
        parse(x.oc_caption_lines(...json(t), wordsPerLine, offsetMs)),
      retimeWord: (t, index, edge, time, offsetMs) =>
        parse(x.oc_retime_word(...json(t), index, edge === "start" ? 0 : 1, time, offsetMs)),
      setWord: (t, index, text) =>
        parse(x.oc_set_word(...json(t), index, ...copyIn(x, encoder.encode(text)))),
      snapPosition: (p, size, threshold) => {
        x.oc_snap_position(p.x, p.y, size.width, size.height, threshold);
        const [sx, sy, onX, onY] = resultFloats(x);
        return { x: sx!, y: sy!, onX: onX === 1, onY: onY === 1 };
      },
    };
  });
  editor.catch(() => {
    editor = undefined;
  });
  return editor;
}

/** The caption editor once the engine has loaded, or null until then. */
export function useCaptionEditor(): CaptionEditor | null {
  const [ready, setReady] = useState<CaptionEditor | null>(null);
  useEffect(() => {
    let live = true;
    loadCaptionEditor().then(
      (e) => live && setReady(e),
      // Without it the timeline stays empty and edits cannot apply; say why.
      (e) => console.error("caption editor failed to load", e),
    );
    return () => {
      live = false;
    };
  }, []);
  return ready;
}
