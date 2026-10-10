import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  emptyHistory,
  GROUP_WINDOW_MS,
  MAX_STEPS,
  recordEdit,
  redo,
  undo,
} from "../../src/lib/history.ts";

describe("history", () => {
  it("steps back and forward through edits", () => {
    let h = emptyHistory<string>();
    h = recordEdit(h, "a"); // a → b
    h = recordEdit(h, "b"); // b → c
    const back = undo(h, "c");
    assert.equal(back?.value, "b");
    const again = back && undo(back.history, back.value);
    assert.equal(again?.value, "a");
    assert.equal(again && undo(again.history, again.value), null, "nothing before the first edit");
    const forward = again && redo(again.history, again.value);
    assert.equal(forward?.value, "b");
    const last = forward && redo(forward.history, forward.value);
    assert.equal(last?.value, "c");
    assert.equal(last && redo(last.history, last.value), null);
  });

  it("forgets what could be redone once something new is edited", () => {
    let h = recordEdit(emptyHistory<string>(), "a");
    const back = undo(h, "b");
    assert.ok(back);
    h = recordEdit(back.history, "a");
    assert.deepEqual(h.future, []);
    assert.equal(redo(h, "x"), null);
  });

  it("joins edits of one group made close together into one step", () => {
    let h = emptyHistory<number>();
    h = recordEdit(h, 0, "drag", 1000);
    h = recordEdit(h, 1, "drag", 1100);
    h = recordEdit(h, 2, "drag", 1200);
    assert.deepEqual(h.past, [0], "undo goes back to before the drag");
  });

  it("starts a new step for another group, a pause, or no group", () => {
    let h = emptyHistory<number>();
    h = recordEdit(h, 0, "drag", 1000);
    h = recordEdit(h, 1, "other", 1100);
    assert.deepEqual(h.past, [0, 1]);
    h = recordEdit(h, 2, "other", 1100 + GROUP_WINDOW_MS);
    assert.deepEqual(h.past, [0, 1, 2], "a pause ends the step");
    h = recordEdit(h, 3, null, 1100 + GROUP_WINDOW_MS);
    h = recordEdit(h, 4, null, 1100 + GROUP_WINDOW_MS);
    assert.deepEqual(h.past, [0, 1, 2, 3, 4], "ungrouped edits never join");
  });

  it("does not join an edit to a step that was undone", () => {
    let h = recordEdit(emptyHistory<number>(), 0, "drag", 1000);
    const back = undo(h, 1);
    assert.ok(back);
    h = recordEdit(back.history, 0, "drag", 1100);
    assert.deepEqual(h.past, [0]);
  });

  it("keeps a bounded number of steps, newest last", () => {
    let h = emptyHistory<number>();
    for (let i = 0; i < MAX_STEPS + 20; i++) h = recordEdit(h, i);
    assert.equal(h.past.length, MAX_STEPS);
    assert.equal(h.past[h.past.length - 1], MAX_STEPS + 19);
    assert.equal(h.past[0], 20);
  });
});
