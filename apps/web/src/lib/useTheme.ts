/**
 * Theme: 'system', 'light' or 'dark'. Until a choice is made the page follows the system, and
 * keeps following it when it changes; a choice is remembered in localStorage.
 *
 * The initial theme is applied synchronously by an inline script in
 * apps/web/index.html so there is no flash of the wrong palette on load.
 * This hook keeps the in-document state in sync.
 */
import { useCallback, useEffect, useState, useSyncExternalStore } from "react";

export type Theme = "light" | "dark";
export type ThemeChoice = Theme | "system";

const STORAGE_KEY = "opencaptions:theme";
const DARK = "(prefers-color-scheme: dark)";

function readChoice(): ThemeChoice {
  try {
    const v = window.localStorage.getItem(STORAGE_KEY);
    if (v === "dark" || v === "light") return v;
  } catch {
    /* storage blocked: follow the system */
  }
  return "system";
}

function subscribeSystem(listener: () => void): () => void {
  const query = window.matchMedia(DARK);
  query.addEventListener("change", listener);
  return () => query.removeEventListener("change", listener);
}

export function useTheme(): {
  /** What was chosen: 'system' until the user picks. */
  choice: ThemeChoice;
  /** What is shown. */
  theme: Theme;
  setChoice: (c: ThemeChoice) => void;
  /** To the other of light and dark, as a choice. */
  toggle: () => void;
} {
  const [choice, setChoiceState] = useState<ThemeChoice>(readChoice);
  const systemDark = useSyncExternalStore(
    subscribeSystem,
    () => window.matchMedia(DARK).matches,
    () => false,
  );
  const theme: Theme = choice === "system" ? (systemDark ? "dark" : "light") : choice;

  useEffect(() => {
    document.documentElement.classList.toggle("dark", theme === "dark");
  }, [theme]);

  const setChoice = useCallback((c: ThemeChoice) => {
    setChoiceState(c);
    try {
      if (c === "system") window.localStorage.removeItem(STORAGE_KEY);
      else window.localStorage.setItem(STORAGE_KEY, c);
    } catch {
      /* the choice just is not remembered */
    }
  }, []);
  const toggle = useCallback(
    () => setChoice(theme === "dark" ? "light" : "dark"),
    [setChoice, theme],
  );

  return { choice, theme, setChoice, toggle };
}
