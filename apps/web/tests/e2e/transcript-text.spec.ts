import { expect, test } from "@playwright/test";
import { MOCK_PROJECT_ID, mockTranscribedProject, type Transcript } from "./helpers/mockProject";

const word = (text: string, start: number, end: number) => ({ text, start, end, confidence: 1 });

const TRANSCRIPT: Transcript = {
  schema_version: 1,
  language: "en",
  language_detection: "manual",
  duration: 4,
  segments: [
    {
      id: "a",
      start: 0.5,
      end: 1.3,
      text: "one two",
      words: [word("one", 0.5, 0.9), word("two", 0.9, 1.3)],
    },
  ],
};

const SRT = `1
00:00:00,500 --> 00:00:01,500
Bonjour tout le monde

2
00:00:02,000 --> 00:00:03,000
Ça va
`;

test.describe("Transcript as text", () => {
  let saved: () => Record<string, unknown>;
  const savedWords = () =>
    (saved().transcript as Transcript).segments.flatMap((s) => s.words.map((w) => w.text));

  test.beforeEach(async ({ page }) => {
    saved = await mockTranscribedProject(page, "Text test", { transcript: TRANSCRIPT });
    await page.goto(`/projects/${MOCK_PROJECT_ID}`);
    await page.getByTestId("transcript-text-open").click();
  });

  test("an edited word is applied, and applying can be undone", async ({ page }) => {
    const text = page.getByTestId("transcript-text");
    await text.fill((await text.inputValue()).replace('"text": "two"', '"text": "deux"'));
    await expect(page.getByTestId("transcript-text-status")).toHaveText(/2 words in 1 segments/);
    await page.getByTestId("transcript-text-apply").click();
    await expect.poll(savedWords).toEqual(["one", "deux"]);
    await page.getByTestId("undo").click();
    await expect.poll(savedWords).toEqual(["one", "two"]);
  });

  test("text that is not a transcript says what is wrong and cannot be applied", async ({
    page,
  }) => {
    await page.getByTestId("transcript-text").fill("{ nope");
    await expect(page.getByRole("alert")).toContainText(/JSON/);
    await expect(page.getByTestId("transcript-text-apply")).toBeDisabled();
  });

  test("a subtitle file is read into the text, and applied as the transcript", async ({ page }) => {
    await page.getByTestId("transcript-import-file").setInputFiles({
      name: "subtitles.srt",
      mimeType: "application/x-subrip",
      buffer: Buffer.from(SRT),
    });
    await expect(page.getByTestId("transcript-text-status")).toHaveText(/6 words in 2 segments/);
    await page.getByTestId("transcript-text-apply").click();
    await expect.poll(savedWords).toEqual(["Bonjour", "tout", "le", "monde", "Ça", "va"]);
  });

  test("a file that is not subtitles is refused", async ({ page }) => {
    await page.getByTestId("transcript-import-file").setInputFiles({
      name: "notes.srt",
      mimeType: "text/plain",
      buffer: Buffer.from("just some words"),
    });
    await expect(page.getByRole("alert")).toContainText(/SRT, WebVTT/);
  });
});
