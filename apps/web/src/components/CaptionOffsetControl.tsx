/**
 * CaptionOffsetControl: nudge every caption's timing earlier/later against the
 * audio to fix alignment drift, without re-transcribing.
 *
 * Sits under the presets in Caption style, where it stays visible whatever
 * preset is chosen. Compact by design. Follows the app's button
 * hierarchy: every control here is an adjustment, none is the primary action,
 * so all are transparent-with-outline; the coarse slider uses `accent-primary`
 * like the other sliders. Theme tokens only, no hardcoded colours.
 */
import { Minus, Plus, RotateCcw } from "lucide-react";
import { RangeInput } from "@/components/RangeInput";
import { CAPTION_OFFSET_MAX_MS, CAPTION_OFFSET_MIN_MS } from "@/lib/captionOffset";
import { useT } from "@/lib/i18n";
import { useEditorStore } from "@/store/editorStore";

/** Precise nudge step (ms) for the +/- buttons. The slider gives coarse drag. */
const NUDGE_MS = 50;

function formatOffset(ms: number): string {
  if (ms === 0) return "0 ms";
  return `${ms > 0 ? "+" : ""}${ms} ms`;
}

export function CaptionOffsetControl() {
  const t = useT();
  const captionOffsetMs = useEditorStore((s) => s.captionOffsetMs);
  const setCaptionOffset = useEditorStore((s) => s.setCaptionOffset);

  return (
    <div
      data-testid="caption-offset-control"
      className="rounded-md border border-border bg-background/40 p-2.5"
    >
      <div className="mb-1.5 flex items-center justify-between gap-2">
        <label htmlFor="caption-offset" className="text-xs font-medium text-muted-foreground">
          {t("Timing offset")}{" "}
          <span className="text-muted-foreground/70">{t("· captions vs. audio")}</span>
        </label>
        <span
          data-testid="caption-offset-value"
          className="text-xs font-semibold tabular-nums text-foreground"
        >
          {formatOffset(captionOffsetMs)}
        </span>
      </div>
      <div className="flex items-center gap-2">
        <button
          type="button"
          aria-label={t("Shift captions earlier")}
          data-testid="caption-offset-dec"
          onClick={() => setCaptionOffset(captionOffsetMs - NUDGE_MS)}
          disabled={captionOffsetMs <= CAPTION_OFFSET_MIN_MS}
          className="inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-md border border-border text-muted-foreground hover:bg-accent hover:text-foreground disabled:opacity-50"
        >
          <Minus className="h-3.5 w-3.5" aria-hidden />
        </button>
        <RangeInput
          id="caption-offset"
          min={CAPTION_OFFSET_MIN_MS}
          max={CAPTION_OFFSET_MAX_MS}
          step={10}
          value={captionOffsetMs}
          onChange={setCaptionOffset}
          data-testid="caption-offset-slider"
          aria-label={t("Caption timing offset in milliseconds")}
        />
        <button
          type="button"
          aria-label={t("Shift captions later")}
          data-testid="caption-offset-inc"
          onClick={() => setCaptionOffset(captionOffsetMs + NUDGE_MS)}
          disabled={captionOffsetMs >= CAPTION_OFFSET_MAX_MS}
          className="inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-md border border-border text-muted-foreground hover:bg-accent hover:text-foreground disabled:opacity-50"
        >
          <Plus className="h-3.5 w-3.5" aria-hidden />
        </button>
        <button
          type="button"
          aria-label={t("Reset timing offset to zero")}
          title={t("Reset to 0")}
          data-testid="caption-offset-reset"
          onClick={() => setCaptionOffset(0)}
          disabled={captionOffsetMs === 0}
          className="inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-md border border-border text-muted-foreground hover:bg-accent hover:text-foreground disabled:opacity-50"
        >
          <RotateCcw className="h-3.5 w-3.5" aria-hidden />
        </button>
      </div>
    </div>
  );
}
