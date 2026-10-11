import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig, type Plugin } from "vite";
import { fillPage, localizePage, renderDemo } from "./scripts/demo-prerender.ts";

// The public demo (opencaptions.app), a second entry of this app with no API: static files for
// a Cloudflare Worker. `demo-public/` replaces `public/` so the application's own assets stay out.
// The application's own index.html sits in the same folder, and the dev server would serve it at
// "/": the app, with no API behind it. The demo is demo.html.
// A page's address names its language: "/" is English, "/fr/" French, and so on.
const LANGUAGE_PATH = /^\/([a-z]{2})\/(\?.*)?$/;

const demoAsIndex: Plugin = {
  name: "demo-as-index",
  configureServer(server) {
    server.middlewares.use((req, _res, next) => {
      if (req.url === "/" || req.url?.startsWith("/?") || LANGUAGE_PATH.test(req.url ?? "")) {
        req.url = "/demo.html";
      }
      next();
    });
  },
};

// The page's <head> (title, cards, structured data) and its text are written into the HTML, so a
// crawler that runs no script reads them; React replaces the body when the demo is ready. The
// build also writes the page of every other language, at "/<code>/index.html".
let outDir = "";
const demoPage: Plugin = {
  name: "demo-page",
  configResolved(config) {
    outDir = config.command === "build" ? path.resolve(config.root, config.build.outDir) : "";
  },
  async transformIndexHtml(html, ctx) {
    const code = LANGUAGE_PATH.exec(ctx.originalUrl ?? "")?.[1] ?? "en";
    const pages = await renderDemo({ only: code, server: ctx.server });
    const page = pages[code] ?? (pages.en as NonNullable<(typeof pages)[string]>);
    return fillPage(html, page, pages[code] ? code : "en");
  },
  async closeBundle() {
    if (!outDir) return;
    const built = readFileSync(path.join(outDir, "demo.html"), "utf8");
    const pages = await renderDemo();
    const english = pages.en;
    if (!english) throw new Error("no English page was prerendered");
    for (const [code, page] of Object.entries(pages)) {
      if (code === "en") continue;
      mkdirSync(path.join(outDir, code), { recursive: true });
      writeFileSync(path.join(outDir, code, "index.html"), localizePage(built, english, page, code));
    }
  },
};

export default defineConfig({
  root: __dirname,
  publicDir: "demo-public",
  plugins: [demoAsIndex, demoPage, react(), tailwindcss()],
  resolve: { alias: { "@": path.resolve(__dirname, "./src") } },
  server: { host: true, port: 5174 },
  build: {
    outDir: "dist-demo",
    sourcemap: false,
    rollupOptions: { input: path.resolve(__dirname, "demo.html") },
  },
});
