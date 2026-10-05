/**
 * Transcript panel: the editable segment list, and re-transcription behind one
 * button. Word timings are shown but not editable; re-transcribing regenerates them.
 */
import { Check, Loader2 } from "lucide-react";
import { Disclosure } from "@/components/Disclosure";
import { RetranscribeDialog } from "@/components/RetranscribeDialog";
import { TranscriptSegments } from "@/components/TranscriptSegments";
import { useEditorStore } from "@/store/editorStore";

export function TranscriptEditor() {
  const transcript = useEditorStore((s) => s.transcript);

  if (!transcript) {
    return (
      <div className="rounded-lg border border-border bg-card p-6 text-sm text-muted-foreground">
        No transcript yet. Upload a video to generate one automatically.
      </div>
    );
  }

  return (
    <div className="rounded-lg border border-border bg-card p-4 shadow-xs">
      <div className="mb-3 flex items-center justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold">Transcript</h2>
          <p className="text-[11px] text-muted-foreground">
            {transcript.segments.length} segments · {transcript.duration.toFixed(1)}s ·{" "}
            <span className="uppercase">{transcript.language}</span>
            {transcript.language_detection === "auto" ? " (auto-detected)" : ""}
          </p>
        </div>
        <div className="flex items-center gap-3">
          <AutosaveIndicator />
          <RetranscribeDialog current={transcript.language} />
        </div>
      </div>

      {/* Open by default: the transcript is the thing the editor is for, and a
          user who collapses it keeps that for the session. */}
      <Disclosure
        label="Show transcript"
        openLabel="Hide transcript"
        storageKey="opencaptions-transcript-open"
        defaultOpen
      >
        <TranscriptSegments transcript={transcript} />
      </Disclosure>
    </div>
  );
}

/** "Saving…", "Saved" or the error; nothing while idle. */
function AutosaveIndicator() {
  const status = useEditorStore((s) => s.autosaveStatus);
  const error = useEditorStore((s) => s.autosaveError);

  if (status === "error") {
    return (
      <span className="text-xs text-destructive" role="alert">
        Save failed{error ? `: ${error}` : ""}
      </span>
    );
  }
  if (status === "saving") {
    return (
      <span className="inline-flex items-center gap-1 text-xs text-muted-foreground">
        <Loader2 className="h-3 w-3 animate-spin" aria-hidden />
        Saving…
      </span>
    );
  }
  if (status === "saved") {
    return (
      <span className="inline-flex items-center gap-1 text-xs text-green-500">
        <Check className="h-3.5 w-3.5" aria-hidden />
        Saved
      </span>
    );
  }
  return null;
}
