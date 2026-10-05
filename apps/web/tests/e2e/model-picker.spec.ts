import { expect, test } from "@playwright/test";

import {
  completedTranscriptionJob,
  MOCK_PROJECT_ID,
  mockTranscribedProject,
} from "./helpers/mockProject";

const PROJECT_ID = MOCK_PROJECT_ID;

test.describe("Local Whisper model selection", () => {
  test("selected upload model is sent while OpenAI receives no local model", async ({ page }) => {
    const realSettings = await (await page.request.get("/api/v1/settings")).json();
    await page.route("**/api/v1/settings", (route) =>
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          ...realSettings,
          transcription: { ...realSettings.transcription, openai_configured: true },
        }),
      }),
    );
    await page.route("**/api/v1/projects", async (route) => {
      if (route.request().method() !== "POST") return route.fallback();
      await route.fulfill({
        status: 201,
        contentType: "application/json",
        body: JSON.stringify({ id: PROJECT_ID }),
      });
    });

    const bodies: Record<string, unknown>[] = [];
    await page.route(`**/api/v1/projects/${PROJECT_ID}/transcribe`, async (route) => {
      bodies.push(route.request().postDataJSON() as Record<string, unknown>);
      await route.fulfill({
        status: 202,
        contentType: "application/json",
        body: JSON.stringify(completedTranscriptionJob()),
      });
    });

    await page.goto("/upload");
    await page.getByTestId("file-input").setInputFiles({
      name: "model-test.mp4",
      mimeType: "video/mp4",
      buffer: Buffer.from("not decoded because upload is intercepted"),
    });
    await page.getByTestId("model-select").selectOption("small");
    await page.getByTestId("submit").click();
    await expect.poll(() => bodies.length).toBe(1);
    expect(bodies[0]).toMatchObject({ provider: "local", model: "small", language: "auto" });

    await page.goto("/upload");
    await page.getByTestId("file-input").setInputFiles({
      name: "openai-test.mp4",
      mimeType: "video/mp4",
      buffer: Buffer.from("intercepted"),
    });
    await page.locator("select#provider").selectOption("openai");
    await page.getByTestId("submit").click();
    await expect.poll(() => bodies.length).toBe(2);
    expect(bodies[1]).toMatchObject({ provider: "openai", language: "auto" });
    expect(bodies[1]).not.toHaveProperty("model");

    await page.goto("/upload");
    await page.getByTestId("mode-url").click();
    await page.getByTestId("video-url").fill("https://example.com/video.mp4");
    await page.getByTestId("title").fill("URL model test");
    await page.getByTestId("model-select").selectOption("small");
    await page.getByTestId("submit").click();
    await expect.poll(() => bodies.length).toBe(3);
    expect(bodies[2]).toMatchObject({ provider: "local", model: "small", language: "auto" });
  });

  test("unchanged editor picker preserves defaults; changed picker selects local model", async ({
    page,
  }) => {
    await mockTranscribedProject(page, "Model picker test");
    const bodies: Record<string, unknown>[] = [];
    await page.route(`**/api/v1/projects/${PROJECT_ID}/transcribe`, async (route) => {
      bodies.push(route.request().postDataJSON() as Record<string, unknown>);
      await route.fulfill({
        status: 202,
        contentType: "application/json",
        body: JSON.stringify(completedTranscriptionJob()),
      });
    });

    await page.goto(`/projects/${PROJECT_ID}`);
    await page.getByTestId("retranscribe").filter({ visible: true }).first().click();
    await page.getByTestId("retranscribe-confirm").click();
    await expect.poll(() => bodies.length).toBe(1);
    expect(bodies[0]).toEqual({});

    // Reload resets the mocked completed job held by the editor store.
    await page.reload();
    // Pick a curated model that is NOT the live default, so this is a genuine
    // change: selecting the already-selected option fires no change event.
    const settings = await (await page.request.get("/api/v1/settings")).json();
    const changedModel = settings.transcription.model === "small" ? "base" : "small";
    await page.getByTestId("retranscribe").filter({ visible: true }).first().click();
    await page.getByTestId("retranscribe-model-select").selectOption(changedModel);
    await page.getByTestId("retranscribe-confirm").click();
    await expect.poll(() => bodies.length).toBe(2);
    expect(bodies[1]).toEqual({ provider: "local", model: changedModel });
  });
});
