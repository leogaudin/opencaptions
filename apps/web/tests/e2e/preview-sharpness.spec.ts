import { expect, test } from "@playwright/test";
import { MOCK_PROJECT_ID, mockTranscribedProject } from "./helpers/mockProject";

test.describe("Caption preview sharpness", () => {
  test("a low-resolution video still gets captions drawn at the size they are shown", async ({
    page,
  }) => {
    // The captions are vector: their sharpness belongs to the screen, not to the video's pixels.
    await mockTranscribedProject(page, "Small", { videoSize: { width: 320, height: 240 } });
    await page.setViewportSize({ width: 1400, height: 900 });
    await page.goto(`/projects/${MOCK_PROJECT_ID}`);

    const preview = page.getByTestId("caption-preview");
    await expect(preview).toBeVisible();
    const shown = await preview.boundingBox();
    expect(shown?.height ?? 0).toBeGreaterThan(400);
    const canvas = preview.locator("canvas");
    await expect
      .poll(() => canvas.evaluate((c: HTMLCanvasElement) => c.height))
      .toBeGreaterThanOrEqual(Math.round((shown?.height ?? 0) * 0.9));
  });
});
