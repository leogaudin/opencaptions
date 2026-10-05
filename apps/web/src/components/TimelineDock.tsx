/**
 * The editor's timeline, docked full-width under the preview and the style
 * panel: the main surface for working with the captions over time.
 */
import { Timeline } from "@/components/Timeline";
import { useVideoRef } from "@/lib/playback";
import { useEditorStore } from "@/store/editorStore";

export function TimelineDock() {
  const video = useVideoRef();
  const project = useEditorStore((s) => s.project);
  const transcript = useEditorStore((s) => s.transcript);
  const wordsPerLine = useEditorStore((s) => s.style.words_per_line);
  const offsetMs = useEditorStore((s) => s.captionOffsetMs);
  const editTranscript = useEditorStore((s) => s.editTranscript);

  if (!project?.video_storage_key || !transcript || transcript.segments.length === 0) {
    return (
      <div className="flex h-full items-center justify-center p-4 text-sm text-muted-foreground">
        Captions appear here once the video is transcribed.
      </div>
    );
  }
  return (
    <div className="h-full overflow-y-auto p-3">
      <Timeline
        video={video}
        transcript={transcript}
        offsetMs={offsetMs}
        wordsPerLine={wordsPerLine}
        duration={Math.max(1, transcript.duration)}
        onEdit={editTranscript}
      />
    </div>
  );
}
