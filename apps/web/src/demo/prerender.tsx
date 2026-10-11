/**
 * The build's way into the page's HTML (see `scripts/demo-prerender.ts`). Not loaded in the browser.
 */
import { renderToString } from "react-dom/server";
import { isLanguage, type LanguageCode, setLanguage } from "@/lib/i18n";
import { DemoSkeleton, Page } from "./Landing";
import { PAGE_LANGUAGES } from "./pages";
import { headTags } from "./seo";

/** Every language the page is in. */
export const languages: readonly string[] = PAGE_LANGUAGES;

/** A language's head tags and body as they are before any script has run (the demo's place held). */
export async function renderLanguage(code: string): Promise<{ head: string; body: string }> {
  const language: LanguageCode = isLanguage(code) ? code : "en";
  await setLanguage(language, false);
  return { head: headTags(language), body: renderToString(<Page demo={<DemoSkeleton />} />) };
}
