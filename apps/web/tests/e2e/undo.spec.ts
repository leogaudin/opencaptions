import { expect, test } from "@playwright/test";
import { MOCK_PROJECT_ID, mockTranscribedProject } from "./helpers/mockProject";

// The transcript's edits are covered with the timeline and the text dialog.
test("undo and redo put a style change back and forward, as the phone's do", async ({ page }) => {
  const saved = await mockTranscribedProject(page, "Style undo");
  await page.goto(`/projects/${MOCK_PROJECT_ID}`);
  await expect(page.getByTestId("caption-handle")).toBeVisible();
  const strokeWidth = () =>
    (saved().style_config as { stroke_width?: number } | null)?.stroke_width;
  await expect(page.getByTestId("undo")).toBeDisabled();

  // A preset changes many fields at once and is one step. Boom has a 10 outline.
  await page.locator("[data-testid='preset-builtin:boom']").click();
  await expect.poll(strokeWidth).toBe(10);
  await page.getByTestId("undo").click();
  await expect.poll(strokeWidth).toBe(0);
  await page.getByTestId("redo").click();
  await expect.poll(strokeWidth).toBe(10);
});
