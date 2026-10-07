/**
 * UploadPage: drop a video, pick provider, show a privacy disclosure when audio leaves the machine.
 *
 * Two-mode input: "Upload file" (local file via dropzone) or "From URL"
 * (direct link to a video file: page links like YouTube are NOT supported).
 *
 * After upload + transcription kickoff, navigate to the editor.
 */
import { type FormEvent, useCallback, useState } from "react";
import { useNavigate } from "react-router-dom";
import { LocalModelSelect } from "@/components/LocalModelSelect";
import { VideoDropzone } from "@/components/VideoDropzone";
import { useT } from "@/lib/i18n";
import { startProjectFromFile, startProjectFromUrl } from "@/lib/projectActions";
import { useTranscriptionSettings } from "@/lib/useTranscriptionSettings";
import { stripExt } from "@/lib/utils";
import type { TranscriptionProvider } from "@/types";

type Provider = TranscriptionProvider;
type InputMode = "file" | "url";

export function UploadPage() {
  const t = useT();
  const nav = useNavigate();
  const [mode, setMode] = useState<InputMode>("file");
  const [file, setFile] = useState<File | null>(null);
  const [videoUrl, setVideoUrl] = useState("");
  const [title, setTitle] = useState("");
  const [language, setLanguage] = useState("auto");
  const {
    settings,
    languages: supportedLanguages,
    models: availableModels,
    defaultModel,
  } = useTranscriptionSettings();
  const openaiConfigured = settings?.transcription.openai_configured ?? false;
  const remoteConfigured = settings?.transcription.remote_configured ?? false;
  const remoteHost = hostOf(settings?.transcription.remote_url);
  const hostedMode = settings?.hosted_mode ?? false;
  const defaultProvider = (settings?.transcription.provider ?? "local") as Provider;
  // Null until the user picks, so the choice tracks the deployment default.
  const [providerChoice, setProvider] = useState<Provider | null>(null);
  const [modelChoice, setModel] = useState<string | null>(null);
  const provider = providerChoice ?? defaultProvider;
  const model = modelChoice ?? defaultModel;
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const onPickFile = useCallback((f: File) => {
    setFile(f);
    // Default the title to the filename (without extension) only if empty.
    setTitle((prev) => prev || stripExt(f.name));
  }, []);

  /** Client-side URL validation: must be a valid http(s) URL. */
  function validateUrl(url: string): string | null {
    if (!url.trim()) return t("Please enter a video URL.");
    try {
      const parsed = new URL(url.trim());
      if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
        return t("Only http:// and https:// URLs are supported.");
      }
    } catch {
      return t("Invalid URL format. Please enter a valid http(s) link.");
    }
    return null;
  }

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);

    if (!title.trim()) {
      setError(t("Project title is required."));
      return;
    }

    if (mode === "file") {
      if (!file) {
        setError(t("Please choose a video file first."));
        return;
      }
    } else {
      const urlError = validateUrl(videoUrl);
      if (urlError) {
        setError(urlError);
        return;
      }
    }

    setSubmitting(true);
    try {
      const project =
        mode === "file"
          ? await startProjectFromFile(file!, {
              title: title.trim(),
              provider,
              language,
              model: provider === "local" ? model || undefined : undefined,
            })
          : await startProjectFromUrl(videoUrl.trim(), {
              title: title.trim(),
              provider,
              language,
              model: provider === "local" ? model || undefined : undefined,
            });
      nav(`/projects/${project.id}`);
    } catch (e) {
      setError((e as Error).message);
      setSubmitting(false);
    }
  }

  return (
    <div className="container mx-auto max-w-2xl px-4 py-10">
      <h1 className="mb-6 text-2xl font-semibold">{t("New project")}</h1>
      <form onSubmit={handleSubmit} className="space-y-6">
        {/* Mode toggle: Upload file / From URL */}
        <div className="inline-flex w-full overflow-hidden rounded-md border border-border bg-background p-0.5">
          <button
            type="button"
            onClick={() => setMode("file")}
            data-testid="mode-file"
            className={`flex-1 rounded px-3 py-1.5 text-sm font-medium transition-colors ${
              mode === "file"
                ? "bg-primary text-primary-foreground"
                : "text-muted-foreground hover:bg-accent/50"
            }`}
          >
            {t("Upload file")}
          </button>
          <button
            type="button"
            onClick={() => setMode("url")}
            data-testid="mode-url"
            className={`flex-1 rounded px-3 py-1.5 text-sm font-medium transition-colors ${
              mode === "url"
                ? "bg-primary text-primary-foreground"
                : "text-muted-foreground hover:bg-accent/50"
            }`}
          >
            {t("From URL")}
          </button>
        </div>

        {/* File drop zone (shown in file mode), shared with the home empty state */}
        {mode === "file" && (
          <VideoDropzone
            onFile={onPickFile}
            onReject={setError}
            selectedFile={file}
            disabled={submitting}
            testId="dropzone"
            inputTestId="file-input"
            className="h-48"
          />
        )}

        {/* URL input (shown in url mode) */}
        {mode === "url" && (
          <div>
            <label className="mb-1 block text-sm font-medium" htmlFor="video-url">
              {t("Video URL")}
            </label>
            <input
              id="video-url"
              data-testid="video-url"
              type="url"
              value={videoUrl}
              onChange={(e) => setVideoUrl(e.target.value)}
              placeholder="https://example.com/video.mp4"
              className="w-full rounded-md border border-border bg-card px-3 py-2 text-sm"
            />
            <p className="mt-1 text-[11px] text-muted-foreground">
              {t(
                "Direct link to a video file only. Page links (YouTube, Vimeo, etc.) are not supported.",
              )}
            </p>
          </div>
        )}

        <div>
          <label className="mb-1 block text-sm font-medium" htmlFor="title">
            {t("Project title")}
          </label>
          <input
            id="title"
            data-testid="title"
            type="text"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            placeholder={t("Untitled")}
            className="w-full rounded-md border border-border bg-card px-3 py-2 text-sm"
          />
        </div>

        {/* In hosted mode the provider is fixed by the operator, so there is
            nothing to choose. The privacy disclosure is kept regardless: if the
            audio leaves the machine the user is told, whoever decided that. */}
        {hostedMode ? (
          provider !== "local" && <PrivacyDisclosure provider={provider} host={remoteHost} />
        ) : (
          <div>
            <label className="mb-1 block text-sm font-medium" htmlFor="provider">
              {t("Transcription provider")}
            </label>
            <select
              id="provider"
              value={provider}
              onChange={(e) => setProvider(e.target.value as Provider)}
              className="w-full rounded-md border border-border bg-card px-3 py-2 text-sm"
            >
              <option value="local">{t("Local (faster-whisper, no upload)")}</option>
              <option value="openai" disabled={!openaiConfigured}>
                OpenAI Whisper API{!openaiConfigured && `, ${t("set OPENAI_API_KEY first")}`}
              </option>
              <option value="opencaptions" disabled={!remoteConfigured}>
                {remoteConfigured
                  ? t("Another OpenCaptions server ({host})", { host: remoteHost })
                  : t("Another OpenCaptions server, set TRANSCRIPTION_REMOTE_URL first")}
              </option>
            </select>
            {provider !== "local" && <PrivacyDisclosure provider={provider} host={remoteHost} />}
            {defaultProvider !== provider && (
              <p className="mt-1 text-xs text-muted-foreground">
                Server default: {defaultProvider}
              </p>
            )}
          </div>
        )}

        {provider === "local" && (
          <LocalModelSelect
            id="whisper-model"
            testId="model-select"
            value={model}
            onChange={setModel}
            models={availableModels}
            defaultModel={defaultModel}
          />
        )}

        <div>
          <label className="mb-1 block text-sm font-medium" htmlFor="language">
            {t("Language")}
          </label>
          <select
            id="language"
            data-testid="language-select"
            value={language}
            onChange={(e) => setLanguage(e.target.value)}
            className="w-full rounded-md border border-border bg-card px-3 py-2 text-sm"
            aria-label={t("Transcription language")}
          >
            <option value="auto">{t("Auto-detect")}</option>
            {supportedLanguages.map((lang) => (
              <option key={lang.code} value={lang.code}>
                {lang.label}
              </option>
            ))}
          </select>
          <p className="mt-1 text-[11px] text-muted-foreground">
            {t("Select a language to improve transcription accuracy, or leave on auto-detect.")}
          </p>
        </div>

        {error && (
          <div className="rounded-md border border-destructive/40 bg-destructive/10 p-3 text-sm text-destructive">
            {error}
          </div>
        )}

        <div className="flex items-center justify-end gap-2">
          <button
            type="button"
            onClick={() => nav(-1)}
            className="rounded-md border border-border px-4 py-2 text-sm hover:bg-accent"
          >
            {t("Cancel")}
          </button>
          <button
            type="submit"
            disabled={submitting || (mode === "file" ? !file : !videoUrl.trim())}
            className="rounded-md bg-primary text-primary-foreground px-4 py-2 text-sm font-medium hover:opacity-90 disabled:opacity-50"
            data-testid="submit"
          >
            {submitting ? t("Creating…") : t("Create project")}
          </button>
        </div>
      </form>
    </div>
  );
}

/** The host of a URL, or an empty string for none or a malformed one. */
function hostOf(url: string | null | undefined): string {
  if (!url) return "";
  try {
    return new URL(url).host;
  } catch {
    return "";
  }
}

function PrivacyDisclosure({ provider, host }: { provider: Provider; host: string }) {
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
