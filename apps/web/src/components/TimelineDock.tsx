/**
 * The editor's timeline, docked full-width under the preview and the style
 * panel: the main surface for working with the captions over time.
 */
import { Timeline } from "@/components/timeline/Timeline";
import { useVideo } from "@/lib/playback";
import { useEditorStore } from "@/store/editorStore";

export function TimelineDock() {
  const video = useVideo();
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
    <Timeline
      video={video}
      transcript={transcript}
      offsetMs={offsetMs}
      wordsPerLine={wordsPerLine}
      duration={Math.max(1, project.video_duration ?? transcript.duration)}
      fps={project.video_fps || 30}
      title={project.title}
      onEdit={editTranscript}
    />
  );
}
