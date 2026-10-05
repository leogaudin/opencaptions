import { expect, type Locator, type Page, test } from "@playwright/test";
import { MOCK_PROJECT_ID, mockTranscribedProject, type Transcript } from "./helpers/mockProject";

const word = (text: string, start: number, end: number) => ({ text, start, end, confidence: 1 });

// Two on-screen lines at the default three words per line, the first spanning
// both segments: [one two three] and [four].
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
    {
      id: "b",
      start: 1.3,
      end: 3,
      text: "three four",
      words: [word("three", 1.3, 1.7), word("four", 2.6, 3)],
    },
  ],
};

type Saved = () => Record<string, unknown>;
const savedWords = (saved: Saved) =>
  (saved().transcript as Transcript).segments.flatMap((s) => s.words);

/** Drags a handle to the timeline position of `time` seconds on a `span`-second track. */
async function dragTo(
  page: Page,
  timeline: Locator,
  handle: Locator,
  time: number,
  span = TRANSCRIPT.duration,
) {
  const track = await timeline.boundingBox();
  const box = await handle.boundingBox();
  if (!track || !box) throw new Error("timeline not laid out");
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await page.mouse.move(track.x + (track.width * time) / span, box.y, { steps: 8 });
  await page.mouse.up();
}

test.describe("Timeline", () => {
  let saved: Saved;
  let timeline: Locator;

  test.beforeEach(async ({ page }) => {
    saved = await mockTranscribedProject(page, "Timeline test", { transcript: TRANSCRIPT });
    await page.goto(`/projects/${MOCK_PROJECT_ID}`);
    timeline = page.getByTestId("timeline").filter({ visible: true });
    await expect(timeline.getByTestId("timeline-line")).toHaveCount(2);
  });

  test("dragging a line's edges moves its first word's start and last word's end", async ({
    page,
  }) => {
    await timeline.getByTestId("timeline-line").first().click();
    await dragTo(page, timeline, timeline.getByTestId("timeline-end"), 2.2);
    await dragTo(page, timeline, timeline.getByTestId("timeline-start"), 0.2);

    await expect.poll(() => savedWords(saved)[2]?.end).toBeCloseTo(2.2, 1);
    await expect.poll(() => savedWords(saved)[0]?.start).toBeCloseTo(0.2, 1);
    // Only the edges move.
    expect(
      savedWords(saved)
        .slice(0, 3)
        .map((w) => [w.text, w.start]),
    ).toEqual([
      ["one", expect.any(Number)],
      ["two", 0.9],
      ["three", 1.3],
    ]);
  });

  test("an edge cannot cross the next line", async ({ page }) => {
    await timeline.getByTestId("timeline-line").first().click();
    await dragTo(page, timeline, timeline.getByTestId("timeline-end"), 3.5);
    await expect.poll(() => savedWords(saved)[2]?.end).toBe(2.6);
  });

  test("double-click edits a line's words; Escape cancels", async ({ page }) => {
    const second = timeline.getByTestId("timeline-line").nth(1);
    const input = timeline.getByTestId("timeline-edit");

    await second.dblclick();
    await input.fill("alpha beta");
    await input.press("Enter");
    await expect
      .poll(() => savedWords(saved).map((w) => w.text))
      .toEqual(["one", "two", "three", "alpha", "beta"]);
    // The two new words share the old word's span.
    const [alpha, beta] = savedWords(saved).slice(3);
    expect([alpha?.start, beta?.end]).toEqual([2.6, 3]);

    await timeline.getByTestId("timeline-line").first().dblclick();
    await input.fill("JUNK");
    await input.press("Escape");
    await expect(input).toHaveCount(0);
    await page.waitForTimeout(1200); // past the autosave debounce
    expect(savedWords(saved)[0]?.text).toBe("one");
  });

  test("with a caption offset, the timeline shows shifted times and saves unshifted ones", async ({
    page,
  }) => {
    saved = await mockTranscribedProject(page, "Offset test", {
      transcript: TRANSCRIPT,
      captionOffsetMs: 500,
    });
    await page.goto(`/projects/${MOCK_PROJECT_ID}`);
    await timeline.getByTestId("timeline-line").first().click();
    // The track covers the shifted captions: 4 s of video plus the 0.5 s offset.
    await dragTo(page, timeline, timeline.getByTestId("timeline-end"), 2.2, 4.5);
    await expect.poll(() => savedWords(saved)[2]?.end).toBeCloseTo(1.7, 1);
  });
});
