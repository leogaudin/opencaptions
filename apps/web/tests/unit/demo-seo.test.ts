import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { before, describe, test } from "node:test";
import { type DemoHtml, fillPage, localizePage, renderDemo } from "../../scripts/demo-prerender.ts";
import { DOCS_URL, GITHUB_URL, SITE_URL } from "../../src/demo/links.ts";

/**
 * What the public demo tells search engines, link previews and AI assistants, in every language it
 * is in. The pages are rendered the way the build renders them (no browser), so these read what a
 * crawler that runs no script reads, and check that every file the pages point to is there.
 */
const PUBLIC = new URL("../../demo-public/", import.meta.url);
const read = (name: string) => readFileSync(new URL(name, PUBLIC), "utf8");
const TEMPLATE = readFileSync(new URL("../../demo.html", import.meta.url), "utf8");

/** The languages of the interface: English, and one file of translations for each other. */
const OTHERS = readdirSync(new URL("../../src/locales/", import.meta.url))
  .filter((f) => f.endsWith(".json"))
  .map((f) => f.replace(".json", ""))
  .sort();

let pages: Record<string, DemoHtml>;
/** Each language's whole page, as the build writes it. */
const html: Record<string, string> = {};
const codes = (): string[] => Object.keys(html);
const urlOf = (code: string): string => (code === "en" ? SITE_URL : `${SITE_URL}${code}/`);

before(async () => {
  pages = await renderDemo();
  const english = fillPage(TEMPLATE, pages.en as DemoHtml);
  for (const [code, page] of Object.entries(pages)) {
    html[code] = code === "en" ? english : localizePage(english, pages.en as DemoHtml, page, code);
  }
});

