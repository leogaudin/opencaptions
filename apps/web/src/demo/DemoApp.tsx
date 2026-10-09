/**
 * The public demo (opencaptions.app): the editor's own preview and its own preset tiles over a
 * few sample clips. No API, no account, nothing saved; the captions are drawn by the engine,
 * exactly as in the editor and the download.
 */
import { Code, Layers, Moon, Server, Smartphone, Sun, Volume2, VolumeX } from "lucide-react";
import { useEffect, useState } from "react";
import { CaptionPreview } from "@/components/CaptionPreview";
import { PresetStrip } from "@/components/PresetStrip";
import { useT } from "@/lib/i18n";
import { PlaybackProvider, useVideo } from "@/lib/playback";
import { BUILTIN_PRESETS, presetLook, presetMatches } from "@/lib/presets";
import { iconButtonClass } from "@/lib/ui";
import { useTheme } from "@/lib/useTheme";
import { useEditorStore } from "@/store/editorStore";
import { type Clip, loadClip, loadManifest } from "./clips";
import { APP_STORE_URL, DOCS_URL, GITHUB_URL } from "./links";

const linkClass =
  "text-sm font-medium text-muted-foreground transition-colors hover:text-foreground";
const buttonClass =
  "inline-flex h-11 items-center justify-center rounded-full px-6 text-sm font-semibold transition-opacity hover:opacity-90";

function ThemeButton() {
  const t = useT();
  const { theme, toggle } = useTheme();
  const label = theme === "dark" ? t("Switch to light mode") : t("Switch to dark mode");
  return (
    <button
      type="button"
      onClick={toggle}
      aria-label={label}
      title={label}
      data-testid="theme-toggle"
      className={iconButtonClass}
    >
      {theme === "dark" ? <Sun className="h-4 w-4" /> : <Moon className="h-4 w-4" />}
    </button>
  );
}

function Nav() {
  const t = useT();
  return (
    <header className="mx-auto flex h-16 max-w-6xl items-center justify-between px-4 sm:px-6">
      <a href="/" className="flex items-center gap-2 text-lg font-bold tracking-tight">
        <img src="/favicon.svg" alt="" className="h-7 w-7" />
        OpenCaptions
      </a>
      <nav className="flex items-center gap-4 sm:gap-6">
        <a href={DOCS_URL} className={linkClass}>
          {t("Docs")}
        </a>
        <a href={GITHUB_URL} className={linkClass}>
          GitHub
        </a>
        <ThemeButton />
      </nav>
    </header>
  );
}

/**
 * Plays each clip as it loads (muted, unless the visitor asked for less motion), also after a
 * change of clip, which loads a new source into the same <video>. The sound is a button.
 */
