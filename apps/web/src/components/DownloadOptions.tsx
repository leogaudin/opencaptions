/**
 * Size, quality and frame rate for a video download, the choices of the iOS
 * Save sheet: only what this video can offer (its own size and rate, and
 * lower ones) is shown, and a row with a single choice is left out.
 */
import { Segmented } from "@/components/StyleFields";
import { setDownloadOptions, useDownloadOptions } from "@/lib/downloadOptions";
import type { ExportChoices, RenderOptions } from "@/types";

const QUALITIES: RenderOptions["quality"][] = ["smaller", "balanced", "best"];

const SIZE_LABELS: Record<RenderOptions["resolution"], string> = {
  original: "Original",
  "2160": "4K",
  "1080": "1080p",
  "720": "720p",
};

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-1">
      <span className="text-[11px] font-medium text-muted-foreground">{label}</span>
      {children}
    </div>
  );
}

export function DownloadOptions({
  choices,
  qualityApplies,
}: {
  choices: ExportChoices;
  /** False when every format offered ignores it (ProRes). */
  qualityApplies: boolean;
}) {
  const options = useDownloadOptions();
  // A remembered choice this video cannot offer is saved at the video's own.
  const resolution = choices.resolutions.includes(options.resolution)
    ? options.resolution
    : "original";
  const frameRate = choices.frame_rates.includes(options.frame_rate)
    ? options.frame_rate
    : "original";
  const sourceFps = choices.source_fps ? `${Math.round(choices.source_fps)} fps` : "Original";

  return (
    <div className="flex flex-col gap-2 px-2 pt-1.5 pb-2" data-testid="download-options">
      {choices.resolutions.length > 1 && (
        <Row label="Size">
          <Segmented
            options={choices.resolutions}
            value={resolution}
            onChange={(v) => setDownloadOptions({ resolution: v })}
            label={(v) => SIZE_LABELS[v]}
          />
        </Row>
      )}
      {qualityApplies && (
        <Row label="Quality">
          <Segmented
            options={QUALITIES}
            value={options.quality}
            onChange={(v) => setDownloadOptions({ quality: v })}
          />
        </Row>
      )}
      {choices.frame_rates.length > 1 && (
        <Row label="Frame rate">
          <Segmented
            options={choices.frame_rates}
            value={frameRate}
            onChange={(v) => setDownloadOptions({ frame_rate: v })}
            label={(v) => (v === "original" ? sourceFps : `${v} fps`)}
          />
        </Row>
      )}
    </div>
  );
}
