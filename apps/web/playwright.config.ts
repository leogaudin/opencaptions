import { defineConfig, devices } from "@playwright/test";
import { STORAGE_STATE } from "./tests/e2e/helpers/auth";

export default defineConfig({
  testDir: "./tests/e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  // The preview waits on the video and the engine's WebAssembly; several workers at once on one
  // machine make that slower than the default 5 s, which is a slow start and not a failure.
  expect: { timeout: 15_000 },
  reporter: process.env.CI ? [["github"], ["html", { open: "never" }]] : "list",
  use: {
    baseURL: process.env.BASE_URL ?? "http://localhost:5173",
    trace: "on-first-retry",
    screenshot: "only-on-failure",
  },
  projects: [
    // Authenticate ONCE for the whole run and persist the session to disk. The
    // test project reuses that storage state instead of every worker performing
    // its own auth round trip against a single shared account (which raced by
    // construction and hammered the throttle).
    { name: "setup", testMatch: /auth\.setup\.ts$/ },
    {
      name: "chromium",
      testMatch: /.*\.spec\.ts$/,
      use: { ...devices["Desktop Chrome"], storageState: STORAGE_STATE },
      dependencies: ["setup"],
    },
  ],
});
