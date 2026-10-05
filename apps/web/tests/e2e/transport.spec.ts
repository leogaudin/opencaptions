import { expect, type Locator, test } from "@playwright/test";
import { MOCK_PROJECT_ID, mockTranscribedProject, type Transcript } from "./helpers/mockProject";

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
      text: "one two",
      words: [
        { text: "one", start: 0, end: 1, confidence: 1 },
        { text: "two", start: 1, end: 2, confidence: 1 },
      ],
    },
  ],
};

const paused = (video: Locator) => video.evaluate((v) => (v as HTMLVideoElement).paused);
const time = (video: Locator) => video.evaluate((v) => (v as HTMLVideoElement).currentTime);

test.describe("Transport", () => {
  let video: Locator;

  test.beforeEach(async ({ page }) => {
    await mockTranscribedProject(page, "Transport test", { transcript: TRANSCRIPT });
    await page.goto(`/projects/${MOCK_PROJECT_ID}`);
    video = page.locator("video");
    await expect(video).toHaveCount(1);
    await expect(page.getByTestId("transport-play")).toBeEnabled();
  });

  test("the play button plays and pauses, and the timecode shows the length", async ({ page }) => {
    await expect(page.getByTestId("transport-time")).toContainText("/ 0:04.00");
    await page.getByTestId("transport-play").click();
    await expect.poll(() => paused(video)).toBe(false);
    await expect(page.getByTestId("transport-play")).toHaveAccessibleName("Pause");
    await page.getByTestId("transport-play").click();
    await expect.poll(() => paused(video)).toBe(true);
  });

  test("Space plays and pauses, and the arrows step a frame, away from text fields", async ({
    page,
  }) => {
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await page.keyboard.press("Space");
    await expect.poll(() => paused(video)).toBe(false);
    await page.keyboard.press("Space");
    await expect.poll(() => paused(video)).toBe(true);

    await page.evaluate(() => {
      (document.querySelector("video") as HTMLVideoElement).currentTime = 1;
    });
    await page.keyboard.press("ArrowRight");
    await expect.poll(() => time(video)).toBeCloseTo(1 + 1 / 30, 1);
    await page.keyboard.press("ArrowLeft");
    await page.keyboard.press("ArrowLeft");
    await expect.poll(() => time(video)).toBeCloseTo(1 - 1 / 30, 1);
  });

  test("a tap on the picture plays it; mute toggles", async ({ page }) => {
    await video.click({ position: { x: 20, y: 20 } });
    await expect.poll(() => paused(video)).toBe(false);
    await video.click({ position: { x: 20, y: 20 } });
    await expect.poll(() => paused(video)).toBe(true);

    await page.getByRole("button", { name: "Mute" }).click();
    await expect.poll(() => video.evaluate((v) => (v as HTMLVideoElement).muted)).toBe(true);
    await expect(page.getByRole("button", { name: "Unmute" })).toBeVisible();
  });
});
