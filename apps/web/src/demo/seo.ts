/**
 * What the public demo tells search engines, link previews and AI assistants: the title and
 * description, the icons, the Open Graph and Twitter cards, and the structured data. It is one
 * place so the tags cannot disagree, and the build writes it into the page's <head>
 * (`demo.html` holds a placeholder).
 *
 * Only claims that are true of the product today: the iPhone app is listed as available once
 * `APP_STORE_URL` is set. The FAQ is the same text as the one on the page.
 */
import { FAQ } from "./faq";
import { APP_STORE_URL, DOCS_URL, GITHUB_URL, SITE_URL } from "./links";

export const TITLE = "OpenCaptions: Free, Open-Source Animated Video Captions";
export const DESCRIPTION =
  "Add word-by-word animated captions to any video. Open source and private: transcribe with Whisper in about 100 languages on your iPhone or your own server.";
const SUMMARY = (FAQ[0] as { a: string }).a;
export const OG_IMAGE = `${SITE_URL}og.png`;
const OG_ALT = "OpenCaptions: animated captions that stop the scroll. Free and open source.";
const LICENSE_URL = "https://www.gnu.org/licenses/agpl-3.0.html";

const FEATURES = [
  "Word-by-word animated captions with presets and a full style panel",
  "Whisper transcription in about 100 languages",
  "On-device transcription in the iPhone app",
  "A timeline to retime captions and fix words",
  "Export to MP4, WebM and ProRes video, SRT, VTT and JSON, or captions on a green screen",
  "Self-hosted with Docker Compose",
  "Open source under AGPL-3.0, with no tracking",
];

/** The schema.org graph: the application, the site, and the FAQ the page shows. */
export function structuredData(): object {
  return {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "SoftwareApplication",
        "@id": `${SITE_URL}#app`,
        name: "OpenCaptions",
        url: SITE_URL,
        description: SUMMARY,
        applicationCategory: "MultimediaApplication",
        operatingSystem: APP_STORE_URL ? "iOS, iPadOS, Web, Docker" : "Web, Docker",
        offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
        isAccessibleForFree: true,
        license: LICENSE_URL,
        featureList: FEATURES,
        image: OG_IMAGE,
        softwareHelp: { "@type": "CreativeWork", url: DOCS_URL },
        sameAs: [GITHUB_URL],
        ...(APP_STORE_URL ? { downloadUrl: APP_STORE_URL } : {}),
      },
      {
        "@type": "WebSite",
        "@id": `${SITE_URL}#site`,
        name: "OpenCaptions",
        url: SITE_URL,
        description: DESCRIPTION,
        inLanguage: "en",
      },
      {
        "@type": "FAQPage",
        "@id": `${SITE_URL}#faq`,
        mainEntity: FAQ.map(({ q, a }) => ({
          "@type": "Question",
          name: q,
          acceptedAnswer: { "@type": "Answer", text: a },
        })),
      },
    ],
  };
}

const attr = (value: string): string =>
  value.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");

/** `<` is escaped so no text in the data can close the script element. */
const json = (data: object): string => JSON.stringify(data).replace(/</g, "\\u003c");

/** The tags for the page's <head>, one per line. */
export function headTags(): string {
  const meta = (name: string, content: string) =>
    `<meta name="${name}" content="${attr(content)}" />`;
  const og = (property: string, content: string) =>
    `<meta property="${property}" content="${attr(content)}" />`;
  return [
    `<title>${attr(TITLE)}</title>`,
    meta("description", DESCRIPTION),
    `<link rel="canonical" href="${SITE_URL}" />`,
    meta("robots", "index, follow, max-image-preview:large, max-snippet:-1, max-video-preview:-1"),
    `<meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)" />`,
    `<meta name="theme-color" content="#0a0a0a" media="(prefers-color-scheme: dark)" />`,
    `<link rel="icon" href="/favicon.ico" sizes="48x48" />`,
    `<link rel="icon" type="image/svg+xml" href="/favicon.svg" sizes="any" />`,
    `<link rel="icon" type="image/png" href="/favicon-96x96.png" sizes="96x96" />`,
    `<link rel="apple-touch-icon" href="/apple-touch-icon.png" />`,
    `<link rel="manifest" href="/site.webmanifest" />`,
    og("og:type", "website"),
    og("og:site_name", "OpenCaptions"),
    og("og:title", TITLE),
    og("og:description", DESCRIPTION),
    og("og:url", SITE_URL),
    og("og:locale", "en_US"),
    og("og:image", OG_IMAGE),
    og("og:image:width", "1200"),
    og("og:image:height", "630"),
    og("og:image:alt", OG_ALT),
    meta("twitter:card", "summary_large_image"),
    meta("twitter:title", TITLE),
    meta("twitter:description", DESCRIPTION),
    meta("twitter:image", OG_IMAGE),
    meta("twitter:image:alt", OG_ALT),
    `<script type="application/ld+json">${json(structuredData())}</script>`,
  ].join("\n    ");
}
