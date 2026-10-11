import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { before, describe, test } from "node:test";
import { type DemoHtml, fillPage, renderDemo } from "../../scripts/demo-prerender.ts";
import { DOCS_URL, GITHUB_URL, SITE_URL } from "../../src/demo/links.ts";

/**
 * What the public demo tells search engines, link previews and AI assistants. The page is rendered the
 * way the build renders it (no browser), so these read what a crawler that runs no script reads, and
 * check that every file the page points to is there.
 */
const PUBLIC = new URL("../../demo-public/", import.meta.url);
const read = (name: string) => readFileSync(new URL(name, PUBLIC), "utf8");

let page: DemoHtml;
let html: string;

before(async () => {
  page = await renderDemo();
  html = fillPage(readFileSync(new URL("../../demo.html", import.meta.url), "utf8"), page);
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

const metaContent = (attrName: string, key: string): string => {
  const tag = html.match(new RegExp(`<meta ${attrName}="${key}" content="([^"]*)"`));
  assert.ok(tag, `no <meta ${attrName}="${key}">`);
  return (tag[1] as string).replace(/&amp;/g, "&").replace(/&quot;/g, '"');
};

/** Width and height of a PNG, from its header. */
function pngSize(name: string): [number, number] {
  const bytes = readFileSync(new URL(name, PUBLIC));
  assert.equal(bytes.subarray(1, 4).toString(), "PNG", `${name} is not a PNG`);
  return [bytes.readUInt32BE(16), bytes.readUInt32BE(20)];
}

describe("demo page: head", () => {
  test("a title and a description that fit a search result", () => {
    const title = html.match(/<title>([^<]*)<\/title>/)?.[1] ?? "";
    assert.ok(title.length >= 30 && title.length <= 60, `title is ${title.length} characters`);
    assert.match(title, /OpenCaptions/);
    const description = metaContent("name", "description");
    assert.ok(
      description.length >= 110 && description.length <= 160,
      `description is ${description.length} characters`,
    );
  });

  test("one canonical address, the one the cards and the sitemap name", () => {
    assert.equal(SITE_URL, "https://opencaptions.app/");
    assert.equal(html.match(/<link rel="canonical" href="([^"]*)"/)?.[1], SITE_URL);
    assert.equal(metaContent("property", "og:url"), SITE_URL);
    assert.match(read("sitemap.xml"), new RegExp(`<loc>${SITE_URL}</loc>`));
  });

  test("a link preview: Open Graph and Twitter cards with a 1200x630 picture", () => {
    const image = metaContent("property", "og:image");
    assert.equal(image, `${SITE_URL}og.png`);
    assert.equal(metaContent("name", "twitter:image"), image);
    assert.equal(metaContent("name", "twitter:card"), "summary_large_image");
    assert.equal(metaContent("property", "og:title"), metaContent("name", "twitter:title"));
    assert.ok(metaContent("property", "og:image:alt").length > 20);
    assert.deepEqual(pngSize("og.png"), [1200, 630]);
  });

  test("the icons are linked, and there", () => {
    const linked = [
      ...html.matchAll(/<link rel="(?:icon|apple-touch-icon|manifest)"[^>]*href="\/([^"]+)"/g),
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

describe("demo page: what a crawler that runs no script reads", () => {
  test("one h1, and headings that go down one level at a time", () => {
    const levels = [...page.body.matchAll(/<h([1-6])[\s>]/g)].map((m) => Number(m[1]));
    assert.equal(levels.filter((l) => l === 1).length, 1);
    assert.equal(levels[0], 1);
    for (let i = 1; i < levels.length; i++) {
      assert.ok((levels[i] as number) <= (levels[i - 1] as number) + 1, `heading ${i}: ${levels}`);
    }
    assert.ok(levels.filter((l) => l === 2).length >= 4, "sections have their own h2");
  });

  test("the words that people search for are in the page", () => {
    const text = words(page.body).toLowerCase();
    for (const phrase of [
      "animated captions",
      "word-by-word",
      "open source",
      "whisper",
      "iphone",
      "about 100 languages",
      "self-host",
      "docker compose up -d",
      "agpl-3.0",
      "srt",
      "green screen",
    ]) {
      assert.ok(text.includes(phrase), `"${phrase}" is not in the page`);
    }
  });

  test("every image has alt text, and every outside link is https", () => {
    for (const [tag] of page.body.matchAll(/<img[^>]*>/g)) assert.match(tag, /\salt="/, tag);
    for (const [, url] of page.body.matchAll(/href="(https?:[^"]*)"/g)) {
      assert.match(url as string, /^https:\/\//, url);
    }
  });

  test("the docs link points at pages that exist (the repository's), not at a site not yet built", () => {
    assert.ok(DOCS_URL.startsWith(GITHUB_URL));
    assert.ok(!page.body.includes("docs.opencaptions.app"));
  });
});

describe("demo page: structured data", () => {
  const graph = (): { "@type": string }[] => {
    const raw = html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)?.[1];
    assert.ok(raw, "no JSON-LD");
    return (JSON.parse(raw) as { "@graph": { "@type": string }[] })["@graph"];
  };

  test("an application, a site and a FAQ", () => {
    const types = graph().map((n) => n["@type"]);
    assert.deepEqual(types, ["SoftwareApplication", "WebSite", "FAQPage"]);
  });

  test("the FAQ in the data is the FAQ on the page, word for word", () => {
    const faq = graph().find((n) => n["@type"] === "FAQPage") as unknown as {
      mainEntity: { name: string; acceptedAnswer: { text: string } }[];
    };
    assert.ok(faq.mainEntity.length >= 6);
    const text = words(page.body);
    for (const { name, acceptedAnswer } of faq.mainEntity) {
      assert.ok(text.includes(name), `question not on the page: ${name}`);
      assert.ok(text.includes(acceptedAnswer.text), `answer not on the page: ${name}`);
    }
  });

  test("the application is free and open source, and says so", () => {
    const app = graph()[0] as unknown as Record<string, unknown>;
    assert.equal((app.offers as { price: string }).price, "0");
    assert.match(String(app.license), /agpl/);
    assert.equal(app.url, SITE_URL);
  });
});

describe("demo page: files for crawlers", () => {
  test("robots.txt welcomes everyone, names AI crawlers, and points at the sitemap", () => {
    const robots = read("robots.txt");
    assert.match(robots, /^User-agent: \*\nAllow: \/$/m);
    assert.ok(!/^Disallow:\s*\/\s*$/m.test(robots), "nothing is blocked");
    for (const bot of ["GPTBot", "ClaudeBot", "PerplexityBot", "Google-Extended"]) {
      assert.match(robots, new RegExp(`^User-agent: ${bot}$`, "m"));
    }
    assert.match(robots, new RegExp(`^Sitemap: ${SITE_URL}sitemap.xml$`, "m"));
  });

  test("llms.txt follows the format: a title, a summary, and absolute links", () => {
    const llms = read("llms.txt");
    assert.match(llms, /^# OpenCaptions\n\n> .{80,}/);
    const links = [...llms.matchAll(/\]\(([^)]+)\)/g)].map((m) => m[1] as string);
    assert.ok(links.length >= 5);
    for (const url of links) assert.match(url, /^https:\/\//, url);
    assert.ok(links.includes(GITHUB_URL));
  });

  test("the sitemap is XML with one url per page", () => {
    const sitemap = read("sitemap.xml");
    assert.match(sitemap, /^<\?xml version="1\.0" encoding="UTF-8"\?>/);
    assert.equal([...sitemap.matchAll(/<url>/g)].length, 1);
  });
});
