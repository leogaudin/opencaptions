/**
 * The demo page around its player: the words and the layout a visitor, a search engine or an AI
 * assistant reads. Nothing here needs a browser, so the build renders it to HTML
 * (`scripts/demo-prerender.ts`): the page has its words before any script runs, and React replaces
 * them once the demo is ready. Keep it free of browser-only code (no `window`, no effects that
 * matter) and put anything interactive in `DemoApp.tsx`.
 */
import {
  Captions,
  Code,
  Download,
  Languages,
  Layers,
  Moon,
  Server,
  Smartphone,
  Sun,
} from "lucide-react";
import type { ReactNode } from "react";
import { getLanguage, LANGUAGES, rememberLanguage, useT } from "@/lib/i18n";
import { iconButtonClass } from "@/lib/ui";
import { useTheme } from "@/lib/useTheme";
import { FAQ } from "./faq";
import { APP_STORE_URL, DOCS_URL, GITHUB_URL, PRIVACY_URL } from "./links";
import { HREFLANG, pagePath } from "./pages";

const linkClass =
  "text-sm font-medium text-muted-foreground transition-colors hover:text-foreground";
const buttonClass =
  "inline-flex h-11 items-center justify-center rounded-full px-6 text-sm font-semibold transition-opacity hover:opacity-90";
/** Links that leave the page open in a new tab, so the demo stays where it is. */
export const external = { target: "_blank", rel: "noopener noreferrer" } as const;
const h2Class = "font-[Montserrat] text-2xl font-black tracking-tight sm:text-3xl";

/** The demo's frame and its player's box: the page holds the same space before the demo loads. */
export const demoFrameClass =
  "mx-auto flex max-w-5xl flex-col items-center gap-6 px-4 pb-16 md:flex-row md:items-start md:justify-center md:gap-10";
export const playerBoxClass = "relative h-[min(70vh,600px)] w-full max-w-[360px] shrink-0";

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
        <img src="/favicon.svg" alt="" width={28} height={28} className="h-7 w-7" />
        OpenCaptions
      </a>
      <nav className="flex items-center gap-4 sm:gap-6">
        <a href={DOCS_URL} {...external} className={linkClass}>
          {t("Docs")}
        </a>
        <a href={GITHUB_URL} {...external} className={linkClass}>
          GitHub
        </a>
        <ThemeButton />
      </nav>
    </header>
  );
}

