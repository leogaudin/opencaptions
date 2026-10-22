/**
 * What a transcription is asked for, chosen the same way wherever one starts (a new project, a
 * re-transcription): where it runs, with which model, and the spoken language, which follows the model.
 * Provider and model start at the deployment's own and only a choice moves them.
 */
import { useState } from "react";
import { languagesForModel, startingLanguage } from "@/lib/transcriptionLanguages";
import { useTranscriptionSettings } from "@/lib/useTranscriptionSettings";
import type { TranscriptionProvider } from "@/types";

/** The host of a URL, or an empty string for none or a malformed one. */
function hostOf(url: string | null | undefined): string {
  if (!url) return "";
  try {
    return new URL(url).host;
  } catch {
    return "";
  }
}

/** The language last used, kept in this browser: someone who transcribes Spanish once probably will again. */
const LANGUAGE_KEY = "transcribeLanguage";

export function rememberedLanguage(): string | null {
  try {
    return localStorage.getItem(LANGUAGE_KEY);
  } catch {
    return null;
  }
}

export function rememberLanguage(language: string): void {
  try {
    localStorage.setItem(LANGUAGE_KEY, language);
  } catch {
    // The choice just is not remembered (a private window).
  }
}

export function useTranscriptionChoice(initialLanguage: string | null) {
  const { settings, languages: supported, models, defaultModel } = useTranscriptionSettings();
  const defaultProvider = (settings?.transcription.provider ?? "local") as TranscriptionProvider;
  // Null until the user picks, so the choice tracks the deployment default.
  const [providerChoice, setProvider] = useState<TranscriptionProvider | null>(null);
  const [modelChoice, setModel] = useState<string | null>(null);
  const [languageChoice, setLanguage] = useState<string | null>(initialLanguage);
  const provider = providerChoice ?? defaultProvider;
  const model = modelChoice ?? defaultModel;
  // The languages follow the model (a provider with no model of ours offers them all).
  const languages = provider === "local" ? languagesForModel(supported, models, model) : supported;
  const language = startingLanguage(languages, languageChoice, navigator.languages ?? []);
  return {
    provider,
    model,
    language,
    languages,
    models,
    defaultModel,
    defaultProvider,
    setProvider,
    setModel,
    setLanguage,
    hostedMode: settings?.hosted_mode ?? false,
    openaiConfigured: settings?.transcription.openai_configured ?? false,
    remoteConfigured: settings?.transcription.remote_configured ?? false,
    remoteHost: hostOf(settings?.transcription.remote_url),
    /** Whether the provider or the model differs from the deployment's, so it has to be sent. */
    changedProvider: provider !== defaultProvider,
    changedModel: provider === "local" && model !== defaultModel,
  };
}

export type TranscriptionChoice = ReturnType<typeof useTranscriptionChoice>;
