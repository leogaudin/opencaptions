import { expect, test } from "@playwright/test";

const ITEM = {
  id: "11111111-1111-4111-8111-111111111111",
  title: "Beach day",
  status: "transcribed",
  video_size_bytes: 12_400_000,
  created_at: "2026-10-01T10:00:00Z",
  updated_at: "2026-10-02T10:00:00Z",
};

test.describe("Home: size and rename", () => {
  test.beforeEach(async ({ page }) => {
    await page.route("**/api/v1/projects?*", (route) =>
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ items: [ITEM], total: 1, page: 1, per_page: 24 }),
      }),
    );
  });

  test("a card shows what the video weighs", async ({ page }) => {
    await page.goto("/");
    await expect(page.getByTestId("project-title")).toHaveText("Beach day");
    await expect(page.getByText("12.4 MB")).toBeVisible();
  });

  test("the title is renamed in place: Enter saves, Escape does not", async ({ page }) => {
    const bodies: Record<string, unknown>[] = [];
    await page.route(`**/api/v1/projects/${ITEM.id}`, async (route) => {
      if (route.request().method() !== "PATCH") return route.fallback();
      bodies.push(route.request().postDataJSON() as Record<string, unknown>);
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ ...ITEM, title: (bodies.at(-1) as { title: string }).title }),
      });
    });
    await page.goto("/");

    await page.getByTestId("project-title").click();
    await page.getByTestId("rename-input").fill("Cancelled name");
    await page.keyboard.press("Escape");
    await expect(page.getByTestId("project-title")).toHaveText("Beach day");
    expect(bodies).toHaveLength(0);

    await page.getByTestId("project-title").click();
    await page.getByTestId("rename-input").fill("  Summer trip ");
    await page.keyboard.press("Enter");
    await expect(page.getByTestId("project-title")).toHaveText("Summer trip");
    expect(bodies).toEqual([{ title: "Summer trip" }]);
  });
});
