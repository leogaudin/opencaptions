/**
 * Re-transcription: one button that opens a dialog with the choices a new project offers (where it runs,
 * the model, the spoken language that follows the model), the same components. They start at what the
 * deployment and the transcript already use, and only a changed choice is sent, so confirming as-is
 * reruns with the same settings.
 */
import * as Dialog from "@radix-ui/react-dialog";
import { AlertTriangle, RefreshCw, X } from "lucide-react";
import { useState } from "react";
import { LanguageList } from "@/components/LanguageList";
import { TranscriptionEngine } from "@/components/TranscriptionEngine";
import { useT } from "@/lib/i18n";
import { useTranscriptionChoice } from "@/lib/useTranscriptionChoice";
import { useEditorStore } from "@/store/editorStore";

export function RetranscribeDialog({ current }: { current: string }) {
  const t = useT();
  const disabled = useEditorStore((s) => {
    const active = s.jobs.find((j) => j.id === s.activeJobId);
    return !s.project?.video_storage_key || active?.type === "transcription";
  });
  const [open, setOpen] = useState(false);

  return (
    <Dialog.Root open={open} onOpenChange={setOpen}>
      <Dialog.Trigger asChild>
        <button
          type="button"
          disabled={disabled}
          data-testid="retranscribe"
          className="inline-flex items-center gap-1.5 rounded-full bg-muted px-3 py-1.5 text-xs font-semibold text-foreground hover:bg-muted/70 disabled:opacity-50"
        >
          <RefreshCw className="h-3.5 w-3.5" aria-hidden />
          {t("Re-transcribe")}
        </button>
      </Dialog.Trigger>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-50 bg-black/50" />
        <Dialog.Content
          data-testid="retranscribe-dialog"
          className="fixed left-1/2 top-1/2 z-50 max-h-[85vh] w-[90vw] max-w-lg -translate-x-1/2 -translate-y-1/2 space-y-4 overflow-y-auto rounded-lg border border-border bg-card p-5 shadow-lg focus:outline-hidden"
        >
          <div className="flex items-center justify-between">
            <Dialog.Title className="text-base font-semibold">{t("Re-transcribe")}</Dialog.Title>
            <Dialog.Close
              className="text-muted-foreground hover:text-foreground"
              aria-label={t("Close")}
            >
              <X className="h-4 w-4" />
            </Dialog.Close>
          </div>
          <Dialog.Description className="flex items-start gap-2 text-xs text-muted-foreground">
            <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0 text-amber-500" aria-hidden />
            {t("The transcript is regenerated from scratch, discarding your word edits.")}
          </Dialog.Description>
          <Choices current={current} disabled={disabled} done={() => setOpen(false)} />
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

/**
 * The choices and the button. Mounted only while the dialog is open, so each opening starts from what the
 * deployment and the transcript use, not from what was last picked.
 */
function Choices({
  current,
  disabled,
  done,
}: {
  current: string;
  disabled: boolean;
  done: () => void;
}) {
  const t = useT();
  const startTranscription = useEditorStore((s) => s.startTranscription);
  const choice = useTranscriptionChoice(current);

  function confirm(): void {
    startTranscription({
      ...(choice.language !== current && { language: choice.language }),
      // Nothing is sent for a provider and model that are the deployment's own.
      ...((choice.changedProvider || choice.changedModel) && { provider: choice.provider }),
      ...(choice.changedModel && { model: choice.model }),
    });
    done();
  }

  return (
    <>
      <TranscriptionEngine choice={choice} />
      <LanguageList
        languages={choice.languages}
        value={choice.language}
        onChange={choice.setLanguage}
        testId="language-list"
      />
      <div className="flex justify-end gap-2">
        <Dialog.Close className="rounded-md border border-border px-3 py-1.5 text-xs hover:bg-accent">
          {t("Cancel")}
        </Dialog.Close>
        <button
          type="button"
          onClick={confirm}
          disabled={disabled}
          data-testid="retranscribe-confirm"
          className="rounded-xl bg-primary px-4 py-2 text-xs font-bold text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
        >
          {t("Re-transcribe")}
        </button>
      </div>
    </>
  );
}
