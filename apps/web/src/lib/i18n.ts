/**
 * The interface's languages. The English text in the code is the key: `t("Download")` is
 * "Download" in English and whatever `locales/<code>.json` says for it in another language, so the
 * code stays readable and a missing translation shows English instead of a blank. `{name}` in a
 * text is replaced from the values given: `t("Page {n}", { n: 2 })`.
 *
 * What the API says (error messages, job progress) is not translated here.
 */
import { useSyncExternalStore } from "react";
import de from "@/locales/de.json";
import es from "@/locales/es.json";
import fr from "@/locales/fr.json";
import id from "@/locales/id.json";
import it from "@/locales/it.json";
import ja from "@/locales/ja.json";
import ko from "@/locales/ko.json";
import pl from "@/locales/pl.json";
import pt from "@/locales/pt.json";
import ru from "@/locales/ru.json";
import tr from "@/locales/tr.json";
import zh from "@/locales/zh.json";

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

const DICTIONARIES: Record<Exclude<LanguageCode, "en">, Record<string, string>> = {
  fr,
  es,
  de,
  pl,
  pt,
  it,
  ru,
  tr,
  ja,
  ko,
  zh,
  id,
};

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

function announce(): void {
  document.documentElement.lang = current;
  for (const listener of listeners) listener();
}
announce();

export function getLanguage(): LanguageCode {
  return current;
}

export function setLanguage(code: LanguageCode): void {
  current = code;
  try {
    localStorage.setItem(STORAGE_KEY, code);
  } catch {
    // The choice just is not remembered.
  }
  announce();
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
  const table = current === "en" ? undefined : DICTIONARIES[current];
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
