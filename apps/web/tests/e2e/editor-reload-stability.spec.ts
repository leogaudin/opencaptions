import { expect, test } from "@playwright/test";

/**
 * Regression: a background project refresh must NOT remount the preview.
 *
 * The editor subscribes to the project WebSocket; job_succeeded /
 * transcript_updated / job_failed / job_cancelled all call reloadProject(),
 * which runs loadProject() and flips the store's `loading` flag true for the
 * duration of the fetch. EditorPage previously gated on `loading || !project`,
 * so every such background refresh swapped the whole editor for a
 * "Loading project…" screen: unmounting CaptionPreview and its <video> and
 * recreating it at frame 0. A playing preview visibly restarted on each event
 * ("looks like a reload"). The gate is now `!project`, so a refresh that keeps
 * the current project re-renders the preview in place instead of remounting it.
 *
 * We mock the project WebSocket, push a transcript_updated frame, and assert
 * the preview's <video> is the SAME DOM node afterwards (re-rendered in place,
 * not remounted) and that the loading screen never replaced the editor.
 */
test.describe("Editor stays mounted across background reloads", () => {
  test("transcript_updated over WS does not remount the preview", async ({ page }) => {
    // Intercept the project WebSocket so it "connects" and we can push a
    // server->client broadcast. Store the routes to send on after the page is
    // ready (the real proxy is not exercised here, this is a pure client test).
    type WsRoute = Parameters<Parameters<typeof page.routeWebSocket>[1]>[0];
    const wsRoutes: WsRoute[] = [];
    await page.routeWebSocket(/\/ws\/v1\/projects\//, (ws) => {
      wsRoutes.push(ws);
      // Ignore client->server frames; the client only ever pings.
      ws.onMessage(() => undefined);
    });

    const resp = await page.request.get("/api/v1/projects");
    const body = await resp.json();
    const items = body.items ?? body;
    test.skip(!items.length, "No projects available, cannot test reload stability");
    const projectId = items[0].id;

    await page.setViewportSize({ width: 1400, height: 900 });
    await page.goto(`/projects/${projectId}`);

    // The preview renders once the transcript has segments and dimensions resolve.
    const preview = page.getByTestId("caption-preview");
    await expect(preview).toBeVisible({ timeout: 15000 });

    const video = preview.locator("video").first();
    await expect(video).toHaveCount(1);
    const videoHandle = await video.elementHandle();
    expect(videoHandle, "preview <video> should exist").not.toBeNull();

    // Push broadcasts that trigger reloadProject() in the editor.
    expect(wsRoutes.length, "project WebSocket should be intercepted").toBeGreaterThan(0);
    for (let i = 0; i < 3; i++) {
      for (const ws of wsRoutes) {
        ws.send(JSON.stringify({ type: "transcript_updated", payload: {} }));
      }
      await page.waitForTimeout(400);
    }
    // Let the async reload(s) settle.
    await page.waitForTimeout(600);

    // The editor must never have been swapped for the loading screen.
    await expect(page.getByText("Loading project")).toHaveCount(0);

    // The original <video> node must still be attached: the preview was
    // re-rendered in place, not torn down and recreated at frame 0.
    const stillConnected = await videoHandle!.evaluate((el) => el.isConnected);
    expect(stillConnected, "Preview <video> must survive a background reload (no remount)").toBe(
      true,
    );
  });
});
