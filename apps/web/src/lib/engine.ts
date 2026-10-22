/**
 * The caption engine in the browser: the same Rust library that draws the export,
 * compiled to WebAssembly, drawing the editor preview. Same code and same fonts,
 * so what the preview shows is what the export contains.
 *
 * The module and fonts are fetched once and one instance serves the whole page: each preview, the
 * tiles and the word card hold a scene of their own in it (a handle), so none disturbs another.
 */
import { useEffect, useState } from "react";
import { type FontManifest, parseFontManifest } from "@/lib/fontManifest";
import { fontSource } from "@/lib/sources";
import type { StyleConfig, Transcript } from "@/types";

const BASE = "/engine";

interface Exports {
  memory: WebAssembly.Memory;
  oc_alloc(len: number): number;
  oc_result_ptr(): number;
  oc_result_len(): number;
  oc_add_font_at(ptr: number, len: number, rank: number): number;
  oc_script_fonts(ptr: number, len: number): number;
  oc_has_font(ptr: number, len: number): number;
  oc_add_requested_font(namePtr: number, nameLen: number, ptr: number, len: number): number;
  oc_scene_new(ptr: number, len: number): number;
  oc_scene_free(scene: number): void;
  oc_render(scene: number, t: number): number;
  oc_frame_ptr(scene: number): number;
  oc_frame_width(scene: number): number;
  oc_frame_height(scene: number): number;
  oc_changed_top(scene: number): number;
  oc_changed_bottom(scene: number): number;
  oc_active_index(scene: number): number;
  oc_active_bounds(scene: number): number;
  oc_active_word_rects(scene: number): number;
  oc_snap_axis(
    position: number,
    extent: number,
    anchor: number,
    size: number,
    threshold: number,
    margin: number,
    out: number,
  ): void;
  oc_fallback_fonts(ptr: number, len: number): number;
  oc_caption_lines(ptr: number, len: number, wordsPerLine: number, offsetMs: number): number;
  oc_subtitles(
    ptr: number,
    len: number,
    wordsPerLine: number,
    offsetMs: number,
    format: number,
  ): number;
  oc_retime_word(
    ptr: number,
    len: number,
    index: number,
    edge: number,
    time: number,
    offsetMs: number,
  ): number;
  oc_set_word(ptr: number, len: number, index: number, textPtr: number, textLen: number): number;
  oc_set_variant(ptr: number, len: number, index: number, variant: number): number;
  oc_shuffle_variants(ptr: number, len: number, count: number, seed: number): number;
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
  /** Fonts to draw with where the style's lacks a letter, already loaded (`loadFallbackFonts`). */
  fallback_fonts?: string[];
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
  /** Flat index of this line's first word: word N here is transcript word `index + N`. */
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
/** A caption position along one axis after magnetism toward the frame's centre and margins. */
export interface SnappedAxis {
  position: number;
  /** The guide line the block is on, a share of the axis, or null if it is free. */
  line: number | null;
}

/** Which part of a caption block is at its position: 0 its start, 0.5 its middle, 1 its end. */
export type BlockAnchor = 0 | 0.5 | 1;

export interface CaptionEditor {
  /**
   * Magnetism for dragging the caption block along one axis: its start, middle and end are pulled to
   * the frame's near margin, centre and far margin when within `threshold` of them. `position` is
   * where the block is held, `anchor` which part of it that is, `extent` its length and `margin` the
   * margins, shares of the axis; `size` is the axis as the preview shows it, in the unit of
   * `threshold` (screen pixels), so the pull feels the same at any size.
   */
  snapAxis(
    position: number,
    extent: number,
    anchor: BlockAnchor,
    size: number,
    threshold: number,
    margin: number,
  ): SnappedAxis;
  /**
   * The captions, cut every `wordsPerLine` words (fewer around a long pause) as the export
   * cuts them, with times as shown (the caption offset applied).
   */
  lines(t: Transcript, wordsPerLine: number, offsetMs: number): CaptionLine[];
  /** The transcript as a subtitle file whose cues are those lines, times as shown. */
  subtitles(t: Transcript, wordsPerLine: number, offsetMs: number, format: "srt" | "vtt"): string;
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
  /**
   * Gives one word the look `variant` of the style (an index into its variants), or the style's own
   * with null, keeping its text and timing.
   */
  setVariant(t: Transcript, index: number, variant: number | null): Transcript;
  /**
   * Deals every word one of `count` looks (or the style's own) at random from `seed`: the same seed
   * gives the same looks, another seed deals again. Text and timing stay.
   */
  shuffleVariants(t: Transcript, count: number, seed: number): Transcript;
}

export interface CaptionRenderer {
  /**
   * Make `family` drawable: fetch it unless a bundled face has that name, the
   * rule the engine applies to an export, so both draw with the same file.
   */
  loadFont(family: string): Promise<void>;
  /**
   * Load the fonts a transcript's scripts need that are not bundled (Chinese, Japanese,
   * Korean...), as the engine names them, and return their families for the scene's
   * `fallback_fonts`. The server's render reads the same families from the same place. The
   * bundled script faces (Arabic, Hebrew, Devanagari, Thai) are fetched here too, when the
   * words have letters of their script: they are not fetched with the engine.
   */
  loadFallbackFonts(transcript: Transcript): Promise<string[]>;
  /** Lay out captions for a new transcript, style or size. */
  setScene(input: SceneInput): void;
  /**
   * What changed in the overlay at `t` seconds, or null when nothing did: the rows
   * from `top` as an image the frame's width (the whole frame after a new scene).
   * Drawing it at (0, top) over the last one gives the frame.
   */
  render(t: number): FrameUpdate | null;
  /** Which line is showing now (its index), or -1 for none: cheap, unlike {@link activeCaption}. */
  activeIndex(): number;
  /** The caption showing now, in frame pixels, or null when none shows. */
  activeCaption(): ActiveCaption | null;
  /** Releases the scene this renderer holds. Call it when the renderer is no longer used. */
  dispose(): void;
}

interface Assets {
  module: WebAssembly.Module;
  manifest: FontManifest;
  /** The font files fetched with the engine, with their places among all of them. */
  fonts: { rank: number; bytes: Uint8Array }[];
}

/** A script face the engine ships: fetched when a caption has letters of its script. */
interface ScriptFace {
  file: string;
  family: string;
}

let assets: Promise<Assets> | null = null;

/** A fetch that fails on a missing file, instead of handing back whatever page answered. */
async function fetchOk(url: string): Promise<Response> {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${url}: ${r.status}`);
  return r;
}

/** The module, compiled while it downloads (when the server says it is WebAssembly). */
async function compileModule(url: string): Promise<WebAssembly.Module> {
  const response = await fetchOk(url);
  try {
    return await WebAssembly.compileStreaming(response.clone());
  } catch {
    // A server that does not send `application/wasm` fails streaming; the bytes still compile.
    return WebAssembly.compile(await response.arrayBuffer());
  }
}

/** A bundled font file, fetched once for every preview on the page. */
const fontFiles = new Map<string, Promise<Uint8Array>>();

function fontFile(file: string): Promise<Uint8Array> {
  let bytes = fontFiles.get(file);
  if (!bytes) {
    bytes = fetchOk(`${BASE}/fonts/${encodeURIComponent(file)}`)
      .then((r) => r.arrayBuffer())
      .then((b) => new Uint8Array(b));
    const fetched = bytes;
    fontFiles.set(file, fetched);
    // A failed fetch must not poison the file for every later caption.
    fetched.catch(() => fontFiles.delete(file));
  }
  return bytes;
}

function loadAssets(): Promise<Assets> {
  assets ??= (async () => {
    // The module compiles while the fonts come in, instead of before them.
    const compiled = compileModule(`${BASE}/opencaptions_engine.wasm`);
    const fonts = fetchOk(`${BASE}/fonts.json`)
      .then((r) => r.json() as Promise<Parameters<typeof parseFontManifest>[0]>)
      .then(async (raw) => {
        const manifest = parseFontManifest(raw);
        const files = await Promise.all(
          manifest.fonts.map(async (file) => ({
            rank: manifest.rank(file),
            bytes: await fontFile(file),
          })),
        );
        return { manifest, files };
      });
    const [module, { manifest, files }] = await Promise.all([compiled, fonts]);
    return { module, manifest, fonts: files };
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

/** The engine of this page: one module instance with every bundled font registered. */
interface Engine {
  x: Exports;
  assets: Assets;
  /** The bundled families, as declared by the font files, and those of the script faces not fetched yet. */
  families: string[];
  scriptFamilies: Map<string, ScriptFace>;
}

let engineOnce: Promise<Engine> | undefined;

/** The script faces a transcript needs, or all of them for none (the engine's rule). */
function scriptFacesFor(x: Exports, transcript?: Transcript): ScriptFace[] {
  const json = transcript ? encoder.encode(JSON.stringify(transcript)) : new Uint8Array();
  if (!x.oc_script_fonts(...copyIn(x, json))) {
    throw new Error(`caption engine rejected the transcript: ${result(x)}`);
  }
  return JSON.parse(result(x)) as ScriptFace[];
}

function engine(): Promise<Engine> {
  engineOnce ??= (async () => {
    const loaded = await loadAssets();
    const x = (await WebAssembly.instantiate(loaded.module)).exports as unknown as Exports;
    const names = loaded.fonts.flatMap((f) =>
      x.oc_add_font_at(...copyIn(x, f.bytes), f.rank) ? [result(x)] : [],
    );
    // The script faces are listed though not fetched: they are bundled, just not here yet.
    const scripts = scriptFacesFor(x);
    return {
      x,
      assets: loaded,
      families: [...new Set([...names, ...scripts.map((face) => face.family)])].sort(),
      scriptFamilies: new Map(scripts.map((face) => [face.family.toLowerCase(), face] as const)),
    };
  })();
  // A failed load must not poison every later preview.
  engineOnce.catch(() => {
    engineOnce = undefined;
  });
  return engineOnce;
}

/** A font file fetched through this instance, shared by every preview on the page. */
const requested = new Map<string, Promise<Uint8Array | null>>();

function requestedFont(family: string): Promise<Uint8Array | null> {
  let font = requested.get(family);
  if (!font) {
    // An unknown family is drawn in the default face, as the export would be.
    font = fetch(fontSource(family))
      .then((r) => (r.ok ? r.arrayBuffer() : null))
      .then((b) => (b ? new Uint8Array(b) : null))
      .catch(() => null);
    requested.set(family, font);
  }
  return font;
}

/** Fonts are the page's, not a scene's: shared by every renderer. */
function fontLoader({
  x,
  assets: loaded,
  scriptFamilies,
}: Engine): Pick<CaptionRenderer, "loadFont" | "loadFallbackFonts"> {
  /** Registers a script face at its place among the bundled ones, unless it is there already. */
  const addScriptFace = async (face: ScriptFace): Promise<void> => {
    const has = (): boolean => x.oc_has_font(...copyIn(x, encoder.encode(face.family))) !== 0;
    if (has()) return;
    const bytes = await fontFile(face.file);
    // Checked again: another call may have added it while this one waited.
    if (!has()) x.oc_add_font_at(...copyIn(x, bytes), loaded.manifest.rank(face.file));
  };
  // The families a transcript needs depend on its words alone, and a style change (a
  // drag, a slider) rebuilds the scene with the same transcript: ask the engine once.
  const fallbackFor = new WeakMap<Transcript, Promise<string[]>>();
  const loadFont = async (family: string): Promise<void> => {
    const name = encoder.encode(family);
    if (x.oc_has_font(...copyIn(x, name))) return;
    // A bundled script face comes from the engine's own files, not from the font catalog.
    const bundled = scriptFamilies.get(family.toLowerCase());
    if (bundled) return addScriptFace(bundled);
    const font = await requestedFont(family);
    // Checked again: another call may have added it while this one waited.
    if (font && !x.oc_has_font(...copyIn(x, name))) {
      x.oc_add_requested_font(...copyIn(x, name), ...copyIn(x, font));
    }
  };
  return {
    loadFont,
    loadFallbackFonts(transcript) {
      let families = fallbackFor.get(transcript);
      if (!families) {
        families = (async () => {
          if (!x.oc_fallback_fonts(...copyIn(x, encoder.encode(JSON.stringify(transcript))))) {
            throw new Error(`caption engine rejected the transcript: ${result(x)}`);
          }
          const needed = JSON.parse(result(x)) as string[];
          // The bundled script faces the words need come with them (an Arabic caption's), apart
          // from the families the scene names.
          const scripts = scriptFacesFor(x, transcript);
          await Promise.all([...scripts.map(addScriptFace), ...needed.map(loadFont)]);
          return needed;
        })();
        families.catch(() => fallbackFor.delete(transcript));
        fallbackFor.set(transcript, families);
      }
      return families;
    },
  };
}

let fonts: Pick<CaptionRenderer, "loadFont" | "loadFallbackFonts"> | undefined;

/** A renderer: a scene of its own in the page's engine. */
export async function createCaptionRenderer(): Promise<CaptionRenderer> {
  const e = await engine();
  const { x } = e;
  fonts ??= fontLoader(e);
  let scene = 0;
  return {
    ...fonts,
    setScene(input) {
      const next = x.oc_scene_new(...copyIn(x, encoder.encode(JSON.stringify(input))));
      if (!next) throw new Error(`caption engine rejected the scene: ${result(x)}`);
      if (scene) x.oc_scene_free(scene);
      scene = next;
    },
    render(t) {
      if (!scene || !x.oc_render(scene, t)) return null;
      const w = x.oc_frame_width(scene);
      const [top, bottom] = [x.oc_changed_top(scene), x.oc_changed_bottom(scene)];
      if (bottom <= top) return null;
      // Copied out: the view would detach if the engine's memory grew. Only the changed
      // rows: a whole frame per screen refresh was most of what playing cost.
      const start = x.oc_frame_ptr(scene) + top * w * 4;
      const pixels = new Uint8ClampedArray(x.memory.buffer, start, (bottom - top) * w * 4).slice();
      return { image: new ImageData(pixels, w, bottom - top), top };
    },
    activeIndex: () => (scene ? x.oc_active_index(scene) : -1),
    activeCaption() {
      const index = scene ? x.oc_active_index(scene) : -1;
      if (index < 0) return null;
      if (!x.oc_active_bounds(scene)) return null;
      const [bx, by, bw, bh] = resultFloats(x);
      x.oc_active_word_rects(scene);
      const flat = resultFloats(x);
      const words: Rect[] = [];
      for (let i = 0; i + 3 < flat.length; i += 4) {
        words.push({ x: flat[i]!, y: flat[i + 1]!, w: flat[i + 2]!, h: flat[i + 3]! });
      }
      return { bounds: { x: bx!, y: by!, w: bw!, h: bh! }, index, words };
    },
    dispose() {
      if (scene) x.oc_scene_free(scene);
      scene = 0;
    },
  };
}

/** The bundled families, as declared by the font files themselves. */
export function engineFamilies(): Promise<string[]> {
  return engine().then((e) => e.families);
}

let editor: Promise<CaptionEditor> | undefined;

/** The caption editor, in the page's engine. It draws nothing, so it keeps no scene. */
export function loadCaptionEditor(): Promise<CaptionEditor> {
  editor ??= engine().then(({ x }) => {
    const json = (t: Transcript): [number, number] => copyIn(x, encoder.encode(JSON.stringify(t)));
    const parse = <T>(ok: number): T => {
      if (!ok) throw new Error(`caption engine rejected the edit: ${result(x)}`);
      return JSON.parse(result(x)) as T;
    };
    // Where `oc_snap_axis` writes its two floats; kept for the life of the page.
    const snapOut = x.oc_alloc(8);
    return {
      lines: (t, wordsPerLine, offsetMs) =>
        parse(x.oc_caption_lines(...json(t), wordsPerLine, offsetMs)),
      subtitles: (t, wordsPerLine, offsetMs, format) =>
        parse(x.oc_subtitles(...json(t), wordsPerLine, offsetMs, format === "srt" ? 0 : 1)),
      retimeWord: (t, index, edge, time, offsetMs) =>
        parse(x.oc_retime_word(...json(t), index, edge === "start" ? 0 : 1, time, offsetMs)),
      setWord: (t, index, text) =>
        parse(x.oc_set_word(...json(t), index, ...copyIn(x, encoder.encode(text)))),
      setVariant: (t, index, variant) => parse(x.oc_set_variant(...json(t), index, variant ?? -1)),
      shuffleVariants: (t, count, seed) => parse(x.oc_shuffle_variants(...json(t), count, seed)),
      snapAxis: (position, extent, anchor, size, threshold, margin) => {
        x.oc_snap_axis(position, extent, anchor, size, threshold, margin, snapOut);
        const [snapped, line] = new Float32Array(x.memory.buffer, snapOut, 2);
        return { position: snapped!, line: line! < 0 ? null : line! };
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
