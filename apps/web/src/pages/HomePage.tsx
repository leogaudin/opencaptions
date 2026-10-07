import { Trash2 } from "lucide-react";
/**
 * HomePage:
 *   - Empty state: a single primary "New project" action (to the upload page,
 *     the one place that collects title/language/provider), plus a lightweight
 *     three-step explanation of the flow. No dropzone here, the only real
 *     dropzone lives on the New project page: and no bundled-sample shortcut.
 *   - With projects: a scannable list with poster thumbnails, relative "updated"
 *     time, live progress for active work, and per-row delete.
 */
import { Fragment, useCallback, useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { ProjectThumbnail } from "@/components/ProjectThumbnail";
import * as api from "@/lib/api";
import { msg, useT } from "@/lib/i18n";
import { formatRelativeTime } from "@/lib/time";
import { shellX } from "@/lib/ui";
import { useProjectWebSocket } from "@/lib/useProjectWebSocket";
import { formatBytes } from "@/lib/utils";
import type { ProjectListItem } from "@/types";

export function HomePage() {
  const t = useT();
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

  const handleRenamed = useCallback((id: string, title: string) => {
    setItems((prev) => (prev ? prev.map((p) => (p.id === id ? { ...p, title } : p)) : prev));
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
        {t("Loading projects…")}
      </div>
    );
  }

  if (items.length === 0) {
    return <EmptyState />;
  }

  return (
    <div className={`w-full ${shellX} py-10`}>
      <div className="mb-6 flex items-center justify-between">
        <h1 className="text-2xl font-extrabold tracking-tight">{t("Your projects")}</h1>
        {/* The single primary "New project" action lives in the header (global,
            reachable from every screen). No duplicate here. */}
      </div>
      <ul className="grid grid-cols-2 gap-x-4 gap-y-7 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6">
        {items.map((p) => (
          <ProjectRow key={p.id} item={p} onDeleted={handleDeleted} onRenamed={handleRenamed} />
        ))}
      </ul>
    </div>
  );
}

/** The three-step flow shown under the empty-state CTA. Copy only, the steps
 *  are context, not actions, so they carry no icon or link of their own. */
const FLOW_STEPS = [
  { label: msg("Upload"), detail: msg("Drop or pick a video") },
  { label: msg("Transcribe"), detail: msg("Runs locally, on your machine") },
  { label: msg("Style & export"), detail: msg("Caption it, download the video") },
] as const;

function EmptyState() {
  const t = useT();
  return (
    <div className={`mx-auto w-full max-w-3xl ${shellX} py-16 text-center`}>
      <h1 className="mb-4 text-4xl font-extrabold tracking-tight sm:text-5xl">
        {t("Add captions that move")}
      </h1>
      {/* A caption as the app draws one: the spoken word in yellow. */}
      <p className="mx-auto mb-4 inline-block max-w-md rounded-2xl bg-black px-5 py-3 text-lg font-semibold text-white">
        {t("Transcribe, restyle and {save} a video, all on your machine.", {
          save: "\u0000",
        })
          .split("\u0000")
          .map((part, i) => (
            <Fragment key={part}>
              {i > 0 && <span className="text-primary">{t("save")}</span>}
              {part}
            </Fragment>
          ))}
      </p>
      <p className="mx-auto mb-8 max-w-md text-sm text-muted-foreground">
        {t("Nothing leaves your machine unless you choose a hosted transcription provider.")}
      </p>

      {/* One unmistakable next action: a large, labelled button that says exactly
          where it leads (the New project page, the only place that also collects
          the title, language and provider). It intentionally repeats the header's
          New project button, on an otherwise empty screen there is nothing else
          to anchor to, unlike the populated list whose header button sits beside
          content. A labelled button, deliberately not an arrow the reader must
          decode. */}
      <Link
        to="/upload"
        data-testid="empty-new-project"
        className="inline-flex items-center justify-center rounded-xl bg-primary px-8 py-3.5 text-base font-bold text-primary-foreground transition-opacity hover:opacity-90"
      >
        {t("New project")}
      </Link>

      {/* The 1-2-3 flow, restyled: it explains how the app works, so it must read
          as quiet context, not three panels competing with the button above.
          The old bordered cards are gone; each step is now a small numbered badge
          with a short label, sitting well below the primary action and laid out
          left-to-right as a sequence. */}
      <ol className="mt-16 flex flex-col gap-8 text-left sm:flex-row sm:gap-6">
        {FLOW_STEPS.map((step, i) => (
          <li key={step.label} className="flex flex-1 items-start gap-3">
            <span
              aria-hidden
              className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-muted text-sm font-bold text-foreground"
            >
              {i + 1}
            </span>
            <div>
              <div className="text-sm font-medium">{t(step.label)}</div>
              <div className="mt-0.5 text-xs text-muted-foreground">{t(step.detail)}</div>
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
  onRenamed,
}: {
  item: ProjectListItem;
  onDeleted: (id: string) => void;
  onRenamed: (id: string, title: string) => void;
}) {
  const t = useT();
  const [confirming, setConfirming] = useState(false);
  // Renaming happens here, on the list, and nowhere else: one place to do it.
  const [draft, setDraft] = useState<string | null>(null);
  const settled = useRef(false);
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

  const finishRename = useCallback(
    async (save: boolean) => {
      // Enter and the blur it causes both land here: the first one decides.
      if (settled.current || draft === null) return;
      settled.current = true;
      const title = draft.trim();
      setDraft(null);
      if (!save || !title || title === item.title) return;
      try {
        await api.updateProject(item.id, { title });
        onRenamed(item.id, title);
      } catch (e) {
        setError((e as Error).message);
      }
    },
    [draft, item.id, item.title, onRenamed],
  );

  return (
    <li className="group relative text-sm">
      <div className="relative">
        <ProjectThumbnail projectId={item.id} className="aspect-[9/16] w-full rounded-2xl" />
        {/* Stretched link: the whole card is one click target for opening the project,
            without nesting the delete button inside an anchor. */}
        <Link
          to={`/projects/${item.id}`}
          aria-label={item.title}
          className="absolute inset-0 rounded-2xl focus:outline-hidden focus-visible:ring-2 focus-visible:ring-ring"
        />
        {/* Controls sit above the link (z-10) and take clicks without opening the project. */}
        <div className="absolute right-2 top-2 z-10 flex items-center gap-1">
          {confirming ? (
            <span className="flex items-center gap-1 rounded-full bg-black/70 p-1 text-white backdrop-blur">
              <button
                type="button"
                onClick={handleDelete}
                disabled={deleting}
                data-testid="delete-confirm"
                className="rounded-full bg-destructive px-2.5 py-1 text-xs font-bold text-destructive-foreground disabled:opacity-50"
              >
                {deleting ? t("Deleting…") : t("Delete")}
              </button>
              <button
                type="button"
                onClick={() => setConfirming(false)}
                disabled={deleting}
                className="rounded-full px-2.5 py-1 text-xs font-semibold hover:bg-white/15 disabled:opacity-50"
              >
                {t("Cancel")}
              </button>
            </span>
          ) : (
            <button
              type="button"
              onClick={() => setConfirming(true)}
              aria-label={`Delete ${item.title}`}
              title={t("Delete project")}
              data-testid="delete-project"
              className="inline-flex h-8 w-8 items-center justify-center rounded-full bg-black/60 text-white opacity-80 backdrop-blur transition-opacity hover:bg-destructive hover:text-destructive-foreground group-hover:opacity-100"
            >
              <Trash2 className="h-4 w-4" aria-hidden />
            </button>
          )}
        </div>
      </div>
      <div className="mt-2 min-w-0">
        {draft === null ? (
          <button
            type="button"
            onClick={() => {
              settled.current = false;
              setDraft(item.title);
            }}
            title={t("Click to rename")}
            data-testid="project-title"
            className="-mx-2 block w-[calc(100%+1rem)] cursor-text truncate rounded-md px-2 py-1 text-left font-semibold hover:bg-muted"
          >
            {item.title}
          </button>
        ) : (
          <input
            // biome-ignore lint/a11y/noAutofocus: the field replaces the title just clicked to rename
            autoFocus
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onFocus={(e) => e.currentTarget.select()}
            onBlur={() => finishRename(true)}
            onKeyDown={(e) => {
              if (e.key === "Enter") finishRename(true);
              else if (e.key === "Escape") finishRename(false);
            }}
            aria-label={t("Project name")}
            data-testid="rename-input"
            maxLength={255}
            className="-mx-2 w-[calc(100%+1rem)] rounded-md border border-border bg-background px-2 py-1 text-sm font-semibold"
          />
        )}
        <div
          className="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-muted-foreground"
          title={new Date(item.updated_at).toLocaleString()}
        >
          {item.status === "transcribing" ? (
            <LiveProgress projectId={item.id} />
          ) : (
            <StatusBadge status={item.status} />
          )}
          {item.video_size_bytes != null && <span>{formatBytes(item.video_size_bytes)}</span>}
          <span>{formatRelativeTime(item.updated_at)}</span>
        </div>
      </div>
      {error && (
        <span role="alert" className="mt-1 block text-[11px] text-destructive">
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
  const t = useT();
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
        {pct !== null ? `${pct}%` : t("Transcribing…")}
      </span>
    </span>
  );
}

const STATUS_LABELS: Record<string, string> = {
  draft: msg("draft"),
  transcribing: msg("transcribing"),
  transcribed: msg("transcribed"),
  preparing: msg("preparing"),
  done: msg("done"),
  error: msg("error"),
};

function StatusBadge({ status }: { status: string }) {
  const t = useT();
  // Semantic status colours use light+dark pairs (matching AboutDialog's
  // convention) so they stay legible in BOTH themes, never a single hardcoded
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
  const label = STATUS_LABELS[status === "rendering" ? "preparing" : status] ?? status;
  return (
    <span className={`rounded-full px-2 py-0.5 text-[11px] font-semibold ${cls}`}>{t(label)}</span>
  );
}
