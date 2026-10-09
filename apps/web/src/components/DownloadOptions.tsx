/**
 * Size, frame rate and background for a video download, the choices of the iOS Save sheet:
 * only what this video can offer (its own size and rate, and lower ones) is
 * shown, and a row with a single choice is left out. There is no quality
 * choice: a download is made as good as each format does well.
 */
import { Segmented } from "@/components/StyleFields";
import { setDownloadOptions, useDownloadOptions } from "@/lib/downloadOptions";
import { msg, useT } from "@/lib/i18n";
import type { ExportChoices, RenderOptions } from "@/types";

const SIZE_LABELS: Record<RenderOptions["resolution"], string> = {
  original: msg("Original"),
  "2160": "4K",
  "1080": "1080p",
  "720": "720p",
};

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
  const sourceFps = choices.source_fps ? `${Math.round(choices.source_fps)} fps` : t("Original");

  return (
    <div className="flex flex-col gap-4" data-testid="download-options">
      {choices.resolutions.length > 1 && (
        <Row label={t("Size")}>
          <Segmented
            options={choices.resolutions}
            value={resolution}
            onChange={(v) => setDownloadOptions({ resolution: v })}
            label={(v) => t(SIZE_LABELS[v])}
          />
        </Row>
      )}
      {choices.frame_rates.length > 1 && (
        <Row label={t("Frame rate")}>
          <Segmented
            options={choices.frame_rates}
            value={frameRate}
            onChange={(v) => setDownloadOptions({ frame_rate: v })}
            label={(v) => (v === "original" ? sourceFps : `${v} fps`)}
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
