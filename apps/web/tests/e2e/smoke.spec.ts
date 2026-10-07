import { expect, test } from "@playwright/test";

/**
 * Smoke E2E: verifies the frontend boots, the empty state renders, and the
 * upload page is reachable. The full upload→download pipeline needs real
 * transcription and rendering, so it is not part of this suite.
 */
test.describe("OpenCaptions UI", () => {
  // Every route requires a session. Authentication is performed once by the
  // `setup` project (see playwright.config.ts + auth.setup.ts); these tests
  // inherit that session via the project's storageState.

  test("home page loads and shows the empty-state hero or project list", async ({ page }) => {
    await page.goto("/");
    // The header is always present.
    await expect(page.getByRole("link", { name: "OpenCaptions" })).toBeVisible();
    // Either we see the empty-state primary action or a project list, both are
    // valid depending on whether this account owns any projects.
    const emptyCta = page.getByTestId("empty-new-project");
    const heading = page.getByRole("heading", { name: "Your projects" });
    await expect(emptyCta.or(heading).first()).toBeVisible();
  });

  test("upload page renders dropzone and form fields", async ({ page }) => {
    await page.goto("/upload");
    await expect(page.getByTestId("dropzone")).toBeVisible();
    await expect(page.getByTestId("title")).toBeVisible();
    await expect(page.getByTestId("submit")).toBeVisible();
  });

  test("local model picker shows the useful size ladder and configured default", async ({
    page,
  }) => {
    await page.goto("/upload");
    const picker = page.getByTestId("model-select");
    await expect(picker).toBeVisible();

    const response = await page.request.get("/api/v1/settings");
    expect(response.ok()).toBeTruthy();
    const settings = await response.json();
    await expect(picker).toHaveValue(settings.transcription.model);

    const values = await picker
      .locator("option")
      .evaluateAll((options) => options.map((option) => (option as HTMLOptionElement).value));
    expect(values).toEqual(["tiny", "base", "small", "medium", "large-v3", "large-v3-turbo"]);
  });

  test("nav from home to upload works", async ({ page }) => {
    await page.goto("/");
    // Header has a "New project" link
    await page.getByRole("link", { name: "New project" }).first().click();
    await expect(page).toHaveURL(/\/upload$/);
  });

  test("submit is disabled until a file is chosen", async ({ page }) => {
    await page.goto("/upload");
    await expect(page.getByTestId("submit")).toBeDisabled();
  });

  test("privacy disclosure shows when OpenAI provider is selected", async ({ page }) => {
    await page.goto("/upload");
    // OpenAI option may be disabled if the server has no key configured,
    // we still verify it renders. We try to select it; if disabled, the
    // disclosure won't appear and that's expected.
    const select = page.locator("select#provider");
    const openaiOption = page.locator('select#provider option[value="openai"]');
    const isDisabled = await openaiOption.isDisabled();
    if (!isDisabled) {
      await select.selectOption({ value: "openai" });
      await expect(page.getByText(/Privacy notice/)).toBeVisible();
    }
  });

  test("about dialog opens from header trigger and is dismissible", async ({ page }) => {
    await page.goto("/");
    const trigger = page.getByTestId("about-trigger");
    await expect(trigger).toBeVisible();
    await trigger.click();
    const dialog = page.getByTestId("about-dialog");
    await expect(dialog).toBeVisible();
    await expect(dialog.getByText("AGPL-3.0-only")).toBeVisible();
    // Dismiss with Escape
    await page.keyboard.press("Escape");
    await expect(dialog).not.toBeVisible();
  });

  test("user menu opens from header, shows the signed-in email, and dismisses with Escape", async ({
    page,
  }) => {
    await page.goto("/");
    const trigger = page.getByTestId("user-menu");
    await expect(trigger).toBeVisible();
    await trigger.click();
    const menu = page.getByTestId("user-menu-content");
    await expect(menu).toBeVisible();
    // It shows who you're signed in as and offers a way out.
    await expect(page.getByTestId("user-menu-email")).toBeVisible();
    await expect(page.getByTestId("logout")).toBeVisible();
    // Dismiss with Escape.
    await page.keyboard.press("Escape");
    await expect(menu).not.toBeVisible();
  });
});
