/**
 * Size, frame rate and background for a video download, the choices of the iOS Save sheet:
 * only what this video can offer (its own size and rate, and the others) is
 * shown, smallest first and each by its number (never "original"), and a row with a single
 * choice is left out. There is no quality
 * choice: a download is made as good as each format does well.
 */
import { Segmented } from "@/components/StyleFields";
import { setDownloadOptions, useDownloadOptions } from "@/lib/downloadOptions";
import { useT } from "@/lib/i18n";
import type { ExportChoices, RenderOptions } from "@/types";

/** A size by its pixels. */
const sizeLabel = (side: number) => (side === 2160 ? "4K" : `${side}p`);

/** Smallest first: the choice reads as a scale, with the video's own size in its place. */
function ascending<T extends string>(values: readonly T[], pixels: (value: T) => number): T[] {
  return [...values].sort((a, b) => pixels(a) - pixels(b));
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-1.5">
      <span className="text-[11px] font-medium text-muted-foreground">{label}</span>
      {children}
    </div>
  );
}

export function DownloadOptions({ choices }: { choices: ExportChoices }) {
  const t = useT();
  const options = useDownloadOptions();
  // A remembered choice this video cannot offer is saved at the video's own.
  const resolution = choices.resolutions.includes(options.resolution)
    ? options.resolution
    : "original";
  const frameRate = choices.frame_rates.includes(options.frame_rate)
    ? options.frame_rate
    : "original";
  // "original" is the video's own size and rate, which the buttons name by their numbers.
  const sourceFps = Math.round(choices.source_fps ?? 30);
  const sideOf = (v: RenderOptions["resolution"]) =>
    v === "original" ? choices.source_resolution : Number(v);
  const rateOf = (v: RenderOptions["frame_rate"]) => (v === "original" ? sourceFps : Number(v));

  return (
    <div className="flex flex-col gap-4" data-testid="download-options">
      {choices.resolutions.length > 1 && (
        <Row label={t("Size")}>
          <Segmented
            options={ascending(choices.resolutions, sideOf)}
            value={resolution}
            onChange={(v) => setDownloadOptions({ resolution: v })}
            label={(v) => sizeLabel(sideOf(v))}
          />
        </Row>
      )}
      {choices.frame_rates.length > 1 && (
        <Row label={t("Frame rate")}>
          <Segmented
            options={ascending(choices.frame_rates, rateOf)}
            value={frameRate}
            onChange={(v) => setDownloadOptions({ frame_rate: v })}
            label={(v) => `${rateOf(v)} fps`}
          />
        </Row>
      )}
      <Row label={t("Background")}>
        <Segmented
          options={["video", "green"] as const}
          value={options.green_screen ? "green" : "video"}
          onChange={(v) => setDownloadOptions({ green_screen: v === "green" })}
          label={(v) => (v === "green" ? t("Green screen") : t("Video"))}
        />
        {options.green_screen && (
          <p className="text-[11px] text-muted-foreground">
            {t("Only the captions, on green, to key out in your editor.")}
          </p>
        )}
      </Row>
    </div>
  );
}
