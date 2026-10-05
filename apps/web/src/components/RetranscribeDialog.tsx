/**
 * Re-transcription: one button that opens a dialog for the language and the
 * model. Both start at what the transcript already uses, and only a changed
 * choice is sent, so confirming as-is reruns with the same settings.
 */
import * as Dialog from "@radix-ui/react-dialog";
import { AlertTriangle, RefreshCw, X } from "lucide-react";
import { useState } from "react";
import { LocalModelSelect } from "@/components/LocalModelSelect";
import { useTranscriptionSettings } from "@/lib/useTranscriptionSettings";
import { useEditorStore } from "@/store/editorStore";

export function RetranscribeDialog({ current }: { current: string }) {
  const startTranscription = useEditorStore((s) => s.startTranscription);
  const disabled = useEditorStore((s) => {
    const active = s.jobs.find((j) => j.id === s.activeJobId);
    const transcribing =
      active?.type === "transcription" || (s.project?.status === "transcribing" && !active);
    return !s.project?.video_storage_key || transcribing;
  });
  const { languages, models, defaultModel } = useTranscriptionSettings();
  const [open, setOpen] = useState(false);
  const [language, setLanguage] = useState(current);
  const [model, setModel] = useState<string | null>(null);

  function onOpenChange(next: boolean): void {
    if (next) {
      setLanguage(current);
      setModel(null);
    }
    setOpen(next);
  }

  function confirm(): void {
    startTranscription({
      ...(language !== current && { language }),
      // Null keeps the deployment's provider and model; a choice pins local + model.
      ...(model && model !== defaultModel && { provider: "local" as const, model }),
    });
    setOpen(false);
  }

  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Trigger asChild>
        <button
          type="button"
          disabled={disabled}
          data-testid="retranscribe"
          className="inline-flex items-center gap-1.5 rounded-md border border-border px-2 py-1 text-xs text-muted-foreground hover:bg-accent hover:text-foreground disabled:opacity-50"
        >
          <RefreshCw className="h-3.5 w-3.5" aria-hidden />
          Re-transcribe
        </button>
      </Dialog.Trigger>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-50 bg-black/50" />
        <Dialog.Content
          data-testid="retranscribe-dialog"
          className="fixed left-1/2 top-1/2 z-50 w-[90vw] max-w-sm -translate-x-1/2 -translate-y-1/2 space-y-4 rounded-lg border border-border bg-card p-5 shadow-lg focus:outline-hidden"
        >
          <div className="flex items-center justify-between">
            <Dialog.Title className="text-base font-semibold">Re-transcribe</Dialog.Title>
            <Dialog.Close
              className="text-muted-foreground hover:text-foreground"
              aria-label="Close"
            >
              <X className="h-4 w-4" />
            </Dialog.Close>
          </div>
          <Dialog.Description className="flex items-start gap-2 text-xs text-muted-foreground">
            <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0 text-amber-500" aria-hidden />
            The transcript is regenerated from scratch, discarding your word edits.
          </Dialog.Description>

          <div>
            <label className="mb-1 block text-xs font-medium" htmlFor="retranscribe-language">
              Language
            </label>
            <select
              id="retranscribe-language"
              data-testid="transcript-language-select"
              value={language}
              onChange={(e) => setLanguage(e.target.value)}
              className="w-full rounded-md border border-border bg-card px-2 py-1.5 text-xs"
            >
              <option value="auto">Auto-detect</option>
              {languages.map((l) => (
                <option key={l.code} value={l.code}>
                  {l.label}
                </option>
              ))}
              {current !== "auto" && !languages.some((l) => l.code === current) && (
                <option value={current}>{current.toUpperCase()} (current)</option>
              )}
            </select>
          </div>

          <LocalModelSelect
            id="retranscribe-model"
            testId="retranscribe-model-select"
            value={model ?? defaultModel}
            onChange={setModel}
            models={models}
            defaultModel={defaultModel}
            label="Model"
            compact
          />

          <div className="flex justify-end gap-2">
            <Dialog.Close className="rounded-md border border-border px-3 py-1.5 text-xs hover:bg-accent">
              Cancel
            </Dialog.Close>
            <button
              type="button"
              onClick={confirm}
              disabled={disabled}
              data-testid="retranscribe-confirm"
              className="rounded-md bg-primary px-3 py-1.5 text-xs font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
            >
              Re-transcribe
            </button>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
