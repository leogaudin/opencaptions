/**
 * UploadPage: drop a video, pick provider, show a privacy disclosure when audio leaves the machine.
 *
 * Two steps, as on the iPhone. First the video, its title, where to transcribe and with which
 * model; then the spoken language, from the languages that model knows (there is no "detect it":
 * a language is always chosen).
 *
 * Two-mode input: "Upload file" (local file via dropzone) or "From URL"
 * (direct link to a video file: page links like YouTube are NOT supported).
 *
 * After upload + transcription kickoff, navigate to the editor.
 */
import { type FormEvent, useCallback, useEffect, useRef, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { LanguageList } from "@/components/LanguageList";
import { TranscriptionEngine } from "@/components/TranscriptionEngine";
import { VideoDropzone } from "@/components/VideoDropzone";
import { useT } from "@/lib/i18n";
import { startProjectFromFile, startProjectFromUrl } from "@/lib/projectActions";
import {
  rememberedLanguage,
  rememberLanguage,
  useTranscriptionChoice,
} from "@/lib/useTranscriptionChoice";
import { stripExt } from "@/lib/utils";

type InputMode = "file" | "url";

export function UploadPage() {
  const t = useT();
  const nav = useNavigate();
  const [mode, setMode] = useState<InputMode>("file");
  const [file, setFile] = useState<File | null>(null);
  const [videoUrl, setVideoUrl] = useState("");
  const [title, setTitle] = useState("");
  const [step, setStep] = useState<1 | 2>(1);
  const choice = useTranscriptionChoice(rememberedLanguage());
  const { provider, model, language } = choice;
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  /** Bytes sent of the file, 0 to 1; null before the first report. */
  const [uploaded, setUploaded] = useState<number | null>(null);
  /** A project that was created though its transcription did not start. */
  const [orphan, setOrphan] = useState<string | null>(null);
  const upload = useRef<AbortController | null>(null);

  // Leaving the page cancels an upload in flight rather than finishing it unseen.
  useEffect(() => () => upload.current?.abort(), []);

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

  /** The first step is complete: a title and a video (or a usable link). */
  function validateFirstStep(): string | null {
    if (!title.trim()) return t("Project title is required.");
    if (mode === "file") return file ? null : t("Please choose a video file first.");
    return validateUrl(videoUrl);
  }

  function goNext(): void {
    const problem = validateFirstStep();
    setError(problem);
    if (!problem) setStep(2);
  }

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    if (step === 1) {
      goNext();
      return;
    }
    setError(null);

    setSubmitting(true);
    setUploaded(null);
    const controller = new AbortController();
    upload.current = controller;
    try {
      const options = {
        title: title.trim(),
        provider,
        language,
        model: provider === "local" ? model || undefined : undefined,
      };
      const { project, transcriptionError } =
        mode === "file"
          ? await startProjectFromFile(file!, options, {
              signal: controller.signal,
              onProgress: (sent, total) => setUploaded(total ? sent / total : null),
            })
          : await startProjectFromUrl(videoUrl.trim(), options);
      if (transcriptionError) {
        // The video is saved; sending the form again would make a second copy.
        setOrphan(project.id);
        setError(
          t("The project was created, but transcription did not start: {error}", {
            error: transcriptionError,
          }),
        );
        setSubmitting(false);
        return;
      }
      rememberLanguage(language);
      nav(`/projects/${project.id}`);
    } catch (e) {
      if ((e as Error).name !== "AbortError") setError((e as Error).message);
      setSubmitting(false);
    }
  }

  return (
    <div className="container mx-auto max-w-2xl px-4 py-10">
      <h1 className="mb-6 text-2xl font-semibold">
        {step === 1 ? t("New project") : t("Spoken language")}
      </h1>
      <form onSubmit={handleSubmit} className="space-y-6">
        {step === 1 && (
          <>
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

            <TranscriptionEngine choice={choice} />
          </>
        )}

        {step === 2 && (
          <LanguageList
            languages={choice.languages}
            value={language}
            onChange={choice.setLanguage}
            testId="language-list"
          />
        )}

        {error && (
          <div className="rounded-md border border-destructive/40 bg-destructive/10 p-3 text-sm text-destructive">
            {error}
            {orphan && (
              <Link to={`/projects/${orphan}`} className="ml-2 font-semibold underline">
                {t("Open project")}
              </Link>
            )}
          </div>
        )}

        {submitting && uploaded !== null && uploaded < 1 && (
          <div
            role="progressbar"
            aria-valuemin={0}
            aria-valuemax={100}
            aria-valuenow={Math.round(uploaded * 100)}
            className="h-1.5 overflow-hidden rounded-full bg-muted"
          >
            <div
              className="h-full bg-primary transition-[width] duration-200"
              style={{ width: `${Math.round(uploaded * 100)}%` }}
            />
          </div>
        )}

        <div className="flex items-center justify-end gap-2">
          {step === 1 ? (
            <>
              {/* Keyed so Next and Create project are two elements: one button changing its type
                  during its own click would submit the form. */}
              <button
                key="cancel"
                type="button"
                onClick={() => nav(-1)}
                className="rounded-md border border-border px-4 py-2 text-sm hover:bg-accent"
              >
                {t("Cancel")}
              </button>
              <button
                key="next"
                type="button"
                onClick={goNext}
                disabled={!!orphan || (mode === "file" ? !file : !videoUrl.trim())}
                data-testid="next"
                className="rounded-md bg-primary text-primary-foreground px-4 py-2 text-sm font-medium hover:opacity-90 disabled:opacity-50"
              >
                {t("Next")}
              </button>
            </>
          ) : (
            <>
              <button
                key="back"
                type="button"
                onClick={() => (submitting ? upload.current?.abort() : setStep(1))}
                data-testid="back"
                className="rounded-md border border-border px-4 py-2 text-sm hover:bg-accent"
              >
                {submitting && mode === "file" ? t("Cancel upload") : t("Back")}
              </button>
              <button
                key="submit"
                type="submit"
                disabled={submitting || !!orphan}
                className="rounded-md bg-primary text-primary-foreground px-4 py-2 text-sm font-medium hover:opacity-90 disabled:opacity-50"
                data-testid="submit"
              >
                {submitting
                  ? uploaded !== null && uploaded < 1
                    ? t("Uploading… {percent}%", { percent: Math.round(uploaded * 100) })
                    : t("Creating…")
                  : t("Create project")}
              </button>
            </>
          )}
        </div>
      </form>
    </div>
  );
}
