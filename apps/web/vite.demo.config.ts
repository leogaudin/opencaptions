import path from "node:path";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// The public demo (opencaptions.app), a second entry of this app with no API: static files for
// Cloudflare Pages. `demo-public/` replaces `public/` so the application's own assets stay out.
export default defineConfig({
  root: __dirname,
  publicDir: "demo-public",
  plugins: [react(), tailwindcss()],
  resolve: { alias: { "@": path.resolve(__dirname, "./src") } },
  server: { host: true, port: 5174 },
  build: {
    outDir: "dist-demo",
    sourcemap: false,
    rollupOptions: { input: path.resolve(__dirname, "demo.html") },
  },
});
