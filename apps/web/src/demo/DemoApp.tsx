/**
 * The public demo (opencaptions.app): the editor's own preview and its own preset tiles over a
 * sample clip. No API, no account, nothing saved; the captions are drawn by the engine,
 * exactly as in the editor and the download.
 */
import { Volume2, VolumeX } from "lucide-react";
import { useEffect, useState } from "react";
import { CaptionPreview } from "@/components/CaptionPreview";
import { PresetStrip } from "@/components/PresetStrip";
import { useT } from "@/lib/i18n";
import { PlaybackProvider, useVideo } from "@/lib/playback";
import { BUILTIN_PRESETS, presetLook, presetMatches } from "@/lib/presets";
import { useEditorStore } from "@/store/editorStore";
import { type Clip, loadClip, loadManifest } from "./clips";
import { demoFrameClass, external, Page, playerBoxClass } from "./Landing";

/**
 * Plays the clip as it loads (muted, unless the visitor asked for less motion), and again and again.
 * It only plays while it can be seen: a hidden tab or a player scrolled out of view pauses it, so
 * the page costs no decoding and no drawing then, and it picks up again when it is back. A change
 * of clip, when there is more than one, loads a new source into the same <video>. The sound is a
 * button.
 */
function Player() {
  const t = useT();
  const video = useVideo();
  const [muted, setMuted] = useState(true);
  useEffect(() => {
    if (!video) return;
    video.muted = true;
    video.loop = true;
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    let tabShown = !document.hidden;
    let inView = true;
    let resume = false; // it was playing when it was hidden
    const seen = (): boolean => tabShown && inView;
    const play = (): void => {
      resume = false;
      video.play().catch(() => undefined);
    };
    const sync = (): void => {
      if (!seen()) {
        resume ||= !video.paused;
        video.pause();
      } else if (resume) {
        play();
      }
    };
    const start = (): void => {
      if (reduced) return;
      if (seen()) play();
      else resume = true;
    };
    const onVisibility = (): void => {
      tabShown = !document.hidden;
      sync();
    };
    const observer = new IntersectionObserver((entries) => {
      inView = entries[entries.length - 1]?.isIntersecting ?? true;
      sync();
    });
    observer.observe(video);
    document.addEventListener("visibilitychange", onVisibility);
    video.addEventListener("loadeddata", start);
    start();
    return () => {
      observer.disconnect();
      document.removeEventListener("visibilitychange", onVisibility);
      video.removeEventListener("loadeddata", start);
    };
  }, [video]);
  if (!video) return null;
  const label = muted ? t("Turn the sound on") : t("Turn the sound off");
  return (
    <button
      type="button"
      onClick={() => {
        video.muted = !video.muted;
        setMuted(video.muted);
      }}
      aria-label={label}
      title={label}
      data-testid="sound-toggle"
      className="absolute bottom-3 right-3 z-10 inline-flex h-9 w-9 items-center justify-center rounded-full bg-black/60 text-white backdrop-blur transition-colors hover:bg-black/80"
    >
      {muted ? <VolumeX className="h-4 w-4" /> : <Volume2 className="h-4 w-4" />}
    </button>
  );
}

function Demo() {
  const t = useT();
  const [clips, setClips] = useState<Clip[]>([]);
  const [clipId, setClipId] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);
  const style = useEditorStore((s) => s.style);
  const setStyle = useEditorStore((s) => s.setStyle);
  const loaded = useEditorStore((s) => s.project !== null);
  const active = BUILTIN_PRESETS.find((p) => presetMatches(p.config, style));

  useEffect(() => {
    loadManifest()
      .then((list) => {
        setClips(list);
        setClipId(list[0]?.id ?? null);
      })
      .catch(() => setFailed(true));
  }, []);

  useEffect(() => {
    const clip = clips.find((c) => c.id === clipId);
    if (!clip) return;
    let cancelled = false;
    loadClip(clip)
      .then(({ project, transcript }) => {
        // The look the visitor picked stays across clips.
        if (!cancelled) useEditorStore.setState({ project, transcript });
      })
      .catch(() => setFailed(true));
    return () => {
      cancelled = true;
    };
  }, [clips, clipId]);

  if (failed) {
    return (
      <p className="p-8 text-center text-sm text-muted-foreground">
        {t("The demo could not be loaded.")}
      </p>
    );
  }

  return (
    <PlaybackProvider>
      <div className={demoFrameClass}>
        <div className={playerBoxClass}>
          {/* Mounted once a project is there: its size observer attaches on first mount. */}
          {loaded && <CaptionPreview interactive={false} />}
          {loaded && <Player />}
        </div>
        <div className="w-full min-w-0 md:max-w-md">
          {clips.length > 1 && (
            <div className="mb-3 flex flex-wrap gap-2" data-testid="clip-chips">
              {clips.map((c) => (
                <button
                  key={c.id}
                  type="button"
                  aria-pressed={c.id === clipId}
                  onClick={() => setClipId(c.id)}
                  className={`rounded-full px-3.5 py-1.5 text-xs font-semibold transition-colors ${
                    c.id === clipId
                      ? "bg-primary text-primary-foreground"
                      : "bg-muted text-foreground hover:bg-muted/70"
                  }`}
                >
                  {c.label}
                </button>
              ))}
            </div>
          )}
          <p className="mb-3 text-sm text-muted-foreground">
            {t("Pick a look and see it on the sample clip.")}
          </p>
          <PresetStrip
            activeId={active?.id}
            onPick={(config) => setStyle(presetLook(config, style))}
            className="flex gap-2.5 overflow-x-auto p-1 md:grid md:grid-cols-3 md:overflow-visible"
            tileClassName="w-32 shrink-0 md:w-auto"
          />
          <p className="mt-3 text-xs text-muted-foreground">
            {t("Tap the video to play or pause.")}
          </p>
        </div>
      </div>
    </PlaybackProvider>
  );
}

/** The clips' credits: CC BY asks for the title, the author, the licence and a note of changes. */
function Credits() {
  const t = useT();
  const [clips, setClips] = useState<Clip[]>([]);
  useEffect(() => {
    loadManifest()
      .then(setClips)
      .catch(() => undefined);
  }, []);
  const credited = clips.filter((c) => c.credit);
  if (credited.length === 0) return null;
  return (
    <p className="mx-auto mb-3 max-w-3xl px-4" data-testid="clip-credits">
      {credited.map((c, i) => {
        const credit = c.credit as NonNullable<Clip["credit"]>;
        return (
          <span key={c.id}>
            {i > 0 && " · "}
            <a href={credit.url} {...external} className="underline">
              {credit.title}
            </a>{" "}
            {credit.author} (
            <a href={credit.licenseUrl} {...external} className="underline">
              {credit.license}
            </a>
            )
          </span>
        );
      })}{" "}
      {t("The clip is cropped and trimmed.")}
    </p>
  );
}

export function DemoApp() {
  return <Page demo={<Demo />} credits={<Credits />} />;
}
