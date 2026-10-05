import { Film } from "lucide-react";
import { useState } from "react";
import { getThumbnailUrl } from "@/lib/api";
import { cn } from "@/lib/utils";

interface ProjectThumbnailProps {
  projectId: string;
  className?: string;
}

/**
 * Poster frame for a project row. Points an <img> at
 * GET /api/v1/projects/{id}/thumbnail (auth via the same-origin session
 * cookie). That endpoint returns an image or 404 when the project has none, so
 * on error we swap to a tasteful film-frame placeholder rather than showing the
 * browser's broken-image icon. Decorative (alt="") — the row's title link is
 * the accessible name.
 */
export function ProjectThumbnail({ projectId, className }: ProjectThumbnailProps) {
  const [failed, setFailed] = useState(false);
  const base = "aspect-video w-24 shrink-0 overflow-hidden rounded-xl bg-muted";

  if (failed) {
    return (
      <div
        className={cn(base, "flex items-center justify-center text-muted-foreground", className)}
        aria-hidden="true"
      >
        <Film className="h-5 w-5" />
      </div>
    );
  }

  return (
    <img
      src={getThumbnailUrl(projectId)}
      alt=""
      loading="lazy"
      onError={() => setFailed(true)}
      className={cn(base, "object-cover", className)}
    />
  );
}
