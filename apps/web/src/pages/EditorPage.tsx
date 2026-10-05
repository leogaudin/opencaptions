/**
 * EditorPage: toolbar above a two-pane layout — preview left, transcript and
 * style right on desktop, stacked on mobile.
 *
 * The shell provides a full-viewport flex column, so panes need min-h-0 to
 * scroll independently instead of overflowing.
 */
import { useEffect } from "react";
import { Group, Panel, Separator, useDefaultLayout } from "react-resizable-panels";
import { useParams } from "react-router-dom";
import { CaptionPreview } from "@/components/CaptionPreview";
import { EditorToolbar } from "@/components/EditorToolbar";
import { StyleControls } from "@/components/StyleControls";
import { TranscriptEditor } from "@/components/TranscriptEditor";
import { useProjectWebSocket } from "@/lib/useProjectWebSocket";
import { useEditorStore } from "@/store/editorStore";

export function EditorPage() {
  const { projectId } = useParams<{ projectId: string }>();
  const project = useEditorStore((s) => s.project);
  const loadProject = useEditorStore((s) => s.loadProject);
  const reloadProject = useEditorStore((s) => s.reloadProject);
  const upsertJob = useEditorStore((s) => s.upsertJob);
  const error = useEditorStore((s) => s.error);

  // Remembers the split between transcript and preview across page loads. v4
  // replaced v3's `autoSaveId` prop with this hook, which spreads defaultLayout
  // and onLayoutChanged onto the Group.
  const layout = useDefaultLayout({ id: "opencaptions:editor:layout" });

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
      // must not be re-bucketed as transcription — prefer the stage the backend
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

  const leftPane = (
    <div className="flex h-full flex-col gap-4 overflow-y-auto p-4">
      <CaptionPreview />
    </div>
  );

  const rightPane = (
    <div className="flex h-full flex-col gap-4 overflow-y-auto p-4">
      <TranscriptEditor />
      <StyleControls />
    </div>
  );

  return (
    /* flex-1 + min-h-0: take remaining vertical space from the app shell's
       flex column without overflowing. No magic viewport arithmetic. */
    <div className="flex min-h-0 flex-1 flex-col">
      {/* Toolbar spans full width directly under the app header */}
      <EditorToolbar />

      {/* Mobile / narrow viewports: stack vertically */}
      <div className="flex flex-1 flex-col gap-4 overflow-y-auto px-4 py-6 md:hidden">
        <CaptionPreview />
        <TranscriptEditor />
        <StyleControls />
      </div>

      {/* Desktop: resizable panels filling all remaining space below toolbar.
          min-h-0 lets children scroll instead of overflowing. */}
      <div className="hidden min-h-0 flex-1 md:block">
        <Group orientation="horizontal" {...layout}>
          <Panel id="transcript" defaultSize="55%" minSize="30%" className="bg-background">
            {leftPane}
          </Panel>
          {/* Resize handle: hairline at rest, generous invisible hit area (~10px),
              grip pill on hover/drag, focus-visible ring for keyboard resizing. */}
          <Separator className="group relative flex w-px items-center justify-center bg-border transition-colors hover:bg-primary/50 data-[separator-dragging]:bg-primary/50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2 cursor-col-resize">
            {/* Invisible hit area — wider than the visual line for easy grabbing */}
            <div className="absolute inset-y-0 left-[-5px] right-[-5px]" />
            {/* Grip pill: visible on hover and while dragging */}
            <div className="pointer-events-none absolute h-8 w-1 rounded-full bg-muted-foreground/30 opacity-0 transition-opacity group-hover:opacity-100 group-data-[separator-dragging]:opacity-100" />
          </Separator>
          <Panel id="preview" defaultSize="45%" minSize="25%" className="bg-background">
            {rightPane}
          </Panel>
        </Group>
      </div>
    </div>
  );
}
