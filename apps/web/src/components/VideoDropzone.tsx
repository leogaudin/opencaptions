import { useCallback } from "react";
import { type FileRejection, useDropzone } from "react-dropzone";
import { useT } from "@/lib/i18n";
import { cn } from "@/lib/utils";

/** Accepted video container formats (kept in one place, shared by all callers). */
const ACCEPT = {
  "video/*": [".mp4", ".mov", ".webm", ".mkv", ".m4v", ".avi"],
};

interface VideoDropzoneProps {
  /** Called with the accepted video file on a successful drop or pick. */
  onFile: (file: File) => void;
  /** Called with a human-readable message when a non-video file is rejected. */
  onReject?: (message: string) => void;
  /** When set, the currently-selected file is shown (name + size). */
  selectedFile?: File | null;
  disabled?: boolean;
  className?: string;
  /** data-testid for the dropzone root (e.g. "dropzone"). */
  testId?: string;
  /** data-testid for the hidden file input. */
  inputTestId?: string;
}

/**
 * A drag-and-drop video zone that is also keyboard-accessible: react-dropzone's
 * root is focusable and opens the file picker on Enter/Space, so the click
 * fallback works without a mouse. Non-video files are rejected via `accept`.
 *
 * Presentation only: the caller decides what to do with the file. Used by both
 * the /upload form and the home empty state so their affordances stay identical.
 */
export function VideoDropzone({
  onFile,
  onReject,
  selectedFile,
  disabled,
  className,
  testId,
  inputTestId,
}: VideoDropzoneProps) {
  const t = useT();
  const onDrop = useCallback(
    (accepted: File[], rejections: FileRejection[]) => {
      if (rejections.length > 0) {
        onReject?.(t("That doesn't look like a video. Try .mp4, .mov, .webm, .mkv or .avi."));
        return;
      }
      const f = accepted[0];
      if (f) onFile(f);
    },
    [onFile, onReject, t],
  );

  const { getRootProps, getInputProps, isDragActive } = useDropzone({
    onDrop,
    accept: ACCEPT,
    maxFiles: 1,
    disabled,
  });

  return (
    <>
      {/* Outside the button: a button may not contain interactive descendants.
          react-dropzone only needs this rendered, not nested in the root. */}
      <input {...getInputProps()} data-testid={inputTestId} />
      <button
        type="button"
        {...getRootProps()}
        data-testid={testId}
        disabled={disabled}
        aria-label={t("Upload a video: drop a file here, or activate to choose one")}
        className={cn(
          // w-full because a button sizes to its content, where the div this replaced
          // filled its parent.
          "flex w-full cursor-pointer flex-col items-center justify-center rounded-lg border-2 border-dashed text-center transition-colors focus:outline-hidden focus-visible:ring-2 focus-visible:ring-ring",
          isDragActive
            ? "border-primary bg-primary/5"
            : "border-border bg-card hover:border-primary/50",
          disabled && "cursor-not-allowed opacity-60",
          className,
        )}
      >
        {selectedFile ? (
          <div>
            <div className="font-medium">{selectedFile.name}</div>
            <div className="text-xs text-muted-foreground">
              {(selectedFile.size / 1024 / 1024).toFixed(1)} MB
            </div>
          </div>
        ) : (
          <div className="text-sm text-muted-foreground">
            <div className="font-medium text-foreground">
              {isDragActive ? t("Drop to upload") : t("Drop a video here, or click to choose")}
            </div>
            <div className="mt-1 text-xs">.mp4 .mov .webm .mkv .avi</div>
          </div>
        )}
      </button>
    </>
  );
}
