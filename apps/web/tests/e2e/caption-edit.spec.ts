import { readFileSync } from "node:fs";
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
  async function editFirstWord(expected = "alpha") {
    const box = await handle.boundingBox();
    if (!box) throw new Error("caption not laid out");
    await handle.dblclick({ position: { x: box.width * 0.3, y: box.height / 2 } });
    await expect(input).toHaveValue(expected);
  }

  test("a double-click renames the word under it, keeping its timing", async () => {
    await editFirstWord();
    await input.fill("gamma");
    await input.press("Enter");
    await expect.poll(savedWords).toEqual(["gamma", "beta"]);
    const first = (saved().transcript as Transcript).segments[0]?.words[0];
    expect([first?.start, first?.end]).toEqual([0, 1]);
  });

  test("spaces are kept: it is still one word, with its timing", async () => {
    await editFirstWord();
    await input.fill("hello  world");
    await expect(input).toHaveValue("hello  world");
    await input.press("Enter");
    await expect.poll(savedWords).toEqual(["hello world", "beta"]);
    const first = (saved().transcript as Transcript).segments[0]?.words[0];
    expect([first?.start, first?.end]).toEqual([0, 1]);
  });

  test("Escape cancels", async ({ page }) => {
    // Every save the editor sends: a cancelled edit must never be in one.
    const sent: string[] = [];
    page.on("request", (request) => {
      if (request.method() === "PATCH") sent.push(request.postData() ?? "");
    });
    await editFirstWord();
    await input.fill("JUNK");
    await input.press("Escape");
    await expect(input).toHaveCount(0);
    // A real edit afterwards is saved after anything the cancelled one could have sent (saves go
    // out in order), so once it has landed there is nothing more to wait for.
    await editFirstWord();
    await input.fill("omega");
    await input.press("Enter");
    await expect.poll(savedWords).toEqual(["omega", "beta"]);
    expect(sent.length).toBeGreaterThan(0);
    expect(sent.filter((body) => body.includes("JUNK"))).toEqual([]);
  });

  test("clearing the word deletes it", async () => {
    await editFirstWord();
    await input.fill("");
    await input.press("Enter");
    await expect.poll(savedWords).toEqual(["beta"]);
  });
});

test.describe("Editing a word on a caption that follows a pause", () => {
  // [a b] then, after 1.6 s of quiet at a 0.2 s pace, [c d]: the pause ends the first caption
  // instead of three words being cut as [a b c] [d].
  const AFTER_A_PAUSE: Transcript = {
    schema_version: 1,
    language: "en",
    language_detection: "manual",
    duration: 4,
    segments: [
      {
        id: "a",
        start: 0,
        end: 2.4,
        text: "a b c d",
        words: [word("a", 0, 0.2), word("b", 0.2, 0.4), word("c", 2, 2.2), word("d", 2.2, 2.4)],
      },
    ],
  };

  test("the word under the pointer is the one renamed", async ({ page }) => {
    const saved = await mockTranscribedProject(page, "Pause test", { transcript: AFTER_A_PAUSE });
    await page.goto(`/projects/${MOCK_PROJECT_ID}`);
    const handle = page.getByTestId("caption-handle");
    await expect(handle).toBeVisible();
    await page.evaluate(() => {
      (document.querySelector("video") as HTMLVideoElement).currentTime = 2.3;
    });
    await expect(handle).toBeVisible();
    const box = await handle.boundingBox();
    if (!box) throw new Error("caption not laid out");
    // The second caption is [c d]: its right half is "d", word 3 of the transcript.
    await handle.dblclick({ position: { x: box.width * 0.8, y: box.height / 2 } });
    const input = page.getByTestId("caption-word-edit");
    await expect(input).toHaveValue("d");
    await input.fill("x");
    await input.press("Enter");
    await expect
      .poll(() =>
        (saved().transcript as Transcript).segments.flatMap((s) => s.words.map((w) => w.text)),
      )
      .toEqual(["a", "b", "c", "x"]);
  });
});

test.describe("Giving a word a look", () => {
  // The Editorial preset defines five looks; the transcript starts with none chosen.
  const presets: { name: string; config: Record<string, unknown> }[] = JSON.parse(
    readFileSync(new URL("../../src/lib/presets.json", import.meta.url), "utf8"),
  );
  const editorial = presets.find((p) => p.name === "Editorial")?.config;

  test("a look chosen on the word card is saved and shown again after a reload", async ({
    page,
  }) => {
    const saved = await mockTranscribedProject(page, "Looks test", {
      transcript: TRANSCRIPT,
      styleConfig: editorial,
    });
    const firstLook = () =>
      (saved().transcript as Transcript).segments[0]?.words[0]?.variant ?? null;
    const open = async () => {
      await page.goto(`/projects/${MOCK_PROJECT_ID}`);
      const handle = page.getByTestId("caption-handle");
      await expect(handle).toBeVisible();
      const box = await handle.boundingBox();
      if (!box) throw new Error("caption not laid out");
      await handle.dblclick({ position: { x: box.width * 0.2, y: box.height / 2 } });
      await expect(page.getByTestId("caption-word-edit")).toHaveValue("alpha");
    };
    await open();
    // The base look and the five of the preset, drawn by the engine.
    for (const id of ["base", "0", "1", "2", "3", "4"]) {
      await expect(page.getByTestId(`word-look-${id}`)).toBeVisible();
    }
    await page.getByTestId("word-look-2").click();
    await expect.poll(firstLook).toBe(2);
    await expect
      .poll(() => (saved().transcript as Transcript).segments[0]?.words[0]?.text)
      .toBe("alpha");
    await open();
    await expect(page.getByTestId("word-look-2")).toHaveAttribute("aria-pressed", "true");
    await page.getByTestId("word-look-base").click();
    await expect.poll(firstLook).toBe(null);
  });
  test("shuffling deals the looks to the words, and it is saved", async ({ page }) => {
    const saved = await mockTranscribedProject(page, "Shuffle test", {
      transcript: TRANSCRIPT,
      styleConfig: editorial,
    });
    await page.goto(`/projects/${MOCK_PROJECT_ID}`);
    const dealt = () =>
      (saved().transcript as Transcript).segments
        .flatMap((s) => s.words)
        .filter((w) => w.variant != null).length;
    // Each word has an even chance of keeping the style's own look, so ask again until one is dealt.
    await expect
      .poll(async () => {
        await page.getByTestId("shuffle-looks").click();
        return dealt();
      })
      .toBeGreaterThan(0);
  });
});
