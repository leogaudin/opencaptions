/** Where captioning without a server keeps what it downloads: the speech model and fonts. */
import { homedir } from "node:os";
import { join } from "node:path";

export function cacheDir(): string {
  const base =
    process.env.OPENCAPTIONS_CACHE ||
    (process.env.XDG_CACHE_HOME ? join(process.env.XDG_CACHE_HOME, "opencaptions") : "");
  return base || join(homedir(), ".cache", "opencaptions");
}
