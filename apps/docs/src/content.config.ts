import { defineCollection } from "astro:content";
import { docsLoader } from "@astrojs/starlight/loaders";
import { docsSchema } from "@astrojs/starlight/schema";

// The pages are the Markdown files of `docs/` at the repository root: the Docker build (and
// `make docs`) put them at src/content/docs, where Starlight reads them.
export const collections = { docs: defineCollection({ loader: docsLoader(), schema: docsSchema() }) };
