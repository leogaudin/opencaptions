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
    // Registered after the helper's, so it wins: a 1080 × 1920, 30 fps video.
    await page.route(`**/api/v1/projects/${MOCK_PROJECT_ID}/exports`, (route) =>
      route.fulfill({
        json: {
          video: [format("mp4", "MP4 (H.264)"), format("mov", "MOV (ProRes)")],
          choices: {
            resolutions: ["original", "720"],
            frame_rates: ["original", "60"],
            source_fps: 30,
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
    await page.getByTestId("download-open").click();
    const options = page.getByTestId("download-options");
    await expect(options.getByRole("button", { name: "Original" })).toBeVisible();
    await expect(options.getByRole("button", { name: "4K" })).toHaveCount(0);
    await expect(options.getByRole("button", { name: "30 fps" })).toBeVisible();
    await expect(options.getByRole("button", { name: /best|balanced/i })).toHaveCount(0);
    await options.getByRole("button", { name: "720p" }).click();
    await options.getByRole("button", { name: "60 fps" }).click();
    const saved = page.waitForEvent("download");
    await page.getByRole("radio", { name: /MP4 \(H\.264\)/ }).check({ force: true });
    await page.getByTestId("download-confirm").click();
    const download = await saved;

    expect(requested[0]).toEqual({
      format: "mp4",
      resolution: "720",
      frame_rate: "60",
      green_screen: false,
    });
    const query = new URL(download.url()).searchParams;
    expect(Object.fromEntries(query)).toEqual({
      resolution: "720",
      frame_rate: "60",
      green_screen: "false",
    });

    await page.reload();
    await page.getByTestId("download-open").click();
    await expect(
      page.getByTestId("download-options").getByRole("button", { name: "720p" }),
    ).toHaveClass(/bg-primary/);
  });

  test("a green screen is asked for with the download and is not remembered", async ({ page }) => {
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
    await page.getByTestId("download-open").click();
    const options = page.getByTestId("download-options");
    await options.getByRole("button", { name: "Green screen" }).click();
    await expect(options.getByText(/key out in your editor/)).toBeVisible();
    const saved = page.waitForEvent("download");
    await page.getByRole("radio", { name: /MP4 \(H\.264\)/ }).check({ force: true });
    await page.getByTestId("download-confirm").click();
    const download = await saved;

    expect(requested[0]?.green_screen).toBe(true);
    expect(new URL(download.url()).searchParams.get("green_screen")).toBe("true");

    // Not remembered: a later save must not be captions only by surprise.
    await page.reload();
    await page.getByTestId("download-open").click();
    await expect(
      page.getByTestId("download-options").getByRole("button", { name: "Video" }),
    ).toHaveClass(/bg-primary/);
  });
});
