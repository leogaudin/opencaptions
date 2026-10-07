/**
 * EditorToolbar: horizontal bar above the editor panes with all meta actions.
 *
 * Left section: transcription progress / Cancel (real-time feedback).
 * Right section: the transcript's language, the autosave status, Re-transcribe,
 * Download video (one button, opening DownloadDialog), Download subtitles.
 *
 * Video download logic (multi-format, content-addressed cache):
 *   - The dialog holds the format, then the size and frame rate (remembered per
 *     browser, lib/downloadOptions); its Download button starts the download.
 *   - If the format is ready on the server, download triggers immediately.
 *   - If not, the server returns a job_id and lib/downloads saves the file
 *     when that render finishes, whichever page the user is on by then.
 *
 * Every video download shares one code path: requestVideoDownload(format) in
 * the store. That function always POSTs /projects/{id}/download first — no
 * code path may navigate the browser to the GET streaming endpoint unless the
 * POST confirmed ready=true.
 */
import * as DropdownMenu from "@radix-ui/react-dropdown-menu";
import { Download, FileText, Loader2 } from "lucide-react";
import { useEffect, useState } from "react";
import { AutosaveIndicator } from "@/components/AutosaveIndicator";
import { DownloadDialog } from "@/components/DownloadDialog";
import { RetranscribeDialog } from "@/components/RetranscribeDialog";
import * as api from "@/lib/api";
import { usePendingDownload } from "@/lib/downloads";
import { useEditorStore } from "@/store/editorStore";

/**
 * Shared class string for non-accent icon-only toolbar buttons.
 * Matches the header's Info and theme-toggle styling: transparent background,
 * border outline, high-contrast foreground, accent on hover.
 * All four non-accent icon buttons use this so they cannot drift apart.
 */
const ICON_BUTTON_CLASSES =
  "inline-flex h-8 w-8 items-center justify-center rounded-full bg-muted text-foreground transition-colors hover:bg-muted/70 disabled:opacity-50";

