/**
 * The demo page's addresses: English at "/", each other language at "/<code>/" (a prerendered page
 * of its own, so a search in that language finds text in that language).
 */
import { isLanguage, LANGUAGES, type LanguageCode } from "@/lib/i18n";
import { SITE_URL } from "./links";

/** The hreflang value of each page (what search engines match to the searcher's language). */
export const HREFLANG: Record<LanguageCode, string> = {
  en: "en",
  fr: "fr",
  es: "es",
  de: "de",
  pl: "pl",
  pt: "pt",
  it: "it",
  ru: "ru",
  tr: "tr",
  ja: "ja",
  ko: "ko",
  zh: "zh-Hans",
  id: "id",
};

/** Open Graph's locale of each page (the Portuguese is the Brazilian one). */
export const OG_LOCALE: Record<LanguageCode, string> = {
  en: "en_US",
  fr: "fr_FR",
  es: "es_ES",
  de: "de_DE",
  pl: "pl_PL",
  pt: "pt_BR",
  it: "it_IT",
  ru: "ru_RU",
  tr: "tr_TR",
  ja: "ja_JP",
  ko: "ko_KR",
  zh: "zh_CN",
  id: "id_ID",
};

export const pagePath = (code: LanguageCode): string => (code === "en" ? "/" : `/${code}/`);

export const pageUrl = (code: LanguageCode): string =>
  `${SITE_URL.replace(/\/$/, "")}${pagePath(code)}`;

/** The language a path names ("/fr/" is French), or null for "/" and anything else. */
export function languageFromPath(pathname: string): LanguageCode | null {
  const first = pathname.split("/")[1];
  return first && first !== "en" && isLanguage(first) ? first : null;
}

/** Every language the page is in, English first. */
export const PAGE_LANGUAGES = LANGUAGES.map((l) => l.code);
