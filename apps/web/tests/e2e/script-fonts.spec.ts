import { expect, test } from "@playwright/test";
import { MOCK_PROJECT_ID, mockTranscribedProject, type Transcript } from "./helpers/mockProject";

const transcript = (text: string, language: string): Transcript => ({
  schema_version: 1,
  language,
  language_detection: "manual",
  duration: 2,
  segments: [
    {
      id: "a",
      start: 0,
      end: 2,
      text,
      words: [{ text, start: 0, end: 2, confidence: 1 }],
    },
  ],
});

/** The font files the engine's own folder served to this page. */
function bundledFontRequests(page: import("@playwright/test").Page): string[] {
  const files: string[] = [];
  page.on("request", (request) => {
    const match = /\/engine\/fonts\/([^/?]+)$/.exec(new URL(request.url()).pathname);
    if (match?.[1]) files.push(decodeURIComponent(match[1]));
  });
  return files;
}

test.describe("The fonts of other scripts", () => {
  test("an English caption fetches no script face", async ({ page }) => {
    const fetched = bundledFontRequests(page);
    await mockTranscribedProject(page, "English", { transcript: transcript("hello", "en") });
    await page.goto(`/projects/${MOCK_PROJECT_ID}`);
    await expect(page.getByTestId("caption-handle")).toBeVisible();
    expect(fetched.length).toBeGreaterThan(0);
    expect(fetched.filter((f) => f.startsWith("NotoSans"))).toEqual([]);
  });

  test("an Arabic caption fetches its face, and only that one, and draws with it", async ({
    page,
  }) => {
    const fetched = bundledFontRequests(page);
    await mockTranscribedProject(page, "Arabic", { transcript: transcript("مرحبا", "ar") });
    await page.goto(`/projects/${MOCK_PROJECT_ID}`);
    await expect(page.getByTestId("caption-handle")).toBeVisible();
    expect(fetched.filter((f) => f.startsWith("NotoSans"))).toEqual(["NotoSansArabic.ttf"]);
    // Drawn: the overlay has ink in it (a missing face would draw empty boxes, still ink, but the
    // caption's box is laid out only once the engine has a scene, which waits for the face).
    const canvas = page.getByTestId("caption-preview").locator("canvas");
    await expect
      .poll(() =>
        canvas.evaluate((c: HTMLCanvasElement) => {
          const data = c.getContext("2d")?.getImageData(0, 0, c.width, c.height).data;
          return data ? data.some((value, i) => i % 4 === 3 && value > 0) : false;
        }),
      )
      .toBe(true);
  });
});
