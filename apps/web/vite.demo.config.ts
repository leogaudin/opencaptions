import path from "node:path";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig, type Plugin } from "vite";

// The public demo (opencaptions.app), a second entry of this app with no API: static files for
// Cloudflare Pages. `demo-public/` replaces `public/` so the application's own assets stay out.
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

export default defineConfig({
  root: __dirname,
  publicDir: "demo-public",
  plugins: [demoAsIndex, react(), tailwindcss()],
  resolve: { alias: { "@": path.resolve(__dirname, "./src") } },
  server: { host: true, port: 5174 },
  build: {
    outDir: "dist-demo",
    sourcemap: false,
    rollupOptions: { input: path.resolve(__dirname, "demo.html") },
  },
});
