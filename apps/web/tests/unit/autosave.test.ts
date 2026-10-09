import assert from "node:assert/strict";
import { beforeEach, describe, mock, test } from "node:test";
import { createAutosave } from "../../src/lib/autosave.ts";

/** Let pending promise callbacks run; timers are mocked, setImmediate is not. */
const settle = () => new Promise<void>((resolve) => setImmediate(resolve));

function harness(opts: { blocked?: () => boolean } = {}) {
  const state = { value: 0 };
  const saves: number[] = [];
  const gates: Array<(ok: boolean) => void> = [];
  const autosave = createAutosave({
    delayMs: 800,
    read: () => state.value,
    // Each save waits for the test to finish it.
    save: () =>
      new Promise<boolean>((resolve) => {
        saves.push(state.value);
        gates.push(resolve);
      }),
    isBlocked: opts.blocked ?? (() => false),
  });
  const edit = (value: number) => {
    state.value = value;
    autosave.schedule();
  };
  return { autosave, edit, saves, gates };
}

describe("autosave", () => {
  beforeEach(() => {
    mock.timers.reset();
    mock.timers.enable({ apis: ["setTimeout"] });
  });

  test("saves once, 800 ms after the last edit", async () => {
    const { edit, saves, gates } = harness();
    edit(1);
    mock.timers.tick(700);
    edit(2);
    mock.timers.tick(700);
    await settle();
    assert.deepEqual(saves, []);
    mock.timers.tick(100);
    await settle();
    assert.deepEqual(saves, [2]);
    gates[0]?.(true);
  });

  test("an edit during a save waits for it, then is saved after it", async () => {
    const { edit, saves, gates } = harness();
    edit(1);
    mock.timers.tick(800);
    await settle();
    assert.deepEqual(saves, [1]);

    edit(2);
    mock.timers.tick(800);
    await settle();
    // Still one request in flight: the second must not start beside it.
    assert.deepEqual(saves, [1]);

    gates[0]?.(true);
    await settle();
    assert.deepEqual(saves, [1, 2]);
    gates[1]?.(true);
    await settle();
    assert.equal(gates.length, 2);
  });

  test("a failed save is retried with a growing delay", async () => {
    const { edit, saves, gates } = harness();
    edit(1);
    mock.timers.tick(800);
    await settle();
    gates[0]?.(false);
    await settle();
    assert.deepEqual(saves, [1]);

    mock.timers.tick(1_600);
    await settle();
    assert.deepEqual(saves, [1, 1]);
    gates[1]?.(false);
    await settle();

    mock.timers.tick(3_199);
    await settle();
    assert.equal(saves.length, 2);
    mock.timers.tick(1);
    await settle();
    assert.equal(saves.length, 3);
    gates[2]?.(true);
    await settle();
    mock.timers.tick(60_000);
    await settle();
    assert.equal(saves.length, 3, "nothing is left unsaved, so nothing is retried");
  });

  test("a save held back by isBlocked runs on release", async () => {
    let blocked = true;
    const { autosave, edit, saves, gates } = harness({ blocked: () => blocked });
    edit(1);
    mock.timers.tick(5_000);
    await settle();
    assert.deepEqual(saves, []);
    blocked = false;
    autosave.release();
    mock.timers.tick(800);
    await settle();
    assert.deepEqual(saves, [1]);
    gates[0]?.(true);
  });

  test("dirty() tells unsaved changes from the saved state", async () => {
    const { autosave, edit } = harness();
    autosave.markSaved();
    assert.equal(autosave.dirty(), false);
    edit(3);
    assert.equal(autosave.dirty(), true);
    autosave.markSaved();
    assert.equal(autosave.dirty(), false);
  });

  test("flush saves now and resolves when it is done", async () => {
    const { autosave, edit, saves, gates } = harness();
    edit(4);
    const flushed = autosave.flush();
    await settle();
    assert.deepEqual(saves, [4]);
    gates[0]?.(true);
    await flushed;
    assert.equal(autosave.dirty(), false);
  });

  test("a save that finishes after reset records nothing", async () => {
    const { autosave, edit, saves, gates } = harness();
    edit(5);
    mock.timers.tick(800);
    await settle();
    autosave.reset();
    gates[0]?.(true);
    await settle();
    // After reset nothing is known to be saved, so the same state is dirty again.
    assert.equal(autosave.dirty(), true);
    edit(5);
    mock.timers.tick(800);
    await settle();
    assert.deepEqual(saves, [5, 5]);
    gates[1]?.(true);
  });
});
