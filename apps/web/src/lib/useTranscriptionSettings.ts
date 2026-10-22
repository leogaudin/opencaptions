import { useEffect, useMemo, useState } from "react";
import * as api from "@/lib/api";
import { translate } from "@/lib/i18n";
import type { AppSettingsResponse, WhisperModelOption } from "@/types";

/**
 * The list is the server's, which offers what the iPhone app does. A custom server default
 * (`DEFAULT_MODEL`) outside it is added in front, so the choice shown is the one in force.
 */
export function productWhisperModelsWithDefault(
  models: WhisperModelOption[],
  defaultModel: string,
): WhisperModelOption[] {
  // An empty list is the server saying "no choice here" (hosted mode); a
  // synthetic default entry would turn that into a one-item picker.
  if (models.length === 0) return [];
  if (!defaultModel || models.some((model) => model.id === defaultModel)) return models;
  return [
    {
      id: defaultModel,
      label: translate("{model} (configured)", { model: defaultModel }),
      note: translate("Custom server default; weights download on first use."),
    },
    ...models,
  ];
}

/**
 * Settings as the transcription UI needs them. Everything is empty until the
 * request returns, and stays empty if it fails: the UI then offers only
 * the deployment default, which is a working choice.
 */
export function useTranscriptionSettings() {
  const [settings, setSettings] = useState<AppSettingsResponse | null>(null);

  useEffect(() => {
    let cancelled = false;
    api
      .getSettings()
      .then((s) => !cancelled && setSettings(s))
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, []);

  return useMemo(() => {
    const t = settings?.transcription;
    // Null in hosted mode: the model is fixed server-side and never shown.
    const defaultModel = t?.model ?? "";
    return {
      settings,
      languages: t?.supported_languages ?? [],
      models: productWhisperModelsWithDefault(t?.available_models ?? [], defaultModel),
      defaultModel,
    };
  }, [settings]);
}
