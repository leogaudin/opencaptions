import { Trash2 } from "lucide-react";
/**
 * HomePage:
 *   - Empty state: a single primary "New project" action (to the upload page,
 *     the one place that collects title/language/provider), plus a lightweight
 *     three-step explanation of the flow. No dropzone here — the only real
 *     dropzone lives on the New project page — and no bundled-sample shortcut.
 *   - With projects: a scannable list with poster thumbnails, relative "updated"
 *     time, live progress for active work, and per-row delete.
 */
import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { ProjectThumbnail } from "@/components/ProjectThumbnail";
import * as api from "@/lib/api";
import { formatRelativeTime } from "@/lib/time";
import { shellX } from "@/lib/ui";
import { useProjectWebSocket } from "@/lib/useProjectWebSocket";
import type { ProjectListItem } from "@/types";

export function HomePage() {
  const [items, setItems] = useState<ProjectListItem[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    api
      .listProjects()
      .then((res) => {
        if (!cancelled) setItems(res.items);
      })
      .catch((e) => {
        if (!cancelled) setError((e as Error).message);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const handleDeleted = useCallback((id: string) => {
    setItems((prev) => (prev ? prev.filter((p) => p.id !== id) : prev));
  }, []);

  if (error) {
    return (
      <div className={`w-full ${shellX} py-12`}>
        <div className="rounded-md border border-destructive/40 bg-destructive/10 p-4 text-sm text-destructive">
          Failed to load projects: {error}
        </div>
      </div>
    );
  }

  if (items === null) {
    return (
      <div className={`w-full ${shellX} py-12 text-sm text-muted-foreground`}>
        Loading projects…
      </div>
    );
  }

  if (items.length === 0) {
    return <EmptyState />;
  }

  return (
    <div className={`w-full ${shellX} py-10`}>
      <div className="mb-6 flex items-center justify-between">
        <h1 className="text-2xl font-semibold">Your projects</h1>
        {/* The single primary "New project" action lives in the header (global,
            reachable from every screen). No duplicate here. */}
      </div>
      <ul className="space-y-2">
        {items.map((p) => (
          <ProjectRow key={p.id} item={p} onDeleted={handleDeleted} />
        ))}
      </ul>
    </div>
  );
}

/** The three-step flow shown under the empty-state CTA. Copy only — the steps
 *  are context, not actions, so they carry no icon or link of their own. */
const FLOW_STEPS = [
  { label: "Upload", detail: "Drop or pick a video" },
  { label: "Transcribe", detail: "Runs locally, on your machine" },
  { label: "Style & export", detail: "Caption it, download the video" },
] as const;

function EmptyState() {
  return (
    <div className={`mx-auto w-full max-w-3xl ${shellX} py-16 text-center`}>
      <h1 className="mb-3 text-4xl font-bold tracking-tight">Transcribe and caption your video</h1>
      <p className="mx-auto mb-8 max-w-md text-sm text-muted-foreground">
        Turn a video into styled, burned-in captions — transcribed locally on your machine.
      </p>

      {/* One unmistakable next action: a large, labelled button that says exactly
          where it leads (the New project page, the only place that also collects
          the title, language and provider). It intentionally repeats the header's
          New project button — on an otherwise empty screen there is nothing else
          to anchor to, unlike the populated list whose header button sits beside
          content. A labelled button, deliberately not an arrow the reader must
          decode. */}
      <Link
        to="/upload"
        data-testid="empty-new-project"
        className="inline-flex items-center justify-center rounded-md bg-primary px-6 py-3 text-base font-medium text-primary-foreground transition-opacity hover:opacity-90"
      >
        New project
      </Link>

      {/* The 1-2-3 flow, restyled: it explains how the app works, so it must read
          as quiet context — not three panels competing with the button above.
          The old bordered cards are gone; each step is now a small numbered badge
          with a short label, sitting well below the primary action and laid out
          left-to-right as a sequence. */}
      <ol className="mt-16 flex flex-col gap-8 text-left sm:flex-row sm:gap-6">
        {FLOW_STEPS.map((step, i) => (
          <li key={step.label} className="flex flex-1 items-start gap-3">
            <span
              aria-hidden
              className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full border border-border text-sm font-semibold text-muted-foreground"
            >
              {i + 1}
            </span>
            <div>
              <div className="text-sm font-medium">{step.label}</div>
              <div className="mt-0.5 text-xs text-muted-foreground">{step.detail}</div>
            </div>
          </li>
        ))}
      </ol>
    </div>
  );
}

function ProjectRow({
  item,
  onDeleted,
}: {
  item: ProjectListItem;
  onDeleted: (id: string) => void;
}) {
  const [confirming, setConfirming] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleDelete = useCallback(async () => {
    setDeleting(true);
    setError(null);
    try {
      await api.deleteProject(item.id);
      onDeleted(item.id);
    } catch (e) {
      setError((e as Error).message);
      setDeleting(false);
      setConfirming(false);
    }
  }, [item.id, onDeleted]);

  return (
    <li className="relative flex items-center gap-3 rounded-md border border-border bg-card px-4 py-3 text-sm hover:bg-accent">
      <ProjectThumbnail projectId={item.id} />
      <div className="min-w-0 flex-1">
        {/* Stretched link: the whole row is one click target for opening the
            project, without nesting the delete button inside an anchor. */}
        <Link
          to={`/projects/${item.id}`}
          className="font-medium after:absolute after:inset-0 focus:outline-hidden focus-visible:underline"
        >
          {item.title}
        </Link>
        <div
          className="text-xs text-muted-foreground"
          title={new Date(item.updated_at).toLocaleString()}
        >
          Updated {formatRelativeTime(item.updated_at)}
        </div>
      </div>

      {/* Trailing controls sit above the stretched link (z-10) so they take
          clicks without triggering navigation. */}
      <div className="relative z-10 flex items-center gap-2">
        {item.status === "transcribing" ? (
          <LiveProgress projectId={item.id} />
        ) : (
          <StatusBadge status={item.status} />
        )}

        {confirming ? (
          <span className="flex items-center gap-1">
            <button
              type="button"
              onClick={handleDelete}
              disabled={deleting}
              data-testid="delete-confirm"
              className="rounded-md border border-destructive/40 px-2 py-1 text-xs text-destructive hover:bg-destructive/10 disabled:opacity-50"
            >
              {deleting ? "Deleting…" : "Delete"}
            </button>
            <button
              type="button"
              onClick={() => setConfirming(false)}
              disabled={deleting}
              className="rounded-md border border-border px-2 py-1 text-xs hover:bg-accent disabled:opacity-50"
            >
              Cancel
            </button>
          </span>
        ) : (
          <button
            type="button"
            onClick={() => setConfirming(true)}
            aria-label={`Delete ${item.title}`}
            title="Delete project"
            data-testid="delete-project"
            className="inline-flex h-8 w-8 items-center justify-center rounded-md border border-border text-muted-foreground transition-colors hover:border-destructive/40 hover:bg-destructive/10 hover:text-destructive"
          >
            <Trash2 className="h-4 w-4" aria-hidden />
          </button>
        )}
      </div>

      {error && (
        <span role="alert" className="absolute -bottom-4 right-0 z-10 text-[11px] text-destructive">
          {error}
        </span>
      )}
    </li>
  );
}

/**
 * Live inline progress for a project that is actively transcribing. Subscribes
 * to the project WebSocket and depends only on the primitive projectId (never a
 * store object/array), per this codebase's Zustand identity rule. The hook
 * holds the handler in a ref, so this inline callback doesn't re-subscribe.
 */
function LiveProgress({ projectId }: { projectId: string }) {
  const [pct, setPct] = useState<number | null>(null);

  useProjectWebSocket(projectId, (msg) => {
    if (msg.type === "job_progress" || msg.type === "job_started") {
      setPct(Math.round(Number(msg.payload.progress ?? 0) * 100));
    }
  });

  return (
    <span className="flex items-center gap-1.5" data-testid="row-progress">
      <span className="h-1.5 w-20 overflow-hidden rounded-full bg-muted">
        <span
          className="block h-full bg-primary transition-[width] duration-300"
          style={{ width: `${pct ?? 0}%` }}
        />
      </span>
      <span className="text-[11px] text-muted-foreground">
        {pct !== null ? `${pct}%` : "Transcribing…"}
      </span>
    </span>
  );
}

function StatusBadge({ status }: { status: string }) {
  // Semantic status colours use light+dark pairs (matching AboutDialog's
  // convention) so they stay legible in BOTH themes — never a single hardcoded
  // shade that vanishes in light mode.
  const cls =
    {
      draft: "bg-muted text-muted-foreground",
      transcribing: "bg-blue-500/20 text-blue-700 dark:text-blue-400",
      transcribed: "bg-amber-500/20 text-amber-700 dark:text-amber-400",
      rendering: "bg-purple-500/20 text-purple-700 dark:text-purple-400",
      done: "bg-green-500/20 text-green-700 dark:text-green-400",
      error: "bg-red-500/20 text-red-700 dark:text-red-400",
    }[status] ?? "bg-muted text-muted-foreground";
  // User-facing labels: avoid exposing internal "rendering" state.
  const label = status === "rendering" ? "preparing" : status;
  return <span className={`rounded-full px-2 py-0.5 text-xs ${cls}`}>{label}</span>;
}