const ENTITIES: Record<string, string> = {
  "&amp;": "&",
  "&lt;": "<",
  "&gt;": ">",
  "&quot;": '"',
  "&#x27;": "'",
};
/** The words of some HTML, as a reader gets them. */
const words = (fragment: string): string =>
  fragment
    .replace(/<[^>]*>/g, " ")
    .replace(/&(?:amp|lt|gt|quot|#x27);/g, (e) => ENTITIES[e] ?? e)
    .replace(/\s+/g, " ");

/** Width in characters, a Chinese, Japanese or Korean one counting double (what a result line fits). */
const width = (s: string): number =>
  [...s].reduce((n, ch) => n + (/[ᄀ-ᇿ　-鿿가-힯＀-￯]/.test(ch) ? 2 : 1), 0);

const metaContent = (code: string, attrName: string, key: string): string => {
  const tag = (html[code] as string).match(
    new RegExp(`<meta ${attrName}="${key}" content="([^"]*)"`),
  );
  assert.ok(tag, `${code}: no <meta ${attrName}="${key}">`);
  return (tag[1] as string).replace(/&amp;/g, "&").replace(/&quot;/g, '"');
};

/** Width and height of a PNG, from its header. */
function pngSize(name: string): [number, number] {
  const bytes = readFileSync(new URL(name, PUBLIC));
  assert.equal(bytes.subarray(1, 4).toString(), "PNG", `${name} is not a PNG`);
  return [bytes.readUInt32BE(16), bytes.readUInt32BE(20)];
}

describe("demo pages: one for each language", () => {
  test("English at /, and a page for every language there are translations in", () => {
    assert.deepEqual([...codes()].sort(), ["en", ...OTHERS].sort());
    assert.equal(codes()[0], "en");
  });

  test("the page of a language is in that language", () => {
    const english = words((pages.en as DemoHtml).body);
    for (const code of OTHERS) {
      assert.match(html[code] as string, new RegExp(`<html lang="${code}">`));
      const text = words((pages[code] as DemoHtml).body);
      assert.notEqual(text, english, `${code} is the English text`);
      assert.notEqual(
        metaContent(code, "property", "og:title"),
        metaContent("en", "property", "og:title"),
        `${code}: the title is not translated`,
      );
    }
    assert.match(html.en as string, /<html lang="en">/);
  });

  test("the sitemap lists each page once", () => {
    const sitemap = read("sitemap.xml");
    assert.match(sitemap, /^<\?xml version="1.0" encoding="UTF-8"\?>/);
    const locs = [...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]);
    assert.deepEqual(locs, codes().map(urlOf));
  });
});

describe("demo pages: head", () => {
  test("a title and a description that fit a search result, in each language", () => {
    for (const code of codes()) {
      const title = ((html[code] as string).match(/<title>([^<]*)<\/title>/)?.[1] ?? "").replace(
        /&amp;/g,
        "&",
      );
      assert.ok(
        width(title) >= 24 && width(title) <= 64,
        `${code}: title is ${width(title)} wide: ${title}`,
      );
      assert.match(title, /OpenCaptions/);
      const description = metaContent(code, "name", "description");
      assert.ok(
        width(description) >= 90 && width(description) <= 175,
        `${code}: description is ${width(description)} wide`,
      );
    }
  });

  test("each page names itself canonical, and lists every page as an alternate", () => {
    for (const code of codes()) {
      const page = html[code] as string;
      assert.equal(page.match(/<link rel="canonical" href="([^"]*)"/)?.[1], urlOf(code), code);
      assert.equal(metaContent(code, "property", "og:url"), urlOf(code));
      const alternates = [
        ...page.matchAll(/<link rel="alternate" hreflang="([^"]+)" href="([^"]+)"/g),
      ];
      assert.deepEqual(
        alternates.map((m) => m[2]),
        [...codes().map(urlOf), urlOf("en")],
        `${code}: alternates (every page, then x-default)`,
      );
      assert.equal(alternates.at(-1)?.[1], "x-default");
      assert.equal(
        new Set(alternates.map((m) => m[1])).size,
        alternates.length,
        "hreflang values are distinct",
      );
    }
  });

  test("a link preview: Open Graph and Twitter cards with a 1200x630 picture", () => {
    assert.equal(SITE_URL, "https://opencaptions.app/");
    for (const code of codes()) {
      const image = metaContent(code, "property", "og:image");
      assert.equal(image, `${SITE_URL}og.png`);
      assert.equal(metaContent(code, "name", "twitter:image"), image);
      assert.equal(metaContent(code, "name", "twitter:card"), "summary_large_image");
      assert.equal(
        metaContent(code, "property", "og:title"),
        metaContent(code, "name", "twitter:title"),
      );
      assert.match(metaContent(code, "property", "og:locale"), /^[a-z]{2}_[A-Z]{2}$/);
    }
    assert.ok(metaContent("en", "property", "og:image:alt").length > 20);
    assert.deepEqual(pngSize("og.png"), [1200, 630]);
  });

  test("the icons are linked, and there", () => {
    const linked = [
      ...(html.en as string).matchAll(
        /<link rel="(?:icon|apple-touch-icon|manifest)"[^>]*href="\/([^"]+)"/g,
      ),
    ];
    assert.ok(
      linked.length >= 5,
      "favicon.ico, favicon.svg, a png, apple-touch-icon and a manifest",
    );
    for (const [, file] of linked)
      assert.ok(existsSync(new URL(file as string, PUBLIC)), `${file}`);
    assert.deepEqual(pngSize("apple-touch-icon.png"), [180, 180]);
    assert.deepEqual(pngSize("favicon-96x96.png"), [96, 96]);
  });

  test("favicon.ico is a real icon with a 48 px image (what search engines ask for)", () => {
    const ico = readFileSync(new URL("favicon.ico", PUBLIC));
    assert.equal(ico.readUInt16LE(0), 0);
    assert.equal(ico.readUInt16LE(2), 1, "type: icon");
    const count = ico.readUInt16LE(4);
    const sizes = Array.from({ length: count }, (_, i) => ico.readUInt8(6 + 16 * i));
    assert.ok(sizes.includes(48), `sizes ${sizes}`);
  });

  test("the web manifest names icons that exist", () => {
    const manifest = JSON.parse(read("site.webmanifest")) as { icons: { src: string }[] };
    assert.ok(manifest.icons.length >= 2);
    for (const { src } of manifest.icons) assert.ok(existsSync(new URL(`.${src}`, PUBLIC)), src);
    assert.deepEqual(pngSize("icon-192.png"), [192, 192]);
    assert.deepEqual(pngSize("icon-512.png"), [512, 512]);
  });
});

