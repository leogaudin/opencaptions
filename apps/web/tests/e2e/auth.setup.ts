import { test as setup } from "@playwright/test";
import { authenticate, STORAGE_STATE } from "./helpers/auth";

/**
 * One-time authentication for the whole e2e run (Playwright "setup project").
 *
 * This runs before the test project (declared as its `dependencies`), so it is
 * the single place an auth round trip happens. It authenticates once and writes
 * the browser storage state: the httpOnly session cookie, to STORAGE_STATE,
 * which the test project then loads via `use.storageState`.
 *
 * `authenticate` registers on a fresh instance (first account → admin) and logs
 * in when the account already exists, so this setup is idempotent across
 * repeated runs without wiping the database.
 */
setup("authenticate", async ({ page }) => {
  await authenticate(page);
  await page.context().storageState({ path: STORAGE_STATE });
});
