import path from "node:path";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig, type Plugin } from "vite";
import { fillPage, renderDemo } from "./scripts/demo-prerender.ts";

// The public demo (opencaptions.app), a second entry of this app with no API: static files for
// a Cloudflare Worker. `demo-public/` replaces `public/` so the application's own assets stay out.
// The application's own index.html sits in the same folder, and the dev server would serve it at
// "/": the app, with no API behind it. The demo is demo.html.
const demoAsIndex: Plugin = {
  name: "demo-as-index",
  configureServer(server) {
    server.middlewares.use((req, _res, next) => {
      if (req.url === "/" || req.url?.startsWith("/?")) req.url = "/demo.html";
      next();
    });
  },
};

// The page's <head> (title, cards, structured data) and its text are written into the HTML, so a
// crawler that runs no script reads them; React replaces the body when the demo is ready.
const demoPage: Plugin = {
  name: "demo-page",
  async transformIndexHtml(html, ctx) {
    return fillPage(html, await renderDemo(ctx.server));
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
