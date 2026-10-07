import * as Dialog from "@radix-ui/react-dialog";
import { Info, X } from "lucide-react";
/**
 * AboutDialog: project info + live runtime health, triggered from the header.
 *
 * Uses @radix-ui/react-dialog for accessible modal behavior (Escape to close,
 * focus trapping, scroll-lock). Health data is fetched lazily on open so the
 * dialog costs nothing until used.
 */
import { useCallback, useEffect, useState } from "react";
import { getHealth, type HealthResponse } from "@/lib/api";
import { iconButtonClass } from "@/lib/ui";
import { version as APP_VERSION } from "../../package.json";

interface AboutDialogProps {
  /** Controls whether the dialog is open (lifted to parent for trigger flexibility). */
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

type FetchState =
  | { status: "idle" }
  | { status: "loading" }
  | { status: "success"; data: HealthResponse }
  | { status: "error"; message: string };

function ServiceBadge({ name, value }: { name: string; value: string }) {
  const isOk = value === "ok";
  return (
    <div className="flex items-center justify-between rounded-md border border-border px-3 py-1.5 text-sm">
      <span className="font-medium capitalize">{name}</span>
      <span
        className={
          isOk
            ? "font-mono text-xs text-green-700 dark:text-green-400"
            : "font-mono text-xs text-red-700 dark:text-red-400"
        }
      >
        {isOk ? "ok" : value}
      </span>
    </div>
  );
}

function TranscriptionRuntime({ info: t }: { info: NonNullable<HealthResponse["transcription"]> }) {
  return (
    <div className="space-y-1">
      <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
        Transcription
      </p>
      <div className="grid grid-cols-2 gap-x-4 gap-y-1 text-sm">
        <span className="text-muted-foreground">Device</span>
        <span className="font-mono text-xs">
          {t.device}
          {t.requested_device !== t.device && (
            <span className="ml-1 text-yellow-600 dark:text-yellow-400">
              (requested: {t.requested_device})
            </span>
          )}
        </span>
        <span className="text-muted-foreground">Compute</span>
        <span className="font-mono text-xs">
          {t.compute_type}
          {t.requested_compute_type !== t.compute_type && (
            <span className="ml-1 text-yellow-600 dark:text-yellow-400">
              (requested: {t.requested_compute_type})
            </span>
          )}
        </span>
        <span className="text-muted-foreground">Provider</span>
        <span className="font-mono text-xs">{t.default_provider}</span>
      </div>
      {t.device_fallback_reason && (
        <p className="mt-1 text-xs text-yellow-600 dark:text-yellow-400">
          ⚠ {t.device_fallback_reason}
        </p>
      )}
      {t.compute_type_fallback_reason && (
        <p className="mt-1 text-xs text-yellow-600 dark:text-yellow-400">
          ⚠ {t.compute_type_fallback_reason}
        </p>
      )}
    </div>
  );
}

export function AboutDialog({ open, onOpenChange }: AboutDialogProps) {
  const [fetchState, setFetchState] = useState<FetchState>({ status: "idle" });

  // Fetch health lazily when the dialog opens, no network cost while closed.
  const fetchHealth = useCallback(async () => {
    setFetchState({ status: "loading" });
    try {
      const data = await getHealth();
      setFetchState({ status: "success", data });
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to reach the API.";
      setFetchState({ status: "error", message });
    }
  }, []);

  useEffect(() => {
    if (open) {
      fetchHealth();
    } else {
      // Reset on close so re-opening always fetches fresh data.
      setFetchState({ status: "idle" });
    }
  }, [open, fetchHealth]);

  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-50 bg-black/50" />
        <Dialog.Content
          data-testid="about-dialog"
          className="fixed left-1/2 top-1/2 z-50 w-[90vw] max-w-md -translate-x-1/2 -translate-y-1/2 rounded-lg border border-border bg-card p-6 shadow-lg focus:outline-hidden"
        >
          <Dialog.Title className="text-lg font-semibold">OpenCaptions</Dialog.Title>
          <Dialog.Description className="mt-1 text-sm text-muted-foreground">
            {/* Version comes from apps/web/package.json, bundled by Vite at build
                time (the single source of truth), never hardcode a literal here. */}
            v{APP_VERSION} · Open-source video captioning
          </Dialog.Description>

          {/* Static project info */}
          <div className="mt-4 space-y-1 text-sm">
            <p>
              <span className="text-muted-foreground">Licence: </span>
              <a
                href="https://github.com/leogaudin/opencaptions/blob/main/LICENSE"
                target="_blank"
                rel="noopener noreferrer"
                className="underline hover:text-foreground"
              >
                AGPL-3.0-only
              </a>
            </p>
            <p>
              <span className="text-muted-foreground">Repository: </span>
              <a
                href="https://github.com/leogaudin/opencaptions"
                target="_blank"
                rel="noopener noreferrer"
                className="underline hover:text-foreground"
              >
                github.com/leogaudin/opencaptions
              </a>
            </p>
          </div>

          {/* Live runtime info */}
          <div className="mt-5 border-t border-border pt-4">
            <h3 className="mb-2 text-sm font-medium text-muted-foreground">Runtime</h3>

            {fetchState.status === "loading" && (
              <p className="text-sm text-muted-foreground">Loading health info…</p>
            )}

            {fetchState.status === "error" && (
              <p className="text-sm text-red-700 dark:text-red-400">
                Could not fetch runtime info: {fetchState.message}
              </p>
            )}

            {fetchState.status === "success" && (
              <div className="space-y-3">
                <p className="text-sm">
                  <span className="text-muted-foreground">API version: </span>
                  <span className="font-mono text-xs">{fetchState.data.version}</span>
                </p>

                {/* Service status (withheld by the API in hosted mode) */}
                {fetchState.data.services && (
                  <div className="space-y-1">
                    <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
                      Services
                    </p>
                    <ServiceBadge name="database" value={fetchState.data.services.database} />
                    <ServiceBadge name="redis" value={fetchState.data.services.redis} />
                    <ServiceBadge name="storage" value={fetchState.data.services.storage} />
                  </div>
                )}

                {/* Transcription info (withheld by the API in hosted mode) */}
                {fetchState.data.transcription && (
                  <TranscriptionRuntime info={fetchState.data.transcription} />
                )}
              </div>
            )}
          </div>

          {/* Close button */}
          <Dialog.Close asChild>
            <button
              type="button"
              aria-label="Close"
              className="absolute right-3 top-3 inline-flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground hover:bg-accent hover:text-foreground"
            >
              <X className="h-4 w-4" aria-hidden />
            </button>
          </Dialog.Close>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

/**
 * Header trigger button for the About dialog.
 * Uses the shared icon-button hierarchy (transparent bg, outline, high-contrast
 * foreground, accent on hover): matching the theme-toggle and logout buttons.
 */
export function AboutTrigger({ onClick }: { onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      data-testid="about-trigger"
      aria-label="About OpenCaptions"
      title="About OpenCaptions"
      className={iconButtonClass}
    >
      <Info className="h-4 w-4" aria-hidden />
    </button>
  );
}
