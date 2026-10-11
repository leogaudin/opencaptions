/**
 * What the public demo tells search engines, link previews and AI assistants: the title and
 * description, the icons, the Open Graph and Twitter cards, and the structured data. It is one
 * place so the tags cannot disagree, and the build writes it into the page's <head>
 * (`demo.html` holds a placeholder), once for each language the page is in.
 *
 * Only claims that are true of the product today: the iPhone app is listed as available once
 * `APP_STORE_URL` is set. The FAQ is the same text as the one on the page.
 */
import { type LanguageCode, msg, translate } from "@/lib/i18n";
import { FAQ } from "./faq";
import { APP_STORE_URL, DOCS_URL, GITHUB_URL, SITE_URL } from "./links";
import { HREFLANG, OG_LOCALE, PAGE_LANGUAGES, pageUrl } from "./pages";

/** In English: a page in another language shows these translated (see `titleOf`). */
export const TITLE = msg("OpenCaptions: Free, Open-Source Animated Video Captions");
export const DESCRIPTION = msg(
  "Add word-by-word animated captions to any video. Open source and private: transcribe with Whisper, Parakeet or Apple Speech on your iPhone or your own server.",
);
export const OG_IMAGE = `${SITE_URL}og.png`;
const OG_ALT = "OpenCaptions: animated captions that stop the scroll. Free and open source.";
const LICENSE_URL = "https://www.gnu.org/licenses/agpl-3.0.html";

const FEATURES = [
  "Word-by-word animated captions with presets and a full style panel",
  "Speech models of your choice: Whisper, Parakeet and Apple Speech",
  "On-device transcription in the iPhone app",
  "A timeline to retime captions and fix words",
  "Export to MP4, WebM and ProRes video, SRT, VTT and JSON, or captions on a green screen",
  "Self-hosted with Docker Compose",
  "Open source under AGPL-3.0, with no tracking",
];

/** The schema.org graph of a page, in its language: the application, the site, and the FAQ it shows. */
export function structuredData(code: LanguageCode): object {
  const url = pageUrl(code);
  return {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "SoftwareApplication",
        "@id": `${url}#app`,
        name: "OpenCaptions",
        url,
        description: translate((FAQ[0] as { a: string }).a),
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
      { "@type": "WebSite", "@id": `${SITE_URL}#site`, name: "OpenCaptions", url: SITE_URL },
      {
        "@type": "FAQPage",
        "@id": `${url}#faq`,
        url,
        inLanguage: HREFLANG[code],
        mainEntity: FAQ.map(({ q, a }) => ({
          "@type": "Question",
          name: translate(q),
          acceptedAnswer: { "@type": "Answer", text: translate(a) },
        })),
      },
    ],
  };
}

const attr = (value: string): string =>
  value.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");

/** `<` is escaped so no text in the data can close the script element. */
const json = (data: object): string => JSON.stringify(data).replace(/</g, "\\u003c");

/** The tags for the <head> of the page in a language (the one the interface is in), one per line. */
export function headTags(code: LanguageCode): string {
  const title = translate(TITLE);
  const description = translate(DESCRIPTION);
  const url = pageUrl(code);
  const meta = (name: string, content: string) =>
    `<meta name="${name}" content="${attr(content)}" />`;
  const og = (property: string, content: string) =>
    `<meta property="${property}" content="${attr(content)}" />`;
  const alternates = [
    ...PAGE_LANGUAGES.map(
      (c) => `<link rel="alternate" hreflang="${HREFLANG[c]}" href="${pageUrl(c)}" />`,
    ),
    `<link rel="alternate" hreflang="x-default" href="${pageUrl("en")}" />`,
  ];
  return [
    `<title>${attr(title)}</title>`,
    meta("description", description),
    `<link rel="canonical" href="${url}" />`,
    ...alternates,
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
    og("og:title", title),
    og("og:description", description),
    og("og:url", url),
    og("og:locale", OG_LOCALE[code]),
    og("og:image", OG_IMAGE),
    og("og:image:width", "1200"),
    og("og:image:height", "630"),
    og("og:image:alt", OG_ALT),
    meta("twitter:card", "summary_large_image"),
    meta("twitter:title", title),
    meta("twitter:description", description),
    meta("twitter:image", OG_IMAGE),
    meta("twitter:image:alt", OG_ALT),
    `<script type="application/ld+json">${json(structuredData(code))}</script>`,
  ].join("\n    ");
}
