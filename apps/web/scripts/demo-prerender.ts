/**
 * The public demo's HTML: the tags for its <head> and the body of the page, rendered from the same
 * components the browser runs (`src/demo/prerender.tsx`). Search engines and AI assistants mostly do
 * not run scripts, so without this they would read an empty page. Used by the demo build
 * (`vite.demo.config.ts`) and by the tests.
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
  headTags(): string;
  renderPage(): string;
}

/** Renders the page, in the given dev server or in one made for the purpose. */
export async function renderDemo(server?: ViteDevServer): Promise<DemoHtml> {
  const vite =
    server ??
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
    return { head: mod.headTags(), body: mod.renderPage() };
  } finally {
    if (!server) await vite.close();
  }
}

/** `demo.html` with its head tags and its body filled in. */
export function fillPage(html: string, page: DemoHtml): string {
  if (!html.includes(HEAD_PLACEHOLDER) || !html.includes(ROOT_ELEMENT)) {
    throw new Error("demo.html has lost the placeholders the prerender fills in");
  }
  if (!page.body.includes("<h1")) throw new Error("the prerendered demo page has no heading");
  // A function, not a string: the page may contain "$&" and the like, which a string would expand.
  return html
    .replace(HEAD_PLACEHOLDER, () => page.head)
    .replace(ROOT_ELEMENT, () => `<div id="root">${page.body}</div>`);
}
