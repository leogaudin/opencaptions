import { Check } from "lucide-react";
import { useT } from "@/lib/i18n";
import type { WhisperModelOption } from "@/types";

/**
 * The speech models as a list to pick from, a row each with its note: what the iPhone app shows in
 * the first step of a transcription. The deployment's default is marked.
 */
export function ModelList({
  models,
  value,
  onChange,
  defaultModel,
  testId,
}: {
  models: WhisperModelOption[];
  value: string;
  onChange: (id: string) => void;
  defaultModel: string;
  testId?: string;
}) {
  const t = useT();
  if (models.length === 0) return null;
  return (
    <div
      role="radiogroup"
      aria-label={t("Speech model")}
      data-testid={testId}
      className="space-y-2"
    >
      {models.map((model) => {
        const selected = model.id === value;
        return (
          <label
            key={model.id}
            data-testid={`model-${model.id}`}
            className={`flex w-full cursor-pointer items-center gap-3 rounded-xl border px-4 py-3 text-left transition-colors has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-primary ${
              selected ? "border-primary bg-primary/10" : "border-border bg-card hover:bg-accent/50"
            }`}
          >
            <input
              type="radio"
              name="speech-model"
              value={model.id}
              checked={selected}
              onChange={() => onChange(model.id)}
              className="sr-only"
            />
            <span className="min-w-0 flex-1">
              <span className="flex items-center gap-2 text-sm font-semibold">
                {model.label}
                {model.id === defaultModel && (
                  <span className="rounded-full bg-muted px-2 py-0.5 text-[10px] font-semibold text-muted-foreground">
                    {t("Default")}
                  </span>
                )}
              </span>
              {model.note && (
                <span className="mt-0.5 block text-xs text-muted-foreground">{model.note}</span>
              )}
            </span>
            {selected && <Check className="h-4 w-4 shrink-0 text-primary" aria-hidden />}
          </label>
        );
      })}
    </div>
  );
}
