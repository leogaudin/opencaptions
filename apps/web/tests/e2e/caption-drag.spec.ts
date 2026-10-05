import { expect, test } from "@playwright/test";
import { MOCK_PROJECT_ID, mockTranscribedProject, type Transcript } from "./helpers/mockProject";

const word = (text: string, start: number, end: number) => ({ text, start, end, confidence: 1 });

// A caption is showing at t=0, where a paused video starts.
const TRANSCRIPT: Transcript = {
  schema_version: 1,
  language: "en",
  language_detection: "manual",
  duration: 4,
  segments: [
    {
      id: "a",
      start: 0,
      end: 2,
      text: "one two three",
      words: [word("one", 0, 0.7), word("two", 0.7, 1.4), word("three", 1.4, 2)],
    },
  ],
};

test.describe("Caption on the preview", () => {
  let saved: () => Record<string, unknown>;
  const position = () => saved().style_config as { position_x: number; position_y: number } | null;

  test.beforeEach(async ({ page }) => {
    saved = await mockTranscribedProject(page, "Drag test", { transcript: TRANSCRIPT });
    await page.goto(`/projects/${MOCK_PROJECT_ID}`);
  });

  test("dragging the caption moves it by the whole drag, not one frame of it", async ({ page }) => {
    const preview = page.getByTestId("caption-preview").filter({ visible: true });
    const handle = page.getByTestId("caption-handle").filter({ visible: true });
    await expect(handle).toBeVisible();
    const frame = await preview.boundingBox();
    const box = await handle.boundingBox();
    if (!frame || !box) throw new Error("preview not laid out");

    const [dx, dy] = [90, -120];
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width / 2 + dx, box.y + box.height / 2 + dy, { steps: 12 });
    await page.mouse.up();

    // Default position is (0.5, 0.84). Many moves arrive; a drag that dies after the
    // first scene update would move about a twelfth of this.
    await expect.poll(() => position()?.position_x ?? 0.5).toBeCloseTo(0.5 + dx / frame.width, 1);
    await expect
      .poll(() => position()?.position_y ?? 0.84)
      .toBeCloseTo(0.84 + dy / frame.height, 1);
    expect(Math.abs((position()?.position_x ?? 0.5) - 0.5)).toBeGreaterThan(
      (0.6 * Math.abs(dx)) / frame.width,
    );
  });
});
