/**
 * EditorPage: the toolbar on top, then the preview beside the style panel, and the
 * timeline docked full-width underneath, on desktop. On a narrow screen the same
 * pieces stack: preview, timeline, style.
 *
 * Exactly one of the two layouts is mounted, so there is one <video> and one
 * engine whichever the width. The shell provides a full-viewport flex column, so
 * panes need min-h-0 to scroll independently instead of overflowing.
 */
import { useEffect } from "react";
import { Group, Panel, Separator, useDefaultLayout } from "react-resizable-panels";
import { useParams } from "react-router-dom";
import { CaptionPreview } from "@/components/CaptionPreview";
import { EditorToolbar } from "@/components/EditorToolbar";
import { StyleControls } from "@/components/StyleControls";
import { TimelineDock } from "@/components/TimelineDock";
import { PlaybackProvider } from "@/lib/playback";
import { useMediaQuery } from "@/lib/useMediaQuery";
import { useProjectWebSocket } from "@/lib/useProjectWebSocket";
import { useEditorStore } from "@/store/editorStore";

export function EditorPage() {
  const { projectId } = useParams<{ projectId: string }>();
  const project = useEditorStore((s) => s.project);
  const loadProject = useEditorStore((s) => s.loadProject);
  const reloadProject = useEditorStore((s) => s.reloadProject);
  const upsertJob = useEditorStore((s) => s.upsertJob);
  const error = useEditorStore((s) => s.error);

  const desktop = useMediaQuery("(min-width: 768px)");

  // Remember the splits across page loads. v4 replaced v3's `autoSaveId` prop with
  // this hook, which spreads defaultLayout and onLayoutChanged onto the Group.
  // Two groups, two ids: the rows (work area over timeline) and the columns
  // (preview beside the style panel).
  const rows = useDefaultLayout({ id: "opencaptions:editor:rows" });
  const columns = useDefaultLayout({ id: "opencaptions:editor:columns" });

  // Load + cleanup
  useEffect(() => {
    if (projectId) loadProject(projectId);
    return () => {
      useEditorStore.getState().reset();
    };
  }, [projectId, loadProject]);

  // Subscribe to job progress events
  useProjectWebSocket(projectId, (msg) => {
    if (msg.type === "job_progress" || msg.type === "job_started") {
      // Resolve job type defensively: a job_progress event without a stage field
      // must not be re-bucketed as transcription, prefer the stage the backend
      // sent, then the type already known for this job, then fall back.
      const jobId = String(msg.payload.job_id);
      const existingJob = useEditorStore.getState().jobs.find((j) => j.id === jobId);
      const resolvedType: "transcription" | "rendering" =
        (msg.payload.stage as "transcription" | "rendering" | undefined) ??
        existingJob?.type ??
        "transcription";
      upsertJob({
        id: jobId,
        project_id: String(projectId),
        type: resolvedType,
        status: "running",
        progress: Number(msg.payload.progress ?? 0),
        message: (msg.payload.message as string) ?? null,
        error: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      });
    } else if (msg.type === "job_succeeded") {
      reloadProject();
    } else if (
      msg.type === "transcript_updated" ||
      msg.type === "job_failed" ||
      msg.type === "job_cancelled"
    ) {
      reloadProject();
    }
  });

  if (error) {
    return (
      <div className="container mx-auto px-4 py-12">
        <div className="rounded-md border border-destructive/40 bg-destructive/10 p-4 text-sm text-destructive">
          {error}
        </div>
      </div>
    );
  }

  // Gate on `!project`, never on `loading`: reloadProject sets loading on every
  // background WebSocket refresh, which would unmount the editor mid-edit.
  if (!project) {
    return (
      <div className="container mx-auto px-4 py-12 text-sm text-muted-foreground">
        Loading project…
      </div>
    );
  }

  const stack = (
    <div className="flex flex-1 flex-col gap-4 overflow-y-auto px-4 py-6">
      <div className="h-[45vh] shrink-0">
        <CaptionPreview />
      </div>
      <div className="h-56 shrink-0 rounded-md border border-border bg-card">
        <TimelineDock />
      </div>
      <StyleControls />
    </div>
  );

  // Resize handles: a hairline at rest, a generous invisible hit area (~10px), a
  // grip pill on hover and while dragging, a focus ring for keyboard resizing.
  const handleClasses =
    "group relative flex items-center justify-center bg-border transition-colors hover:bg-primary/50 data-[separator-dragging]:bg-primary/50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2";
  const panels = (
    <Group orientation="vertical" {...rows}>
      <Panel id="work" defaultSize="68%" minSize="30%" className="bg-background">
        <Group orientation="horizontal" {...columns}>
          <Panel id="preview" defaultSize="60%" minSize="30%" className="bg-background">
            <div className="h-full p-4">
              <CaptionPreview />
            </div>
          </Panel>
          <Separator className={`${handleClasses} w-px cursor-col-resize`}>
            <div className="absolute inset-y-0 left-[-5px] right-[-5px]" />
            <div className="pointer-events-none absolute h-8 w-1 rounded-full bg-muted-foreground/30 opacity-0 transition-opacity group-hover:opacity-100 group-data-[separator-dragging]:opacity-100" />
          </Separator>
          <Panel id="style" defaultSize="40%" minSize="25%" className="bg-background">
            <div className="flex h-full flex-col gap-4 overflow-y-auto p-4">
              <StyleControls />
            </div>
          </Panel>
        </Group>
      </Panel>
      <Separator className={`${handleClasses} h-px cursor-row-resize`}>
        <div className="absolute inset-x-0 top-[-5px] bottom-[-5px]" />
        <div className="pointer-events-none absolute h-1 w-8 rounded-full bg-muted-foreground/30 opacity-0 transition-opacity group-hover:opacity-100 group-data-[separator-dragging]:opacity-100" />
      </Separator>
      <Panel
        id="dock"
        defaultSize="32%"
        minSize={140}
        className="overflow-hidden border-t border-border bg-card"
      >
        <TimelineDock />
      </Panel>
    </Group>
  );

  return (
    /* flex-1 + min-h-0: take remaining vertical space from the app shell's
       flex column without overflowing. No magic viewport arithmetic. */
    <PlaybackProvider>
      <div className="flex min-h-0 flex-1 flex-col">
        {/* Toolbar spans full width directly under the app header */}
        <EditorToolbar />
        {desktop ? <div className="min-h-0 flex-1">{panels}</div> : stack}
      </div>
    </PlaybackProvider>
  );
}
