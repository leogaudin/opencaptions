import { expect, type Locator, test } from "@playwright/test";
import { MOCK_PROJECT_ID, mockTranscribedProject } from "./helpers/mockProject";

/**
 * Picks a color as the browser's own picker does: the value is set below React's tracking of it, then
 * an `input` event is fired. (`fill` sets it through React's tracker, and React then sees no change.)
 */
async function pickColor(input: Locator, hex: string) {
  await input.evaluate((el: HTMLInputElement, value) => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set?.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
  }, hex);
}

test.describe("Highlight colors", () => {
  let saved: () => Record<string, unknown>;

  test.beforeEach(async ({ page }) => {
    saved = await mockTranscribedProject(page, "Colors");
    await page.goto(`/projects/${MOCK_PROJECT_ID}`);
    await page.getByTestId("style-tab-text").click();
  });

  const savedColors = () =>
    (saved().style_config as { highlight_colors?: string[] } | null)?.highlight_colors;

  test("changing the highlight color is saved and is what the preview draws", async ({ page }) => {
    await pickColor(page.getByTestId("highlight-color-0"), "#ff0000");
    await expect.poll(savedColors).toEqual(["#FF0000"]);

    // The default look is a box on the word being said; at the start of the clip it is on "Hello".
    const canvas = page.getByTestId("caption-preview").locator("canvas");
    await expect
      .poll(() =>
        canvas.evaluate((c: HTMLCanvasElement) => {
          const { data } = c.getContext("2d")?.getImageData(0, 0, c.width, c.height) ?? {
            data: new Uint8ClampedArray(),
          };
          let red = 0;
          for (let i = 0; i < data.length; i += 4) {
            if ((data[i] ?? 0) > 200 && (data[i + 1] ?? 255) < 60 && (data[i + 3] ?? 0) > 20) red++;
          }
          return red;
        }),
      )
      .toBeGreaterThan(200);
  });

  test("colors are added, up to four, and removed, and the first cannot be", async ({ page }) => {
    await expect(page.getByTestId("highlight-color-remove-0")).toHaveCount(0);
    const add = page.getByTestId("highlight-color-add");
    for (const n of [2, 3, 4]) {
      await add.click();
      await expect.poll(() => savedColors()?.length).toBe(n);
    }
    await expect(add).toHaveCount(0);

    await pickColor(page.getByTestId("highlight-color-1"), "#00ff00");
    await expect.poll(() => savedColors()?.[1]).toBe("#00FF00");
    await page.getByTestId("highlight-color-remove-1").click();
    await expect.poll(() => savedColors()?.length).toBe(3);
    await expect(add).toBeVisible();
  });
});
