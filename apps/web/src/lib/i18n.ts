/**
 * The interface's languages. The English text in the code is the key: `t("Download")` is
 * "Download" in English and whatever `locales/<code>.json` says for it in another language, so the
 * code stays readable and a missing translation shows English instead of a blank. `{name}` in a
 * text is replaced from the values given: `t("Page {n}", { n: 2 })`.
 *
 * What the API says (error messages, job progress) is not translated here.
 */
import { useSyncExternalStore } from "react";

export const LANGUAGES = [
  { code: "en", name: "English" },
  { code: "fr", name: "Français" },
  { code: "es", name: "Español" },
  { code: "de", name: "Deutsch" },
  { code: "pl", name: "Polski" },
  { code: "pt", name: "Português" },
  { code: "it", name: "Italiano" },
  { code: "ru", name: "Русский" },
  { code: "tr", name: "Türkçe" },
  { code: "ja", name: "日本語" },
  { code: "ko", name: "한국어" },
  { code: "zh", name: "简体中文" },
  { code: "id", name: "Bahasa Indonesia" },
] as const;

export type LanguageCode = (typeof LANGUAGES)[number]["code"];

type Dictionary = Record<string, string>;

/**
 * The translations are loaded when a language is in use, not shipped all together: the
 * twelve files were 180 KB of the first download, and a visitor reads one.
 */
const LOADERS: Record<Exclude<LanguageCode, "en">, () => Promise<{ default: Dictionary }>> = {
  fr: () => import("@/locales/fr.json"),
  es: () => import("@/locales/es.json"),
  de: () => import("@/locales/de.json"),
  pl: () => import("@/locales/pl.json"),
  pt: () => import("@/locales/pt.json"),
  it: () => import("@/locales/it.json"),
  ru: () => import("@/locales/ru.json"),
  tr: () => import("@/locales/tr.json"),
  ja: () => import("@/locales/ja.json"),
  ko: () => import("@/locales/ko.json"),
  zh: () => import("@/locales/zh.json"),
  id: () => import("@/locales/id.json"),
};

const loaded = new Map<LanguageCode, Dictionary>();

/** Fetch a language's translations (English is the code itself and needs none). */
export async function loadLanguage(code: LanguageCode): Promise<void> {
  if (code === "en" || loaded.has(code)) return;
  try {
    loaded.set(code, (await LOADERS[code]()).default);
  } catch {
    // Offline or a stale deploy: the interface stays in English rather than failing to start.
  }
}

const STORAGE_KEY = "language";

function isLanguage(code: string | null | undefined): code is LanguageCode {
  return LANGUAGES.some((l) => l.code === code);
}

/** The saved choice, else the browser's first language that is offered, else English. */
function initialLanguage(): LanguageCode {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (isLanguage(saved)) return saved;
  } catch {
    // Storage unavailable: the browser's language is used.
  }
  for (const tag of navigator.languages ?? [navigator.language]) {
    const code = tag.toLowerCase().split("-")[0];
    if (isLanguage(code)) return code;
  }
  return "en";
}

let current: LanguageCode = initialLanguage();
const listeners = new Set<() => void>();

/** The language the page starts in: await this before the first render, so it does not flash English. */
export const languageReady: Promise<void> = loadLanguage(current);

function announce(): void {
  document.documentElement.lang = current;
  for (const listener of listeners) listener();
}
announce();

export function getLanguage(): LanguageCode {
  return current;
}

export function setLanguage(code: LanguageCode): void {
  try {
    localStorage.setItem(STORAGE_KEY, code);
  } catch {
    // The choice just is not remembered.
  }
  // Switch once its translations have arrived, so the text changes in one step.
  void loadLanguage(code).then(() => {
    current = code;
    announce();
  });
}

/**
 * Marks a text to be translated later, where it is shown with `t(variable)`: the marked text is
 * found by the check that every text has its translations, which a variable could not be.
 */
export function msg(text: string): string {
  return text;
}

export type Values = Record<string, string | number>;

/** `text` in the current language, with `{name}` replaced from `values`. */
export function translate(text: string, values?: Values): string {
  const table = loaded.get(current);
  const out = table?.[text] ?? text;
  if (!values) return out;
  return out.replace(/\{(\w+)\}/g, (whole, name: string) =>
    name in values ? String(values[name]) : whole,
  );
}

/** `translate`, and the component re-renders when the language is changed. */
export function useT(): typeof translate {
  useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => current,
  );
  return translate;
}
