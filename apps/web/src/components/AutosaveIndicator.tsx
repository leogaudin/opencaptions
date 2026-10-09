import { Check, Loader2 } from "lucide-react";
import { useT } from "@/lib/i18n";
import { useEditorStore } from "@/store/editorStore";

/** "Saving…", "Saved" or the error; nothing while idle. A download that could not start shows here too. */
export function AutosaveIndicator() {
  const t = useT();
  const status = useEditorStore((s) => s.autosaveStatus);
  const error = useEditorStore((s) => s.autosaveError);
  const downloadError = useEditorStore((s) => s.downloadError);

  if (status === "error") {
    return (
      <span className="text-xs text-destructive" role="alert">
        {t("Save failed")}
        {error ? `: ${error}` : ""}
      </span>
    );
  }
  if (downloadError) {
    return (
      <span className="text-xs text-destructive" role="alert">
        {downloadError}
      </span>
    );
  }
  if (status === "saving") {
    return (
      <span className="inline-flex items-center gap-1 text-xs text-muted-foreground">
        <Loader2 className="h-3 w-3 animate-spin" aria-hidden />
        {t("Saving…")}
      </span>
    );
  }
  if (status === "saved") {
    return (
      <span className="inline-flex items-center gap-1 text-xs text-green-500">
        <Check className="h-3.5 w-3.5" aria-hidden />
        {t("Saved")}
      </span>
    );
  }
  return null;
}