function Hero() {
  const t = useT();
  return (
    <section className="mx-auto max-w-3xl px-4 pb-8 pt-4 text-center sm:pt-8">
      <h1 className="font-[Montserrat] text-4xl font-black leading-[1.3] tracking-tight sm:text-5xl">
        {t("Animated captions that")}{" "}
        <span
          className="bg-gradient-to-b from-primary to-primary bg-[length:100%_1.02em] bg-center bg-no-repeat px-1 text-black sm:whitespace-nowrap"
          style={{ boxDecorationBreak: "clone", WebkitBoxDecorationBreak: "clone" }}
        >
          {t("stop the scroll")}
        </span>
      </h1>
      <p className="mx-auto mt-5 max-w-xl text-base text-muted-foreground sm:text-lg">
        {t(
          "Add word-by-word captions to any video. Open source and private: transcribe on your iPhone or on your own server, with the speech model you choose.",
        )}
      </p>
      <div className="mt-7 flex flex-wrap items-center justify-center gap-3">
        <a
          href={GITHUB_URL}
          {...external}
          className={`${buttonClass} bg-primary text-primary-foreground`}
        >
          {t("Self-host it")}
        </a>
        {APP_STORE_URL ? (
          <a
            href={APP_STORE_URL}
            {...external}
            className={`${buttonClass} bg-muted text-foreground`}
          >
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
  );
}

function IconBadge({ icon: Icon }: { icon: typeof Code }) {
  return (
    <span className="mb-4 inline-flex h-11 w-11 items-center justify-center rounded-xl bg-primary text-primary-foreground">
      <Icon className="h-5 w-5" aria-hidden="true" />
    </span>
  );
}

function HowItWorks() {
  const t = useT();
  const steps = [
    {
      title: t("Add a video"),
      body: t("Pick a video from your photos, or upload one in the browser."),
    },
    {
      title: t("Get the words"),
      body: t("A speech model of your choice writes the words and gives each one its timing."),
    },
    {
      title: t("Pick a look and export"),
      body: t(
        "Choose a style, fix a word or retime a caption on the timeline, then save the captioned video.",
      ),
    },
  ];
  return (
    <section className="mx-auto max-w-5xl px-4 pb-16">
      <h2 className={h2Class}>{t("How it works")}</h2>
      <ol className="mt-6 grid gap-6 sm:grid-cols-3">
        {steps.map(({ title, body }, i) => (
          <li key={title} className="flex gap-4 sm:block">
            <span className="inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-full bg-primary text-lg font-black text-primary-foreground sm:mb-4">
              {i + 1}
            </span>
            <div>
              <h3 className="text-base font-bold">{title}</h3>
              <p className="mt-2 text-sm text-muted-foreground">{body}</p>
            </div>
          </li>
        ))}
      </ol>
    </section>
  );
}

function Facts() {
  const t = useT();
  const facts = [
    {
      icon: Captions,
      title: t("Word-by-word animation"),
      body: t(
        "Each word lights up as it is spoken. Start from a preset, then change the font, colors, outline, background and position.",
      ),
    },
    {
      icon: Languages,
      title: t("Your choice of speech model"),
      body: t(
        "Whisper covers about 100 languages, Parakeet is fast in 25 European ones, and Apple Speech is built into iOS. Captions can be drawn in Latin, Cyrillic, Arabic, Hebrew, Indic, Thai and CJK scripts.",
      ),
    },
    {
      icon: Smartphone,
      title: t("On your device"),
      body: t("The iPhone app writes the words on the phone itself. No upload needed."),
    },
    {
      icon: Download,
      title: t("Export what you need"),
      body: t(
        "A captioned MP4, WebM or ProRes video, SRT or VTT subtitle files, or only the captions on a green screen to key out in your video editor.",
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
    <section className="mx-auto max-w-5xl px-4 pb-16">
      <h2 className={h2Class}>{t("What you get")}</h2>
      <div className="mt-6 grid gap-8 sm:grid-cols-2 lg:grid-cols-3">
        {facts.map(({ icon, title, body }) => (
          <div key={title}>
            <IconBadge icon={icon} />
            <h3 className="text-base font-bold">{title}</h3>
            <p className="mt-2 text-sm text-muted-foreground">{body}</p>
          </div>
        ))}
      </div>
    </section>
  );
}

function Ways() {
  const t = useT();
  return (
    <section className="mx-auto max-w-5xl px-4 pb-16">
      <h2 className={h2Class}>{t("Use it where you work")}</h2>
      <div className="mt-6 grid gap-4 sm:grid-cols-2">
        <article className="flex flex-col gap-3 rounded-2xl bg-muted p-6">
          <IconBadge icon={Smartphone} />
          <h3 className="text-lg font-bold">{t("iPhone and iPad")}</h3>
          <p className="flex-1 text-sm text-muted-foreground">
            {t("Caption, retime and save right on the phone.")}
          </p>
          {APP_STORE_URL ? (
            <a
              href={APP_STORE_URL}
              {...external}
              className={`${buttonClass} bg-primary text-primary-foreground`}
            >
              {t("Get the iPhone app")}
            </a>
          ) : (
            <span className="text-sm font-semibold text-muted-foreground">
              {t("iPhone app: coming soon")}
            </span>
          )}
        </article>
        <article className="flex min-w-0 flex-col gap-3 rounded-2xl bg-muted p-6">
          <IconBadge icon={Server} />
          <h3 className="text-lg font-bold">{t("Your own server")}</h3>
          <p className="flex-1 text-sm text-muted-foreground">
            {t(
              "The web editor, with a timeline, subtitle files and an API, started with one docker compose command.",
            )}
          </p>
          <a
            href={DOCS_URL}
            {...external}
            className={`${buttonClass} bg-foreground text-background`}
          >
            {t("Read the docs")}
          </a>
        </article>
      </div>
    </section>
  );
}

function Faq() {
  const t = useT();
  return (
    <section className="mx-auto max-w-5xl px-4 pb-20">
      <h2 className={h2Class}>{t("Questions and answers")}</h2>
      <div className="mt-6 grid gap-x-10 gap-y-7 md:grid-cols-2">
        {FAQ.map(({ q, a }) => (
          <div key={q}>
            <h3 className="text-base font-bold">{t(q)}</h3>
            <p className="mt-2 text-sm text-muted-foreground">{t(a)}</p>
          </div>
        ))}
      </div>
    </section>
  );
}

/** Links to the page in each language: plain anchors, so a search engine finds every translation. */
function LanguageLinks() {
  const t = useT();
  const current = getLanguage();
  return (
    <nav
      aria-label={t("Language")}
      className="mx-auto mb-5 flex max-w-3xl flex-wrap items-center justify-center gap-x-4 gap-y-1.5 px-4"
    >
      {LANGUAGES.map(({ code, name }) => (
        <a
          key={code}
          href={pagePath(code)}
          hrefLang={HREFLANG[code]}
          lang={code}
          aria-current={code === current ? "page" : undefined}
          onClick={() => rememberLanguage(code)}
          className={`text-xs transition-colors hover:text-foreground ${
            code === current ? "font-semibold text-foreground" : "text-muted-foreground"
          }`}
        >
          {name}
        </a>
      ))}
    </nav>
  );
}

function Footer({ credits }: { credits?: ReactNode }) {
  const t = useT();
  return (
    <footer className="border-t border-border py-8 text-center text-xs text-muted-foreground">
      <LanguageLinks />
      <nav className="mb-4 flex flex-wrap items-center justify-center gap-x-6 gap-y-2">
        <a href={DOCS_URL} {...external} className={linkClass}>
          {t("Docs")}
        </a>
        <a href={GITHUB_URL} {...external} className={linkClass}>
          GitHub
        </a>
        <a href={PRIVACY_URL} {...external} className={linkClass}>
          {t("Privacy")}
        </a>
      </nav>
      {credits}
      {t("OpenCaptions is free software, AGPL-3.0.")}
    </footer>
  );
}

/** The whole page. `demo` is the player and its looks; `credits` the clips' attribution. */
export function Page({ demo, credits }: { demo: ReactNode; credits?: ReactNode }) {
  return (
    <div className="min-h-screen">
      <Nav />
      <main>
        <Hero />
        {demo}
        <HowItWorks />
        <Facts />
        <Ways />
        <Faq />
      </main>
      <Footer credits={credits} />
    </div>
  );
}

/** Holds the demo's place in the prerendered page, at the size it will have. */
export function DemoSkeleton() {
  return (
    <div className={demoFrameClass}>
      <div className={`${playerBoxClass} rounded-2xl bg-muted`} />
      <div className="h-28 w-full md:max-w-md" />
    </div>
  );
}
