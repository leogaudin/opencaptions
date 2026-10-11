import type * as Preset from "@docusaurus/preset-classic";
import type { Config } from "@docusaurus/types";
import { themes } from "prism-react-renderer";

const GITHUB = "https://github.com/leogaudin/opencaptions";
const SITE = "https://docs.opencaptions.app";
// The pages are the Markdown files of `docs/` at the repository root. A build in a container puts them
// somewhere else and says where.
const DOCS_PATH = process.env.DOCS_PATH ?? "../../docs";

const config: Config = {
  title: "OpenCaptions",
  tagline: "Animated captions for your videos. Open source, self-hosted, and on your iPhone.",
  favicon: "img/favicon.ico",
  url: SITE,
  baseUrl: "/",
  organizationName: "leogaudin",
  projectName: "opencaptions",
  trailingSlash: false,

  // A page that links to something that is not there fails the build, so a rename cannot leave
  // a dead link behind.
  onBrokenLinks: "throw",
  onBrokenAnchors: "throw",
  markdown: {
    // The pages are plain Markdown that GitHub shows too: `.md` is CommonMark, with no JSX in it.
    format: "detect",
    hooks: { onBrokenMarkdownLinks: "throw" },
  },
  i18n: { defaultLocale: "en", locales: ["en"] },

  headTags: [
    {
      tagName: "link",
      attributes: { rel: "apple-touch-icon", href: "/img/apple-touch-icon.png" },
    },
    { tagName: "link", attributes: { rel: "icon", type: "image/svg+xml", href: "/img/favicon.svg" } },
  ],

  presets: [
    [
      "classic",
      {
        docs: {
          path: DOCS_PATH,
          routeBasePath: "/",
          sidebarPath: "./sidebars.ts",
          editUrl: `${GITHUB}/edit/main/docs/`,
        },
        blog: false,
        theme: { customCss: "./src/css/custom.css" },
        sitemap: { changefreq: null, priority: null },
      } satisfies Preset.Options,
    ],
  ],

  themes: [
    [
      // Search that runs in the browser, from an index built with the site: no service to sign
      // up to, and no query leaves the page.
      "@easyops-cn/docusaurus-search-local",
      {
        hashed: true,
        docsDir: DOCS_PATH,
        docsRouteBasePath: "/",
        indexBlog: false,
        highlightSearchTermsOnTargetPage: true,
        explicitSearchResultPath: true,
      },
    ],
  ],

  themeConfig: {
    image: "img/og.png",
    metadata: [
      {
        name: "keywords",
        content:
          "OpenCaptions, animated captions, subtitles, Whisper, Parakeet, self-hosted, open source, Docker, video captions",
      },
    ],
    colorMode: { respectPrefersColorScheme: true },
    docs: { sidebar: { hideable: true, autoCollapseCategories: false } },
    navbar: {
      title: "OpenCaptions",
      logo: { alt: "", src: "img/favicon.svg" },
      items: [
        { type: "docSidebar", sidebarId: "docs", position: "left", label: "Docs" },
        { to: "/reference/api", label: "API", position: "left" },
        { href: "https://opencaptions.app", label: "Demo", position: "right" },
        { href: GITHUB, label: "GitHub", position: "right" },
      ],
    },
    footer: {
      style: "light",
      links: [
        {
          title: "Docs",
          items: [
            { label: "Quick start", to: "/getting-started/quick-start" },
            { label: "Self-hosting", to: "/self-hosting/installation" },
            { label: "HTTP API", to: "/reference/api" },
            { label: "FAQ", to: "/faq" },
          ],
        },
        {
          title: "Project",
          items: [
            { label: "GitHub", href: GITHUB },
            { label: "Issues", href: `${GITHUB}/issues` },
            { label: "Releases", href: `${GITHUB}/releases` },
            { label: "Sponsor", href: "https://github.com/sponsors/leogaudin" },
          ],
        },
        {
          title: "Legal",
          items: [
            { label: "License (AGPL-3.0)", href: `${GITHUB}/blob/main/LICENSE` },
            { label: "Privacy", href: `${GITHUB}/blob/main/PRIVACY.md` },
            { label: "Security", href: `${GITHUB}/blob/main/SECURITY.md` },
          ],
        },
      ],
      copyright: "OpenCaptions is free software, AGPL-3.0. Built and maintained by Leo Gaudin.",
    },
    prism: {
      theme: themes.github,
      darkTheme: themes.dracula,
      additionalLanguages: ["bash", "yaml", "json", "docker", "swift", "diff"],
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
