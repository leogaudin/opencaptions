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

  test("the picker keeps the colors it is given while it is open", async ({ page }) => {
    // The browser's picker stays open and sends a color per move. If the page wrote the style's
    // (older) color back into the input after each, the picker would be put back and drop the choice.
    const kept = await page.getByTestId("highlight-color-0").evaluate((el: HTMLInputElement) => {
      const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;
      const afterEach: string[] = [];
      for (const hex of ["#112233", "#445566", "#778899"]) {
        set?.call(el, hex);
        el.dispatchEvent(new Event("input", { bubbles: true }));
        afterEach.push(el.value.toUpperCase());
      }
      return afterEach;
    });
    expect(kept).toEqual(["#112233", "#445566", "#778899"]);
    await expect.poll(savedColors).toEqual(["#778899"]);
    await expect(page.getByTestId("highlight-color-0")).toHaveValue("#778899");
  });

  test("changing the highlight color is saved and is what the preview draws", async ({ page }) => {
    await pickColor(page.getByTestId("highlight-color-0"), "#ff0000");
    await expect.poll(savedColors).toEqual(["#FF0000"]);

    // The default look is a box on the word being said; at the start of the clip it is on "Hello",
    // still fading in, so the box is faint there (any visible alpha will do: its colour is what is tested).
    const canvas = page.getByTestId("caption-preview").locator("canvas");
    await expect
      .poll(() =>
        canvas.evaluate((c: HTMLCanvasElement) => {
          const { data } = c.getContext("2d")?.getImageData(0, 0, c.width, c.height) ?? {
            data: new Uint8ClampedArray(),
          };
          let red = 0;
          for (let i = 0; i < data.length; i += 4) {
            if ((data[i] ?? 0) > 200 && (data[i + 1] ?? 255) < 60 && (data[i + 3] ?? 0) > 4) red++;
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
