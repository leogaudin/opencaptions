import { expect, test } from "@playwright/test";

/**
 * Regression test: preview resize restores correctly after viewport shrink.
 *
 * The CaptionPreview component clamps its height to MAX_VIEWPORT_FRACTION of
 * the viewport. A previous bug caused the preview to shrink when the viewport
 * shrank (e.g. docking dev tools) but never grow back when the viewport was
 * restored: a one-directional ratchet caused by `window.innerHeight` being
 * read during render without being tracked as state.
 *
 * This test opens the editor at a large viewport, shrinks the viewport height
 * (simulating bottom-docked dev tools), then restores it, twice, and asserts
 * the preview returns to its original bounding box within ±2px each time.
 */
test.describe("CaptionPreview resize", () => {
  const LARGE_VP = { width: 1400, height: 900 };
  const SMALL_VP = { width: 1400, height: 550 };

  // The editor requires a session. Authentication is performed once by the
  // `setup` project (see playwright.config.ts); this spec inherits it via
  // storageState. The auth cookie therefore lives on the page context, so the
  // project lookup below uses page.request rather than the standalone `request`
  // fixture (which has its own, unauthenticated, cookie jar).

  test("preview restores to original size after viewport height shrink/restore cycle", async ({
    page,
  }) => {
    // Get a project ID from the API (authenticated via the page context).
    const resp = await page.request.get("/api/v1/projects");
    const body = await resp.json();
    const items = body.items ?? body;
    test.skip(!items.length, "No projects available, cannot test preview resize");
    const projectId = items[0].id;

    await page.setViewportSize(LARGE_VP);
    await page.goto(`/projects/${projectId}`);
    await page.waitForLoadState("networkidle");
    // Wait for the preview to render.
    await page.waitForTimeout(1000);

    const preview = page.getByTestId("caption-preview");

    // Helper: measure the visible preview's bounding box after layout settles.
    async function measurePreview() {
      await page.waitForTimeout(300); // layout settle
      return preview.boundingBox();
    }

    for (let cycle = 1; cycle <= 2; cycle++) {
      // 1. Large viewport baseline.
      await page.setViewportSize(LARGE_VP);
      const large = await measurePreview();
      expect(large, `cycle ${cycle}: preview visible at large VP`).not.toBeNull();

      // 2. Shrink viewport (simulates docked dev tools).
      await page.setViewportSize(SMALL_VP);
      const small = await measurePreview();
      expect(small, `cycle ${cycle}: preview visible at small VP`).not.toBeNull();
      // The preview should have shrunk.
      expect(small!.height).toBeLessThan(large!.height);

      // 3. Restore viewport, this is where the bug manifested.
      await page.setViewportSize(LARGE_VP);
      const restored = await measurePreview();
      expect(restored, `cycle ${cycle}: preview visible at restored VP`).not.toBeNull();
      // Must be within ±2px of the original.
      expect(Math.abs(restored!.width - large!.width)).toBeLessThanOrEqual(2);
      expect(Math.abs(restored!.height - large!.height)).toBeLessThanOrEqual(2);
    }
  });
});
