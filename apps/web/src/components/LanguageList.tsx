import { Check, Search } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { useT } from "@/lib/i18n";
import { languageFlag } from "@/lib/transcriptionLanguages";
import type { SupportedLanguage } from "@/types";

/**
 * The spoken language, from a searchable list with a flag for each: the second step of a
 * transcription, as on the iPhone. The list is the chosen model's, and one is always chosen.
 */
export function LanguageList({
  languages,
  value,
  onChange,
  testId,
}: {
  languages: SupportedLanguage[];
  value: string;
  onChange: (code: string) => void;
  testId?: string;
}) {
  const t = useT();
  const [query, setQuery] = useState("");
  const list = useRef<HTMLDivElement>(null);
  // The list opens with the chosen language in view, not at the top of a hundred.
  useEffect(() => {
    const box = list.current;
    const row = box?.querySelector<HTMLElement>("label:has(input:checked)");
    if (box && row) box.scrollTop = row.offsetTop - box.clientHeight / 2 + row.clientHeight / 2;
  }, []);
  const needle = query.trim().toLowerCase();
  const shown = needle
    ? languages.filter((l) => l.label.toLowerCase().includes(needle) || l.code === needle)
    : languages;
  return (
    <div className="space-y-3">
      <div className="flex items-center gap-2 rounded-xl border border-border bg-card px-3 py-2.5">
        <Search className="h-4 w-4 shrink-0 text-muted-foreground" aria-hidden />
        <input
          type="search"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder={t("Search languages")}
          aria-label={t("Search languages")}
          data-testid="language-search"
          className="w-full bg-transparent text-sm outline-none"
        />
      </div>
      <div
        ref={list}
        role="radiogroup"
        aria-label={t("Transcription language")}
        data-testid={testId}
        className="relative max-h-[48vh] divide-y divide-border overflow-y-auto rounded-xl border border-border bg-card"
      >
        {shown.length === 0 && (
          <p className="px-4 py-3 text-sm text-muted-foreground">{t("No language matches.")}</p>
        )}
        {shown.map((language) => {
          const selected = language.code === value;
          return (
            <label
              key={language.code}
              data-testid={`language-${language.code}`}
              className={`flex w-full cursor-pointer items-center gap-3 px-4 py-2.5 text-left text-sm font-semibold transition-colors has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-inset has-[:focus-visible]:ring-primary ${
                selected ? "bg-primary/10" : "hover:bg-accent/50"
              }`}
            >
              <input
                type="radio"
                name="spoken-language"
                value={language.code}
                checked={selected}
                onChange={() => onChange(language.code)}
                className="sr-only"
              />
              <span className="w-7 text-xl leading-none" aria-hidden>
                {languageFlag(language.code)}
              </span>
              <span className="flex-1">{language.label}</span>
              {selected && <Check className="h-4 w-4 text-primary" aria-hidden />}
            </label>
          );
        })}
      </div>
    </div>
  );
}
