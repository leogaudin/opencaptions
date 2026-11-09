import { readFileSync } from "node:fs";

/** The package's version, from its manifest: one place to change it, which the release bumps. */
export const VERSION: string = JSON.parse(
  readFileSync(new URL("../package.json", import.meta.url), "utf8"),
).version;
