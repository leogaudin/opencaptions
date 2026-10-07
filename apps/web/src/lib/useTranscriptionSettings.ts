import { useEffect, useMemo, useState } from "react";
import { productWhisperModelsWithDefault } from "@/components/LocalModelSelect";
import * as api from "@/lib/api";
import type { AppSettingsResponse } from "@/types";

/**
 * Settings as the transcription UI needs them. Everything is empty until the
 * request returns, and stays empty if it fails: the UI then offers only
 * auto-detect and the deployment default, which is a working choice.
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
