import { expect, type Page, test } from "@playwright/test";

/**
 * Hosted mode is decided by the API and merely reflected by the SPA, so these
 * tests simulate a hosted instance at the network boundary: the real public
 * bootstrap (`/auth/status`) and settings responses are fetched, then rewritten
 * the way the API itself rewrites them when HOSTED_MODE=true. The self-hosted
 * default is covered by the smoke tests, which assert the same surfaces exist.
 */

import { MOCK_PROJECT_ID, mockTranscribedProject } from "./helpers/mockProject";

const PROJECT_ID = MOCK_PROJECT_ID;

async function simulateHostedInstance(page: Page) {
  // Fetch the real responses once, then answer every request from memory:
  // an upstream fetch inside a route handler can outlive the test and fail
  // during teardown, which would report a false negative.
  const status = await (await page.request.get("/api/v1/auth/status")).json();
  const settings = await (await page.request.get("/api/v1/settings")).json();
  await page.route("**/api/v1/auth/status", (route) =>
    route.fulfill({ json: { ...status, hosted_mode: true } }),
  );
  await page.route("**/api/v1/settings", (route) =>
    route.fulfill({
      json: {
        ...settings,
        hosted_mode: true,
        transcription: {
          ...settings.transcription,
          available_models: [],
          model: null,
          device: null,
          openai_configured: false,
        },
      },
    }),
  );
}

test.describe("Hosted mode", () => {
  test("hides the Information button while keeping the rest of the header", async ({ page }) => {
    await simulateHostedInstance(page);
    await page.goto("/");
    await expect(page.getByTestId("user-menu")).toBeVisible();
    await expect(page.getByTestId("about-trigger")).toHaveCount(0);
  });

  test("hides provider and model choice on new project and in the editor", async ({ page }) => {
    await simulateHostedInstance(page);
    await mockTranscribedProject(page, "Hosted mode test");

    await page.goto("/upload");
    await expect(page.getByTestId("title")).toBeVisible();
    await expect(page.locator("select#provider")).toHaveCount(0);
    await expect(page.getByTestId("model-select")).toHaveCount(0);

    await page.goto(`/projects/${PROJECT_ID}`);
    // The timing offset is on the style panel's Timing tab.
    await page.getByTestId("style-tab-timing").click();
    await expect(page.getByTestId("caption-offset-control")).toBeVisible();
    await page.getByTestId("retranscribe").click();
    await expect(page.getByTestId("retranscribe-dialog")).toBeVisible();
    await expect(page.getByTestId("retranscribe-model-select")).toHaveCount(0);
  });
});
