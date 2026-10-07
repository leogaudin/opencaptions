import type { Page } from "@playwright/test";

/**
 * Shared E2E auth.
 *
 * Authentication runs ONCE per suite in the `setup` project (`auth.setup.ts`),
 * which calls `authenticate` and saves the resulting browser storage state (the
 * httpOnly session cookie) to STORAGE_STATE. The test project loads that state
 * via `use.storageState`, so individual specs start already authenticated and
 * never perform their own auth round trip: the old per-worker approach raced on
 * a single shared account and tripped the throttle.
 *
 * `authenticate` registers the account via the API, which sets the httpOnly
 * session cookie on the page's browser context: and, if it already exists (the
 * DB isn't fresh, e.g. a second local run), falls back to logging in with the
 * same credentials. Either way the page context ends up authenticated. We
 * authenticate at the API layer rather than driving the login form so setup is
 * fast and independent of the auth UI's own markup. Auth calls use page.request
 * (bound to the page's context) so the cookie lands in the context whose state
 * we persist.
 */
export const E2E_USER = {
  email: "e2e@opencaptions.test",
  password: "e2e-password-1234",
};

// Where the setup project writes the authenticated storage state and the test
// project reads it from (see playwright.config.ts). Relative to apps/web;
// gitignored so it is never committed.
export const STORAGE_STATE = "playwright/.auth/user.json";

export async function authenticate(page: Page): Promise<void> {
  const register = await page.request.post("/api/v1/auth/register", { data: E2E_USER });
  if (register.ok()) return;
  const login = await page.request.post("/api/v1/auth/login", { data: E2E_USER });
  if (!login.ok()) {
    throw new Error(
      `E2E auth setup failed: register → ${register.status()}, login → ${login.status()}`,
    );
  }
}
