import { expect, test } from "@playwright/test";
import { MOCK_PROJECT_ID, mockTranscribedProject } from "./helpers/mockProject";

const format = (id: string, label: string) => ({
  format: id,
  label,
  ready: false,
  download_url: `/api/v1/projects/${MOCK_PROJECT_ID}/download/${id}`,
  note: null,
});

test.describe("Download options", () => {
  test.beforeEach(async ({ page }) => {
    await mockTranscribedProject(page, "Options");
    // Registered after the helper's, so it wins: a 1080 × 1920, 60 fps video.
    await page.route(`**/api/v1/projects/${MOCK_PROJECT_ID}/exports`, (route) =>
      route.fulfill({
        json: {
          video: [format("mp4", "MP4 (H.264)"), format("mov", "MOV (ProRes)")],
          choices: {
            resolutions: ["original", "720"],
            frame_rates: ["original", "30"],
            source_fps: 60,
          },
          subtitles: { srt: "", vtt: "", json_url: "" },
        },
      }),
    );
  });

  test("the chosen size and frame rate go with the download, and are remembered", async ({
    page,
  }) => {
    const requested: Record<string, unknown>[] = [];
    await page.route(`**/api/v1/projects/${MOCK_PROJECT_ID}/download`, async (route) => {
      requested.push(route.request().postDataJSON() as Record<string, unknown>);
      await route.fulfill({
        json: { ready: true, download_url: `/api/v1/projects/${MOCK_PROJECT_ID}/download/mp4` },
      });
    });
    await page.route(`**/api/v1/projects/${MOCK_PROJECT_ID}/download/mp4?*`, (route) =>
      route.fulfill({ body: "video", contentType: "video/mp4" }),
    );

    await page.goto(`/projects/${MOCK_PROJECT_ID}`);
    await page.getByRole("button", { name: "Choose video format" }).click();
    const options = page.getByTestId("download-options");
    await expect(options.getByRole("button", { name: "Original" })).toBeVisible();
    await expect(options.getByRole("button", { name: "4K" })).toHaveCount(0);
    await expect(options.getByRole("button", { name: "60 fps" })).toBeVisible();
    await expect(options.getByRole("button", { name: /best|balanced/i })).toHaveCount(0);
    await options.getByRole("button", { name: "720p" }).click();
    await options.getByRole("button", { name: "30 fps" }).click();
    const saved = page.waitForEvent("download");
    await page.getByRole("menuitem", { name: /MP4 \(H\.264\)/ }).click();
    const download = await saved;

    expect(requested[0]).toEqual({
      format: "mp4",
      resolution: "720",
      frame_rate: "30",
    });
    const query = new URL(download.url()).searchParams;
    expect(Object.fromEntries(query)).toEqual({
      resolution: "720",
      frame_rate: "30",
    });

    await page.reload();
    await page.getByRole("button", { name: "Choose video format" }).click();
    await expect(
      page.getByTestId("download-options").getByRole("button", { name: "720p" }),
    ).toHaveClass(/bg-primary/);
  });
});
