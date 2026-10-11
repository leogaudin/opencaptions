/**
 * The public demo's HTML: the tags for each page's <head> and the body of the page, rendered from the
 * same components the browser runs (`src/demo/prerender.tsx`), in every language the page is in.
 * Search engines and AI assistants mostly do not run scripts, so without this they would read an
 * empty page. Used by the demo build (`vite.demo.config.ts`) and by the tests.
 */
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createServer, type ViteDevServer } from "vite";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const ENTRY = "/src/demo/prerender.tsx";

/** What `demo.html` holds in their place. */
const HEAD_PLACEHOLDER = "<!--seo-head-->";
const ROOT_ELEMENT = '<div id="root"></div>';

export interface DemoHtml {
  head: string;
  body: string;
}

interface PrerenderModule {
  languages: string[];
  renderLanguage(code: string): Promise<DemoHtml>;
}

/**
 * Renders the page in one language (`only`) or in all of them, keyed by language code, in the given
 * dev server or in one made for the purpose.
 */
export async function renderDemo(
  options: { only?: string; server?: ViteDevServer } = {},
): Promise<Record<string, DemoHtml>> {
  const vite =
    options.server ??
    (await createServer({
      root: ROOT,
      configFile: false,
      logLevel: "error",
      appType: "custom",
      server: { middlewareMode: true, watch: null, hmr: false },
      resolve: { alias: { "@": path.join(ROOT, "src") } },
      oxc: { jsx: { runtime: "automatic" } },
    }));
  try {
    const mod = (await vite.ssrLoadModule(ENTRY)) as PrerenderModule;
    const pages: Record<string, DemoHtml> = {};
    // One after the other: the language is state of the module they all read.
    for (const code of options.only ? [options.only] : mod.languages) {
      pages[code] = await mod.renderLanguage(code);
    }
    return pages;
  } finally {
    if (!options.server) await vite.close();
  }
}

/**
 * `demo.html` with its head tags and its body filled in (English, or the language of `code`). Without
 * `withBody` the body stays empty: the dev server loads the styles with the script, so a prerendered
 * body would show unstyled until then.
 */
export function fillPage(html: string, page: DemoHtml, code = "en", withBody = true): string {
  if (!html.includes(HEAD_PLACEHOLDER) || !html.includes(ROOT_ELEMENT)) {
    throw new Error("demo.html has lost the placeholders the prerender fills in");
  }
  if (withBody && !page.body.includes("<h1")) {
    throw new Error("the prerendered demo page has no heading");
  }
  // Functions, not strings: the page may contain "$&" and the like, which a string would expand.
  return html
    .replace('<html lang="en">', () => `<html lang="${code}">`)
    .replace(HEAD_PLACEHOLDER, () => page.head)
    .replace(ROOT_ELEMENT, () => (withBody ? `<div id="root">${page.body}</div>` : ROOT_ELEMENT));
}

/**
 * The built English page (its scripts and styles are the same in every language) as the page of
 * another language: its head tags, its body and its `lang`.
 */
export function localizePage(built: string, english: DemoHtml, page: DemoHtml, code: string): string {
  for (const part of [english.head, english.body, '<html lang="en">']) {
    if (!built.includes(part)) throw new Error("the built demo page is not the one that was prerendered");
  }
  return built
    .replace('<html lang="en">', () => `<html lang="${code}">`)
    .replace(english.head, () => page.head)
    .replace(english.body, () => page.body);
}
