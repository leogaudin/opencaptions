import { Check, Loader2 } from "lucide-react";
import { useEditorStore } from "@/store/editorStore";

/** "Saving…", "Saved" or the error; nothing while idle. */
export function AutosaveIndicator() {
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