describe("demo pages: what a crawler that runs no script reads", () => {
  test("one h1, and headings that go down one level at a time, in each language", () => {
    for (const code of codes()) {
      const body = (pages[code] as DemoHtml).body;
      const levels = [...body.matchAll(/<h([1-6])[\s>]/g)].map((m) => Number(m[1]));
      assert.equal(levels.filter((l) => l === 1).length, 1, code);
      assert.equal(levels[0], 1, code);
      for (let i = 1; i < levels.length; i++) {
        assert.ok(
          (levels[i] as number) <= (levels[i - 1] as number) + 1,
          `${code} heading ${i}: ${levels}`,
        );
      }
      assert.ok(levels.filter((l) => l === 2).length >= 4, `${code}: sections have their own h2`);
    }
  });

  test("the words that people search for are in the English page", () => {
    const text = words((pages.en as DemoHtml).body).toLowerCase();
    for (const phrase of [
      "animated captions",
      "word-by-word",
      "open source",
      "whisper",
      "parakeet",
      "apple speech",
      "iphone",
      "about 100 languages",
      "self-host",
      "docker compose",
      "agpl-3.0",
      "srt",
      "green screen",
    ]) {
      assert.ok(text.includes(phrase), `"${phrase}" is not in the page`);
    }
  });

  test("every page links to every page, with the language as the link's text", () => {
    for (const code of codes()) {
      const body = (pages[code] as DemoHtml).body;
      for (const other of codes()) {
        const path = other === "en" ? "/" : `/${other}/`;
        assert.ok(body.includes(`href="${path}"`), `${code} does not link to ${path}`);
      }
    }
  });

  test("every image has alt text, and every outside link is https", () => {
    for (const code of codes()) {
      const body = (pages[code] as DemoHtml).body;
      for (const [tag] of body.matchAll(/<img[^>]*>/g)) assert.match(tag, /\salt="/, tag);
      for (const [, url] of body.matchAll(/href="(https?:[^"]*)"/g)) {
        assert.match(url as string, /^https:\/\//, url);
      }
    }
  });

  test("the docs link points at pages that exist (the repository's), not at a site not yet built", () => {
    assert.ok(DOCS_URL.startsWith(GITHUB_URL));
    assert.ok(!(pages.en as DemoHtml).body.includes("docs.opencaptions.app"));
  });

  test("the page shows no command to copy (it does not read well there)", () => {
    assert.ok(!(pages.en as DemoHtml).body.includes("<pre"));
  });
});

describe("demo pages: structured data", () => {
  const graph = (code: string): { "@type": string }[] => {
    const raw = (html[code] as string).match(
      /<script type="application\/ld\+json">([\s\S]*?)<\/script>/,
    )?.[1];
    assert.ok(raw, `${code}: no JSON-LD`);
    return (JSON.parse(raw) as { "@graph": { "@type": string }[] })["@graph"];
  };

  test("an application, a site and a FAQ, on every page", () => {
    for (const code of codes()) {
      assert.deepEqual(
        graph(code).map((n) => n["@type"]),
        ["SoftwareApplication", "WebSite", "FAQPage"],
        code,
      );
    }
  });

  test("the FAQ in the data is the FAQ on the page, word for word, in each language", () => {
    for (const code of codes()) {
      const faq = graph(code).find((n) => n["@type"] === "FAQPage") as unknown as {
        inLanguage: string;
        mainEntity: { name: string; acceptedAnswer: { text: string } }[];
      };
      assert.ok(faq.mainEntity.length >= 6);
      assert.ok(faq.inLanguage.startsWith(code));
      const text = words((pages[code] as DemoHtml).body);
      for (const { name, acceptedAnswer } of faq.mainEntity) {
        assert.ok(text.includes(name), `${code}: question not on the page: ${name}`);
        assert.ok(text.includes(acceptedAnswer.text), `${code}: answer not on the page: ${name}`);
      }
    }
  });

  test("the application is free and open source, and says so", () => {
    const app = graph("en")[0] as unknown as Record<string, unknown>;
    assert.equal((app.offers as { price: string }).price, "0");
    assert.match(String(app.license), /agpl/);
    assert.equal(app.url, SITE_URL);
  });
});

describe("demo pages: files for crawlers", () => {
  test("robots.txt welcomes everyone, names AI crawlers, and points at the sitemap", () => {
    const robots = read("robots.txt");
    assert.match(robots, /^User-agent: \*\nAllow: \/$/m);
    assert.ok(!/^Disallow:\s*\/\s*$/m.test(robots), "nothing is blocked");
    for (const bot of ["GPTBot", "ClaudeBot", "PerplexityBot", "Google-Extended"]) {
      assert.match(robots, new RegExp(`^User-agent: ${bot}$`, "m"));
    }
    assert.match(robots, new RegExp(`^Sitemap: ${SITE_URL}sitemap.xml$`, "m"));
  });

  test("llms.txt follows the format: a title, a summary, absolute links, and every translation", () => {
    const llms = read("llms.txt");
    assert.match(llms, /^# OpenCaptions\n\n> .{80,}/);
    const links = [...llms.matchAll(/\]\(([^)]+)\)/g)].map((m) => m[1] as string);
    assert.ok(links.length >= 5);
    for (const url of links) assert.match(url, /^https:\/\//, url);
    assert.ok(links.includes(GITHUB_URL));
    for (const code of OTHERS) assert.ok(links.includes(urlOf(code)), `${code} is not in llms.txt`);
  });
});