function Player() {
  const t = useT();
  const video = useVideo();
  const [muted, setMuted] = useState(true);
  useEffect(() => {
    if (!video) return;
    video.muted = true;
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const start = (): void => {
      if (!reduced) video.play().catch(() => undefined);
    };
    start();
    video.addEventListener("loadeddata", start);
    return () => video.removeEventListener("loadeddata", start);
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
      <div className="mx-auto flex max-w-5xl flex-col items-center gap-6 px-4 pb-16 md:flex-row md:items-start md:justify-center md:gap-10">
        <div className="relative h-[min(70vh,600px)] w-full max-w-[360px] shrink-0">
          {/* Mounted once a project is there: its size observer attaches on first mount. */}
          {loaded && <CaptionPreview interactive={false} />}
          {loaded && <Player />}
        </div>
        <div className="w-full min-w-0 md:max-w-md">
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
          <PresetStrip
            activeId={active?.id}
            onPick={(config) => setStyle(presetLook(config))}
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

function IconBadge({ icon: Icon }: { icon: typeof Code }) {
  return (
    <span className="mb-4 inline-flex h-11 w-11 items-center justify-center rounded-xl bg-primary text-primary-foreground">
      <Icon className="h-5 w-5" aria-hidden="true" />
    </span>
  );
}

function Facts() {
  const t = useT();
  const facts = [
    {
      icon: Smartphone,
      title: t("On your device"),
      body: t(
        "The iPhone app can write the words on the phone itself, with Whisper. No upload needed.",
      ),
    },
    {
      icon: Code,
      title: t("Open source"),
      body: t("Read the code, build it yourself, or run the whole web editor on your own server."),
    },
    {
      icon: Layers,
      title: t("Same pixels everywhere"),
      body: t(
        "One Rust engine draws every caption in the browser, on the server and on the phone.",
      ),
    },
  ];
  return (
    <section className="mx-auto grid max-w-5xl gap-8 px-4 pb-16 sm:grid-cols-3">
      {facts.map(({ icon, title, body }) => (
        <div key={title}>
          <IconBadge icon={icon} />
          <h3 className="text-base font-bold">{title}</h3>
          <p className="mt-2 text-sm text-muted-foreground">{body}</p>
        </div>
      ))}
    </section>
  );
}

function Ways() {
  const t = useT();
  return (
    <section className="mx-auto max-w-5xl px-4 pb-20">
      <h2 className="font-[Montserrat] text-2xl font-black tracking-tight sm:text-3xl">
        {t("Use it where you work")}
      </h2>
      <div className="mt-6 grid gap-4 sm:grid-cols-2">
        <article className="flex flex-col gap-3 rounded-2xl bg-muted p-6">
          <IconBadge icon={Smartphone} />
          <h3 className="text-lg font-bold">{t("iPhone and iPad")}</h3>
          <p className="flex-1 text-sm text-muted-foreground">
            {t("Caption, retime and save right on the phone.")}
          </p>
          {APP_STORE_URL ? (
            <a href={APP_STORE_URL} className={`${buttonClass} bg-primary text-primary-foreground`}>
              {t("Get the iPhone app")}
            </a>
          ) : (
            <span className="text-sm font-semibold text-muted-foreground">
              {t("iPhone app: coming soon")}
            </span>
          )}
        </article>
        <article className="flex flex-col gap-3 rounded-2xl bg-muted p-6">
          <IconBadge icon={Server} />
          <h3 className="text-lg font-bold">{t("Your own server")}</h3>
          <p className="flex-1 text-sm text-muted-foreground">
            {t(
              "The web editor, with a timeline, subtitle files and an API, started with one docker compose command.",
            )}
          </p>
          <a href={DOCS_URL} className={`${buttonClass} bg-foreground text-background`}>
            {t("Read the docs")}
          </a>
        </article>
      </div>
    </section>
  );
}

export function DemoApp() {
  const t = useT();
  return (
    <div className="min-h-screen">
      <Nav />
      <main>
        <section className="mx-auto max-w-3xl px-4 pb-8 pt-4 text-center sm:pt-8">
          <h1 className="font-[Montserrat] text-4xl font-black leading-[1.3] tracking-tight sm:text-5xl">
            {t("Captions that")}{" "}
            <span
              className="bg-gradient-to-b from-primary to-primary bg-[length:100%_1.02em] bg-center bg-no-repeat px-1 text-black"
              style={{ boxDecorationBreak: "clone", WebkitBoxDecorationBreak: "clone" }}
            >
              {t("stop the scroll")}
            </span>
          </h1>
          <p className="mx-auto mt-5 max-w-xl text-base text-muted-foreground sm:text-lg">
            {t(
              "Open-source AI captions you host yourself. Pick a look and see it on a sample clip.",
            )}
          </p>
          <div className="mt-7 flex flex-wrap items-center justify-center gap-3">
            <a href={GITHUB_URL} className={`${buttonClass} bg-primary text-primary-foreground`}>
              {t("Self-host it")}
            </a>
            {APP_STORE_URL ? (
              <a href={APP_STORE_URL} className={`${buttonClass} bg-muted text-foreground`}>
                {t("Get the iPhone app")}
              </a>
            ) : (
              <span
                className={`${buttonClass} cursor-default bg-muted text-muted-foreground hover:opacity-100`}
              >
                {t("iPhone app: coming soon")}
              </span>
            )}
          </div>
        </section>
        <Demo />
        <Facts />
        <Ways />
      </main>
      <footer className="border-t border-border py-8 text-center text-xs text-muted-foreground">
        {t("OpenCaptions is free software, AGPL-3.0.")}
      </footer>
    </div>
  );
}
