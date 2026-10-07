import { expect, test } from "@playwright/test";
import { MOCK_PROJECT_ID, mockTranscribedProject } from "./helpers/mockProject";

test.describe("Caption style tabs", () => {
  test.beforeEach(async ({ page }) => {
    await mockTranscribedProject(page, "Tabs");
    await page.goto(`/projects/${MOCK_PROJECT_ID}`);
  });

  test("each tab shows its own controls, the presets first", async ({ page }) => {
    await expect(page.getByTestId("preset-strip")).toBeVisible();
    await expect(page.getByText("Font size")).toHaveCount(0);

    await page.getByTestId("style-tab-text").click();
    await expect(page.getByText("Font size")).toBeVisible();
    await expect(page.getByTestId("preset-strip")).toHaveCount(0);

    await page.getByTestId("style-tab-outline").click();
    await expect(page.getByText("Stroke width")).toBeVisible();

    await page.getByTestId("style-tab-timing").click();
    await expect(page.getByTestId("caption-offset-control")).toBeVisible();
  });

  test("a background and an animation are picked from tiles", async ({ page }) => {
    await page.getByTestId("style-tab-background").click();
    const solid = page.getByTestId("background-solid");
    await expect(page.getByTestId("background-none")).toHaveAttribute("aria-pressed", "true");
    await solid.click();
    await expect(solid).toHaveAttribute("aria-pressed", "true");
    // A background with no opacity would show nothing: choosing one makes it visible.
    await expect(page.getByText("Background opacity")).toBeVisible();

    await page.getByTestId("style-tab-animation").click();
    const pop = page.getByTestId("animation-word_pop");
    await pop.click();
    await expect(pop).toHaveAttribute("aria-pressed", "true");
  });
});
