import { Monitor, Moon, Sun } from "lucide-react";
import { useT } from "@/lib/i18n";
import { type ThemeChoice, useTheme } from "@/lib/useTheme";
import { cn } from "@/lib/utils";

/** System, light or dark: the appearance of the interface, remembered in this browser. */
export function ThemeSelect() {
  const t = useT();
  const { choice, setChoice } = useTheme();
  const options: { value: ThemeChoice; label: string; icon: typeof Sun }[] = [
    { value: "system", label: t("System"), icon: Monitor },
    { value: "light", label: t("Light"), icon: Sun },
    { value: "dark", label: t("Dark"), icon: Moon },
  ];
  return (
    <div
      role="radiogroup"
      aria-label={t("Appearance")}
      data-testid="theme-select"
      className="inline-flex rounded-xl bg-muted p-1"
    >
      {options.map(({ value, label, icon: Icon }) => (
        // biome-ignore lint/a11y/useSemanticElements: a segmented control, not a form radio
        <button
          key={value}
          type="button"
          role="radio"
          aria-checked={choice === value}
          onClick={() => setChoice(value)}
          className={cn(
            "inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm font-medium transition-colors",
            choice === value
              ? "bg-background text-foreground shadow-sm"
              : "text-muted-foreground hover:text-foreground",
          )}
        >
          <Icon className="h-4 w-4" aria-hidden />
          {label}
        </button>
      ))}
    </div>
  );
}
