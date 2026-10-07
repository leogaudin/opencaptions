import { translate } from "@/lib/i18n";
import type { WhisperModelOption } from "@/types";

/**
 * The product picker is intentionally smaller than faster-whisper's complete
 * registry. Aliases, superseded v1/v2 models, English-only `.en` variants, and
 * distil-large-v3 are useful for experiments but add noise here. The latter also
 * mis-detected French as English in testing.
 */
const PRODUCT_MODEL_IDS = [
  "tiny",
  "base",
  "small",
  "medium",
  "large-v3",
  "large-v3-turbo",
] as const;

/**
 * Return the product ladder in product-owned order, injecting a custom server
 * default when an operator configured one outside the standard choices.
 */
export function productWhisperModelsWithDefault(
  models: WhisperModelOption[],
  defaultModel: string,
): WhisperModelOption[] {
  // An empty list is the server saying "no choice here" (hosted mode); a
  // synthetic default entry would turn that into a one-item picker.
  if (models.length === 0) return [];
  const byId = new Map(models.map((model) => [model.id, model]));
  const curated = PRODUCT_MODEL_IDS.flatMap((id) => {
    const model = byId.get(id);
    return model ? [model] : [];
  });
  if (!defaultModel || curated.some((model) => model.id === defaultModel)) return curated;
  return [
    {
      id: defaultModel,
      label: translate("{model} (configured)", { model: defaultModel }),
      note: translate("Custom server default; weights download on first use."),
    },
    ...curated,
  ];
}

interface LocalModelSelectProps {
  id: string;
  value: string;
  onChange: (model: string) => void;
  models: WhisperModelOption[];
  defaultModel: string;
  label?: string;
  hint?: string;
  compact?: boolean;
  testId?: string;
}

/** Shared model choice for initial transcription and later re-transcription. */
export function LocalModelSelect({
  id,
  value,
  onChange,
  models,
  defaultModel,
  label = translate("Local Whisper model"),
  hint = translate("Larger models use more memory. Weights download on first use."),
  compact = false,
  testId,
}: LocalModelSelectProps) {
  if (models.length === 0 || !value) return null;

  const selected = models.find((model) => model.id === value);

  return (
    <div>
      <label
        className={`${compact ? "mb-1 block text-xs" : "mb-1 block text-sm"} font-medium`}
        htmlFor={id}
      >
        {label}
      </label>
      <select
        id={id}
        data-testid={testId}
        value={value}
        onChange={(event) => onChange(event.target.value)}
        className={`${compact ? "px-2 py-1.5 text-xs" : "px-3 py-2 text-sm"} w-full rounded-md border border-border bg-card`}
      >
        {models.map((model) => (
          <option key={model.id} value={model.id}>
            {model.label}
            {model.id === defaultModel && !model.label.endsWith("(configured)") ? " (default)" : ""}
          </option>
        ))}
      </select>
      <p className={`${compact ? "mt-1 text-[11px]" : "mt-1 text-xs"} text-muted-foreground`}>
        {selected?.note || hint}
      </p>
    </div>
  );
}
