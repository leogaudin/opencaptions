/**
 * Where a transcription runs and with which model: the provider (this server, OpenAI, another
 * OpenCaptions server) with its privacy notice, and for a local run the speech models to pick from.
 * The same choices when a video is added and when it is transcribed again. In hosted mode the operator
 * fixes the provider, so only the notice remains, if the audio leaves the machine.
 */
import { ModelList } from "@/components/ModelList";
import { useT } from "@/lib/i18n";
import type { TranscriptionChoice } from "@/lib/useTranscriptionChoice";
import type { TranscriptionProvider } from "@/types";

export function TranscriptionEngine({ choice }: { choice: TranscriptionChoice }) {
  const t = useT();
  const { provider, remoteHost } = choice;
  return (
    <>
      {/* In hosted mode the provider is fixed by the operator, so there is nothing to choose. The
          privacy disclosure is kept regardless: if the audio leaves the machine the user is told,
          whoever decided that. */}
      {choice.hostedMode ? (
        provider !== "local" && <PrivacyDisclosure provider={provider} host={remoteHost} />
      ) : (
        <div>
          <label className="mb-1 block text-sm font-medium" htmlFor="provider">
            {t("Transcription provider")}
          </label>
          <select
            id="provider"
            value={provider}
            onChange={(e) => choice.setProvider(e.target.value as TranscriptionProvider)}
            className="w-full rounded-md border border-border bg-card px-3 py-2 text-sm"
          >
            <option value="local">{t("Local (faster-whisper, no upload)")}</option>
            <option value="openai" disabled={!choice.openaiConfigured}>
              OpenAI Whisper API
              {!choice.openaiConfigured && `, ${t("set OPENAI_API_KEY first")}`}
            </option>
            <option value="opencaptions" disabled={!choice.remoteConfigured}>
              {choice.remoteConfigured
                ? t("Another OpenCaptions server ({host})", { host: remoteHost })
                : t("Another OpenCaptions server, set TRANSCRIPTION_REMOTE_URL first")}
            </option>
          </select>
          {provider !== "local" && <PrivacyDisclosure provider={provider} host={remoteHost} />}
          {choice.defaultProvider !== provider && (
            <p className="mt-1 text-xs text-muted-foreground">
              Server default: {choice.defaultProvider}
            </p>
          )}
        </div>
      )}

      {provider === "local" && choice.models.length > 0 && (
        <div>
          <div className="mb-2 text-sm font-medium">{t("Speech model")}</div>
          <ModelList
            models={choice.models}
            value={choice.model}
            onChange={choice.setModel}
            defaultModel={choice.defaultModel}
            testId="model-list"
          />
        </div>
      )}
    </>
  );
}

function PrivacyDisclosure({ provider, host }: { provider: TranscriptionProvider; host: string }) {
  const t = useT();
  if (provider === "opencaptions") {
    return (
      <div className="mt-2 rounded-md border border-amber-500/40 bg-amber-500/10 p-3 text-sm text-amber-300">
        <strong>{t("Privacy notice:")}</strong>{" "}
        {t(
          "your audio will be sent to {host}, which transcribes it and deletes the audio when it is done. This server keeps the result.",
          { host: host || t("the remote server") },
        )}
      </div>
    );
  }
  return (
    <div className="mt-2 rounded-md border border-amber-500/40 bg-amber-500/10 p-3 text-sm text-amber-300">
      <strong>{t("Privacy notice:")}</strong>{" "}
      {t("selecting the OpenAI provider will upload your audio to OpenAI's servers.")}{" "}
      <a
        href="https://openai.com/policies/api-data-usage-policies/"
        target="_blank"
        rel="noreferrer"
        className="underline"
      >
        {t("Their data usage policy applies.")}
      </a>{" "}
      {t("The local provider keeps everything on this machine.")}
    </div>
  );
}
