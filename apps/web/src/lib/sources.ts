/**
 * Where the preview reads a project's video and a font family. The application's own API by
 * default; the public demo, which has no API, points them at static files (src/demo/main.tsx).
 */
export interface Sources {
  video: (projectId: string) => string;
  font: (family: string) => string;
}

let sources: Sources = {
  video: (projectId) => `/api/v1/projects/${projectId}/source`,
  font: (family) => `/api/v1/fonts/${encodeURIComponent(family)}/file`,
};

export function setSources(next: Sources): void {
  sources = next;
}

export const videoSource = (projectId: string): string => sources.video(projectId);
export const fontSource = (family: string): string => sources.font(family);
