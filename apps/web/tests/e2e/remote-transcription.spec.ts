import { expect, test } from "@playwright/test";

import { completedTranscriptionJob, MOCK_PROJECT_ID } from "./helpers/mockProject";

/** The real settings with a remote OpenCaptions server configured, as the deployment would. */
async function withRemote(page: import("@playwright/test").Page): Promise<void> {
  const real = await (await page.request.get("/api/v1/settings")).json();
  await page.route("**/api/v1/settings", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        ...real,
        transcription: {
          ...real.transcription,
          remote_configured: true,
          remote_url: "https://gpu.example.org",
        },
      }),
    }),
  );
}

test.describe("Transcribing on another OpenCaptions server", () => {
  test("it is offered only when configured, names the host, and sends no model", async ({
    page,
  }) => {
    await page.goto("/upload");
    await expect(page.locator("select#provider option[value=opencaptions]")).toBeDisabled();

    await withRemote(page);
    await page.route("**/api/v1/projects", async (route) => {
      if (route.request().method() !== "POST") return route.fallback();
      await route.fulfill({
        status: 201,
        contentType: "application/json",
        body: JSON.stringify({ id: MOCK_PROJECT_ID }),
      });
    });
    const bodies: Record<string, unknown>[] = [];
    await page.route(`**/api/v1/projects/${MOCK_PROJECT_ID}/transcribe`, async (route) => {
      bodies.push(route.request().postDataJSON() as Record<string, unknown>);
      await route.fulfill({
        status: 202,
        contentType: "application/json",
        body: JSON.stringify(completedTranscriptionJob()),
      });
    });

    await page.goto("/upload");
    await page.getByTestId("file-input").setInputFiles({
      name: "remote.mp4",
      mimeType: "video/mp4",
      buffer: Buffer.from("intercepted"),
    });
    await page.locator("select#provider").selectOption("opencaptions");
    await expect(page.getByText(/your audio will be sent to gpu\.example\.org/i)).toBeVisible();
    await page.getByTestId("submit").click();
    await expect.poll(() => bodies.length).toBe(1);
    expect(bodies[0]).toMatchObject({ provider: "opencaptions", language: "auto" });
    expect(bodies[0]).not.toHaveProperty("model");
  });

  test("the account page tests the connection and says what happened", async ({ page }) => {
    await page.goto("/account");
    await expect(page.getByTestId("transcription-service")).toHaveCount(0);

    await withRemote(page);
    let answer: object = {
      ok: true,
      instance_name: "Home GPU",
      api_version: 1,
      models: [{ id: "large-v3", label: "Large v3" }],
    };
    await page.route("**/api/v1/settings/transcription/test", (route) =>
      route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(answer) }),
    );
    await page.goto("/account");
    await page.getByRole("button", { name: "Test connection" }).click();
    await expect(page.getByTestId("remote-test-ok")).toContainText("Connected to Home GPU");
    await expect(page.getByTestId("remote-test-ok")).toContainText("Large v3");

    answer = { ok: false, error: "The remote instance rejected the key (revoked or wrong)." };
    await page.getByRole("button", { name: "Test connection" }).click();
    await expect(page.getByTestId("remote-test-error")).toContainText("rejected the key");
  });

  test("a new key comes with a link that connects the phone app to this server", async ({
    page,
  }) => {
    await page.goto("/account");
    await page.getByLabel("Key name").fill("iPhone");
    await page.getByRole("button", { name: "Create key" }).click();
    const link = page.getByTestId("new-api-key").locator("code").last();
    await expect(link).toContainText("opencaptions://connect?url=");
    await expect(link).toContainText(encodeURIComponent(new URL(page.url()).origin));
    await expect(link).toContainText("&key=oc_");
    // The same link as a QR code, which the phone's Camera app can read.
    const qr = page.getByTestId("pairing-qr");
    await expect(qr).toBeVisible();
    await expect(qr).toHaveAttribute("src", /^data:image\/gif;base64,/);
  });
});
