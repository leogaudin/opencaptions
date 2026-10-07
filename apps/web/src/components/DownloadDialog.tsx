/**
 * The one place a video download is set up, as the iOS Save sheet is: the
 * format, the size and the frame rate, then Download. It opens from the
 * toolbar's single Download button; there is no menu of formats.
 */
import * as Dialog from "@radix-ui/react-dialog";
import { X } from "lucide-react";
import { useState } from "react";
import { DownloadOptions } from "@/components/DownloadOptions";
import type { ExportLinks } from "@/lib/api";
import { useT } from "@/lib/i18n";
import { iconButtonClass } from "@/lib/ui";

export function DownloadDialog({
  open,
  onOpenChange,
  exports,
  onDownload,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  exports: ExportLinks | null;
  onDownload: (format: string) => void;
}) {
  const t = useT();
  const formats = exports?.video ?? [];
  const [chosen, setChosen] = useState("mp4");
  // A format the server no longer lists falls back to the first it does.
  const format = formats.find((f) => f.format === chosen) ?? formats[0];

  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-50 bg-black/50" />
        <Dialog.Content
          data-testid="download-dialog"
          aria-describedby={undefined}
          className="fixed left-1/2 top-1/2 z-50 w-[90vw] max-w-sm -translate-x-1/2 -translate-y-1/2 rounded-2xl border border-border bg-card p-5 shadow-lg focus:outline-hidden"
        >
          <div className="flex items-center justify-between">
            <Dialog.Title className="text-lg font-semibold">{t("Download")}</Dialog.Title>
            <Dialog.Close className={iconButtonClass} aria-label={t("Close")}>
              <X className="h-4 w-4" aria-hidden />
            </Dialog.Close>
          </div>

          <div className="mt-4 flex flex-col gap-4">
            <div>
              <fieldset className="flex flex-col gap-1.5">
                <legend className="mb-1.5 text-[11px] font-medium text-muted-foreground">
                  {t("Format")}
                </legend>
                {formats.map((f) => (
                  <label
                    key={f.format}
                    className="flex cursor-pointer flex-col rounded-xl border border-border px-3 py-2 text-sm transition-colors hover:bg-accent/50 has-[:checked]:border-primary has-[:checked]:bg-primary/10"
                  >
                    <input
                      type="radio"
                      name="download-format"
                      className="sr-only"
                      checked={f.format === format?.format}
                      onChange={() => setChosen(f.format)}
                    />
                    <span className="font-medium">{f.label}</span>
                    {/* Shown here, not on hover: the ProRes size warning is read before the click. */}
                    {f.note && <span className="text-[11px] text-muted-foreground">{f.note}</span>}
                  </label>
                ))}
              </fieldset>
            </div>
            {exports && formats.length > 0 && <DownloadOptions choices={exports.choices} />}
          </div>

          <button
            type="button"
            data-testid="download-confirm"
            disabled={!format}
            onClick={() => {
              if (!format) return;
              onOpenChange(false);
              onDownload(format.format);
            }}
            className="mt-5 inline-flex h-10 w-full items-center justify-center rounded-full bg-primary text-sm font-semibold text-primary-foreground hover:opacity-90 disabled:opacity-50"
          >
            {t("Download")}
          </button>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
