import starlight from "@astrojs/starlight";
import { unified } from "@astrojs/markdown-remark";
import { defineConfig } from "astro/config";
import starlightLinksValidator from "starlight-links-validator";
import { remarkDocs } from "./plugins/remark-docs.ts";

const GITHUB = "https://github.com/leogaudin/opencaptions";
const SITE = "https://docs.opencaptions.app";

export default defineConfig({
  site: SITE,
  markdown: { processor: unified({ remarkPlugins: [remarkDocs] }) },
  integrations: [
    starlight({
      title: "OpenCaptions",
      description: "Animated captions for your videos. Open source, self-hosted, and on your iPhone.",
      logo: { src: "./src/assets/logo.svg" },
      favicon: "/img/favicon.svg",
      social: [{ icon: "github", label: "GitHub", href: GITHUB }],
      editLink: { baseUrl: `${GITHUB}/edit/main/docs/` },
      customCss: ["./src/styles/custom.css"],
      head: [
        { tag: "link", attrs: { rel: "icon", href: "/img/favicon.ico", sizes: "32x32" } },
        { tag: "link", attrs: { rel: "apple-touch-icon", href: "/img/apple-touch-icon.png" } },
        { tag: "meta", attrs: { property: "og:image", content: `${SITE}/img/og.png` } },
        { tag: "meta", attrs: { name: "twitter:image", content: `${SITE}/img/og.png` } },
      ],
      // A page that links to something that is not there (or to a heading that is not there)
      // fails the build. The pages say to open http://localhost:5173, which is meant.
      plugins: [starlightLinksValidator({ errorOnLocalLinks: false })],
      sidebar: [
        { label: "Introduction", link: "/" },
        { label: "Getting started", items: [{ autogenerate: { directory: "getting-started" } }] },
        { label: "Guides", items: [{ autogenerate: { directory: "guides" } }] },
        { label: "Self-hosting", items: [{ autogenerate: { directory: "self-hosting" } }] },
        { label: "Reference", items: [{ autogenerate: { directory: "reference" } }] },
        { slug: "faq" },
        { label: "About the project", collapsed: true, items: [{ autogenerate: { directory: "project" } }] },
        {
          label: "Links",
          items: [
            { label: "Try the demo", link: "https://opencaptions.app" },
            { label: "Releases", link: `${GITHUB}/releases` },
            { label: "Report a problem", link: `${GITHUB}/issues` },
          ],
        },
      ],
    }),
  ],
});
