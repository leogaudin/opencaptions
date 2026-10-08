/**
 * The interface language: on the screens before sign-in, and in the Account page once signed in. Defaults to the browser's language; the choice is remembered in this browser.
 */
import { getLanguage, LANGUAGES, type LanguageCode, setLanguage, useT } from "@/lib/i18n";

export function LanguageSelect() {
  const t = useT();
  return (
    <select
      aria-label={t("Language")}
      data-testid="language-select"
      value={getLanguage()}
      onChange={(e) => setLanguage(e.target.value as LanguageCode)}
      className="rounded-md border border-border bg-card px-2 py-1 text-xs text-muted-foreground"
    >
      {LANGUAGES.map((l) => (
        <option key={l.code} value={l.code}>
          {l.name}
        </option>
      ))}
    </select>
  );
}
