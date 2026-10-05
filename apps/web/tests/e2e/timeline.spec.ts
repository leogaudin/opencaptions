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
    timeline = page.getByTestId("timeline");
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

  const currentTime = (page: Page) =>
    page.evaluate(() => (document.querySelector("video") as HTMLVideoElement).currentTime);
  const trackWidth = async () => (await timeline.boundingBox())?.width ?? 0;

  test("the ruler and the video track seek, and the playhead follows", async ({ page }) => {
    const ruler = page.getByTestId("timeline-ruler");
    const box = await ruler.boundingBox();
    if (!box) throw new Error("ruler not laid out");
    await page.mouse.click(box.x + box.width / 2, box.y + 8);
    await expect.poll(() => currentTime(page)).toBeCloseTo(2, 1);
    const head = await page.getByTestId("timeline-playhead").boundingBox();
    expect(head?.x).toBeCloseTo(box.x + box.width / 2, -1);

    // Dragging scrubs.
    await page.mouse.move(box.x + box.width * 0.25, box.y + 8);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width * 0.75, box.y + 8, { steps: 6 });
    await page.mouse.up();
    await expect.poll(() => currentTime(page)).toBeCloseTo(3, 1);

    const clip = await page.getByTestId("timeline-video").boundingBox();
    if (!clip) throw new Error("video track not laid out");
    await page.mouse.click(clip.x + clip.width / 4, clip.y + clip.height / 2);
    await expect.poll(() => currentTime(page)).toBeCloseTo(1, 1);
  });

  test("ctrl+wheel zooms around the pointer, and Fit brings the whole video back", async ({
    page,
  }) => {
    const fitWidth = await trackWidth();
    const track = await timeline.boundingBox();
    if (!track) throw new Error("timeline not laid out");
    const [x, y] = [track.x + track.width * 0.6, track.y + 10];
    const timeUnderPointer = async () => {
      const b = await timeline.boundingBox();
      return b ? ((x - b.x) / b.width) * TRANSCRIPT.duration : Number.NaN;
    };
    const before = await timeUnderPointer();

    await page.mouse.move(x, y);
    await page.keyboard.down("Control");
    await page.mouse.wheel(0, -100);
    await page.keyboard.up("Control");
    // A 4 s clip fits at 300 px/s, so the 400 px/s limit leaves a third to zoom.
    await expect.poll(trackWidth).toBeGreaterThan(fitWidth * 1.2);
    expect(await timeUnderPointer()).toBeCloseTo(before, 1);

    await page.getByTestId("zoom-fit").click();
    await expect.poll(trackWidth).toBeCloseTo(fitWidth, 0);
  });

  test("the zoom buttons zoom in and out, and stop at the whole video", async ({ page }) => {
    const fitWidth = await trackWidth();
    await expect(page.getByTestId("zoom-out")).toBeDisabled();
    await expect(page.getByTestId("zoom-fit")).toBeDisabled();

    await page.getByTestId("zoom-in").click();
    await expect.poll(trackWidth).toBeGreaterThan(fitWidth * 1.2);
    await expect(page.getByTestId("zoom-out")).toBeEnabled();

    await page.getByTestId("zoom-out").click();
    await expect.poll(trackWidth).toBeCloseTo(fitWidth, 0);
    await expect(page.getByTestId("zoom-out")).toBeDisabled();
  });
});