export function EditorToolbar() {
  const project = useEditorStore((s) => s.project);
  const transcript = useEditorStore((s) => s.transcript);
  const requestVideoDownload = useEditorStore((s) => s.requestVideoDownload);
  const activeJobId = useEditorStore((s) => s.activeJobId);
  const downloadFormat = usePendingDownload(project?.id);
  const jobs = useEditorStore((s) => s.jobs);
  const saving = useEditorStore((s) => s.autosaveStatus === "saving");
  const cancelActiveJob = useEditorStore((s) => s.cancelActiveJob);

  const [exports, setExports] = useState<api.ExportLinks | null>(null);
  const [downloading, setDownloading] = useState(false);

  // Store objects (project) get new identities on every Zustand write; key on
  // the primitive fields that actually determine when exports should be refetched.
  const projectId = project?.id;
  const projectStatus = project?.status;
  const projectUpdatedAt = project?.updated_at;

  // biome-ignore lint/correctness/useExhaustiveDependencies: projectStatus and projectUpdatedAt are intentional refetch triggers — exports change when status or updated_at change
  useEffect(() => {
    if (!projectId) return;
    let cancelled = false;
    api
      .getExportLinks(projectId)
      .then((res) => {
        if (!cancelled) setExports(res);
      })
      .catch(() => {
        // Non-fatal — export links may not be ready yet.
      });
    return () => {
      cancelled = true;
    };
  }, [projectId, projectStatus, projectUpdatedAt]);

  if (!project) return null;

  const activeJob = jobs.find((j) => j.id === activeJobId);
  const preparingDownload = activeJob?.type === "rendering" ? activeJob : null;
  const transcriptionJob = activeJob?.type === "transcription" ? activeJob : null;
  const preparingNow = !!preparingDownload;
  const transcribing = !!transcriptionJob || (project.status === "transcribing" && !activeJob);
  const preparePct = preparingDownload ? Math.round((preparingDownload.progress ?? 0) * 100) : 0;
  const transcriptionPct = transcriptionJob
    ? Math.round((transcriptionJob.progress ?? 0) * 100)
    : 0;
  const transcriptionMessage = transcriptionJob?.message ?? "Transcribing…";

  /** Format label for the in-progress download indicator. */
  const preparingFormatLabel = downloadFormat?.toUpperCase() ?? "video";

  async function handleFormatDownload(format: string): Promise<void> {
    if (!project) return;
    await requestVideoDownload(format);
  }

  return (
    <div className="flex flex-wrap items-center gap-2 bg-background px-4 py-2">
      {/* ----- Left: transcription progress (real-time feedback) ----- */}
      <div className="flex items-center gap-3">
        {transcribing && (
          <div className="flex items-center gap-2">
            <div className="flex items-center gap-1.5">
              <div className="h-1.5 w-24 overflow-hidden rounded-full bg-muted">
                <div
                  className="h-full bg-primary transition-[width] duration-300"
                  style={{ width: `${transcriptionPct}%` }}
                  data-testid="progress-bar"
                />
              </div>
              <span className="text-[11px] text-muted-foreground">
                {transcriptionPct > 0 ? `${transcriptionPct}%` : ""} {transcriptionMessage}
              </span>
            </div>
            <button
              type="button"
              onClick={cancelActiveJob}
              disabled={!activeJobId}
              data-testid="cancel-job"
              className="rounded-md border border-destructive/40 px-2 py-0.5 text-[11px] text-destructive hover:bg-destructive/10 disabled:opacity-50"
            >
              Cancel
            </button>
          </div>
        )}
        {/* Download preparation progress (shown inline when a format is being prepared) */}
        {preparingNow && (
          <div className="flex items-center gap-1.5">
            <Loader2 className="h-3.5 w-3.5 animate-spin text-primary-ink" aria-hidden />
            <span className="text-[11px] text-muted-foreground">
              Preparing {preparingFormatLabel}
              {preparePct > 0 ? ` ${preparePct}%` : "…"}
            </span>
          </div>
        )}
      </div>

      {/* ----- Right: action buttons (right-aligned) -----
       * All toolbar buttons are intentionally icon-only with aria-label + title
       * for accessibility. Hovering reveals the action name via native tooltip.
       * Download video uses filled/accented styling (primary bg) to convey visual
       * hierarchy; secondary buttons use ICON_BUTTON_CLASSES (transparent bg,
       * border, high-contrast foreground, accent on hover) matching the header's
       * Info and theme-toggle buttons.
       */}
      <div className="ml-auto flex flex-wrap items-center gap-2">
        {transcript && (
          <>
            <span
              data-testid="transcript-language"
              className="hidden text-[11px] text-muted-foreground sm:inline"
            >
              <span className="uppercase">{transcript.language}</span>
              {transcript.language_detection === "auto" ? " (auto-detected)" : ""}
            </span>
            <AutosaveIndicator />
            <RetranscribeDialog current={transcript.language} />
          </>
        )}
        {/* Download video: one button, which opens the dialog where format, size and
            frame rate are chosen (the iOS Save sheet's counterpart). */}
        <button
          type="button"
          onClick={() => setDownloading(true)}
          disabled={preparingNow || saving || !transcript}
          data-testid="download-open"
          title="Download video"
          aria-label="Download video"
          className="inline-flex h-7 items-center justify-center gap-1.5 rounded-full bg-primary px-3 text-xs font-semibold text-primary-foreground hover:opacity-90 disabled:opacity-50"
        >
          {preparingNow ? (
            <Loader2 className="h-3.5 w-3.5 animate-spin" aria-hidden />
          ) : (
            <Download className="h-3.5 w-3.5" aria-hidden />
          )}
          Download
        </button>
        <DownloadDialog
          open={downloading}
          onOpenChange={setDownloading}
          exports={exports}
          onDownload={handleFormatDownload}
        />

        {/* Download subtitles dropdown (transparent bg, outline, matches header buttons) */}
        <DropdownMenu.Root>
          <DropdownMenu.Trigger asChild>
            <button
              type="button"
              disabled={!exports?.subtitles}
              aria-label="Download subtitles"
              title="Download subtitles"
              className={ICON_BUTTON_CLASSES}
            >
              <FileText className="h-3.5 w-3.5" aria-hidden />
            </button>
          </DropdownMenu.Trigger>
          <DropdownMenu.Portal>
            <DropdownMenu.Content
              className="z-50 min-w-[120px] rounded-md border border-border bg-card p-1 shadow-md"
              sideOffset={4}
              align="end"
            >
              <DropdownMenu.Item asChild>
                <a
                  href={exports?.subtitles?.srt ?? "#"}
                  download
                  data-testid="dl-srt"
                  className="flex cursor-pointer items-center rounded-sm px-2 py-1.5 text-xs outline-hidden hover:bg-accent focus:bg-accent"
                >
                  SRT
                </a>
              </DropdownMenu.Item>
              <DropdownMenu.Item asChild>
                <a
                  href={exports?.subtitles?.vtt ?? "#"}
                  download
                  data-testid="dl-vtt"
                  className="flex cursor-pointer items-center rounded-sm px-2 py-1.5 text-xs outline-hidden hover:bg-accent focus:bg-accent"
                >
                  VTT
                </a>
              </DropdownMenu.Item>
              <DropdownMenu.Item asChild>
                <a
                  href={exports?.subtitles?.json ?? "#"}
                  download
                  data-testid="dl-json"
                  className="flex cursor-pointer items-center rounded-sm px-2 py-1.5 text-xs outline-hidden hover:bg-accent focus:bg-accent"
                >
                  JSON
                </a>
              </DropdownMenu.Item>
            </DropdownMenu.Content>
          </DropdownMenu.Portal>
        </DropdownMenu.Root>
      </div>
    </div>
  );
}
