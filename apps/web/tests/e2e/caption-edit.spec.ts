import { expect, type Locator, test } from "@playwright/test";
import { MOCK_PROJECT_ID, mockTranscribedProject, type Transcript } from "./helpers/mockProject";

const word = (text: string, start: number, end: number) => ({ text, start, end, confidence: 1 });

// One line, "alpha beta", showing at t=0 where a paused video starts.
const TRANSCRIPT: Transcript = {
  schema_version: 1,
  language: "en",
  language_detection: "manual",
  duration: 4,
  segments: [
    {
      id: "a",
      start: 0,
      end: 2,
      text: "alpha beta",
      words: [word("alpha", 0, 1), word("beta", 1, 2)],
    },
  ],
};

test.describe("Editing a word on the preview", () => {
  let saved: () => Record<string, unknown>;
  let handle: Locator;
  let input: Locator;
  const savedWords = () =>
    (saved().transcript as Transcript).segments.flatMap((s) => s.words.map((w) => w.text));

  test.beforeEach(async ({ page }) => {
    saved = await mockTranscribedProject(page, "Edit test", { transcript: TRANSCRIPT });
    await page.goto(`/projects/${MOCK_PROJECT_ID}`);
    handle = page.getByTestId("caption-handle");
    input = page.getByTestId("caption-word-edit");
    await expect(handle).toBeVisible();
  });

  /** Double-clicks the first word of the line: the left part of the caption block. */
  async function editFirstWord() {
    const box = await handle.boundingBox();
    if (!box) throw new Error("caption not laid out");
    await handle.dblclick({ position: { x: box.width * 0.3, y: box.height / 2 } });
    await expect(input).toHaveValue("alpha");
  }

  test("a double-click renames the word under it, keeping its timing", async () => {
    await editFirstWord();
    await input.fill("gamma");
    await input.press("Enter");
    await expect.poll(savedWords).toEqual(["gamma", "beta"]);
    const first = (saved().transcript as Transcript).segments[0]?.words[0];
    expect([first?.start, first?.end]).toEqual([0, 1]);
  });

  test("typing several words splits the word, sharing its time", async () => {
    await editFirstWord();
    await input.fill("hello world");
    await expect(input).toHaveValue("hello world");
    await input.press("Enter");
    await expect.poll(savedWords).toEqual(["hello", "world", "beta"]);
    const [hello, world] = (saved().transcript as Transcript).segments[0]?.words ?? [];
    expect([hello?.start, world?.end]).toEqual([0, 1]);
    expect(hello?.end).toBe(world?.start);
  });

  test("Escape cancels", async ({ page }) => {
    await editFirstWord();
    await input.fill("JUNK");
    await input.press("Escape");
    await expect(input).toHaveCount(0);
    await page.waitForTimeout(1200); // past the autosave debounce
    expect(savedWords()).toEqual(["alpha", "beta"]);
  });

  test("clearing the word deletes it", async () => {
    await editFirstWord();
    await input.fill("");
    await input.press("Enter");
    await expect.poll(savedWords).toEqual(["beta"]);
  });
});
